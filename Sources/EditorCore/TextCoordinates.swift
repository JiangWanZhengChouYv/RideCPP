import Foundation

/// Conversions between 1-based line/column pairs and UTF-16 string offsets.
///
/// Columns count characters (grapheme clusters) the way a user sees them, while
/// offsets are UTF-16 units, matching `NSTextStorage` and compiler diagnostics.
public enum TextCoordinates {

    /// UTF-16 offset of the first character of `line` (1-based).
    public static func utf16Offset(ofLine line: Int, in text: String) -> Int? {
        guard line >= 1 else { return nil }
        if line == 1 { return 0 }
        let ns = text as NSString
        var currentLine = 1
        var index = 0
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            currentLine += 1
            if currentLine == line { return NSMaxRange(range) <= ns.length ? NSMaxRange(range) : nil }
            index = NSMaxRange(range)
        }
        return nil
    }

    /// UTF-16 offset for a 1-based line and 1-based column.
    public static func utf16Offset(line: Int, column: Int, in text: String) -> Int? {
        guard let start = utf16Offset(ofLine: line, in: text) else { return nil }
        guard column > 1 else { return start }
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        let contentEnd = lineRange.location + contentLength(of: lineRange, in: ns)
        var offset = start
        var columnCount = 1
        while offset < contentEnd, columnCount < column {
            let composed = ns.rangeOfComposedCharacterSequence(at: offset)
            offset = NSMaxRange(composed)
            columnCount += 1
        }
        return min(offset, contentEnd)
    }

    /// 1-based line and column for a UTF-16 offset.
    public static func lineAndColumn(at offset: Int, in text: String) -> (line: Int, column: Int)? {
        let ns = text as NSString
        guard ns.length > 0 else { return offset == 0 ? (1, 1) : nil }
        let clamped = min(max(0, offset), ns.length)
        var line = 1
        var index = 0
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            if clamped < NSMaxRange(range) || NSMaxRange(range) >= ns.length {
                let contentEnd = range.location + contentLength(of: range, in: ns)
                var column = 1
                var cursor = range.location
                while cursor < min(clamped, contentEnd) {
                    cursor = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: cursor))
                    column += 1
                }
                return (line, column)
            }
            index = NSMaxRange(range)
            line += 1
        }
        return (line, 1)
    }

    /// Number of lines in the text (a trailing newline does not add a line).
    public static func lineCount(in text: String) -> Int {
        let ns = text as NSString
        guard ns.length > 0 else { return 1 }
        var count = 0
        var index = 0
        while index < ns.length {
            index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
            count += 1
        }
        return max(1, count)
    }

    /// The text of a 1-based line, without its line terminator.
    public static func line(_ line: Int, in text: String) -> String? {
        guard let start = utf16Offset(ofLine: line, in: text) else { return nil }
        let ns = text as NSString
        let range = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        return ns.substring(with: NSRange(location: range.location, length: contentLength(of: range, in: ns)))
    }

    /// Length of a line range excluding the terminator.
    static func contentLength(of lineRange: NSRange, in ns: NSString) -> Int {
        var length = lineRange.length
        while length > 0 {
            let last = ns.character(at: lineRange.location + length - 1)
            if last == 10 || last == 13 {
                length -= 1
            } else {
                break
            }
        }
        return length
    }

    /// Normalizes CRLF/CR line endings to LF. The IDE stores text with LF only.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
