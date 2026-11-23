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
    /// Bumped on every edit, so views can react to text changes cheaply.
    @Published public private(set) var editGeneration = 0
    /// 1-based caret line, published so the breadcrumb and status bar can follow it.
    @Published public private(set) var caretLine = 1
    @Published public private(set) var caretColumn = 1

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
            self?.editGeneration &+= 1
        }
        engine.onCaretChange = { [weak self] in
            self?.updateCaretPosition()
        }
        compileURL = fileURL
    }

    public var text: String { engine.textView.string }

    /// Recomputes the caret's line and column from the text view.
    public func updateCaretPosition() {
        let location = engine.textView.selectedRange().location
        let ns = text as NSString
        let clamped = min(max(0, location), ns.length)
        let prefix = ns.substring(to: clamped)
        let line = prefix.components(separatedBy: "\n").count
        let columnStart = prefix.range(of: "\n", options: .backwards)
            .map { (prefix as NSString).range(of: String(prefix[$0])).location + 1 } ?? 0
        let column = clamped - columnStart + 1
        if line != caretLine { caretLine = line }
        if column != caretColumn { caretColumn = column }
    }

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

    /// Jumps to a 1-based line in this document.
    public func jump(toLine line: Int) {
        engine.jump(toLine: line)
    }

    /// Serialized text for saving/compiling. The editor always stores LF.
    public var persistedText: String { text }
}
