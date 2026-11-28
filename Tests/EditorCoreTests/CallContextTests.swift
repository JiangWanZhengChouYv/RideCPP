import XCTest
@testable import EditorCore

/// Deciding when the caret is inside a call's arguments.
final class CallContextTests: XCTestCase {

    /// Caret placed with a marker so the offsets read like the source.
    private func info(in marked: String) -> CallContext.Info? {
        guard let mark = marked.firstIndex(of: "|") else { return nil }
        let offset = marked.distance(from: marked.startIndex, to: mark)
        let text = marked.replacingOccurrences(of: "|", with: "")
        return CallContext.info(at: offset, in: text)
    }

    func testFirstArgument() {
        let context = info(in: "greet(|")
        XCTAssertEqual(context?.callee, "greet")
        XCTAssertEqual(context?.argumentIndex, 0)
    }

    func testThirdArgumentIsCountedFromCommas() {
        let context = info(in: "greet(s, 3, |")
        XCTAssertEqual(context?.callee, "greet")
        XCTAssertEqual(context?.argumentIndex, 2)
    }

    func testNestedCallsCountTheInnerOne() {
        let context = info(in: "outer(inner(a, |)")
        XCTAssertEqual(context?.callee, "inner")
        XCTAssertEqual(context?.argumentIndex, 1)
    }

    /// A comma inside a string literal must not advance the parameter.
    func testCommasInStringsDoNotCount() {
        let context = info(in: #"printf("a, b", |"#)
        XCTAssertEqual(context?.argumentIndex, 1)
    }

    /// Control-flow keywords take parentheses but are not calls.
    func testKeywordsAreNotCalls() {
        XCTAssertNil(info(in: "if (|"))
        XCTAssertNil(info(in: "while (|"))
        XCTAssertNil(info(in: "for (|"))
        XCTAssertNil(info(in: "return (|"))
    }

    /// Outside any parentheses there is nothing to describe.
    func testOutsideCallIsNil() {
        XCTAssertNil(info(in: "int x = |"))
        XCTAssertNil(info(in: "greet(a)|"))
    }

    /// Once a statement ended, an earlier parenthesis is not enclosing.
    func testStatementBoundaryStopsTheScan() {
        XCTAssertNil(info(in: "f(a); g = |"))
    }

    func testMemberCallNameIsJustTheIdentifier() {
        let context = info(in: "v.push_back(|")
        XCTAssertEqual(context?.callee, "push_back")
    }

    /// Whitespace between the name and the parenthesis is allowed.
    func testSpaceBeforeParenthesis() {
        let context = info(in: "greet (|")
        XCTAssertEqual(context?.callee, "greet")
    }

    /// The caret at the very start of the document has nothing to describe.
    func testStartOfDocument() {
        XCTAssertNil(info(in: "|int x;"))
    }
}
