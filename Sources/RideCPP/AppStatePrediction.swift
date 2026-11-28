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
/// Connects the predicted-continuation hook for one document.
///
/// The model answers asynchronously, so nothing is shown until it replies; a
/// reply that arrives after the caret moved is discarded.
func wireInlineSuggestion(_ document: DocumentModel) {
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
}
