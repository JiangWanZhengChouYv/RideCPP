import AppKit
import EditorCore

// MARK: - Squiggles

extension CodeTextView {
/// Removes every inline diagnostic.
public func clearErrorMarkers() {
    diagnostics = []
    guard let layoutManager else { return }
    let cleared = removePaintedMarkers(layoutManager: layoutManager,
                                       in: string as NSString)
    if cleared { scheduleRehighlight() }
    refreshGutterMarkers()
}

/// Strips every diagnostic attribute actually present in the text.
///
/// Positions are found by reading the layout manager rather than by trusting
/// remembered offsets: those go stale the moment the text is edited, and a
/// stale offset is exactly what leaves a red box on an innocent character.
///
/// Returns whether anything was removed, so the caller can repaint syntax
/// colours over the holes.
@discardableResult
func removePaintedMarkers(layoutManager: NSLayoutManager, in ns: NSString) -> Bool {
    let full = NSRange(location: 0, length: ns.length)
    guard full.length > 0 else { return false }
    // AppKit offers no enumerator for temporary attributes, so the painted
    // spans are rebuilt by scanning and coalescing runs. This runs once per
    // diagnostic update (a few times a second at most), over the visible
    // text, which is cheap enough to avoid caching stale offsets.
    var removed = false
    var runStart: Int?
    for index in 0...full.length {
        let painted = index < full.length
            && layoutManager.temporaryAttribute(.backgroundColor,
                                                atCharacterIndex: index,
                                                effectiveRange: nil) != nil
        if painted, runStart == nil {
            runStart = index
        } else if !painted, let start = runStart {
            let range = NSRange(location: start, length: index - start)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            removed = true
            runStart = nil
        }
    }
    return removed
}

    /// Repaints syntax colours after diagnostics were removed.
    ///
    /// Removing `.foregroundColor` from a diagnostic's characters also strips the
    /// syntax colour they had, so they have to be highlighted again or they stay
    /// in the plain text colour.
    func scheduleRehighlight() {
        onDiagnosticsCleared?()
    }

/// Re-applies the diagnostic text colours after syntax highlighting repainted
/// the whole visible range.
///
/// Called by the highlighter, which owns `.foregroundColor` on the same
/// temporary-attribute store. Background and underline are untouched by
/// highlighting, so only the text colour needs restoring.
func reapplyDiagnosticColors() {
    guard let layoutManager, !diagnostics.isEmpty else { return }
    let ns = string as NSString
    let full = NSRange(location: 0, length: ns.length)
    for item in diagnostics {
        let clamped = NSIntersectionRange(item.range, full)
        guard clamped.length > 0 else { continue }
        layoutManager.addTemporaryAttribute(
            .foregroundColor,
            value: item.kind == .error ? EditorTheme.errorText : EditorTheme.warningText,
            forCharacterRange: clamped)
    }
}

/// Paints the wavy underlines.
///
/// Kept as a static helper so the view body stays within the lint budget.
static func drawDiagnosticSquiggles(in textView: CodeTextView, dirtyRect: NSRect) {
    guard let layoutManager = textView.layoutManager,
          let container = textView.textContainer,
          !textView.diagnostics.isEmpty else { return }
    let origin = textView.textContainerOrigin
    let amplitude: CGFloat = 1.8
    let wavelength: CGFloat = 4.0
    let length = (textView.string as NSString).length
    for item in textView.diagnostics {
        let clamped = NSIntersectionRange(item.range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { continue }
        let color = item.kind == .error ? EditorTheme.errorUnderline : EditorTheme.warningUnderline
        color.setStroke()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped,
                                                  actualCharacterRange: nil)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
            let lineGlyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
            let overlap = NSIntersectionRange(lineGlyphs, glyphRange)
            guard overlap.length > 0 else { return }
            let start = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: overlap.location, length: 0), in: container)
            let end = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: NSMaxRange(overlap) - 1, length: 1), in: container)
            let y = rect.maxY + origin.y - 1
            let x0 = start.minX + origin.x
            let x1 = end.maxX + origin.x
            guard x1 > x0 else { return }
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSPoint(x: x0, y: y))
            var x = x0
            while x < x1 {
                let next = min(x + wavelength / 2, x1)
                let mid = (x + next) / 2
                path.curve(to: NSPoint(x: next, y: y),
                           controlPoint1: NSPoint(x: mid, y: y + amplitude),
                           controlPoint2: NSPoint(x: mid, y: y - amplitude))
                x = next
            }
            path.stroke()
        }
    }
}
}

// MARK: - Dismissing the hover panel

extension CodeTextView {
/// Arms a dismissal after the pointer leaves the panel.
///
/// Not immediate: the trip from the code to the button is fast, and a
/// hairline exit between the two would dismiss the thing being aimed at.
public func scheduleHoverClose() {
    cancelHoverClose()
    let work = DispatchWorkItem { [weak self] in
        guard let self, !self.isPointerOnHoverPanel else { return }
        self.hideHoverIfPointerNotOverDiagnostic()
    }
    pendingHoverClose = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCloseGrace, execute: work)
}

/// Cancels a pending dismissal (the pointer came back).
public func cancelHoverClose() {
    pendingHoverClose?.cancel()
    pendingHoverClose = nil
}

/// Closes the panel unless the pointer is back over a problem.
public func hideHoverIfPointerNotOverDiagnostic() {
    guard let window else { return hideHover() }
    let inWindow = window.mouseLocationOutsideOfEventStream
    let point = convert(inWindow, from: nil)
    // Outside the view entirely: nothing to keep the panel for.
    guard bounds.contains(point), let index = characterOffset(atPoint: point),
          diagnostic(at: index) != nil else {
        hideHover()
        return
    }
}
}
