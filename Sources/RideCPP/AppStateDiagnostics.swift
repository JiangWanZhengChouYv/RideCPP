import SwiftUI
import AppKit
import BuildKit
import EditorWindow
import EditorCore

/// Turning clangd's diagnostics into underlines, and holding them back while the
/// user is still typing.
extension AppState {

    /// Pending displays, keyed by document.
    ///
    /// A stored property cannot live in an extension, and the delay is a display
    /// concern that does not belong on `AppState` itself.
    nonisolated(unsafe) private static var pending: [UUID: DispatchWorkItem] = [:]

    func applyLiveDiagnostics(_ items: [LSPDiagnostic], for url: URL, text: String) {
        diagnosticsByFile[url.standardizedFileURL] = items
        guard let document = documents.first(where: {
            $0.semanticURL.standardizedFileURL == url.standardizedFileURL
        }) else { return }
        // Convert against the text the diagnostics were computed from, not the
        // current text: while the user types, the two differ and the marks would
        // land on unrelated lines.
        let ns = text as NSString
        var inline: [CodeTextView.InlineDiagnostic] = []
        for item in items {
            guard let range = Self.characterRange(for: item.range, in: ns) else { continue }
            let kind: CodeTextView.InlineDiagnostic.Kind = item.severity == .error ? .error : .warning
            inline.append(.init(range: range, kind: kind, message: item.message, code: item.code))
        }
        // Squiggles are shown only once the typing stops. clangd reports on every
        // keystroke, so a half-written line lights up the moment it becomes
        // incomplete — red marks flickering on and off under the caret while the
        // user is still typing is noise, not information.
        rememberComputed(inline, for: document)
        scheduleDiagnosticDisplay(inline, for: document)
    }

    /// Drops the marks on a document and any display still queued for it.
    func clearPendingDiagnostics(for document: DocumentModel) {
        Self.pending[document.id]?.cancel()
        Self.pending.removeValue(forKey: document.id)
        Self.lastComputed.removeValue(forKey: document.id)
        document.engine.textView.setDiagnostics([])
    }

    /// Shows `inline` unless another edit arrives first.
    ///
    /// A newer set of diagnostics replaces the pending one, so only the state at
    /// the end of a burst of typing is ever painted.
    private func scheduleDiagnosticDisplay(_ inline: [CodeTextView.InlineDiagnostic],
                                           for document: DocumentModel) {
        Self.pending[document.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            Self.pending.removeValue(forKey: document.id)
            document.engine.textView.setDiagnostics(inline)
        }
        Self.pending[document.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.diagnosticDelay, execute: work)
    }
}

extension AppState {
    /// How long typing has to pause before red marks appear.
    ///
    /// Long enough that ordinary typing does not flash a warning on every
    /// half-finished token, short enough that a real mistake is still pointed out
    /// while the user is thinking about that line.
    static let diagnosticDelay: TimeInterval = 0.6

    /// Diagnostics received but not yet painted.
    ///
    /// The delay is presentational, so anything that acts on a diagnostic must be
    /// able to see it before it appears — otherwise ⌥F could be pressed on a
    /// mistake the editor has not drawn yet and report that there is nothing here.
    func pendingInlineDiagnostics(for document: DocumentModel) -> [CodeTextView.InlineDiagnostic] {
        Self.lastComputed[document.id] ?? []
    }

    /// Records the set a delayed display is about to paint.
    func rememberComputed(_ inline: [CodeTextView.InlineDiagnostic], for document: DocumentModel) {
        Self.lastComputed[document.id] = inline
    }
}

extension AppState {
    /// Most recent set, whether or not it has been painted yet.
    nonisolated(unsafe) static var lastComputed: [UUID: [CodeTextView.InlineDiagnostic]] = [:]
}
