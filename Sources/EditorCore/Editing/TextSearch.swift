import Foundation

/// Finds occurrences of a search term in text.
///
/// Lives in `EditorCore` rather than the view so the matching rules — whole
/// word, case sensitivity, regular expressions — can be tested without a window,
/// and so the same logic could later drive replace-all across documents.
public struct TextSearch {

    public struct Options: Equatable, Sendable {
        public var caseSensitive: Bool
        public var wholeWord: Bool
        public var isRegex: Bool

        public init(caseSensitive: Bool = false, wholeWord: Bool = false, isRegex: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
            self.isRegex = isRegex
        }
    }

    /// One match, as UTF-16 offsets.
    public struct Match: Equatable, Sendable {
        public let range: NSRange
        /// 0-based index of the line the match starts on.
        public let line: Int

        public init(range: NSRange, line: Int) {
            self.range = range
            self.line = line
        }
    }

    public init() {}

    /// Every match of `query` in `text`, in document order.
    ///
    /// Returns an empty array for an empty query rather than "everything", which
    /// is what a naive `range(of:)` loop would produce.
    public func matches(of query: String, in text: String, options: Options) -> [Match] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }

        var found: [NSRange] = []
        if options.isRegex {
            guard let regex = try? NSRegularExpression(pattern: query,
                                                       options: options.caseSensitive ? [] : [.caseInsensitive]) else {
                return []
            }
            for result in regex.matches(in: text, options: [], range: full) {
                let range = result.range
                // A pattern that can match nothing would loop forever if we
                // searched forward from it; skip zero-width hits.
                guard range.length > 0 else { continue }
                if options.wholeWord, !Self.isWholeWord(range, in: ns) { continue }
                found.append(range)
            }
        } else {
            var cursor = 0
            let compareOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            while cursor < ns.length {
                let searchRange = NSRange(location: cursor, length: ns.length - cursor)
                let hit = ns.range(of: query, options: compareOptions, range: searchRange)
                guard hit.location != NSNotFound else { break }
                if !options.wholeWord || Self.isWholeWord(hit, in: ns) {
                    found.append(hit)
                }
                cursor = max(hit.location + max(hit.length, 1), cursor + 1)
            }
        }
        return found.map { Match(range: $0, line: Self.lineNumber(at: $0.location, in: ns)) }
    }

    /// The first match strictly after `location`, wrapping to the start.
    ///
    /// This is what makes ⌘G behave the way people expect: the next hit from
    /// wherever the caret is, and back to the first one at the end.
    public func nextMatch(after location: Int, in matches: [Match]) -> Match? {
        guard !matches.isEmpty else { return nil }
        return matches.first { $0.range.location > location } ?? matches.first
    }

    /// The first match strictly before `location`, wrapping to the last.
    public func previousMatch(before location: Int, in matches: [Match]) -> Match? {
        guard !matches.isEmpty else { return nil }
        return matches.last { $0.range.location < location } ?? matches.last
    }

    /// Whether `range` is bounded by non-identifier characters on both sides.
    static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isWordCharacter(_ index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            let scalar = text.character(at: index)
            guard let uni = UnicodeScalar(scalar) else { return false }
            return CharacterSet.alphanumerics.contains(uni) || uni == "_"
        }
        let beforeIsWord = isWordCharacter(range.location - 1)
        let afterIsWord = isWordCharacter(NSMaxRange(range))
        return !beforeIsWord && !afterIsWord
    }

    /// 0-based line index of a UTF-16 offset.
    static func lineNumber(at offset: Int, in text: NSString) -> Int {
        var line = 0
        var index = 0
        let limit = min(max(0, offset), text.length)
        while index < limit {
            let found = text.range(of: "\n", options: [],
                                   range: NSRange(location: index, length: limit - index))
            if found.location == NSNotFound { break }
            index = found.location + 1
            line += 1
        }
        return line
    }
}

/// Replaces every match of a search term.
public extension TextSearch {

    /// Rewrites `text` with every match replaced by `replacement`.
    ///
    /// The replacement is inserted literally: back-references like `\1` in a
    /// regex replacement would need their own escaping rules, and silently
    /// interpreting them here would mangle a replacement that legitimately
    /// contains a backslash.
    func replacingAll(in text: String, query: String, with replacement: String,
                      options: Options) -> String {
        let found = matches(of: query, in: text, options: options)
        guard !found.isEmpty else { return text }
        var result = text
        // Replace back-to-front so earlier offsets stay valid.
        for match in found.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
