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
    /// Diagnostics pushed by the server for a file.
    ///
    /// clangd publishes these after every parse (debounced internally), which is
    /// what makes live error checking possible without compiling.
    ///
    /// The third argument is the document text the diagnostics were computed from.
    /// clangd echoes the `version` it analysed, so the text can be looked up exactly
    /// instead of assuming it is the same as the current buffer — while the user
    /// types, the two differ by an edit or more, and placing the ranges against the
    /// newer text is what makes a squiggle land on the wrong token.
    public var onDiagnostics: ((String, [LSPDiagnostic], String) -> Void)? {
        didSet {
            // Replay the most recent result: a subscriber set after the first
            // publish (common: the editor attaches after the server starts) must
            // not miss the diagnostics that already arrived.
            lock.lock()
            let snapshot = latestDiagnostics
            lock.unlock()
            if let snapshot {
                DispatchQueue.main.async { [weak self] in
                    self?.onDiagnostics?(snapshot.uri, snapshot.items, snapshot.text)
                }
            }
        }
    }

    /// Last diagnostics per URI, kept for late subscribers.
    private var latestDiagnostics: (uri: String, items: [LSPDiagnostic], text: String)?

    /// Text of each version sent to the server, so a publish can be matched to the
    /// exact bytes it describes. Bounded: only the last few versions can still be
    /// in flight, and keeping them forever would leak a copy of every document.
    private var versionedTexts: [String: [Int: String]] = [:]

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

    /// Language standard handed to clangd as its fallback.
    ///
    /// clangd guesses C++14 when no compile flags are known, so every C++17
    /// construct (`auto [a, b] = …`, `std::optional`, structured bindings) was
    /// reported as an error on code that compiles perfectly. The editor builds
    /// with `-std=c++17`, so diagnostics must use the same language.
    private let standard: String
    /// Extra fallback flags (include paths) handed to clangd.
    private let fallbackFlags: [String]

    public init?(workingDirectory: URL, standard: String = "c++17",
                 extraIncludePaths: [String] = []) {
        guard let found = ClangdSession.findClangd() else { return nil }
        self.executable = found
        self.workingDirectory = workingDirectory
        self.standard = standard
        var flags = ["-std=\(standard)"]
        flags.append(contentsOf: extraIncludePaths.flatMap { ["-I", $0] })
        self.fallbackFlags = flags
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

    /// Writes a `bits/stdc++.h` shim and returns the directory holding it.
    ///
    /// `<bits/stdc++.h>` is a GCC convenience header that Apple's toolchain does
    /// not ship. Almost every competitive-programming template starts with it, and
    /// without a replacement clangd reports *every* use of `std` as undeclared —
    /// the single loudest source of false errors. The shim is generated (not
    /// bundled) so it is also available in tests and self-test runs.
    ///
    /// Returns `nil` when the directory cannot be written, in which case clangd
    /// simply keeps its normal behaviour.
    public static func prepareCompatibilityHeaders(
        in base: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let root = base.appendingPathComponent("RideCPP-clangd-include", isDirectory: true)
        let bits = root.appendingPathComponent("bits", isDirectory: true)
        let header = bits.appendingPathComponent("stdc++.h")
        do {
            try FileManager.default.createDirectory(at: bits, withIntermediateDirectories: true)
            try compatibilityHeader.write(to: header, atomically: true, encoding: .utf8)
            return root.path
        } catch {
            return nil
        }
    }

    /// Contents of the generated `bits/stdc++.h`.
    ///
    /// Only standard headers are listed, so this compiles against libc++ exactly
    /// like the GCC header does against libstdc++.
    static let compatibilityHeader = """
    // Generated by RideCPP. Stands in for GCC's <bits/stdc++.h>, which the
    // Apple toolchain does not ship. Only standard headers are included.
    #pragma once
    #include <algorithm>
    #include <array>
    #include <bitset>
    #include <cassert>
    #include <cctype>
    #include <cerrno>
    #include <cfloat>
    #include <climits>
    #include <cmath>
    #include <complex>
    #include <cstdarg>
    #include <cstddef>
    #include <cstdint>
    #include <cstdio>
    #include <cstdlib>
    #include <cstring>
    #include <ctime>
    #include <deque>
    #include <exception>
    #include <fstream>
    #include <functional>
    #include <iomanip>
    #include <ios>
    #include <iosfwd>
    #include <iostream>
    #include <istream>
    #include <iterator>
    #include <limits>
    #include <list>
    #include <map>
    #include <memory>
    #include <numeric>
    #include <ostream>
    #include <queue>
    #include <set>
    #include <sstream>
    #include <stack>
    #include <stdexcept>
    #include <streambuf>
    #include <string>
    #include <tuple>
    #include <type_traits>
    #include <unordered_map>
    #include <unordered_set>
    #include <utility>
    #include <valarray>
    #include <vector>

    """

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
                    "synchronization": ["didSave": false],
                    "publishDiagnostics": ["versionSupport": true],
                    // Declared so the server knows argument hints are wanted and
                    // formats them for a text client rather than an editor that
                    // renders its own markup.
                    "signatureHelp": [
                        "signatureInformation": [
                            "parameterInformation": ["labelOffsetSupport": false]
                        ]
                    ],
                    // Without this clangd answers code-action requests in the old
                    // `Command` form (`clangd.applyFix` carrying the edit in its
                    // arguments) instead of returning an `edit`, so the client
                    // sees actions it cannot apply. Declaring literal support is
                    // what makes quick fixes usable.
                    "codeAction": [
                        "codeActionLiteralSupport": [
                            "codeActionKind": [
                                "valueSet": ["quickfix", "refactor", "source"]
                            ]
                        ]
                    ]
                ]
            ],
            // Without these clangd falls back to C++14 and to a bare include path,
            // which makes valid code look broken: C++17 syntax is rejected and
            // `bits/stdc++.h` (absent from Apple's toolchain) is not found.
            "initializationOptions": ["fallbackFlags": fallbackFlags]
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
                let version = self.versions[uri] ?? 1
                self.remember(text: text, uri: uri, version: version)
                self.sendNotification(method: "textDocument/didChange", params: [
                    "textDocument": ["uri": uri, "version": version],
                    "contentChanges": [["text": text]]
                ])
            } else {
                self.openDocuments.insert(uri)
                self.versions[uri] = 1
                self.remember(text: text, uri: uri, version: 1)
                self.sendNotification(method: "textDocument/didOpen", params: [
                    "textDocument": ["uri": uri,
                                     "languageId": languageID,
                                     "version": 1,
                                     "text": text]
                ])
            }
        }
    }

    /// Records the text of one document version, dropping versions that can no
    /// longer be in flight.
    private func remember(text: String, uri: String, version: Int) {
        var history = versionedTexts[uri] ?? [:]
        history[version] = text
        // clangd answers the newest version it has parsed; older ones only matter
        // while a publish is still in transit. Four is comfortably more than the
        // debounce window, and keeps memory bounded to a few copies per file.
        if history.count > 4 {
            for key in history.keys.sorted().dropLast(4) {
                history.removeValue(forKey: key)
            }
        }
        versionedTexts[uri] = history
    }

    /// The text a `publishDiagnostics` refers to.
    ///
    /// Prefers the exact version clangd reports. When the field is absent (an
    /// older server) the newest recorded text is the best available guess.
    private func text(for uri: String, version: Int?) -> String? {
        guard let history = versionedTexts[uri] else { return nil }
        if let version, let exact = history[version] { return exact }
        return history[history.keys.max() ?? 0]
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

    // MARK: - Signature help

    /// Asks what arguments a call at `position` takes.
    ///
    /// clangd answers with the whole signature list plus which parameter the
    /// caret is inside, which is what lets the editor highlight the argument
    /// being typed instead of dumping the full prototype and leaving the user to
    /// count commas.
    public func requestSignatureHelp(uri: String,
                                     position: LSPPosition,
                                     completion: @escaping ([LSPSignature]) -> Void) {
        sendRequest(method: "textDocument/signatureHelp", params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ]) { result in
            guard case .success(let value) = result,
                  let object = value as? [String: Any],
                  let raw = object["signatures"] as? [[String: Any]] else {
                completion([])
                return
            }
            let active = object["activeParameter"] as? Int ?? 0
            let activeSignature = object["activeSignature"] as? Int ?? 0
            let signatures = raw.compactMap(Self.signature(from:))
            guard !signatures.isEmpty else {
                completion([])
                return
            }
            // The server names the active signature; fall back to the first.
            let chosen = signatures.indices.contains(activeSignature) ? activeSignature : 0
            completion([signatures[chosen]])
        }
    }

    static func signature(from json: [String: Any]) -> LSPSignature? {
        guard let label = json["label"] as? String else { return nil }
        let rawParameters = json["parameters"] as? [[String: Any]] ?? []
        let parameters: [LSPSignature.Parameter] = rawParameters.compactMap { entry in
            guard let text = entry["label"] as? String else { return nil }
            // Plain-string parameter labels are what clangd sends; the array form
            // would need offsets into the label, which is not worth supporting.
            return LSPSignature.Parameter(label: text)
        }
        return LSPSignature(label: label, parameters: parameters)
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
            // Match the publish to the exact text it describes. clangd echoes the
            // version it parsed; without it a squiggle drawn on a newer buffer
            // lands on whatever token happens to occupy those offsets now.
            let text = text(for: uri, version: params["version"] as? Int) ?? ""
            lock.lock()
            latestDiagnostics = (uri, diagnostics, text)
            let handler = onDiagnostics
            lock.unlock()
            DispatchQueue.main.async { handler?(uri, diagnostics, text) }
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
        let kind = json["kind"] as? String
        let preferred = json["isPreferred"] as? Bool ?? false
        guard let edit = json["edit"] as? [String: Any] else {
            return LSPCodeAction(title: title, newText: nil, range: nil,
                                 kind: kind, isPreferred: preferred)
        }
        // Either a WorkspaceEdit with `changes`, or a documentChanges array.
        if let changes = edit["changes"] as? [String: [[String: Any]]],
           let first = changes.values.first?.first,
           let newText = first["newText"] as? String {
            return LSPCodeAction(title: title, newText: newText,
                                 range: range(from: first["range"]),
                                 kind: kind, isPreferred: preferred)
        }
        if let documentChanges = edit["documentChanges"] as? [[String: Any]],
           let first = documentChanges.first,
           let edits = first["edits"] as? [[String: Any]],
           let edit0 = edits.first,
           let newText = edit0["newText"] as? String {
            return LSPCodeAction(title: title, newText: newText,
                                 range: range(from: edit0["range"]),
                                 kind: kind, isPreferred: preferred)
        }
        return LSPCodeAction(title: title, newText: nil, range: nil,
                             kind: kind, isPreferred: preferred)
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
///
/// Only actions that carry a concrete, applicable edit are exposed: clangd also
/// returns refactorings that are *commands* (`clangd.applyTweak`) rather than
/// edits, and offering those in a menu would give the user items that do nothing.
public struct LSPCodeAction: Sendable, Equatable {
    public let title: String
    public let newText: String?
    public let range: LSPRange?
    /// `quickfix`, `refactor`, … — clangd only marks genuine fixes as `quickfix`.
    public let kind: String?
    /// True for the fix clangd recommends when several are offered.
    public let isPreferred: Bool

    public init(title: String, newText: String?, range: LSPRange?,
                kind: String? = nil, isPreferred: Bool = false) {
        self.title = title
        self.newText = newText
        self.range = range
        self.kind = kind
        self.isPreferred = isPreferred
    }

    /// Whether this action can actually be applied to the buffer.
    public var isApplicable: Bool { newText != nil && range != nil }
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

/// One overload of a callable, as reported by `textDocument/signatureHelp`.
public struct LSPSignature: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public let label: String

        public init(label: String) {
            self.label = label
        }
    }

    /// Full prototype, e.g. `push_back(const value_type &value)`.
    public let label: String
    public let parameters: [Parameter]

    public init(label: String, parameters: [Parameter]) {
        self.label = label
        self.parameters = parameters
    }
}
