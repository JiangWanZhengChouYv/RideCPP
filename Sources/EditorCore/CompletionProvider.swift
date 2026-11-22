import Foundation

/// A single completion candidate.
public struct CompletionItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let detail: String?

    public init(id: String = UUID().uuidString, text: String, detail: String? = nil) {
        self.id = id
        self.text = text
        self.detail = detail
    }
}

/// Hook for a future API-backed completion model.
///
/// This version intentionally ships no completion behaviour: `CodeTextView`
/// consults its provider only if one is set, and the app leaves it `nil`. Wiring
/// a model later means implementing `CompletionProviding` and assigning it — no
/// editor or UI restructuring required.
public protocol CompletionProviding: AnyObject {
    /// Synchronous result used by the AppKit text view's completion path.
    func completionItems(forPrefix prefix: String, document: String) -> [CompletionItem]
}

public extension CompletionProviding {
    /// Asynchronous request path for a remote model. The default implementation
    /// bridges to the synchronous list so an API-backed provider only has to
    /// override this one when it wants to.
    func completions(forPrefix prefix: String, document: String) async -> [CompletionItem] {
        completionItems(forPrefix: prefix, document: document)
    }
}

/// Placeholder provider that never suggests anything.
public final class NoopCompletionProvider: CompletionProviding {
    public init() {}
    public func completionItems(forPrefix prefix: String, document: String) -> [CompletionItem] { [] }
}
