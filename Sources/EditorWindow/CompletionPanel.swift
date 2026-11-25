import AppKit
import EditorCore

/// A completion list drawn by us rather than by AppKit.
///
/// `NSTextView.complete(_:)` can only show plain strings, so it cannot grey out
/// placeholder text — which is the whole point here (`if (⟨condition⟩)` must show
/// `condition` greyed and must not insert it). This panel draws each suggestion
/// as code plus grey placeholders and reports the chosen insertion text.
final class CompletionPanel: NSPanel {

    /// Called when the user accepts a suggestion.
    var onAccept: ((CompletionItem) -> Void)?
    /// Called when the list is dismissed without a choice.
    var onCancel: (() -> Void)?

    private var items: [CompletionItem] = []
    private var selectedIndex = 0
    private let rowHeight: CGFloat = 22
    private let width: CGFloat = 360
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        // The editor must keep keyboard focus: the panel is a passive list, so
        // arrow keys and Return reach the text view and it drives the selection.
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = CompletionListContentView(panel: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Never steal focus from the text view.
    override var acceptsFirstResponder: Bool { false }

    var count: Int { items.count }

    /// Shows the list next to `caretScreenRect`, with `items` selectable.
    /// Shows the list directly under `lineRect`, left-aligned with `caretX`.
    ///
    /// Anchoring below the caret *line* (rather than at the caret itself) is what
    /// keeps the popup from covering the code being typed.
    func show(items: [CompletionItem], below lineRect: NSRect, caretX: CGFloat, font: NSFont) {
        self.items = items
        self.font = font
        selectedIndex = 0
        let height = min(CGFloat(items.count) * rowHeight + 4, 240)
        setContentSize(NSSize(width: width, height: height))
        setFrameOrigin(origin(below: lineRect, caretX: caretX, height: height))
        (contentView as? CompletionListContentView)?.rebuild()
        // `orderFront` (not `orderFrontRegardless`) keeps the current key window,
        // so the editor keeps receiving the keystrokes that drive this list.
        orderFront(nil)
        // A short fade-in reads as a popup rather than a flash of text. The panel
        // is a plain window, so the animation is applied to its content view.
        if let view = contentView {
            view.wantsLayer = true
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                view.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard isVisible else {
            items = []
            return
        }
        if let view = contentView {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.06
                view.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.orderOut(nil)
            })
        } else {
            orderOut(nil)
        }
        items = []
    }

    var isShowing: Bool { isVisible && !items.isEmpty }

    /// Moves the selection by `delta` rows, wrapping around.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        let previous = selectedIndex
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        guard selectedIndex != previous else { return }
        // The rows are drawn by the inner table view, not by the container, so
        // redrawing the container left the highlight stuck on the old row even
        // though the selection had moved.
        (contentView as? CompletionListContentView)?.redrawRows()
        scrollToSelection()
    }

    func acceptSelection() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        let handler = onAccept
        dismiss()
        handler?(item)
    }

    func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    private func scrollToSelection() {
        guard let scrollView = contentView?.subviews.first as? NSScrollView else { return }
        let rowRect = NSRect(x: 0, y: CGFloat(selectedIndex) * rowHeight,
                             width: scrollView.contentView.bounds.width, height: rowHeight)
        scrollView.contentView.scrollToVisible(rowRect)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Screen origin for a popup that hangs *below* `lineRect`.
    ///
    /// In AppKit screen coordinates `maxY` is the top edge, so sitting under a line
    /// means starting at `lineRect.minY - height`.
    private func origin(below lineRect: NSRect, caretX: CGFloat, height: CGFloat) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(lineRect) }) ?? NSScreen.main else {
            return NSPoint(x: caretX, y: lineRect.minY - height - 1)
        }
        let gap: CGFloat = 1
        var x = caretX
        var y = lineRect.minY - height - gap
        // No room below: flip above the line rather than off-screen.
        if y < screen.visibleFrame.minY + 4 {
            y = lineRect.maxY + gap
        }
        if x + width > screen.visibleFrame.maxX {
            x = screen.visibleFrame.maxX - width - 4
        }
        if x < screen.visibleFrame.minX { x = screen.visibleFrame.minX + 4 }
        return NSPoint(x: x, y: y)
    }

    fileprivate func item(at index: Int) -> CompletionItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    fileprivate var selectedRow: Int { selectedIndex }

    /// Test accessors: what the highlight currently points at.
    var selectedRowForTesting: Int { selectedIndex }
    var selectedTextForTesting: String? { item(at: selectedIndex)?.insertionText }
    fileprivate var rowSize: CGFloat { rowHeight }
    fileprivate var codeFont: NSFont { font }
}

/// Scrollable list of suggestions with grey placeholders.
private final class CompletionListContentView: NSView {
    private weak var panel: CompletionPanel?
    private let scrollView = NSScrollView()
    private let tableView = CompletionTableView()

    init(panel: CompletionPanel) {
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1)
        ])
        tableView.panel = panel
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repaints the rows after the selection changed.
    func redrawRows() {
        tableView.reloadData()
    }

    func rebuild() {
        guard let panel else { return }
        let count = panel.count
        let rowHeight = panel.rowSize
        tableView.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width,
                                 height: max(CGFloat(count) * rowHeight, rowHeight))
        tableView.rowHeight = rowHeight
        tableView.reloadData()
    }
}

/// Row drawing for the completion list.
private final class CompletionTableView: NSView {
    weak var panel: CompletionPanel?
    var rowHeight: CGFloat = 22

    func reloadData() {
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let panel else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let count = panel.count
        let visible = dirtyRect
        for row in 0..<count {
            let rowRect = NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
            guard rowRect.intersects(visible) else { continue }
            if row == panel.selectedRow {
                NSColor.selectedContentBackgroundColor.setFill()
                rowRect.fill()
            }
            guard let item = panel.item(at: row) else { continue }
            draw(item: item, in: rowRect, selected: row == panel.selectedRow)
        }
    }

    /// Draws the leading badge: a small outlined box with `kw`, `fx` or `var`
    /// in its bottom-right corner, in front of the word.
    /// Colour for each suggestion kind. Muted but distinct, so the list reads as
    /// coloured at a glance without becoming noisy.
    static func tint(for kind: SymbolKind) -> NSColor {
        switch kind {
        case .keyword:
            return NSColor(srgbRed: 0.62, green: 0.45, blue: 0.92, alpha: 1)   // violet
        case .header:
            return NSColor(srgbRed: 0.18, green: 0.62, blue: 0.90, alpha: 1)   // blue
        case .userDefined:
            return NSColor(srgbRed: 0.20, green: 0.72, blue: 0.45, alpha: 1)   // green
        }
    }

    /// Short letter shown inside the badge.
    static func letter(for kind: SymbolKind) -> String {
        switch kind {
        case .keyword: return "k"
        case .header: return "f"
        case .userDefined: return "v"
        }
    }

    /// Draws a small rounded square with a single letter, tinted by kind.
    ///
    /// A filled shape with one glyph stays readable at 14 pt and reads as a real
    /// icon rather than a checkerboard of tiny labels.
    private func drawBadge(for kind: SymbolKind, at x: CGFloat, rowRect: NSRect, selected: Bool) -> CGFloat {
        let side: CGFloat = 14
        let box = NSRect(x: x, y: rowRect.midY - side / 2, width: side, height: side)
        let tint = Self.tint(for: kind)
        // A soft fill plus a slightly darker border keeps the colour from shouting
        // when the row is already highlighted.
        let fill = selected ? tint.blended(withFraction: 0.15, of: .white) ?? tint : tint
        fill.withAlphaComponent(selected ? 0.95 : 0.16).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()

        if !selected {
            tint.withAlphaComponent(0.55).setStroke()
            let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            border.lineWidth = 0.8
            border.stroke()
        }

        let letter = Self.letter(for: kind) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: selected ? .white : tint
        ]
        let size = letter.size(withAttributes: attributes)
        letter.draw(at: NSPoint(x: box.midX - size.width / 2,
                                y: box.midY - size.height / 2 + 0.5),
                    withAttributes: attributes)
        return box.maxX
    }

    private func draw(item: CompletionItem, in rowRect: NSRect, selected: Bool) {
        guard let panel else { return }
        let font = panel.codeFont
        let codeColor: NSColor = selected ? .white : .labelColor
        let placeholderColor: NSColor = selected
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.65)

        var x = rowRect.minX + 10
        x = drawBadge(for: item.kind, at: x, rowRect: rowRect, selected: selected) + 7
        let baselineY = rowRect.midY - font.capHeight / 2 - font.descender / 2
        for segment in item.displaySegments {
            let color = segment.isPlaceholder ? placeholderColor : codeColor
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let text = segment.text as NSString
            let size = text.size(withAttributes: attributes)
            // Keep one line: collapse newlines so the row stays a single height.
            text.replacingOccurrences(of: "\n", with: "⏎")
                .draw(at: NSPoint(x: x, y: baselineY), withAttributes: attributes)
            x += size.width
            if x > rowRect.maxX - 40 { break }
        }

        if let detail = item.detail {
            let detailFont = NSFont.systemFont(ofSize: font.pointSize - 2)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: detailFont,
                .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.7) : .tertiaryLabelColor
            ]
            let text = detail as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rowRect.maxX - size.width - 10, y: baselineY),
                      withAttributes: attributes)
        }
    }
}
