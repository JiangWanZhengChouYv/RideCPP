import XCTest
import AppKit
@testable import EditorCore

/// Pixel-level checks for the line-number gutter.
///
/// These exist because the two failure modes here are visual, not logical: a
/// gutter offset by the text-container inset still "works" in code, and a stray
/// separator drawn during an intermediate layout pass only shows up as pixels
/// outside the editor. Rendering the editor and measuring ink rows catches both.
@MainActor
final class LineNumberRulerTests: XCTestCase {

    private func makeEngine(fontSize: CGFloat, lines: Int) -> EditorEngine {
        let engine = EditorEngine(settings: EditSettings(), fontSize: fontSize, showLineNumbers: true)
        let text = (1...lines).map { "int line\($0) = \($0);" }.joined(separator: "\n")
        engine.load(text: text, undoManager: UndoManager())
        return engine
    }

    /// Renders the editor into an offscreen window and returns the bitmap.
    private func render(_ engine: EditorEngine, size: NSSize = NSSize(width: 640, height: 420)) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = engine.scrollView
        engine.scrollView.frame = NSRect(origin: .zero, size: size)
        window.displayIfNeeded()
        engine.scrollView.layoutSubtreeIfNeeded()
        guard let rep = engine.scrollView.bitmapImageRepForCachingDisplay(in: engine.scrollView.bounds) else {
            return nil
        }
        engine.scrollView.cacheDisplay(in: engine.scrollView.bounds, to: rep)
        return rep
    }

    /// Vertical centre of the ink inside `xRange` for the rows in `yRange`.
    private func inkCenter(in rep: NSBitmapImageRep,
                           xRange: ClosedRange<Int>,
                           yRange: ClosedRange<Int>,
                           background: Int) -> Double? {
        var weighted = 0.0
        var count = 0.0
        for y in yRange {
            var rowInk = 0
            for x in xRange {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = Int((color.redComponent * 255).rounded())
                let g = Int((color.greenComponent * 255).rounded())
                let b = Int((color.blueComponent * 255).rounded())
                // Ink is anything clearly different from the flat background.
                if abs(r - background) + abs(g - background) + abs(b - background) > 60 {
                    rowInk += 1
                }
            }
            if rowInk > 0 {
                weighted += Double(y) * Double(rowInk)
                count += Double(rowInk)
            }
        }
        return count > 0 ? weighted / count : nil
    }

    func testLineNumbersAlignWithTextAtLargeFont() throws {
        let fontSize: CGFloat = 22
        let engines = makeEngine(fontSize: fontSize, lines: 6)
        guard let textView = engines.textView as CodeTextView?,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let rep = render(engines) else {
            return XCTFail("could not render the editor")
        }
        layoutManager.ensureLayout(for: container)

        let scale = Double(rep.pixelsWide) / Double(engines.scrollView.bounds.width)
        XCTAssertGreaterThan(scale, 0)
        let background = 26  // the dark-theme editor background
        let gutterX = 4...Int(30 * scale)
        let textX = Int(44 * scale)...Int(180 * scale)

        let nsText = textView.string as NSString
        for line in 1...5 {
            let offset = try XCTUnwrap(TextCoordinates.utf16Offset(ofLine: line, in: textView.string))
            let glyph = layoutManager.glyphIndexForCharacter(at: offset)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Fragment rect is in container space; add the container origin to get
            // the text view's coordinates, then convert to the ruler for the rows.
            let fragmentTop = Int(((textView.textContainerOrigin.y + fragment.minY) * scale).rounded())
            let fragmentBottom = Int(((textView.textContainerOrigin.y + fragment.maxY) * scale).rounded())
            let band = max(0, fragmentTop - 4)...min(rep.pixelsHigh - 1, fragmentBottom + 4)

            let gutterCentre = try XCTUnwrap(inkCenter(in: rep, xRange: gutterX, yRange: band, background: background),
                                             "no line number ink for line \(line)")
            let textCentre = try XCTUnwrap(inkCenter(in: rep, xRange: textX, yRange: band, background: background),
                                           "no code ink for line \(line)")
            XCTAssertEqual(gutterCentre, textCentre, accuracy: 3.0 * scale,
                           "line \(line) number is not aligned with its code line (font \(fontSize))")
            _ = nsText
        }
    }

    func testGutterDoesNotPaintOutsideTheEditor() throws {
        let engines = makeEngine(fontSize: 13, lines: 6)
        guard let rep = render(engines) else { return XCTFail("could not render") }
        // Rows just above the editor belong to the tab strip in the real window;
        // here they must simply stay free of gutter ink (no separator, no numbers).
        let gutterX = 0...Int(36 * (Double(rep.pixelsWide) / Double(engines.scrollView.bounds.width)))
        for y in 0..<2 {
            for x in gutterX {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = Int(((color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255).rounded())
                XCTAssertLessThan(luminance, 80, "bright pixel at top-left corner (\(x), \(y))")
            }
        }
    }

    func testRulerThicknessGrowsWithLineCount() {
        let engine = EditorEngine(settings: EditSettings(), fontSize: 13, showLineNumbers: true)
        let shortText = (1...9).map { "int value\($0);" }.joined(separator: "\n")
        engine.load(text: shortText, undoManager: UndoManager())
        let short = engine.ruler.ruleThickness

        let longText = (1...12345).map { "int value\($0);" }.joined(separator: "\n")
        engine.load(text: longText, undoManager: UndoManager())
        let long = engine.ruler.ruleThickness

        XCTAssertGreaterThanOrEqual(short, 38)
        XCTAssertGreaterThan(long, short, "five-digit line numbers need a wider gutter")
    }
}
