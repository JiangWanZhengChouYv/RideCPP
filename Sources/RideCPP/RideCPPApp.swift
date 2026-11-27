import SwiftUI
import AppKit
import EditorCore
import BuildKit
import EditorWindow

@main
struct RideCPPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup(L10n.appName) {
            ContentView()
                .environmentObject(state)
                .environmentObject(settings)
        }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(settings)
        }
    }
}

/// File / edit / build menus.
struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("file.newTab")) { state.newDocument() }
                .keyboardShortcut("t")
            Button(L10n.t("file.open")) { openDocument() }
                .keyboardShortcut("o")
            Divider()
            Button(L10n.t("file.save")) { saveDocument() }
                .keyboardShortcut("s")
            Button(L10n.t("file.saveAs")) { saveDocumentAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(L10n.t("file.closeTab")) { closeTab() }
                .keyboardShortcut("w")
                .disabled(state.selectedDocument == nil)
        }

        CommandGroup(after: .appInfo) {
            Button(L10n.t("menu.checkForUpdates")) {
                // A manual check reports its outcome; a silent one would look
                // broken when there is simply nothing new.
                state.updates.check(userInitiated: true) { title, message in
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(L10n.t("edit.undo")) { state.undo() }
                .keyboardShortcut("z")
                .disabled(!state.canUndo)
            Button(L10n.t("edit.redo")) { state.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.canRedo)
        }

        CommandMenu(L10n.codeMenuTitle) {
            Button(L10n.t("edit.toggleComment")) {
                state.selectedDocument?.engine.textView.toggleComment(nil)
            }
            .keyboardShortcut("/", modifiers: [.command])
            .disabled(state.selectedDocument == nil)

            Button(L10n.t("edit.indent")) {
                state.selectedDocument?.engine.textView.indentSelection(nil)
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(state.selectedDocument == nil)

            Button(L10n.t("edit.outdent")) {
                state.selectedDocument?.engine.textView.outdentSelection(nil)
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(state.selectedDocument == nil)

            Divider()

            Button(L10n.t("edit.formatDocument")) { state.formatDocument() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!state.canFormat)
        }

        CommandMenu(L10n.t("menu.build")) {
            Button(L10n.t("build.build")) { state.build(andRun: false) }
                .keyboardShortcut("b")
                .disabled(state.isBuilding || state.isRunning || state.selectedDocument == nil)
            Button(L10n.t("build.run")) { state.build(andRun: true) }
            Divider()
            Button(L10n.t("edit.goToDefinition")) { state.goToDefinition() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!state.semanticCompletionReady)
            Button(L10n.t("edit.fixDiagnostic")) { state.fixDiagnosticAtCaret() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!state.semanticCompletionReady || !state.canFixDiagnostic)
            Button(L10n.t("edit.complete")) { NSApp.sendAction(#selector(CodeTextView.showCompletions(_:)), to: nil, from: nil) }
                .keyboardShortcut(" ", modifiers: .control)
                .keyboardShortcut("r")
                .disabled(state.isBuilding || state.isRunning || state.selectedDocument == nil)
            Button(L10n.t("build.stop")) { state.stop() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!state.isBuilding && !state.isRunning)
            Divider()
            Button(L10n.t("build.clearOutput")) { state.clearOutput() }
            Toggle(L10n.t("output.show"), isOn: Binding(
                get: { state.isOutputVisible },
                set: { state.isOutputVisible = $0 }
            ))
            .keyboardShortcut("y", modifiers: [.command, .shift])
        }
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        panel.message = L10n.t("file.open")
        guard panel.runModal() == .OK else { return }
        state.open(urls: panel.urls)
    }

    private func saveDocument() {
        guard let document = state.selectedDocument else { return }
        _ = state.save(document: document)
    }

    private func saveDocumentAs() {
        guard let document = state.selectedDocument else { return }
        _ = state.saveAs(document: document)
    }

    private func closeTab() {
        guard let document = state.selectedDocument else { return }
        state.close(document: document)
    }
}

/// Handles lifecycle, file-open requests and app termination.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SelfTestRunner.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An automated self-test run must be able to exit on its own.
        if SelfTestRunner.isRunning { return .terminateNow }
        return AppState.shared.confirmQuit()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.open(urls: urls)
    }
}
