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

    func testOnDemandIndexOnlyCoversIncludedHeaders() {
        let index = DocumentSymbolIndex()
        let headers = HeaderPaths.includes(in: "#include <vector>\n#include <string>\n")
        XCTAssertEqual(headers, ["vector", "string"])
        index.indexSynchronously(headers: headers)

        XCTAssertTrue(index.names(from: headers, prefix: "vector", limit: 5).contains("vector"))
        // A header the file does not include must contribute nothing.
        XCTAssertTrue(index.names(from: headers, prefix: "unordered_", limit: 5).isEmpty)
        XCTAssertEqual(index.indexedHeaderCount, 2)
    }

    func testIncludeParsing() {
        let document = """
        #include <iostream>
        #include "local.h"
        #include <vector>
        // #include <ignored>
        int main() {}
        """
        XCTAssertEqual(HeaderPaths.includes(in: document), ["iostream", "local.h", "vector"])
    }

    func testFirstQueryDoesNotBlockBeforeIndexing() {
        let index = DocumentSymbolIndex()
        let headers = HeaderPaths.includes(in: "#include <deque>\n")
        let started = Date()
        _ = index.names(from: headers, prefix: "deq", limit: 5)
        // Must return immediately (it queues the scan) rather than waiting for I/O.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
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

/// Insertion-side behaviour: snippets must match the document's own indentation.
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
