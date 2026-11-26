import AppKit
import Combine
import SwiftUI
import EditorCore
import BuildKit
import EditorWindow

/// In-process acceptance checks, run only when `RIDECPP_SELFTEST` is set.
///
/// This exists because UI automation (sending keystrokes or Apple Events to the
/// app) needs Accessibility permission, which a build machine may not have. The
/// runner drives the real `AppState`, real `EditorEngine` and real compilers, then
/// writes a JSON report and quits, which is enough to prove the integrated app
/// works end to end.
///
/// Usage:
///   RIDECPP_SELFTEST=/tmp/report.json ./RideCPP.app/Contents/MacOS/RideCPP
@MainActor
final class SelfTestRunner {

    private var report: SelfTestReport
    private let reportPath: String
    private var snapshotIndex = 0

    init(reportPath: String) {
        self.reportPath = reportPath
        self.report = SelfTestReport(path: reportPath)
    }

    /// True while the automated self-test drives the app; the delegate uses it
    /// to skip the unsaved-changes prompt when quitting.
    private(set) static var isRunning = false

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["RIDECPP_SELFTEST"], !path.isEmpty else { return }
        isRunning = true
        let runner = SelfTestRunner(reportPath: path)
        Task { await runner.run() }
    }

    func run() async {
        let state = AppState.shared

        guard let document = await checkWelcomeAndEditing(state) else { return }
        await checkEditingAndCompletion(state, document)
        await checkBuildRunAndInput(state, document)
        await checkConsoleAndOutput(state, document)
        await checkFormattingAndTabs(state, document)
        await checkFileOpenAndSettings(state, document)
    }

    @discardableResult
    private func checkWelcomeAndEditing(_ state: AppState) async -> DocumentModel? {
        // 1. Launch shows the welcome page (no file open), not a blank document.
        await settle()
        snapshot(named: "welcome")
        record("launch-shows-welcome", state.documents.isEmpty,
               "documents=\(state.documents.count)")

        // 1a. A fresh install defaults to -O2 (algorithm work needs it).
        let suite = "RideCPP.selftest.\(UUID().uuidString)"
        if let freshDefaults = UserDefaults(suiteName: suite) {
            defer {
                // `removePersistentDomain` empties the domain, but cfprefsd still
                // writes an empty plist to disk, so every self-test run used to
                // leave one behind (124 had accumulated). Delete the file too.
                freshDefaults.removePersistentDomain(forName: suite)
                Self.removePreferencesFile(named: suite)
            }
            let fresh = SettingsStore(defaults: freshDefaults, compilers: [], clangFormat: nil)
            record("default-optimization", fresh.optimization == "-O2",
                   "optimization=\(fresh.optimization)")
        }

        // 1b. "New File" from the welcome page creates a tab. Building saves
        // first, and an untitled tab needs a path: the "Save As" panel is
        // replaced with a fixed location for this headless run.
        _ = state.newDocument()
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        state.saveAsOverrideURL = buildDir.appendingPathComponent("main.cpp")
        record("document-created", state.documents.count == 1,
               "documents=\(state.documents.count)")
        guard let document = state.selectedDocument else {
            record("document-created", false, "no document after New File")
            return nil
        }
        return document
    }

    private func checkEditingAndCompletion(_ state: AppState, _ document: DocumentModel) async {
        // 2. Auto-indent through the real text view.
        let view = document.engine.textView
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.insertText("int main() {\nreturn 0;\n}\n", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 12, length: 0))   // right after "{"
        view.insertNewline(nil)
        let indented = view.string
        record("auto-indent",
               indented.contains("{\n    \n"),
               "text=\(escaped(indented))")

        // 3. Bracket pairing through the real text view.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        record("auto-pair", view.string.hasSuffix("()"),
               "tail=\(escaped(String(view.string.suffix(20))))")

        // 4. Dirty tracking — the tab's dot must appear on the first keystroke,
        //    with no click needed. A fresh, unmodified document is used so the
        //    clean → dirty transition can be observed.
        record("dirty-tracking", document.isDirty, "isDirty=\(document.isDirty)")
        let probe = DocumentModel(title: "probe",
                                  untitledNumber: nil,
                                  text: "int x;",
                                  fileURL: nil,
                                  settings: SettingsStore.shared.editSettings,
                                  fontSize: SettingsStore.shared.fontSize,
                                  showLineNumbers: false)
        var publishedChange = false
        let subscription = probe.objectWillChange.sink { publishedChange = true }
        probe.engine.textView.insertText("x",
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
        // AppKit posts its change notification on the next run-loop turn, which
        // is when the document publishes and the tab's dot repaints.
        await settle()
        subscription.cancel()
        record("dirty-publishes-on-typing",
               probe.isDirty && publishedChange,
               "isDirty=\(probe.isDirty) published=\(publishedChange)")
        await settle()
        snapshot(named: "dirty-tab")

        // 4b. Undo: the menu state must follow the stack, and undo must restore
        //     the text (this is what ⌘Z drives).
        let beforeUndo = view.string
        await settle()
        let undoEnabled = state.canUndo
        state.undo()
        await settle()
        let undone = view.string != beforeUndo
        record("undo",
               undoEnabled && undone,
               "enabled=\(undoEnabled) changed=\(undone)")
        // Redo the edit so later checks still see an edited document.
        state.redo()
        await settle()
        record("redo", view.string == beforeUndo, "restored=\(view.string == beforeUndo)")

        // 5. Highlighting installs temporary colors without touching undo.
        document.engine.highlighter.highlightNow()
        let temporary = view.layoutManager?.temporaryAttribute(.foregroundColor,
                                                               atCharacterIndex: 0,
                                                               effectiveRange: nil)
        record("syntax-highlighting", temporary != nil,
               "colors=\(document.engine.highlighter.lastTokenCount)")

    }

    private func checkBuildRunAndInput(_ state: AppState, _ document: DocumentModel) async {
        let view = document.engine.textView
        // 5b. Typing "i" opens the completion list with keywords harvested from
        //     the compiler, and the list greys out placeholders it will not insert.
        view.string = "int main() {\n    \n}\n"
        let textView = document.engine.textView
        textView.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "    \n").location, length: 0))
        textView.insertText("i", replacementRange: NSRange(location: NSNotFound, length: 0))
        let provider = textView.completionProvider
        let suggestions = provider?.completionItems(forPrefix: "i", document: view.string, context: .code).map(\.text) ?? []
        let popupVisible = textView.isShowingCompletions && textView.completionItemCount > 0
        record("completion-popup",
               suggestions.contains("int") && suggestions.contains { $0.hasPrefix("if") },
               "candidates=\(suggestions.prefix(3)) popup=\(popupVisible)")
        // Give the popup a moment, then capture it for visual review.
        try? await Task.sleep(nanoseconds: 300_000_000)
        snapshot(named: "completion-popup")

        // 5c. Vocabulary is per-document: only headers this file includes
        //     contribute, and nothing is scanned at launch.
        let documentIndex = DocumentSymbolIndex()
        let sample = "#include <vector>\n#include <string>\n"
        let headers = HeaderPaths.includes(in: sample)
        documentIndex.indexSynchronously(headers: headers)
        let vectorHits = documentIndex.names(from: headers, prefix: "vector", limit: 10)
        let unrelated = documentIndex.names(from: headers, prefix: "unordered_", limit: 10)
        record("completion-on-demand-index",
               headers == ["vector", "string"]
                   && vectorHits.contains("vector")
                   && unrelated.isEmpty,
               "headers=\(headers) vector=\(vectorHits.prefix(3)) unordered=\(unrelated.count) indexed=\(documentIndex.indexedHeaderCount)")

        // 5d. Placeholders are display-only: accepting a snippet must not type
        //     "condition" into the buffer.
        let ifSnippet = provider?
            .completionItems(forPrefix: "if", document: "", context: .code)
            .first { $0.text.contains("⟨condition⟩") }
        let inserted = ifSnippet?.insertionText ?? ""
        record("completion-placeholders-omitted",
               ifSnippet != nil && !inserted.contains("condition") && inserted.contains("if ()"),
               "inserted=\(escaped(String(inserted.prefix(40))))")

        textView.cancelOperation(nil)
        view.string = ""

        snapshot(named: "console-idle")

    }

    private func checkConsoleAndOutput(_ state: AppState, _ document: DocumentModel) async {
        let view = document.engine.textView
        // 6. A real build + run of the current tab. Building saves first, so the
        //    compiled source is the file on disk rather than a scratch copy.
        view.string = """
        #include <iostream>
        int main() {
            std::cout << "selftest-ok" << std::endl;
            return 0;
        }
        """
        // Clear first so a stale transcript cannot satisfy the check, and wait for
        // the program's own text: `isRunning` flips before the last output chunk is
        // appended, which made this check flaky.
        state.outputText = ""
        state.build(andRun: true)
        let ranOK = await waitUntil(timeout: 60) {
            !state.isBuilding && !state.isRunning && state.outputText.contains("selftest-ok")
        }
        let onDisk = document.fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        record("build-saves-before-compiling",
               document.fileURL != nil && onDisk == view.string,
               "path=\(document.fileURL?.lastPathComponent ?? "nil") saved=\(onDisk == view.string)")
        let output = state.outputText
        record("build-and-run", ranOK && output.contains("selftest-ok"),
               "output=\(escaped(String(output.suffix(400))))")
        // The console must report time and memory alongside the exit code.
        record("run-statistics",
               output.contains("用时") && output.contains("内存") && output.contains("退出码 0"),
               "output=\(escaped(String(output.suffix(160))))")
        // The compiler command line must never appear in the program view.
        record("no-compiler-log-in-output",
               !output.contains("clang++") && !output.contains("-std="),
               "output=\(escaped(String(output.suffix(200))))")
        snapshot(named: "output-panel")

        // 6a. Memory is measured for the program itself (not the compiler).
        view.string = """
        #include <vector>
        #include <chrono>
        #include <thread>
        #include <iostream>
        int main() {
            std::vector<char> buf(32 * 1024 * 1024);
            for (size_t i = 0; i < buf.size(); i += 4096) buf[i] = 1;
            volatile char keep = buf[4096]; (void)keep;
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            std::cout << "alloc-ok" << std::endl;
            return 0;
        }
        """
        // Reset first: `isRunning` can drop a frame before `.runFinished` lands the
        // statistics, so waiting on those two flags alone raced the measurement.
        state.lastRunPeakMemoryBytes = nil
        state.build(andRun: true)
        let allocRan = await waitUntil(timeout: 60) {
            !state.isBuilding && !state.isRunning && state.lastRunPeakMemoryBytes != nil
        }
        let peak = state.lastRunPeakMemoryBytes ?? 0
        record("run-memory",
               allocRan && peak > 20 * 1024 * 1024,
               "peak=\(RunStatisticsFormatter.memory(peak)) output=\(escaped(String(state.outputText.suffix(120))))")

        // 6b. Interactive input: the program asks first, the IDE answers.
        view.string = """
        #include <iostream>
        #include <string>
        int main() {
            std::cout << "Name? ";
            std::string name;
            std::getline(std::cin, name);
            std::cout << "Hello, " << name << "!" << std::endl;
            int n = 0;
            std::cout << "Number? ";
            if (std::cin >> n) { std::cout << "doubled=" << n * 2 << std::endl; }
            return 0;
        }
        """
        state.build(andRun: true)
        let sawPrompt = await waitUntil(timeout: 60) { state.outputText.contains("Name? ") }
        let promptedBeforeInput = sawPrompt && state.isRunning
        state.submitConsoleLine("RideCPP")
        let sawSecondPrompt = await waitUntil(timeout: 30) { state.outputText.contains("Number? ") }
        state.submitConsoleLine("21")
        let finished = await waitUntil(timeout: 30) { !state.isRunning }
        let interactiveOutput = state.outputText
        record("interactive-input",
               promptedBeforeInput && sawSecondPrompt && finished
                   && interactiveOutput.contains("Hello, RideCPP!")
                   && interactiveOutput.contains("doubled=42"),
               "promptFirst=\(promptedBeforeInput) second=\(sawSecondPrompt) output=\(escaped(String(interactiveOutput.suffix(300))))")
        snapshot(named: "interactive-run")

    }

    private func checkFormattingAndTabs(_ state: AppState, _ document: DocumentModel) async {
        let view = document.engine.textView
        // 7a. The console palette adapts to the system appearance: dark text on a
        //     light panel in light mode, light text on a dark panel in dark mode.
        //     A fixed palette is what made text vanish in one of the two modes.
        if let console = ConsoleView.liveConsole {
            let aqua = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
            let darkAqua = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
            let lightBg = paletteLuminance(ConsoleTextView.terminalBackground(for: aqua))
            let lightFg = paletteLuminance(ConsoleTextView.terminalText(for: aqua))
            let darkBg = paletteLuminance(ConsoleTextView.terminalBackground(for: darkAqua))
            let darkFg = paletteLuminance(ConsoleTextView.terminalText(for: darkAqua))
            let hintLight = paletteLuminance(ConsoleTextView.terminalHintText.resolved(for: aqua))
            let hintDark = paletteLuminance(ConsoleTextView.terminalHintText.resolved(for: darkAqua))
            let paletteDescription = Self.describePalette(
                light: (lightBg, lightFg), dark: (darkBg, darkFg),
                hints: (hintLight, hintDark))
            record("console-adapts-to-appearance",
                   consolePaletteAdaptsToAppearance(),
                   paletteDescription)
            record("console-hint-contrast",
                   consoleHintContrastsInBothAppearances(),
                   paletteDescription)

        // 7a3. Data is never lost, regardless of how much is displayed: the full
        //      transcript keeps every line even when only the tail is rendered.
        if let console = ConsoleView.liveConsole {
            let savedFull = console.fullTranscript
            defer {
                console.clearPendingInput()
                console.replaceTranscript(savedFull)
            }
            console.clearPendingInput()
            console.replaceTranscript("")
            let expected = 300   // below the display cap: everything should render
            for index in 0..<expected {
                console.appendOutput("line \(index)\n")
            }
            let text = console.transcriptText
            let produced = text.components(separatedBy: "\n").count - 1
            record("console-keeps-long-output",
                   produced == expected
                       && text.contains("line 0\n")
                       && text.contains("line \(expected - 1)\n")
                       && console.fullTranscript.contains("line 0\n"),
                   "rendered=\(produced)/\(expected) full=\(console.fullTranscript.count) chars")
        }

        // 7a4. Very long output is not laid out in full: the console shows a
        //      notice plus the tail, and copying still yields everything.
        if let console = ConsoleView.liveConsole {
            let savedTranscript = console.transcriptText
            let savedFull = console.fullTranscript
            defer {
                console.clearPendingInput()
                console.replaceTranscript(savedFull.isEmpty ? savedTranscript : savedFull)
            }
            console.clearPendingInput()
            console.replaceTranscript("")
            let total = ConsoleTextView.maximumDisplayedLines + 250
            for index in 0..<total {
                console.appendOutput("row \(index)\n")
            }
            console.displayIfNeeded()
            if let rep = console.bitmapImageRepForCachingDisplay(in: console.bounds) {
                console.cacheDisplay(in: console.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let directory = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
                    try? data.write(to: directory.appendingPathComponent("ridecpp-console-too-long.png"))
                }
            }
            let rendered = console.transcriptText
            let renderedLines = rendered.components(separatedBy: "\n").count
            let full = console.fullTranscript
            let fullLines = full.components(separatedBy: "\n").count - 1
            console.copyAll(nil)
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            let copiedLines = copied.components(separatedBy: "\n").count - 1
            record("console-truncates-display-not-data",
                   renderedLines <= ConsoleTextView.maximumDisplayedLines + 3
                       && fullLines == total
                       && copiedLines == total
                       && rendered.contains("输出过长")
                       && rendered.contains("row \(total - 1)")
                       && !rendered.contains("row 0\n"),
                   "rendered=\(renderedLines) full=\(fullLines) copied=\(copiedLines)")
        }

        // 7b. Copy all puts the transcript on the pasteboard.
            console.copyAll(nil)
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            record("console-copy-all",
                   !copied.isEmpty && copied.contains("Hello,"),
                   "copied=\(copied.count) chars: \(escaped(String(copied.prefix(40))))")
        }

        await checkConsoleRendering(state, view: view)

        // 7. Diagnostics from broken code, mapped back to the tab.
        view.string = "int main() { return missing_symbol; }"
        state.build(andRun: false)
        _ = await waitUntil(timeout: 60) { !state.isBuilding }
        let errors = state.diagnostics.filter { $0.severity == .error }
        record("diagnostics", !errors.isEmpty,
               "first=\(errors.first.map { "\($0.line):\($0.column) \($0.message)" } ?? "none")")
        await checkProblemsPanel(state, view: view)

    }

    private func checkFileOpenAndSettings(_ state: AppState, _ document: DocumentModel) async {
        let view = document.engine.textView
        // 8. Formatting the document with clang-format.
        view.string = "int  main(){int x=1;return  0;}"
        let before = view.string
        state.formatDocument()
        let formatted = await waitUntil(timeout: 20) { view.string != before }
        record("format-document",
               formatted && (formatted || state.canFormat),
               "after=\(escaped(view.string))")

        // 8b. Stopping a long-running program.
        view.string = """
        #include <iostream>
        #include <unistd.h>
        int main() { for (int i = 0; i < 60; ++i) { std::cout << "tick " << i << std::endl; usleep(100000); } return 0; }
        """
        state.build(andRun: true)
        _ = await waitUntil(timeout: 60) { state.isRunning }
        let sawRun = state.isRunning
        state.stop()
        let stopped = await waitUntil(timeout: 15) { !state.isRunning && !state.isBuilding }
        record("stop-running-program", sawRun && stopped,
               "sawRun=\(sawRun) stopped=\(stopped)")

        // 9. A second tab keeps an independent undo stack and selection.
        let firstID = document.id
        let second = state.newDocument()
        record("second-tab", state.documents.count == 2 && second.id != firstID,
               "documents=\(state.documents.count)")
        record("independent-undo",
               second.undoManager !== document.undoManager,
               "distinct undo managers")

        // 9b. Closing every tab leaves the welcome page, and numbering is reused.
        for open in state.documents {
            state.close(document: open, askToSave: false)
        }
        let allClosed = state.documents.isEmpty
        let reopened = state.newDocument()
        let reusedNumber = reopened.title == L10n.t("file.untitledTab", 1)
        record("close-last-tab",
               allClosed && reusedNumber,
               "closedAll=\(allClosed) newTitle=\(reopened.title)")
        // Close the freshly reopened tab again and capture the welcome page that
        // closing the last tab must leave behind.
        state.close(document: reopened, askToSave: false)
        await settle()
        snapshot(named: "welcome-after-close")

        // 6c3. Semantic completion via clangd: typing a member prefix must offer
        //      the real members with their signatures.
        let semanticDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-semantic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: semanticDir, withIntermediateDirectories: true)
        let semanticFile = semanticDir.appendingPathComponent("main.cpp")
        let semanticSource = """
        #include <string>
        struct Point { int x; int y; void moveTo(int a, int b); int manhattan(); };
        int main() {
            Point p;
            p.manhattan();
            std::string s;
            s.append("x");
            return 0;
        }
        """
        try? semanticSource.write(to: semanticFile, atomically: true, encoding: .utf8)
        // This probe opens its own file: remember the tab count so it can be
        // restored, otherwise later checks see an extra document.
        let documentsBefore = state.documents.count
        state.open(urls: [semanticFile])
        if let doc = state.selectedDocument, let provider = ClangdSession.findClangd() != nil ? doc.engine.textView.completionProvider : nil {
            // Give clangd time to start and parse.
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            let typed = semanticSource.replacingOccurrences(of: "s.append(\"x\");", with: "s.ap")
            doc.engine.textView.string = typed
            let lines = typed.components(separatedBy: "\n")
            let lineIndex = lines.firstIndex { $0.contains("s.ap") } ?? 0
            if let semantic = provider as? SemanticCompletionProvider {
                semantic.syncDocument(text: typed, fileURL: doc.fileURL)
                semantic.caretPosition = CursorPosition(line: lineIndex,
                                                       character: (lines[lineIndex] as NSString).length)
            }
            // clangd answers asynchronously and its overload set arrives over a few
            // requests; keep asking until the signature-bearing overload shows up.
            // An overload with no parameters legitimately has no `detail`, so the
            // check is for a *signature* somewhere in the list, not on the first item.
            var suggestions: [CompletionItem] = []
            var appends: [CompletionItem] = []
            for _ in 0..<20 {
                suggestions = provider.completionItems(forPrefix: "ap", document: typed, context: .code)
                appends = suggestions.filter { $0.text == "append" }
                if appends.contains(where: { !($0.detail ?? "").isEmpty }) { break }
                for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let signatures = appends.compactMap(\.detail).filter { !$0.isEmpty }
            record("semantic-completion-via-clangd",
                   !appends.isEmpty && !signatures.isEmpty,
                   "clangd=\(provider is SemanticCompletionProvider) appends=\(appends.count) signatures=\(signatures.prefix(2))")
        } else {
            record("semantic-completion-via-clangd", false, "clangd unavailable")
        }
        // Restore the tab count for the remaining checks.
        if let opened = state.selectedDocument, state.documents.count > documentsBefore {
            state.close(document: opened)
        }

        // 12. Opening a real file must show its text inside the editor, at a
        //     non-zero size (a zero-width text container renders nothing).
        let demoPath = FileManager.default.temporaryDirectory.appendingPathComponent("ridecpp-open-test.cpp")
        try? "#include <iostream>\nint main() {\n    return 0;\n}\n".write(to: demoPath, atomically: true, encoding: .utf8)
        state.open(urls: [demoPath])
        if let opened = state.selectedDocument {
            opened.focusEditor()
            try? await Task.sleep(nanoseconds: 200_000_000)
            let frame = opened.engine.textView.frame
            let containerWidth = opened.engine.textView.textContainer?.containerSize.width ?? 0
            // Height is unbounded by design (greatestFiniteMagnitude), so only the
            // width tells us the container was laid out.
            let frameDescription = "\(Int(frame.width))x\(Int(frame.height))"
            let containerDescription = "\(Int(containerWidth))"
            // A non-zero container is not enough: the text view inside it must have a
        // usable size too. A fixed intrinsic height on the host broke this while
        // still reporting a laid-out container.
        let innerSize = opened.engine.scrollView.frame.size
        let docSize = opened.engine.scrollView.documentView?.frame.size ?? .zero
        record("editor-inner-view-sized",
               innerSize.width > 200 && innerSize.height > 100 && docSize.width > 200,
               "scroll=\(Int(innerSize.width))x\(Int(innerSize.height)) doc=\(Int(docSize.width))x\(Int(docSize.height))")
        record("open-file-visible",
                                                          opened.engine.textView.string.contains("int main()")
                       && frame.width > 100 && frame.height > 50
                       && containerWidth > 100,
                   "chars=\(opened.engine.textView.string.count) frame=\(frameDescription) containerWidth=\(containerDescription)")
            snapshot(named: "opened-file")
        // The sidebar must not steal the editor's height.
        let editorFrame = opened.engine.scrollView.frame
        let editorWindow = opened.engine.scrollView.window?.frame ?? .zero
        record("editor-keeps-height-with-sidebar",
               editorFrame.height > 200 && editorFrame.width > 200,
               "editor=\(Int(editorFrame.width))x\(Int(editorFrame.height)) window=\(Int(editorWindow.width))x\(Int(editorWindow.height))")
        }

        await checkClangdIntegration(state, view: view)
    }


    /// Deletes the on-disk plist for a throwaway defaults suite.
    ///
    /// `UserDefaults` alone leaves an empty file behind, so repeated self-test
    /// runs accumulate one plist per run.
    static func removePreferencesFile(named suite: String) {
        // Ask cfprefsd to drop the domain, then remove the file it writes. The
        // daemon owns the plist and rewrites it after the process exits, so
        // deleting the file alone leaves an empty one behind.
        let domains = Process()
        domains.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        domains.arguments = ["delete", suite]
        domains.standardOutput = FileHandle.nullDevice
        domains.standardError = FileHandle.nullDevice
        try? domains.run()
        domains.waitUntilExit()

        let file = ("~/Library/Preferences/" as NSString).expandingTildeInPath
            .appending("/\(suite).plist")
        try? FileManager.default.removeItem(atPath: file)
    }

    /// Renders the real `SettingsView` offscreen and saves a PNG.
    private func snapshotSettingsView() -> Bool {
        let view = NSHostingView(rootView: SettingsView().environmentObject(SettingsStore.shared))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let directory = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        let file = directory.appendingPathComponent("ridecpp-settings.png")
        return (try? data.write(to: file)) != nil
    }

    // MARK: - Snapshots

    /// Writes a PNG of the live window next to the report, so the integrated UI
    /// can be inspected without screen-recording permissions.
    private func snapshot(named name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else { return }
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        let file = directory.appendingPathComponent("ridecpp-\(name).png")
        try? data.write(to: file)
        snapshotIndex += 1
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        NSApp.windows.forEach { $0.displayIfNeeded() }
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String) {
        report.record(name, passed, detail)
    }

    private func escaped(_ text: String) -> String {
        SelfTestReport.escaped(text)
    }

    private func finish() {
        report.finish()
        NSApp.terminate(nil)
    }

    // MARK: - Console palette checks

    /// Compact one-line summary of the resolved palette, for the report.
    private static func describePalette(light: (Double, Double),
                                        dark: (Double, Double),
                                        hints: (Double, Double)) -> String {
        func pair(_ values: (Double, Double)) -> String {
            String(format: "%.2f/fg%.2f", values.0, values.1)
        }
        return "light=\(pair(light)) dark=\(pair(dark)) "
            + "hintLight=\(String(format: "%.2f", hints.0)) hintDark=\(String(format: "%.2f", hints.1))"
    }

    private func paletteLuminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * Double(srgb.redComponent)
            + 0.7152 * Double(srgb.greenComponent)
            + 0.0722 * Double(srgb.blueComponent)
    }

    /// The console must flip with the system appearance, and stay legible in both.
    ///
    /// This checks resolved colours *and* rendered pixels, because the earlier bug
    /// was a palette that looked fine as constants but drew invisible text when the
    /// system switched modes.
    private func consolePaletteAdaptsToAppearance() -> Bool {
        let light = NSAppearance(named: .aqua)
        let dark = NSAppearance(named: .darkAqua)
        guard let light, let dark else { return false }

        let lightBackground = paletteLuminance(ConsoleTextView.terminalBackground(for: light))
        let lightText = paletteLuminance(ConsoleTextView.terminalText(for: light))
        let darkBackground = paletteLuminance(ConsoleTextView.terminalBackground(for: dark))
        let darkText = paletteLuminance(ConsoleTextView.terminalText(for: dark))

        // Light mode: light panel, dark text. Dark mode: dark panel, light text.
        let lightOK = lightBackground > 0.7 && lightText < 0.5
        let darkOK = darkBackground < 0.3 && darkText > 0.5
        // Both modes must actually contrast, not merely be "different".
        let lightContrast = abs(lightBackground - lightText)
        let darkContrast = abs(darkBackground - darkText)
        return lightOK && darkOK && lightContrast > 0.4 && darkContrast > 0.4
    }

    /// The empty-console hint must contrast with the panel in both appearances.
    private func consoleHintContrastsInBothAppearances() -> Bool {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { return false }
            let background = paletteLuminance(ConsoleTextView.terminalBackground(for: appearance))
            let hint = paletteLuminance(ConsoleTextView.terminalHintText.resolved(for: appearance))
            // The hint is secondary text, but must still read clearly: 0.45 is the
            // difference between "visible" and "washed out on white".
            if abs(hint - background) < 0.45 { return false }
        }
        return true
    }

}

// MARK: - clangd / compiler integration checks
//
// Moved out of the main class body to stay within the lint budget. The
// runner declares no stored property these methods read, so an extension
// behaves identically.
extension SelfTestRunner {
    /// Problems panel: live clangd diagnostics merged with compiler output.
    ///
    /// Split out of `checkBuildAndRun`, which had grown past the lint budget.
    private func checkProblemsPanel(_ state: AppState, view: CodeTextView) async {
        // The panel must merge both sources: the compiler only speaks after a
        // build, clangd speaks while typing, and users expect one list.
        // Assigning `string` does not post the edit notification, so the sync is
        // requested explicitly here (typing does it automatically in the app).
        if let semantic = view.completionProvider as? SemanticCompletionProvider,
           let document = state.selectedDocument {
            semantic.syncDocument(text: view.string, fileURL: document.semanticURL)
        }
        let mergeDeadline = Date().addingTimeInterval(15)
        while Date() < mergeDeadline, state.liveDiagnostics.isEmpty {
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let compilerProblems = state.allProblems.filter { $0.source == .compiler }
        let liveProblems = state.allProblems.filter { $0.source == .clangd }
        record("problems-panel-merges-live-diagnostics",
               !compilerProblems.isEmpty
                   && !liveProblems.isEmpty
                   && state.allProblems.first?.severity == .error,
               "total=\(state.allProblems.count) compiler=\(compilerProblems.count) clangd=\(liveProblems.count)")
        state.outputSegment = .problems
        state.isOutputVisible = true
        await settle()
        snapshot(named: "problems-panel")

    }

    /// Console rendering end to end: long output, direct typing, exit reporting.
    private func checkConsoleRendering(_ state: AppState, view: CodeTextView) async {
        // 6c2. End to end: a program printing 900 lines must reach the console
        //      complete. This exercises the batching path in AppState, which is
        //      where a long output could be dropped.
        view.string = """
        #include <iostream>
        int main() {
            for (int i = 0; i < 900; ++i) std::cout << i << "\\n";
            return 0;
        }
        """
        state.build(andRun: true)
        let printed = await waitUntil(timeout: 60) {
            !state.isBuilding && !state.isRunning && state.outputText.contains("\n899")
        }
        // Count only the numeric lines the program printed; the run summary and
        // blank lines are not part of the program's output.
        let numericLines = state.outputText
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty && Int($0) != nil }
        record("long-output-not-truncated",
               printed && numericLines.count >= 900
                   && numericLines.first == "0" && numericLines.last == "899",
               "lines=\(numericLines.count) first=\(numericLines.first ?? "-") last=\(numericLines.last ?? "-")")

        // 6b2. Waiting for typed input must not count as running time.
        view.string = """
        #include <iostream>
        #include <string>
        int main() {
            std::cout << "ready? ";
            std::string answer;
            std::getline(std::cin, answer);
            std::cout << "got " << answer << std::endl;
            return 0;
        }
        """
        state.build(andRun: true)
        let askedFirst = await waitUntil(timeout: 60) { state.outputText.contains("ready? ") && state.isRunning }
        let typedAt = Date()
        if askedFirst {
            // Simulate a user taking a while to type.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            state.submitConsoleLine("hi")
        }
        let answered = await waitUntil(timeout: 30) { !state.isRunning && state.outputText.contains("got hi") }
        let waitedForInput = Date().timeIntervalSince(typedAt)
        record("run-time-excludes-input-wait",
               askedFirst && answered && state.lastRunDuration < 0.6,
               "waited=\(String(format: "%.0f", waitedForInput * 1000))ms reported=\(String(format: "%.0f", state.lastRunDuration * 1000))ms")

        // 6c. Input prepared before the run is delivered when it starts.
        view.string = """
        #include <iostream>
        #include <string>
        int main() {
            std::string a, b;
            std::cout << "first: ";
            std::cin >> a;
            std::cout << "second: ";
            std::cin >> b;
            std::cout << a << "+" << b << std::endl;
            return 0;
        }
        """
        state.submitConsoleLine("alpha")
        state.submitConsoleLine("beta")
        let queued = state.queuedInputLines.count
        state.build(andRun: true)
        let queuedRunFinished = await waitUntil(timeout: 60) { !state.isBuilding && !state.isRunning }
        record("input-queued-before-run",
               queued == 2 && queuedRunFinished && state.outputText.contains("alpha+beta"),
               "queued=\(queued) output=\(escaped(String(state.outputText.suffix(160))))")

        // 6d. Typing directly into the console view sends input to the program.
        view.string = """
        #include <iostream>
        #include <string>
        int main() {
            std::cout << "who? ";
            std::string who;
            std::getline(std::cin, who);
            std::cout << "hi " << who << std::endl;
            return 0;
        }
        """
        state.build(andRun: true)
        let consoleReady = await waitUntil(timeout: 60) { state.outputText.contains("who? ") && state.isRunning }
        var typedIntoConsole = false
        if let console = ConsoleView.liveConsole {
            console.focusInput()
            console.insertText("typed-directly", replacementRange: NSRange(location: NSNotFound, length: 0))
            let typedText = console.pendingInput
            console.submitPendingInput()
            typedIntoConsole = typedText == "typed-directly"
        }
        let consoleRunFinished = await waitUntil(timeout: 30) { !state.isRunning }
        record("console-direct-typing",
               consoleReady && typedIntoConsole && consoleRunFinished
                   && state.outputText.contains("hi typed-directly"),
               "ready=\(consoleReady) typed=\(typedIntoConsole) output=\(escaped(String(state.outputText.suffix(200))))")
    }

    /// Everything that depends on clangd: diagnostics, hover, quick fixes,
    /// plus the compiler/settings checks that share the same temporary files.
    private func checkClangdIntegration(_ state: AppState, view: CodeTextView) async {
        await checkFilesSettingsAndCompilers(state, view: view)

        // 11b. Live diagnostics: clangd must underline a real type error without
        //      compiling. This is the "errors while typing" path.
        let diagDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: diagDir, withIntermediateDirectories: true)
        let diagFile = diagDir.appendingPathComponent("bad.cpp")
        let diagSource = """
        struct Point { int x; int y; };
        int main() {
            Point p;
            p.notAMember();
            return 0;
        }
        """
        try? diagSource.write(to: diagFile, atomically: true, encoding: .utf8)
        let diagDocumentsBefore = state.documents.count
        state.open(urls: [diagFile])
        var liveSeen: [LSPDiagnostic] = []
        let diagDeadline = Date().addingTimeInterval(20)
        while Date() < diagDeadline {
            if let opened = state.selectedDocument, opened.fileURL == diagFile {
                opened.engine.textView.string = diagSource
                if let semantic = opened.engine.textView.completionProvider as? SemanticCompletionProvider {
                    semantic.syncDocument(text: diagSource, fileURL: opened.semanticURL)
                }
            }
            liveSeen = state.liveDiagnostics
            if liveSeen.contains(where: { $0.code == "no_member" }) { break }
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let memberError = liveSeen.first { $0.code == "no_member" }
        record("live-diagnostics-from-clangd",
               memberError != nil && memberError?.severity == .error,
               "count=\(liveSeen.count) code=\(memberError?.code ?? "-") msg=\(escaped(String((memberError?.message ?? "-").prefix(40))))")
        // Restore the tab count for the checks that follow.
        if let opened = state.selectedDocument, state.documents.count > diagDocumentsBefore {
            state.close(document: opened)
        }

        // 11b2. An *unsaved* tab must get diagnoses too: starting an algorithm
        //       problem in "Untitled" is the normal path, and it used to get none.
        let untitledDocumentsBefore = state.documents.count
        _ = state.newDocument()
        var untitledSeen: [LSPDiagnostic] = []
        if let untitled = state.selectedDocument {
            untitled.engine.textView.string = diagSource
            if let semantic = untitled.engine.textView.completionProvider as? SemanticCompletionProvider {
                semantic.syncDocument(text: diagSource, fileURL: untitled.semanticURL)
            }
            let untitledDeadline = Date().addingTimeInterval(20)
            while Date() < untitledDeadline {
                untitledSeen = state.liveDiagnostics
                if untitledSeen.contains(where: { $0.code == "no_member" }) { break }
                for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        record("live-diagnostics-in-unsaved-tab",
               untitledSeen.contains { $0.code == "no_member" },
               "count=\(untitledSeen.count) codes=\(untitledSeen.compactMap(\.code).prefix(4))")
        if let opened = state.selectedDocument, state.documents.count > untitledDocumentsBefore {
            state.close(document: opened, askToSave: false)
        }

        // 11c. No false positives: a correct, run-of-the-mill algorithm file must
        //      produce *zero* error-severity diagnostics. This is the regression
        //      guard for the two things that used to paint valid code red — clangd
        //      falling back to C++14, and `<bits/stdc++.h>` being absent from the
        //      Apple toolchain.
        let cleanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-clean-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cleanDir, withIntermediateDirectories: true)
        let cleanFile = cleanDir.appendingPathComponent("algo.cpp")
        let cleanSource = """
        #include <bits/stdc++.h>
        using namespace std;

        int main() {
            int n;
            cin >> n;
            vector<int> a(n);
            for (int &x : a) cin >> x;
            sort(a.begin(), a.end());
            long long sum = accumulate(a.begin(), a.end(), 0LL);
            cout << sum << endl;
            return 0;
        }
        """
        try? cleanSource.write(to: cleanFile, atomically: true, encoding: .utf8)
        let cleanDocumentsBefore = state.documents.count
        state.open(urls: [cleanFile])
        var cleanErrors: [LSPDiagnostic] = []
        let cleanDeadline = Date().addingTimeInterval(20)
        while Date() < cleanDeadline {
            if let opened = state.selectedDocument, opened.fileURL == cleanFile {
                opened.engine.textView.string = cleanSource
                if let semantic = opened.engine.textView.completionProvider as? SemanticCompletionProvider {
                    semantic.syncDocument(text: cleanSource, fileURL: cleanFile)
                }
            }
            cleanErrors = state.liveDiagnostics.filter { $0.severity == .error }
            // Give clangd time to publish at least once, then stop early on a
            // failure: a false positive never fixes itself by waiting.
            if !cleanErrors.isEmpty { break }
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        record("no-false-diagnostics-on-valid-code",
               cleanErrors.isEmpty,
               "errors=\(cleanErrors.count) first=\(escaped(cleanErrors.first?.message ?? "-"))")
        if let opened = state.selectedDocument, state.documents.count > cleanDocumentsBefore {
            state.close(document: opened)
        }

        // 11d. Hovering a squiggle explains it, error code included.
        let hoverDocumentsBefore = state.documents.count
        let hoverDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-hover-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: hoverDir, withIntermediateDirectories: true)
        let hoverFile = hoverDir.appendingPathComponent("hover.cpp")
        let hoverSource = """
        struct Point { int x; int y; };
        int main() {
            Point p;
            p.notAMember();
            return 0;
        }
        """
        try? hoverSource.write(to: hoverFile, atomically: true, encoding: .utf8)
        state.open(urls: [hoverFile])
        var hoverDiagnostics: [CodeTextView.InlineDiagnostic] = []
        let hoverDeadline = Date().addingTimeInterval(20)
        while Date() < hoverDeadline {
            if let opened = state.selectedDocument, opened.fileURL == hoverFile {
                opened.engine.textView.string = hoverSource
                if let semantic = opened.engine.textView.completionProvider as? SemanticCompletionProvider {
                    semantic.syncDocument(text: hoverSource, fileURL: hoverFile)
                }
                hoverDiagnostics = opened.engine.textView.diagnosticsForTesting
            }
            if !hoverDiagnostics.isEmpty { break }
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // The squiggle must be hittable and carry both the message and the code.
        var hoverHit: CodeTextView.InlineDiagnostic?
        var hoverText = ""
        if let opened = state.selectedDocument, let first = hoverDiagnostics.first {
            hoverHit = opened.engine.textView.diagnostic(at: first.range.location)
            hoverText = hoverHit?.hoverText ?? ""
        }
        record("hover-shows-diagnostic",
               hoverHit != nil
               && hoverText.contains("No member named")
               && hoverText.contains("no_member"),
               "underlines=\(hoverDiagnostics.count) hover=\(escaped(String(hoverText.prefix(70))))")
        if let opened = state.selectedDocument, state.documents.count > hoverDocumentsBefore {
            state.close(document: opened)
        }

        // 11e. Quick fix: a typo in a standard type must be fixable from the
        //      editor. This exercises the whole chain — diagnostic → codeAction
        //      request → edit → text replaced — which only works when the client
        //      declares `codeActionLiteralSupport`; without it clangd answers in
        //      the old Command form and nothing is applicable.
        let fixDocumentsBefore = state.documents.count
        let fixDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-fix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixDir, withIntermediateDirectories: true)
        let fixFile = fixDir.appendingPathComponent("fix.cpp")
        let fixSource = """
        #include <string>

        int main() {
            std::strin s = "x";
            return 0;
        }
        """
        try? fixSource.write(to: fixFile, atomically: true, encoding: .utf8)
        state.open(urls: [fixFile])
        var typoSeen: LSPDiagnostic?
        let fixDeadline = Date().addingTimeInterval(20)
        while Date() < fixDeadline {
            if let opened = state.selectedDocument, opened.fileURL == fixFile {
                opened.engine.textView.string = fixSource
                if let semantic = opened.engine.textView.completionProvider as? SemanticCompletionProvider {
                    semantic.syncDocument(text: fixSource, fileURL: opened.semanticURL)
                }
            }
            typoSeen = state.liveDiagnostics.first { $0.code == "unknown_nested_typename_suggest" }
            if typoSeen != nil { break }
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Drive the same entry point the menu uses: put the caret on the squiggle
        // and let the action replace the text.
        var fixApplied = false
        if let typo = typoSeen,
           let opened = state.selectedDocument,
           let range = AppState.characterRange(for: typo.range, in: opened.text as NSString) {
            opened.engine.textView.setSelectedRange(NSRange(location: range.location, length: 0))
            state.fixDiagnosticAtCaret()
            let appliedBy = Date().addingTimeInterval(20)
            while Date() < appliedBy, !opened.text.contains("std::string s") {
                for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            fixApplied = opened.text.contains("std::string s")
        }
        record("quick-fix-applies-edit",
               typoSeen != nil && fixApplied,
               "diagnostic=\(typoSeen?.code ?? "-") applied=\(fixApplied) status=\(escaped(state.statusText))")
        if let opened = state.selectedDocument, state.documents.count > fixDocumentsBefore {
            state.close(document: opened, askToSave: false)
        }
        finish()
    }

    /// Opening a real file, the settings window, and every discovered compiler.
    private func checkFilesSettingsAndCompilers(_ state: AppState, view: CodeTextView) async {
        // 10. Opening a real file from disk.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ridecpp-selftest-\(UUID().uuidString).cpp")
        try? "#include <cstdio>\nint main(){return 0;}\n".write(to: tempFile, atomically: true, encoding: .utf8)
        state.open(urls: [tempFile])
        let opened = state.selectedDocument?.fileURL?.standardizedFileURL == tempFile.standardizedFileURL
        record("open-file", opened, "path=\(tempFile.lastPathComponent)")
        try? FileManager.default.removeItem(at: tempFile)
        if let first = state.documents.first { state.select(first.id) }

        // 11. The settings UI renders with real discovered values.
        let settingsOK = snapshotSettingsView()
        record("settings-window", settingsOK, "snapshot=ridecpp-settings.png")

        // 12. Alternating the compiler: every discovered compiler can build.
        if let first = state.documents.first { state.select(first.id) }
        let candidates = Array(SettingsStore.shared.availableCompilers.prefix(3))
        var builtWith: [String] = []
        var failures: [String] = []
        for compiler in candidates {
            view.string = "int main() { return 0; }"
            SettingsStore.shared.compilerPath = compiler.path
            state.build(andRun: false)
            let done = await waitUntil(timeout: 90) { !state.isBuilding }
            let ok = done && state.statusText == L10n.t("status.succeeded")
            if ok {
                builtWith.append(compiler.path)
            } else {
                let tail = String(state.compilerLog.suffix(300))
                failures.append("\(compiler.path): \(escaped(tail))")
            }
        }
        record("compiler-switching", builtWith.count == candidates.count,
               "built with: \(builtWith.joined(separator: ", ")) failures: \(failures.joined(separator: " | "))")
        if let clang = SettingsStore.shared.availableCompilers.first(where: { $0.family == .clang }) {
            SettingsStore.shared.compilerPath = clang.path
        }
    }
}
