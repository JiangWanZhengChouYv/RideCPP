import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// An error must be obvious at a glance, not just technically underlined.
///
/// These assert the cues the visual design depends on, so a future "tidy up"
/// cannot quietly reduce a red squiggle back to a faint dotted line.
@MainActor
final class DiagnosticVisibilityTests: XCTestCase {

    private let source = """
    struct Point { int x; int y; };

    int main() {
        Point p;
        p.notAMember();
        return 0;
    }
    """

    private func makeEngine() -> EditorEngine {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: source, undoManager: UndoManager())
        engine.highlighter.highlightNow()
        return engine
    }

    private func errorRange() -> NSRange {
        (source as NSString).range(of: "notAMember")
    }

    func testErrorTokenGetsBackgroundAndRedText() {
        let engine = makeEngine()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        guard let layoutManager = engine.textView.layoutManager else {
            return XCTFail("no layout manager")
        }
        // Background marks the token itself.
        let background = layoutManager.temporaryAttribute(.backgroundColor,
                                                          atCharacterIndex: range.location,
                                                          effectiveRange: nil) as? NSColor
        XCTAssertNotNil(background, "an error must tint its token")
        // Text turns red rather than keeping the syntax colour.
        let foreground = layoutManager.temporaryAttribute(.foregroundColor,
                                                          atCharacterIndex: range.location,
                                                          effectiveRange: nil) as? NSColor
        XCTAssertNotNil(foreground)
        guard let color = foreground?.usingColorSpace(.sRGB) else {
            return XCTFail("no sRGB colour")
        }
        XCTAssertGreaterThan(color.redComponent, color.greenComponent,
                             "error text must read as red, got \(color)")
        XCTAssertGreaterThan(color.redComponent, color.blueComponent,
                             "error text must read as red, got \(color)")
    }

    func testRedTextSurvivesRehighlighting() {
        // Syntax highlighting repaints every visible character on each keystroke;
        // it used to wipe the error colour, leaving the tint alone.
        let engine = makeEngine()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        engine.highlighter.highlightNow()
        let foreground = engine.textView.layoutManager?
            .temporaryAttribute(.foregroundColor, atCharacterIndex: range.location,
                                effectiveRange: nil) as? NSColor
        guard let color = foreground?.usingColorSpace(.sRGB) else {
            return XCTFail("error colour lost after re-highlighting")
        }
        XCTAssertGreaterThan(color.redComponent, color.greenComponent,
                             "error colour was overwritten by syntax highlighting")
    }

    func testGutterMarksTheOffendingLine() {
        let engine = makeEngine()
        let range = errorRange()
        // "notAMember" sits on line 5.
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        XCTAssertEqual(engine.ruler.errorLines, [5])
        XCTAssertTrue(engine.ruler.warningLines.isEmpty)

        engine.textView.setDiagnostics([.init(range: range, kind: .warning, message: "m", code: "c")])
        XCTAssertEqual(engine.ruler.warningLines, [5])
        XCTAssertTrue(engine.ruler.errorLines.isEmpty)
    }

    func testClearingRemovesEveryCue() {
        let engine = makeEngine()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        engine.textView.clearErrorMarkers()
        let background = engine.textView.layoutManager?
            .temporaryAttribute(.backgroundColor, atCharacterIndex: range.location,
                                effectiveRange: nil)
        XCTAssertNil(background)
        XCTAssertTrue(engine.ruler.errorLines.isEmpty)
    }

    func testErrorCuesAreNotUsedByPlainCode() {
        let engine = makeEngine()
        let range = (source as NSString).range(of: "return")
        let background = engine.textView.layoutManager?
            .temporaryAttribute(.backgroundColor, atCharacterIndex: range.location,
                                effectiveRange: nil)
        XCTAssertNil(background, "correct code must not be tinted")
        XCTAssertTrue(engine.ruler.errorLines.isEmpty)
    }
}
