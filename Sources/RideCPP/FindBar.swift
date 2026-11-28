import SwiftUI
import AppKit
import EditorCore

/// The find/replace bar that appears at the top of the editor.
///
/// Written as SwiftUI rather than AppKit's `NSTextFinder`: that panel has its own
/// visual language (next to the scroll bar, separate from the app's controls) and
/// cannot be styled to match the rest of the window.
struct FindBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model: FindModel
    @FocusState private var focus: Field?

    private enum Field {
        case find
        case replace
    }

    init(model: FindModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 6) {
            findRow
            if model.showsReplace {
                replaceRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear {
            focus = .find
        }
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            field(text: $model.query, placeholder: L10n.t("find.placeholder"), field: .find)
                .onSubmit { model.findNext() }
            resultCount
            optionsToggle
            Spacer()
            Button { model.findPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("find.previous"))
            Button { model.findNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("find.next"))
            Button { model.showsReplace.toggle() } label: {
                Image(systemName: model.showsReplace ? "chevron.down.circle" : "chevron.right.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("find.toggleReplace"))
            Button { model.dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("find.close"))
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            field(text: $model.replacement, placeholder: L10n.t("find.replacePlaceholder"),
                  field: .replace)
                .onSubmit { model.replaceCurrent() }
            Spacer()
            Button(L10n.t("find.replace")) { model.replaceCurrent() }
            Button(L10n.t("find.replaceAll")) { model.replaceAll() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
        }
        .padding(.leading, 0)
    }

    private func field(text: Binding<String>, placeholder: String, field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .frame(width: 240)
            .focused($focus, equals: field)
    }

    /// "3 of 12" style readout, or a warning when a regex will not compile.
    @ViewBuilder
    private var resultCount: some View {
        if model.hasInvalidRegex {
            Text(L10n.t("find.invalidRegex"))
                .font(.system(size: 11))
                .foregroundStyle(.red)
        } else if !model.query.isEmpty {
            Text(model.matchCount == 0
                 ? L10n.t("find.noMatches")
                 : L10n.t("find.matchCount", model.currentMatchNumber, model.matchCount))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var optionsToggle: some View {
        HStack(spacing: 4) {
            optionButton("Aa", isOn: $model.caseSensitive, help: L10n.t("find.caseSensitive"))
            optionButton("⌘.*", isOn: $model.isRegex, help: L10n.t("find.regex"))
            optionButton("W", isOn: $model.wholeWord, help: L10n.t("find.wholeWord"))
        }
    }

    private func optionButton(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 18)
                .background(isOn.wrappedValue
                            ? Color.accentColor.opacity(0.22)
                            : Color.clear)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn.wrappedValue ? Color.accentColor.opacity(0.6)
                                                   : Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
