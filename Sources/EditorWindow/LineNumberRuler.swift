import AppKit
import EditorCore

/// Line-number gutter drawn as an `NSRulerView` next to the text view.
///
/// Positions come from the layout manager and are converted from the text view's
/// own coordinate space, including `textContainerOrigin`, and numbers are drawn
/// on each line's *baseline*. That is what keeps them aligned at any font size:
/// centering a label box inside the fragment drifts as the font grows.
public final class LineNumberRuler: NSRulerView {

    /// Line numbers that should be drawn in the "active" color.
    public var highlightedLines: Set<Int> = []
    /// 1-based lines holding an error, marked in the gutter.
    public var errorLines: Set<Int> = []
    /// 1-based lines holding a warning, marked in the gutter.
    public var warningLines: Set<Int> = []

    private static let minimumThickness: CGFloat = 38
    private static let horizontalPadding: CGFloat = 6

    public init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.minimumThickness
        if let clipView = scrollView.contentView as NSClipView? {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(scrollViewDidScroll(_:)),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: clipView)
        }
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        needsDisplay = true
    }

    /// Recomputes the width needed for the current document's largest line number.
    public func refreshThickness() {
        guard let textView = clientView as? NSTextView else { return }
        let lineCount = TextCoordinates.lineCount(in: textView.string)
        let digits = max(2, String(lineCount).count)
        let font = numberFont(for: textView)
        let sampleWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let desired = max(Self.minimumThickness, CGFloat(digits) * sampleWidth + Self.horizontalPadding * 2)
        if abs(ruleThickness - desired) > 0.5 {
            ruleThickness = desired
        }
        needsDisplay = true
    }

    private func numberFont(for textView: NSTextView) -> NSFont {
        EditorTheme.lineNumberFont(size: textView.font?.pointSize ?? 13)
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.lineNumberBackground.setFill()
        bounds.fill()

        // Separator against the text area. Drawn only for the gutter's own
        // height, which is the editor's height.
        EditorTheme.lineNumberSeparator.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let nsText = textView.string as NSString
        let font = numberFont(for: textView)
        let color = NSColor.labelColor
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        // The text container's origin inside the text view: text is laid out
        // starting here, so fragment coordinates must be shifted by it.
        let containerOrigin = textView.textContainerOrigin

        guard nsText.length > 0 else {
            drawNumber(1,
                       baselineInTextView: containerOrigin.y + font.ascender,
                       textView: textView,
                       font: font,
                       attributes: baseAttributes)
            return
        }

        // First and last character of the visible range, with a little margin so
        // partially visible lines are still numbered.
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let visibleStart = max(0, charRange.location)
        let visibleEnd = min(nsText.length, NSMaxRange(charRange))

        // Count lines before the visible range so numbering starts correctly.
        var lineNumber = 1
        var cursor = 0
        while cursor < visibleStart {
            let range = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(range)
            if next <= cursor { break }
            cursor = next
            lineNumber += 1
        }

        let activeLine = currentLine(in: textView)
        var index = visibleStart
        while index < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            // `location(forGlyphAt:)` is the glyph's baseline origin inside the
            // fragment; adding the fragment and the container origin gives the
            // baseline in the text view's coordinates.
            let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
            let baselineInTextView = containerOrigin.y + fragment.minY + glyphLocation.y
            let baselineY = convert(NSPoint(x: 0, y: baselineInTextView), from: textView).y

            let isActive = highlightedLines.contains(lineNumber) || lineNumber == activeLine
            var attributes = baseAttributes
            attributes[.foregroundColor] = isActive
                ? EditorTheme.lineNumberActiveText
                : EditorTheme.lineNumberText

            if baselineY < bounds.minY - font.pointSize * 1.5 {
                // Above the visible area; keep walking.
            } else if baselineY > bounds.maxY + font.pointSize * 1.5 {
                break
            } else {
                drawNumber(lineNumber, baseline: baselineY, font: font, attributes: attributes)
            }

            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
            lineNumber += 1
            if index > visibleEnd { break }
        }
    }

    /// Draws a right-aligned number whose baseline sits at `baseline`.
    private func drawNumber(_ number: Int,
                            baseline: CGFloat,
                            font: NSFont,
                            attributes: [NSAttributedString.Key: Any]) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        let x = bounds.width - size.width - Self.horizontalPadding
        label.draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: attributes)
    }

    private func drawNumber(_ number: Int,
                            baselineInTextView: CGFloat,
                            textView: NSTextView,
                            font: NSFont,
                            attributes: [NSAttributedString.Key: Any]) {
        let baselineY = convert(NSPoint(x: 0, y: baselineInTextView), from: textView).y
        drawNumber(number, baseline: baselineY, font: font, attributes: attributes)
        drawMarker(forLine: number, baseline: baselineY, font: font)
    }

    /// Draws the error/warning badge at the gutter's leading edge.
    ///
    /// An error is a filled disc, a warning a triangle — distinguishable by shape
    /// alone, so it still reads for colour-blind users and in grayscale.
    private func drawMarker(forLine line: Int, baseline: CGFloat, font: NSFont) {
        let isError = errorLines.contains(line)
        let isWarning = !isError && warningLines.contains(line)
        guard isError || isWarning else { return }
        // Sized against the font so it stays proportional to the text, and clearly
        // bigger than a bullet: the badge has to be findable while scanning a page.
        let side = max(9, font.pointSize * 0.78)
        let centerY = baseline - font.ascender / 2 - font.descender / 2
        let x = Self.horizontalPadding - 2
        if isError {
            let rect = NSRect(x: x, y: centerY - side / 2, width: side, height: side)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x + side / 2, y: centerY + side / 2))
            path.line(to: NSPoint(x: x, y: centerY - side / 2))
            path.line(to: NSPoint(x: x + side, y: centerY - side / 2))
            path.close()
            NSColor.systemOrange.setFill()
            path.fill()
        }
    }

    private func currentLine(in textView: NSTextView) -> Int {
        let nsText = textView.string as NSString
        if nsText.length == 0 { return 1 }
        let location = min(textView.selectedRange().location, nsText.length)
        var line = 1
        var cursor = 0
        while cursor < location {
            let range = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(range)
            if next <= cursor { break }
            cursor = next
            line += 1
        }
        return line
    }
}
