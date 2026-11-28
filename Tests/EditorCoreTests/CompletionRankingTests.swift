import XCTest
@testable import EditorCore

/// A completion list is only useful if the right thing is near the top.
final class SemanticRankingTests: XCTestCase {

    private func lsp(_ label: String, kind: Int, sort: String) -> LSPCompletionItem {
        LSPCompletionItem(label: label, insertText: label, detail: nil,
                          documentation: nil, kindCode: kind, sortText: sort)
    }

    /// clangd prefixes header symbols with a bullet. Treating it as part of the
    /// name made the name empty, which then sorted those symbols to the top.
    func testBulletIsNotPartOfTheName() {
        XCTAssertEqual(SemanticCompletionProvider.name(from: "•FE_ALL_EXCEPT"), "FE_ALL_EXCEPT")
        XCTAssertEqual(SemanticCompletionProvider.name(from: "•cout"), "cout")
        XCTAssertEqual(SemanticCompletionProvider.name(from: "flag"), "flag")
        XCTAssertEqual(SemanticCompletionProvider.name(from: "factorial(int x)"), "factorial")
    }

    /// clangd's own ordering is meaningful and must survive.
    func testServerOrderingIsPreserved() {
        let local = SemanticCompletionProvider.rankKey(
            lsp: lsp("flag", kind: 6, sort: "3f8bfb0eflag"), name: "flag", prefix: "f")
        let standardLib = SemanticCompletionProvider.rankKey(
            lsp: lsp("•false_type", kind: 8, sort: "4109f058false_type"),
            name: "false_type", prefix: "f")
        XCTAssertLessThan(local, standardLib, "a local variable must outrank a header symbol")
    }

    /// Typing lowercase must not surface SHOUTY macros above real matches.
    func testCaseMismatchSortsLast() {
        let exact = SemanticCompletionProvider.rankKey(
            lsp: lsp("float", kind: 14, sort: "00"), name: "float", prefix: "f")
        let caseOnly = SemanticCompletionProvider.rankKey(
            lsp: lsp("•FE_ALL_EXCEPT", kind: 4, sort: "00"),
            name: "FE_ALL_EXCEPT", prefix: "f")
        XCTAssertLessThan(exact, caseOnly,
                          "an exact-case match must come before a case-insensitive one")
    }

    /// clangd sends `for (…)` as a snippet; it must read as a keyword.
    func testSnippetKindMapsToKeyword() {
        XCTAssertEqual(SemanticCompletionProvider.kind(fromLSP: 15), .keyword)
        XCTAssertEqual(SemanticCompletionProvider.kind(fromLSP: 14), .keyword)
        XCTAssertEqual(SemanticCompletionProvider.kind(fromLSP: 6), .userDefined)
    }

    /// Different kinds of library symbol still read differently in the list.
    func testLibrarySymbolsAreNotAllLabelledTheSame() {
        XCTAssertEqual(SemanticCompletionProvider.kind(fromLSP: 6), .userDefined)  // variable
        XCTAssertNotEqual(SemanticCompletionProvider.kind(fromLSP: 7),
                          SemanticCompletionProvider.kind(fromLSP: 15))       // class vs keyword
    }
}
