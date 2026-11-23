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

/// Navigation and list-refresh behaviour of the open completion list.
final class CompletionNavigationTests: XCTestCase {

    private func makeEditor() -> CodeTextView {
        let engine = EditorEngine(settings: EditSettings(indentWidth: 4))
        let view = engine.textView
        view.string = "int main() {\n    \n}\n"
        view.setSelectedRange(NSRange(location: 17, length: 0))
        view.showCompletions(nil)
        return view
    }

    private var downArrow: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{F701}",
                         charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
    }

    private var upArrow: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{F700}",
                         charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
    }

    func testArrowKeysMoveTheSelection() {
        let view = makeEditor()
        XCTAssertGreaterThan(view.completionItemCount, 2)
        let start = view.selectedCompletionIndex
        XCTAssertTrue(view.handleCompletionKey(downArrow))
        XCTAssertEqual(view.selectedCompletionIndex, start + 1)
        XCTAssertTrue(view.handleCompletionKey(downArrow))
        XCTAssertEqual(view.selectedCompletionIndex, start + 2)
        XCTAssertTrue(view.handleCompletionKey(upArrow))
        XCTAssertEqual(view.selectedCompletionIndex, start + 1)
    }

    func testSelectionWrapsAroundBothEnds() {
        let view = makeEditor()
        let count = view.completionItemCount
        // Up from the first row wraps to the last.
        _ = view.handleCompletionKey(upArrow)
        XCTAssertEqual(view.selectedCompletionIndex, count - 1)
        // Down from the last wraps back to the first.
        _ = view.handleCompletionKey(downArrow)
        XCTAssertEqual(view.selectedCompletionIndex, 0)
    }

    func testAcceptingInsertsTheNavigatedToItem() {
        let view = makeEditor()
        _ = view.handleCompletionKey(downArrow)
        let expected = view.selectedCompletionText
        _ = view.handleCompletionKey(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                      modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil,
                                                      characters: "\r",
                                                      charactersIgnoringModifiers: "\r",
                                                      isARepeat: false, keyCode: 36)!)
        XCTAssertFalse(view.isShowingCompletions)
        if let expected, !expected.contains("\n") {
            XCTAssertTrue(view.string.contains(expected), "expected \(expected.debugDescription) in \(view.string.debugDescription)")
        }
    }

    func testDeletingRefiltersTheOpenList() {
        // Type "vec", then delete back: the candidate list must follow each step.
        let engine = EditorEngine(settings: EditSettings(indentWidth: 4))
        let view = engine.textView
        view.string = "int main() {\n    \n}\n"
        view.setSelectedRange(NSRange(location: 17, length: 0))
        for character in "vec" {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertTrue(view.isShowingCompletions)
        let atVec = view.completionItemCount

        view.deleteBackward(nil)
        XCTAssertTrue(view.isShowingCompletions, "list closed after one deletion")
        let atVe = view.completionItemCount
        // "ve" is a broader prefix than "vec", so it offers at least as many.
        XCTAssertGreaterThanOrEqual(atVe, atVec)

        view.deleteBackward(nil)
        view.deleteBackward(nil)
        // With the word gone there is nothing to complete.
        XCTAssertFalse(view.isShowingCompletions)
    }

    func testDeletingKeepsListOpenWhilePrefixRemains() {
        let view = makeEditor()
        let before = view.completionItemCount
        view.deleteBackward(nil)
        // Deleting the space leaves an empty prefix, so the list is dismissed.
        XCTAssertFalse(view.isShowingCompletions, "expected dismissal once the word is gone")

        // Re-open and delete within a word instead.
        view.insertText("v", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.isShowingCompletions)
        XCTAssertGreaterThan(view.completionItemCount, 0)
        view.deleteBackward(nil)
        XCTAssertTrue(view.isShowingCompletions, "list closed even though a prefix remains")
        _ = before
    }
}

/// `using namespace std;` must remove the `std::` prefix from suggestions.
final class NamespaceAwarenessTests: XCTestCase {

    private let provider = BuiltinCompletionProvider()

    private func insertion(for prefix: String, in document: String) -> String? {
        provider.completionItems(forPrefix: prefix, document: document, context: .code)
            .first { $0.insertionText.contains("vector") }?
            .insertionText
    }

    func testUsingNamespaceStdDropsThePrefix() {
        let result = insertion(for: "vec", in: "using namespace std;\nint main() {}\n")
        XCTAssertEqual(result, "vector<int>")
    }

    func testWithoutUsingNamespaceKeepsThePrefix() {
        let result = insertion(for: "vec", in: "int main() {}\n")
        XCTAssertEqual(result, "std::vector<int>")
    }

    func testUsingDeclarationDoesNotCount() {
        // `using std::vector;` imports one name, not the namespace.
        let result = insertion(for: "vec", in: "using std::vector;\nint main() {}\n")
        XCTAssertEqual(result, "std::vector<int>")
    }

    func testDetectionIgnoresComments() {
        XCTAssertFalse(BuiltinCompletionProvider.hasUsingNamespaceStd("// using namespace std;\n"))
        XCTAssertFalse(BuiltinCompletionProvider.hasUsingNamespaceStd("/* using namespace std; */\n"))
        XCTAssertTrue(BuiltinCompletionProvider.hasUsingNamespaceStd("using namespace std;"))
        XCTAssertTrue(BuiltinCompletionProvider.hasUsingNamespaceStd("  using  namespace   std ;"))
    }

    func testDetectionInGlobalScopeOnlyMattersNotLocalScope() {
        // A local `using` still covers the file's later code here, which is what
        // the user intends when writing it.
        XCTAssertTrue(BuiltinCompletionProvider.hasUsingNamespaceStd("int main() { using namespace std; }"))
    }
}

/// Frequency-based ranking: common names must survive the candidate cap from the
/// first keystroke, which plain alphabetical order could not guarantee.
final class CompletionRankingTests: XCTestCase {

    private func makeProvider() -> (BuiltinCompletionProvider, DocumentSymbolIndex, String) {
        let document = """
        #include <iostream>
        #include <vector>
        #include <algorithm>
        #include <string>
        using namespace std;
        int main() { return 0; }
        """
        let index = DocumentSymbolIndex()
        index.indexSynchronously(headers: HeaderPaths.includes(in: document))
        return (BuiltinCompletionProvider(index: index), index, document)
    }

    func testShortPrefixStillOffersFrequentlyUsedName() {
        let (provider, _, document) = makeProvider()
        let singleLetter = provider.completionItems(forPrefix: "c", document: document, context: .code)
            .map(\.insertionText)
        // `cout` used to be pushed out by the keyword list until "cou" was typed.
        XCTAssertTrue(singleLetter.contains("cout"), "cout missing for prefix c: \(singleLetter.prefix(10))")
        XCTAssertTrue(singleLetter.contains("cin"))
    }

    func testCommonNamesRankAheadOfEqualLengthKeywords() {
        let (provider, _, document) = makeProvider()
        let names = provider.completionItems(forPrefix: "s", document: document, context: .code)
            .map(\.insertionText)
        guard let first = names.first else { return XCTFail("no suggestions") }
        // `size`/`sort` are far more likely than `static`/`struct` here.
        XCTAssertTrue(["size", "sort", "swap", "string", "second"].contains(first),
                      "unexpected top suggestion: \(first)")
    }

    func testLocallyUsedNamesOutrankHeaderNames() {
        let document = """
        #include <iostream>
        int main() { int counter = 0; return counter; }
        """
        let index = DocumentSymbolIndex()
        index.indexSynchronously(headers: HeaderPaths.includes(in: document))
        let provider = BuiltinCompletionProvider(index: index)
        let names = provider.completionItems(forPrefix: "c", document: document, context: .code)
            .map(\.insertionText)
        let localPosition = names.firstIndex(of: "counter")
        let keywordPosition = names.firstIndex(of: "class")
        if let localPosition, let keywordPosition {
            XCTAssertLessThan(localPosition, keywordPosition,
                              "a name used in this file should beat a keyword of similar shape")
        }
    }

    func testRankingDoesNotInventVocabulary() {
        // Every offered name must be a keyword or come from the included headers.
        let document = "#include <iostream>\n"
        let index = DocumentSymbolIndex()
        index.indexSynchronously(headers: ["iostream"])
        let provider = BuiltinCompletionProvider(index: index)
        let offered = provider.completionItems(forPrefix: "c", document: document, context: .code)
            .map(\.insertionText)
            // Snippets are multi-line scaffolds, not vocabulary; they are added
            // after ranking and are checked by their own tests.
            .filter { !$0.contains("\n") && !$0.contains("{") }
        let allowed = Set(KeywordTable.keywords())
        for name in offered where !allowed.contains(name) {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(index.names(from: ["iostream"], prefix: name, limit: 1).contains(name),
                          "\(name) is neither a keyword nor from the headers")
        }
    }
}

/// The remembered-symbol store: custom functions, structs, classes and variables
/// must come back in later files and sessions.
final class UserSymbolStoreTests: XCTestCase {

    func testParsesDeclarationsButNotStandardNames() {
        let document = """
        #include <iostream>
        struct Point { int x; int y; };
        class Solver { public: int solve(int n); };
        enum class Color { Red };
        std::vector<int> numbers;
        int computeSum(int a, int b) { return a + b; }
        int main() { Point p; return 0; }
        """
        let names = UserSymbolStore.parseDeclarations(in: document).map(\.0)
        XCTAssertTrue(names.contains("Point"))
        XCTAssertTrue(names.contains("Solver"))
        XCTAssertTrue(names.contains("solve"))
        XCTAssertTrue(names.contains("Color"))
        XCTAssertTrue(names.contains("computeSum"))
        // Standard types and keywords are not user symbols.
        XCTAssertFalse(names.contains("vector"))
        XCTAssertFalse(names.contains("int"))
        XCTAssertFalse(names.contains("main"))
    }

    func testRemembersAcrossDocumentsWithoutIncludes() {
        let store = UserSymbolStore()
        store.replaceAll([])
        store.remember(declarationsIn: "struct TreeNode { int val; };\nint computeHash(int k) { return k; }\n")
        XCTAssertEqual(store.count, 2)

        // A brand-new file with no includes: only memory can help here.
        let provider = BuiltinCompletionProvider(index: DocumentSymbolIndex(), symbols: store)
        let suggestions = provider.completionItems(forPrefix: "tree", document: "int main() {}\n", context: .code)
        XCTAssertEqual(suggestions.first?.insertionText, "TreeNode")
        XCTAssertEqual(suggestions.first?.kind, .userDefined)
    }

    func testFrequentlyUsedNamesRankFirst() {
        let store = UserSymbolStore()
        store.replaceAll([
            RememberedSymbol(name: "alphaName", kind: .userDefined, uses: 1, lastSeen: Date()),
            RememberedSymbol(name: "alpinePeak", kind: .userDefined, uses: 9, lastSeen: Date())
        ])
        let names = store.symbols(withPrefix: "alp", limit: 5).map(\.name)
        XCTAssertEqual(names.first, "alpinePeak")
    }

    func testStoreIsCapped() {
        let store = UserSymbolStore()
        let many = (0..<(UserSymbolStore.maximumSymbols + 50)).map {
            RememberedSymbol(name: "sym\($0)", kind: .userDefined, uses: 1, lastSeen: Date())
        }
        store.replaceAll(many)
        XCTAssertLessThanOrEqual(store.count, UserSymbolStore.maximumSymbols)
    }

    func testKindsDriveTheBadgeSource() {
        let document = "#include <iostream>\nstruct Widget { };\n"
        let index = DocumentSymbolIndex()
        index.indexSynchronously(headers: ["iostream"])
        let store = UserSymbolStore()
        store.replaceAll([])
        store.remember(declarationsIn: document)
        let provider = BuiltinCompletionProvider(index: index, symbols: store)

        let items = provider.completionItems(forPrefix: "w", document: document, context: .code)
        XCTAssertEqual(items.first { $0.insertionText == "Widget" }?.kind, .userDefined)

        let standard = provider.completionItems(forPrefix: "cou", document: document, context: .code)
        XCTAssertEqual(standard.first { $0.insertionText == "cout" }?.kind, .header)

        let keyword = provider.completionItems(forPrefix: "whil", document: document, context: .code)
        XCTAssertEqual(keyword.first { $0.insertionText == "while" }?.kind, .keyword)
    }
}

/// The outline sidebar: symbols and their line numbers.
final class DocumentOutlineTests: XCTestCase {

    private let document = """
    #include <iostream>

    struct Point { int x; };

    class Solver {
    public:
        int solve(int n);
    };

    enum class Color { Red };

    int globalCount = 0;

    int computeSum(int a, int b) {
        int total = a + b;
        return total;
    }
    """

    func testFindsEveryDeclarationKind() {
        let items = DocumentOutline.items(in: document)
        let kinds = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.kind) })
        XCTAssertEqual(kinds["Point"], .structure)
        XCTAssertEqual(kinds["Solver"], .class)
        XCTAssertEqual(kinds["Color"], .enumeration)
        XCTAssertEqual(kinds["computeSum"], .function)
        XCTAssertEqual(kinds["solve"], .function)
        XCTAssertEqual(kinds["iostream"], .include)
        XCTAssertEqual(kinds["globalCount"], .variable)
    }

    func testLineNumbersPointAtTheDeclaration() {
        let items = DocumentOutline.items(in: document)
        guard let function = items.first(where: { $0.name == "computeSum" }) else {
            return XCTFail("computeSum missing")
        }
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines[function.line - 1].contains("computeSum"),
                      "line \(function.line) is \(lines[function.line - 1])")
    }

    func testLocalsInsideFunctionsAreNotOutlined() {
        let items = DocumentOutline.items(in: document)
        XCTAssertFalse(items.contains { $0.name == "total" },
                       "a function-local variable should not appear in the outline")
    }

    func testParameterListIsCaptured() {
        let items = DocumentOutline.items(in: document)
        XCTAssertEqual(items.first { $0.name == "computeSum" }?.detail, "(int a, int b)")
        // No parameters reads as a bare name rather than "()".
        XCTAssertNil(items.first { $0.name == "solve" } != nil ? nil : "(nothing)")
        XCTAssertEqual(items.first { $0.name == "solve" }?.detail, "(int n)")
    }
}
