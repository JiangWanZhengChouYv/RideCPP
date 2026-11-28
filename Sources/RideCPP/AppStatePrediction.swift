import AppKit
import EditorCore
import EditorWindow
import BuildKit

// MARK: - Inline prediction

/// Wiring for the ghost-text suggestions.
///
/// One source only: the local model. An earlier design also learned line shapes
/// from the user's own files, but that corpus collected the mistakes of whatever
/// was open at the time — including test files — and contributed nothing the
/// model does not do better.
extension AppState {
/// Connects the parameter hint for one document.
///
/// Driven by caret movement rather than by typing: moving into an argument is
/// just as much a reason to show the signature as typing a comma is.
func wireSignatureHint(_ document: DocumentModel, provider: SemanticCompletionProvider) {
    let textView = document.engine.textView
    textView.onSignatureQuery = { [weak self, weak document] in
        guard let self, let document else { return }
        self.requestSignatureHint(document, provider: provider)
    }
}

/// Asks for the signature of the enclosing call, or hides the hint.
func requestSignatureHint(_ document: DocumentModel, provider: SemanticCompletionProvider) {
    let textView = document.engine.textView
    // Only while actually editing one document; a background tab must not open
    // a floating hint over the one in front.
    guard selectedDocument === document,
          textView.selectedRange().length == 0 else {
        textView.hideSignatureHint()
        return
    }
    let caret = textView.selectedRange().location
    guard CallContext.info(at: caret, in: document.text) != nil else {
        textView.hideSignatureHint()
        return
    }
    provider.signatureHelp(atOffset: caret, in: document.text,
                           fileURL: document.semanticURL) { [weak self, weak document] signature, index in
        guard let self, let document, self.selectedDocument === document,
              document.engine.textView.selectedRange().location == caret else { return }
        document.engine.textView.showSignatureHint(signature, activeParameter: index)
    }
}

/// Connects the predicted-continuation hook for one document.
///
/// The model answers asynchronously, so nothing is shown until it replies; a
/// reply that arrives after the caret moved is discarded.
func wireInlineSuggestion(_ document: DocumentModel) {
    document.engine.textView.onDocumentRevisionChanged = { [weak self] in
        guard let self else { return }
        self.inlineSuggestionGeneration &+= 1
    }
    document.engine.textView.onRequestSuggestion = { [weak self, weak document] prefix, suffix in
        guard let self, let document else { return nil }
        self.requestModelSuggestion(prefix: prefix, suffix: suffix, document: document)
        return nil
    }
}

/// Resolves which model to use and records the Ollama situation.
///
/// Called at launch and whenever settings change, so the settings screen can
/// tell the user exactly what is missing — not installed, not running, or a
/// model that still needs pulling.
public func refreshOllamaAvailability() {
    ollama.checkAvailability { [weak self] availability in
        guard let self else { return }
        self.ollamaAvailability = availability
        switch availability {
        case .ready(let model):
            self.inlineModelName = model
            // Every installed code model is offered in settings; without this the
            // picker only ever showed the one that happened to be active.
            let installed = self.ollama.availableModels
            let codeModels = installed.filter {
                let lower = $0.lowercased()
                return lower.contains("coder") || lower.contains("code")
            }
            self.availableInlineModels = codeModels.sorted()
        case .notInstalled, .notRunning, .modelMissing:
            self.inlineModelName = nil
            self.availableInlineModels = []
        }
    }
}

/// Pulls the recommended model through the running server.
public func pullInlineModel(progress: @escaping (Double?, String) -> Void,
                            completion: @escaping (Result<Void, Error>) -> Void) {
    let model = ollama.config.preferredModels.first ?? "qwen2.5-coder:0.5b"
    pendingPull = ollama.pull(model: model, progress: { update in
        progress(update.fraction, update.status)
    }, completion: { [weak self] result in
        if case .success = result { self?.refreshOllamaAvailability() }
        completion(result)
    })
}

/// Asks the local model for a continuation, replacing the offline guess when a
/// better one arrives.
    func requestModelSuggestion(prefix: String, suffix: String, document: DocumentModel) {
    guard settings.inlineModelEnabled else { return }
    let configured = settings.inlineModel.trimmingCharacters(in: .whitespaces)
    guard let model = configured.isEmpty ? inlineModelName : configured else { return }
    // A model round trip is only worth it for the text the user paused on.
    // The generation identifies the text this answer is for, so it advances only
    // when the document changes — not on every request. Bumping it per request
    // made each in-flight query cancel the one before it, and since the model
    // takes ~0.15 s while typing re-triggers faster than that, every answer was
    // discarded and no suggestion ever appeared.
    let generation = inlineSuggestionGeneration
    ollama.complete(model: model, prefix: prefix, suffix: suffix) { [weak self, weak document] text in
        guard let self, let document, !text.isEmpty,
              self.inlineSuggestionGeneration == generation,
              self.selectedDocument === document else { return }
        // Never overwrite something the user already accepted or typed past.
        //
        // Note the absence of a `hasSuggestion` check here: that required an
        // offline suggestion to already exist, so turning the model on produced
        // nothing whenever the predictor had no guess — which is most of the
        // time. The model's answer is itself the suggestion in that case.
        let tv = document.engine.textView
        guard tv.selectedRange().length == 0 else { return }
        tv.showSuggestion(text)
    }
}

/// Saves every modified document that has a real path.
func saveDirtyDocuments() {
    for document in documents where document.isDirty && document.fileURL != nil {
        _ = save(document: document)
    }
}

public func showFind(replacing: Bool) {
    guard let document = selectedDocument else { return }
    find.documentProvider = { [weak self] in self?.selectedDocument }
    _ = document
    find.show(replacing: replacing)
}

    /// Renames the symbol under the caret across the document.
    ///
    /// The identifier is taken from the word around the caret, so the dialog opens
    /// with the current name rather than an empty field.
    public func renameSymbolAtCaret() {
        guard let document = selectedDocument, let provider = semanticProvider else { return }
        let textView = document.engine.textView
        let ns = document.text as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        guard let word = Self.identifier(around: caret, in: ns) else {
            statusText = L10n.t("status.noSymbolHere")
            return
        }
        let offset = word.location
        textView.promptForRename(current: ns.substring(with: word),
                                 texts: .init(title: L10n.t("rename.title"),
                                              message: L10n.t("rename.message"),
                                              placeholder: L10n.t("rename.placeholder"),
                                              confirm: L10n.t("rename.ok"),
                                              cancel: L10n.t("rename.cancel"))) { [weak self] newName in
            guard let self else { return }
            provider.rename(atOffset: offset, in: document.text, to: newName,
                            fileURL: document.semanticURL) { result in
                switch result {
                case .success(let edits):
                    let applied = textView.applyRenameEdits(edits)
                    self.statusText = applied
                        ? L10n.t("status.renamed", edits.count)
                        : L10n.t("status.noSymbolHere")
                case .failure(let error):
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    /// The identifier characters around `offset`, including one the caret is just
    /// after (which is where it sits after a double-click or ⌘D style selection).
    static func identifier(around offset: Int, in text: NSString) -> NSRange? {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            guard let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        var start = offset
        if !isWord(start), isWord(start - 1) { start -= 1 }
        guard isWord(start) else { return nil }
        var end = start
        while isWord(end) { end += 1 }
        var begin = start
        while isWord(begin - 1) { begin -= 1 }
        return NSRange(location: begin, length: end - begin)
    }
}
