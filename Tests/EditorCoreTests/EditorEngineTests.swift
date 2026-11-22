import XCTest
import AppKit
@testable import EditorCore

@MainActor
final class EditorEngineTests: XCTestCase {

    private func makeEngine(text: String) -> (EditorEngine, UndoManager) {
        let engine = EditorEngine(settings: EditSettings())
        let undo = UndoManager()
        engine.load(text: text, undoManager: undo)
        return (engine, undo)
    }

    func testLoadsTextIntoTextView() {
        let (engine, _) = makeEngine(text: "int main() {}\n")
        XCTAssertEqual(engine.textView.string, "int main() {}\n")
        XCTAssertNotNil(engine.textView.textStorage)
        XCTAssertNotNil(engine.textView.layoutManager)
        XCTAssertNotNil(engine.textView.textContainer)
    }

    func testInsertNewlineAppliesAutoIndent() {
        let (engine, _) = makeEngine(text: "    int x;")
        engine.textView.setSelectedRange(NSRange(location: 10, length: 0))
        engine.textView.insertNewline(nil)
        XCTAssertEqual(engine.textView.string, "    int x;\n    ")
    }

    func testTypingOpenBracePairs() {
        let (engine, _) = makeEngine(text: "")
        engine.textView.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.textView.string, "{}")
        XCTAssertEqual(engine.textView.selectedRange().location, 1)
    }

    func testUndoIsPerDocument() {
        let (engineA, undoA) = makeEngine(text: "A")
        let (engineB, undoB) = makeEngine(text: "B")
        let managerA = undoA
        let managerB = undoB
        XCTAssertFalse(undoA.canUndo)
        XCTAssertFalse(undoB.canUndo)

        engineA.textView.setSelectedRange(NSRange(location: 1, length: 0))
        engineA.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(managerA.canUndo ?? false)
        XCTAssertFalse(managerB.canUndo ?? false)
    }

    func testUndoRestoresTextAfterTyping() {
        let (engine, undo) = makeEngine(text: "abc")
        engine.textView.setSelectedRange(NSRange(location: 3, length: 0))
        engine.textView.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.textView.string, "abcd")
        undo.undo()
        XCTAssertEqual(engine.textView.string, "abc")
    }

    func testHighlightingUsesTemporaryAttributes() {
        let (engine, _) = makeEngine(text: "int main() { return 0; }")
        engine.highlighter.highlightNow()
        guard let layoutManager = engine.textView.layoutManager else {
            return XCTFail("no layout manager")
        }
        let color = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil)
        XCTAssertNotNil(color, "keyword should carry a temporary color")
        // The temporary color for a keyword is the theme's keyword color, and
        // the stored attribute (plain text color) is left untouched.
        XCTAssertEqual(color as? NSColor, EditorTheme.type)
        let stored = engine.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(stored, EditorTheme.type)
    }

    func testHighlightingDoesNotEnterUndoStack() {
        let (engine, undo) = makeEngine(text: "int main() {}")
        undo.removeAllActions()
        engine.highlighter.highlightNow()
        XCTAssertFalse(undo.canUndo)
    }

    func testGoToLinePositionsCaret() {
        let (engine, _) = makeEngine(text: "one\ntwo\nthree")
        engine.textView.goTo(line: 3, column: 2)
        // "one\ntwo\nthree" — line 3 starts at offset 8, column 2 is offset 9.
        XCTAssertEqual(engine.textView.selectedRange().location, 9)
    }

    func testLineCountForRuler() {
        let (engine, _) = makeEngine(text: "a\nb\nc")
        XCTAssertEqual(TextCoordinates.lineCount(in: engine.textView.string), 3)
    }

    func testReplaceAllTextIsUndoable() {
        let (engine, undo) = makeEngine(text: "int  x   = 1;")
        undo.removeAllActions()
        engine.textView.replaceAllText(with: "int x = 1;", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(engine.textView.string, "int x = 1;")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(engine.textView.string, "int  x   = 1;")
    }

    func testFontSizeChangeKeepsText() {
        let (engine, _) = makeEngine(text: "int x;")
        engine.apply(settings: EditSettings(), fontSize: 18, showLineNumbers: true)
        XCTAssertEqual(engine.textView.string, "int x;")
    }

    func testNoopCompletionProviderReturnsNothing() {
        let provider = NoopCompletionProvider()
        XCTAssertTrue(provider.completionItems(forPrefix: "vec", document: "").isEmpty)
    }
}
