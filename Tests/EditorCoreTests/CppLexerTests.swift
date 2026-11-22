import XCTest
@testable import EditorCore

final class CppLexerTests: XCTestCase {

    private func kinds(_ text: String) -> [(String, SyntaxToken.Kind)] {
        let ns = text as NSString
        return CppLexer.tokenize(text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testKeywordsAndTypes() {
        let tokens = kinds("int main() { return 0; }")
        XCTAssertTrue(tokens.contains { $0.0 == "int" && $0.1 == .type })
        XCTAssertTrue(tokens.contains { $0.0 == "return" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "main" && $0.1 == .identifier })
        XCTAssertTrue(tokens.contains { $0.0 == "0" && $0.1 == .number })
    }

    func testLineCommentRunsToEndOfLine() {
        let tokens = kinds("int a; // int b;\nint c;")
        let comments = tokens.filter { $0.1 == .comment }
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.0, "// int b;")
    }

    func testBlockCommentSpansLines() {
        let tokens = kinds("/* int\n x */ int y;")
        let comments = tokens.filter { $0.1 == .comment }
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.0, "/* int\n x */")
    }

    func testUnterminatedBlockCommentRunsToEnd() {
        let tokens = kinds("int a; /* unterminated")
        let comments = tokens.filter { $0.1 == .comment }
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.0, "/* unterminated")
    }

    func testStringEscapesAreNotTerminatedEarly() {
        let tokens = kinds(#"std::string s = "a\"b";"#)
        let strings = tokens.filter { $0.1 == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings.first?.0, #""a\"b""#)
    }

    func testRawStringLiteral() {
        let source = #"auto s = R"delim(he said "hi")delim";"#
        let tokens = kinds(source)
        let strings = tokens.filter { $0.1 == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings.first?.0, #"R"delim(he said "hi")delim""#)
    }

    func testCharacterLiteral() {
        let tokens = kinds("char c = '\\n';")
        XCTAssertTrue(tokens.contains { $0.0 == "'\\n'" && $0.1 == .character })
    }

    func testPreprocessorLine() {
        let tokens = kinds("#include <iostream>\nint x;")
        let preprocessor = tokens.filter { $0.1 == .preprocessor }
        XCTAssertEqual(preprocessor.count, 1)
        XCTAssertEqual(preprocessor.first?.0, "#include <iostream>")
    }

    func testDigitSeparatorsAndSuffixes() {
        let tokens = kinds("auto x = 1'000ull;")
        XCTAssertTrue(tokens.contains { $0.0 == "1'000ull" && $0.1 == .number })
    }

    func testRangesAreUTF16Offsets() {
        // An emoji is 2 UTF-16 units; the token after it must still line up with
        // NSString indices used by NSTextStorage.
        let source = "// 😀\nint x;"
        let tokens = CppLexer.tokenize(source)
        let ns = source as NSString
        for token in tokens {
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), ns.length)
        }
        guard let intToken = tokens.first(where: { ns.substring(with: $0.range) == "int" }) else {
            return XCTFail("int token missing")
        }
        XCTAssertEqual(ns.substring(with: intToken.range), "int")
    }

    func testCJKIdentifiersDoNotCrash() {
        let tokens = kinds("int 变量 = 1; // 注释")
        XCTAssertTrue(tokens.contains { $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.1 == .type })
    }

    func testInsideLiteralDetection() {
        let source = #"std::string s = "a(b"; // ("#
        let tokens = CppLexer.tokenize(source)
        let insideString = source.distance(from: source.startIndex, to: source.firstIndex(of: "(")!)
        XCTAssertTrue(CppLexer.isInsideLiteralOrComment(tokens, at: insideString))
        let code = source.distance(from: source.startIndex, to: source.firstIndex(of: "d")!)
        XCTAssertFalse(CppLexer.isInsideLiteralOrComment(tokens, at: code))
    }

    func testEmptyInput() {
        XCTAssertTrue(CppLexer.tokenize("").isEmpty)
    }

    func testUnicodeScalarViewOffsetsMatchTokenText() {
        let source = "int 😀x = 3;"
        let ns = source as NSString
        for token in CppLexer.tokenize(source) {
            XCTAssertTrue(NSMaxRange(token.range) <= ns.length)
        }
    }
}
