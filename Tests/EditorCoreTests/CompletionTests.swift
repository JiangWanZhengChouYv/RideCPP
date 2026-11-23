import XCTest
@testable import EditorCore

final class CompletionTests: XCTestCase {

    private let provider = BuiltinCompletionProvider()

    private func texts(_ prefix: String, context: CompletionContext = .code, document: String = "") -> [String] {
        provider.completionItems(forPrefix: prefix, document: document, context: context).map(\.text)
    }

    func testSingleLetterListsCommonKeywords() {
        let items = texts("i")
        XCTAssertTrue(items.contains("int"), "expected int for prefix i, got \(items)")
        XCTAssertTrue(items.contains(where: { $0.hasPrefix("if") }), "expected an if form for prefix i")
    }

    func testPrefixFiltersAndKeepsOrderByRelevance() {
        let items = texts("whi")
        XCTAssertEqual(items.first, "while")
        XCTAssertFalse(items.contains("int"))
    }

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(texts("RET"), ["return"])
    }

    func testExactKeywordAlsoOffersSnippet() {
        let items = texts("for")
        // The snippet body is offered (it contains the loop scaffold) and the
        // plain keyword is still selectable.
        XCTAssertTrue(items.contains("for"))
        XCTAssertTrue(items.contains { $0.contains("for (") && $0.contains("++i") })
    }

    func testPreprocessorContextListsDirectives() {
        let items = texts("", context: .preprocessor)
        XCTAssertTrue(items.contains("#include"))
        XCTAssertTrue(items.contains("#define"))
        let filtered = texts("inc", context: .preprocessor)
        XCTAssertTrue(filtered.contains("#include"))
        XCTAssertFalse(filtered.contains("#pragma"))
    }

    func testIdentifiersFromDocumentComplete() {
        let document = """
        struct TreeNode { int value; };
        int main() {
            TreeNode node;
            return 0;
        }
        """
        let items = texts("Tre", document: document)
        XCTAssertTrue(items.contains("TreeNode"), "expected TreeNode, got \(items)")
    }

    func testNoDuplicateSuggestions() {
        let items = texts("i", document: "int x = 1; int y = 2;")
        XCTAssertEqual(items.count, Set(items).count)
    }

    func testPrefixExtractionAndRange() {
        let text = "int main() { int cou"
        let result = BuiltinCompletionProvider.prefix(at: (text as NSString).length, in: text)
        XCTAssertEqual(result.prefix, "cou")
        XCTAssertEqual((text as NSString).substring(with: result.range), "cou")
    }

    func testPrefixAtWordBoundaryIsEmpty() {
        let text = "int x = "
        let result = BuiltinCompletionProvider.prefix(at: (text as NSString).length, in: text)
        XCTAssertEqual(result.prefix, "")
    }

    func testOverlongPrefixSuggestsNothing() {
        XCTAssertTrue(texts(String(repeating: "a", count: 40)).isEmpty)
    }
}
