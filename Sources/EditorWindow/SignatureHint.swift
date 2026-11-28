import AppKit
import EditorCore

// MARK: - Signature hint

/// Shows a call's parameters just below the caret, with the argument being
/// typed emphasised.
///
/// A separate panel from the hover hint: both can be on screen at once (hovering
/// a diagnostic while inside a call), and they anchor differently.
extension CodeTextView {

    /// Shows the parameter hint, or hides it when there is nothing to show.
    public func showSignatureHint(_ signature: LSPSignature?, activeParameter: Int) {
        guard let signature else {
            hideSignatureHint()
            return
        }
        guard let anchor = caretRectInView(), let window else { return }
        let content = SignatureHintView(signature: signature, activeParameter: activeParameter)
        let size = content.fittingSize()
        let panel: NSPanel
        if let existing = signatureHintPanel {
            panel = existing
            panel.contentView = content
        } else {
            panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // Below other apps, like the other hints: a signature is a local aid,
            // not something that should float over the user's browser.
            panel.level = .floating
            panel.hasShadow = true
            panel.backgroundColor = .windowBackgroundColor
            panel.isOpaque = true
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.contentView = content
            signatureHintPanel = panel
        }
        panel.setContentSize(size)
        // Anchor under the line the caret is on, clamped to the window.
        let screenRect = window.convertToScreen(convert(anchor, to: nil))
        var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - size.height - 2)
        if let screen = window.screen {
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 4)
            if origin.y < screen.visibleFrame.minY + 4 {
                origin.y = screenRect.maxY + 2
            }
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    /// Closes the parameter hint.
    public func hideSignatureHint() {
        signatureHintPanel?.orderOut(nil)
        signatureHintPanel = nil
    }

    public var isSignatureHintVisible: Bool { signatureHintPanel?.isVisible ?? false }
}

/// Draws one signature, emphasising the active parameter.
///
/// Drawn by hand rather than with an `NSAttributedString` in a label because the
/// active parameter is a range inside the label that needs its own background —
/// which is the whole point of the hint.
final class SignatureHintView: NSView {

    private let signature: LSPSignature
    private let activeParameter: Int
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 8

    init(signature: LSPSignature, activeParameter: Int) {
        self.signature = signature
        self.activeParameter = activeParameter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Size needed for the label at this font.
    func fittingSize() -> NSSize {
        let size = (signature.label as NSString).size(withAttributes: [.font: font])
        return NSSize(width: min(900, ceil(size.width) + padding * 2),
                      height: ceil(size.height) + padding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let text = signature.label as NSString
        let textOrigin = NSPoint(x: padding, y: padding)

        // Highlight the active parameter, located inside the full label so a
        // member-function signature stays visually one string.
        if signature.parameters.indices.contains(activeParameter) {
            let parameter = signature.parameters[activeParameter].label
            let range = text.range(of: parameter)
            if range.location != NSNotFound {
                let before = text.substring(to: range.location) as NSString
                let width = before.size(withAttributes: baseAttributes).width
                let parameterWidth = (parameter as NSString).size(withAttributes: baseAttributes).width
                let highlight = NSRect(x: textOrigin.x + width - 1,
                                       y: textOrigin.y - 1,
                                       width: parameterWidth + 2,
                                       height: font.ascender - font.descender + 2)
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 3, yRadius: 3).fill()
            }
        }
        text.draw(at: textOrigin, withAttributes: baseAttributes)

        // A small index readout, so "2 of 3" is visible without counting.
        if signature.parameters.count > 1 {
            let counter = "\(activeParameter + 1)/\(signature.parameters.count)" as NSString
            let counterFont = NSFont.systemFont(ofSize: 9)
            let width = counter.size(withAttributes: [.font: counterFont]).width
            counter.draw(at: NSPoint(x: bounds.maxX - width - padding, y: padding - 2),
                         withAttributes: [.font: counterFont,
                                          .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }
}
