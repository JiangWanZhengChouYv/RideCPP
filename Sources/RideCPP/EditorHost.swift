import SwiftUI
import AppKit
import EditorCore

/// Bridges the AppKit editor engine into SwiftUI.
///
/// The engine owns the `NSScrollView`; this representable just installs it, so
/// each tab's scroll position, selection and undo stack survive view rebuilds.
struct EditorHost: NSViewRepresentable {
    let document: DocumentModel

    func makeNSView(context: Context) -> NSView {
        let container = EditorContainerView()
        container.install(document.engine.scrollView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? EditorContainerView else { return }
        container.install(document.engine.scrollView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? EditorContainerView)?.detach()
    }
}

/// Plain view that keeps a single child (the editor's scroll view) sized to fill.
final class EditorContainerView: NSView {
    private weak var installed: NSView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backing plus clipping confines the editor's drawing to this
        // view. Without it, a gutter drawn during an intermediate layout pass
        // leaves stale pixels in the window backing store above the editor —
        // which shows up as a stray vertical line running to the window's top.
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    func install(_ view: NSView) {
        guard installed !== view else { return }
        installed?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        installed = view
        layoutSubtreeIfNeeded()
        (view as? NSScrollView)?.documentView?.setFrameSize(
            NSSize(width: max(view.bounds.width, 1), height: max(((view as? NSScrollView)?.documentView?.frame.height ?? 0), view.bounds.height)))
    }

    func detach() {
        installed?.removeFromSuperview()
        installed = nil
    }
}
