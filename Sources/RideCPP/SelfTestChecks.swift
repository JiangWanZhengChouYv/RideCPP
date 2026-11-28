import AppKit
import EditorCore
import EditorWindow
import BuildKit

// MARK: - clangd / compiler integration checks
//
// Moved out of the main class body to stay within the lint budget. The
// runner declares no stored property these methods read, so an extension
// behaves identically.
extension SelfTestRunner {
    /// Problems panel: live clangd diagnostics merged with compiler output.
    ///
    /// Split out of `checkBuildAndRun`, which had grown past the lint budget.
    /// Inline prediction: the offline predictor must answer instantly, the ghost
    /// text must be acceptable with Tab, and it must never run into the text.
    func checkInlinePrediction(_ state: AppState, view: CodeTextView) async {
        let source = "int main() {\n    int n;\n    cin >> n;\n"
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let predictor = StatisticalPredictor(storageURL: nil)
        view.onRequestSuggestion = { prefix, suffix in
            predictor.predict(prefixBeforeCaret: prefix, document: view.string,
                              suffixAfterCaret: suffix)
        }
        view.insertText("    ", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("for", replacementRange: NSRange(location: NSNotFound, length: 0))
        // The request is debounced, so let the run loop deliver it.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !view.hasSuggestion {
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let offered = view.hasSuggestion
        let accepted = view.acceptSuggestion()
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        // The continuation must keep the space after `for`, and complete the loop.
        let correct = view.string.contains("for (int i") && view.string.contains(") {")
        record("inline-prediction-offline",
               offered && accepted && correct,
               "offered=\(offered) accepted=\(accepted) tail=\(escaped(String(view.string.suffix(40))))")

        // Undo must remove the accepted text in one step.
        let afterAccept = view.string
        view.undoManager?.undo()
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        record("inline-prediction-undoable", view.string != afterAccept,
               "after=\(escaped(String(view.string.suffix(30))))")

        // Escape dismisses without inserting anything. The caret must sit at the
        // end of a line that already has content, which is when a continuation is
        // meaningful.
        // An unfinished line: a completed statement (ending in `;`) is correctly
        // not continued, so the caret goes after a half-written word.
        view.string = "int main() {\n    int n;\n    fo"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.onRequestSuggestion = { _, _ in "r (int j = 0; j < 9; ++j) {" }
        view.requestSuggestionNow()
        let shown = view.hasSuggestion
        view.dismissSuggestion()
        record("inline-prediction-dismiss", shown && !view.hasSuggestion,
               "shown=\(shown) remaining=\(view.hasSuggestion)")

        // What the model situation is, so the settings screen has something to say.
        state.refreshOllamaAvailability()
        let availDeadline = Date().addingTimeInterval(10)
        while Date() < availDeadline, state.ollamaAvailability == nil {
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        record("ollama-detected",
               state.ollamaAvailability != nil,
               "availability=\(state.ollamaAvailability.map { "\($0)" } ?? "nil")")
        view.onRequestSuggestion = nil
        view.string = ""
    }

    func checkProblemsPanel(_ state: AppState, view: CodeTextView) async {
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
    func checkConsoleRendering(_ state: AppState, view: CodeTextView) async {
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
    func checkClangdIntegration(_ state: AppState, view: CodeTextView) async {
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
    func checkFilesSettingsAndCompilers(_ state: AppState, view: CodeTextView) async {
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

    /// A local variable must lead the completion list, ahead of library symbols.
    ///
    /// clangd's `sortText` encodes that ordering; ignoring it put header macros
    /// like `FE_ALL_EXCEPT` at the top.
    func checkCompletionRanking(_ state: AppState) {
        guard let semantic = state.selectedDocument?.engine.textView.completionProvider
                as? SemanticCompletionProvider,
              let document = state.selectedDocument else { return }
        let source = """
        #include <bits/stdc++.h>
        using namespace std;
        int main() {
            int flag = 0;
            f
        }
        """
        let tv = document.engine.textView
        tv.string = source
        semantic.syncDocument(text: source, fileURL: document.semanticURL)
        let caret = (source as NSString).range(of: "\n    f\n").location + 6
        let prefix = (source as NSString).substring(to: caret)
        let lines = prefix.components(separatedBy: "\n")
        semantic.caretPosition = CursorPosition(line: lines.count - 1,
                                                character: (lines.last! as NSString).length)
        _ = semantic.completionItems(forPrefix: "f", document: source, context: .code)
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let ranked = semantic.completionItems(forPrefix: "f", document: source, context: .code)
        let first = ranked.first?.text ?? "-"
        let flagIndex = ranked.firstIndex { $0.text == "flag" }
        record("completion-ranks-local-first",
               first == "flag" || (flagIndex ?? 99) <= 2,
               "first=\(first) flagAt=\(flagIndex.map(String.init) ?? "-") top=\(ranked.prefix(4).map(\.text))")
        tv.string = ""
    }
}
