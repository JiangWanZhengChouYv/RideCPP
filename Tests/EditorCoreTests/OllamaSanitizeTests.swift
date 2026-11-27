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
        XCTAssertEqual(clean(" >> n >> m;", typed: "cin"), ">> n >> m;")
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
        // A model given `wh` normally repeats the whole word. The typed part is
        // removed, so what comes back is exactly what still needs inserting.
        XCTAssertEqual(clean("while (cin >> n) {", typed: "wh"), "ile (cin >> n) {")
        XCTAssertEqual(clean("vector<int> a(n);", typed: "vec"), "tor<int> a(n);")
    }

    /// A leading newline is not noise: it means the model wants to start a new
    /// line, and the suggestion keeps that shape.
    func testLeadingNewlineIsPreserved() {
        XCTAssertEqual(clean("\n (int i = 0; i < n; ++i) {", typed: "for"),
                       "\n (int i = 0; i < n; ++i) {")
    }

    func testStripsMarkdownFences() {
        XCTAssertEqual(clean("```cpp\n (a);\n```", typed: "sort"), "\n (a);")
    }

    func testTrailingWordExtractsTheTypedIdentifier() {
        XCTAssertEqual(OllamaClient.trailingWord(in: "    wh"), "wh")
        XCTAssertEqual(OllamaClient.trailingWord(in: "a = "), "")
        XCTAssertEqual(OllamaClient.trailingWord(in: "vec_1"), "vec_1")
    }

    /// After `int n;` the model wants to start a new statement, which it signals
    /// with a leading newline. Dropping those made the model look broken on the
    /// most ordinary case of all.
    func testKeepsANewLineStatement() {
        // One statement only: a second, unrelated statement would cover the code
        // underneath and is not part of this prediction.
        XCTAssertEqual(clean("\n    int a[n];\n    for (int i = 0; i < n; i++) {", typed: "i"),
                       "\n    int a[n];")
        XCTAssertEqual(clean("\n    cout << n;", typed: ""), "\n    cout << n;")
        // A statement that opens a block keeps the block's first line.
        XCTAssertEqual(clean("\n    for (int i = 0; i < n; i++) {\n        cin >> a[i];", typed: "i"),
                       "\n    for (int i = 0; i < n; i++) {\n        cin >> a[i];")
    }

    /// `wh` + `cout` is a different word, but `wh` + `hile` is `while`.
    func testContinuationDetection() {
        XCTAssertTrue(OllamaClient.continuesLine(" (cin >> n) {", typedWord: "while"))
        XCTAssertTrue(OllamaClient.continuesLine("hile (cin >> n) {", typedWord: "w"))
        XCTAssertTrue(OllamaClient.continuesLine("(a.begin(), a.end());", typedWord: "sort"))
        XCTAssertFalse(OllamaClient.continuesLine("cout << n;", typedWord: "wh"))
        XCTAssertFalse(OllamaClient.continuesLine("int a[n];", typedWord: "for"))
        // A full identifier followed by more of itself is not a continuation.
        XCTAssertFalse(OllamaClient.continuesLine("sort(a, b);", typedWord: "sort"))
    }
}
