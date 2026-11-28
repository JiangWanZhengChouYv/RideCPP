import SwiftUI
import AppKit
import BuildKit
import EditorCore

/// Main window contents: tabs on top, editor in the middle, output panel below.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    /// Observed directly: `find` is a separate ObservableObject, so changes to
    /// its visibility do not reach a view that only observes `AppState`.
    @ObservedObject private var find: FindModel
    @State private var outputHeight: CGFloat = 220
    @State private var sidebarVisible = true
    @State private var breadcrumbLine: Int?

    init() {
        // Seeded from the shared state; the environment object is not available
        // inside an initializer.
        _find = ObservedObject(wrappedValue: AppState.shared.find)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            if find.isVisible {
                FindBar(model: find)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                if sidebarVisible, let document = state.selectedDocument {
                    SidebarView(document: document, selectedLine: $breadcrumbLine)
                        .frame(width: 220)
                        .transition(.opacity)
                    Divider()
                }
                editorColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.isOutputVisible && state.selectedDocument != nil {
                Divider()
                OutputPanel()
                    .frame(height: outputHeight)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                Divider()
            }
            // `updateRevision` is read so this body re-runs when the updater
            // changes: `state.updates` is not itself observed, so without it the
            // banner never appeared even though `available` was set.
            if let update = state.updates.available {
                let _ = state.updateRevision
                updateBanner(update)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            statusBar
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar { toolbarContent }
        // Animations are applied to the *panels* rather than to this container.
        // Attaching an implicit animation to the container that holds the
        // NSViewRepresentable editor makes SwiftUI animate its AppKit view too,
        // and the text view stops drawing (the window showed an empty editor).
        .onAppear {
            state.selectedDocument?.focusEditor()
        }
    }

    /// The editor plus the breadcrumb strip above it.
    private var editorColumn: some View {
        VStack(spacing: 0) {
            if state.selectedDocument != nil {
                breadcrumb
                Divider()
            }
            // The editor must claim all remaining height explicitly: an
            // NSViewRepresentable has no intrinsic size, and inside an HStack with
            // the sidebar it otherwise collapsed to zero height.
            editorArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Path + cursor position, the way an IDE shows where you are.
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if let url = state.selectedDocument?.fileURL {
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("file.untitled"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let document = state.selectedDocument, let symbol = symbolName(for: document) {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
                Image(systemName: "function")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isBuilding || state.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            }
            Text("Ln \(state.selectedDocument?.caretLine ?? 1), Col \(state.selectedDocument?.caretColumn ?? 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.15), value: state.isBuilding)
        .animation(.easeInOut(duration: 0.15), value: state.isRunning)
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

    /// Non-blocking notice when a newer release exists, with live download
    /// progress once the update is being fetched.
    private func updateBanner(_ update: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: bannerIcon)
                .foregroundStyle(bannerTint)
                .font(.system(size: 11))

            Text(bannerTitle(update))
                .font(.system(size: 11))
                .lineLimit(1)

            if case .downloading = state.updates.phase {
                // A determinate bar, driven by bytes actually received.
                ProgressView(value: state.updates.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 150)
                Text(progressLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
            }

            bannerAction(update)

            Spacer()

            if case .downloading = state.updates.phase {
                Button {
                    state.updates.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("update.cancel"))
            } else if case .failed = state.updates.phase {
                Button {
                    state.updates.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if case .idle = state.updates.phase {
                Button {
                    state.updates.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(bannerTint.opacity(0.12))
    }

    private var bannerIcon: String {
        switch state.updates.phase {
        case .downloading: return "arrow.down.circle"
        case .installing, .readyToRelaunch: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "arrow.down.circle.fill"
        }
    }

    private var bannerTint: Color {
        if case .failed = state.updates.phase { return .orange }
        return .accentColor
    }

    private func bannerTitle(_ update: ReleaseInfo) -> String {
        switch state.updates.phase {
        case .idle:
            return L10n.t("update.available.message", update.versionLabel)
        case .downloading:
            return L10n.t("update.downloading", update.versionLabel)
        case .installing:
            return L10n.t("update.installing")
        case .readyToRelaunch:
            return L10n.t("update.relaunching")
        case .failed(let message):
            return L10n.t("update.failed.short", message)
        }
    }

    private var progressLabel: String {
        let megabytes = Double(state.updates.bytes.received) / (1024 * 1024)
        let total = Double(state.updates.bytes.total) / (1024 * 1024)
        if total > 0 {
            return String(format: "%.1f / %.1f MB", megabytes, total)
        }
        return String(format: "%.1f MB", megabytes)
    }

    @ViewBuilder
    private func bannerAction(_ update: ReleaseInfo) -> some View {
        switch state.updates.phase {
        case .idle:
            // One action: the update installs itself. Opening the release page was a
            // second, redundant path.
            Button(L10n.t("update.install")) { state.updates.install() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        case .downloading, .installing, .readyToRelaunch:
            EmptyView()
        case .failed:
            Button(L10n.t("update.retry")) { state.updates.install() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
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

    /// The enclosing declaration at the caret, for the breadcrumb.
    private func symbolName(for document: DocumentModel) -> String? {
        let outline: [OutlineItem] = DocumentOutline.items(in: document.text)
        let line = document.caretLine
        let enclosing: OutlineItem? = outline.last { item in
            guard item.line <= line else { return false }
            switch item.kind {
            case .function, .structure, .class, .enumeration: return true
            case .variable, .include: return false
            }
        }
        return enclosing?.name
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Label(L10n.t("toolbar.sidebar"), systemImage: "sidebar.left")
            }
            .help(L10n.t("toolbar.sidebar"))
        }

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
