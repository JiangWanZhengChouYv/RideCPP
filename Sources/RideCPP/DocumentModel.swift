import AppKit
import Combine
import EditorCore

/// One open editor tab: its editor engine, undo stack, file identity and
/// dirty state.
@MainActor
public final class DocumentModel: ObservableObject, Identifiable {

    public let id = UUID()
    public let undoManager = UndoManager()
    public let engine: EditorEngine

    @Published public private(set) var title: String
    @Published public private(set) var isDirty = false

    /// The number behind an untitled tab's name ("Untitled 3" → 3), so new tabs
    /// can reuse numbers freed by closing instead of counting up forever.
    public private(set) var untitledNumber: Int?

    /// Backing file on disk, once saved or opened.
    public private(set) var fileURL: URL?
    /// File actually handed to the compiler (scratch file for unsaved tabs).
    public private(set) var compileURL: URL?

    /// Text as last loaded or saved, used to decide whether edits are real.
    private var savedText: String

    public init(title: String,
                untitledNumber: Int? = nil,
                text: String,
                fileURL: URL?,
                settings: EditSettings,
                fontSize: CGFloat,
                showLineNumbers: Bool) {
        self.title = title
        self.untitledNumber = untitledNumber
        self.fileURL = fileURL
        self.savedText = text
        self.engine = EditorEngine(settings: settings, fontSize: fontSize, showLineNumbers: showLineNumbers)
        engine.load(text: text, undoManager: undoManager)
        engine.onEdit = { [weak self] in
            self?.updateDirtyState()
        }
        compileURL = fileURL
    }

    public var text: String { engine.textView.string }

    public func updateDirtyState() {
        let nowDirty = text != savedText
        if nowDirty != isDirty {
            isDirty = nowDirty
        }
    }

    public func markSaved(to url: URL) {
        let isNewPath = fileURL?.standardizedFileURL != url.standardizedFileURL
        fileURL = url
        compileURL = url
        savedText = text
        title = url.lastPathComponent
        // A named file no longer holds an "Untitled N" slot.
        untitledNumber = nil
        isDirty = false
        // A save into a *new* file starts a fresh history. Saving over the same
        // file (which is what every build does) must keep undo working.
        if isNewPath {
            undoManager.removeAllActions()
        }
    }

    public func setCompileLocation(_ url: URL) {
        compileURL = url
    }

    public func apply(settings: EditSettings, fontSize: CGFloat, showLineNumbers: Bool) {
        engine.apply(settings: settings, fontSize: fontSize, showLineNumbers: showLineNumbers)
    }

    public func focusEditor() {
        engine.focus()
    }

    /// Serialized text for saving/compiling. The editor always stores LF.
    public var persistedText: String { text }
}
