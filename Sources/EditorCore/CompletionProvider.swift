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

    public init(id: String = UUID().uuidString, text: String, detail: String? = nil) {
        self.id = id
        self.text = text
        self.detail = detail
    }

    /// Text with placeholders removed, which is what accepting the item inserts.
    public var insertionText: String {
        Placeholder.strip(from: text)
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
/// 2. **Standard library names** — harvested from the SDK headers that compiler
///    ships (`HeaderSymbolIndex`), so `vector`, `cout`, `sort`, … come from the
///    real headers rather than a list written by hand.
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
    public static let snippets: [(name: String, body: String, detail: String)] = [
        ("main", "int main() {\n    ⟨body⟩\n    return 0;\n}", "main function"),
        ("for", "for (int i = 0; i < ⟨n⟩; ++i) {\n    ⟨body⟩\n}", "indexed loop"),
        ("forr", "for (const auto& ⟨item⟩ : ⟨container⟩) {\n    ⟨body⟩\n}", "range-based for"),
        ("while", "while (⟨condition⟩) {\n    ⟨body⟩\n}", "while loop"),
        ("if", "if (⟨condition⟩) {\n    ⟨body⟩\n}", "if statement"),
        ("ife", "if (⟨condition⟩) {\n    ⟨body⟩\n} else {\n    ⟨else body⟩\n}", "if / else"),
        ("switch", "switch (⟨value⟩) {\ncase 0:\n    ⟨body⟩\n    break;\ndefault:\n    break;\n}", "switch statement"),
        ("vec", "std::vector<⟨T⟩> ⟨name⟩;", "std::vector declaration"),
        ("class", "class ⟨Name⟩ {\npublic:\n    ⟨Name⟩() = default;\n};", "class definition")
    ]

    private let index: HeaderSymbolIndex
    private let compilerPath: String?

    public init(index: HeaderSymbolIndex = .shared, compilerPath: String? = nil) {
        self.index = index
        self.compilerPath = compilerPath
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
        var items: [CompletionItem] = []
        var seen = Set<String>()

        func add(_ text: String, _ detail: String, id: String) {
            // Deduplicate on what would actually be inserted.
            let insertion = Placeholder.strip(from: text)
            guard !insertion.isEmpty, !seen.contains(insertion) else { return }
            seen.insert(insertion)
            items.append(CompletionItem(id: id, text: text, detail: detail))
        }

        // A snippet whose trigger matches exactly is the most likely intent.
        for snippet in Self.snippets where snippet.name.lowercased() == lowered {
            add(snippet.body, snippet.detail, id: "snip:\(snippet.name)")
        }
        for keyword in KeywordTable.keywords(compilerPath: compilerPath) where keyword.hasPrefix(lowered) {
            add(keyword, "keyword", id: "kw:\(keyword)")
        }
        for name in index.names(withPrefix: query, limit: 30) {
            add(name, "standard library", id: "hdr:\(name)")
        }
        for symbol in Self.localIdentifiers(in: document) where symbol.lowercased().hasPrefix(lowered) {
            add(symbol, "in this file", id: "sym:\(symbol)")
        }
        for snippet in Self.snippets where snippet.name.lowercased().hasPrefix(lowered) && snippet.name.lowercased() != lowered {
            add(snippet.body, snippet.detail, id: "snip:\(snippet.name)")
        }
        return Array(items.prefix(40))
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
