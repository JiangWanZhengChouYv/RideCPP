import AppKit

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
    func show(items: [CompletionItem], near caretScreenRect: NSRect, font: NSFont) {
        self.items = items
        self.font = font
        selectedIndex = 0
        let height = min(CGFloat(items.count) * rowHeight + 4, 220)
        setContentSize(NSSize(width: width, height: height))
        setFrameOrigin(origin(below: caretScreenRect, height: height))
        (contentView as? CompletionListContentView)?.rebuild()
        // `orderFront` (not `orderFrontRegardless`) keeps the current key window,
        // so the editor keeps receiving the keystrokes that drive this list.
        orderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
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

    private func origin(below caret: NSRect, height: CGFloat) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) ?? NSScreen.main else {
            return NSPoint(x: caret.minX, y: caret.minY - height)
        }
        var x = caret.minX
        var y = caret.minY - height - 2
        // Flip above the caret when there is no room below.
        if y < screen.visibleFrame.minY + 4 { y = caret.maxY + 2 }
        if x + width > screen.visibleFrame.maxX { x = screen.visibleFrame.maxX - width - 4 }
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
    private func drawBadge(for kind: SymbolKind, at x: CGFloat, rowRect: NSRect, selected: Bool) -> CGFloat {
        let boxSide: CGFloat = 13
        let box = NSRect(x: x, y: rowRect.midY - boxSide / 2 + 1, width: boxSide, height: boxSide)
        let tint: NSColor = selected ? .white : NSColor.secondaryLabelColor
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        tint.withAlphaComponent(selected ? 0.85 : 0.5).setStroke()
        path.stroke()

        // A glyph inside the box hints at the kind; the tiny label sits on the
        // bottom-right corner so it reads as a tag rather than text.
        let glyph: String
        let label: String
        switch kind {
        case .keyword: glyph = "◇"; label = "kw"
        case .header:  glyph = "ƒ"; label = "fx"
        case .userDefined: glyph = "■"; label = "var"
        }
        let glyphAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: tint.withAlphaComponent(selected ? 0.9 : 0.65)
        ]
        let glyphSize = (glyph as NSString).size(withAttributes: glyphAttributes)
        (glyph as NSString).draw(at: NSPoint(x: box.midX - glyphSize.width / 2,
                                             y: box.midY - glyphSize.height / 2 + 1),
                                 withAttributes: glyphAttributes)

        // The corner label, drawn over the box's bottom-right edge.
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6, weight: .semibold),
            .foregroundColor: selected ? NSColor.white : NSColor.tertiaryLabelColor
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttributes)
        let labelOrigin = NSPoint(x: box.maxX - labelSize.width + 1.5,
                                  y: box.minY - labelSize.height + 1.5)
        // Clear a small patch so the tag stays legible over the box outline.
        let patch = NSRect(x: labelOrigin.x - 1, y: labelOrigin.y,
                           width: labelSize.width + 2, height: labelSize.height)
        (selected ? NSColor.selectedContentBackgroundColor : NSColor.windowBackgroundColor).setFill()
        patch.fill()
        (label as NSString).draw(at: labelOrigin, withAttributes: labelAttributes)
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
