import Foundation

/// The C++ keywords the active compiler accepts.
///
/// The set is not hand-maintained and not guessed: every candidate is verified by
/// one compiler invocation (see `probe`), and the result is cached both in memory
/// and on disk. Compiling once with `-ferror-limit=0` and putting each candidate
/// on its own line makes a single ~25 ms run classify all of them.
///
/// Crucially, this never runs on the main thread during typing: `prepare` does the
/// work in the background, and `keywords()` returns the last good result (or the
/// part of speech that is safe to assume) until it is ready.
public enum KeywordTable {

    /// Candidate spellings covering C++20 plus the TS keywords compilers accept.
    static let candidates = [
        "alignas", "alignof", "and", "and_eq", "asm", "atomic_cancel", "atomic_commit",
        "atomic_noexcept", "auto", "bitand", "bitor", "bool", "break", "case", "catch",
        "char", "char8_t", "char16_t", "char32_t", "class", "compl", "concept", "const",
        "consteval", "constexpr", "constinit", "const_cast", "continue", "co_await",
        "co_return", "co_yield", "decltype", "default", "delete", "do", "double",
        "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false", "float",
        "for", "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace",
        "new", "noexcept", "not", "not_eq", "nullptr", "operator", "or", "or_eq",
        "private", "protected", "public", "reflexpr", "register", "reinterpret_cast",
        "requires", "return", "short", "signed", "sizeof", "static", "static_assert",
        "static_cast", "struct", "switch", "synchronized", "template", "this",
        "thread_local", "throw", "true", "try", "typedef", "typeid", "typename",
        "union", "unsigned", "using", "virtual", "void", "volatile", "wchar_t", "while",
        "xor", "xor_eq"
    ]

    /// Words that cannot appear in `int <word> = 0;` for grammar reasons, so the
    /// probe cannot classify them by compiling: they are part of a declaration.
    private static let structurallyInvalidAsIdentifier = [
        "atomic_cancel", "atomic_commit", "atomic_noexcept", "reflexpr", "synchronized"
    ]

    /// Last verified set. Reads are lock-protected; the value is replaced whole.
    private static var current: [String] = fallback
    private static var preparing = false
    private static let lock = NSLock()

    /// Used until the compiler has been asked. These are unambiguous C++ keywords
    /// (not TS-only spellings), so suggestions are never wrong in the meantime.
    static let fallback: [String] = [
        "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor",
        "bool", "break", "case", "catch", "char", "char16_t", "char32_t", "class",
        "compl", "concept", "const", "consteval", "constexpr", "constinit",
        "const_cast", "continue", "decltype", "default", "delete", "do", "double",
        "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false",
        "float", "for", "friend", "goto", "if", "inline", "int", "long", "mutable",
        "namespace", "new", "noexcept", "not", "not_eq", "nullptr", "operator", "or",
        "or_eq", "private", "protected", "public", "register", "reinterpret_cast",
        "requires", "return", "short", "signed", "sizeof", "static", "static_assert",
        "static_cast", "struct", "switch", "template", "this", "thread_local", "throw",
        "true", "try", "typedef", "typeid", "typename", "union", "unsigned", "using",
        "virtual", "void", "volatile", "wchar_t", "while", "xor", "xor_eq"
    ]

    /// The current best-known keyword list. Never blocks.
    public static func keywords() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Verifies against `compilerPath` in the background, at most once.
    ///
    /// Safe to call from anywhere: it returns immediately, and a second call while
    /// the first is running does nothing.
    public static func prepare(compilerPath: String?) {
        lock.lock()
        let alreadyRunning = preparing
        preparing = true
        lock.unlock()
        guard !alreadyRunning else { return }

        let compiler = compilerPath ?? "/usr/bin/clang++"
        DispatchQueue.global(qos: .utility).async {
            let verified = loadCache(compiler: compiler) ?? verify(compiler: compiler)
            saveCache(verified, compiler: compiler)
            lock.lock()
            current = verified
            preparing = false
            lock.unlock()
        }
    }

    /// Synchronous verification, for tests.
    public static func buildSynchronously(compilerPath: String?) -> [String] {
        let compiler = compilerPath ?? "/usr/bin/clang++"
        if let cached = loadCache(compiler: compiler) {
            lock.lock()
            current = cached
            lock.unlock()
            return cached
        }
        let verified = verify(compiler: compiler)
        saveCache(verified, compiler: compiler)
        lock.lock()
        current = verified
        lock.unlock()
        return verified
    }

    /// Classifies every candidate with a single compiler run.
    ///
    /// `int <word> = 0;` compiles only when `<word>` is an ordinary identifier, so
    /// the line numbers the compiler rejects are exactly the keywords.
    static func verify(compiler: String) -> [String] {
        let candidatesToProbe = candidates.filter { !structurallyInvalidAsIdentifier.contains($0) }
        let translationUnit = candidatesToProbe.map { "int \($0) = 0;" }.joined(separator: "\n") + "\n"

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ridecpp-keywords-\(UUID().uuidString).cpp")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? translationUnit.write(to: file, atomically: true, encoding: .utf8)) != nil else {
            return fallback
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = ["-std=c++20", "-fsyntax-only", "-ferror-limit=0", file.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return fallback
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)

        // Collect the 1-based line numbers that failed.
        var failedLines = Set<Int>()
        for line in message.split(separator: "\n") {
            guard let range = line.range(of: #"cpp:(\d+):"#, options: .regularExpression) else { continue }
            let digits = line[range].dropFirst(4).dropLast(1)
            if let number = Int(digits) { failedLines.insert(number) }
        }
        guard !failedLines.isEmpty else { return fallback }

        var keywords = structurallyInvalidAsIdentifier
        for (offset, word) in candidatesToProbe.enumerated() where failedLines.contains(offset + 1) {
            keywords.append(word)
        }
        return keywords.sorted()
    }

    // MARK: - Disk cache

    /// Cache location, keyed by compiler path so switching toolchains re-verifies.
    static func cacheURL(compiler: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("RideCPP", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "keywords-" + compiler.replacingOccurrences(of: "/", with: "-") + ".txt"
        return directory.appendingPathComponent(name)
    }

    static func loadCache(compiler: String) -> [String]? {
        guard let url = cacheURL(compiler: compiler),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let words = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words
    }

    static func saveCache(_ keywords: [String], compiler: String) {
        guard let url = cacheURL(compiler: compiler) else { return }
        try? keywords.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
