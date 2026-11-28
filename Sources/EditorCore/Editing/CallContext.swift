import Foundation

/// Works out whether the caret sits inside a call's argument list, and in which
/// argument.
///
/// The language server answers "what are this call's parameters" only when asked
/// at the right moment. Asking on every keystroke would be wasteful and would pop
/// the hint up while the user is writing the function name; this scan is what
/// decides that the caret is between a `(` and its matching `)` and how many
/// commas precede it.
public enum CallContext {

    public struct Info: Equatable, Sendable {
        /// The callable's name, e.g. `greet` or `push_back`.
        public let callee: String
        /// 0-based index of the argument the caret is in.
        public let argumentIndex: Int
        /// Offset of the opening parenthesis, for anchoring the hint.
        public let openParenthesis: Int

        public init(callee: String, argumentIndex: Int, openParenthesis: Int) {
            self.callee = callee
            self.argumentIndex = argumentIndex
            self.openParenthesis = openParenthesis
        }
    }

    /// Describes the call the caret at `offset` is inside, or nil.
    ///
    /// Scans backwards for the parenthesis that is still open, skipping string
    /// and character literals and ignoring parentheses that belong to something
    /// that is not a call (`if (`, `while (`).
    public static func info(at offset: Int, in text: String) -> Info? {
        let ns = text as NSString
        guard offset >= 0, offset <= ns.length, ns.length > 0 else { return nil }

        var depth = 0
        var argumentIndex = 0
        var index = offset - 1
        var openParen = -1
        var inString = false
        var inCharacter = false

        while index >= 0 {
            let character = ns.substring(with: NSRange(location: index, length: 1))
            // Track literals so a comma inside a string does not count.
            if character == "\"" && !inCharacter { inString.toggle() }
            else if character == "'" && !inString { inCharacter.toggle() }
            else if !inString, !inCharacter {
                if character == ")" {
                    depth += 1
                } else if character == "(" {
                    if depth == 0 {
                        openParen = index
                        break
                    }
                    depth -= 1
                } else if depth == 0, character == "," {
                    argumentIndex += 1
                } else if depth == 0, character == ";" || character == "{" || character == "}" {
                    // A new statement or block ended before any open parenthesis.
                    return nil
                }
            }
            index -= 1
        }
        guard openParen >= 0 else { return nil }
        // A statement boundary between the parenthesis and the caret means this
        // is not the enclosing call at all.
        if containsStatementBoundary(from: openParen, to: offset, in: ns) { return nil }

        let callee = calleeName(before: openParen, in: ns)
        guard !callee.isEmpty else { return nil }
        // Keywords with parentheses are not calls.
        let nonCalls: Set<String> = ["if", "while", "for", "switch", "return", "sizeof",
                                     "catch", "do", "else", "case", "throw", "new", "delete"]
        guard !nonCalls.contains(callee) else { return nil }
        return Info(callee: callee, argumentIndex: argumentIndex, openParenthesis: openParen)
    }

    /// Whether an unclosed statement appears between two offsets.
    private static func containsStatementBoundary(from start: Int, to end: Int, in text: NSString) -> Bool {
        guard start < end else { return false }
        let slice = text.substring(with: NSRange(location: start, length: end - start))
        var inString = false
        for character in slice {
            if character == "\"" { inString.toggle() }
            else if !inString, character == ";" { return true }
        }
        return false
    }

    /// The identifier immediately before a `(`, allowing `obj.method` and `a->b`.
    static func calleeName(before offset: Int, in text: NSString) -> String {
        var end = offset
        // Skip whitespace between the name and the parenthesis.
        while end > 0 {
            let character = text.substring(with: NSRange(location: end - 1, length: 1))
            if character == " " || character == "\t" { end -= 1 } else { break }
        }
        var start = end
        while start > 0 {
            let character = text.substring(with: NSRange(location: start - 1, length: 1))
            if character.rangeOfCharacter(from: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "_"))) != nil {
                start -= 1
            } else {
                break
            }
        }
        guard start < end else { return "" }
        let name = text.substring(with: NSRange(location: start, length: end - start))
        // `new Foo(...)` is constructed as a call; the member name is what the
        // server needs to resolve.
        return name
    }
}
