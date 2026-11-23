import SwiftUI
import EditorCore

/// Left sidebar: document symbols, so the window reads as an IDE rather than a
/// text editor with a title bar.
///
/// It lists includes and declarations for the active document and jumps the caret
/// to the one you click. The outline is recomputed when the text changes, which is
/// a cheap textual scan (see `DocumentOutline`).
struct SidebarView: View {
    @ObservedObject var document: DocumentModel
    @Binding var selectedLine: Int?
    @EnvironmentObject private var state: AppState

    @State private var outline: [OutlineItem] = []
    @State private var filter = ""

    private var visibleItems: [OutlineItem] {
        guard !filter.isEmpty else { return outline }
        let needle = filter.lowercased()
        return outline.filter { $0.name.lowercased().contains(needle) }
    }

    private var groups: [(OutlineKind, [OutlineItem])] {
        let order: [OutlineKind] = [.structure, .class, .enumeration, .function, .variable, .include]
        return order.compactMap { kind in
            let items = visibleItems.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if outline.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(groups, id: \.0) { kind, items in
                            sectionHeader(kind, count: items.count)
                            ForEach(items) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onAppear { rebuild() }
        .onReceive(document.$editGeneration) { _ in rebuild() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L10n.t("sidebar.outline"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(outline.count)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "curlybraces")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            Text(L10n.t("sidebar.noSymbols"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private func sectionHeader(_ kind: OutlineKind, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title(for: kind))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private func title(for kind: OutlineKind) -> String {
        switch kind {
        case .function: return L10n.t("sidebar.functions")
        case .structure: return L10n.t("sidebar.structs")
        case .class: return L10n.t("sidebar.classes")
        case .enumeration: return L10n.t("sidebar.enums")
        case .variable: return L10n.t("sidebar.variables")
        case .include: return L10n.t("sidebar.includes")
        }
    }

    private func row(_ item: OutlineItem) -> some View {
        let isSelected = selectedLine == item.line
        return Button {
            selectedLine = item.line
            document.jump(toLine: item.line)
            state.statusText = L10n.t("status.jumped", item.name, item.line)
        } label: {
            HStack(spacing: 6) {
                Text(item.kind.tag)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16, height: 13)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isSelected ? Color.white.opacity(0.5) : Color.secondary.opacity(0.35), lineWidth: 0.8)
                    )
                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 2)
                Text("\(item.line)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor)
                        .padding(.horizontal, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.detail.map { "\(item.name)\($0)" } ?? item.name)
    }

    private func rebuild() {
        // Debounced by SwiftUI's update cadence; the scan itself is sub-millisecond
        // for ordinary files.
        let items = DocumentOutline.items(in: document.text)
        if items != outline {
            withAnimation(.easeOut(duration: 0.15)) {
                outline = items
            }
        }
    }
}
