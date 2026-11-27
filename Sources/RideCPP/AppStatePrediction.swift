import AppKit
import EditorCore
import EditorWindow
import BuildKit

// MARK: - Inline prediction

/// Wiring for the ghost-text suggestions.
///
/// Kept apart from the main class body: the predictor answers offline and
/// instantly, while the model is an optional second opinion that arrives later
/// and replaces it only when it is still relevant.
extension AppState {
/// Connects the predicted-continuation hook for one document.
///
/// The predictor always answers instantly from what the user has written, so
/// a suggestion never waits on the network. When a local model is available
/// its answer replaces the offline one as soon as it arrives.
func wireInlineSuggestion(_ document: DocumentModel) {
    predictor.learn(from: document.text)
    document.engine.textView.onRequestSuggestion = { [weak self, weak document] prefix, suffix in
        guard let self, let document else { return nil }
        let offline = self.predictor.predict(prefixBeforeCaret: prefix,
                                             document: document.text,
                                             suffixAfterCaret: suffix)
        self.requestModelSuggestion(prefix: prefix, suffix: suffix, document: document)
        return offline
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
        case .notInstalled, .notRunning, .modelMissing:
            self.inlineModelName = nil
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
    let generation = inlineSuggestionGeneration &+ 1
    inlineSuggestionGeneration = generation
    ollama.complete(model: model, prefix: prefix, suffix: suffix) { [weak self, weak document] text in
        guard let self, let document, !text.isEmpty,
              self.inlineSuggestionGeneration == generation,
              self.selectedDocument === document else { return }
        // Never overwrite something the user already accepted or typed past.
        let tv = document.engine.textView
        guard tv.selectedRange().length == 0, document.engine.textView.hasSuggestion else { return }
        tv.showSuggestion(text)
    }
}
}
