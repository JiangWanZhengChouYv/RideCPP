import XCTest
@testable import EditorCore

/// Which blocks can be folded, and what they would hide.
final class CodeFoldingTests: XCTestCase {

    func testFoldsAMultiLineFunction() {
        let text = """
        int main() {
            int x = 1;
            return x;
        }
        """
        let regions = CodeFolding.regions(in: text)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.startLine, 0)
        XCTAssertEqual(regions.first?.endLine, 3)
    }

    /// A body on one line has nothing to hide.
    func testSingleLineBlockIsNotFoldable() {
        XCTAssertTrue(CodeFolding.regions(in: "int f() { return 1; }").isEmpty)
    }

    func testNestedBlocksFoldIndependently() {
        let text = """
        void f() {
            if (x) {
                a();
            }
        }
        """
        let map = CodeFolding.foldMap(in: text)
        XCTAssertEqual(map[0], 4, "outer function")
        XCTAssertEqual(map[1], 3, "inner if")
    }

    /// Braces inside strings and comments are not structure.
    func testBracesInLiteralsAndCommentsAreIgnored() {
        let text = """
        // {
        const char *s = "{{{";
        """
        XCTAssertTrue(CodeFolding.regions(in: text).isEmpty)
    }

    func testBlockCommentHidesBraces() {
        let text = """
        /* {
              } */
        """
        XCTAssertTrue(CodeFolding.regions(in: text).isEmpty)
    }

    /// An escaped quote must not end the literal early and expose a brace.
    func testEscapedQuoteDoesNotEndTheString() {
        let text = """
        const char *s = "a\\"{";
        """
        XCTAssertTrue(CodeFolding.regions(in: text).isEmpty)
    }

    /// Unbalanced braces (a file being typed) must not crash or invent ranges.
    func testUnclosedBraceIsIgnored() {
        let text = """
        void f() {
            if (x) {
        """
        XCTAssertTrue(CodeFolding.regions(in: text).isEmpty)
    }

    func testStrayClosingBraceIsIgnored() {
        XCTAssertTrue(CodeFolding.regions(in: "}\n").isEmpty)
    }
}
