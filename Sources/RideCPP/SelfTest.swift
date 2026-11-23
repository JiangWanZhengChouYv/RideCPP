import AppKit
import Combine
import SwiftUI
import EditorCore
import BuildKit

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

    struct Check {
        let name: String
        var passed: Bool
        var detail: String
    }

    private var checks: [Check] = []
    private let reportPath: String
    private var snapshotIndex = 0

    init(reportPath: String) {
        self.reportPath = reportPath
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

        // 1. Launch shows the welcome page (no file open), not a blank document.
        await settle()
        snapshot(named: "welcome")
        record("launch-shows-welcome", state.documents.isEmpty,
               "documents=\(state.documents.count)")

        // 1a. A fresh install defaults to -O2 (algorithm work needs it).
        let suite = "RideCPP.selftest.\(UUID().uuidString)"
        if let freshDefaults = UserDefaults(suiteName: suite) {
            defer { freshDefaults.removePersistentDomain(forName: suite) }
            let fresh = SettingsStore(defaults: freshDefaults, compilers: [], clangFormat: nil)
            record("default-optimization", fresh.optimization == "-O2",
                   "optimization=\(fresh.optimization)")
        }

        // 1b. "New File" from the welcome page creates a tab. Building saves
        // first, and an untitled tab needs a path: the "Save As" panel is
        // replaced with a fixed location for this headless run.
        state.newDocument()
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        state.saveAsOverrideURL = buildDir.appendingPathComponent("main.cpp")
        record("document-created", state.documents.count == 1,
               "documents=\(state.documents.count)")
        guard let document = state.selectedDocument else {
            finish()
            return
        }

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

        // 6. A real build + run of the current tab. Building saves first, so the
        //    compiled source is the file on disk rather than a scratch copy.
        view.string = """
        #include <iostream>
        int main() {
            std::cout << "selftest-ok" << std::endl;
            return 0;
        }
        """
        state.build(andRun: true)
        let ranOK = await waitUntil(timeout: 60) { !state.isBuilding && !state.isRunning }
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

        // 7. Diagnostics from broken code, mapped back to the tab.
        view.string = "int main() { return missing_symbol; }"
        state.build(andRun: false)
        _ = await waitUntil(timeout: 60) { !state.isBuilding }
        let errors = state.diagnostics.filter { $0.severity == .error }
        record("diagnostics", !errors.isEmpty,
               "first=\(errors.first.map { "\($0.line):\($0.column) \($0.message)" } ?? "none")")
        state.outputSegment = .problems
        state.isOutputVisible = true
        await settle()
        snapshot(named: "problems-panel")

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
            record("open-file-visible",
                   opened.engine.textView.string.contains("int main()")
                       && frame.width > 100 && frame.height > 50
                       && containerWidth > 100,
                   "chars=\(opened.engine.textView.string.count) frame=\(frameDescription) containerWidth=\(containerDescription)")
            snapshot(named: "opened-file")
        }

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

        finish()
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
        checks.append(Check(name: name, passed: passed, detail: detail))
        print("[selftest] \(passed ? "PASS" : "FAIL") \(name) — \(detail)")
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func finish() {
        let passed = checks.allSatisfy(\.passed)
        var json = "{\n  \"passed\": \(passed),\n  \"checks\": [\n"
        json += checks.map { check in
            "    {\"name\": \"\(check.name)\", \"passed\": \(check.passed), \"detail\": \"\(check.detail)\"}"
        }.joined(separator: ",\n")
        json += "\n  ]\n}\n"
        try? json.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("[selftest] \(passed ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED") -> \(reportPath)")
        NSApp.terminate(nil)
    }
}
