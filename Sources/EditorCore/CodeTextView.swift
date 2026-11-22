import AppKit

/// `NSTextView` subclass that owns the editor's smart editing behaviour.
///
/// The view uses TextKit 1 (`NSTextView(frame:textContainer:)` creates one)
/// because temporary-attribute highlighting and `NSRulerView` line numbers are
/// both fully supported on the TextKit 1 path.
public final class CodeTextView: NSTextView {

    /// Per-document undo manager. Each tab gets its own stack so switching tabs
    /// never mixes histories.
    private var documentUndoManager: UndoManager?
    private var editSettings = EditSettings()

    /// Called after any user edit so the window can refresh dirty state, line
    /// numbers and highlighting.
    public var onTextChange: (() -> Void)?
    /// Called when the caret moves, used to repaint the active line number.
    public var onSelectionChange: (() -> Void)?

    /// Provider for future model-backed completion. `nil` in this version.
    public var completionProvider: CompletionProviding?

    public override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }

    public func setDocumentUndoManager(_ manager: UndoManager) {
        documentUndoManager = manager
    }

    public func apply(settings: EditSettings) {
        editSettings = settings
    }

    public var currentSettings: EditSettings { editSettings }

    /// Designated initializer. With a `nil` container it assembles a complete
    /// TextKit 1 stack (text storage + layout manager + text container):
    /// `NSTextView(frame:textContainer:)` with `nil` leaves `textStorage` nil, so
    /// nothing could ever be displayed.
    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            super.init(frame: frameRect, textContainer: container)
        } else {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let newContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            newContainer.widthTracksTextView = true
            layoutManager.addTextContainer(newContainer)
            super.init(frame: frameRect, textContainer: newContainer)
        }
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// Creates a fully configured code editor view.
    public convenience init(settings: EditSettings) {
        self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        editSettings = settings
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        isFieldEditor = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        // Automatic text munging fights a code editor: disable all of it.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isAutomaticTextCompletionEnabled = false
        usesFontPanel = false
        importsGraphics = false

        drawsBackground = true
        backgroundColor = EditorTheme.background
        textColor = EditorTheme.plainText
        insertionPointColor = EditorTheme.cursor
        selectedTextAttributes = [.backgroundColor: EditorTheme.selection]
        font = EditorTheme.font(size: 13)

        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 10, height: 8)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 4
    }

    /// Applies a font size to existing text as well as future typing.
    public func setFontSize(_ size: CGFloat) {
        let newFont = EditorTheme.font(size: size)
        font = newFont
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: newFont, range: full)
        needsDisplay = true
    }

    // MARK: - Smart editing

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        // Never interfere with an active input-method composition.
        guard !hasMarkedText(), let typed = string as? String else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Multi-character insertions (paste, IME commit) bypass the planner.
        guard typed.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let selection = effectiveSelection(replacing: replacementRange)
        let outcome = EditPlanner.apply(.insert(typed), to: self.string, selection: selection, settings: editSettings)

        if outcome.text == self.string {
            // Type-through: move the caret over the character already there.
            setSelectedRange(EditPlanner.clampRange(outcome.selection, in: self.string))
            scrollRangeToVisible(selectedRange())
            onSelectionChange?()
            return
        }
        apply(outcome)
    }

    public override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        apply(EditPlanner.apply(.newline, to: string, selection: selectedRange(), settings: editSettings))
    }

    public override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.insertTab(sender)
            return
        }
        apply(EditPlanner.apply(.tab, to: string, selection: selectedRange(), settings: editSettings))
    }

    public override func insertBacktab(_ sender: Any?) {
        apply(EditPlanner.apply(.backtab, to: string, selection: selectedRange(), settings: editSettings))
    }

    public override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }
        apply(EditPlanner.apply(.deleteBackward, to: string, selection: selectedRange(), settings: editSettings))
    }

    /// ⌘/ — comment or uncomment the lines covered by the selection.
    @objc public func toggleComment(_ sender: Any?) {
        apply(EditPlanner.apply(.toggleComment, to: string, selection: selectedRange(), settings: editSettings))
    }

    @objc public func indentSelection(_ sender: Any?) {
        apply(EditPlanner.apply(.tab, to: string, selection: selectedRange(), settings: editSettings))
    }

    @objc public func outdentSelection(_ sender: Any?) {
        apply(EditPlanner.apply(.backtab, to: string, selection: selectedRange(), settings: editSettings))
    }

    /// Replaces the whole document as one undoable action (used by formatting).
    public func replaceAllText(with newText: String, selection: NSRange, actionName: String? = nil) {
        guard newText != string else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: newText) else { return }
        textStorage?.replaceCharacters(in: full, with: newText)
        didChangeText()
        undoManager?.setActionName(actionName ?? "Edit")
        setSelectedRange(EditPlanner.clampRange(selection, in: newText))
        scrollRangeToVisible(selectedRange())
    }

    /// Moves the caret to a 1-based line/column and optionally marks the line.
    public func goTo(line: Int, column: Int = 1, highlightError: Bool = false) {
        guard let position = TextCoordinates.utf16Offset(line: line, column: column, in: string) else { return }
        let range = NSRange(location: position, length: 0)
        setSelectedRange(range)
        scrollRangeToVisible(range)
        window?.makeFirstResponder(self)
        if highlightError { flashErrorLine(containing: position) }
    }

    /// Underlines the line containing `location` with a dotted red underline,
    /// used to point at a compiler diagnostic.
    public func flashErrorLine(containing location: Int) {
        guard let layoutManager else { return }
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let lineRange = ns.lineRange(for: NSRange(location: min(max(0, location), ns.length), length: 0))
        let full = NSRange(location: 0, length: ns.length)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layoutManager.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: EditorTheme.errorUnderline
        ], forCharacterRange: lineRange)
    }

    public func clearErrorMarkers() {
        guard let layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
    }

    // MARK: - Completion hook (not implemented in this version)

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        // Call site reserved for the future API-backed completion provider.
        if let provider = completionProvider {
            let prefix = (string as NSString).substring(with: charRange)
            let items = provider.completionItems(forPrefix: prefix, document: string)
            if !items.isEmpty { return items.map(\.text) }
        }
        var selected = 0
        let result = super.completions(forPartialWordRange: charRange, indexOfSelectedItem: &selected)
        index?.pointee = selected
        return result
    }

    // MARK: - Plumbing

    private func effectiveSelection(replacing replacementRange: NSRange) -> NSRange {
        if replacementRange.location != NSNotFound {
            return EditPlanner.clampRange(replacementRange, in: string)
        }
        return selectedRange()
    }

    /// Applies a planner outcome through the standard text-system path so undo,
    /// notifications and layout invalidation all behave natively.
    private func apply(_ outcome: EditOutcome) {
        guard outcome.changed else {
            setSelectedRange(EditPlanner.clampRange(outcome.selection, in: string))
            onSelectionChange?()
            NSSound.beep()
            return
        }

        guard let storage = textStorage else { return }
        let oldText = string as NSString
        let newText = outcome.text as NSString

        // Replace only the span that actually changed: cheaper layout and a
        // tighter undo action.
        var prefix = 0
        let maxPrefix = min(oldText.length, newText.length)
        while prefix < maxPrefix, oldText.character(at: prefix) == newText.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < maxPrefix - prefix,
              oldText.character(at: oldText.length - 1 - suffix) == newText.character(at: newText.length - 1 - suffix) {
            suffix += 1
        }
        let oldSpan = NSRange(location: prefix, length: oldText.length - prefix - suffix)
        let replacement = newText.substring(with: NSRange(location: prefix, length: newText.length - prefix - suffix))

        guard oldSpan.length > 0 || !replacement.isEmpty else { return }
        guard shouldChangeText(in: oldSpan, replacementString: replacement) else { return }

        storage.beginEditing()
        storage.replaceCharacters(in: oldSpan, with: replacement)
        storage.endEditing()
        didChangeText()

        setSelectedRange(EditPlanner.clampRange(outcome.selection, in: string))
        scrollRangeToVisible(selectedRange())
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onSelectionChange?()
    }
}
