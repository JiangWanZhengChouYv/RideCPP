import AppKit

/// Contents of the hover hint: the message, plus a fix button when clangd has
/// one to offer.
///
/// Written as a view rather than a plain text field because the message alone
/// left "fix this" reachable only through a menu shortcut, which nobody would
/// find while already pointing at the problem.
final class HoverContentView: HoverTrackingView {

    var onAction: (() -> Void)?

    private let label: NSTextField
    private let button: NSButton?
    private let width: CGFloat
    private let padding: CGFloat = 8
    private let spacing: CGFloat = 8
    /// Deliberately generous: the button has to be hit by a pointer travelling
    /// from the code above it, and a 20 pt target is a coin toss on a fast trackpad.
    private let buttonHeight: CGFloat = 24

    init(text: String, width: CGFloat, actionTitle: String?) {
        self.width = width
        label = NSTextField(wrappingLabelWithString: text)
        button = actionTitle.map { NSButton(title: $0, target: nil, action: nil) }
        super.init(frame: .zero)

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width - padding * 2
        addSubview(label)

        if let button {
            // A bordered control reads as clickable; a link style would be easy to
            // miss against code.
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = #selector(fixTapped)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fixTapped() {
        onAction?()
    }

    /// Height that fits the message and, when present, the button row.
    var fittingHeight: CGFloat {
        let textHeight = label.sizeThatFits(NSSize(width: width - padding * 2, height: 10_000)).height
        let row = button == nil ? 0 : buttonHeight + spacing - 2
        return ceil(max(24, textHeight + padding * 2 + row))
    }

    override func layout() {
        super.layout()
        let innerWidth = width - padding * 2
        let textHeight = label.sizeThatFits(NSSize(width: innerWidth, height: 10_000)).height
        // AppKit's origin is bottom-left, so the button sits at the bottom and the
        // message above it.
        var textBottom = padding
        if let button {
            let buttonWidth = min(innerWidth, max(72, button.intrinsicContentSize.width + 16))
            button.frame = NSRect(x: padding, y: padding, width: buttonWidth, height: buttonHeight)
            textBottom = padding + buttonHeight + spacing - 2
        }
        label.frame = NSRect(x: padding, y: textBottom, width: innerWidth, height: textHeight)
    }
}

/// Hover panel that reports when the pointer is inside it.
///
/// The message is not the only thing to click any more: a pointer travelling to
/// the fix button leaves the diagnostic's range, which would otherwise replace
/// the panel out from under the button.
final class HoverPanel: NSPanel {
    /// Called when the pointer enters or leaves the panel.
    var onPointerInside: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

}

/// Reports pointer entry and exit for the hover panel's window.
///
/// Tracking areas belong to views, not windows, so this sits on the content view
/// and forwards the two events the panel cares about.
class HoverTrackingView: NSView {
    var onPointerInside: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerInside?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerInside?(false)
    }
}
