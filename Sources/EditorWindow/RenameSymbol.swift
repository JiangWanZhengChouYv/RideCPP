import AppKit
import EditorCore

// MARK: - Rename

/// Runs a rename for the symbol at the caret.
///
/// The dialog here only collects a name; the edits come from the language server
/// and are applied as one undoable change, so ⌘Z puts every reference back at
/// once rather than removing them one at a time.
extension CodeTextView {

    /// Asks for a new name and hands it to `apply`.
    ///
    /// `current` is the identifier under the caret, used to prefill the field so
    /// the user edits a name rather than retyping it.
    /// `texts` supplies the dialog's strings: this module sits below the app layer
    /// and cannot read its localization table.
    public struct RenameTexts {
        public let title: String
        public let message: String
        public let placeholder: String
        public let confirm: String
        public let cancel: String

        public init(title: String, message: String, placeholder: String,
                    confirm: String, cancel: String) {
            self.title = title
            self.message = message
            self.placeholder = placeholder
            self.confirm = confirm
            self.cancel = cancel
        }
    }

    public func promptForRename(current: String, texts: RenameTexts,
                                apply: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = texts.title
        alert.informativeText = texts.message
        alert.addButton(withTitle: texts.confirm)
        alert.addButton(withTitle: texts.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = texts.placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        // An unchanged or empty name is not a rename; an identifier with spaces
        // would not compile, so it is rejected rather than inserted.
        guard !newName.isEmpty, newName != current,
              newName.rangeOfCharacter(from: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "_"))) != nil,
              newName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return
        }
        apply(newName)
    }

    /// Replaces every given range with its new text in one undoable edit.
    ///
    /// Applied back to front so earlier ranges keep their offsets, and through the
    /// text storage as a single replacement so the undo stack sees one action.
    public func applyRenameEdits(_ edits: [LSPTextEdit]) -> Bool {
        guard !edits.isEmpty, let layoutManager, let textStorage else { return false }
        let old = string
        let ns = old as NSString
        var resolved: [(range: NSRange, text: String)] = []
        for edit in edits {
            // Only this document's offsets are meaningful here.
            guard let start = Self.offset(of: edit.range.start, in: ns),
                  let end = Self.offset(of: edit.range.end, in: ns),
                  end >= start else { continue }
            resolved.append((NSRange(location: start, length: end - start), edit.newText))
        }
        guard !resolved.isEmpty else { return false }
        // A single pass over the immutable string, then one storage update.
        var result = old
        for edit in resolved.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(edit.range, in: result) else { continue }
            result.replaceSubrange(range, with: edit.text)
        }
        guard result != old else { return false }
        let whole = NSRange(location: 0, length: ns.length)
        guard shouldChangeText(in: whole, replacementString: result) else { return false }
        textStorage.replaceCharacters(in: whole, with: result)
        didChangeText()
        // The caret moved with the text; keep it on screen.
        setSelectedRange(NSRange(location: min(selectedRange().location,
                                               (result as NSString).length), length: 0))
        _ = layoutManager
        return true
    }

    /// UTF-16 offset for an LSP position.
    static func offset(of position: LSPPosition, in text: NSString) -> Int? {
        var line = 0
        var index = 0
        while line < position.line {
            let found = text.range(of: "\n", options: [],
                                   range: NSRange(location: index, length: text.length - index))
            if found.location == NSNotFound { return nil }
            index = found.location + 1
            line += 1
        }
        let result = index + position.character
        return result <= text.length ? result : nil
    }
}
