import AppKit
import EditorCore

// MARK: - Inline suggestions

/// Accepting, dismissing and scheduling the predicted continuation.
///
/// Split out of the main class body to stay within the file budget; the state
/// it touches lives on `CodeTextView` and is internal for this reason.
extension CodeTextView {
public func acceptSuggestion() -> Bool {
    guard inlineSuggestion.isVisible else { return false }
    let text = inlineSuggestion.text
    inlineSuggestion.clear()
    let caret = selectedRange()
    // Re-indent continuation lines to match the caret's column, so a
    // multi-line suggestion does not land flush against the left margin.
    let indented = reindent(text, at: caret.location)
    insertText(indented, replacementRange: caret)
    onAcceptSuggestion?()
    return true
}

/// Aligns the second and later lines of a suggestion with the caret.
func reindent(_ suggestion: String, at offset: Int) -> String {
    let ns = string as NSString
    guard suggestion.contains("\n"), offset <= ns.length else { return suggestion }
    let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
    let beforeCaret = ns.substring(with: NSRange(location: lineRange.location,
                                                 length: offset - lineRange.location))
    let indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
    guard !indent.isEmpty else { return suggestion }
    var lines = suggestion.components(separatedBy: "\n")
    guard lines.count > 1 else { return suggestion }
    let base = lines[0].prefix { $0 == " " }.count
    lines = [lines[0]] + lines.dropFirst().map { line in
        guard !line.isEmpty else { return line }
        let own = line.prefix { $0 == " " }.count
        let relative = max(0, own - base)
        return indent + String(repeating: " ", count: relative) + line.drop { $0 == " " }
    }
    return lines.joined(separator: "\n")
}

/// Schedules a prediction request after the user stops typing.
///
/// Debounced because every keystroke would otherwise ask the model, and the
/// request that matters is the one for the text the user actually paused on.
public func scheduleSuggestionRequest() {
    guard onRequestSuggestion != nil else { return }
    pendingSuggestionWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
        self?.requestSuggestionNow()
    }
    pendingSuggestionWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.suggestionDelay, execute: work)
}

/// Asks for a prediction for the current caret position.
public func requestSuggestionNow() {
    guard let onRequestSuggestion else { return }
    let ns = string as NSString
    let caret = min(selectedRange().location, ns.length)
    guard selectedRange().length == 0 else { return dismissSuggestion() }
    // Only continue the line being typed; predicting in blank space or in a
    // comment produces noise.
    // `lineRange` for a caret at the start of an empty last line covers that
    // empty line, so the text shown is "" even though the line above is full.
    // Look backwards to the first non-empty line instead of giving up.
    // Only the line being typed is continued. Walking back to the previous
    // non-empty line made a suggestion reappear after Enter, once the line was
    // finished — a prediction for a line the user had already moved past.
    let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
    let beforeCaret = ns.substring(with: NSRange(location: lineRange.location,
                                                 length: caret - lineRange.location))
    let trimmed = beforeCaret.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else {
        return dismissSuggestion()
    }
    // A line that already ends a statement is finished; nothing to continue.
    if trimmed.hasSuffix(";") || trimmed.hasSuffix("}") || trimmed.hasSuffix("{") {
        return dismissSuggestion()
    }
    let suffix = ns.substring(from: caret)
    let requestOffset = caret
    guard let suggestion = onRequestSuggestion(beforeCaret, suffix), !suggestion.isEmpty else {
        return dismissSuggestion()
    }
    // The document may have moved while the model was thinking.
    guard selectedRange().location == requestOffset, selectedRange().length == 0 else { return }
    showSuggestion(suggestion)
}

/// How long typing must pause before a prediction is requested.
static let suggestionDelay: TimeInterval = 0.12

/// Dismisses the ghost text (Escape, or any edit that invalidates it).
public func dismissSuggestion() {
    guard inlineSuggestion.isVisible else { return }
    inlineSuggestion.clear()
    needsDisplay = true
}

    /// Paints the predicted continuation as ghost text at the caret.
    func drawInlineSuggestion() {
        guard inlineSuggestion.isVisible, let caretRect = caretRectInView(),
              caretRect.intersects(bounds) else { return }
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        inlineSuggestion.draw(in: self, caretRect: caretRect, font: font)
    }

    /// Rect the caret occupies, in this view's coordinates.
    ///
    /// Built from the line fragment and the glyph's own offset rather than from
    /// `boundingRect(forGlyphRange:)`: a zero-length range has no reliable bounds,
    /// and on a line with trailing spaces the text view reports the fragment's
    /// own rect — which is why the ghost text drifted away from the caret.
    func caretRectInView() -> NSRect? {
        guard let layoutManager, let container = textContainer else {
            return nil
        }
        let length = (string as NSString).length
        let location = min(max(0, selectedRange().location), length)
        // At the end of the document there is no glyph at `location`; anchor to
        // the last one and advance past it.
        let glyphIndex: Int
        var advancePastGlyph = false
        if location >= length, length > 0 {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: length - 1)
            advancePastGlyph = true
        } else {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
        }
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        var x = lineRect.minX
        if advancePastGlyph {
            x = layoutManager.location(forGlyphAt: glyphIndex).x
                + layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                             in: container).width
        } else {
            x = layoutManager.location(forGlyphAt: glyphIndex).x
        }
        return NSRect(x: x + textContainerOrigin.x,
                      y: lineRect.minY + textContainerOrigin.y,
                      width: 2,
                      height: lineRect.height)
    }

public func showSuggestion(_ text: String?) {
    let offset = selectedRange().location
    guard let text, !text.isEmpty else {
        inlineSuggestion.clear()
        needsDisplay = true
        return
    }
    // A suggestion that repeats what follows the caret would produce
    // "forfor" the moment Tab is pressed.
    let ns = string as NSString
    guard offset <= ns.length else { return }
    let following = ns.substring(from: offset)
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty, following.hasPrefix(trimmed) {
        inlineSuggestion.clear()
        needsDisplay = true
        return
    }
    inlineSuggestion.offer(text, at: offset)
    needsDisplay = true
}

public var hasSuggestion: Bool { inlineSuggestion.isVisible }
}
