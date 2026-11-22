import Foundation

/// Editor behaviour that the edit planner needs. Mirrors the subset of the
/// user-facing settings that change how typing behaves.
public struct EditSettings: Equatable, Sendable {
    public var indentWidth: Int
    public var indentWithTabs: Bool
    public var autoPair: Bool
    public var autoIndent: Bool
    public var autoPairAngles: Bool

    public init(indentWidth: Int = 4,
                indentWithTabs: Bool = false,
                autoPair: Bool = true,
                autoIndent: Bool = true,
                autoPairAngles: Bool = false) {
        self.indentWidth = max(1, indentWidth)
        self.indentWithTabs = indentWithTabs
        self.autoPair = autoPair
        self.autoIndent = autoIndent
        self.autoPairAngles = autoPairAngles
    }

    /// The whitespace inserted for one indentation level.
    public var indentUnit: String {
        indentWithTabs ? "\t" : String(repeating: " ", count: indentWidth)
    }

    /// One level of indentation removed from the start of a line, preferring the
    /// editor's own unit and falling back to a single tab or one space.
    public func outdent(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let spaces = line.prefix { $0 == " " }.count
        let removeCount = min(spaces, indentWidth)
        if removeCount > 0 { return String(line.dropFirst(removeCount)) }
        return line
    }
}

/// A user edit that may be adjusted by the editor's smart behaviour.
public enum EditCommand: Equatable, Sendable {
    case insert(String)
    case newline
    case tab
    case backtab
    case deleteBackward
    case toggleComment
}

/// The outcome of running an `EditCommand` through the planner.
public struct EditOutcome: Equatable, Sendable {
    public let text: String
    /// Selection to restore after the edit, in UTF-16 offsets.
    public let selection: NSRange
    /// False when the command produced no change at all (caller should do nothing).
    public let changed: Bool

    public init(text: String, selection: NSRange, changed: Bool) {
        self.text = text
        self.selection = selection
        self.changed = changed
    }
}

/// Pure, testable implementation of the editor's automatic behaviour:
/// bracket/quote pairing, auto-indent, tab handling and comment toggling.
///
/// Everything here works on plain `String` + UTF-16 `NSRange` so it can be unit
/// tested without an AppKit text view.
public enum EditPlanner {

    public static let openingPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
    public static let closingPairs: [Character: Character] = [")": "(", "]": "[", "}": "{", "\"": "\"", "'": "'"]
    public static let angleOpening: Character = "<"
    public static let angleClosing: Character = ">"

    public static func apply(_ command: EditCommand,
                             to text: String,
                             selection: NSRange,
                             settings: EditSettings) -> EditOutcome {
        let clamp = clampRange(selection, in: text)
        switch command {
        case .insert(let typed):
            return insert(typed, into: text, selection: clamp, settings: settings)
        case .newline:
            return newline(in: text, selection: clamp, settings: settings)
        case .tab:
            return tab(in: text, selection: clamp, settings: settings)
        case .backtab:
            return outdentLines(in: text, selection: clamp, settings: settings)
        case .deleteBackward:
            return deleteBackward(in: text, selection: clamp, settings: settings)
        case .toggleComment:
            return toggleComment(in: text, selection: clamp, settings: settings)
        }
    }

    // MARK: - Insert

    private static func insert(_ typed: String, into text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        let ns = text as NSString
        let mutable = NSMutableString(string: text)

        // Only single typed characters take part in pairing; pastes and IME
        // commits go straight in.
        guard typed.count == 1, let character = typed.first else {
            mutable.replaceCharacters(in: selection, with: typed)
            let cursor = selection.location + (typed as NSString).length
            return EditOutcome(text: mutable as String,
                               selection: NSRange(location: cursor, length: 0),
                               changed: true)
        }

        let tokens = CppLexer.tokenize(text)
        let insideLiteral = CppLexer.isInsideLiteralOrComment(tokens, at: selection.location)

        // 1. Type-through: typing a closing character when the same character is
        //    already right after the caret just moves the caret over it.
        if selection.length == 0, !insideLiteral,
           let opener = closingPairs[character],
           isPairCharacter(matching: opener, settings: settings),
           selection.location < ns.length,
           ns.character(at: selection.location) == (String(character) as NSString).character(at: 0) {
            return EditOutcome(text: text,
                               selection: NSRange(location: selection.location + 1, length: 0),
                               changed: false)
        }

        // 2. A non-empty single-line selection gets wrapped by an opening character.
        if settings.autoPair,
           selection.length > 0,
           let closer = openingPairs[character],
           isPairCharacter(matching: character, settings: settings),
           !insideLiteral,
           canWrap(selection: selection, in: ns) {
            mutable.replaceCharacters(in: selection, with: "\(character)\(ns.substring(with: selection))\(closer)")
            return EditOutcome(text: mutable as String,
                               selection: NSRange(location: selection.location, length: selection.length + 2),
                               changed: true)
        }

        // 3. Auto-close an opening character when what follows allows it.
        if settings.autoPair,
           let closer = openingPairs[character],
           isPairCharacter(matching: character, settings: settings),
           !insideLiteral,
           selection.length == 0,
           shouldAutoClose(character, at: selection.location, in: ns) {
            mutable.replaceCharacters(in: selection, with: "\(character)\(closer)")
            return EditOutcome(text: mutable as String,
                               selection: NSRange(location: selection.location + 1, length: 0),
                               changed: true)
        }

        // 4. Typing `}` on an otherwise blank, indented line outdents that line
        //    so the brace lines up with the block opener.
        if settings.autoIndent, character == "}", selection.length == 0 {
            let line = lineRange(at: selection.location, in: ns)
            let prefixRange = NSRange(location: line.location, length: selection.location - line.location)
            let prefix = ns.substring(with: prefixRange)
            if !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let outdented = settings.outdent(prefix)
                if outdented != prefix {
                    let lineText = ns.substring(with: line)
                    let contentLength = TextCoordinates.contentLength(of: line, in: ns)
                    let content = ns.substring(with: NSRange(location: line.location, length: contentLength))
                    let newLine = outdented + "}" + String(content.dropFirst(prefix.utf16.count))
                    mutable.replaceCharacters(in: line, with: newLine + String(lineText.dropFirst(contentLength)))
                    let cursor = line.location + (outdented as NSString).length + 1
                    return EditOutcome(text: mutable as String,
                                       selection: NSRange(location: cursor, length: 0),
                                       changed: true)
                }
            }
        }

        mutable.replaceCharacters(in: selection, with: typed)
        return EditOutcome(text: mutable as String,
                           selection: NSRange(location: selection.location + 1, length: 0),
                           changed: true)
    }

    private static func isPairCharacter(matching character: Character, settings: EditSettings) -> Bool {
        if character == angleOpening || character == angleClosing {
            return settings.autoPairAngles
        }
        return openingPairs[character] != nil || closingPairs[character] != nil
    }

    private static func canWrap(selection: NSRange, in ns: NSString) -> Bool {
        !ns.substring(with: selection).contains("\n")
    }

    private static func shouldAutoClose(_ character: Character, at location: Int, in ns: NSString) -> Bool {
        guard location < ns.length else { return true }
        let nextRange = ns.rangeOfComposedCharacterSequence(at: location)
        guard let nextScalar = ns.substring(with: nextRange).unicodeScalars.first else { return true }

        if nextScalar == " " || nextScalar == "\t" || nextScalar == "\n" || nextScalar == "\r" {
            return true
        }
        if nextScalar.properties.isAlphabetic || (nextScalar.value >= 48 && nextScalar.value <= 57) || nextScalar == "_" {
            // Brackets stay useful in front of a word; quotes do not.
            return character != "\"" && character != "'"
        }
        if CharacterSet(charactersIn: ")]};,").contains(nextScalar) {
            return true
        }
        if nextScalar == "\"" || nextScalar == "'" {
            return false
        }
        return true
    }

    // MARK: - Newline

    private static func newline(in text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        let ns = text as NSString
        let mutable = NSMutableString(string: text)

        if !settings.autoIndent {
            mutable.replaceCharacters(in: selection, with: "\n")
            return EditOutcome(text: mutable as String,
                               selection: NSRange(location: selection.location + 1, length: 0),
                               changed: true)
        }

        let line = lineRange(at: selection.location, in: ns)
        let beforeCursor = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let afterCursor = ns.substring(with: NSRange(location: NSMaxRange(selection),
                                                     length: max(0, NSMaxRange(line) - NSMaxRange(selection))))
        let leading = String(beforeCursor.prefix { $0 == " " || $0 == "\t" })
        let trimmedBefore = beforeCursor.trimmingCharacters(in: .whitespaces)
        let trimmedAfter = afterCursor.trimmingCharacters(in: .whitespaces)

        // `{|}` — expand into a three-line block with the caret in the middle.
        if selection.length == 0,
           trimmedBefore.hasSuffix("{"),
           trimmedAfter.hasPrefix("}") {
            let innerIndent = leading + settings.indentUnit
            let inserted = "\n" + innerIndent + "\n" + leading
            mutable.replaceCharacters(in: selection, with: inserted)
            let cursor = selection.location + 1 + (innerIndent as NSString).length
            return EditOutcome(text: mutable as String,
                               selection: NSRange(location: cursor, length: 0),
                               changed: true)
        }

        // Otherwise inherit this line's indentation, plus a level after `{`.
        var indent = leading
        if trimmedBefore.hasSuffix("{") {
            indent += settings.indentUnit
        }
        let inserted = "\n" + indent
        mutable.replaceCharacters(in: selection, with: inserted)
        return EditOutcome(text: mutable as String,
                           selection: NSRange(location: selection.location + (inserted as NSString).length, length: 0),
                           changed: true)
    }

    // MARK: - Tab / Shift-Tab

    private static func tab(in text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        if selection.length > 0 {
            return indentLines(in: text, selection: selection, settings: settings)
        }
        let mutable = NSMutableString(string: text)
        mutable.insert(settings.indentUnit, at: selection.location)
        return EditOutcome(text: mutable as String,
                           selection: NSRange(location: selection.location + settings.indentUnit.utf16.count, length: 0),
                           changed: true)
    }

    private static func indentLines(in text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        let ns = text as NSString
        let ranges = lineRanges(covering: selection, in: ns)
        let contents = contentRanges(for: ranges, in: ns)
        let replacements = contents.map { settings.indentUnit + ns.substring(with: $0) }
        guard let (newText, newSelection) = applyLineReplacements(in: text,
                                                                  contentRanges: contents,
                                                                  replacements: replacements,
                                                                  selection: selection) else {
            return EditOutcome(text: text, selection: selection, changed: false)
        }
        return EditOutcome(text: newText, selection: newSelection, changed: true)
    }

    private static func outdentLines(in text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        let ns = text as NSString
        let ranges = lineRanges(covering: selection, in: ns)
        let contents = contentRanges(for: ranges, in: ns)
        let replacements = contents.map { settings.outdent(ns.substring(with: $0)) }
        guard replacements.contains(where: { line in line != "" }) else {
            return EditOutcome(text: text, selection: selection, changed: false)
        }
        guard let (newText, newSelection) = applyLineReplacements(in: text,
                                                                  contentRanges: contents,
                                                                  replacements: replacements,
                                                                  selection: selection) else {
            return EditOutcome(text: text, selection: selection, changed: false)
        }
        return EditOutcome(text: newText, selection: newSelection, changed: true)
    }

    // MARK: - Delete

    private static func deleteBackward(in text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        let ns = text as NSString
        let mutable = NSMutableString(string: text)

        if selection.length > 0 {
            mutable.replaceCharacters(in: selection, with: "")
            return EditOutcome(text: mutable as String,
                               selection: NSRange(location: selection.location, length: 0),
                               changed: true)
        }
        guard selection.location > 0, selection.location <= ns.length else {
            return EditOutcome(text: text, selection: selection, changed: false)
        }

        // Empty pair: `()`, `[]`, `{}`, `""`, `''`
        if settings.autoPair, selection.location < ns.length {
            let before = ns.substring(with: NSRange(location: selection.location - 1, length: 1))
            let after = ns.substring(with: NSRange(location: selection.location, length: 1))
            if let opener = before.first,
               let closer = openingPairs[opener],
               after == String(closer) {
                mutable.replaceCharacters(in: NSRange(location: selection.location - 1, length: 2), with: "")
                return EditOutcome(text: mutable as String,
                                   selection: NSRange(location: selection.location - 1, length: 0),
                                   changed: true)
            }
        }

        // Outdent when only whitespace precedes the caret on its line.
        if settings.autoIndent {
            let line = lineRange(at: selection.location, in: ns)
            let prefix = ns.substring(with: NSRange(location: line.location,
                                                    length: selection.location - line.location))
            if !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let outdented = settings.outdent(prefix)
                let removed = prefix.utf16.count - outdented.utf16.count
                if removed > 0 {
                    mutable.replaceCharacters(in: NSRange(location: line.location, length: removed), with: "")
                    return EditOutcome(text: mutable as String,
                                       selection: NSRange(location: selection.location - removed, length: 0),
                                       changed: true)
                }
            }
        }

        mutable.deleteCharacters(in: NSRange(location: selection.location - 1, length: 1))
        return EditOutcome(text: mutable as String,
                           selection: NSRange(location: selection.location - 1, length: 0),
                           changed: true)
    }

    // MARK: - Comments

    private static func toggleComment(in text: String, selection: NSRange, settings: EditSettings) -> EditOutcome {
        let ns = text as NSString
        let ranges = lineRanges(covering: selection, in: ns)
        let contents = contentRanges(for: ranges, in: ns)
        let lines = contents.map { ns.substring(with: $0) }

        let contentIndices = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !contentIndices.isEmpty else {
            return EditOutcome(text: text, selection: selection, changed: false)
        }

        let allCommented = contentIndices.allSatisfy { index in
            lines[index].drop { $0 == " " || $0 == "\t" }.hasPrefix("//")
        }

        var replacements = lines
        if allCommented {
            for index in contentIndices {
                let line = lines[index]
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var rest = line.dropFirst(indent.count)
                rest = rest.dropFirst(2)
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                replacements[index] = String(indent) + String(rest)
            }
        } else {
            // Comment at the column of the shallowest non-blank line.
            let column = contentIndices.map { index -> Int in
                lines[index].prefix { $0 == " " || $0 == "\t" }.utf16.count
            }.min() ?? 0
            for index in contentIndices {
                let line = lines[index]
                guard !line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") else { continue }
                let cut = String.Index(utf16Offset: column, in: line)
                replacements[index] = String(line[..<cut]) + "// " + String(line[cut...])
            }
        }

        guard let (newText, newSelection) = applyLineReplacements(in: text,
                                                                  contentRanges: contents,
                                                                  replacements: replacements,
                                                                  selection: selection) else {
            return EditOutcome(text: text, selection: selection, changed: false)
        }
        return EditOutcome(text: newText, selection: newSelection, changed: true)
    }

    // MARK: - Range helpers

    public static func clampRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, range.location), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }

    public static func lineRange(at location: Int, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = min(max(0, location), ns.length)
        return ns.lineRange(for: NSRange(location: clamped, length: 0))
    }

    /// Every line touched by `selection`, in document order, each including its
    /// line terminator (if any). A non-empty selection that ends exactly at the
    /// start of a line does not include that following line.
    public static func lineRanges(covering selection: NSRange, in ns: NSString) -> [NSRange] {
        guard ns.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let clamped = clampRange(selection, in: ns as String)
        let first = lineRange(at: clamped.location, in: ns)
        let lastLocation: Int
        if clamped.length > 0 {
            lastLocation = min(NSMaxRange(clamped) - 1, ns.length - 1)
        } else {
            lastLocation = clamped.location
        }
        let last = lineRange(at: max(lastLocation, first.location), in: ns)

        var ranges: [NSRange] = []
        var cursor = first.location
        while cursor <= last.location {
            let range = lineRange(at: cursor, in: ns)
            ranges.append(range)
            let next = NSMaxRange(range)
            if next <= cursor { break }
            cursor = next
        }
        return ranges.isEmpty ? [first] : ranges
    }

    /// Line ranges with their terminators stripped.
    static func contentRanges(for ranges: [NSRange], in ns: NSString) -> [NSRange] {
        ranges.map { NSRange(location: $0.location, length: TextCoordinates.contentLength(of: $0, in: ns)) }
    }

    /// Replaces each content range with its replacement text, keeping line
    /// terminators untouched, and maps `selection` through the edit.
    static func applyLineReplacements(in text: String,
                                      contentRanges: [NSRange],
                                      replacements: [String],
                                      selection: NSRange) -> (String, NSRange)? {
        guard contentRanges.count == replacements.count else { return nil }
        let result = NSMutableString(string: text)
        var deltaBeforeCaret = 0
        for index in contentRanges.indices.reversed() {
            let range = contentRanges[index]
            let replacement = replacements[index]
            let delta = (replacement as NSString).length - range.length
            if delta != 0, range.location < selection.location {
                deltaBeforeCaret += delta
            }
            result.replaceCharacters(in: range, with: replacement)
        }
        let newCaret = max(0, selection.location + deltaBeforeCaret)
        let newText = result as String
        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: min(newCaret, (newText as NSString).length), length: 0)
        } else {
            newSelection = clampRange(NSRange(location: selection.location,
                                              length: max(0, selection.length + (newCaret - selection.location))),
                                      in: newText)
        }
        return (newText, newSelection)
    }
}
