import AppKit

// MARK: - Find highlights

/// Paints search matches over the text.
///
/// Kept apart from diagnostics because the two use overlapping machinery but must
/// not interfere: an error inside a match has to keep its red background, and
/// clearing the search must not strip error marks.
extension CodeTextView {

    /// Characters painted as search matches.
    private static var findHighlightsKey: UInt8 { 0 }

    /// Shows every match, distinguishing the one currently selected.
    public func showFindHighlights(_ ranges: [NSRange], current: NSRange?) {
        guard let layoutManager else { return }
        removeFindHighlights()
        let length = (string as NSString).length
        for range in ranges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }
            let isCurrent = current.map { NSEqualRanges($0, range) } ?? false
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: isCurrent ? EditorTheme.findCurrentMatch : EditorTheme.findMatch,
                forCharacterRange: clamped)
        }
        findHighlightRanges = ranges
        needsDisplay = true
    }

    /// Removes every search highlight, restoring the text underneath.
    public func hideFindHighlights() {
        guard !findHighlightRanges.isEmpty else { return }
        removeFindHighlights()
        needsDisplay = true
        // The characters that carried a match also lost their syntax colour, so
        // they have to be repainted rather than left in the plain colour.
        onDiagnosticsCleared?()
    }

    private func removeFindHighlights() {
        guard let layoutManager else { return }
        let length = (string as NSString).length
        for range in findHighlightRanges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
        }
        findHighlightRanges = []
    }
}
