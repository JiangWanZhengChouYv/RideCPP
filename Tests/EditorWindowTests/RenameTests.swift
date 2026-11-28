import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// Applying a rename's edits must be one undoable change and hit exactly the
/// ranges the server named.
@MainActor
final class RenameTests: XCTestCase {

    private let source = "int count = 0;\nvoid bump() { count++; }\n"

    private func makeEngine() -> EditorEngine {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: source, undoManager: UndoManager())
        return engine
    }

    private func edit(line: Int, _ start: Int, _ end: Int, _ text: String) -> LSPTextEdit {
        LSPTextEdit(path: "",
                    range: LSPRange(start: LSPPosition(line: line, character: start),
                                    end: LSPPosition(line: line, character: end)),
                    newText: text)
    }

    func testAppliesEveryRange() {
        let engine = makeEngine()
        let edits = [edit(line: 0, 4, 9, "counter"),
                     edit(line: 1, 14, 19, "counter")]
        XCTAssertTrue(engine.textView.applyRenameEdits(edits))
        XCTAssertEqual(engine.textView.string,
                       "int counter = 0;\nvoid bump() { counter++; }\n")
    }

    /// ⌘Z after a rename must restore the whole thing, not one reference.
    func testRenameIsOneUndoStep() {
        let engine = makeEngine()
        let undo = engine.textView.undoManager
        let edits = [edit(line: 0, 4, 9, "counter"),
                     edit(line: 1, 14, 19, "counter")]
        XCTAssertTrue(engine.textView.applyRenameEdits(edits))
        XCTAssertNotEqual(engine.textView.string, source)
        undo?.undo()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(engine.textView.string, source, "one undo must restore both references")
    }

    func testNoEditsIsNotAChange() {
        let engine = makeEngine()
        XCTAssertFalse(engine.textView.applyRenameEdits([]))
        XCTAssertEqual(engine.textView.string, source)
    }

    /// An edit already containing the new text leaves the document alone.
    func testIdenticalReplacementIsIgnored() {
        let engine = makeEngine()
        XCTAssertFalse(engine.textView.applyRenameEdits([edit(line: 0, 4, 9, "count")]))
        XCTAssertEqual(engine.textView.string, source)
    }

    func testOffsetConversion() {
        let ns = source as NSString
        XCTAssertEqual(EditorWindow.CodeTextView.offset(of: LSPPosition(line: 0, character: 4), in: ns), 4)
        XCTAssertEqual(EditorWindow.CodeTextView.offset(of: LSPPosition(line: 1, character: 0), in: ns), 15)
        // Past the end of the line is rejected rather than clamped silently.
        XCTAssertNil(EditorWindow.CodeTextView.offset(of: LSPPosition(line: 9, character: 0), in: ns))
    }
}
