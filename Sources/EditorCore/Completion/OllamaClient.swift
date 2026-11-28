import Foundation

/// Talks to a local Ollama server for inline code completion.
///
/// Why a local model instead of a cloud API: RideCPP is meant to work on a plane
/// and to keep the user's code on their machine. Ollama is already how people run
/// local models on macOS, so the editor drives it over its HTTP API rather than
/// bundling a runtime.
///
/// The model that actually fits is `qwen2.5-coder` — it is trained for
/// fill-in-the-middle, which is exactly "given what is before and after the
/// caret, what belongs here". Measured on this machine at ~0.1 s warm, versus
/// seconds for general chat models that try to *answer* instead of *continue*.
///
/// Everything here fails quietly. A completion that arrives late, or is wrong,
/// must never disturb typing.
public final class OllamaClient {

    /// What the caller asked for, resolved against what the server offers.
    public enum Availability: Equatable, Sendable {
        /// Ollama is not installed.
        case notInstalled
        /// Installed, but the server is not responding.
        case notRunning
        /// Running, but the model has not been pulled.
        case modelMissing(String)
        /// Ready to serve completions.
        case ready(String)
    }

    public struct Config: Sendable {
        public var host: String
        /// Model names in preference order; the first installed one wins when the
        /// user has not picked one.
        ///
        /// The 0.5b leads: at 397 MB it leaves the machine cool and answers in
        /// around a tenth of a second. The user can choose any installed model in
        /// settings; this list is only the default.
        public var preferredModels: [String]
        /// Hard ceiling for one suggestion. Past this the text is discarded.
        public var timeout: TimeInterval
        /// How many tokens a suggestion may contain.
        public var maximumTokens: Int

        public init(host: String = "http://127.0.0.1:11434",
                    preferredModels: [String] = OllamaClient.defaultModels,
                    timeout: TimeInterval = 4,
                    maximumTokens: Int = 32) {
            self.host = host
            self.preferredModels = preferredModels
            self.timeout = timeout
            self.maximumTokens = maximumTokens
        }
    }

    /// Default model when the user has not chosen one.
    ///
    /// 0.5b: the lightest option that still completes code, and the one that
    /// keeps the machine cool and quiet. Larger models are available in settings.
    public static let defaultModels = [
        "qwen2.5-coder:0.5b",
        "qwen2.5-coder:1.5b"
    ]

    public var config: Config
    private let session: URLSession
    /// Models the server reported, cached for the lifetime of one availability check.
    private var installedModels: [String] = []
    private let queue = DispatchQueue(label: "RideCPP.OllamaClient")

    public init(config: Config = Config()) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Availability

    /// Whether an executable named `ollama` can be found.
    ///
    /// Checked on disk rather than by running it: launching the CLI on every
    /// check would be a visible cost, and the app bundle paths are known.
    public static func isOllamaInstalled() -> Bool {
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        // Homebrew on Apple silicon, plus the app bundle the installer drops in.
        return FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
    }

    /// Models the server reported on the last availability check.
    ///
    /// Used to populate the model picker; empty until a check has run.
    public var availableModels: [String] {
        queue.sync { installedModels }
    }

    /// Asks the server which models it has.
    public func listModels(completion: @escaping (Result<[String], Error>) -> Void) {
        guard let url = URL(string: config.host + "/api/tags") else {
            completion(.failure(ClientError.badURL))
            return
        }
        session.dataTask(with: url) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]] else {
                completion(.failure(ClientError.badResponse))
                return
            }
            let names = models.compactMap { $0["name"] as? String }
            completion(.success(names))
        }.resume()
    }

    /// Resolves the best available state, in one round trip when possible.
    public func checkAvailability(completion: @escaping (Availability) -> Void) {
        listModels { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                completion(Self.isOllamaInstalled() ? .notRunning : .notInstalled)
            case .success(let names):
                self.queue.sync { self.installedModels = names }
                if let match = self.config.preferredModels.first(where: { preferred in
                    names.contains { $0 == preferred || $0.hasPrefix(preferred + ":") }
                }) ?? self.config.preferredModels.first(where: { names.contains($0) }) {
                    completion(.ready(match))
                } else {
                    completion(.modelMissing(self.config.preferredModels.first ?? "qwen2.5-coder:0.5b"))
                }
            }
        }
    }

    // MARK: - Completion

    /// Fill-in-the-middle prompt the coder models were trained on.
    static func prompt(prefix: String, suffix: String) -> String {
        "<|fim_prefix|>" + prefix + "<|fim_suffix|>" + suffix + "<|fim_middle|>"
    }

    /// Requests a continuation of `prefix` that runs up to `suffix`.
    ///
    /// Returns an empty string when there is nothing worth showing — no server, a
    /// timeout, a malformed answer. Callers treat "" as "no suggestion".
    public func complete(model: String,
                         prefix: String,
                         suffix: String,
                         completion: @escaping (String) -> Void) {
        guard let url = URL(string: config.host + "/api/generate") else {
            completion("")
            return
        }
        let body: [String: Any] = [
            "model": model,
            "prompt": Self.prompt(prefix: prefix, suffix: suffix),
            "raw": true,
            "stream": false,
            "options": [
                "num_predict": config.maximumTokens,
                // Greedy: a suggestion must be the same answer every time it is
                // asked, or the ghost text shifts while the user stares at it.
                "temperature": 0,
                "top_p": 1,
                // Enough to see the whole file for a typical algorithm solution.
                // A tiny window made the model lose the includes and the style,
                // and it answered in C with printf instead of this file's C++.
                "num_ctx": 2048,
                "stop": ["\n\n", "<|fim", "<|endoftext|>", "```"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion("")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The server must give up before the user has moved on.
        request.timeoutInterval = config.timeout

        let task = session.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["response"] as? String else {
                completion("")
                return
            }
            completion(Self.sanitize(raw, following: Self.trailingWord(in: prefix)))
        }
        task.resume()
    }

    /// The word being typed at the very end of `prefix`.
    static func trailingWord(in prefix: String) -> String {
        var word = ""
        for character in prefix.reversed() {
            if character.isLetter || character.isNumber || character == "_" {
                word = String(character) + word
            } else {
                break
            }
        }
        return word
    }

    /// Cleans a model continuation into something worth inserting.
    ///
    /// Small code models leak markdown fences and occasionally repeat the line
    /// they were continuing; both are stripped rather than shown.
    static func sanitize(_ raw: String, following typedWord: String = "") -> String {
        var text = raw
        for marker in ["```cpp", "```c++", "```c", "```"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        // The server terminates some answers with a carriage return; inserting it
        // turns the suggestion into a line break.
        text = text.replacingOccurrences(of: "\r", with: "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        // Small models pad their output with spaces. The ones C++ requires are
        // re-added below, so none is carried over blindly.
        text = String(text.drop { $0 == " " || $0 == "\t" })

        // A leading newline means "continue on the next line", which is a normal
        // thing for the model to say: after `int n;` it wants to start a new
        // statement. That is kept as a multi-line suggestion rather than being
        // trimmed into a bogus continuation of the current line.
        var opensNewLine = false
        while text.hasPrefix("\n") || text.hasPrefix("\r") {
            text.removeFirst()
            opensNewLine = true
        }
        guard !text.isEmpty else { return "" }

        if !opensNewLine {
            // The continuation must extend what the user is typing rather than
            // replace it. A model answering `wh` with `cout << n << endl;` would
            // corrupt the line if inserted.
            // The model often repeats the part already typed (`fo` → `for (…`).
            // Sending that through would insert `fofor`, so the overlap is removed.
            let typedLower = typedWord.trimmingCharacters(in: .whitespaces).lowercased()
            if !typedLower.isEmpty {
                let head = String(text.prefix(typedLower.count)).lowercased()
                if head == typedLower, text.count > typedLower.count {
                    text = String(text.dropFirst(typedLower.count))
                    text = String(text.drop { $0 == " " })
                    guard !text.isEmpty else { return "" }
                }
            }
            guard continuesLine(text, typedWord: typedWord) else { return "" }
            // `for` needs a space before its parenthesis, and `cin` before `>>`.
            // The model's own padding was stripped above, so it is restored
            // deliberately, once, where C++ requires it.
            let needsSpace = text.hasPrefix("(") || text.hasPrefix(">>")
                || text.hasPrefix("<<") || text.hasPrefix("{")
            if needsSpace {
                text = " " + text
            }
            let lines = text.components(separatedBy: "\n")
            let first = lines[0]
            guard !first.isEmpty else { return "" }
            // A continuation that opens a block reads better with the body's first
            // line; anything longer starts to cover the code beneath.
            if first.contains("{"), !first.contains("}"), lines.count > 1 {
                let body = lines[1]
                if !body.trimmingCharacters(in: .whitespaces).isEmpty {
                    return first + "\n" + body
                }
            }
            return first
        }

        // Starting a new line: keep the statement and, when it opens a block, its
        // first body line. More than that covers the code underneath.
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let firstLine = lines.first else { return "" }
        if firstLine.contains("{"), !firstLine.contains("}"), lines.count > 1 {
            let next = lines[1]
            if !next.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\n" + firstLine + "\n" + next
            }
        }
        return "\n" + firstLine
    }

    /// Whether `text` continues the line the user is typing.
    ///
    /// Two shapes are a continuation: punctuation that extends the expression
    /// (`(a.begin(), ` → `a.end())`), or the rest of the identifier being typed
    /// (`vec` → `tor<int>`). A different word is a new statement and is rejected.
    static func continuesLine(_ text: String, typedWord: String) -> Bool {
        let typed = typedWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return true }

        // Punctuation that extends the expression being typed.
        let continuationSymbols: Set<Character> = ["(", " ", "<", ".", "[", ">", ";", "{",
                                                   ":", ",", "=", "+", "-", "*", "/", "%",
                                                   "!", "&", "|", "?", ")", "}"]
        // One leading space is meaningful (`for` + ` (int i…`); several, or a space
        // in front of a word fragment, is the model formatting rather than
        // continuing — inserting it would give `f  or (int i…`.
        if text.hasPrefix("  ") { return false }
        if let first = text.first, continuationSymbols.contains(first) {
            // A space introduces punctuation or an operator, not a word fragment.
            if first == " " {
                let afterSpace = text.dropFirst().first
                return afterSpace.map { continuationSymbols.contains($0) || $0 == ">" } ?? false
            }
            return true
        }

        // The model is spelling out the rest of a word. Accept only when the two
        // halves join into a keyword or identifier the language knows — `w` +
        // `hile` = `while`, `vec` + `tor` = `vector`. `wh` + `cout` joins into
        // nothing, so it is a different statement rather than a continuation.
        let chunk = String(text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }).lowercased()
        guard !chunk.isEmpty else { return false }
        // Either the model spells out the rest of the word (`wh` + `ile`), or it
        // repeats the whole word and continues (`wh` → `while (cin >> n) {`).
        // Repeating the word already typed would produce `sortsort`, so a chunk
        // identical to what is there is not a continuation.
        guard chunk != typed else { return false }
        return knownWords.contains(typed + chunk) || chunk.hasPrefix(typed)
    }

    /// Words a C++ file plausibly begins with, used to recognise a continuation
    /// that completes the identifier being typed.
    static let knownWords: Set<String> = [
        "while", "for", "if", "else", "return", "break", "continue", "switch", "case",
        "default", "do", "sizeof", "struct", "class", "namespace", "using", "typedef",
        "template", "typename", "public", "private", "protected", "const", "static",
        "inline", "virtual", "operator", "new", "delete", "this", "nullptr",
        "vector", "string", "map", "set", "queue", "stack", "deque", "pair", "tuple",
        "priority_queue", "unordered_map", "unordered_set", "list", "array", "bitset",
        "cout", "cin", "cerr", "endl", "printf", "scanf", "sort", "reverse", "max",
        "min", "abs", "swap", "fill", "count", "find", "lower_bound", "upper_bound",
        "push_back", "pop_back", "push", "pop", "top", "front", "back", "size",
        "empty", "clear", "insert", "erase", "begin", "end", "resize", "assign",
        "accumulate", "to_string", "stoi", "stoll", "memset", "memcpy", "strlen",
        "int", "long", "double", "float", "char", "bool", "void", "auto", "signed",
        "unsigned", "short", "main", "true", "false", "include", "define"
    ]

    // MARK: - Pulling a model

    /// Progress of a model download.
    public struct PullProgress: Equatable, Sendable {
        /// 0...1, or nil while the server is resolving the manifest.
        public let fraction: Double?
        /// Human-readable server status, e.g. "pulling 20693aeb02c6".
        public let status: String
        public let completedBytes: Int64
        public let totalBytes: Int64
    }

    /// Downloads a model through the running server.
    ///
    /// Doing this in-app matters: telling a user to open a terminal and type
    /// `ollama pull` is where most people stop. The server streams newline-
    /// delimited JSON, which is parsed as it arrives so the UI can show real
    /// progress rather than a spinner of unknown length.
    @discardableResult
    public func pull(model: String,
                     progress: @escaping (PullProgress) -> Void,
                     completion: @escaping (Result<Void, Error>) -> Void) -> PullTask? {
        guard let url = URL(string: config.host + "/api/pull") else {
            completion(.failure(ClientError.badURL))
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        // A download is not a completion: no short timeout.
        request.timeoutInterval = 60 * 60

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60 * 60
        let task = PullTask(progress: progress, completion: completion)
        let delegate = PullDelegate(task: task)
        let inner = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task.session = inner
        task.dataTask = inner.dataTask(with: request)
        task.dataTask?.resume()
        return task
    }

    /// One in-flight model download.
    ///
    /// A plain `dataTask` completion handler fires only once the *whole* response
    /// has arrived, which would leave the progress bar blank for a 400 MB pull.
    /// The bytes are therefore read through a session delegate as they stream in.
    public final class PullTask {
        let progress: (PullProgress) -> Void
        let completion: (Result<Void, Error>) -> Void
        fileprivate var session: URLSession?
        fileprivate var dataTask: URLSessionDataTask?
        private let lock = NSLock()
        private var finished = false

        init(progress: @escaping (PullProgress) -> Void,
             completion: @escaping (Result<Void, Error>) -> Void) {
            self.progress = progress
            self.completion = completion
        }

        public func cancel() {
            dataTask?.cancel()
            finish(.failure(PullFailure(message: "cancelled")))
        }

        fileprivate func finish(_ result: Result<Void, Error>) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            completion(result)
            session?.invalidateAndCancel()
        }

        fileprivate func handle(line: Data) {
            lock.lock()
            let done = finished
            lock.unlock()
            guard !done else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let message = object["error"] as? String {
                finish(.failure(PullFailure(message: message)))
                return
            }
            let status = object["status"] as? String ?? ""
            let total = (object["total"] as? NSNumber)?.int64Value ?? 0
            let completed = (object["completed"] as? NSNumber)?.int64Value ?? 0
            progress(PullProgress(fraction: total > 0 ? Double(completed) / Double(total) : nil,
                                  status: status,
                                  completedBytes: completed,
                                  totalBytes: total))
            if status == "success" {
                finish(.success(()))
            }
        }
    }

    /// Streams newline-delimited JSON out of the pull response.
    private final class PullDelegate: NSObject, URLSessionDataDelegate {
        private let task: PullTask
        private var pending = Data()

        init(task: PullTask) {
            self.task = task
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { task.handle(line: line) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                self.task.finish(.failure(error))
            } else if !pending.isEmpty {
                self.task.handle(line: pending)
            }
        }
    }

    public struct PullFailure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public enum ClientError: Error {
        case badURL
        case badResponse
    }
}
