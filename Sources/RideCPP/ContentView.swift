import SwiftUI
import AppKit
import BuildKit

/// Main window contents: tabs on top, editor in the middle, output panel below.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var outputHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            editorArea
            if state.isOutputVisible && state.selectedDocument != nil {
                Divider()
                OutputPanel()
                    .frame(height: outputHeight)
                Divider()
            }
            if let update = state.availableUpdate {
                updateBanner(update)
            }
            statusBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar { toolbarContent }
        .onAppear {
            state.selectedDocument?.focusEditor()
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if let document = state.selectedDocument {
            EditorHost(document: document)
                .id(document.id)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            WelcomeView()
        }
    }

    /// Non-blocking notice when a newer release exists.
    private func updateBanner(_ update: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 11))
            Text(L10n.t("update.available.message", update.tag))
                .font(.system(size: 11))
            Button(L10n.t("update.download")) { state.openAvailableUpdate() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Spacer()
            Button {
                state.availableUpdate = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.accentColor.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if state.isOutputVisible && state.selectedDocument != nil {
                Button {
                    state.isOutputVisible = false
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L10n.t("output.hide"))
            } else {
                Button {
                    state.isOutputVisible = true
                    state.outputSegment = .console
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L10n.t("output.show"))
            }

            Text(state.statusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let document = state.selectedDocument {
                Text(document.fileURL?.path ?? L10n.t("file.untitled"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.build(andRun: false)
            } label: {
                Label(L10n.t("toolbar.build"), systemImage: "hammer")
            }
            .disabled(state.isBuilding || state.isRunning)
            .help(L10n.t("toolbar.build"))

            Button {
                state.build(andRun: true)
            } label: {
                Label(L10n.t("toolbar.run"), systemImage: "play.fill")
            }
            .disabled(state.isBuilding || state.isRunning)
            .help(L10n.t("toolbar.run"))

            Button {
                state.stop()
            } label: {
                Label(L10n.t("toolbar.stop"), systemImage: "stop.fill")
            }
            .disabled(!state.isBuilding && !state.isRunning)
            .help(L10n.t("toolbar.stop"))

            Button {
                state.formatDocument()
            } label: {
                Label(L10n.t("toolbar.format"), systemImage: "text.alignleft")
            }
            .disabled(!state.canFormat)
            .help(L10n.t("toolbar.format"))
        }
    }
}
