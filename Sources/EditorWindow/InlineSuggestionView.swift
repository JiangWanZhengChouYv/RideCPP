import AppKit

/// Shows a predicted continuation as ghost text after the caret.
///
/// Drawn inside the text view rather than as a floating panel: a suggestion
/// belongs to the line it continues, must scroll with it, and must never steal
/// focus or appear over another application. Inline drawing gives all three for
/// free.
///
/// The text is *not* inserted. It exists only as a hint until the user presses
/// Tab, which keeps the document — and the undo history — free of text the user
/// never chose.
public final class InlineSuggestionView {

    /// The suggestion currently offered, and where it would be inserted.
    public private(set) var text: String = ""
    /// Character offset the suggestion is anchored at.
    public private(set) var anchor: Int = 0
    /// Multi-line suggestions are drawn as a single preview line.
    private(set) var isMultiLine = false

    public var isVisible: Bool { !text.isEmpty }

    /// Replaces the current suggestion.
    ///
    /// Rejections are silent: a continuation that does not start where the caret
    /// is now, or that is already present, is simply dropped.
    public func offer(_ suggestion: String, at offset: Int) {
        // Only trailing whitespace is dropped: the leading space is meaningful,
        // since `for` followed by ` (int i...` must not become `for(int`.
        let normalised = suggestion.replacingOccurrences(of: "\r\n", with: "\n")
        let cleaned = String(normalised.reversed().drop { $0.isWhitespace }.reversed())
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clear()
            return
        }
        text = cleaned
        anchor = offset
        isMultiLine = cleaned.contains("\n")
    }

    public func clear() {
        text = ""
        isMultiLine = false
    }

    /// Advance the anchor after the user typed inside the suggestion's line.
    ///
    /// Without this the ghost text slides one character to the left on every
    /// keystroke, which makes it look like it is running away.
    public func shiftAnchor(by delta: Int) {
        guard isVisible else { return }
        anchor = max(0, anchor + delta)
    }

    /// Draws the ghost text at the caret.
    ///
    /// - Parameter caretScreenRect: the caret's rect in the text view's own
    ///   coordinates, already including the container inset.
    public func draw(in textView: NSTextView, caretRect: NSRect, font: NSFont) {
        guard isVisible else { return }
        // Only the first line is previewed: ghost text that wrapped would cover
        // the code below it.
        let preview = isMultiLine
            ? String(text[text.startIndex..<(text.firstIndex(of: "\n") ?? text.endIndex)])
            : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let origin = NSPoint(x: caretRect.maxX, y: caretRect.minY + (caretRect.height - font.ascender) / 4)
        (preview as NSString).draw(at: origin, withAttributes: attributes)

        if isMultiLine {
            // A small marker so the user knows Tab brings in more than one line.
            let marker = " ⏎"
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: font.pointSize * 0.7),
                .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.8)
            ]
            let width = (preview as NSString).size(withAttributes: attributes).width
            (marker as NSString).draw(at: NSPoint(x: origin.x + width + 2, y: origin.y),
                                       withAttributes: markerAttributes)
        }
    }
}
