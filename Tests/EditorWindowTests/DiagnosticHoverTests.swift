import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// The hover path: a squiggle must explain itself.
///
/// These do not drive the mouse — they assert the model the mouse handler reads,
/// which is where the bugs live (wrong range, missing code, wrong severity).
@MainActor
final class DiagnosticHoverTests: XCTestCase {

    private func makeTextView(_ text: String) -> CodeTextView {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: text, undoManager: UndoManager())
        return engine.textView
    }

    private let source = "int main() {\n    undefinedThing();\n    return 0;\n}\n"

    private func diagnostics() -> [CodeTextView.InlineDiagnostic] {
        // "undefinedThing" starts at offset 16 on the second line.
        [.init(range: NSRange(location: 16, length: 14), kind: .error,
               message: "use of undeclared identifier 'undefinedThing'",
               code: "undeclared_var_use")]
    }

    func testHoverTextIncludesSeverityMessageAndCode() {
        let item = CodeTextView.InlineDiagnostic(range: NSRange(location: 0, length: 1),
                                                 kind: .error,
                                                 message: "no member named 'x'",
                                                 code: "no_member")
        XCTAssertTrue(item.hoverText.contains("error"))
        XCTAssertTrue(item.hoverText.contains("no member named 'x'"))
        XCTAssertTrue(item.hoverText.contains("no_member"))
    }

    func testWarningHoverTextSaysWarning() {
        let item = CodeTextView.InlineDiagnostic(range: NSRange(location: 0, length: 1),
                                                 kind: .warning,
                                                 message: "unused variable 'x'",
                                                 code: "unused-variable")
        XCTAssertTrue(item.hoverText.hasPrefix("warning:"), item.hoverText)
    }

    func testHoverTextWithoutCodeStillReadable() {
        let item = CodeTextView.InlineDiagnostic(range: NSRange(location: 0, length: 1),
                                                 kind: .error, message: "something broke")
        XCTAssertEqual(item.hoverText, "error: something broke")
        XCTAssertFalse(item.hoverText.contains("[]"))
    }

    func testDiagnosticIsFoundEverywhereInsideItsRange() {
        let view = makeTextView(source)
        view.setDiagnostics(diagnostics())
        for offset in 16..<30 {
            XCTAssertNotNil(view.diagnostic(at: offset), "offset \(offset) should hit the squiggle")
        }
        XCTAssertNil(view.diagnostic(at: 15), "the character before must not hit")
        XCTAssertNil(view.diagnostic(at: 31), "the character after must not hit")
    }

    func testDiagnosticLookupSurvivesNonASCIIPrefix() {
        // A multi-byte character shifts UTF-16 offsets; the range must still be
        // computed in the same units the server used.
        let text = "// 中文注释\nundefinedThing();\n"
        let view = makeTextView(text)
        let ns = text as NSString
        let target = ns.range(of: "undefinedThing")
        XCTAssertNotEqual(target.location, NSNotFound)
        view.setDiagnostics([.init(range: target, kind: .error,
                                   message: "use of undeclared identifier", code: nil)])
        XCTAssertNotNil(view.diagnostic(at: target.location))
        XCTAssertNotNil(view.diagnostic(at: target.location + target.length - 1))
    }

    func testClearingDiagnosticsRemovesThem() {
        let view = makeTextView(source)
        view.setDiagnostics(diagnostics())
        XCTAssertNotNil(view.diagnostic(at: 16))
        view.setDiagnostics([])
        XCTAssertNil(view.diagnostic(at: 16))
    }

    func testDiagnosticsDoNotEnterTheUndoStack() {
        let engine = EditorEngine(settings: EditSettings())
        let undo = UndoManager()
        engine.load(text: source, undoManager: undo)
        let before = undo.canUndo
        engine.textView.setDiagnostics(diagnostics())
        XCTAssertEqual(undo.canUndo, before, "underlining must not be undoable")
    }
}
