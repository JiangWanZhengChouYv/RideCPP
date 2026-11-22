import AppKit

/// Applies syntax colors to the text view.
///
/// Colors are installed as *temporary attributes* on the layout manager, which
/// is what keeps highlighting out of the document's attribute storage and out of
/// the undo stack: the user's undo history only contains text edits.
public final class SyntaxHighlighter {

    /// Files bigger than this are highlighted by visible range only.
    public static let largeFileThreshold = 2 * 1024 * 1024
    /// Files bigger than this are not highlighted at all.
    public static let maximumHighlightedSize = 12 * 1024 * 1024

    public weak var textView: CodeTextView?
    public private(set) var lastTokenCount = 0

    private var pendingWork: DispatchWorkItem?
    private let highlightDelay: TimeInterval = 0.06

    public init(textView: CodeTextView) {
        self.textView = textView
    }

    deinit {
        pendingWork?.cancel()
    }

    /// Schedules a full highlight after a short debounce.
    public func scheduleHighlight() {
        guard textView != nil else { return }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.highlightNow()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + highlightDelay, execute: work)
    }

    /// Highlights immediately (used after loading a file).
    public func highlightNow() {
        pendingWork?.cancel()
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let nsText = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Clear previous colors.
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

        let byteCount = nsText.length * 4
        guard byteCount <= Self.maximumHighlightedSize else {
            lastTokenCount = 0
            return
        }

        let source: String
        if byteCount > Self.largeFileThreshold {
            // Only highlight what is on screen (plus a margin) for big files.
            let visible = textView.visibleRect
            if let container = textView.textContainer {
                let glyphs = layoutManager.glyphRange(forBoundingRect: visible.insetBy(dx: 0, dy: -visible.height), in: container)
                let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                source = nsText.substring(with: chars)
                applyColors(on: source, at: chars.location, layoutManager: layoutManager)
                return
            }
        }
        source = textView.string
        applyColors(on: source, at: 0, layoutManager: layoutManager)
    }

    private func applyColors(on source: String, at baseLocation: Int, layoutManager: NSLayoutManager) {
        let tokens = CppLexer.tokenize(source)
        lastTokenCount = tokens.count
        // Group by color so the layout manager does fewer attribute runs.
        var rangesByKind: [SyntaxToken.Kind: [NSRange]] = [:]
        for token in tokens {
            let shifted = NSRange(location: token.range.location + baseLocation, length: token.range.length)
            rangesByKind[token.kind, default: []].append(shifted)
        }
        for (kind, ranges) in rangesByKind {
            let color = EditorTheme.color(for: kind)
            for range in ranges {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
            }
        }
    }

    /// Restores the plain text color without re-lexing.
    public func clearHighlighting() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        lastTokenCount = 0
    }
}
