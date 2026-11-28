import AppKit
import EditorCore

// MARK: - Inlay hints

/// Draws clangd's advisory labels — `name:` on call arguments, `: int` on deduced
/// types — inside the code the way CLion does, with the text pushed aside so the
/// label sits in its own space.
///
/// Why attachments and not a drawing pass: TextKit will happily *paint* at a
/// position, but it does not move anything aside for it, so a drawn label lands
/// on top of the code. An `NSTextAttachment` is the only mechanism that makes the
/// layout leave room.
///
/// The attachments live in the *display* text storage and never in the document:
/// the editor keeps the real text aside while hints are shown, so what gets saved,
/// copied or compiled never contains them. Any edit drops the hints and restores
/// the document exactly.
extension CodeTextView {

    /// Labels currently shown.
    public var inlayHintItems: [InlayHintItem] { inlayState.items }

    /// Shows `hints`, pushing the code aside to make room for each label.
    public func setInlayHints(_ hints: [LSPInlayHint]) {
        showLabels(hints)
    }

    /// Removes every label and restores the document text.
    public func clearInlayHints() {
        removeLabels()
    }

    /// True while labels occupy space in the display text.
    var hasInlayLabelAttachments: Bool { inlayState.applied }
}

/// One label to draw.
public struct InlayHintItem: Equatable, Sendable {
    /// Character offset of the original text the label sits before.
    public let offset: Int
    public let text: String
    public let isParameter: Bool
}

// MARK: - Display/real text separation

extension CodeTextView {

    /// The document text with the labels spliced in.
    ///
    /// Built fresh from `lastDisplayedSource` each time so a stale attachment can
    /// never survive into a later render.
    func showLabels(_ hints: [LSPInlayHint]) {
        let source = currentSourceText()
        guard !hints.isEmpty else {
            removeLabels()
            return
        }
        let ns = source as NSString
        let font = NSFont.systemFont(ofSize: max(9, (self.font?.pointSize ?? 13) - 1))
        // Attachments are inserted back to front so earlier offsets stay valid.
        let sorted = hints.compactMap { hint -> (Int, String)? in
            guard let offset = Self.utf16Offset(of: hint.position, in: ns) else { return nil }
            return (offset, hint.text)
        }.sorted { $0.0 > $1.0 }

        let display = NSMutableAttributedString(string: source, attributes: [
            .font: self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: textColor ?? NSColor.labelColor
        ])
        var inserted: [(offset: Int, text: String)] = []
        for (offset, text) in sorted {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = InlayHintCell(label: text, hintFont: font)
            display.insert(NSAttributedString(attachment: attachment), at: offset)
            inserted.append((offset, text))
        }

        // Remember the real text *before* swapping, so it can be restored.
        if !inlayState.applied {
            inlayState.sourceText = source
        }
        inlayState.applied = true
        inlayState.items = inserted.reversed().map {
            InlayHintItem(offset: $0.offset, text: $0.text, isParameter: $0.text.hasSuffix(":"))
        }

        let selection = selectedRange()
        silentlyReplaceDisplayText(display)
        // The caret sat before `offset` attachments; move it past the ones that
        // were inserted before it so it stays where the user put it.
        let shift = inserted.filter { $0.offset < selection.location }.count
        setSelectedRange(NSRange(location: min(selection.location + shift, (string as NSString).length),
                                 length: selection.length))
    }

    /// Puts the document text back and drops every label.
    func removeLabels() {
        guard inlayState.applied else { return }
        inlayState.applied = false
        inlayState.items = []
        guard let original = inlayState.sourceText else { return }
        inlayState.sourceText = nil
        // Only restore if the display has not drifted; an edit already re-synced.
        let selection = selectedRange()
        silentlyReplaceDisplayText(NSAttributedString(string: original, attributes: [
            .font: self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: textColor ?? NSColor.labelColor
        ]))
        setSelectedRange(NSRange(location: min(selection.location, (original as NSString).length),
                                 length: 0))
    }

    /// Replaces the storage without notifying undo, the delegate, or the app.
    ///
    /// Labels are cosmetic, so this must not look like an edit: no dirty flag, no
    /// undo entry, no unsaved-changes prompt.
    private func silentlyReplaceDisplayText(_ attributed: NSAttributedString) {
        guard let textStorage else { return }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: attributed)
        textStorage.endEditing()
    }

    /// The document's text, ignoring any attachment currently in the display.
    public func currentSourceText() -> String {
        inlayState.applied ? (inlayState.sourceText ?? string) : string
    }

    /// UTF-16 offset of an LSP position.
    static func utf16Offset(of position: LSPPosition, in text: NSString) -> Int? {
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

/// Draws a grey label in the space an attachment occupies.
final class InlayHintCell: NSTextAttachmentCell {

    private let label: String
    private let hintFont: NSFont

    init(label: String, hintFont: NSFont) {
        self.label = label
        self.hintFont = hintFont
        super.init()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize {
        let size = (label as NSString).size(withAttributes: [.font: hintFont])
        // A little breathing room so the label does not touch the code it precedes.
        return NSSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -2)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        (label as NSString).draw(at: NSPoint(x: cellFrame.minX, y: cellFrame.minY),
                                 withAttributes: [.font: hintFont,
                                                  .foregroundColor: EditorTheme.inlayHint])
    }
}

/// Mutable inlay-label state, kept beside the view.
final class InlayHintState {
    var items: [InlayHintItem] = []
    var applied = false
    var sourceText: String?
}
