import AppKit
import EditorCore

// MARK: - Inlay hints

/// Draws clangd's advisory labels — `name:` on call arguments, `: int` on deduced
/// types — inside the code, with the text pushed aside so each label has room.
///
/// How the space is made matters. Putting attachments in the text storage works,
/// but it puts characters into the document that are not in the file: every edit,
/// undo entry and cursor position then has to be translated, and `NSTextStorage`
/// edits made from outside the text view corrupt the undo stack outright.
///
/// A `.kern` attribute on a single existing character reserves the same width and
/// changes no text at all. Attributes are also not part of the undo stack, so ⌘Z
/// keeps undoing what the user typed. This is the approach CLion-style hints need:
/// the layout is the only thing touched.
extension CodeTextView {

    /// Labels currently reserving space.
    public var inlayHintItems: [InlayHintItem] { inlayState.items }

    /// Shows `hints`, reserving room for each label and drawing it in that room.
    public func setInlayHints(_ hints: [LSPInlayHint]) {
        showLabels(hints)
    }

    /// Removes every label and releases the reserved space.
    public func clearInlayHints() {
        releaseLabelSpace()
        inlayState.items = []
        needsDisplay = true
    }

    /// True while labels are on screen.
    var hasInlayLabels: Bool { !inlayState.items.isEmpty }

    /// The document's text; labels never change it now, but callers still use this
    /// so the contract does not depend on that staying true.
    public func currentSourceText() -> String { string }
}

// MARK: - Reserving space

extension CodeTextView {

    func showLabels(_ hints: [LSPInlayHint]) {
        guard !hints.isEmpty else {
            clearInlayHints()
            return
        }
        let ns = string as NSString
        let font = NSFont.systemFont(ofSize: max(9, (font?.pointSize ?? 13) - 1))
        var items: [InlayHintItem] = []
        for hint in hints {
            // clangd names anonymous members `u1`, `u2`, … and decorates them with
            // the punctuation around them; those read as noise, not as a name.
            guard let label = Self.readableLabel(hint.text),
                  let offset = Self.utf16Offset(of: hint.position, in: ns) else { continue }
            let width = (label as NSString).size(withAttributes: [.font: font]).width + 3
            items.append(InlayHintItem(offset: offset, text: label, width: ceil(width)))
        }
        items.sort { $0.offset < $1.offset }
        inlayState.items = items
        reserveSpace()
        needsDisplay = true
    }

    /// Puts a kern on the character preceding each label.
    ///
    /// Kern is applied to the *previous* character so the label reads as sitting
    /// immediately before the token it describes. A label at the very start of a
    /// line has no preceding character, so it is skipped rather than kerned onto
    /// the line above.
    func reserveSpace() {
        guard let storage = textStorage else { return }
        let length = storage.length
        // An attribute change is not an edit: it keeps the text and the undo stack
        // as they are, which a temporary attribute fails to do here — TextKit does
        // not relayout for a temporary `.kern`, so the glyphs never move and the
        // label lands on the code.
        withoutUndoOnStorage {
            if length > 0 {
                storage.removeAttribute(.kern, range: NSRange(location: 0, length: length))
            }
            let text = string as NSString
            for item in inlayState.items {
                let anchor = item.offset - 1
                guard anchor >= 0, anchor < length else { continue }
                // A newline has no glyph to carry spacing.
                guard text.character(at: anchor) != 10 else { continue }
                storage.addAttribute(.kern, value: item.width,
                                     range: NSRange(location: anchor, length: 1))
            }
        }
        if length > 0 {
            layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length),
                                            actualCharacterRange: nil)
        }
    }

    /// Runs `body` with undo registration off and outside the current group.
    ///
    /// An attribute edit would otherwise be folded into the group the user's typing
    /// is in, which made one ⌘Z undo only part of an edit.
    private func withoutUndoOnStorage(_ body: () -> Void) {
        guard let manager = undoManager else {
            body()
            return
        }
        var reopened = 0
        while manager.groupingLevel > 0 {
            manager.endUndoGrouping()
            reopened += 1
        }
        manager.disableUndoRegistration()
        body()
        manager.enableUndoRegistration()
        for _ in 0..<reopened { manager.beginUndoGrouping() }
    }

    /// Drops the reserved space.
    func releaseLabelSpace() {
        // Nothing reserved: touching the storage here would be a pointless
        // attribute edit on every keystroke.
        guard !inlayState.items.isEmpty, let storage = textStorage, storage.length > 0 else { return }
        withoutUndoOnStorage {
            storage.removeAttribute(.kern, range: NSRange(location: 0, length: storage.length))
        }
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                        actualCharacterRange: nil)
    }

    /// Draws each label into the space reserved for it.
    func drawInlayLabels() {
        guard !inlayState.items.isEmpty,
              let layoutManager, let container = textContainer else { return }
        let base = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: max(9, base.pointSize - 1))
        let origin = textContainerOrigin
        let text = string as NSString
        for item in inlayState.items {
            let anchor = item.offset - 1
            guard anchor >= 0, anchor < text.length, text.character(at: anchor) != 10 else { continue }
            // Draw inside the gap the kern opened. Measured layout: the gap runs
            // from the anchor glyph's origin to the next glyph's origin, and the
            // anchor character still occupies its own advance at the start of it —
            // so the label begins one advance past the anchor, not at its origin.
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let anchorOrigin = layoutManager.location(forGlyphAt: glyph).x
            let anchorWidth = (text.substring(with: NSRange(location: anchor, length: 1)) as NSString)
                .size(withAttributes: [.font: base]).width
            let x = origin.x + anchorOrigin + anchorWidth + 1
            let y = origin.y + fragment.minY + (fragment.height - labelFont.ascender) / 2
            _ = base
            (item.text as NSString).draw(at: NSPoint(x: x, y: y),
                                         withAttributes: [.font: labelFont,
                                                          .foregroundColor: EditorTheme.inlayHint])
        }
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

    /// Trims a hint label to what is worth showing.
    ///
    /// clangd wraps synthetic names in the surrounding punctuation — `{&u1:` for an
    /// anonymous pair member — and reuses names like `u1` that mean nothing to a
    /// reader. Returning nil drops the label entirely.
    static func readableLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "{}&* "))
        guard !trimmed.isEmpty else { return nil }
        let name = trimmed.split(separator: ":").first.map(String.init) ?? trimmed
        if name.count >= 2, name.first == "u", name.dropFirst().allSatisfy({ $0.isNumber }) {
            return nil
        }
        return trimmed
    }
}

/// One label to draw.
public struct InlayHintItem: Equatable, Sendable {
    /// Character offset the label sits before.
    public let offset: Int
    public let text: String
    /// Space reserved for it, in points.
    public let width: CGFloat
}

/// Mutable inlay-label state, kept beside the view.
final class InlayHintState {
    var items: [InlayHintItem] = []
}
