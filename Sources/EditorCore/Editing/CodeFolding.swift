import Foundation

/// Works out which lines can be folded, and what they hide.
///
/// Folding is computed from braces rather than from a parse tree: for the single
/// files this editor targets, a brace that opens and closes many lines later is
/// the structure the user wants out of the way, and this stays correct while the
/// file does not compile — which is exactly when folding is useful.
public enum CodeFolding {

    /// One collapsible region.
    public struct Region: Equatable, Sendable {
        /// 0-based line of the opening brace's statement.
        public let startLine: Int
        /// 0-based last line of the block, which stays visible as `…`.
        public let endLine: Int

        public init(startLine: Int, endLine: Int) {
            self.startLine = startLine
            self.endLine = endLine
        }
    }

    /// Every foldable region in `text`, outermost first.
    ///
    /// A block is only offered when it spans at least two lines: folding a
    /// one-line body would hide the only thing on the line.
    public static func regions(in text: String) -> [Region] {
        var regions: [Region] = []
        var stack: [(line: Int, depth: Int, hasNewline: Bool)] = []
        var line = 0
        var inString = false
        var inChar = false
        var inLineComment = false
        var inBlockComment = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if character == "\n" {
                line += 1
                inLineComment = false
                if !stack.isEmpty { stack[stack.count - 1].hasNewline = true }
                index = next
                continue
            }
            // Comments and literals: braces inside them are not structure.
            if inLineComment { index = next; continue }
            if inBlockComment {
                if character == "*", next < text.endIndex, text[next] == "/" {
                    inBlockComment = false
                    index = text.index(after: next)
                    continue
                }
                index = next
                continue
            }
            if inString {
                // Skip an escaped character so `\"` does not end the literal.
                if character == "\\", next < text.endIndex {
                    index = text.index(after: next)
                    continue
                }
                if character == "\"" { inString = false }
                index = next
                continue
            }
            if inChar {
                if character == "'" { inChar = false }
                index = next
                continue
            }
            if character == "/", next < text.endIndex {
                if text[next] == "/" { inLineComment = true; index = text.index(after: next); continue }
                if text[next] == "*" { inBlockComment = true; index = text.index(after: next); continue }
            }
            if character == "\"" { inString = true; index = next; continue }
            if character == "'" { inChar = true; index = next; continue }

            if character == "{" {
                stack.append((line: line, depth: stack.count, hasNewline: false))
            } else if character == "}" {
                if let opened = stack.popLast(), opened.hasNewline, line > opened.line {
                    regions.append(Region(startLine: opened.line, endLine: line))
                }
            }
            index = next
        }
        // Sorted by position so the caller can render gutter carets in order.
        return regions.sorted { lhs, rhs in
            if lhs.startLine != rhs.startLine { return lhs.startLine < rhs.startLine }
            return lhs.endLine > rhs.endLine
        }
    }

    /// For each start line, the end line of the region it opens.
    ///
    /// When regions share a start line the widest wins, which is the one whose
    /// caret a user is most likely aiming at.
    public static func foldMap(in text: String) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for region in regions(in: text) {
            if let existing = map[region.startLine] {
                map[region.startLine] = max(existing, region.endLine)
            } else {
                map[region.startLine] = region.endLine
            }
        }
        return map
    }
}
