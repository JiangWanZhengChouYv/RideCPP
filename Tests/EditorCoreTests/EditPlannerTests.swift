import XCTest
@testable import EditorCore

final class EditPlannerTests: XCTestCase {

    private let settings = EditSettings(indentWidth: 4, indentWithTabs: false, autoPair: true, autoIndent: true)

    private func offset(of marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { return text.utf16.count }
        return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
    }

    /// Runs `command` with the caret at `marker` (a `|` that is removed first).
    private func run(_ command: EditCommand,
                     in template: String,
                     settings overrideSettings: EditSettings? = nil) -> (text: String, caret: Int) {
        let caretIndex = template.firstIndex(of: "|")
        var text = template
        let caret: Int
        if let caretIndex {
            let location = template.distance(from: template.startIndex, to: caretIndex)
            text.remove(at: caretIndex)
            caret = text.prefix(location).utf16.count
        } else {
            caret = text.utf16.count
        }
        let outcome = EditPlanner.apply(command,
                                        to: text,
                                        selection: NSRange(location: caret, length: 0),
                                        settings: overrideSettings ?? settings)
        return (outcome.text, outcome.selection.location)
    }

    // MARK: - Pairing

    func testParenPairIsInsertedWithCaretInside() {
        let result = run(.insert("("), in: "int main|")
        XCTAssertEqual(result.text, "int main()")
        XCTAssertEqual(result.caret, 9)
    }

    func testBracePair() {
        let result = run(.insert("{"), in: "void f()|")
        XCTAssertEqual(result.text, "void f(){}")
        XCTAssertEqual(result.caret, 9)
    }

    func testQuotePair() {
        let result = run(.insert("\""), in: "std::string s = |")
        XCTAssertEqual(result.text, "std::string s = \"\"")
        XCTAssertEqual(result.caret, 17)
    }

    func testPairingSuppressedInsideString() {
        // Caret sits between the quotes, i.e. inside the literal.
        let result = run(.insert("("), in: #"std::string s = "te|xt""#)
        XCTAssertEqual(result.text, #"std::string s = "te(xt""#)
    }

    func testPairingSuppressedInsideComment() {
        // Caret sits between two words of the comment, i.e. inside it.
        let result = run(.insert("("), in: "// no|te")
        XCTAssertEqual(result.text, "// no(te")
    }

    func testTypeThroughClosingCharacter() {
        // Typing `)` when the next character already is `)` just moves the caret.
        let result = run(.insert(")"), in: "main(|)")
        XCTAssertEqual(result.text, "main()")
        XCTAssertEqual(result.caret, 6)
    }

    func testSelectionIsWrapped() {
        let text = "main abc"
        let selection = NSRange(location: 5, length: 3)
        let outcome = EditPlanner.apply(.insert("("), to: text, selection: selection, settings: settings)
        XCTAssertEqual(outcome.text, "main (abc)")
        XCTAssertEqual(outcome.selection, NSRange(location: 5, length: 5))
    }

    func testAutoPairDisabledBehavesLikePlainTyping() {
        let off = EditSettings(autoPair: false)
        let result = run(.insert("("), in: "foo|", settings: off)
        XCTAssertEqual(result.text, "foo(")
    }

    func testBracketDoesNotPairBeforeIdentifier() {
        let result = run(.insert("\""), in: "foo|bar")
        XCTAssertEqual(result.text, "foo\"bar")
    }

    func testBracketStillPairsBeforeIdentifier() {
        let result = run(.insert("("), in: "foo|bar")
        XCTAssertEqual(result.text, "foo()bar")
    }

    // MARK: - Newline / indentation

    func testNewlineInheritsIndentation() {
        let result = run(.newline, in: "    int x;|")
        XCTAssertEqual(result.text, "    int x;\n    ")
        XCTAssertEqual(result.caret, result.text.utf16.count)
    }

    func testNewlineAfterOpenBraceAddsLevel() {
        let result = run(.newline, in: "if (x) {|\n}")
        XCTAssertEqual(result.text, "if (x) {\n    \n}")
    }

    func testNewlineBetweenBracesExpandsToThreeLines() {
        let result = run(.newline, in: "int main() {|}")
        XCTAssertEqual(result.text, "int main() {\n    \n}")
        // Caret lands on the indented middle line.
        XCTAssertEqual(result.caret, 17)
    }

    func testNewlineBetweenBracesUsesOuterIndent() {
        let result = run(.newline, in: "    if (x) {|}")
        XCTAssertEqual(result.text, "    if (x) {\n        \n    }")
    }

    func testClosingBraceTypedOnBlankLineOutdents() {
        let result = run(.insert("}"), in: "if (x) {\n    |")
        XCTAssertEqual(result.text, "if (x) {\n}")
        XCTAssertEqual(result.caret, result.text.utf16.count)
    }

    func testAutoIndentDisabledInsertsPlainNewline() {
        let off = EditSettings(autoIndent: false)
        let result = run(.newline, in: "    int x;|", settings: off)
        XCTAssertEqual(result.text, "    int x;\n")
    }

    func testTabInsertsIndentUnit() {
        let result = run(.tab, in: "|int x;")
        XCTAssertEqual(result.text, "    int x;")
    }

    func testTabIndentsSelectedLines() {
        let text = "a\nb"
        let outcome = EditPlanner.apply(.tab, to: text, selection: NSRange(location: 0, length: 3), settings: settings)
        XCTAssertEqual(outcome.text, "    a\n    b")
    }

    func testBacktabOutdentsLine() {
        let result = run(.backtab, in: "        int x;|")
        XCTAssertEqual(result.text, "    int x;")
    }

    func testTabUsesTabsWhenConfigured() {
        let tabs = EditSettings(indentWidth: 4, indentWithTabs: true)
        let result = run(.tab, in: "|x", settings: tabs)
        XCTAssertEqual(result.text, "\tx")
    }

    // MARK: - Deletion

    func testDeleteBackwardRemovesEmptyPair() {
        // The pair is empty, so both characters go.
        let result = run(.deleteBackward, in: "foo(|)")
        XCTAssertEqual(result.text, "foo")
        XCTAssertEqual(result.caret, 3)
    }

    func testDeleteBackwardRemovesEmptyBraces() {
        let result = run(.deleteBackward, in: "if (x) {|}")
        XCTAssertEqual(result.text, "if (x) ")
    }

    func testDeleteBackwardOutdentsWhitespaceOnlyLine() {
        let result = run(.deleteBackward, in: "int x;\n        |")
        XCTAssertEqual(result.text, "int x;\n    ")
    }

    func testDeleteBackwardRemovesSingleCharacterOtherwise() {
        let result = run(.deleteBackward, in: "abc|")
        XCTAssertEqual(result.text, "ab")
    }

    // MARK: - Comments

    func testToggleCommentCommentsLine() {
        let result = run(.toggleComment, in: "int x = 1;|")
        XCTAssertEqual(result.text, "// int x = 1;")
    }

    func testToggleCommentUncommentsLine() {
        let result = run(.toggleComment, in: "// int x = 1;|")
        XCTAssertEqual(result.text, "int x = 1;")
    }

    func testToggleCommentRespectsIndentation() {
        let result = run(.toggleComment, in: "    int x = 1;|")
        XCTAssertEqual(result.text, "    // int x = 1;")
    }

    func testToggleCommentAcrossSelection() {
        let text = "int a;\nint b;"
        let outcome = EditPlanner.apply(.toggleComment,
                                        to: text,
                                        selection: NSRange(location: 0, length: (text as NSString).length),
                                        settings: settings)
        XCTAssertEqual(outcome.text, "// int a;\n// int b;")
    }

    func testToggleCommentKeepsBlankLinesUntouched() {
        let text = "int a;\n\nint b;"
        let outcome = EditPlanner.apply(.toggleComment,
                                        to: text,
                                        selection: NSRange(location: 0, length: (text as NSString).length),
                                        settings: settings)
        XCTAssertEqual(outcome.text, "// int a;\n\n// int b;")
    }

    func testToggleCommentUncommentsMixedSelection() {
        let text = "// int a;\nint b;"
        let outcome = EditPlanner.apply(.toggleComment,
                                        to: text,
                                        selection: NSRange(location: 0, length: (text as NSString).length),
                                        settings: settings)
        XCTAssertEqual(outcome.text, "// int a;\n// int b;")
    }

    // MARK: - Helpers

    func testClampRange() {
        XCTAssertEqual(EditPlanner.clampRange(NSRange(location: 100, length: 5), in: "abc"),
                       NSRange(location: 3, length: 0))
        XCTAssertEqual(EditPlanner.clampRange(NSRange(location: -4, length: 99), in: "abcdef"),
                       NSRange(location: 0, length: 6))
    }

    func testIndentUnit() {
        XCTAssertEqual(EditSettings(indentWidth: 2).indentUnit, "  ")
        XCTAssertEqual(EditSettings(indentWidth: 8, indentWithTabs: true).indentUnit, "\t")
    }
}
