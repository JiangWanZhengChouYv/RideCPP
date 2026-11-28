import XCTest
@testable import EditorCore

/// clangd sends snippets; what we show and insert must be usable code.
final class SnippetConversionTests: XCTestCase {

    /// clangd's suggestion for a using-directive is `using namespace $0;`. The
    /// marker is a cursor position, not text, and must not reach the list.
    func testPositionalPlaceholderIsRemoved() {
        let converted = SemanticCompletionProvider.convertSnippet("using namespace $0;")
        XCTAssertFalse(converted.contains("$0"), "converted=\\(converted)")
    }

    func testNamedPlaceholderBecomesAGreyMarker() {
        let converted = SemanticCompletionProvider.convertSnippet("using ${1:name} = $0;")
        XCTAssertTrue(converted.contains("name"), converted)
        XCTAssertFalse(converted.contains("$0"), converted)
    }

    /// Accepting must produce code with no leftover markers and no double space.
    func testAcceptedTextIsCleanCPlusPlus() {
        let converted = SemanticCompletionProvider.convertSnippet("using namespace $0;")
        let inserted = CompletionItem(text: converted).insertionText
        XCTAssertEqual(inserted, "using namespace ;")
        XCTAssertFalse(inserted.contains("$"), "inserted=\\(inserted)")
        XCTAssertFalse(inserted.contains("  "), "no double space: \\(inserted)")
    }
}
