import Foundation

/// A minimal Language Server Protocol client for `clangd`.
///
/// Scope is deliberately narrow: this exists to give the editor **semantic**
/// completion (member access, overloads, correct signatures) instead of the
/// text-based approximation. It speaks JSON-RPC over the server's stdin/stdout and
/// implements only the subset needed for completion:
///
///   initialize → initialized → didOpen / didChange → completion
///
/// Design notes:
/// * One process per workspace; restarted if it exits.
/// * Requests are answered on a background queue; callbacks are delivered on the
///   main queue so the UI can consume them directly.
/// * Never blocks the editor: if the server is not ready yet, callers get nil and
///   the text-based provider covers the gap.
public final class ClangdSession {

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    /// Called on the main queue whenever `state` changes.
    public var onStateChange: ((State) -> Void)?
    /// Diagnostics pushed by the server for a file, keyed by URI.
    ///
    /// clangd publishes these after every parse (debounced internally), which is
    /// what makes live error checking possible without compiling.
    public var onDiagnostics: ((String, [LSPDiagnostic]) -> Void)? {
        didSet {
            // Replay the most recent result: a subscriber set after the first
            // publish (common: the editor attaches after the server starts) must
            // not miss the diagnostics that already arrived.
            lock.lock()
            let snapshot = latestDiagnostics
            lock.unlock()
            if let snapshot {
                DispatchQueue.main.async { [weak self] in
                    self?.onDiagnostics?(snapshot.uri, snapshot.items)
                }
            }
        }
    }

    /// Last diagnostics per URI, kept for late subscribers.
    private var latestDiagnostics: (uri: String, items: [LSPDiagnostic])?

    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            let snapshot = state
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(snapshot)
            }
        }
    }

    private let executable: String
    private let workingDirectory: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let ioQueue = DispatchQueue(label: "RideCPP.ClangdSession.io")
    private var nextRequestID = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private let lock = NSLock()
    /// Document version per URI, required by `didChange`.
    private var versions: [String: Int] = [:]
    private var openDocuments: Set<String> = []
    /// Documents requested before the handshake finished, replayed once ready.
    ///
    /// Dropping these was why clangd kept analysing the on-disk version of a file:
    /// the very first sync happens before `initialize` completes.
    private var pendingSync: [String: String] = [:]

    public struct ServerFailure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init?(workingDirectory: URL) {
        guard let found = ClangdSession.findClangd() else { return nil }
        self.executable = found
        self.workingDirectory = workingDirectory
    }

    /// Locates a `clangd` binary: PATH first, then the Xcode toolchain.
    ///
    /// Xcode ships clangd, so on a machine with the command line tools there is
    /// nothing to install.
    public static func findClangd() -> String? {
        for candidate in ["/usr/bin/clangd",
                          "/opt/homebrew/opt/llvm/bin/clangd"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let xcrun = runAndCapture("/usr/bin/xcrun", ["-f", "clangd"]) {
            let path = xcrun.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Starts the server and performs the LSP handshake.
    public func start() {
        guard process == nil else { return }
        state = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // `--log=error` keeps stderr quiet; clangd is chatty otherwise.
        process.arguments = ["--log=error"]
        process.currentDirectoryURL = workingDirectory
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        // Drain stderr so the child never blocks on a full pipe.
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.ioQueue.async {
                self.process = nil
                self.stdin = nil
                self.openDocuments.removeAll()
                self.versions.removeAll()
                self.failAllPending(ServerFailure(message: "clangd exited"))
                self.state = .stopped
            }
        }

        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        self.stdin = input.fileHandleForWriting

        sendRequest(method: "initialize", params: [
            "processId": NSNull(),
            "rootUri": "file://" + workingDirectory.path,
            "capabilities": [
                "textDocument": [
                    "completion": [
                        "completionItem": [
                            "snippetSupport": true,
                            "documentationFormat": ["plaintext"]
                        ]
                    ],
                    "synchronization": ["didSave": false]
                ]
            ]
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.sendNotification(method: "initialized", params: [:])
                self.state = .ready
                // Replay whatever arrived while starting up.
                self.ioQueue.async { [weak self] in
                    guard let self else { return }
                    let queued = self.pendingSync
                    self.pendingSync.removeAll()
                    for (uri, text) in queued {
                        self.openDocument(uri: uri, text: text)
                    }
                }
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.sendNotification(method: "exit", params: [:])
            self.stdin?.closeFile()
            self.process?.terminate()
            self.process = nil
            self.stdin = nil
            self.state = .stopped
        }
    }

    // MARK: - Document sync

    /// Tells the server the current contents of a file.
    public func openDocument(uri: String, text: String, languageID: String = "cpp") {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.state == .ready else {
                // Remember it and replay after the handshake; the latest text wins.
                self.pendingSync[uri] = text
                return
            }
            if self.openDocuments.contains(uri) {
                self.versions[uri, default: 1] += 1
                self.sendNotification(method: "textDocument/didChange", params: [
                    "textDocument": ["uri": uri, "version": self.versions[uri] ?? 1],
                    "contentChanges": [["text": text]]
                ])
            } else {
                self.openDocuments.insert(uri)
                self.versions[uri] = 1
                self.sendNotification(method: "textDocument/didOpen", params: [
                    "textDocument": ["uri": uri,
                                     "languageId": languageID,
                                     "version": 1,
                                     "text": text]
                ])
            }
        }
    }

    // MARK: - Completion

    /// Requests completions at a UTF-16 position. `nil` when the server is busy or
    /// not ready, so callers can fall back without blocking.
    /// Requests completions. `completion` is called on the session's IO queue.
    ///
    /// Deliberately *not* dispatched to the main queue: callers that need the main
    /// thread can hop themselves, and a busy main queue (during a build, or in the
    /// self-test) would otherwise stall the answer indefinitely.
    public func requestCompletions(uri: String,
                                   line: Int,
                                   character: Int,
                                   completion: @escaping ([LSPCompletionItem]) -> Void) {
        sendRequest(method: "textDocument/completion", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character]
        ]) { result in
            guard case .success(let value) = result else {
                completion([])
                return
            }
            completion(LSPCompletionItem.parse(value))
        }
    }

    // MARK: - Navigation

    /// Asks the server for the declaration/definition at a position.
    ///
    /// Returns every location the server reports, so a symbol declared in a header
    /// and defined in a source file both come back.
    public func requestDefinition(uri: String,
                                  position: LSPPosition,
                                  completion: @escaping ([LSPLocation]) -> Void) {
        sendRequest(method: "textDocument/definition", params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ]) { result in
            guard case .success(let value) = result else {
                completion([])
                return
            }
            completion(Self.locations(from: value))
        }
    }

    /// Asks for hover text: type, signature and documentation.
    public func requestHover(uri: String,
                             position: LSPPosition,
                             completion: @escaping (String?) -> Void) {
        sendRequest(method: "textDocument/hover", params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ]) { result in
            guard case .success(let value) = result,
                  let payload = value as? [String: Any] else {
                completion(nil)
                return
            }
            // `contents` may be a string, a MarkupContent, or an array of either.
            if let text = Self.markupText(payload["contents"]) {
                completion(text.isEmpty ? nil : text)
            } else {
                completion(nil)
            }
        }
    }

    /// Asks for quick fixes at a range, given the diagnostics reported there.
    ///
    /// The diagnostics must be passed back: LSP expects the client to echo them, and
    /// clangd returns no actions when the list is empty.
    public func requestCodeActions(uri: String,
                                   range: LSPRange,
                                   diagnostics: [LSPDiagnostic],
                                   completion: @escaping ([LSPCodeAction]) -> Void) {
        let context: [String: Any] = [
            "diagnostics": diagnostics.map(Self.diagnosticJSON),
            "triggerKind": 1
        ]
        sendRequest(method: "textDocument/codeAction", params: [
            "textDocument": ["uri": uri],
            "range": [
                "start": ["line": range.start.line, "character": range.start.character],
                "end": ["line": range.end.line, "character": range.end.character]
            ],
            "context": context
        ]) { result in
            guard case .success(let value) = result,
                  let actions = value as? [[String: Any]] else {
                completion([])
                return
            }
            completion(actions.compactMap(Self.codeAction(from:)))
        }
    }

    // MARK: - JSON-RPC

    private func sendRequest(method: String,
                             params: [String: Any],
                             completion: @escaping (Result<Any, Error>) -> Void) {
        ioQueue.async { [weak self] in
            guard let self, let stdin = self.stdin else {
                completion(.failure(ServerFailure(message: "clangd is not running")))
                return
            }
            self.lock.lock()
            let id = self.nextRequestID
            self.nextRequestID += 1
            self.pending[id] = completion
            self.lock.unlock()

            let message: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                          "method": method, "params": params]
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            var framed = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
            framed.append(data)
            stdin.write(framed)
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        guard let stdin else { return }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var framed = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        framed.append(data)
        stdin.write(framed)
    }

    /// Accumulates bytes and dispatches every complete LSP message.
    private func ingest(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(data)
            while let message = self.takeMessage() {
                self.handle(message)
            }
        }
    }

    /// Extracts one `Content-Length`-framed JSON payload, if complete.
    private func takeMessage() -> [String: Any]? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard length > 0 else {
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer[bodyStart..<bodyEnd]
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }

    private func handle(_ message: [String: Any]) {
        // Notifications have no id; they are how the server pushes diagnostics.
        guard let id = message["id"] as? Int else {
            handleNotification(message)
            return
        }
        lock.lock()
        let completion = pending.removeValue(forKey: id)
        lock.unlock()
        guard let completion else { return }
        if let error = message["error"] as? [String: Any] {
            completion(.failure(ServerFailure(message: error["message"] as? String ?? "clangd error")))
        } else {
            completion(.success(message["result"] ?? NSNull()))
        }
    }

    /// Handles a server-initiated notification.
    private func handleNotification(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let uri = params["uri"] as? String,
                  let raw = params["diagnostics"] as? [[String: Any]] else { return }
            let diagnostics = raw.compactMap(LSPDiagnostic.init(json:))
            lock.lock()
            latestDiagnostics = (uri, diagnostics)
            let handler = onDiagnostics
            lock.unlock()
            DispatchQueue.main.async { handler?(uri, diagnostics) }
        default:
            // `window/logMessage`, `telemetry/event`, … are intentionally ignored.
            break
        }
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let callbacks = pending.values
        pending.removeAll()
        lock.unlock()
        for callback in callbacks { callback(.failure(error)) }
    }

    private static func runAndCapture(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    // MARK: - Payload decoding

    /// Extracts every location from a definition result.
    static func locations(from value: Any) -> [LSPLocation] {
        var raw: [[String: Any]] = []
        if let list = value as? [[String: Any]] {
            raw = list
        } else if let single = value as? [String: Any] {
            raw = [single]
        }
        return raw.compactMap { item in
            guard let uri = item["uri"] as? String,
                  let range = range(from: item["range"]) else { return nil }
            return LSPLocation(uri: uri, range: range)
        }
    }

    /// Decodes a range dictionary.
    static func range(from value: Any?) -> LSPRange? {
        guard let json = value as? [String: Any],
              let start = json["start"] as? [String: Any],
              let end = json["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startChar = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endChar = end["character"] as? Int else { return nil }
        return LSPRange(start: LSPPosition(line: startLine, character: startChar),
                        end: LSPPosition(line: endLine, character: endChar))
    }

    /// Flattens LSP markup (string | MarkupContent | array of either) into text.
    static func markupText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let json = value as? [String: Any] {
            return json["value"] as? String
        }
        if let list = value as? [Any] {
            let parts = list.compactMap { markupText($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return nil
    }

    /// Re-encodes a diagnostic so it can be sent back with a code-action request.
    static func diagnosticJSON(_ diagnostic: LSPDiagnostic) -> [String: Any] {
        var json: [String: Any] = [
            "range": [
                "start": ["line": diagnostic.range.start.line,
                          "character": diagnostic.range.start.character],
                "end": ["line": diagnostic.range.end.line,
                        "character": diagnostic.range.end.character]
            ],
            "severity": diagnostic.severity.rawValue,
            "message": diagnostic.message,
            "source": "clang"
        ]
        if let code = diagnostic.code { json["code"] = code }
        return json
    }

    /// Builds a code action, keeping the first workspace edit it carries.
    static func codeAction(from json: [String: Any]) -> LSPCodeAction? {
        guard let title = json["title"] as? String else { return nil }
        guard let edit = json["edit"] as? [String: Any] else {
            return LSPCodeAction(title: title, newText: nil, range: nil)
        }
        // Either a WorkspaceEdit with `changes`, or a documentChanges array.
        if let changes = edit["changes"] as? [String: [[String: Any]]],
           let first = changes.values.first?.first,
           let newText = first["newText"] as? String {
            return LSPCodeAction(title: title, newText: newText, range: range(from: first["range"]))
        }
        if let documentChanges = edit["documentChanges"] as? [[String: Any]],
           let first = documentChanges.first,
           let edits = first["edits"] as? [[String: Any]],
           let edit0 = edits.first,
           let newText = edit0["newText"] as? String {
            return LSPCodeAction(title: title, newText: newText, range: range(from: edit0["range"]))
        }
        return LSPCodeAction(title: title, newText: nil, range: nil)
    }


}

/// One completion entry as returned by clangd.
public struct LSPCompletionItem: Sendable, Equatable {
    public let label: String
    /// Text to insert; may contain snippet placeholders (`${1:name}`).
    public let insertText: String
    public let detail: String?
    public let documentation: String?
    /// LSP `CompletionItemKind` (3 = function, 6 = variable, 22 = struct, …).
    public let kindCode: Int
    /// Sort text chosen by the server's own ranking.
    public let sortText: String?

    public init(label: String, insertText: String, detail: String?,
                documentation: String?, kindCode: Int, sortText: String?) {
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.documentation = documentation
        self.kindCode = kindCode
        self.sortText = sortText
    }

    /// Parses either a `CompletionList` or a bare array, as LSP permits both.
    public static func parse(_ value: Any) -> [LSPCompletionItem] {
        let rawItems: [[String: Any]]
        if let list = value as? [String: Any], let items = list["items"] as? [[String: Any]] {
            rawItems = items
        } else if let items = value as? [[String: Any]] {
            rawItems = items
        } else {
            return []
        }
        return rawItems.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let text = (item["textEdit"] as? [String: Any])?["newText"] as? String
                ?? item["insertText"] as? String
                ?? label
            let documentation: String?
            if let text = item["documentation"] as? String {
                documentation = text
            } else if let markup = item["documentation"] as? [String: Any] {
                documentation = markup["value"] as? String
            } else {
                documentation = nil
            }
            return LSPCompletionItem(label: label,
                                     insertText: text,
                                     detail: item["detail"] as? String,
                                     documentation: documentation,
                                     kindCode: item["kind"] as? Int ?? 0,
                                     sortText: item["sortText"] as? String)
        }
    }
}
// MARK: - Protocol payloads

/// A 0-based position in a document.
public struct LSPPosition: Sendable, Equatable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// A half-open range in a document.
public struct LSPRange: Sendable, Equatable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// One diagnostic as published by clangd.
///
/// `code` is a stable identifier (`no_member`, `undeclared_var_use`, …), which is
/// what makes it possible to act on a problem beyond echoing its message.
public struct LSPDiagnostic: Sendable, Equatable {
    public enum Severity: Int, Sendable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }

    public let range: LSPRange
    public let severity: Severity
    public let message: String
    public let code: String?
    /// True when the server can offer an automatic fix.
    public let hasFix: Bool

    public init(range: LSPRange, severity: Severity, message: String, code: String?, hasFix: Bool) {
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
        self.hasFix = hasFix
    }

    init?(json: [String: Any]) {
        guard let rangeJSON = json["range"] as? [String: Any],
              let startJSON = rangeJSON["start"] as? [String: Any],
              let endJSON = rangeJSON["end"] as? [String: Any],
              let startLine = startJSON["line"] as? Int,
              let startChar = startJSON["character"] as? Int,
              let endLine = endJSON["line"] as? Int,
              let endChar = endJSON["character"] as? Int,
              let message = json["message"] as? String else { return nil }
        self.range = LSPRange(
            start: LSPPosition(line: startLine, character: startChar),
            end: LSPPosition(line: endLine, character: endChar)
        )
        self.severity = Severity(rawValue: json["severity"] as? Int ?? 3) ?? .information
        self.message = message
        // `code` may arrive as a string or a number.
        if let text = json["code"] as? String {
            self.code = text
        } else if let number = json["code"] as? Int {
            self.code = String(number)
        } else {
            self.code = nil
        }
        self.hasFix = (json["data"] as? [String: Any]).map { !$0.isEmpty } ?? false
    }
}

/// A quick fix the server can apply.
public struct LSPCodeAction: Sendable, Equatable {
    public let title: String
    public let newText: String?
    public let range: LSPRange?

    public init(title: String, newText: String?, range: LSPRange?) {
        self.title = title
        self.newText = newText
        self.range = range
    }
}

/// A location the server can navigate to.
public struct LSPLocation: Sendable, Equatable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

