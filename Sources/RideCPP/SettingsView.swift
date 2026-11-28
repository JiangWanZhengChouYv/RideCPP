import SwiftUI
import AppKit

/// Settings window, split into editor / build / formatting pages.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var state: AppState
    @State private var isPulling = false
    @State private var pullFraction: Double?
    @State private var pullStatus = ""

    var body: some View {
        TabView {
            editorTab
                .tabItem { Label(L10n.t("settings.tab.editor"), systemImage: "textformat") }
            buildTab
                .tabItem { Label(L10n.t("settings.tab.build"), systemImage: "hammer") }
            formattingTab
                .tabItem { Label(L10n.t("settings.tab.format"), systemImage: "text.alignleft") }
            predictionTab
                .tabItem { Label(L10n.t("settings.tab.prediction"), systemImage: "wand.and.stars") }
            generalTab
                .tabItem { Label(L10n.t("settings.tab.general"), systemImage: "gearshape") }
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }

    private var editorTab: some View {
        Form {
            Section(L10n.t("settings.tab.editor")) {
                HStack {
                    Text(L10n.t("settings.fontSize"))
                    Slider(value: $settings.fontSize, in: 9...24, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Picker(L10n.t("settings.indentWidth"), selection: $settings.indentWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { width in
                        Text("\(width)").tag(width)
                    }
                }
                Toggle(L10n.t("settings.indentWithTabs"), isOn: $settings.indentWithTabs)
                Toggle(L10n.t("settings.autoPair"), isOn: $settings.autoPair)
                Toggle(L10n.t("settings.autoIndent"), isOn: $settings.autoIndent)
                Toggle(L10n.t("settings.autoComplete"), isOn: $settings.autoComplete)
                Toggle(L10n.t("settings.showLineNumbers"), isOn: $settings.showLineNumbers)
            }
        }
        .formStyle(.grouped)
    }

    /// Inline predictions: the local model, and what to do when it is absent.
    private var predictionTab: some View {
        Form {
            Section {
                Toggle(L10n.t("settings.prediction.toggle"), isOn: $settings.inlineModelEnabled)
                Text(L10n.t("settings.prediction.toggle.detail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.inlineModelEnabled {
                Section {
                    modelStatus
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch state.ollamaAvailability {
        case .ready(let model):
            LabeledContent(L10n.t("settings.prediction.ready"), value: model)
            Text(L10n.t("settings.prediction.ready.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .modelMissing(let model):
            Text(L10n.t("settings.prediction.missing", model))
                .fixedSize(horizontal: false, vertical: true)
            Button(pullTitle) { startPull() }
                .disabled(isPulling)
            if isPulling {
                ProgressView(value: pullFraction ?? 0)
                Text(pullStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notRunning:
            Label(L10n.t("settings.prediction.notRunning"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(L10n.t("settings.prediction.notRunning.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.t("settings.prediction.recheck")) { state.refreshOllamaAvailability() }
        case .notInstalled, .none:
            Label(L10n.t("settings.prediction.notInstalled"), systemImage: "info.circle")
                .foregroundStyle(.secondary)
            Text(L10n.t("settings.prediction.notInstalled.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.t("settings.prediction.getOllama")) {
                    if let url = URL(string: "https://ollama.com/download") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(L10n.t("settings.prediction.recheck")) { state.refreshOllamaAvailability() }
            }
        }
    }

    private var pullTitle: String {
        L10n.t("settings.prediction.pull", "qwen2.5-coder:0.5b")
    }

    private func startPull() {
        isPulling = true
        pullFraction = nil
        pullStatus = ""
        state.pullInlineModel(progress: { fraction, status in
            pullFraction = fraction
            pullStatus = status
        }, completion: { result in
            isPulling = false
            switch result {
            case .success:
                pullStatus = L10n.t("settings.prediction.pulled")
            case .failure(let error):
                pullStatus = error.localizedDescription
            }
        })
    }

    private var buildTab: some View {
        Form {
            Section(L10n.t("settings.compiler")) {
                Picker(L10n.t("settings.compiler.path"), selection: $settings.compilerPath) {
                    ForEach(settings.availableCompilers) { compiler in
                        Text(compiler.menuTitle).tag(compiler.path)
                    }
                    if !settings.availableCompilers.contains(where: { $0.path == settings.compilerPath }) {
                        Text(settings.compilerPath).tag(settings.compilerPath)
                    }
                }
                HStack {
                    Text(settings.compilerPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L10n.t("settings.compiler.custom")) {
                        chooseCompiler()
                    }
                }
            }
            Section(L10n.t("settings.tab.build")) {
                Picker(L10n.t("settings.standard"), selection: $settings.standard) {
                    ForEach(SettingsStore.standards, id: \.self) { standard in
                        Text(standard).tag(standard)
                    }
                }
                Picker(L10n.t("settings.optimization"), selection: $settings.optimization) {
                    ForEach(SettingsStore.optimizations, id: \.self) { level in
                        Text(level).tag(level)
                    }
                }
                TextField(L10n.t("settings.extraFlags"), text: $settings.extraFlags)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.t("settings.extraFlags.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("settings.runArguments"), text: $settings.runArguments)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
    }

    private var formattingTab: some View {
        Form {
            Section(L10n.t("settings.tab.format")) {
                HStack {
                    Text(L10n.t("settings.clangFormat.path"))
                    Spacer()
                    Text(settings.clangFormatExecutable ?? L10n.t("settings.clangFormat.missing"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Picker(L10n.t("settings.clangFormat.style"), selection: $settings.clangFormatStyle) {
                    ForEach(SettingsStore.clangFormatStyles, id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
                Text(L10n.t("settings.clangFormat.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section(L10n.t("settings.tab.general")) {
                Text(L10n.t("settings.general.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(L10n.t("settings.restoreDefaults")) {
                    settings.restoreDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseCompiler() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.compilerPath = url.path
        }
    }
}
