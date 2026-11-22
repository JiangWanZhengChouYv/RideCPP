import XCTest
@testable import EditorCore

final class TextCoordinatesTests: XCTestCase {

    func testLineStartOffsets() {
        let text = "a\nbb\nccc"
        XCTAssertEqual(TextCoordinates.utf16Offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(TextCoordinates.utf16Offset(ofLine: 2, in: text), 2)
        XCTAssertEqual(TextCoordinates.utf16Offset(ofLine: 3, in: text), 5)
        XCTAssertNil(TextCoordinates.utf16Offset(ofLine: 9, in: text))
        XCTAssertNil(TextCoordinates.utf16Offset(ofLine: 0, in: text))
    }

    func testColumnLookup() {
        let text = "abc\ndef"
        XCTAssertEqual(TextCoordinates.utf16Offset(line: 2, column: 1, in: text), 4)
        XCTAssertEqual(TextCoordinates.utf16Offset(line: 2, column: 3, in: text), 6)
        // Clamped to end of line, not past the newline.
        XCTAssertEqual(TextCoordinates.utf16Offset(line: 2, column: 99, in: text), 7)
    }

    func testLineAndColumnRoundTrip() {
        let text = "one\ntwo\nthree"
        for line in 1...3 {
            for column in 1...3 {
                guard let offset = TextCoordinates.utf16Offset(line: line, column: column, in: text),
                      let result = TextCoordinates.lineAndColumn(at: offset, in: text) else {
                    return XCTFail("round trip failed for \(line):\(column)")
                }
                XCTAssertEqual(result.line, line)
                XCTAssertEqual(result.column, column)
            }
        }
    }

    func testUtf16OffsetsWithEmoji() {
        let text = "// 😀\nint x;"
        // The emoji is two UTF-16 units, so line 2 starts at offset 6.
        XCTAssertEqual(TextCoordinates.utf16Offset(ofLine: 2, in: text), 6)
        let (line, column) = TextCoordinates.lineAndColumn(at: 6, in: text)!
        XCTAssertEqual(line, 2)
        XCTAssertEqual(column, 1)
    }

    func testLineCount() {
        XCTAssertEqual(TextCoordinates.lineCount(in: ""), 1)
        XCTAssertEqual(TextCoordinates.lineCount(in: "a"), 1)
        XCTAssertEqual(TextCoordinates.lineCount(in: "a\nb"), 2)
        // A trailing newline does not create an extra visible line.
        XCTAssertEqual(TextCoordinates.lineCount(in: "a\nb\n"), 2)
    }

    func testLineText() {
        let text = "first\nsecond\n"
        XCTAssertEqual(TextCoordinates.line(1, in: text), "first")
        XCTAssertEqual(TextCoordinates.line(2, in: text), "second")
    }

    func testLineEndingsNormalization() {
        XCTAssertEqual(TextCoordinates.normalizeLineEndings("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(TextCoordinates.normalizeLineEndings("plain"), "plain")
    }

    func testEmptyDocumentPositions() {
        XCTAssertEqual(TextCoordinates.utf16Offset(ofLine: 1, in: ""), 0)
        XCTAssertNil(TextCoordinates.utf16Offset(ofLine: 2, in: ""))
        XCTAssertEqual(TextCoordinates.lineAndColumn(at: 0, in: "")?.line, 1)
    }
}
