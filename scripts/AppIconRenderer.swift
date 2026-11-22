import AppKit

/// Renders the RideCPP app icon at every size macOS asks for.
///
/// The mark: a rounded-square "squircle" in the app's accent gradient, carrying a
/// code bracket pair and a terminal prompt — the two halves of the product (a
/// C++ editor that runs your program and talks back).
enum AppIconRenderer {

    static func render(size: Int) -> NSImage {
        let side = CGFloat(size)
        // Draw straight into a bitmap of exactly `size` pixels: `lockFocus` would
        // follow the screen's backing scale and produce 2x images, which the
        // asset catalog rejects.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: size,
                                         pixelsHigh: size,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return NSImage(size: NSSize(width: side, height: side))
        }
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let context = graphics.cgContext
        let inset = side * 0.085
        let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = rect.width * 0.225

        // Subtle drop shadow, like a macOS app icon.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                          blur: side * 0.03,
                          color: NSColor.black.withAlphaComponent(0.28).cgColor)
        let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        squircle.fill()
        context.restoreGState()

        // Gradient background: deep indigo to teal, the colors of the editor theme.
        context.saveGState()
        squircle.addClip()
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.20, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.09, green: 0.42, blue: 0.52, alpha: 1)
        ])
        gradient?.draw(in: rect, angle: -70)

        // A soft highlight in the upper-left, for depth.
        let highlight = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.20),
            NSColor.white.withAlphaComponent(0.0)
        ])
        highlight?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
        context.restoreGState()

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let strokeWidth = max(1.2, side * 0.036)

        // Layout is a clean left-to-right row with real gaps, so nothing overlaps:
        //   <   ▮   >
        // The two angle brackets are the code; the accent block between them is a
        // terminal cursor, for "your program runs here".
        let bracketHeight = rect.height * 0.34
        let bracketWidth = bracketHeight * 0.46
        let centreGap = bracketWidth * 1.55          // half-gap from centre to each bracket tip
        let codeColor = NSColor(srgbRed: 0.94, green: 0.97, blue: 1.0, alpha: 1)
        let accent = NSColor(srgbRed: 0.36, green: 0.90, blue: 0.70, alpha: 1)

        func drawChevron(tipX: CGFloat, openingToRight: Bool) {
            let path = NSBezierPath()
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // The tips ("<" and ">") sit at the outer edges, backs face the centre.
            let backX = openingToRight ? tipX - bracketWidth : tipX + bracketWidth
            let halfHeight = bracketHeight / 2
            path.move(to: NSPoint(x: backX, y: center.y + halfHeight))
            path.line(to: NSPoint(x: tipX, y: center.y))
            path.line(to: NSPoint(x: backX, y: center.y - halfHeight))
            path.stroke()
        }

        codeColor.setStroke()
        // Left bracket "<": opens to the right, tip on the left.
        drawChevron(tipX: center.x - centreGap, openingToRight: false)
        // Right bracket ">": opens to the left, tip on the right.
        drawChevron(tipX: center.x + centreGap, openingToRight: true)

        // Cursor block in the middle, clear of both brackets.
        let cursorHeight = bracketHeight * 0.34
        let cursorWidth = strokeWidth * 1.15
        let cursorRect = NSRect(x: center.x - cursorWidth / 2,
                                y: center.y - cursorHeight / 2,
                                width: cursorWidth,
                                height: cursorHeight)
        accent.setFill()
        NSBezierPath(roundedRect: cursorRect,
                     xRadius: cursorWidth / 2.6,
                     yRadius: cursorWidth / 2.6).fill()

        // A short accent underline under the whole mark, reading as a baseline.
        let ruleWidth = (centreGap + bracketWidth) * 2
        let ruleRect = NSRect(x: center.x - ruleWidth / 2,
                              y: center.y - bracketHeight * 0.86,
                              width: ruleWidth,
                              height: max(1, side * 0.008))
        accent.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: ruleRect, xRadius: ruleRect.height / 2, yRadius: ruleRect.height / 2).fill()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    static func pngData(size: Int) -> Data? {
        let image = render(size: size)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        rep.size = NSSize(width: size, height: size)
        return rep.representation(using: .png, properties: [:])
    }
}
