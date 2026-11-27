import XCTest
import AppKit
import EditorCore
@testable import EditorWindow

/// The hover panel: only problems get one, the button is localized, and the
/// panel survives the pointer travelling onto it.
@MainActor
final class HoverPanelTests: XCTestCase {

    private let source = """
    struct Point { int x; int y; };

    int main() {
        Point p;
        p.notAMember();
        int ok = 1;
        return ok;
    }
    """

    /// Panels that exist because of *this* test, ignoring any left by another one:
    /// AppKit keeps closed windows in `NSApp.windows` for a while.
    private var baselinePanels: Set<ObjectIdentifier> = []

    private func makeWindow() -> (EditorEngine, NSWindow) {
        baselinePanels = Set(NSApp.windows.compactMap { $0 as? NSPanel }.map(ObjectIdentifier.init))
        let engine = EditorEngine(settings: EditSettings())
        engine.load(text: source, undoManager: UndoManager())
        engine.highlighter.highlightNow()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = engine.textView
        engine.textView.frame = NSRect(x: 0, y: 0, width: 700, height: 320)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (engine, window)
    }

    /// Drives the real `mouseMoved` with an event aimed at a character.
    private func hover(_ index: Int, in engine: EditorEngine, window: NSWindow) {
        let screen = engine.textView.firstRect(forCharacterRange: NSRange(location: index, length: 1),
                                               actualRange: nil)
        let inWindow = window.convertFromScreen(screen)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved,
                                             location: NSPoint(x: inWindow.midX, y: inWindow.midY),
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        engine.textView.mouseMoved(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private var visiblePanels: [NSPanel] {
        NSApp.windows.compactMap { $0 as? NSPanel }
            .filter { $0.isVisible && !baselinePanels.contains(ObjectIdentifier($0)) }
    }

    private func buttonTitle() -> String? {
        guard let view = visiblePanels.first?.contentView else { return nil }
        var found: String?
        func walk(_ v: NSView) {
            if let b = v as? NSButton { found = b.title }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private func errorRange() -> NSRange {
        (source as NSString).range(of: "notAMember")
    }

    func testCorrectCodeShowsNoPanel() {
        let (engine, window) = makeWindow()
        let ok = (source as NSString).range(of: "ok = 1")
        hover(ok.location, in: engine, window: window)
        XCTAssertTrue(visiblePanels.isEmpty,
                      "hovering ordinary code must not open a panel")
        engine.textView.hideHover()
    }

    func testErrorShowsPanel() {
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error,
                                              message: "No member named 'notAMember'",
                                              code: "no_member")])
        hover(range.location, in: engine, window: window)
        XCTAssertEqual(visiblePanels.count, 1)
        engine.textView.hideHover()
    }

    func testFixButtonUsesTheAppLocalizedTitle() {
        CodeTextView.setHoverActionTitle("修复", for: "fix")
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        hover(range.location, in: engine, window: window)
        XCTAssertEqual(buttonTitle(), "修复", "the button must follow the UI language")
        engine.textView.hideHover()
    }

    func testPanelStaysWhilePointerIsOnIt() {
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        hover(range.location, in: engine, window: window)
        XCTAssertEqual(visiblePanels.count, 1)
        // Entering the panel must latch it: the pointer is on its way to the
        // button, and any replacement would pull the button away.
        engine.textView.isPointerOnHoverPanel = true
        let someOtherIndex = (source as NSString).range(of: "return").location
        hover(someOtherIndex, in: engine, window: window)
        XCTAssertEqual(visiblePanels.count, 1, "panel must survive the pointer moving onto it")
        engine.textView.isPointerOnHoverPanel = false
        engine.textView.hideHover()
    }

    func testMovingOffTheErrorClosesThePanel() {
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        hover(range.location, in: engine, window: window)
        XCTAssertEqual(visiblePanels.count, 1)
        let ok = (source as NSString).range(of: "ok = 1")
        hover(ok.location, in: engine, window: window)
        XCTAssertTrue(visiblePanels.isEmpty, "leaving the problem must close the panel")
    }

    func testCompletionPanelDoesNotOutrankOtherApps() {
        let panel = CompletionPanel()
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testCompletionPanelHidesWhenAppDeactivates() {
        XCTAssertTrue(CompletionPanel().hidesOnDeactivate)
    }

    /// Reaching the button is a fast gesture. At 100 Hz the pointer jumps several
    /// points per frame, so it can clip the panel's edge on the way; a dismissal
    /// on that first exit makes the button effectively unhittable.
    func testPanelSurvivesAPointerThatGrazesItsEdge() {
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        hover(range.location, in: engine, window: window)
        XCTAssertEqual(visiblePanels.count, 1)

        // Pointer left the panel a moment ago and has not arrived back yet.
        engine.textView.scheduleHoverClose()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(visiblePanels.count, 1, "a brief exit must not dismiss the panel at once")

        // It lands on the panel before the grace period runs out.
        engine.textView.isPointerOnHoverPanel = true
        engine.textView.cancelHoverClose()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(visiblePanels.count, 1, "landing on the panel must keep it open")

        engine.textView.isPointerOnHoverPanel = false
        engine.textView.hideHover()
    }

    /// There must be no dead strip between the code and the panel: the pointer
    /// crossing it belongs to neither, and the panel would close mid-journey.
    func testNoGapBetweenLineAndPanel() {
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        hover(range.location, in: engine, window: window)
        guard let panel = visiblePanels.first else {
            return XCTFail("expected a panel")
        }
        let lineBottom = engine.textView.firstRect(forCharacterRange: range, actualRange: nil).minY
        XCTAssertEqual(lineBottom, panel.frame.maxY, accuracy: 1.5,
                       "the panel must butt against the line, not float below it")
        engine.textView.hideHover()
    }

    func testLeavingForGoodEventuallyCloses() {
        let (engine, window) = makeWindow()
        let range = errorRange()
        engine.textView.setDiagnostics([.init(range: range, kind: .error, message: "m", code: "c")])
        hover(range.location, in: engine, window: window)
        XCTAssertEqual(visiblePanels.count, 1)
        engine.textView.isPointerOnHoverPanel = false
        engine.textView.scheduleHoverClose()
        // Well past the grace period, with the pointer nowhere near a problem.
        RunLoop.current.run(until: Date().addingTimeInterval(CodeTextView.hoverCloseGrace + 0.4))
        XCTAssertTrue(visiblePanels.isEmpty, "the panel must not linger forever")
    }
}
