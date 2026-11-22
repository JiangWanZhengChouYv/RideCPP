import SwiftUI
import AppKit

/// Horizontal strip of open documents with close buttons and a dirty marker.
struct TabStrip: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(state.documents) { document in
                    // Each tab observes its own document, so the dirty dot appears
                    // the moment the text changes instead of on the next click.
                    TabItemView(document: document,
                                isSelected: state.selectedDocumentID == document.id,
                                onSelect: { state.select(document.id) },
                                onClose: { state.close(document: document) })
                    Divider().frame(height: 20)
                }
                addButton
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
        }
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var addButton: some View {
        Button {
            state.newDocument()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 30)
        }
        .buttonStyle(.plain)
        .help(L10n.t("file.newTab"))
    }
}

/// One tab. Observing the document here is what keeps the unsaved marker live.
private struct TabItemView: View {
    @ObservedObject var document: DocumentModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(document.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                // Fixed-width slot so the tab does not shift when it becomes dirty.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .opacity(document.isDirty ? 1 : 0)
                    .help(L10n.t("tab.unsaved"))
                closeButton
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(document.fileURL?.path ?? document.title)
        .accessibilityLabel(document.isDirty ? "\(document.title) — \(L10n.t("tab.unsaved"))" : document.title)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .opacity(isSelected ? 1 : 0.6)
        .help(L10n.t("tab.close"))
    }
}
