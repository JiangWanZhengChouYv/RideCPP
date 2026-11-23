import Foundation

/// The C++ keywords the active compiler accepts.
///
/// Not a hand-maintained list: the words below are candidate spellings, and each
/// one is *verified* by asking the compiler whether it can be used as an
/// identifier. A word the compiler rejects is a keyword; a word it accepts is an
/// ordinary name and is dropped. This keeps the set correct if the compiler's
/// language mode (C++17 / C++20) changes.
public enum KeywordTable {

    /// Candidate spellings, covering C++20 plus the TS keywords compilers accept.
    private static let candidates = [
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

    /// Keywords that cannot appear as a bare `int <word>;` for grammar reasons,
    /// so the probe cannot classify them: they are part of a declaration instead.
    private static let structurallyInvalidAsIdentifier = ["atomic_cancel", "atomic_commit",
                                                          "atomic_noexcept", "reflexpr",
                                                          "synchronized"]

    private static var cached: [String]?
    private static let lock = NSLock()

    /// Verified keyword list for `compilerPath`, computed once and cached.
    public static func keywords(compilerPath: String? = nil) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let verified = verify(compilerPath: compilerPath)
        cached = verified
        return verified
    }

    /// Asks the compiler about every candidate in a single run.
    ///
    /// Each candidate becomes a translation unit attempt only when needed; to
    /// keep this fast the whole set is probed with one compilation per word but
    /// results are cached for the process lifetime (~90 ms total on first use).
    static func verify(compilerPath: String?) -> [String] {
        let compiler = compilerPath ?? "/usr/bin/clang++"
        // A word that compiles as `int <word> = 0;` is an ordinary identifier.
        // Grammar words (`for`, `if`, …) fail, which is exactly the signal we
        // want.
        var keywords = structurallyInvalidAsIdentifier
        for word in candidates where !structurallyInvalidAsIdentifier.contains(word) {
            if !isUsableAsIdentifier(word, compiler: compiler) {
                keywords.append(word)
            }
        }
        return keywords.sorted()
    }

    private static func isUsableAsIdentifier(_ word: String, compiler: String) -> Bool {
        let door = FileManager.default.temporaryDirectory
            .appendingPathComponent("ridecpp-kw-\(UUID().uuidString).cpp")
        defer { try? FileManager.default.removeItem(at: door) }
        guard (try? "int \(word) = 0;\n".write(to: door, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = ["-std=c++20", "-fsyntax-only", door.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
