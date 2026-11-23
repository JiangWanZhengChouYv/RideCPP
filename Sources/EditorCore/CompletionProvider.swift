import Foundation

/// One suggestion, plus how to render and insert it.
///
/// `text` may contain placeholder segments (see `Placeholder`). They are shown
/// greyed out in the completion list and **not** inserted when the suggestion is
/// accepted: they only mark the spots the user needs to fill in.
public struct CompletionItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let detail: String?
    /// What this suggestion refers to; drives the leading badge (kw / fx / var).
    public let kind: SymbolKind

    public init(id: String = UUID().uuidString,
                text: String,
                detail: String? = nil,
                kind: SymbolKind = .keyword) {
        self.id = id
        self.text = text
        self.detail = detail
        self.kind = kind
    }

    /// Text with placeholders and indent markers removed, which is what
    /// accepting the item inserts (the editor re-applies indentation).
    public var insertionText: String {
        Placeholder.strip(from: text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = String(line)
                while text.last == " " || text.last == "\t" { text.removeLast() }
                return text
            }
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var body = String(line)
                while body.hasPrefix(String(BuiltinCompletionProvider.indentMarker)) {
                    body.removeFirst()
                }
                return body
            }
            .joined(separator: "\n")
    }

    /// The parts to draw, in order, so placeholders can be greyed out.
    public var displaySegments: [DisplaySegment] {
        Placeholder.segments(in: text)
    }
}

/// A run of text in a suggestion: either real code or a grey placeholder.
public struct DisplaySegment: Equatable, Sendable {
    public let text: String
    public let isPlaceholder: Bool
}

/// Placeholder syntax used in snippet suggestions.
///
/// Written as `⟨name⟩` so it is visible in source, unambiguous against C++ code,
/// and cheap to strip. The classic `${1:condition}` form is avoided because it
/// would need escaping in C++ string literals.
public enum Placeholder {
    public static let open: Character = "⟨"
    public static let close: Character = "⟩"

    /// Removes every placeholder, leaving the code around it.
    public static func strip(from text: String) -> String {
        var result = ""
        var inside = false
        for character in text {
            if character == open { inside = true; continue }
            if character == close { inside = false; continue }
            if !inside { result.append(character) }
        }
        return result
    }

    /// Splits text into alternating code / placeholder runs for rendering.
    public static func segments(in text: String) -> [DisplaySegment] {
        var segments: [DisplaySegment] = []
        var current = ""
        var inside = false
        func flush() {
            guard !current.isEmpty else { return }
            segments.append(DisplaySegment(text: current, isPlaceholder: inside))
            current = ""
        }
        for character in text {
            if character == open, !inside {
                flush()
                inside = true
            } else if character == close, inside {
                flush()
                inside = false
            } else {
                current.append(character)
            }
        }
        flush()
        return segments
    }
}

/// Where the caret sits, which decides what to suggest.
public enum CompletionContext: Sendable {
    /// Ordinary code.
    case code
    /// Right after `#` — preprocessor directives.
    case preprocessor
}

/// Hook for completion sources.
public protocol CompletionProviding: AnyObject {
    func completionItems(forPrefix prefix: String, document: String, context: CompletionContext) -> [CompletionItem]
}

public extension CompletionProviding {
    /// Asynchronous request path for a remote model.
    func completions(forPrefix prefix: String, document: String) async -> [CompletionItem] {
        completionItems(forPrefix: prefix, document: document, context: .code)
    }
}

/// The built-in, offline completion source.
///
/// Sources, in order of authority:
/// 1. **Keywords** — verified against the active compiler (`KeywordTable`).
/// 2. **Names from this file's includes** — harvested on demand from the headers
///    the document actually `#include`s (`DocumentSymbolIndex`), so `vector`,
///    `cout`, `sort`, … come from the real headers rather than a list written by
///    hand, and nothing is scanned for headers the file does not use.
/// 3. **Names already used in this file** — so partially typed locals complete.
/// 4. **A few structural snippets** — loop/function scaffolds. These exist
///    because a suggestion list cannot create multi-line structure, and their
///    variable parts are grey placeholders that are not inserted.
public final class BuiltinCompletionProvider: CompletionProviding {

    /// Preprocessor directives come from the compiler's own accepted grammar.
    public static let preprocessorDirectives = [
        "#include", "#define", "#undef", "#if", "#ifdef", "#ifndef", "#elif",
        "#else", "#endif", "#line", "#error", "#pragma"
    ]

    /// Multi-line scaffolds. Placeholders mark the parts the user fills in and
    /// are shown grey, never inserted.
    ///
    /// Bodies are written with a single-space indent marker (`·`), which is
    /// replaced by the editor's own indent unit at insertion time. Hard-coding
    /// four spaces made snippets look wrong next to two-space or tab-indented
    /// files, and looked wrong next to the surrounding code.
    public static let snippets: [(name: String, body: String, detail: String)] = [
        ("main", "int main() {\n·⟨body⟩\n·return 0;\n}", "main function"),
        ("for", "for (int i = 0; i < ⟨n⟩; ++i) {\n·⟨body⟩\n}", "indexed loop"),
        ("forr", "for (const auto& ⟨item⟩ : ⟨container⟩) {\n·⟨body⟩\n}", "range-based for"),
        ("while", "while (⟨condition⟩) {\n·⟨body⟩\n}", "while loop"),
        ("if", "if (⟨condition⟩) {\n·⟨body⟩\n}", "if statement"),
        ("ife", "if (⟨condition⟩) {\n·⟨body⟩\n} else {\n·⟨else body⟩\n}", "if / else"),
        ("switch", "switch (⟨value⟩) {\ncase 0:\n·⟨body⟩\n·break;\ndefault:\n·break;\n}", "switch statement"),
        ("vec", "⟨namespace⟩vector<int>", "vector declaration"),
        ("class", "class ⟨Name⟩ {\npublic:\n·⟨Name⟩() = default;\n};", "class definition")
    ]

    /// The character that marks one level of indentation inside a snippet body.
    public static let indentMarker: Character = "·"

    private let index: DocumentSymbolIndex
    private let symbols: UserSymbolStore

    public init(index: DocumentSymbolIndex = .shared,
                symbols: UserSymbolStore = .shared) {
        self.index = index
        self.symbols = symbols
    }

    public func completionItems(forPrefix prefix: String,
                                document: String,
                                context: CompletionContext = .code) -> [CompletionItem] {
        let query = prefix.trimmingCharacters(in: .whitespaces)
        if context == .preprocessor {
            let needle = query.isEmpty ? "#" : (query.hasPrefix("#") ? query : "#" + query)
            return Self.preprocessorDirectives
                .filter { $0.lowercased().hasPrefix(needle.lowercased()) }
                .map { CompletionItem(id: "pp:\($0)", text: $0, detail: "preprocessor") }
        }

        let lowered = query.lowercased()
        guard !lowered.isEmpty, lowered.count <= 32 else { return [] }
        // With `using namespace std;` in the file, `std::` prefixing is noise: the
        // user writes `vector`, not `std::vector`.
        let standardNamespaceIsOpen = Self.hasUsingNamespaceStd(document)
        var items: [CompletionItem] = []
        var seen = Set<String>()

        func add(_ text: String, _ detail: String?, id: String, kind: SymbolKind) {
            // Deduplicate on what would actually be inserted.
            let insertion = Placeholder.strip(from: text)
            guard !insertion.isEmpty, !seen.contains(insertion) else { return }
            seen.insert(insertion)
            items.append(CompletionItem(id: id, text: text, detail: detail, kind: kind))
        }

        // A snippet whose trigger matches exactly is the most likely intent.
        for snippet in Self.snippets where snippet.name.lowercased() == lowered {
            add(Self.expandingSnippet(snippet.body, standardNamespaceIsOpen: standardNamespaceIsOpen),
                snippet.detail,
                id: "snip:\(snippet.name)",
                kind: .keyword)
        }

        // Everything else competes on usage rank rather than being concatenated:
        // with a one-letter prefix the keyword list alone used to fill all 40
        // slots, so `cout` never appeared until three letters were typed.
        var candidates: [RankedCandidate] = []
        for keyword in KeywordTable.keywords() where keyword.hasPrefix(lowered) {
            guard !Self.isNoise(keyword) else { continue }
            candidates.append(RankedCandidate(name: keyword, detail: nil,
                                              score: Self.usageScore(keyword, query: lowered, kind: .keyword),
                                              kind: .keyword))
        }
        // Only the headers this file includes contribute vocabulary, so cost stays
        // proportional to what is actually used (one header, or one
        // `bits/stdc++.h` that pulls everything).
        let headers = HeaderPaths.includes(in: document)
        for name in index.names(from: headers, prefix: query, limit: 40) {
            // Namespace and macro scaffolding is never what the user is typing.
            guard !Self.isNoise(name) else { continue }
            candidates.append(RankedCandidate(name: name, detail: nil,
                                              score: Self.usageScore(name, query: lowered, kind: .header),
                                              kind: .header))
        }
        // Names remembered from earlier files and sessions: the "custom function,
        // struct, class, variable" memory.
        for remembered in symbols.symbols(withPrefix: query, limit: 20)
        where !Self.isNoise(remembered.name) {
            var score = Self.usageScore(remembered.name, query: lowered, kind: .userDefined)
            // Frequently written names deserve to lead the list.
            score += min(Double(remembered.uses), 20) * 2
            if symbols.isSessionName(remembered.name) { score += 10 }
            candidates.append(RankedCandidate(name: remembered.name,
                                              detail: "remembered",
                                              score: score,
                                              kind: .userDefined))
        }
        for symbol in Self.localIdentifiers(in: document) where symbol.lowercased().hasPrefix(lowered) {
            // `using namespace std;` makes `std` look like a local identifier; it
            // is still never a thing to type.
            guard !Self.isNoise(symbol) else { continue }
            candidates.append(RankedCandidate(name: symbol, detail: nil,
                                              score: Self.usageScore(symbol, query: lowered, kind: .userDefined),
                                              kind: .userDefined))
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.name < rhs.name
        }
        for candidate in candidates {
            add(candidate.name, candidate.detail, id: "rank:\(candidate.name)",
                kind: candidate.kind)
        }

        for snippet in Self.snippets where snippet.name.lowercased().hasPrefix(lowered) && snippet.name.lowercased() != lowered {
            add(Self.expandingSnippet(snippet.body, standardNamespaceIsOpen: standardNamespaceIsOpen),
                snippet.detail,
                id: "snip:\(snippet.name)",
                kind: .keyword)
        }
        return Array(items.prefix(40))
    }

    /// Names that are technically valid but never useful as a suggestion: the
    /// `std` namespace itself, and internal-looking identifiers.
    static func isNoise(_ name: String) -> Bool {
        if name == "std" || name.hasPrefix("std__") { return true }
        // `__x`-style implementation names leak in from macros.
        if name.hasPrefix("__") { return true }
        return false
    }

    /// A completion candidate with its usefulness score.
    struct RankedCandidate {
        let name: String
        let detail: String?
        let score: Double
        let kind: SymbolKind
    }

    enum CandidateKind {
        case keyword
        case header
        case userDefined
    }

    /// Names that are worth surfacing from the first keystroke, in rough order of
    /// how often they appear in everyday C++ code.
    ///
    /// This is an ordering hint, not a vocabulary: every name here must still come
    /// from the compiler or the included headers to be offered at all. Its only
    /// job is to decide *which* real candidates survive the 40-item cap — without
    /// it, alphabetical luck decided, and `cout` lost to `class`.
    static let commonNames: [String: Double] = {
        let tiers: [(Double, [String])] = [
            (100, ["cout", "cin", "endl", "vector", "string", "int", "return", "sort",
                   "size", "push_back", "size()", "max", "min", "swap", "for", "if", "while"]),
            (80, ["cerr", "printf", "scanf", "map", "set", "queue", "stack", "pair",
                  "begin", "end", "first", "second", "abs", "sqrt", "reverse", "memset",
                  "int64_t", "long", "double", "float", "char", "bool", "void", "auto",
                  "const", "static", "struct", "class"]),
            (60, ["unordered_map", "unordered_set", "deque", "priority_queue", "vector<",
                  "string_view", "to_string", "stoi", "stol", "getline", "substr", "find",
                  "insert", "erase", "clear", "empty", "count", "accumulate", "fill",
                  "lower_bound", "upper_bound", "binary_search", "unique", "erase_unique"]),
            (40, ["unsigned", "size_t", "nullptr", "true", "false", "break", "continue",
                  "else", "switch", "case", "default", "do", "goto", "try", "catch",
                  "throw", "new", "delete", "namespace", "using", "include", "define",
                  "template", "typename", "public", "private", "protected", "virtual",
                  "inline", "explicit", "operator", "friend", "mutable", "volatile",
                  "typedef", "sizeof"])
        ]
        var table: [String: Double] = [:]
        for (score, names) in tiers {
            for name in names { table[name] = score }
        }
        return table
    }()

    /// Score for one candidate. Higher wins.
    ///
    /// A short prefix needs usage information most, so the common-name table gets
    /// the most weight there; as the user types more, an exact/near-exact name
    /// match and a shorter name naturally take over.
    static func usageScore(_ name: String, query: String, kind: CandidateKind) -> Double {
        let lowered = name.lowercased()
        var score = 0.0

        // Prefix quality: exact beats longer.
        if lowered == query { score += 60 }
        else if lowered.hasPrefix(query) { score += 30 }
        score -= Double(max(0, lowered.count - query.count)) * 0.6

        // Where the name came from: names the file already uses are the most
        // relevant, then names from the headers it includes, then keywords.
        switch kind {
        // Names already used in this file are what the user is most likely to
        // retype, so they must beat keywords even when the keyword is "common".
        case .userDefined: score += 160
        case .header: score += 30
        case .keyword: score += 12
        }

        // Usage hint, weighted more heavily when the prefix is short.
        let usage = commonNames[lowered] ?? 0
        let shortPrefixBoost = query.count <= 2 ? 1.0 : (query.count == 3 ? 0.5 : 0.25)
        score += usage * shortPrefixBoost

        // All-caps and underscore-heavy names are usually internals.
        if lowered.contains("_") { score -= 6 }
        if lowered.allSatisfy({ !$0.isLowercase }) { score -= 12 }
        return score
    }

    /// Fills in snippet placeholders that depend on the document.
    ///
    /// `⟨namespace⟩` expands to `"std::"` or to nothing, so the same snippet text
    /// works for a file with `using namespace std;` and one without it.
    static func expandingSnippet(_ body: String, standardNamespaceIsOpen: Bool) -> String {
        body.replacingOccurrences(of: "⟨namespace⟩", with: standardNamespaceIsOpen ? "" : "std::")
    }

    /// True when the document opens the `std` namespace without qualification.
    ///
    /// Only `using namespace std;` counts; `using std::vector;` brings in one name
    /// and does not justify dropping the prefix everywhere.
    public static func hasUsingNamespaceStd(_ document: String) -> Bool {
        let code = DocumentSymbolIndex.strippingCommentsAndLiterals(document)
        // Match the statement anywhere, not just at the start of a line: it can be
        // written inline (`int main() { using namespace std; }`).
        let pattern = #"using\s+namespace\s+std\s*;"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    /// Identifiers already present in the document, most recently used first.
    public static func localIdentifiers(in document: String) -> [String] {
        let tokens = CppLexer.tokenize(document)
        let ns = document as NSString
        var order: [String] = []
        var seen = Set<String>()
        for token in tokens.reversed() {
            guard token.kind == .identifier, NSMaxRange(token.range) <= ns.length else { continue }
            let word = ns.substring(with: token.range)
            guard word.count >= 2, !seen.contains(word) else { continue }
            seen.insert(word)
            order.append(word)
        }
        return order
    }

    /// The word the caret is in, used as the completion prefix.
    public static func prefix(at location: Int, in text: String) -> (prefix: String, range: NSRange) {
        let ns = text as NSString
        let clamped = min(max(0, location), ns.length)
        var start = clamped
        while start > 0 {
            let scalar = ns.character(at: start - 1)
            let isIdentifier = (scalar >= 48 && scalar <= 57)
                || (scalar >= 65 && scalar <= 90)
                || (scalar >= 97 && scalar <= 122)
                || scalar == 95
            if !isIdentifier { break }
            start -= 1
        }
        let range = NSRange(location: start, length: clamped - start)
        return (ns.substring(with: range), range)
    }
}

/// Placeholder provider that never suggests anything.
public final class NoopCompletionProvider: CompletionProviding {
    public init() {}
    public func completionItems(forPrefix prefix: String, document: String, context: CompletionContext) -> [CompletionItem] { [] }
}
