import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

final class CompletionInsertionTests: XCTestCase {

    private func accept(prefix: String, in text: String, caret: Int, indentWidth: Int) -> String {
        let engine = EditorEngine(settings: EditSettings(indentWidth: indentWidth))
        let view = engine.textView
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.showCompletions(nil)
        for character in prefix {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if view.isShowingCompletions {
            _ = view.handleCompletionKey(acceptEvent)
        }
        return view.string
    }

    private var acceptEvent: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    func testTwoSpaceDocumentGetsTwoSpaceBody() {
        // A body line that already carries the block's indentation.
        let result = accept(prefix: "if", in: "int main() {\n  ", caret: 15, indentWidth: 2)
        // Statement at 2, body at 4, closing brace back at 2.
        XCTAssertEqual(result, "int main() {\n  if () {\n    \n  }")
    }

    func testFourSpaceDocumentGetsFourSpaceBody() {
        let result = accept(prefix: "if", in: "int main() {\n    ", caret: 17, indentWidth: 4)
        XCTAssertEqual(result, "int main() {\n    if () {\n        \n    }")
    }

    func testAcceptedSnippetHasNoPlaceholderOrMarkerText() {
        let result = accept(prefix: "if", in: "int main() {\n    ", caret: 17, indentWidth: 4)
        XCTAssertFalse(result.contains("condition"))
        XCTAssertFalse(result.contains("⟨"))
        XCTAssertFalse(result.contains("·"))
    }
}

/// Navigation and list-refresh behaviour of the open completion list.
final class CompletionNavigationTests: XCTestCase {

    private func makeEditor() -> CodeTextView {
        let engine = EditorEngine(settings: EditSettings(indentWidth: 4))
        let view = engine.textView
        view.string = "int main() {\n    \n}\n"
        view.setSelectedRange(NSRange(location: 17, length: 0))
        view.showCompletions(nil)
        return view
    }

    private var downArrow: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{F701}",
                         charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
    }

    private var upArrow: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{F700}",
                         charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
    }

    func testArrowKeysMoveTheSelection() {
        let view = makeEditor()
        XCTAssertGreaterThan(view.completionItemCount, 2)
        let start = view.selectedCompletionIndex
        XCTAssertTrue(view.handleCompletionKey(downArrow))
        XCTAssertEqual(view.selectedCompletionIndex, start + 1)
        XCTAssertTrue(view.handleCompletionKey(downArrow))
        XCTAssertEqual(view.selectedCompletionIndex, start + 2)
        XCTAssertTrue(view.handleCompletionKey(upArrow))
        XCTAssertEqual(view.selectedCompletionIndex, start + 1)
    }

    func testSelectionWrapsAroundBothEnds() {
        let view = makeEditor()
        let count = view.completionItemCount
        // Up from the first row wraps to the last.
        _ = view.handleCompletionKey(upArrow)
        XCTAssertEqual(view.selectedCompletionIndex, count - 1)
        // Down from the last wraps back to the first.
        _ = view.handleCompletionKey(downArrow)
        XCTAssertEqual(view.selectedCompletionIndex, 0)
    }

    func testAcceptingInsertsTheNavigatedToItem() {
        let view = makeEditor()
        _ = view.handleCompletionKey(downArrow)
        let expected = view.selectedCompletionText
        _ = view.handleCompletionKey(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                      modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil,
                                                      characters: "\r",
                                                      charactersIgnoringModifiers: "\r",
                                                      isARepeat: false, keyCode: 36)!)
        XCTAssertFalse(view.isShowingCompletions)
        if let expected, !expected.contains("\n") {
            XCTAssertTrue(view.string.contains(expected), "expected \(expected.debugDescription) in \(view.string.debugDescription)")
        }
    }

    func testDeletingRefiltersTheOpenList() {
        // Type "vec", then delete back: the candidate list must follow each step.
        let engine = EditorEngine(settings: EditSettings(indentWidth: 4))
        let view = engine.textView
        view.string = "int main() {\n    \n}\n"
        view.setSelectedRange(NSRange(location: 17, length: 0))
        for character in "vec" {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertTrue(view.isShowingCompletions)
        let atVec = view.completionItemCount

        view.deleteBackward(nil)
        XCTAssertTrue(view.isShowingCompletions, "list closed after one deletion")
        let atVe = view.completionItemCount
        // "ve" is a broader prefix than "vec", so it offers at least as many.
        XCTAssertGreaterThanOrEqual(atVe, atVec)

        view.deleteBackward(nil)
        view.deleteBackward(nil)
        // With the word gone there is nothing to complete.
        XCTAssertFalse(view.isShowingCompletions)
    }

    func testDeletingKeepsListOpenWhilePrefixRemains() {
        let view = makeEditor()
        let before = view.completionItemCount
        view.deleteBackward(nil)
        // Deleting the space leaves an empty prefix, so the list is dismissed.
        XCTAssertFalse(view.isShowingCompletions, "expected dismissal once the word is gone")

        // Re-open and delete within a word instead.
        view.insertText("v", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.isShowingCompletions)
        XCTAssertGreaterThan(view.completionItemCount, 0)
        view.deleteBackward(nil)
        XCTAssertTrue(view.isShowingCompletions, "list closed even though a prefix remains")
        _ = before
    }
}

/// `using namespace std;` must remove the `std::` prefix from suggestions.
