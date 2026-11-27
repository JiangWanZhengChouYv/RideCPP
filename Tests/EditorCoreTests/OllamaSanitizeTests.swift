import XCTest
@testable import EditorCore

/// Cleaning a model continuation: keep what continues the line, drop the rest.
final class OllamaSanitizeTests: XCTestCase {

    private func clean(_ raw: String, typed: String) -> String {
        OllamaClient.sanitize(raw, following: typed)
    }

    func testKeepsAGenuineContinuation() {
        XCTAssertEqual(clean(" (int i = 0; i < n; ++i) {", typed: "for"),
                       " (int i = 0; i < n; ++i) {")
        XCTAssertEqual(clean(" >> n >> m;", typed: "cin"), " >> n >> m;")
        XCTAssertEqual(clean("(a.begin(), a.end());", typed: "sort"),
                       "(a.begin(), a.end());")
    }

    /// The failure the user actually saw: `wh` answered with a whole new
    /// statement. Inserting that corrupts the line, so it must be dropped.
    func testRejectsANewStatementInsteadOfAContinuation() {
        XCTAssertEqual(clean("cout << n << endl;", typed: "wh"), "")
    }

    /// Answering with the rest of the word is a continuation, and useful.
    func testAcceptsCompletionOfTheWordBeingTyped() {
        // A model given `wh` normally repeats the whole word or continues it.
        XCTAssertEqual(clean("while (cin >> n) {", typed: "wh"), "while (cin >> n) {")
        XCTAssertEqual(clean("vector<int> a(n);", typed: "vec"), "vector<int> a(n);")
    }

    /// A leading newline is common and used to make the first line empty, which
    /// silently threw away a good suggestion.
    func testLeadingNewlineDoesNotDiscardTheSuggestion() {
        XCTAssertEqual(clean("\n (int i = 0; i < n; ++i) {", typed: "for"),
                       " (int i = 0; i < n; ++i) {")
    }

    func testStripsMarkdownFences() {
        XCTAssertEqual(clean("```cpp\n (a);\n```", typed: "sort"), " (a);")
    }

    func testTrailingWordExtractsTheTypedIdentifier() {
        XCTAssertEqual(OllamaClient.trailingWord(in: "    wh"), "wh")
        XCTAssertEqual(OllamaClient.trailingWord(in: "a = "), "")
        XCTAssertEqual(OllamaClient.trailingWord(in: "vec_1"), "vec_1")
    }
}
