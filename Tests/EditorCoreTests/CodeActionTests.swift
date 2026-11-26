import XCTest
@testable import EditorCore

/// Quick-fix plumbing: the server edit has to map onto the exact range.
final class CodeActionTests: XCTestCase {

    private func action(newText: String, start: (Int, Int), end: (Int, Int)) -> LSPCodeAction {
        LSPCodeAction(title: "fix",
                      newText: newText,
                      range: LSPRange(start: LSPPosition(line: start.0, character: start.1),
                                      end: LSPPosition(line: end.0, character: end.1)),
                      kind: "quickfix", isPreferred: true)
    }

    func testReplacesSingleLineRange() {
        let text = "std::strin s;\n"
        let fixed = SemanticCompletionProvider.apply(
            action(newText: "string", start: (0, 5), end: (0, 10)), to: text)
        XCTAssertEqual(fixed, "std::string s;\n")
    }

    func testReplacesRangeOnLaterLine() {
        let text = "int main() {\n    std::strin s;\n}\n"
        let fixed = SemanticCompletionProvider.apply(
            action(newText: "string", start: (1, 9), end: (1, 14)), to: text)
        XCTAssertEqual(fixed, "int main() {\n    std::string s;\n}\n")
    }

    func testReplacesMultiLineRange() {
        let text = "a\nb\nc\n"
        let fixed = SemanticCompletionProvider.apply(
            action(newText: "X", start: (0, 0), end: (1, 1)), to: text)
        XCTAssertEqual(fixed, "X\nc\n")
    }

    func testActionWithoutEditIsNotApplicable() {
        let noEdit = LSPCodeAction(title: "Extract variable", newText: nil, range: nil,
                                   kind: "refactor", isPreferred: false)
        XCTAssertFalse(noEdit.isApplicable)
        XCTAssertNil(SemanticCompletionProvider.apply(noEdit, to: "int x;"))
    }

    func testActionWithOutOfBoundsRangeIsRejected() {
        let text = "short\n"
        let broken = action(newText: "x", start: (5, 0), end: (5, 2))
        XCTAssertNil(SemanticCompletionProvider.apply(broken, to: text))
    }

    func testParsingPrefersLiteralEditWithKindAndPreferred() {
        let json: [String: Any] = [
            "title": "change 'strin' to 'string'",
            "kind": "quickfix",
            "isPreferred": true,
            "edit": ["changes": ["file:///tmp/x.cpp": [[
                "newText": "string",
                "range": [
                    "start": ["line": 3, "character": 9],
                    "end": ["line": 3, "character": 14]
                ]
            ]]]]
        ]
        let parsed = ClangdSession.codeAction(from: json)
        XCTAssertEqual(parsed?.title, "change 'strin' to 'string'")
        XCTAssertEqual(parsed?.kind, "quickfix")
        XCTAssertEqual(parsed?.isPreferred, true)
        XCTAssertEqual(parsed?.newText, "string")
        XCTAssertEqual(parsed?.range?.start.line, 3)
        XCTAssertEqual(parsed?.range?.start.character, 9)
        XCTAssertTrue(parsed?.isApplicable == true)
    }

    func testParsingCommandStyleActionKeepsTitleButIsNotApplicable() {
        // What clangd sends without literal support: a Command, no edit.
        let json: [String: Any] = [
            "title": "Apply fix: change 'strin' to 'string'",
            "command": ["command": "clangd.applyFix", "title": "Apply fix"]
        ]
        let parsed = ClangdSession.codeAction(from: json)
        XCTAssertEqual(parsed?.title, "Apply fix: change 'strin' to 'string'")
        XCTAssertFalse(parsed?.isApplicable == true)
    }
}
