import AppKit
import SwiftUI

/// A terminal-style console: program output and the user's typing live in the
/// same text view, so input is entered directly where the output appears.
///
/// The transcript is immutable from the user's point of view: everything before
/// `transcriptLength` is locked, and the editable tail is the current input.
/// Return submits that tail to the running program (or queues it), exactly like
/// typing into a terminal.
final class ConsoleTextView: NSTextView {

    /// Length (UTF-16) of the locked transcript at the start of the view.
    private(set) var transcriptLength = 0
    /// Set while the view itself is mutating the storage, so the edit guard does
    /// not reject its own changes.
    private var isApplyingInternalEdit = false

    var onSubmit: ((String) -> Void)?
    var onInterrupt: (() -> Void)?
    /// Reports the text currently being typed (the editable tail).
    var onPendingInputChange: ((String) -> Void)?
    /// Whether Return should submit right now (a program is running).
    var submitsToProgram = false

    // MARK: - Setup

    static func make() -> ConsoleTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = ConsoleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200),
                                   textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .labelColor
        insertionPointColor = .controlAccentColor
        font = Self.outputFont
        textContainerInset = NSSize(width: 8, height: 6)
        textContainer?.lineFragmentPadding = 2
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        typingAttributes = Self.inputAttributes
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    }

    static var outputFont: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }

    static var outputAttributes: [NSAttributedString.Key: Any] {
        [.font: outputFont, .foregroundColor: NSColor.labelColor]
    }

    static var inputAttributes: [NSAttributedString.Key: Any] {
        [.font: outputFont, .foregroundColor: NSColor.controlAccentColor]
    }

    // MARK: - Transcript

    /// Program output arrives here and is inserted before the pending input, so
    /// what the user is typing stays at the end.
    func appendOutput(_ text: String) {
        guard !text.isEmpty else { return }
        isApplyingInternalEdit = true
        let insertionPoint = transcriptLength
        let inputRange = NSRange(location: transcriptLength,
                                 length: (string as NSString).length - transcriptLength)
        let caret = selectedRange()
        let pending = inputRange.length > 0 ? (string as NSString).substring(with: inputRange) : ""

        textStorage?.beginEditing()
        textStorage?.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: text)
        // Re-apply input attributes on the tail (text storage merges around edits).
        if !pending.isEmpty {
            let newInputRange = NSRange(location: insertionPoint + (text as NSString).length,
                                        length: (pending as NSString).length)
            textStorage?.setAttributes(Self.inputAttributes, range: newInputRange)
        }
        textStorage?.endEditing()
        isApplyingInternalEdit = false

        transcriptLength += (text as NSString).length

        // Keep the caret at the end when it was at the end, otherwise shift it.
        if caret.location >= insertionPoint {
            let shifted = caret.location + (text as NSString).length
            setSelectedRange(NSRange(location: min(shifted, (string as NSString).length), length: 0))
        }
        scrollToEnd()
    }

    /// Rebuilds the transcript wholesale (used when output is cleared or when the
    /// console is restored after a tab switch).
    func replaceTranscript(_ text: String) {
        isApplyingInternalEdit = true
        let pending = pendingInput
        let combined = text + pending
        textStorage?.beginEditing()
        textStorage?.replaceCharacters(in: NSRange(location: 0, length: (string as NSString).length),
                                       with: combined)
        textStorage?.setAttributes(Self.outputAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        if !pending.isEmpty {
            let start = (text as NSString).length
            textStorage?.setAttributes(Self.inputAttributes,
                                       range: NSRange(location: start, length: (pending as NSString).length))
        }
        textStorage?.endEditing()
        isApplyingInternalEdit = false
        transcriptLength = (text as NSString).length
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollToEnd()
    }

    /// Echoes a submitted line into the transcript as user input.
    private func echo(_ line: String) {
        isApplyingInternalEdit = true
        let insertion = NSRange(location: transcriptLength,
                                length: (pendingInput as NSString).length)
        textStorage?.beginEditing()
        textStorage?.replaceCharacters(in: insertion, with: line + "\n")
        let echoRange = NSRange(location: transcriptLength, length: (line as NSString).length + 1)
        textStorage?.setAttributes(Self.inputAttributes, range: echoRange)
        textStorage?.endEditing()
        isApplyingInternalEdit = false
        transcriptLength += (line as NSString).length + 1
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        onPendingInputChange?("")
        scrollToEnd()
    }

    /// The editable tail: what the user has typed but not submitted.
    var pendingInput: String {
        let ns = string as NSString
        guard transcriptLength <= ns.length else { return "" }
        return ns.substring(from: transcriptLength)
    }

    func focusInput() {
        window?.makeFirstResponder(self)
        let end = (string as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
    }

    private func scrollToEnd() {
        let end = (string as NSString).length
        guard end > 0 else { return }
        scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    // MARK: - Keys

    override func insertNewline(_ sender: Any?) {
        submitPendingInput()
    }

    override func insertLineBreak(_ sender: Any?) {
        insertNewline(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl-C interrupts the program, like a terminal.
        if event.modifierFlags.contains(.control),
           let characters = event.charactersIgnoringModifiers,
           characters == "c" || characters == "C" {
            onInterrupt?()
            return
        }
        super.keyDown(with: event)
    }

    /// Sends whatever is typed in the console (used by the Return button too).
    func submitPendingInput() {
        let line = pendingInput
        let hadTrailingNewline = false
        _ = hadTrailingNewline
        echo(line)
        onSubmit?(line)
    }

    // MARK: - Edit guard

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isApplyingInternalEdit { return true }
        // Never let typing or deletion touch the transcript.
        if affectedCharRange.location < transcriptLength { return false }
        // A deletion that reaches into the transcript is refused as well.
        if let replacement = replacementString {
            if affectedCharRange.location + affectedCharRange.length < transcriptLength { return false }
            _ = replacement
        } else if affectedCharRange.location + affectedCharRange.length < transcriptLength {
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !isApplyingInternalEdit else { return }
        // Typing replaces the selection, so keep the caret out of the transcript.
        let caret = selectedRange()
        if caret.location < transcriptLength {
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
    }

    override func didChangeText() {
        super.didChangeText()
        guard !isApplyingInternalEdit else { return }
        onPendingInputChange?(pendingInput)
    }
}

/// SwiftUI wrapper for the console.
struct ConsoleView: NSViewRepresentable {
    @ObservedObject var state: AppState

    /// The live console view, used by the in-process self-test to type into it
    /// exactly the way a user would.
    static weak var liveConsole: ConsoleTextView?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ConsoleTextView.make()
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView

        context.coordinator.textView = textView
        ConsoleView.liveConsole = textView
        textView.onSubmit = { line in
            state.submitConsoleLine(line)
        }
        textView.onInterrupt = {
            state.interruptProgram()
        }
        textView.replaceTranscript(state.outputText)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.syncTranscript(state.outputText)
        textView.submitsToProgram = state.isRunning
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: ConsoleTextView?
    }
}

extension ConsoleTextView {
    /// Keeps the text view in step with the authoritative transcript in
    /// `AppState`, appending only what is new.
    func syncTranscript(_ output: String) {
        let displayed = transcriptText
        if output == displayed { return }
        if output.hasPrefix(displayed) {
            appendOutput(String(output.dropFirst(displayed.count)))
        } else {
            replaceTranscript(output)
        }
    }

    /// The transcript portion only (without the pending input).
    var transcriptText: String {
        let ns = string as NSString
        guard transcriptLength <= ns.length else { return string }
        return ns.substring(to: transcriptLength)
    }
}
