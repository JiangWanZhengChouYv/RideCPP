import SwiftUI
import AppKit

/// Shown when no file is open: a clear starting point instead of a blank window.
struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 6) {
                    Text(L10n.t("welcome.title"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(L10n.t("welcome.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button {
                        state.newDocument()
                    } label: {
                        Label(L10n.t("welcome.newFile"), systemImage: "doc.badge.plus")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        state.openFromPanel()
                    } label: {
                        Label(L10n.t("welcome.openFile"), systemImage: "folder")
                            .frame(minWidth: 130)
                    }
                    .controlSize(.large)
                }

                if !state.recentFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("welcome.recent"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(state.recentFiles, id: \.self) { url in
                                Button {
                                    state.open(urls: [url])
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 11))
                                        Text(url.deletingLastPathComponent().path)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 16)

            HStack(spacing: 14) {
                hint(L10n.t("welcome.hint.build"), shortcut: "⌘B")
                hint(L10n.t("welcome.hint.run"), shortcut: "⌘R")
                hint(L10n.t("welcome.hint.format"), shortcut: "⇧⌘I")
                hint(L10n.t("welcome.hint.comment"), shortcut: "⌘/")
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func hint(_ title: String, shortcut: String) -> some View {
        HStack(spacing: 4) {
            Text(shortcut)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
