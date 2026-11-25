import Foundation

/// What kind of thing a suggestion refers to. Drives the leading badge in the
/// completion list and the ranking.
public enum SymbolKind: String, Sendable, Equatable {
    /// A language keyword (`if`, `const`, …).
    case keyword
    /// Something declared by a header: functions, types, standard names.
    case header
    /// A name the user declared in a file: function, struct, class, variable.
    case userDefined
}

/// One symbol the editor remembers from files it has opened.
public struct RememberedSymbol: Equatable, Sendable {
    public let name: String
    public let kind: SymbolKind
    /// How many times the name has been written, used as the ranking weight.
    public let uses: Int
    /// Last time it was seen, so recently used names can win ties.
    public let lastSeen: Date

    public init(name: String, kind: SymbolKind, uses: Int, lastSeen: Date) {
        self.name = name
        self.kind = kind
        self.uses = uses
        self.lastSeen = lastSeen
    }
}

/// Remembers names the user declared, so they come back across files and sessions.
///
/// Only names the user actually wrote are stored: functions, structs, classes and
/// variables. Language keywords and standard library names are **not** stored —
/// they are already known from the compiler and the headers — so the store stays
/// small (a few hundred entries, single-digit KB).
///
/// Storage is a small JSON file in Application Support, written at most every few
/// seconds rather than on every keystroke.
public final class UserSymbolStore {

    /// Shared store used by the editor.
    public static let shared = UserSymbolStore()

    /// Recorded symbols keyed by name.
    private var symbols: [String: RememberedSymbol] = [:]
    /// Cached prefix lookups, invalidated whenever a symbol is added.
    private var prefixCache: [String: [(String, SymbolKind)]] = [:]
    private let lock = NSLock()
    private var dirty = false
    private var flushScheduled = false
    /// Names remembered from the current document session, used to rank them up.
    private var sessionNames: Set<String> = []

    /// Hard caps so the store can never grow without bound.
    static let maximumSymbols = 2000

    public init() {}

    // MARK: - Recording

    /// Records the identifiers declared in a document.
    ///
    /// Called when a file is opened and when a build starts (a natural point where
    /// the document is saved), not on every keystroke.
    public func remember(declarationsIn document: String) {
        let declarations = Self.parseDeclarations(in: document)
        guard !declarations.isEmpty else { return }
        let now = Date()
        lock.lock()
        for (name, kind) in declarations {
            if let existing = symbols[name] {
                symbols[name] = RememberedSymbol(name: existing.name,
                                                 kind: kind == .userDefined ? kind : existing.kind,
                                                 uses: min(existing.uses + 1, 999),
                                                 lastSeen: now)
            } else {
                symbols[name] = RememberedSymbol(name: name, kind: kind, uses: 1, lastSeen: now)
            }
            sessionNames.insert(name)
        }
        pruneIfNeededLocked()
        prefixCache.removeAll()
        dirty = true
        let needsFlush = !flushScheduled
        if needsFlush { flushScheduled = true }
        lock.unlock()
        if needsFlush { scheduleFlush() }
    }

    /// Names seen in this session, ranked before older ones.
    public func isSessionName(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionNames.contains(name)
    }

    /// Symbols starting with `prefix`, best first.
    ///
    /// Entries used more often and seen more recently sort first, which is what
    /// makes "remembered names" feel personal rather than alphabetical.
    public func symbols(withPrefix prefix: String, limit: Int = 30) -> [RememberedSymbol] {
        guard !prefix.isEmpty else { return [] }
        let lowered = prefix.lowercased()
        lock.lock()
        if let cached = prefixCache[lowered] {
            lock.unlock()
            return cached.compactMap { name, _ in symbols[name] }
        }
        let matches = symbols.values
            .filter { $0.name.lowercased().hasPrefix(lowered) }
            .sorted { lhs, rhs in
                if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
                return lhs.lastSeen > rhs.lastSeen
            }
            .prefix(limit)
        let snapshot = Array(matches)
        prefixCache[lowered] = snapshot.map { ($0.name, $0.kind) }
        lock.unlock()
        return snapshot
    }

    /// Number of remembered symbols (diagnostics/tests).
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return symbols.count
    }

    /// Replaces the entire store, used by tests and by `load()`.
    public func replaceAll(_ entries: [RememberedSymbol]) {
        lock.lock()
        symbols = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        // The cap must hold for restored data too, not only for fresh recordings:
        // an old or hand-edited file could otherwise exceed it.
        pruneIfNeededLocked()
        prefixCache.removeAll()
        lock.unlock()
    }

    public func allSymbols() -> [RememberedSymbol] {
        lock.lock()
        defer { lock.unlock() }
        return Array(symbols.values)
    }

    // MARK: - Persistence

    private struct StoredSymbol: Codable {
        let name: String
        let kind: String
        let uses: Int
        let lastSeen: Date
    }

    private static var storeURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("RideCPP", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("symbols.json")
    }

    /// Loads the store from disk. Called once at launch, off the main thread.
    public func load() {
        guard let url = Self.storeURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredSymbol].self, from: data) else { return }
        var loaded: [String: RememberedSymbol] = [:]
        for entry in stored {
            let kind = SymbolKind(rawValue: entry.kind) ?? .userDefined
            loaded[entry.name] = RememberedSymbol(name: entry.name, kind: kind,
                                                  uses: entry.uses, lastSeen: entry.lastSeen)
        }
        lock.lock()
        symbols.merge(loaded) { existing, incoming in
            existing.uses >= incoming.uses ? existing : incoming
        }
        prefixCache.removeAll()
        lock.unlock()
    }

    /// Writes the store out. Called on a background queue.
    public func flush() {
        guard let url = Self.storeURL else { return }
        lock.lock()
        let snapshot = symbols.values.map {
            StoredSymbol(name: $0.name, kind: $0.kind.rawValue, uses: $0.uses, lastSeen: $0.lastSeen)
        }
        dirty = false
        flushScheduled = false
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func scheduleFlush() {
        // Coalesce writes: remembering happens per build, and serialising 2k tiny
        // records is cheap, but doing it per keystroke would not be.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let needsWrite = self.dirty
            self.lock.unlock()
            if needsWrite { self.flush() }
        }
    }

    private func pruneIfNeededLocked() {
        guard symbols.count > Self.maximumSymbols else { return }
        let keep = symbols.values
            .sorted { lhs, rhs in
                if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
                return lhs.lastSeen > rhs.lastSeen
            }
            .prefix(Self.maximumSymbols)
        symbols = Dictionary(uniqueKeysWithValues: keep.map { ($0.name, $0) })
    }

    // MARK: - Declaration parsing

    /// Extracts user-declared names from C++ source.
    ///
    /// Deliberately simple and conservative: it looks for the shapes that are
    /// unambiguous in ordinary code (`struct X`, `class X`, `enum X`, functions,
    /// and variable declarations), and prefers missing a name over inventing one.
    public static func parseDeclarations(in document: String) -> [(String, SymbolKind)] {
        let code = DocumentSymbolIndex.strippingCommentsAndLiterals(document)
        var found: [(String, SymbolKind)] = []
        var seen = Set<String>()

        func record(_ name: String, _ kind: SymbolKind) {
            guard !name.isEmpty, name.count >= 2, !seen.contains(name) else { return }
            guard !isLanguageNoise(name) else { return }
            seen.insert(name)
            found.append((name, kind))
        }

        for rawLine in code.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // struct / class / union / enum [class] Name
            if let name = firstName(after: ["struct", "class", "union", "enum class", "enum"], in: line) {
                record(name, .userDefined)
            }

            // Function definition or declaration: `Type name(...)`.
            if let name = functionName(in: line) {
                record(name, .userDefined)
            }

            // Variable declarations: `Type name = …`, `Type name;`, `Type name{…}`.
            if let name = variableName(in: line) {
                record(name, .userDefined)
            }
        }
        return found
    }

    /// The identifier following one of `keywords`, if present at a word boundary.
    private static func firstName(after keywords: [String], in line: String) -> String? {
        for keyword in keywords.sorted(by: { $0.count > $1.count }) {
            guard let range = line.range(of: keyword), line.hasPrefix(keyword) else { continue }
            let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // `enum class X` is handled by trying "enum class" first.
            if let name = leadingIdentifier(rest), name != "class" { return name }
        }
        return nil
    }

    /// `Type name(` → `name`, ignoring control-flow keywords and calls.
    private static func functionName(in line: String) -> String? {
        guard let paren = line.firstIndex(of: "(") else { return nil }
        let before = line[..<paren].trimmingCharacters(in: .whitespaces)
        guard let name = before.split(separator: " ").last.map(String.init) else { return nil }
        guard leadingIdentifier(name) == name else { return nil }
        guard !controlFlow.contains(name) else { return nil }
        // A call (`foo(...)`) has no type before it; a definition does.
        let parts = before.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        return name
    }

    /// `Type name = …` / `Type name;` / `Type name{…}`.
    private static func variableName(in line: String) -> String? {
        // Only the simple `Type name <terminator>` shape; anything more complex is
        // skipped rather than guessed at.
        let terminators: [Character] = ["=", ";", "{", "["]
        guard let stop = line.firstIndex(where: { terminators.contains($0) }) else { return nil }
        let before = line[..<stop].trimmingCharacters(in: .whitespaces)
        let parts = before.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return nil }
        guard let name = parts.last, leadingIdentifier(name) == name else { return nil }
        guard !controlFlow.contains(parts[0]), !typesThatAreNotUserDefined.contains(name) else { return nil }
        // A first token that is not a plausible type (lowercase, no :: or <>)
        // usually means this is an expression, not a declaration.
        let typeToken = parts[0]
        let looksLikeType = typeToken.contains("::") || typeToken.contains("<")
            || typeToken.first.map { $0.isUppercase } == true
        guard looksLikeType else { return nil }
        return name
    }

    private static func leadingIdentifier(_ text: String) -> String? {
        var result = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                result.append(character)
            } else {
                break
            }
        }
        return result.isEmpty ? nil : result
    }

    private static let controlFlow: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "return", "catch",
        "try", "throw", "sizeof", "new", "delete", "while", "goto"
    ]

    /// Standard names that must not be stored as user declarations.
    private static let typesThatAreNotUserDefined: Set<String> = [
        "std", "string", "vector", "map", "set", "queue", "deque", "pair",
        "int", "char", "double", "float", "bool", "void", "long", "short",
        "unsigned", "signed", "size_t", "auto", "const", "static"
    ]

    /// Names that are compiler or language scaffolding rather than user symbols.
    static func isLanguageNoise(_ name: String) -> Bool {
        if name == "std" || name == "main" { return true }
        if name.hasPrefix("__") { return true }
        if controlFlow.contains(name) { return true }
        return false
    }
}
