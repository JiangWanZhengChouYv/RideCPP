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
        // Responses carry an id; notifications (diagnostics) do not and are ignored.
        guard let id = message["id"] as? Int else { return }
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
