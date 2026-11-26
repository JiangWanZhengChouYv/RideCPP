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
    }

    /// Asks for a hover query at a character offset (set by the app).
    public var onHoverQuery: ((Int) -> Void)?
    /// Called when a button inside the hover panel is clicked.
    public var onHoverAction: ((HoverAction) -> Void)?
    /// Called after every edit so a semantic provider can keep its server in sync.
    public var onDocumentSync: ((String, URL?) -> Void)?
    /// Inline diagnostics currently drawn.
    private var diagnostics: [InlineDiagnostic] = []
    /// Read-only view of the current underlines, for tests and diagnostics panels.
    public var diagnosticsForTesting: [InlineDiagnostic] { diagnostics }
    /// Floating hover hint, if one is visible.
    private var hoverPanel: HoverPanel?
    /// True while the pointer rests on the hover panel itself (over its button).
    var isPointerOnHoverPanel = false
    /// Queued documentation query, cancelled when the pointer moves on.
    private var pendingHoverWorkItem: DispatchWorkItem?
    /// Offset the last documentation query was made for, so resting on one
    /// character does not keep re-asking clangd.
    private var lastQueriedHoverIndex: Int?

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
        /// Supplied here rather than looked up in the view: `EditorWindow` sits
        /// below the app layer, so it has no access to the localization table.
        var title: String {
            switch self {
            case .fix: return "Fix"
            }
        }
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
        guard let onHoverQuery else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: point) else {
            cancelPendingHover()
            return
        }
        // While the pointer is on the panel, leave it alone: it is on its way to
        // the fix button, and replacing it would pull the button away.
        guard !isPointerOnHoverPanel else { return }
        // Over a squiggle the diagnostic is the answer; asking clangd would only
        // add latency and, on code that does not parse, return nothing useful.
        if let diagnostic = diagnostic(at: index) {
            cancelPendingHover()
            showHover(diagnostic.hoverText, at: index, kind: diagnostic.kind,
                      action: .fix(DiagnosticFixTarget(diagnostic: diagnostic)))
            return
        }
        // Documentation comes from clangd and takes a round trip. Asking on every
        // mouse move queued a request per pixel, so the answer arrived a second or
        // more late, and the panel would appear long after the pointer moved on.
        // Wait for the pointer to settle first; the squiggle path above stays
        // instant because it needs no server.
        guard index != lastQueriedHoverIndex else { return }
        scheduleHoverQuery(at: index, handler: onHoverQuery)
    }

    /// Waits for the pointer to stop moving before asking clangd for documentation.
    private func scheduleHoverQuery(at index: Int, handler: @escaping (Int) -> Void) {
        pendingHoverWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastQueriedHoverIndex = index
            handler(index)
        }
        pendingHoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverSettleDelay, execute: work)
    }

    /// Cancels a queued documentation query (the pointer moved or left a squiggle).
    private func cancelPendingHover() {
        pendingHoverWorkItem?.cancel()
        pendingHoverWorkItem = nil
        lastQueriedHoverIndex = nil
    }

    /// How long the pointer must rest before documentation is requested.
    static let hoverSettleDelay: TimeInterval = 0.25

    /// Character offset under a point, or nil when the point is past the text.
    private func characterIndex(at point: NSPoint) -> Int? {
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
            self?.isPointerOnHoverPanel = inside
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
            panel.setFrameOrigin(NSPoint(x: x, y: onScreen.minY - height - 2))
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
        hoverPanel?.orderOut(nil)
        hoverPanel = nil
        isPointerOnHoverPanel = false
        cancelPendingHover()
    }

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
        let full = NSRange(location: 0, length: ns.length)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        for item in items {
            // Clamp: the server reports ranges against the text it last saw, which
            // can be one edit behind ours.
            let clamped = NSIntersectionRange(item.range, NSRange(location: 0, length: ns.length))
            guard clamped.length > 0 else { continue }
            let color = item.kind == .error ? EditorTheme.errorUnderline : EditorTheme.warningUnderline
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: color
            ], forCharacterRange: clamped)
        }
    }

    /// Removes every inline diagnostic.
    public func clearErrorMarkers() {
        diagnostics = []
        guard let layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
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

/// Contents of the hover hint: the message, plus a fix button when clangd has
/// one to offer.
///
/// Written as a view rather than a plain text field because the message alone
/// left "fix this" reachable only through a menu shortcut, which nobody would
/// find while already pointing at the problem.
final class HoverContentView: HoverTrackingView {

    var onAction: (() -> Void)?

    private let label: NSTextField
    private let button: NSButton?
    private let width: CGFloat
    private let padding: CGFloat = 8
    private let spacing: CGFloat = 8
    private let buttonHeight: CGFloat = 20

    init(text: String, width: CGFloat, actionTitle: String?) {
        self.width = width
        label = NSTextField(wrappingLabelWithString: text)
        button = actionTitle.map { NSButton(title: $0, target: nil, action: nil) }
        super.init(frame: .zero)

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width - padding * 2
        addSubview(label)

        if let button {
            // A bordered control reads as clickable; a link style would be easy to
            // miss against code.
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = #selector(fixTapped)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fixTapped() {
        onAction?()
    }

    /// Height that fits the message and, when present, the button row.
    var fittingHeight: CGFloat {
        let textHeight = label.sizeThatFits(NSSize(width: width - padding * 2, height: 10_000)).height
        let row = button == nil ? 0 : buttonHeight + spacing - 2
        return ceil(max(24, textHeight + padding * 2 + row))
    }

    override func layout() {
        super.layout()
        let innerWidth = width - padding * 2
        let textHeight = label.sizeThatFits(NSSize(width: innerWidth, height: 10_000)).height
        // AppKit's origin is bottom-left, so the button sits at the bottom and the
        // message above it.
        var textBottom = padding
        if let button {
            let buttonWidth = min(innerWidth, max(72, button.intrinsicContentSize.width + 16))
            button.frame = NSRect(x: padding, y: padding, width: buttonWidth, height: buttonHeight)
            textBottom = padding + buttonHeight + spacing - 2
        }
        label.frame = NSRect(x: padding, y: textBottom, width: innerWidth, height: textHeight)
    }
}

/// Hover panel that reports when the pointer is inside it.
///
/// The message is not the only thing to click any more: a pointer travelling to
/// the fix button leaves the diagnostic's range, which would otherwise replace
/// the panel out from under the button.
final class HoverPanel: NSPanel {
    /// Called when the pointer enters or leaves the panel.
    var onPointerInside: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

}

/// Reports pointer entry and exit for the hover panel's window.
///
/// Tracking areas belong to views, not windows, so this sits on the content view
/// and forwards the two events the panel cares about.
class HoverTrackingView: NSView {
    var onPointerInside: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerInside?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerInside?(false)
    }
}
