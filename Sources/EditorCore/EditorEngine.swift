import AppKit

/// Everything one editor tab needs: the text view, its scroll view, the line
/// number gutter and the syntax highlighter.
///
/// Each document owns an independent engine, which is what makes per-tab undo
/// history, scroll position and selection survive tab switches for free.
public final class EditorEngine {

    public let textView: CodeTextView
    public let scrollView: NSScrollView
    public let ruler: LineNumberRuler
    public let highlighter: SyntaxHighlighter

    /// Fired on every user edit (after the text storage has changed).
    public var onEdit: (() -> Void)?
    /// Fired when the caret or selection moves.
    public var onCaretChange: (() -> Void)?

    public init(settings: EditSettings, fontSize: CGFloat = 13, showLineNumbers: Bool = true) {
        textView = CodeTextView(settings: settings)
        scrollView = NSScrollView()
        ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        highlighter = SyntaxHighlighter(textView: textView)

        textView.setFontSize(fontSize)
        // Give the document view a real initial size: a zero-sized text view
        // never lays out, so nothing would be drawn after loading a file.
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        // Clip the editor (and its line-number gutter) to its own bounds so a
        // drawing pass at an intermediate size cannot leave artefacts elsewhere
        // in the window.
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        ruler.wantsLayer = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.documentView = textView
        scrollView.hasVerticalRuler = showLineNumbers
        scrollView.rulersVisible = showLineNumbers
        scrollView.verticalRulerView = ruler
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.onTextChange = { [weak self] in
            self?.textDidChange()
        }
        // (kept for programmatic edits that bypass the responder chain)
        textView.onSelectionChange = { [weak self] in
            self?.ruler.needsDisplay = true
            self?.onCaretChange?()
        }

        // `NSText.didChangeNotification` is posted by AppKit for every text
        // change (typing, pasting, programmatic `didChangeText()`), which is the
        // single reliable trigger for dirty state, highlighting and the ruler.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(textStorageDidChange(_:)),
                                               name: NSText.didChangeNotification,
                                               object: textView)
    }

    @objc private func textStorageDidChange(_ notification: Notification) {
        textDidChange()
    }

    private func textDidChange() {
        highlighter.scheduleHighlight()
        ruler.refreshThickness()
        ruler.needsDisplay = true
        onEdit?()
    }

    /// Loads text into the engine as a fresh document (no undo entry).
    public func load(text: String, undoManager: UndoManager) {
        textView.setDocumentUndoManager(undoManager)
        textView.string = text
        textView.setFontSize(textView.font?.pointSize ?? 13)
        undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        highlighter.highlightNow()
        ruler.refreshThickness()
    }

    public func apply(settings: EditSettings, fontSize: CGFloat, showLineNumbers: Bool) {
        textView.apply(settings: settings)
        if textView.font?.pointSize != fontSize {
            textView.setFontSize(fontSize)
            highlighter.highlightNow()
        }
        if scrollView.hasVerticalRuler != showLineNumbers {
            scrollView.hasVerticalRuler = showLineNumbers
            scrollView.rulersVisible = showLineNumbers
        }
        scrollView.verticalRulerView = ruler
        ruler.refreshThickness()
        textView.needsDisplay = true
    }

    /// Inserts a snippet replacing the current selection.
    public func insert(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// Moves the caret to the start of `line` (1-based) and scrolls it into view.
    ///
    /// Used by the outline sidebar: clicking a symbol should put the cursor on its
    /// declaration, not merely scroll near it.
    public func jump(toLine line: Int) {
        let ns = textView.string as NSString
        var currentLine = 1
        var index = 0
        while currentLine < line, index < ns.length {
            let found = ns.range(of: "\n", options: [], range: NSRange(location: index, length: ns.length - index))
            if found.location == NSNotFound { break }
            index = found.location + 1
            currentLine += 1
        }
        // Column 0 of the declaration's line, skipping its indentation so the caret
        // lands on the first visible character.
        var start = index
        while start < ns.length, ns.character(at: start) == 0x20 || ns.character(at: start) == 0x09 {
            start += 1
        }
        textView.setSelectedRange(NSRange(location: min(start, ns.length), length: 0))
        textView.scrollRangeToVisible(NSRange(location: min(start, ns.length), length: 0))
        focus()
    }
}
