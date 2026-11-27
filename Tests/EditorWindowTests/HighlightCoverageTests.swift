import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// Text that reaches the editor by any route must end up coloured.
///
/// `NSText.didChangeNotification` only fires when `didChangeText()` runs, so
/// assigning `textView.string` — a reload, an IME commit, a replaced range —
/// used to leave the document with no syntax colours at all: plain white text.
@MainActor
final class HighlightCoverageTests: XCTestCase {

    private let code = "int main() { return missing_symbol; }\n"

    private func prepare(_ engine: EditorEngine) {
        engine.textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Number of characters carrying an explicit colour.
    private func styledCount(_ engine: EditorEngine) -> Int {
        guard let layoutManager = engine.textView.layoutManager else { return 0 }
        let length = (engine.textView.string as NSString).length
        var styled = 0
        for index in 0..<length
        where layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                               effectiveRange: nil) != nil {
            styled += 1
        }
        return styled
    }

    func testDirectStringAssignmentIsHighlighted() {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: "", undoManager: UndoManager())
        prepare(engine)
        engine.textView.string = code
        // Highlighting is debounced, so let the run loop deliver it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertGreaterThan(styledCount(engine), 0,
                             "assigning textView.string left the text uncoloured")
        XCTAssertNotNil(engine.textView.layoutManager?
            .temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil),
                        "the leading `int` keyword must carry a colour")
    }

    func testTypingKeepsColours() {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: "", undoManager: UndoManager())
        prepare(engine)
        engine.textView.setSelectedRange(NSRange(location: 0, length: 0))
        engine.textView.insertText(code,
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertGreaterThan(styledCount(engine), 0)
    }

    func testKeywordAndIdentifierGetDifferentColours() {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: code, undoManager: UndoManager())
        prepare(engine)
        engine.highlighter.highlightNow()
        let layoutManager = engine.textView.layoutManager
        let keyword = layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                                        effectiveRange: nil) as? NSColor
        let identifier = layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 4,
                                                           effectiveRange: nil) as? NSColor
        XCTAssertNotNil(keyword)
        XCTAssertNotNil(identifier)
        XCTAssertNotEqual(keyword, identifier,
                          "`int` and `main` must not share a colour, or nothing reads as coloured")
    }

    /// clangd publishes an empty diagnostic list for a clean file. That used to
    /// clear `.foregroundColor` across the whole document — wiping the syntax
    /// colours — because the clear was not limited to the diagnostic ranges.
    /// A clean file is the *normal* state, so the editor simply looked uncoloured.
    func testEmptyDiagnosticsDoNotWipeSyntaxColours() {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: code, undoManager: UndoManager())
        prepare(engine)
        engine.highlighter.highlightNow()
        let before = styledCount(engine)
        XCTAssertGreaterThan(before, 0)

        engine.textView.setDiagnostics([])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(styledCount(engine), before,
                       "a clean-file diagnostic report must not repaint the text plain")
    }

    /// Removing a diagnostic must restore the syntax colour underneath it, not
    /// leave those characters in the plain colour.
    func testClearingADiagnosticRestoresSyntaxColour() {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: code, undoManager: UndoManager())
        prepare(engine)
        engine.highlighter.highlightNow()
        let baseline = styledCount(engine)

        let range = (code as NSString).range(of: "return")
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        engine.textView.setDiagnostics([])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(styledCount(engine), baseline,
                       "characters that held a diagnostic must be highlighted again")
    }
}
