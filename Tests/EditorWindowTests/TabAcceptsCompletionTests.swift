import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// Tab is the key people press to accept a suggestion. It must work on the
/// first press, and it must not swallow the keystroke when there is nothing to
/// accept.
@MainActor
final class TabAcceptsCompletionTests: XCTestCase {

    /// No `NSWindow`: creating one inside xctest has crashed this suite before.
    /// The completion panel and the text view work without a window.
    private func makeEngine() -> EditorEngine {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: "int main() {\n    int flag = 0;\n    fl\n}\n",
                    undoManager: UndoManager())
        engine.textView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return engine
    }

    private func placeCaretAfterFl(_ engine: EditorEngine) {
        let text = engine.textView.string as NSString
        engine.textView.setSelectedRange(NSRange(location: text.range(of: "    fl\n").location + 6,
                                                 length: 0))
    }

    /// One press. Tab arrives through `insertTab`, which used to indent without
    /// consulting the open list, so the first press did nothing useful.
    func testOneTabAcceptsTheSelectedItem() {
        let engine = makeEngine()
        placeCaretAfterFl(engine)
        engine.textView.showCompletions(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(engine.textView.isShowingCompletions)
        XCTAssertEqual(engine.textView.selectedCompletionText, "flag")

        engine.textView.insertTab(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(engine.textView.string.contains("    flag\n"),
                      "string=\\(engine.textView.string.debugDescription)")
        XCTAssertFalse(engine.textView.isShowingCompletions)
    }

    /// Accepting a suggestion that equals what was typed would consume a
    /// keystroke and change nothing.
    func testTheWordBeingTypedIsNotOffered() {
        let engine = makeEngine()
        let items = engine.textView.completionProvider?
            .completionItems(forPrefix: "fl", document: engine.textView.string, context: .code) ?? []
        XCTAssertFalse(items.contains { $0.text == "fl" },
                       "offered: \\(items.map(\\.text))")
        XCTAssertTrue(items.contains { $0.text == "flag" })
    }

    /// With nothing open, Tab must still indent.
    func testTabIndentsWhenNoListIsOpen() {
        let engine = makeEngine()
        engine.textView.hideCompletions()
        let before = engine.textView.string
        engine.textView.setSelectedRange(NSRange(location: 20, length: 0))
        engine.textView.insertTab(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotEqual(engine.textView.string, before, "Tab must still indent")
    }

    /// Every edit must notify the owner, which is what invalidates a prediction
    /// still in flight for the older text.
    func testEditsNotifyTheRevisionHook() {
        let engine = makeEngine()
        var revisions = 0
        engine.textView.onDocumentRevisionChanged = { revisions += 1 }
        engine.textView.setSelectedRange(NSRange(location: 0, length: 0))
        engine.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        engine.textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(revisions, 2, "each edit must bump the revision")
    }

    /// The ghost text must clear when the line it described changes.
    func testGhostTextClearsOnEdit() {
        let engine = makeEngine()
        engine.textView.setSelectedRange(NSRange(location: 0, length: 0))
        engine.textView.showSuggestion(" (int i = 0; i < n; ++i) {")
        XCTAssertTrue(engine.textView.hasSuggestion)
        engine.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(engine.textView.hasSuggestion, "a suggestion for older text must not linger")
    }
}
