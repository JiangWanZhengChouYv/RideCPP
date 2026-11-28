import XCTest
import AppKit
@testable import EditorWindow
@testable import EditorCore

/// Edits made while clangd's inlay labels are displayed must behave normally.
///
/// The labels reserve their space with a `.kern` attribute and never enter the
/// text, so these already passed before the rewrite; they stay as the guard
/// against going back to embedding characters in the document.
final class WbdNewlineReproTests: XCTestCase {
    private func makeView(text: String, at character: Int) -> (EditorEngine, CodeTextView) {
        let engine = EditorEngine(settings: EditSettings())
        let view = engine.textView
        view.string = text
        let hint = LSPInlayHint(position: LSPPosition(line: 0, character: character),
                                text: " n", kind: 1, paddingRight: false)
        view.setInlayHints([hint])
        XCTAssertTrue(view.hasInlayLabels)
        return (engine, view)
    }

    func testNewlineWithInlayLabel() {
        let (_, view) = makeView(text: "int main() { return 0; }", at: 14)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let before = view.currentSourceText()

        view.insertNewline(nil)

        XCTAssertEqual(view.currentSourceText().count, before.count + 1,
                       "newline must survive; got \(view.currentSourceText().debugDescription)")
        XCTAssertFalse(view.currentSourceText().contains("\u{FFFC}"))
        XCTAssertFalse(view.hasInlayLabels)
    }

    func testTypingWithInlayLabel() {
        let (_, view) = makeView(text: "int main() { return 0; }", at: 5)
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))

        let source = view.currentSourceText()
        XCTAssertTrue(source.contains("x"), "typed character must survive")
        XCTAssertFalse(source.contains("\u{FFFC}"))
        XCTAssertEqual(view.selectedRange().location, 25, "caret follows inserted character")
    }

    /// Backspace beside a label removes exactly the character it always would.
    ///
    /// `[dsh]` The label used to be an attachment inside the text, and this test
    /// existed to pin down how far the caret shifted when it was stripped. Labels
    /// now reserve space with a `.kern` attribute and never enter the text, so the
    /// caret needs no translation: index 4 in `abcdef` is after `d`, and Backspace
    /// there removes `d`.
    func testBackspaceWithInlayLabel() {
        let (_, view) = makeView(text: "abcdef", at: 3)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.deleteBackward(nil)

        XCTAssertEqual(view.currentSourceText(), "abcef")
        XCTAssertEqual(view.selectedRange().location, 3, "caret sits where the deleted character was")
        XCTAssertFalse(view.currentSourceText().contains("\u{FFFC}"))
    }
}
