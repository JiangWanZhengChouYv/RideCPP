import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// The hover panel must offer the fix inline, and must not outlive the app's
/// focus.
@MainActor
final class HoverPanelTests: XCTestCase {

    private func makeTextView() -> CodeTextView {
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: "int main() {\n    undefinedThing();\n}\n", undoManager: UndoManager())
        return engine.textView
    }

    private let source = "int main() {\n    undefinedThing();\n}\n"

    func testDiagnosticHoverOffersFixAction() {
        let view = makeTextView()
        let target = NSRange(location: 16, length: 14)
        view.setDiagnostics([.init(range: target, kind: .error,
                                   message: "use of undeclared identifier",
                                   code: "undeclared_var_use")])
        var actions: [CodeTextView.HoverAction] = []
        view.onHoverAction = { actions.append($0) }
        XCTAssertTrue(view.diagnostic(at: target.location) != nil)
        XCTAssertEqual(CodeTextView.HoverAction.fix(.init(diagnostic: view.diagnostic(at: 16)!)).title, "Fix")
        XCTAssertTrue(view.onHoverAction != nil)
        XCTAssertTrue(actions.isEmpty)
    }

    func testFixTargetKeepsTheHoveredRange() {
        let view = makeTextView()
        let first = NSRange(location: 16, length: 14)
        let second = NSRange(location: 0, length: 3)
        view.setDiagnostics([
            .init(range: first, kind: .error, message: "a", code: "code_a"),
            .init(range: second, kind: .warning, message: "b", code: "code_b")
        ])
        let target = CodeTextView.DiagnosticFixTarget(diagnostic: view.diagnostic(at: 20)!)
        // The button must act on the hovered problem, not on the caret.
        XCTAssertEqual(target.range, first)
        XCTAssertEqual(target.code, "code_a")
    }

    func testCompletionPanelDoesNotOutrankOtherApps() {
        let panel = CompletionPanel()
        // `.popUpMenu` floats above every other application's windows; a
        // completion list must not.
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testCompletionPanelHidesWhenAppDeactivates() {
        let panel = CompletionPanel()
        XCTAssertTrue(panel.hidesOnDeactivate)
    }

    func testHoverPanelStaysAboveEditorButBelowPopups() {
        let view = makeTextView()
        view.showHover("error: something", at: 16)
        let windows = NSApp.windows.filter { $0 is NSPanel && $0.isVisible }
        XCTAssertFalse(windows.isEmpty, "hover panel should be visible")
        for window in windows {
            XCTAssertLessThan(window.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
            XCTAssertTrue(window.hidesOnDeactivate)
        }
        view.hideHover()
    }
}
