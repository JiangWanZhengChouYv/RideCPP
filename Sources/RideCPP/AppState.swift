import AppKit
import Combine
import EditorCore
import BuildKit
import EditorWindow

/// Application-wide state: open tabs, output, diagnostics and the build/run
/// session. Single instance so menu commands can reach it.
@MainActor
public final class AppState: ObservableObject {

    public static let shared = AppState()

    @Published public var documents: [DocumentModel] = []
    @Published public var selectedDocumentID: UUID?

    @Published public var outputText: String = ""
    @Published public var diagnostics: [Diagnostic] = []
    @Published public var statusText: String = L10n.t("status.ready")
    @Published public var isBuilding = false
    @Published public var isRunning = false
    /// Raw compiler output, kept for the Problems list and error summaries. It
    /// is deliberately not shown in the program output view.
    @Published public var compilerLog: String = ""
    /// The tab whose program is running, so input goes to it even if the user
    /// switches tabs mid-run.
    @Published public var runningDocumentID: UUID?
    /// Mirrors the active document's undo stack, so the Edit menu's Undo/Redo
    /// items enable and disable as the user types (a plain computed property
    /// would never re-render the menu).
    /// Name of the function/type the caret is inside, for the breadcrumb.
    @Published public private(set) var selectedSymbolName: String?
    /// "Ln 12, Col 5" indicator.
    @Published public private(set) var caretPositionText = "Ln 1, Col 1"
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    /// Statistics of the most recent program run, kept for the status bar/tests.
    @Published public private(set) var lastRunDuration: TimeInterval = 0
    @Published public private(set) var lastRunCPUTime: TimeInterval = 0
    @Published public var lastRunPeakMemoryBytes: UInt64?
    /// Lines typed before the program started; delivered as soon as it runs.
    @Published public private(set) var queuedInputLines: [String] = []
    @Published public var isOutputVisible = true
    @Published public var outputSegment: OutputSegment = .console

    public enum OutputSegment: Int, CaseIterable, Identifiable {
        case console
        case problems

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .console: return L10n.t("output.segment.console")
            case .problems: return L10n.t("output.segment.problems")
            }
        }
    }

    public let settings: SettingsStore
    private let buildService = BuildService()
    private var buildTask: Task<Void, Never>?
    /// Bytes of output yet to be flushed into `outputText`, batched per run-loop
    /// turn so a chatty program cannot flood SwiftUI with updates.
    private var pendingProgramOutput = ""
    private var isFlushScheduled = false
    /// Incremented for every build/run so a finishing older session can never
    /// clobber the state of a newer one.
    private var sessionGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    private static let outputLineLimit = 5000
    private static let recentFilesKey = "recentFiles"
    private static let recentFilesLimit = 6

    /// Recently opened or saved files, newest first, shown on the welcome page.
    @Published public private(set) var recentFiles: [URL] = []

    private init(settings: SettingsStore = .shared) {
        self.settings = settings
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsDidChange() }
            .store(in: &cancellables)
        observeUndoStacks()
        recentFiles = (UserDefaults.standard.stringArray(forKey: Self.recentFilesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        // Look for a newer release in the background; failures are silent.
        updates.checkAutomatically()

        // Load the remembered symbol store, then keep learning from each document.
        DispatchQueue.global(qos: .utility).async {
            UserSymbolStore.shared.load()
            DispatchQueue.main.async {
                UserSymbolStore.shared.remember(declarationsIn: self.selectedDocument?.text ?? "")
            }
        }

        // Start clangd for semantic completion. It is optional: without it the
        // built-in text-based provider keeps working.
        DispatchQueue.main.async { [weak self] in
            self?.configureSemanticCompletion()

        }

        // Verify the keyword set in the background (one ~25 ms compiler run, then
        // cached on disk). Header vocabulary is indexed on demand per document,
        // never at launch.
        KeywordTable.prepare(compilerPath: settings.compilerPath)

        // No document is created at launch on purpose: opening straight into a
        // blank "Untitled 1" hides the choice of starting a new file or opening
        // an existing one. The empty state in `ContentView` offers both.
    }

    public var selectedDocument: DocumentModel? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    // MARK: - Tabs

    @discardableResult
    public func newDocument() -> DocumentModel {
        // Reuse the smallest free number: closing "Untitled 1" must let the next
        // new tab be "Untitled 1" again, not an ever-increasing count.
        let number = nextUntitledNumber()
        let name = L10n.t("file.untitledTab", number)
        let template = """
        #include <iostream>

        int main() {
            std::cout << "Hello, RideCPP!" << std::endl;
            return 0;
        }
        """
        let document = DocumentModel(title: name,
                                     untitledNumber: number,
                                     text: template,
                                     fileURL: nil,
                                     settings: settings.editSettings,
                                     fontSize: settings.fontSize,
                                     showLineNumbers: settings.showLineNumbers)
        // A new tab needs the semantic wiring as much as an opened file does.
        // Skipping it left "Untitled" tabs with no completion, no hover and no
        // live diagnostics — the exact path most algorithm problems start from.
        attachSemanticProvider(to: document)
        documents.append(document)
        selectedDocumentID = document.id
        updateWindowTitle()
        refreshUndoAvailability()
        return document
    }

    /// Lowest untitled number that is not currently used by an open tab.
    private func nextUntitledNumber() -> Int {
        let used = Set(documents.compactMap(\.untitledNumber))
        var candidate = 1
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    public func select(_ id: UUID) {
        selectedDocumentID = id
        updateWindowTitle()
        refreshUndoAvailability()
        selectedDocument?.focusEditor()
    }

    public func close(document: DocumentModel, askToSave: Bool = true) {
        if askToSave, document.isDirty {
            guard confirmDiscardChanges(for: document) else { return }
        }
        // A program belonging to the tab being closed has nowhere to print to.
        if runningDocumentID == document.id {
            stop()
        }
        documents.removeAll { $0.id == document.id }
        // Forget the file's diagnostics with it, or reopening the path later
        // would show stale squiggles from the previous session.
        diagnosticsByFile.removeValue(forKey: document.semanticURL.standardizedFileURL)
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.last?.id
        }
        refreshUndoAvailability()
        // Closing the last tab shows the welcome page; it must not silently open
        // a replacement document (that made the tab look impossible to close).
        updateWindowTitle()
    }

    public func open(urls: [URL]) {
        for url in urls {
            if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                selectedDocumentID = existing.id
                continue
            }
            do {
                let (text, usedFallback) = try readText(at: url)
                let document = DocumentModel(title: url.lastPathComponent,
                                             text: text,
                                             fileURL: url,
                                             settings: settings.editSettings,
                                             fontSize: settings.fontSize,
                                             showLineNumbers: settings.showLineNumbers)
                attachSemanticProvider(to: document)
                documents.append(document)
                selectedDocumentID = document.id
                rememberRecent(url)
                UserSymbolStore.shared.remember(declarationsIn: text)
                if usedFallback {
                    appendOutput("\n" + L10n.t("alert.encoding", url.lastPathComponent) + "\n", revealPanel: true)
                }
            } catch {
                presentError(L10n.t("alert.readFailed", url.lastPathComponent),
                             info: error.localizedDescription)
            }
            updateWindowTitle()
        }
    }

    /// Reads a text file as UTF-8, falling back to Latin-1 for legacy sources.
    private func readText(at url: URL) throws -> (String, Bool) {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return (TextCoordinates.normalizeLineEndings(stripBOM(text)), false)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (TextCoordinates.normalizeLineEndings(text), true)
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Saves the document so the build compiles what the user sees.
    ///
    /// Returns false when the user cancels the save panel, in which case the
    /// build is abandoned rather than compiling stale content.
    private func saveBeforeBuilding(_ document: DocumentModel) -> Bool {
        if document.fileURL != nil {
            return save(document: document)
        }
        // Untitled document: it needs a real path before it can be built.
        let saved = saveAs(document: document)
        if saved { statusText = L10n.t("status.saved") }
        return saved
    }

    public func save(document: DocumentModel) -> Bool {
        guard let url = document.fileURL else {
            return saveAs(document: document)
        }
        return write(document: document, to: url)
    }

    public func saveAs(document: DocumentModel) -> Bool {
        if let override = saveAsOverrideURL {
            return write(document: document, to: override)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? defaultFileName(for: document)
        panel.canCreateDirectories = true
        panel.title = L10n.t("file.saveAs")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(document: document, to: url)
    }

    private func write(document: DocumentModel, to url: URL) -> Bool {
        do {
            try document.persistedText.write(to: url, atomically: true, encoding: .utf8)
            document.markSaved(to: url)
            rememberRecent(url)
            refreshUndoAvailability()
            updateWindowTitle()
            return true
        } catch {
            presentError(L10n.t("alert.writeFailed", url.lastPathComponent),
                         info: error.localizedDescription)
            return false
        }
    }

    private func defaultFileName(for document: DocumentModel) -> String {
        let base = document.title.replacingOccurrences(of: " •", with: "")
        return base.contains(".") ? base : base + ".cpp"
    }

    private func confirmDiscardChanges(for document: DocumentModel) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.unsaved.title", document.title)
        alert.informativeText = L10n.t("alert.unsaved.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("alert.save"))
        alert.addButton(withTitle: L10n.t("alert.dontSave"))
        alert.addButton(withTitle: L10n.t("alert.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save(document: document)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Called from `applicationShouldTerminate` so quitting can cancel.
    public func confirmQuit() -> NSApplication.TerminateReply {
        let dirty = documents.filter(\.isDirty)
        guard !dirty.isEmpty else { return .terminateNow }
        for document in dirty {
            selectedDocumentID = document.id
            if !confirmDiscardChanges(for: document) {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    // MARK: - Updates

    /// In-app update flow, owned by its own controller.
    public lazy var updates: UpdateController = UpdateController(
        currentVersion: { SemanticVersion.current() },
        prepareForRelaunch: { [weak self] in self?.saveDirtyDocuments() }
    )

    /// Saves every modified document that has a real path.
    private func saveDirtyDocuments() {
        for document in documents where document.isDirty && document.fileURL != nil {
            _ = save(document: document)
        }
    }

    // MARK: - Undo / redo

    /// Observes undo-manager activity so the menu items track the real stack.
    private func observeUndoStacks() {
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshUndoAvailability()
            }
        }
    }

    /// Recomputes whether Undo/Redo are available for whatever is focused.
    /// Semantic (clangd) completion state, for settings and diagnostics.
    @Published public var semanticCompletionReady = false
    /// Live diagnostics for the focused document, exposed for the Problems panel.
    ///
    /// Diagnostics belong to a *file*, not to the app: storing one global list
    /// meant switching tabs showed the previous file's errors — and the Problems
    /// panel would list errors from a file that is not even on screen.
    public var liveDiagnostics: [LSPDiagnostic] {
        guard let url = selectedDocument?.semanticURL.standardizedFileURL else { return [] }
        return diagnosticsByFile[url] ?? []
    }
    /// Latest clangd result per file, keyed by standardized URL.
    @Published private var diagnosticsByFile: [URL: [LSPDiagnostic]] = [:]

    private var semanticProvider: SemanticCompletionProvider?
    /// Workspace root clangd is bound to.
    private var semanticWorkspace: URL?

    /// Creates the clangd-backed provider and wires it to every open document.
    func configureSemanticCompletion() {
        // The hover panel's buttons live in EditorWindow, which cannot read the
        // localization table; hand it the translated labels.
        CodeTextView.setHoverActionTitle(L10n.t("hover.fix"), for: "fix")
        let workspace = documents.first?.fileURL?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        guard let provider = SemanticCompletionProvider(
            workingDirectory: workspace,
            standard: settings.standard
        ) else {
            semanticCompletionReady = false
            return
        }
        semanticProvider = provider
        semanticWorkspace = workspace
        for document in documents {
            document.engine.textView.completionProvider = provider
            document.engine.textView.documentFileURL = document.semanticURL
            document.engine.textView.onDocumentSync = { text, url in
                provider.syncDocument(text: text, fileURL: url)
            }
            provider.syncDocument(text: document.text, fileURL: document.semanticURL)
        }
        semanticCompletionReady = provider.isSemanticReady
        // Live diagnostics from clangd: underline the ranges it reports.
        provider.onDiagnostics = { [weak self] url, items, text in
            self?.applyLiveDiagnostics(items, for: url, text: text)
        }
        // Hover documentation, shown as a floating hint.
        for document in documents {
            wireHoverAndNavigation(document, provider: provider)
        }
    }

    /// Converts clangd diagnostics into editor underlines for the matching document.
    ///
    /// Positions arrive as LSP line/character pairs, which are 0-based and counted in
    /// UTF-16 units — the same units `NSString` uses, so the conversion is direct.
    private func applyLiveDiagnostics(_ items: [LSPDiagnostic], for url: URL, text: String) {
        diagnosticsByFile[url.standardizedFileURL] = items
        guard let document = documents.first(where: {
            $0.semanticURL.standardizedFileURL == url.standardizedFileURL
        }) else { return }
        // Convert against the text the diagnostics were computed from, not the
        // current text: while the user types, the two differ and the marks would
        // land on unrelated lines.
        let ns = text as NSString
        var inline: [CodeTextView.InlineDiagnostic] = []
        for item in items {
            guard let range = Self.characterRange(for: item.range, in: ns) else { continue }
            let kind: CodeTextView.InlineDiagnostic.Kind = item.severity == .error ? .error : .warning
            inline.append(.init(range: range, kind: kind, message: item.message, code: item.code))
        }
        document.engine.textView.setDiagnostics(inline)
    }

    /// Installs the hover panel's fix button on one document.
    ///
    /// Only diagnostics produce a hover panel now, so there is no documentation
    /// query to wire up: hovering ordinary code shows nothing.
    private func wireHoverAndNavigation(_ document: DocumentModel, provider: SemanticCompletionProvider) {
        // The fix button inside the hover panel.
        document.engine.textView.onHoverAction = { [weak self, weak document] action in
            guard let self, let document else { return }
            switch action {
            case .fix(let target):
                self.applyFix(for: target, in: document)
            }
        }
    }

    /// Jumps to the definition of the symbol at the caret (⌘-click or a shortcut).
    public func goToDefinition() {
        guard let document = selectedDocument, let provider = semanticProvider else { return }
        let tv = document.engine.textView
        tv.hideHover()
        var offset = tv.selectedRange().location
        // If the caret sits at the end of a word, look at the previous character so
        // the query lands inside the identifier.
        if offset > 0, offset >= (document.text as NSString).length { offset -= 1 }
        provider.definition(atOffset: offset, in: document.text, fileURL: document.semanticURL) { [weak self] locations in
            guard let self, let first = locations.first else { return }
            self.openDefinition(first)
        }
    }

    /// Opens the file holding a definition and places the caret on it.
    private func openDefinition(_ location: LSPLocation) {
        guard let url = URL(string: location.uri) else { return }
        if let existing = documents.first(where: {
            $0.fileURL?.standardizedFileURL.path == url.standardizedFileURL.path
        }) {
            select(existing.id)
            existing.engine.jump(toLine: location.range.start.line + 1)
        } else if FileManager.default.fileExists(atPath: url.path) {
            open(urls: [url])
            selectedDocument?.engine.jump(toLine: location.range.start.line + 1)
        }
    }

    /// Points a newly opened document at the semantic provider as well.
    func attachSemanticProvider(to document: DocumentModel) {
        guard let provider = semanticProvider else { return }
        document.engine.textView.completionProvider = provider
        document.engine.textView.documentFileURL = document.semanticURL
        document.engine.textView.onDocumentSync = { text, url in
            provider.syncDocument(text: text, fileURL: url)
        }
        provider.syncDocument(text: document.text, fileURL: document.semanticURL)
        wireHoverAndNavigation(document, provider: provider)
    }

    /// Updates the breadcrumb symbol and the Ln/Col readout.
    public func updateCaretContext(line: Int, column: Int, text: String) {
        caretPositionText = "Ln \(line), Col \(column)"
        // Nearest preceding declaration is the enclosing symbol.
        let outline = DocumentOutline.items(in: text)
        let enclosing = outline.last { $0.line <= line && ($0.kind == .function || $0.kind == .structure
                                                          || $0.kind == .class || $0.kind == .enumeration) }
        if selectedSymbolName != enclosing?.name {
            selectedSymbolName = enclosing?.name
        }
    }

    public func refreshUndoAvailability() {
        let manager = undoManagerForFocus() ?? selectedDocument?.undoManager
        let undo = manager?.canUndo ?? false
        let redo = manager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }

    /// The undo manager that ⌘Z should act on: a focused plain text view (a
    /// settings field, the console) keeps its own, otherwise the code editor's
    /// document manager is used.
    private func undoManagerForFocus() -> UndoManager? {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return selectedDocument?.undoManager
        }
        if responder is CodeTextView {
            return selectedDocument?.undoManager
        }
        // The field editor's manager belongs to the window.
        return responder.undoManager ?? NSApp.keyWindow?.undoManager
    }

    public func undo() {
        guard let manager = undoManagerForFocus() ?? selectedDocument?.undoManager,
              manager.canUndo else { return }
        manager.undo()
        selectedDocument?.updateDirtyState()
        refreshUndoAvailability()
    }

    public func redo() {
        guard let manager = undoManagerForFocus() ?? selectedDocument?.undoManager,
              manager.canRedo else { return }
        manager.redo()
        selectedDocument?.updateDirtyState()
        refreshUndoAvailability()
    }

    // MARK: - Build & run

    /// Test-only override: when set, "Save As…" resolves to this URL instead of
    /// showing a panel, so the build auto-save path can be exercised headlessly.
    public var saveAsOverrideURL: URL?

    public func build(andRun: Bool) {
        // `sessionGeneration` already makes a finishing older session harmless,
        // so a stale `buildTask` must not block the next run: `isRunning` flips
        // to false slightly before the task itself winds down.
        guard !isBuilding, !isRunning else { return }
        guard let document = selectedDocument else { return }

        // Building saves first: what runs is what is on disk, so a stray crash or
        // a later revert never leaves the file behind the code that was tested.
        // An untitled tab has no path yet and asks for one.
        guard saveBeforeBuilding(document) else { return }

        let compilerPath = settings.compilerPath
        guard FileManager.default.isExecutableFile(atPath: compilerPath) else {
            presentCompilerMissing(compilerPath)
            return
        }

        // Unsaved tabs compile from a scratch file so diagnostics map back here.
        // A tab whose backing file was deleted or moved also falls back to a
        // scratch copy rather than failing to compile.
        let sourceURL: URL
        let displayName: String
        if let fileURL = document.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            sourceURL = fileURL
            displayName = fileURL.lastPathComponent
        } else {
            let scratch = buildService.prepareScratchFile(contents: document.persistedText,
                                                          tabID: document.id,
                                                          suggestedName: defaultFileName(for: document))
            sourceURL = URL(fileURLWithPath: scratch.path)
            displayName = scratch.displayName
            document.setCompileLocation(sourceURL)
        }

        let workingDirectory = sourceURL.deletingLastPathComponent().path
        let executableURL = executableLocation(for: sourceURL)

        let request = BuildRequest(action: andRun ? .run : .build,
                                   sourcePath: sourceURL.path,
                                   sourceDisplayName: displayName,
                                   compilerPath: compilerPath,
                                   standard: settings.standard,
                                   optimization: settings.optimization,
                                   extraFlags: settings.extraFlagList,
                                   runArguments: settings.runArgumentList,
                                   outputPath: executableURL.path,
                                   workingDirectory: workingDirectory)

        diagnostics = []
        compilerLog = ""
        if !andRun { queuedInputLines = [] }
        document.engine.textView.clearErrorMarkers()
        // A run shows a clean program view; a plain build lists problems.
        outputSegment = .console
        if andRun {
            flushPendingProgramOutput()
            outputText = ""
        }

        statusText = L10n.t("status.building")
        isBuilding = true
        runningDocumentID = document.id
        sessionGeneration += 1
        let generation = sessionGeneration

        buildTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.buildService.perform(request) {
                // Ignore events from a session that has been superseded.
                guard generation == self.sessionGeneration else { return }
                switch event {
                case .started:
                    break
                case .compilerOutput(let text):
                    // Compiler chatter feeds diagnostics only, never the run view.
                    self.compilerLog += text
                case .diagnostics(let parsed):
                    self.diagnostics = parsed
                    self.markDiagnostics(in: document, parsed: parsed)
                case .finished(let exitCode, let succeeded):
                    self.isBuilding = false
                    if succeeded {
                        self.statusText = L10n.t("status.succeeded")
                        if andRun { self.outputSegment = .console }
                    } else {
                        self.statusText = L10n.t("status.failed")
                        self.outputSegment = .problems
                        self.appendOutput(Self.failureSummary(exitCode: exitCode))
                    }
                case .runStarted:
                    self.isRunning = true
                    self.statusText = L10n.t("status.running")
                    self.outputSegment = .console
                    if !self.isOutputVisible { self.isOutputVisible = true }
                    // Input typed before the program started is sent now.
                    self.flushQueuedInput()
                case .runOutput(let text):
                    self.appendProgramOutput(text)
                case .runFinished(let exitCode, let duration, let cpuTime, let peakMemoryBytes):
                    self.flushPendingProgramOutput()
                    self.isRunning = false
                    self.runningDocumentID = nil
                    self.queuedInputLines = []
                    // Algorithms are judged on time and memory, so report both next
                    // to the exit code.
                    self.lastRunDuration = duration
                    self.lastRunCPUTime = cpuTime
                    self.lastRunPeakMemoryBytes = peakMemoryBytes
                    let time = RunStatisticsFormatter.duration(duration)
                    let summary: String
                    if let peakMemoryBytes {
                        summary = L10n.t("output.runStats",
                                         Int(exitCode),
                                         time,
                                         RunStatisticsFormatter.memory(peakMemoryBytes))
                    } else {
                        summary = L10n.t("output.runStatsNoMemory", Int(exitCode), time)
                    }
                    self.statusText = summary
                    self.appendOutput("\n" + summary + "\n")
                case .failed(let message):
                    self.isBuilding = false
                    self.isRunning = false
                    self.runningDocumentID = nil
                    self.statusText = L10n.t("status.failed")
                    self.outputSegment = .problems
                    self.appendOutput("\n✗ \(message)\n")
                }
            }
            guard generation == self.sessionGeneration else { return }
            self.isBuilding = false
            self.isRunning = false
            self.runningDocumentID = nil
            self.flushPendingProgramOutput()
            self.buildTask = nil
        }
    }

    public func stop() {
        sessionGeneration += 1
        buildService.cancel()
        buildTask?.cancel()
        buildTask = nil
        isBuilding = false
        isRunning = false
        runningDocumentID = nil
        queuedInputLines = []
        flushPendingProgramOutput()
        statusText = L10n.t("status.stopped")
    }

    /// A line submitted from the console (Return in the console's input area).
    ///
    /// While a program runs the line goes straight to it. Before that it is
    /// queued and delivered the moment the program starts, exactly like typing
    /// ahead in a terminal. The console echoes the line into its transcript.
    public func submitConsoleLine(_ line: String) {
        guard !line.isEmpty else { return }
        if isRunning {
            guard buildService.send(input: line) else { return }
            appendProgramOutput(line + "\n")
        } else {
            queuedInputLines.append(line)
            appendProgramOutput(line + "\n")
        }
    }

    private func flushQueuedInput() {
        guard !queuedInputLines.isEmpty else { return }
        let lines = queuedInputLines
        queuedInputLines = []
        for line in lines {
            _ = buildService.send(input: line)
        }
    }

    /// Lines typed before the program started, still waiting to be delivered.
    public var pendingQueuedInput: Int { queuedInputLines.count }

    /// Sends Ctrl-C to the running program.
    public func interruptProgram() {
        buildService.interruptProgram()
    }

    private static func failureSummary(exitCode: Int32) -> String {
        let title = L10n.t("status.failed")
        return exitCode >= 0 ? "\n✗ \(title) (exit \(exitCode))\n" : "\n✗ \(title)\n"
    }

    private func executableLocation(for sourceURL: URL) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-builds", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8))")
    }

    private func markDiagnostics(in document: DocumentModel, parsed: [Diagnostic]) {
        guard let source = document.compileURL?.path else { return }
        let errors = DiagnosticsParser.diagnostics(parsed,
                                                   matching: source,
                                                   workingDirectory: source.isEmpty ? nil : (source as NSString).deletingLastPathComponent)
        guard let first = errors.first(where: { $0.severity == .error }) ?? errors.first else { return }
        document.engine.textView.goTo(line: first.line, column: first.column, highlightError: true)
    }

    // MARK: - Formatting

    public func formatDocument() {
        guard let document = selectedDocument else { return }
        guard let executable = settings.clangFormatExecutable else {
            let alert = NSAlert()
            alert.messageText = L10n.t("alert.formatFailed")
            alert.informativeText = L10n.t("alert.clangFormatMissing")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let textView = document.engine.textView
        let source = textView.string
        let selection = textView.selectedRange()
        let fileName = document.fileURL?.lastPathComponent
            ?? (document.title.replacingOccurrences(of: " •", with: "") + ".cpp")
        let lineBefore = TextCoordinates.lineAndColumn(at: selection.location, in: source)?.line ?? 1

        Task { [weak self] in
            do {
                let formatted = try await FormatterService.formatAsync(source: source,
                                                                       fileName: fileName,
                                                                       executablePath: executable,
                                                                       style: self?.settings.clangFormatStyle ?? "LLVM")
                guard let self, formatted != source else { return }
                // Keep the caret on the same line number after reformatting.
                let newText = TextCoordinates.normalizeLineEndings(formatted)
                let targetOffset = TextCoordinates.utf16Offset(ofLine: lineBefore, in: newText) ?? 0
                textView.replaceAllText(with: newText,
                                        selection: NSRange(location: targetOffset, length: 0),
                                        actionName: L10n.t("edit.formatDocument"))
                document.updateDirtyState()
                self.statusText = L10n.t("status.ready")
            } catch {
                guard let self else { return }
                self.presentError(L10n.t("alert.formatFailed"), info: error.localizedDescription)
            }
        }
    }

    /// True when a formatter is available, used to enable/disable the menu item.
    public var canFormat: Bool { settings.clangFormatExecutable != nil }

    // MARK: - Output

    public func appendOutput(_ text: String, revealPanel: Bool = false) {
        outputText += text
        // Trim from the front when the panel grows past the line budget.
        let lines = outputText.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.outputLineLimit {
            outputText = lines.suffix(Self.outputLineLimit).joined(separator: "\n")
        }
        if revealPanel { isOutputVisible = true }
    }

    /// Appends program output. Batched to at most one UI update per run-loop
    /// turn, so programs that print in tight loops stay responsive.
    public func appendProgramOutput(_ text: String) {
        pendingProgramOutput += text
        if !isFlushScheduled {
            isFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingProgramOutput()
            }
        }
    }

    public func flushPendingProgramOutput() {
        isFlushScheduled = false
        guard !pendingProgramOutput.isEmpty else { return }
        let chunk = pendingProgramOutput
        pendingProgramOutput = ""
        appendOutput(chunk)
    }

    /// Records a file in the recent list (newest first, de-duplicated).
    private func rememberRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        // Temporary files (scratch compiles, self-test runs) are noise in a
        // "recent files" list that is meant to reopen real work.
        if path.hasPrefix(FileManager.default.temporaryDirectory.path) { return }
        var updated = recentFiles.filter { $0.standardizedFileURL.path != path }
        updated.insert(url, at: 0)
        if updated.count > Self.recentFilesLimit {
            updated = Array(updated.prefix(Self.recentFilesLimit))
        }
        recentFiles = updated
        UserDefaults.standard.set(updated.map(\.path), forKey: Self.recentFilesKey)
    }

    /// Opens a file picker (used by menus and the empty editor state).
    public func openFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L10n.t("file.open")
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    /// True when the program is waiting for input (or the console has queued
    /// text), used to hide the console placeholder.
    public var hasPendingConsoleInput: Bool { !queuedInputLines.isEmpty || isRunning }

    public func clearOutput() {
        pendingProgramOutput = ""
        outputText = ""
        compilerLog = ""
        diagnostics = []
        selectedDocument?.engine.textView.clearErrorMarkers()
    }

    // MARK: - Settings propagation

    private func settingsDidChange() {
        let edit = settings.editSettings
        for document in documents {
            document.apply(settings: edit,
                           fontSize: settings.fontSize,
                           showLineNumbers: settings.showLineNumbers)
        }
    }

    // MARK: - Window / alerts

    private func updateWindowTitle() {
        for window in NSApp.windows where window.isVisible {
            window.title = selectedDocument?.title ?? L10n.appName
        }
    }

    private func presentCompilerMissing(_ path: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.compilerMissing")
        alert.informativeText = L10n.t("alert.compilerMissing.message", path)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.t("alert.openSettings"))
        if alert.runModal() == .alertSecondButtonReturn {
            openSettings()
        }
    }

    private func presentError(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    public func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Problems, ranges and navigation
//
// Moved out of the main class body to stay within the lint budget. Nothing
// here is `@Published`, so an extension has identical behaviour.
extension AppState {
/// Everything the Problems panel lists: compiler output plus clangd's live
/// diagnostics for the focused file.
///
/// The two must be merged, not concatenated: the compiler only speaks after a
/// build, while clangd speaks while typing. Listing them separately would make
/// the panel look empty for the common case of editing before building.
public var allProblems: [ProblemItem] {
    var items: [ProblemItem] = []
    let liveURL = selectedDocument?.fileURL?.standardizedFileURL
    for lsp in liveDiagnostics {
        // clangd positions are 0-based; the UI speaks in 1-based lines.
        items.append(ProblemItem(severity: lsp.severity == .error ? .error : .warning,
                                 message: lsp.message,
                                 file: liveURL?.path ?? "",
                                 line: lsp.range.start.line + 1,
                                 column: lsp.range.start.character + 1,
                                 code: lsp.code,
                                 source: .clangd))
    }
    for parsed in diagnostics {
        items.append(ProblemItem(severity: parsed.severity,
                                 message: parsed.message,
                                 file: parsed.file,
                                 line: parsed.line,
                                 column: parsed.column,
                                 code: nil,
                                 source: .compiler))
    }
    return items.sorted {
        if $0.severity != $1.severity { return $0.severity < $1.severity }
        if $0.file != $1.file { return $0.file < $1.file }
        return $0.line < $1.line
    }
}

/// One row in the Problems panel, from either source.
public struct ProblemItem: Identifiable, Hashable {
    public enum Source: Hashable {
        case clangd
        case compiler

        public var label: String { self == .clangd ? "clangd" : "compiler" }
    }

    public let id = UUID()
    public let severity: Diagnostic.Severity
    public let message: String
    public let file: String
    public let line: Int
    public let column: Int
    public let code: String?
    public let source: Source
}

/// Maps an LSP range onto `NSString` offsets.
static func characterRange(for range: LSPRange, in text: NSString) -> NSRange? {
    func offset(_ position: LSPPosition) -> Int? {
        var line = 0
        var index = 0
        while line < position.line {
            let found = text.range(of: "\n", options: [],
                                   range: NSRange(location: index, length: text.length - index))
            if found.location == NSNotFound { return nil }
            index = found.location + 1
            line += 1
        }
        return min(index + position.character, text.length)
    }
    guard let start = offset(range.start), let end = offset(range.end), end >= start else { return nil }
    return NSRange(location: start, length: end - start)
}

/// Replaces the action's range with its text, as one undoable edit.
func apply(codeAction action: LSPCodeAction, to document: DocumentModel) {
    guard let updated = SemanticCompletionProvider.apply(action, to: document.text) else {
        statusText = L10n.t("status.noFixAvailable")
        return
    }
    let textView = document.engine.textView
    let full = NSRange(location: 0, length: (document.text as NSString).length)
    // Going through the text view keeps undo, dirty tracking and the clangd
    // sync working exactly as if the user had typed the fix.
    if textView.shouldChangeText(in: full, replacementString: updated) {
        textView.replaceCharacters(in: full, with: updated)
        textView.didChangeText()
    }
    statusText = action.title
}

public func reveal(problem: ProblemItem) {
    // A clangd problem belongs to the focused file; a compiler problem names a
    // path, which has to be matched against the open tabs first.
    if problem.source == .clangd {
        if let document = selectedDocument {
            document.engine.textView.goTo(line: problem.line,
                                          column: problem.column,
                                          highlightError: problem.severity == .error)
        }
        return
    }
    let normalisedTarget = (problem.file as NSString).standardizingPath
    if let document = documents.first(where: { document in
        guard let compile = document.compileURL else { return false }
        let candidate = (compile.path as NSString).standardizingPath
        return candidate == normalisedTarget
            || (candidate as NSString).lastPathComponent == (normalisedTarget as NSString).lastPathComponent
    }) {
        selectedDocumentID = document.id
        document.engine.textView.goTo(line: problem.line,
                                      column: problem.column,
                                      highlightError: problem.severity == .error)
    } else if let document = selectedDocument {
        document.engine.textView.goTo(line: problem.line,
                                      column: problem.column,
                                      highlightError: problem.severity == .error)
    }
}

public func reveal(diagnostic: Diagnostic) {
    // Prefer the tab that produced the diagnostic.
    let targetPath = DiagnosticsParser.canonicalPath(diagnostic.file, workingDirectory: nil)
    let normalisedTarget = (targetPath as NSString).standardizingPath
    if let document = documents.first(where: { document in
        guard let compile = document.compileURL else { return false }
        let candidate = (compile.path as NSString).standardizingPath
        return candidate == normalisedTarget
            || (candidate as NSString).lastPathComponent == (normalisedTarget as NSString).lastPathComponent
    }) {
        selectedDocumentID = document.id
        document.engine.textView.goTo(line: diagnostic.line,
                                      column: diagnostic.column,
                                      highlightError: diagnostic.severity == .error)
    } else if let document = selectedDocument {
        document.engine.textView.goTo(line: diagnostic.line,
                                      column: diagnostic.column,
                                      highlightError: diagnostic.severity == .error)
    }
}

/// True when the caret sits on a diagnostic clangd may have a fix for, used
/// to enable the "Fix" menu item.
public var canFixDiagnostic: Bool {
    guard let document = selectedDocument else { return false }
    return document.engine.textView.diagnostic(at: document.engine.textView.selectedRange().location) != nil
}

/// Applies the best available quick fix for the diagnostic at the caret.
///
/// clangd marks its recommended fix with `isPreferred`; when several are
/// offered the preferred one is applied, otherwise the first. With no fix
/// available nothing happens and the status line says so, rather than opening
/// an empty menu.
public func fixDiagnosticAtCaret() {
    guard let document = selectedDocument, let provider = semanticProvider else { return }
    let tv = document.engine.textView
    guard let inline = tv.diagnostic(at: tv.selectedRange().location) else {
        statusText = L10n.t("status.noFixHere")
        return
    }
    // Match the editor's underline back to the server diagnostic, which is
    // what `textDocument/codeAction` expects in its context.
    guard let diagnostic = liveDiagnostics.first(where: {
        Self.characterRange(for: $0.range, in: document.text as NSString) == inline.range
    }) else {
        statusText = L10n.t("status.noFixHere")
        return
    }
    provider.codeActions(for: diagnostic, in: document.text,
                         fileURL: document.semanticURL) { [weak self] actions in
        guard let self else { return }
        guard let action = actions.first(where: \.isPreferred) ?? actions.first else {
            self.statusText = L10n.t("status.noFixAvailable")
            return
        }
        self.apply(codeAction: action, to: document)
    }
}

/// Applies clangd's preferred fix for a diagnostic the user clicked on.
///
/// Unlike `fixDiagnosticAtCaret` this is driven by the hovered range, so the
/// caret does not have to be on the problem.
func applyFix(for target: CodeTextView.DiagnosticFixTarget, in document: DocumentModel) {
    guard let provider = semanticProvider else { return }
    guard let diagnostic = liveDiagnostics.first(where: {
        Self.characterRange(for: $0.range, in: document.text as NSString) == target.range
    }) else {
        statusText = L10n.t("status.noFixHere")
        return
    }
    provider.codeActions(for: diagnostic, in: document.text,
                         fileURL: document.semanticURL) { [weak self] actions in
        guard let self else { return }
        guard let action = actions.first(where: \.isPreferred) ?? actions.first else {
            self.statusText = L10n.t("status.noFixAvailable")
            return
        }
        self.apply(codeAction: action, to: document)
    }
}
}
