import SwiftUI
import AppKit
import BuildKit

/// Bottom panel: a terminal-style console where program output and input share
/// one box, plus the clickable problems list.
struct OutputPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $state.outputSegment) {
                ForEach(AppState.OutputSegment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            if state.isRunning {
                Button {
                    state.interruptProgram()
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(L10n.t("output.interrupt"))
            }

            Spacer()

            if state.isBuilding || state.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Text(state.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                state.clearOutput()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L10n.t("build.clearOutput"))

            Button {
                state.isOutputVisible = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(L10n.t("output.hide"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        switch state.outputSegment {
        case .console:
            consoleView
        case .problems:
            problemsView
        }
    }

    /// The program's own console: output and input share one box, and the user
    /// types directly into it.
    private var consoleView: some View {
        ConsoleView(state: state)
            .overlay(alignment: .topLeading) {
                if state.outputText.isEmpty && !state.hasPendingConsoleInput && state.selectedDocument != nil {
                    Text(placeholder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    private var placeholder: String {
        if state.selectedDocument == nil {
            return L10n.t("console.noFile")
        }
        if state.isBuilding {
            return L10n.t("console.building")
        }
        if state.isRunning {
            return L10n.t("console.running")
        }
        return L10n.t("console.idle")
    }

    private var problemsView: some View {
        Group {
            if state.diagnostics.isEmpty {
                Text(L10n.t("output.problems.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.diagnostics) { diagnostic in
                    Button {
                        state.reveal(diagnostic: diagnostic)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(for: diagnostic.severity))
                                .foregroundStyle(color(for: diagnostic.severity))
                                .font(.system(size: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(diagnostic.message)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                Text("\(shortPath(diagnostic.file)):\(diagnostic.line)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }

    private func icon(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "info.circle"
        }
    }

    private func color(for severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .note: return .secondary
        }
    }
}
