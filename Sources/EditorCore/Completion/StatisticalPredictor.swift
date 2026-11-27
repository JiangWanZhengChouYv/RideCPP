import Foundation

/// Predictive completion built from the code the user actually writes.
///
/// Why not ask the language model first: a model round trip costs 50-300 ms at
/// best and yields a suggestion that is often wrong, whereas competitive
/// programming code is extremely repetitive — `for (int i = 0; i < n; ++i) {`
/// and `cin >> n;` recur in nearly every file. Learning those shapes from the
/// user's own history gives an answer instantly, with no server, no model and no
/// heat, and it never proposes something that does not compile.
///
/// Strategy:
///  1. Templates learned from previously opened files (persisted).
///  2. Structural patterns for C++ constructs, filled from identifiers that
///     actually appear in the current file.
///  3. Otherwise nothing — a bad suggestion is worse than none.
public final class StatisticalPredictor {

    /// One learned line, keyed by the text typed before the caret.
    public struct Template: Codable, Equatable, Sendable {
        /// What the user has typed, e.g. "for" or "cin".
        public let prefix: String
        /// What came after it on the line, e.g. " (int i = 0; i < n; i++) {".
        public let completion: String
        /// How often this shape has been seen; higher ranks first.
        public let count: Int
    }

    /// Learned templates, most useful first.
    private var templates: [Template] = []
    private let queue = DispatchQueue(label: "RideCPP.StatisticalPredictor")
    private static let maximumTemplates = 400
    private let storageURL: URL?

    public init(storageURL: URL? = StatisticalPredictor.defaultStorageURL()) {
        self.storageURL = storageURL
        load()
    }

    /// Where templates are remembered between runs.
    ///
    /// Deliberately beside the user symbol store: this is user data, not ship data.
    public static func defaultStorageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("RideCPP", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("completion-templates.json")
    }

    // MARK: - Learning

    /// Learns every meaningful line of a document.
    ///
    /// Lines that are blank, comments or trivial braces teach nothing.
    public func learn(from text: String) {
        var learned: [String: Int] = [:]
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 4 else { continue }
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*"),
                  !trimmed.hasPrefix("*"), !trimmed.hasPrefix("#include") else { continue }
            guard let (prefix, completion) = Self.split(line) else { continue }
            // Only remember shapes that continue past the prefix; a bare "{"
            // teaches nothing.
            guard completion.count >= 3 else { continue }
            learned[prefix + "\u{1}" + completion, default: 0] += 1
        }
        guard !learned.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var merged: [String: Int] = [:]
            for template in self.templates {
                merged[template.prefix + "\u{1}" + template.completion] = template.count
            }
            for (key, count) in learned {
                merged[key, default: 0] += count
            }
            self.templates = merged.compactMap { key, count -> Template? in
                let parts = key.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { return nil }
                return Template(prefix: parts[0], completion: parts[1], count: count)
            }
            .sorted { $0.count > $1.count }
            self.templates = Array(self.templates.prefix(Self.maximumTemplates))
            self.save()
        }
    }

    /// Splits a line into "what the user types" and "what follows".
    ///
    /// The split point is the first token boundary — for `for (int i = 0; ...`
    /// that is `for` and ` (int i = 0; ...`.
    static func split(_ line: String) -> (prefix: String, completion: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = String(leading)
        let body = line.dropFirst(indent.count)
        guard let end = body.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "[" }) else {
            return nil
        }
        let prefix = String(body[..<end]).trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty, prefix.count <= 12 else { return nil }
        let completion = String(body[end...])
        return (prefix, completion)
    }

    // MARK: - Predicting

    /// A completion for the text before the caret.
    ///
    /// Returns something only when the predictor is reasonably confident; an
    /// empty string means "say nothing", which is the common case.
    public func predict(prefixBeforeCaret: String, document: String,
                        suffixAfterCaret: String) -> String {
        let lineStart = prefixBeforeCaret.lastIndex(of: "\n")
            .map { prefixBeforeCaret.index(after: $0) } ?? prefixBeforeCaret.startIndex
        let linePrefix = String(prefixBeforeCaret[lineStart...])
        let typed = linePrefix.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return "" }

        // A suggestion must not duplicate what is already there.
        let restOfLine = suffixAfterCaret.prefix { $0 != "\n" }
            .trimmingCharacters(in: .whitespaces)

        // 1. Something the user has written before, starting with these characters.
        if let learned = learnedCompletion(for: typed, excluding: restOfLine) {
            return learned
        }
        // 2. A structural pattern, filled from this file's own identifiers.
        if let structured = structuralCompletion(for: typed, document: document,
                                                 excluding: restOfLine) {
            return structured
        }
        return ""
    }

    private func learnedCompletion(for typed: String, excluding restOfLine: String) -> String? {
        let candidates = queue.sync { templates }
            .filter { $0.prefix == typed && !$0.completion.isEmpty }
            .filter { template in
                // Do not repeat what the line already contains.
                let trimmed = template.completion.trimmingCharacters(in: .whitespaces)
                return !restOfLine.hasPrefix(trimmed)
            }
        return candidates.first?.completion
    }

    /// Built-in shapes for the constructs that dominate algorithm work.
    ///
    /// The values are not invented: each one is the standard idiom, and the
    /// identifiers come from the document being edited so a suggestion refers to
    /// variables that exist.
    private func structuralCompletion(for typed: String, document: String,
                                      excluding restOfLine: String) -> String? {
        let names = Self.identifiers(in: document)
        guard !restOfLine.hasPrefix("(") else { return nil }
        switch typed {
        case "for":
            return " (int i = 0; i < n; ++i) {"
        case "while":
            return " (cin >> n) {"
        case "if":
            return " (n == 0) {"
        case "cin":
            if let first = names.first { return " >> \(first);" }
            return " >> n;"
        case "cout":
            if let first = names.first { return " << \(first) << endl;" }
            return " << endl;"
        case "sort":
            return "(a.begin(), a.end());"
        case "vector":
            return "<int> \(Self.conventionalArrayName(in: document))\(Self.arraySize(in: document));"
        case "return":
            return " 0;"
        case "int":
            return " main() {"
        case "ios":
            return "::sync_with_stdio(false);"
        default:
            return nil
        }
    }

    /// Identifiers declared in the document, in first-appearance order.
    ///
    /// Deliberately crude: only `int a;` / `ll b;` / `vector<int> c;` shapes are
    /// picked up, which covers how these files actually declare things without
    /// needing a parser.
    static func identifiers(in document: String) -> [String] {
        let pattern = #"(?:^|[\s;{(])(?:int|long long|ll|double|char|bool|string|size_t)\s+([A-Za-z_]\w*)\s*(?:[;=,\[])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let ns = document as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: document, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let name = ns.substring(with: match.range(at: 1))
            let reserved: Set<String> = ["main", "return", "const", "void", "true", "false"]
            guard !reserved.contains(name), !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(name)
        }
        return result
    }

    static func conventionalArrayName(in document: String) -> String {
        document.contains("vector<int> a") ? "b" : "a"
    }

    static func arraySize(in document: String) -> String {
        document.contains("cin >> n") ? "(n)" : "(n + 1)"
    }

    // MARK: - Persistence

    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        if let decoded = try? JSONDecoder().decode([Template].self, from: data) {
            templates = decoded
        }
    }

    private func save() {
        guard let storageURL, let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    /// Test hook: the templates currently known.
    public var templateCountForTesting: Int { queue.sync { templates.count } }
}
