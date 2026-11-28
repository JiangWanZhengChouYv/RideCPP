import XCTest
@testable import EditorCore

/// Finding and replacing: the rules a person expects from a find bar.
final class TextSearchTests: XCTestCase {

    private let search = TextSearch()
    private let text = """
    int n;
    int count = 0;
    int counter = 0;
    // n is the count
    """

    func testFindsEveryOccurrence() {
        let found = search.matches(of: "int", in: text, options: .init())
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.first?.line, 0)
        XCTAssertEqual(found.last?.line, 2)
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(search.matches(of: "", in: text, options: .init()).isEmpty,
                      "an empty query must not match everything")
    }

    func testCaseInsensitiveByDefault() {
        let found = search.matches(of: "COUNT", in: text, options: .init())
        XCTAssertEqual(found.count, 3, "count, counter, count")
    }

    func testCaseSensitiveWhenAsked() {
        let found = search.matches(of: "COUNT", in: text, options: .init(caseSensitive: true))
        XCTAssertTrue(found.isEmpty)
    }

    /// `count` must not appear inside `counter`, which is what whole-word mode is for.
    func testWholeWordSkipsSubstrings() {
        let all = search.matches(of: "count", in: text, options: .init())
        let word = search.matches(of: "count", in: text, options: .init(wholeWord: true))
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(word.count, 2, "`counter` must be excluded")
    }

    func testRegularExpressions() {
        let found = search.matches(of: #"int\s+(\w+)"#, in: text,
                                   options: .init(caseSensitive: true, isRegex: true))
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual((text as NSString).substring(with: found[0].range), "int n")
    }

    /// A pattern that can match nothing must not hang the search.
    func testZeroWidthRegexDoesNotLoop() {
        let found = search.matches(of: "^", in: text,
                                   options: .init(isRegex: true))
        XCTAssertTrue(found.isEmpty || found.allSatisfy { $0.range.length > 0 })
    }

    func testInvalidRegexReturnsNothing() {
        XCTAssertTrue(search.matches(of: "([", in: text, options: .init(isRegex: true)).isEmpty)
    }

    /// ⌘G from the middle of the document moves forward, and wraps at the end.
    func testNextMatchWraps() {
        let found = search.matches(of: "int", in: text, options: .init())
        let after = search.nextMatch(after: found[0].range.location, in: found)
        XCTAssertEqual(after?.range, found[1].range)
        let wrapped = search.nextMatch(after: found.last!.range.location, in: found)
        XCTAssertEqual(wrapped?.range, found[0].range, "wraps to the first match")
    }

    func testPreviousMatchWrapsBackwards() {
        let found = search.matches(of: "int", in: text, options: .init())
        let before = search.previousMatch(before: found[2].range.location, in: found)
        XCTAssertEqual(before?.range, found[1].range)
        let wrapped = search.previousMatch(before: found[0].range.location, in: found)
        XCTAssertEqual(wrapped?.range, found[2].range, "wraps to the last match")
    }

    /// Replacing is applied to the whole document in one pass.
    func testReplaceAll() {
        let result = search.replacingAll(in: text, query: "int", with: "long", options: .init())
        XCTAssertEqual(result.components(separatedBy: "long").count - 1, 3)
        XCTAssertFalse(result.contains("int "))
    }

    /// A replacement containing a backslash is inserted literally, not treated
    /// as a capture reference.
    func testReplacementIsLiteral() {
        let result = search.replacingAll(in: "a.b", query: "a", with: #"\1"#, options: .init())
        XCTAssertEqual(result, #"\1.b"#)
    }

    func testReplaceAllWithNoMatchesLeavesTextAlone() {
        let result = search.replacingAll(in: text, query: "zzz", with: "x", options: .init())
        XCTAssertEqual(result, text)
    }
}
