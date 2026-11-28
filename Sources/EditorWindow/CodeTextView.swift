import AppKit
import EditorCore

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

    /// Source of completion suggestions. Defaults to the built-in offline
    /// provider; the app replaces it with the clangd-backed one when available.
    public var completionProvider: CompletionProviding? = BuiltinCompletionProvider()

    /// File this document corresponds to, used by semantic providers.
    public var documentFileURL: URL?

    /// Set while the view applies one of its own edits, so the sync that follows
    /// does not recurse.
    private var isApplyingInternalEdit = false

    /// Called after diagnostic attributes were removed, so the owner can repaint
    /// syntax colours on the affected characters.
    public var onDiagnosticsCleared: (() -> Void)?

    /// Called whenever the text changed, whatever caused it.
    ///
    /// This is the single hook AppKit gives for every kind of edit — typing,
    /// deleting, pasting, undo, drag-and-drop and programmatic replacement — so it
    /// is where the document must be pushed to clangd. Syncing only from the
    /// keyboard paths left the server analysing stale text, which showed up as
    /// errors on correct code.
    public override func didChangeText() {
        super.didChangeText()
    }

    /// Tells the listener that the text changed.
    ///
    /// Called from the engine's `NSText.didChangeNotification` handler, which is
    /// the one place AppKit reports *every* edit — typing, deleting, pasting,
    /// undo, drag-and-drop and programmatic replacement alike.
    func notifyDocumentChanged() {
        onDocumentSync?(self.string, documentFileURL)
        // A prediction describes the text it was made for; once that text
        // changes it is stale. Ask again after the user stops typing.
        dismissSuggestion()
        // Tells the owner the text advanced, so an answer still in flight for the
        // old text can be recognised and dropped.
        onDocumentRevisionChanged?()
        scheduleSuggestionRequest()
    }

    /// Called when a button inside the hover panel is clicked.
    public var onHoverAction: ((HoverAction) -> Void)?
    /// Called after every edit so a semantic provider can keep its server in sync.
    public var onDocumentSync: ((String, URL?) -> Void)?
    /// Inline diagnostics currently drawn.
    private var diagnostics: [InlineDiagnostic] = []
    /// Character ranges currently painted as search matches.
    var findHighlightRanges: [NSRange] = []
    /// Read-only view of the current underlines, for tests and diagnostics panels.
    public var diagnosticsForTesting: [InlineDiagnostic] { diagnostics }
    /// Floating hover hint, if one is visible.
    private var hoverPanel: HoverPanel?
    /// True while the pointer rests on the hover panel itself (over its button).
    public var isPointerOnHoverPanel = false
    /// Pending dismissal after the pointer left the panel.
    var pendingHoverClose: DispatchWorkItem?

    /// Whether the completion list opens automatically while typing.
    public var autoCompletionEnabled = true

    /// The completion popup, created on first use.
    private var completionPanel: CompletionPanel?
    /// Range of text the active completion list is replacing.
    private var completionRange: NSRange?
    /// Prefix the active list was opened with, to filter as the user types.
    private var activeCompletionPrefix = ""

    public override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }

    public func setDocumentUndoManager(_ manager: UndoManager) {
        documentUndoManager = manager
    }

    public func apply(settings: EditSettings) {
        editSettings = settings
        autoCompletionEnabled = settings.autoComplete
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

        // Completing an identifier replaces the whole word, so end the current
        // undo group first: otherwise ⌘Z after accepting a completion would only
        // remove the last typed character.
        endCurrentUndoGroup()

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
        maybeShowCompletions(afterTyping: typed)
    }

    /// Opens the completion list after an identifier character, which is what
    /// makes it feel like a normal code editor: type `i`, get `int`, `if`, …
    private func maybeShowCompletions(afterTyping typed: String) {
        guard autoCompletionEnabled, completionProvider != nil,
              let character = typed.first else { return }
        let isIdentifierCharacter = character.isLetter || character.isNumber || character == "_"
        guard isIdentifierCharacter else {
            hideCompletions()
            return
        }
        showCompletionsIfUseful()
    }

    /// Shows or refreshes the list for the word at the caret.
    private func showCompletionsIfUseful() {
        guard let provider = completionProvider,
              let candidate = completionPrefixAtCaret() else {
            hideCompletions()
            return
        }
        // One character is enough: "i" must offer int/if.
        let items = provider.completionItems(forPrefix: candidate.prefix,
                                             document: string,
                                             context: candidate.context)
        guard !items.isEmpty else {
            hideCompletions()
            return
        }
        activeCompletionPrefix = candidate.prefix
        presentItems(items, range: candidate.range)
    }

    /// The word being typed at the caret, plus the context that decides which
    /// suggestions make sense.
    /// Caret as an LSP line/character pair (line 0-based, character in UTF-16).
    func caretLSPPosition() -> CursorPosition {
        let ns = string as NSString
        let location = min(selectedRange().location, ns.length)
        let prefix = ns.substring(to: location)
        let lines = prefix.components(separatedBy: "\n")
        let line = max(0, lines.count - 1)
        let character = (lines.last as NSString?)?.length ?? 0
        return CursorPosition(line: line, character: character)
    }

    private func completionPrefixAtCaret() -> (prefix: String, range: NSRange, context: CompletionContext)? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let text = string
        guard !CppLexer.isInsideLiteralOrComment(CppLexer.tokenize(text), at: selection.location) else {
            return nil
        }
        let found = BuiltinCompletionProvider.prefix(at: selection.location, in: text)
        let ns = text as NSString
        var context = CompletionContext.code
        if found.range.location > 0 {
            let before = ns.substring(to: found.range.location).trimmingCharacters(in: .whitespaces)
            if before.hasSuffix("#") { context = .preprocessor }
        }
        if context == .code, found.prefix.isEmpty { return nil }
        return (found.prefix, found.range, context)
    }

    /// Screen-space rect of the caret, for positioning the popup.
    /// The caret line's rectangle in screen coordinates.
    ///
    /// Returns the whole line fragment (not just the caret glyph) so the popup can
    /// be anchored below the *line*: anchoring to the caret's own rect put the list
    /// on top of the text being typed, because text view coordinates are flipped.
    /// Where a popup should be anchored: the caret line's rect, plus the caret's x.
    private struct PopupAnchor {
        let line: NSRect
        let caretX: CGFloat
    }

    private func caretLineScreenRect() -> PopupAnchor {
        guard let window, let layoutManager, let container = textContainer else {
            return PopupAnchor(line: .zero, caretX: 0)
        }
        let location = min(selectedRange().location, (string as NSString).length)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 0),
                                                  actualCharacterRange: nil)
        let caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        // The full line fragment gives the line's top/bottom, which is what we want
        // to sit under.
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        var rect = NSRect(x: caretRect.origin.x,
                          y: lineRect.origin.y,
                          width: max(caretRect.width, 2),
                          height: lineRect.height)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        let inWindow = convert(rect, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return PopupAnchor(line: onScreen, caretX: onScreen.minX)
    }

    private func completionPanelInstance() -> CompletionPanel {
        if let completionPanel { return completionPanel }
        let panel = CompletionPanel()
        completionPanel = panel
        return panel
    }

    /// Inserts the accepted suggestion, replacing the prefix being typed.
    ///
    /// Multi-line snippets are re-indented to match the line they are inserted
    /// on, using the document's own indent unit, so accepting `if` inside a
    /// four-space block does not jump to column 0.
    private func accept(_ item: CompletionItem) {
        guard !item.insertionText.isEmpty else { return }
        let range = EditPlanner.clampRange(completionRange
            ?? BuiltinCompletionProvider.prefix(at: selectedRange().location, in: string).range,
            in: string)
        let insertion = indentSnippet(item.insertionText, at: range.location)
        // One edit for the whole snippet: inserting it character by character let
        // the auto-pair and auto-indent planner re-process braces and newlines,
        // which is what produced growing, misaligned output.
        insertCompletionText(insertion, replacing: range)
        completionRange = nil
        activeCompletionPrefix = ""
    }

    /// Rewrites a snippet so each line carries the current line's indentation
    /// plus the document's indent unit per nesting level.
    private func indentSnippet(_ snippet: String, at location: Int) -> String {
        let ns = string as NSString
        let lineRange = EditPlanner.lineRange(at: location, in: ns)
        let beforeCaret = ns.substring(with: NSRange(location: lineRange.location,
                                                     length: max(0, location - lineRange.location)))
        // Indentation already sitting on this line. The replacement range starts
        // *after* it, so the first line must not receive it again — that
        // duplication is what produced six spaces inside a four-space block.
        let baseIndent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        let unit = editSettings.indentUnit
        // Track brace nesting so body lines land one level inside the block.
        var braceDepth = 0
        return snippet
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { offset, line -> String in
                var body = String(line)
                var depth = 0
                while body.hasPrefix(String(BuiltinCompletionProvider.indentMarker)) {
                    body.removeFirst()
                    depth += 1
                }
                // A closing brace belongs to the enclosing level.
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("}") { braceDepth = max(0, braceDepth - 1) }
                // The first line continues the current one, so it already sits at
                // `baseIndent`. Later lines restart from the enclosing indent and
                // add one unit per nesting level (a bare marker line is one level
                // deeper than the statement itself).
                // Inside the snippet, `{` opens one level and `}` closes one, so a
                // marker line ends up indented relative to the statement.
                let prefix = offset == 0 ? "" : baseIndent
                let nesting = offset == 0 ? 0 : max(depth, braceDepth)
                let indented = prefix + String(repeating: unit, count: nesting) + body
                if trimmed.hasSuffix("{") { braceDepth += 1 }
                return indented
            }
            .joined(separator: "\n")
    }

    /// Replaces `range` with `text` through the normal text-system path so undo
    /// and syntax highlighting treat it like any other edit.
    private func insertCompletionText(_ text: String, replacing range: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
        onSelectionChange?()
    }

    /// Whether the completion popup is on screen. Used by tests and the UI.
    public var isShowingCompletions: Bool { completionPanel?.isShowing ?? false }

    /// Number of suggestions currently offered.
    public var completionItemCount: Int { completionPanel?.count ?? 0 }

    /// Index of the highlighted suggestion (0 when the list is closed).
    public var selectedCompletionIndex: Int { completionPanel?.selectedRowForTesting ?? 0 }

    /// Text of the highlighted suggestion, for tests and diagnostics.
    public var selectedCompletionText: String? { completionPanel?.selectedTextForTesting }

    /// Hides the completion list, if any.
    func hideCompletions() {
        completionPanel?.dismiss()
        completionRange = nil
        activeCompletionPrefix = ""
    }

    /// Routes navigation keys while the list is open. Returns true when the key
    /// was consumed.
    public func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard let panel = completionPanel, panel.isShowing else { return false }
        switch event.keyCode {
        case 125:  // down arrow
            panel.moveSelection(by: 1)
            return true
        case 126:  // up arrow
            panel.moveSelection(by: -1)
            return true
        case 36, 76:  // return, enter
            panel.acceptSelection()
            return true
        case 48:  // tab
            panel.acceptSelection()
            return true
        case 53:  // escape
            panel.cancel()
            return true
        default:
            break
        }
        // Function keys can be remapped, so fall back to the characters.
        switch event.charactersIgnoringModifiers {
        case "\u{F701}":  // down arrow (private-use code)
            panel.moveSelection(by: 1)
            return true
        case "\u{F700}":  // up arrow
            panel.moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    public override func resignFirstResponder() -> Bool {
        hideCompletions()
        return super.resignFirstResponder()
    }

    /// ⌃Space — open the completion list explicitly.
    ///
    /// Unlike typing, an explicit request on an empty prefix lists the vocabulary
    /// from the start instead of doing nothing.
    @objc public func showCompletions(_ sender: Any?) {
        guard let provider = completionProvider else { return }
        guard let candidate = completionPrefixAtCaret() else {
            // No word at the caret: offer the common starting points.
            presentItems(provider.completionItems(forPrefix: "i", document: string, context: .code),
                         range: NSRange(location: selectedRange().location, length: 0))
            return
        }
        presentItems(provider.completionItems(forPrefix: candidate.prefix,
                                              document: string,
                                              context: candidate.context),
                     range: candidate.range)
    }

    /// Shows `items` in the popup, replacing `range` if one is accepted.
    private func presentItems(_ items: [CompletionItem], range: NSRange) {
        guard !items.isEmpty else {
            hideCompletions()
            return
        }
        completionRange = range
        let panel = completionPanelInstance()
        panel.onAccept = { [weak self] item in self?.accept(item) }
        panel.onCancel = { [weak self] in self?.completionRange = nil }
        // Give a semantic provider the exact caret before it queries.
        (completionProvider as? SemanticCompletionProvider)?.caretPosition = caretLSPPosition()
        let displayFont = font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let anchor = caretLineScreenRect()
        panel.show(items: items, below: anchor.line, caretX: anchor.caretX, font: displayFont)
    }

    public override func cancelOperation(_ sender: Any?) {
        // Escape dismisses the ghost text first; the completion list and the
        // rest of the responder chain stay reachable on a second press.
        if inlineSuggestion.isVisible {
            dismissSuggestion()
            return
        }
        if completionPanel?.isShowing == true {
            completionPanel?.cancel()
            return
        }
        super.cancelOperation(sender)
    }

    public override func keyDown(with event: NSEvent) {
        if handleCompletionKey(event) { return }
        super.keyDown(with: event)
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
        // Tab arrives through `insertTab`, not `keyDown`, so the completion
        // panel never saw it — the first Tab indented and only the second
        // accepted an item. The open list takes it first.
        if completionPanel?.isShowing == true {
            completionPanel?.acceptSelection()
            return
        }
        // Tab accepts the prediction when one is showing, and indents otherwise:
        // the ghost text is only ever what the single next key acts on.
        if acceptSuggestion() { return }
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
        // Deleting a character changes the prefix being completed, so the list
        // must be re-filtered (and closed once the word is gone).
        refreshCompletionsAfterDeleting()
    }

    /// Re-filters an open completion list after a deletion.
    private func refreshCompletionsAfterDeleting() {
        guard completionPanel?.isShowing == true, autoCompletionEnabled,
              let provider = completionProvider else { return }
        // The prefix is recomputed from the current text; the range stored when
        // the list opened is stale after a deletion.
        guard let candidate = completionPrefixAtCaret(), !candidate.prefix.isEmpty else {
            hideCompletions()
            return
        }
        let items = provider.completionItems(forPrefix: candidate.prefix,
                                             document: string,
                                             context: candidate.context)
        guard !items.isEmpty else {
            hideCompletions()
            return
        }
        activeCompletionPrefix = candidate.prefix
        presentItems(items, range: candidate.range)
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

    /// One diagnostic to underline, in character offsets.
    public struct InlineDiagnostic: Equatable {
        public enum Kind: Equatable {
            case error
            case warning
        }

        public let range: NSRange
        public let kind: Kind
        public let message: String
        /// Server error code (clangd's `code`, e.g. `no_member`), shown with the
        /// message so it can be searched for.
        public let code: String?

        public init(range: NSRange, kind: Kind, message: String, code: String? = nil) {
            self.range = range
            self.kind = kind
            self.message = message
            self.code = code
        }

        /// One-line description for the hover panel: severity, message, code.
        public var hoverText: String {
            let severity = kind == .error ? "error" : "warning"
            guard let code, !code.isEmpty else { return "\(severity): \(message)" }
            return "\(severity): \(message) [\(code)]"
        }
    }

    /// What a button in the hover panel should do when clicked.
    public enum HoverAction {
        /// Apply clangd's quick fix for the diagnostic the pointer is over.
        case fix(DiagnosticFixTarget)

        /// Text on the button that triggers this action.
        ///
        /// Supplied by the app layer: `EditorWindow` sits below it and cannot read
        /// the localization table, and a hard-coded English label stayed English
        /// in a Chinese UI.
        /// Localized label registered by the app layer for this action.
        var title: String {
            switch self {
            case .fix: return CodeTextView.hoverActionTitles["fix"] ?? "Fix"
            }
        }
    }

    /// Localized button labels for the hover panel, set by the app at launch.
    static private(set) var hoverActionTitles: [String: String] = [:]

    /// Registers the localized label shown for an action.
    public static func setHoverActionTitle(_ title: String, for action: String) {
        hoverActionTitles[action] = title
    }

    /// The diagnostic a hover button acts on.
    ///
    /// Carries the underline the panel was built from, so the click applies the
    /// fix to the problem the user is actually pointing at rather than to
    /// whatever happens to sit under the caret by then.
    public struct DiagnosticFixTarget {
        public let range: NSRange
        public let code: String?

        public init(diagnostic: InlineDiagnostic) {
            self.range = diagnostic.range
            self.code = diagnostic.code
        }
    }

    /// Tracks the mouse for hover queries.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterOffset(atPoint: point) else {
            if !isPointerOnHoverPanel { hideHover() }
            return
        }
        // While the pointer is on the panel, leave it alone: it is on its way to
        // the fix button, and replacing it would pull the button away.
        guard !isPointerOnHoverPanel else { return }
        // Only problems get a panel. Hovering ordinary code used to fetch
        // documentation from clangd for every identifier, which was both slow and
        // noisy: a floating box over code the user was merely reading.
        guard let diagnostic = diagnostic(at: index) else {
            hideHover()
            return
        }
        showHover(diagnostic.hoverText, at: index, kind: diagnostic.kind,
                  action: .fix(DiagnosticFixTarget(diagnostic: diagnostic)))
    }

    /// Character offset under a point in view coordinates, or nil past the text.
    public func characterOffset(atPoint point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerInset.width,
                                  y: point.y - textContainerInset.height)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        return min(max(0, charIndex), (string as NSString).length)
    }

    /// Shows a floating hint near a character offset (hover documentation).
    ///
    /// `kind` tints the panel's border so a hovered squiggle reads as an error or
    /// a warning at a glance, without having to parse the text.
    public func showHover(_ text: String, at character: Int,
                          kind: InlineDiagnostic.Kind? = nil,
                          action: HoverAction? = nil) {
        hideHover()
        guard !text.isEmpty else { return }
        let ns = string as NSString
        let clamped = min(max(0, character), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let lineText = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let width: CGFloat = min(460, max(260, CGFloat(lineText.count) * 7))

        let content = HoverContentView(text: text, width: width, actionTitle: action?.title)
        content.onAction = { [weak self] in
            guard let self, let action else { return }
            self.hideHover()
            self.onHoverAction?(action)
        }
        let height = content.fittingHeight

        let panel = HoverPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        content.onPointerInside = { [weak self] inside in
            guard let self else { return }
            self.isPointerOnHoverPanel = inside
            if inside {
                // Back on the panel: cancel a pending dismissal. The pointer often
                // clips the edge on its way to the button.
                self.cancelHoverClose()
                return
            }
            // Leaving does not close immediately. Crossing from the code to the
            // button is a fast gesture — at 100 Hz the pointer jumps several
            // points per frame — and a hairline exit in between would dismiss the
            // panel the user is aiming at. Give them time to land on it.
            self.scheduleHoverClose()
        }
        panel.isFloatingPanel = true
        // Above the editor, but not above other applications: a hover hint that
        // stays on top after switching away looks like a stuck tooltip.
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Position just below the hovered line.
        if let layoutManager, let container = textContainer, let window {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: clamped, length: 0),
                                                      actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            var rect = lineRect
            rect.origin.y += textContainerInset.height
            rect.origin.x = textContainerInset.width
            let inWindow = convert(rect, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            var x = onScreen.minX
            if let screen = window.screen {
                x = min(x, screen.visibleFrame.maxX - width - 4)
            }
            // Butt the panel against the line with no gap. A 2 pt strip between
            // the code and the panel is a dead zone: the pointer crosses it while
            // travelling to the button, stops being over either one, and the
            // panel closes out from under the click.
            panel.setFrameOrigin(NSPoint(x: x, y: onScreen.minY - height))
        }
        panel.orderFront(nil)
        hoverPanel = panel
        if let kind {
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.borderWidth = 1
            panel.contentView?.layer?.borderColor =
                (kind == .error ? EditorTheme.errorUnderline : EditorTheme.warningUnderline).cgColor
        }
    }

    /// Closes the hover hint.
    public func hideHover() {
        cancelHoverClose()
        hoverPanel?.orderOut(nil)
        hoverPanel = nil
        isPointerOnHoverPanel = false
    }

    /// How long the panel survives after the pointer leaves it.
    static let hoverCloseGrace: TimeInterval = 0.45

    /// Message for the diagnostic under `location`, for a tooltip.
    public func diagnostic(at location: Int) -> InlineDiagnostic? {
        diagnostics.first { NSLocationInRange(location, $0.range) || location == $0.range.location }
    }

    /// Replaces all inline diagnostics (live checks reported by clangd).
    ///
    /// Uses temporary attributes, so the marks never enter the text storage, never
    /// trigger undo, and never get saved into the file.
    public func setDiagnostics(_ items: [InlineDiagnostic]) {
        diagnostics = items
        guard let layoutManager else { return }
        let ns = string as NSString
        // Clear whatever is actually painted, not the ranges we remember.
        //
        // The remembered ranges are offsets into the text the server last saw.
        // Once the user edits, those offsets point somewhere else, so removing
        // "the previous ranges" left a red box behind on whichever character now
        // occupied the old position — a mark that never went away.
        let cleared = removePaintedMarkers(layoutManager: layoutManager, in: ns)
        // Those characters also lost the syntax colour underneath the mark; put it
        // back before painting the new ones, or they stay plain.
        if cleared { scheduleRehighlight() }
        for item in items {
            // Clamp: the server reports ranges against the text it last saw, which
            // can be one edit behind ours.
            let clamped = NSIntersectionRange(item.range, NSRange(location: 0, length: ns.length))
            guard clamped.length > 0 else { continue }
            let isError = item.kind == .error
            // Four cues, because one is not enough to find a problem by eye: a
            // tinted background, red text, a solid squiggle, and a gutter badge.
            layoutManager.addTemporaryAttributes([
                .backgroundColor: isError ? EditorTheme.errorBackground : EditorTheme.warningBackground,
                .foregroundColor: isError ? EditorTheme.errorText : EditorTheme.warningText
            ], forCharacterRange: clamped)
        }
        refreshGutterMarkers()
    }

    /// Recolors the view when the system switches between light and dark.
    ///
    /// The syntax colours are installed as *temporary* attributes, which hold
    /// concrete `NSColor`s resolved when they were written. Switching appearance
    /// therefore left the old palette in place — on a dark background white-ish
    /// text looks like the highlighting simply stopped working. Re-running the
    /// highlighter rebuilds every run against the new appearance.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = EditorTheme.background
        textColor = EditorTheme.plainText
        insertionPointColor = EditorTheme.cursor
        selectedTextAttributes = [.backgroundColor: EditorTheme.selection]
        onAppearanceChange?()
    }

    /// Called after the effective appearance changed, so the engine can repaint.
    public var onAppearanceChange: (() -> Void)?

    /// The predicted continuation shown as ghost text after the caret.
    let inlineSuggestion = InlineSuggestionView()
    /// Asks the owner for a prediction. Must answer quickly or not at all.
    public var onRequestSuggestion: ((_ prefixToCaret: String, _ suffix: String) -> String?)?
    /// Called when the user accepts the ghost text (Tab).
    public var onAcceptSuggestion: (() -> Void)?
    /// Called after every edit, so in-flight predictions can be invalidated.
    public var onDocumentRevisionChanged: (() -> Void)?
    /// Pending prediction request.
    var pendingSuggestionWork: DispatchWorkItem?


    /// Shows a prediction at the caret, or clears it when there is none.

    /// Inserts the pending suggestion as a normal, undoable edit.
    ///
    /// Returns false when there is nothing to accept, so Tab can fall back to
    /// indentation.
    @discardableResult


    /// Draws the squiggles; the drawing itself lives in an extension below.
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Self.drawDiagnosticSquiggles(in: self, dirtyRect: dirtyRect)
        drawInlineSuggestion()
    }



    /// Removes every inline diagnostic.
    public func clearErrorMarkers() {
        diagnostics = []
        guard let layoutManager else { return }
        let cleared = removePaintedMarkers(layoutManager: layoutManager,
                                           in: string as NSString)
        if cleared { scheduleRehighlight() }
        refreshGutterMarkers()
    }

    /// Pushes the current diagnostics' line numbers to the gutter.
    ///
    /// The n-th line the marks belong to, so the gutter can draw a badge next to
    /// the line — the cue that survives even when the offending token is a single
    /// character, or scrolled out of the visible columns.
    private func refreshGutterMarkers() {
        guard let scrollView = enclosingScrollView,
              let ruler = scrollView.verticalRulerView as? LineNumberRuler else { return }
        let ns = string as NSString
        var errors: Set<Int> = []
        var warnings: Set<Int> = []
        for item in diagnostics {
            guard item.range.location <= ns.length else { continue }
            let lineRange = ns.lineRange(for: NSRange(location: item.range.location, length: 0))
            let line = ns.substring(to: lineRange.location).components(separatedBy: "\n").count
            if item.kind == .error { errors.insert(line) } else { warnings.insert(line) }
        }
        ruler.errorLines = errors
        ruler.warningLines = warnings
        ruler.needsDisplay = true
    }

    // MARK: - Completion hook (not implemented in this version)

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        // AppKit's own list cannot grey out placeholders, so it is not used; the
        // custom panel handles suggestions. Returning nil leaves "Edit > Complete"
        // to `showCompletions(_:)`.
        if completionProvider is BuiltinCompletionProvider { return nil }
        var selected = 0
        let result = super.completions(forPartialWordRange: charRange, indexOfSelectedItem: &selected)
        index?.pointee = selected
        return result
    }

    private func builtinContextForCaret() -> CompletionContext {
        let location = selectedRange().location
        guard location > 0 else { return .code }
        let before = (string as NSString).substring(to: location).trimmingCharacters(in: .whitespaces)
        return before.hasSuffix("#") ? .preprocessor : .code
    }

    /// Closes the open undo group so the next edit starts a new one.
    private func endCurrentUndoGroup() {
        guard let manager = undoManager, manager.groupingLevel > 0 else { return }
        manager.endUndoGrouping()
        manager.beginUndoGrouping()
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


// MARK: - Squiggles

extension CodeTextView {
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
    private func scheduleRehighlight() {
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
