import Foundation

/// One lexical token of a C++ source file.
///
/// Ranges are expressed in the same UTF-16 coordinates that `NSTextStorage`
/// uses, so they can be applied to an `NSLayoutManager` without conversion.
public struct SyntaxToken: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case keyword
        case type
        case number
        case string
        case character
        case comment
        case preprocessor
        case punctuation
        case identifier
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// A single-pass C++ lexer used by the syntax highlighter and by the editor's
/// contextual rules ("am I inside a string or comment?").
///
/// The lexer is deliberately forgiving: it never fails, it just produces fewer
/// tokens for malformed input. That keeps highlighting useful while the user is
/// in the middle of typing.
public enum CppLexer {

    public static let typeKeywords: Set<String> = [
        "auto", "bool", "char", "char8_t", "char16_t", "char32_t", "double",
        "float", "int", "long", "short", "signed", "unsigned", "void",
        "wchar_t", "size_t", "ssize_t", "int8_t", "int16_t", "int32_t",
        "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t"
    ]

    public static let keywords: Set<String> = [
        "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor",
        "break", "case", "catch", "class", "compl", "concept", "consteval",
        "constexpr", "constinit", "const", "const_cast", "continue", "co_await",
        "co_return", "co_yield", "decltype", "default", "delete", "do",
        "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false",
        "final", "for", "friend", "goto", "if", "inline", "mutable", "namespace",
        "new", "noexcept", "not", "not_eq", "nullptr", "operator", "or",
        "or_eq", "override", "private", "protected", "public", "register",
        "reinterpret_cast", "requires", "return", "sizeof", "static",
        "static_assert", "static_cast", "struct", "switch", "template", "this",
        "thread_local", "throw", "true", "try", "typedef", "typeid", "typename",
        "union", "using", "virtual", "volatile", "while", "xor", "xor_eq"
    ]

    /// Tokenizes `text`. Comments, string literals and preprocessor lines are
    /// treated as opaque: nothing inside them is classified further.
    public static func tokenize(_ text: String) -> [SyntaxToken] {
        let scalars = Array(text.unicodeScalars)
        var tokens: [SyntaxToken] = []
        var index = 0
        let count = scalars.count

        // UTF-16 offset of every scalar boundary, so ranges match NSString.
        var utf16Offsets = [Int]()
        utf16Offsets.reserveCapacity(count + 1)
        var running = 0
        for scalar in scalars {
            utf16Offsets.append(running)
            running += scalar.utf16.count
        }
        utf16Offsets.append(running)

        func range(_ start: Int, _ end: Int) -> NSRange {
            NSRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])
        }

        func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || scalar.properties.isAlphabetic
        }

        func isIdentifierBody(_ scalar: Unicode.Scalar) -> Bool {
            isIdentifierStart(scalar) || (scalar.value >= 48 && scalar.value <= 57)
        }

        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 48 && scalar.value <= 57
        }

        var pendingStringPrefix = false

        while index < count {
            let scalar = scalars[index]

            // Whitespace
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
                continue
            }

            // Line comment
            if scalar == "/" && index + 1 < count && scalars[index + 1] == "/" {
                var end = index
                while end < count && scalars[end] != "\n" { end += 1 }
                tokens.append(SyntaxToken(range: range(index, end), kind: .comment))
                index = end
                continue
            }

            // Block comment (unterminated block comments run to end of file)
            if scalar == "/" && index + 1 < count && scalars[index + 1] == "*" {
                var end = index + 2
                while end < count {
                    if scalars[end] == "*" && end + 1 < count && scalars[end + 1] == "/" {
                        end += 2
                        break
                    }
                    end += 1
                }
                tokens.append(SyntaxToken(range: range(index, end), kind: .comment))
                index = end
                continue
            }

            // Preprocessor line (may be continued with a trailing backslash)
            if scalar == "#" {
                var end = index
                while end < count {
                    if scalars[end] == "\n" {
                        var backslash = end - 1
                        if backslash >= index && scalars[backslash] == "\r" { backslash -= 1 }
                        if backslash >= index && scalars[backslash] == "\\" {
                            end += 1
                            continue
                        }
                        break
                    }
                    end += 1
                }
                tokens.append(SyntaxToken(range: range(index, end), kind: .preprocessor))
                index = end
                continue
            }

            // Raw string literal, with optional encoding prefix.
            if let (start, end) = scanRawString(scalars, index: index) {
                tokens.append(SyntaxToken(range: range(start, end), kind: .string))
                index = end
                continue
            }

            // Ordinary string / character literal, with optional encoding prefix
            // (u8"", L"", u"", U"") or user-defined literal suffix handled below.
            if scalar == "\"" || scalar == "'" {
                let isString = scalar == "\""
                var end = index + 1
                while end < count {
                    let current = scalars[end]
                    if current == "\\" {
                        end = min(end + 2, count)
                        continue
                    }
                    if current == scalar {
                        end += 1
                        break
                    }
                    if current == "\n" && !isString { break }
                    end += 1
                }
                tokens.append(SyntaxToken(range: range(index, end), kind: isString ? .string : .character))
                index = end
                continue
            }

            // Number literal (digits, separators, exponent, suffixes)
            if isDigit(scalar) || (scalar == "." && index + 1 < count && isDigit(scalars[index + 1])) {
                var end = index
                while end < count {
                    let current = scalars[end]
                    let isExponentSign = (current == "+" || current == "-")
                        && end > index
                        && (scalars[end - 1] == "e" || scalars[end - 1] == "E"
                            || scalars[end - 1] == "p" || scalars[end - 1] == "P")
                    if isIdentifierBody(current) || current == "." || current == "'" || isExponentSign {
                        end += 1
                    } else {
                        break
                    }
                }
                tokens.append(SyntaxToken(range: range(index, end), kind: .number))
                index = end
                continue
            }

            // Identifier or keyword
            if isIdentifierStart(scalar) {
                var end = index
                while end < count && isIdentifierBody(scalars[end]) { end += 1 }
                let word = String(String.UnicodeScalarView(scalars[index..<end]))
                let kind: SyntaxToken.Kind
                if keywords.contains(word) {
                    kind = .keyword
                } else if typeKeywords.contains(word) {
                    kind = .type
                } else {
                    kind = .identifier
                }
                tokens.append(SyntaxToken(range: range(index, end), kind: kind))
                index = end
                pendingStringPrefix = false
                continue
            }

            // Punctuation and operators
            if "{}()[];,.:?~!+-*/%^&|=<>".unicodeScalars.contains(scalar) {
                tokens.append(SyntaxToken(range: range(index, index + 1), kind: .punctuation))
                index += 1
                continue
            }

            index += 1
            pendingStringPrefix = false
        }

        _ = pendingStringPrefix
        return tokens
    }

    /// Scans a raw string literal starting at `index` if one begins there.
    /// Matches `R"delimiter( ... )delimiter"` plus the `u8R`, `uR`, `UR`, `LR`
    /// prefixes.
    private static func scanRawString(_ scalars: [Unicode.Scalar], index: Int) -> (Int, Int)? {
        var cursor = index
        // Optional encoding prefix.
        if cursor < scalars.count, "uUL".unicodeScalars.contains(scalars[cursor]) {
            if cursor + 1 < scalars.count, scalars[cursor + 1] == "8" {
                cursor += 2
            } else if cursor + 1 < scalars.count, scalars[cursor + 1] == "R" {
                cursor += 1
            } else {
                return nil
            }
        }
        guard cursor < scalars.count, scalars[cursor] == "R" else { return nil }
        cursor += 1
        guard cursor < scalars.count, scalars[cursor] == "\"" else { return nil }
        cursor += 1

        // Delimiter: up to 16 characters, no whitespace, no parens, no backslash.
        var delimiter = ""
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == "(" { break }
            if delimiter.count >= 16 { return nil }
            if scalar == " " || scalar == "\\" || scalar == ")" || scalar == ";" { return nil }
            delimiter.unicodeScalars.append(scalar)
            cursor += 1
        }
        guard cursor < scalars.count, scalars[cursor] == "(" else { return nil }
        cursor += 1

        // Look for `)delimiter"`.
        let closing = Array((")" + delimiter + "\"").unicodeScalars)
        var scan = cursor
        while scan + closing.count <= scalars.count {
            var offset = 0
            var matches = true
            while offset < closing.count {
                if scalars[scan + offset] != closing[offset] {
                    matches = false
                    break
                }
                offset += 1
            }
            if matches {
                return (index, scan + closing.count)
            }
            scan += 1
        }
        return (index, scalars.count)
    }

    /// Returns true when `location` sits inside a comment, a string or a
    /// character literal. Used to skip bracket pairing inside them.
    public static func isInsideLiteralOrComment(_ tokens: [SyntaxToken], at location: Int) -> Bool {
        for token in tokens {
            guard location >= token.range.location, location < NSMaxRange(token.range) else {
                if token.range.location > location { return false }
                continue
            }
            switch token.kind {
            case .comment, .string, .character, .preprocessor:
                return true
            default:
                return false
            }
        }
        return false
    }
}
