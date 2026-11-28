import SwiftUI
import AppKit
import EditorCore

/// Drives the find bar: holds the query and options, runs the search, and moves
/// the editor's selection between matches.
///
/// Separate from the view so the behaviour can be exercised without a window, and
/// so the same model can later back "find in files".
@MainActor
public final class FindModel: ObservableObject {

    @Published var query: String = "" {
        didSet { if query != oldValue { searchChanged() } }
    }
    @Published var replacement: String = ""
    @Published var caseSensitive = false {
        didSet { if caseSensitive != oldValue { searchChanged() } }
    }
    @Published var wholeWord = false {
        didSet { if wholeWord != oldValue { searchChanged() } }
    }
    @Published var isRegex = false {
        didSet { if isRegex != oldValue { searchChanged() } }
    }
    @Published var showsReplace = false
    @Published private(set) var matchCount = 0
    @Published private(set) var currentIndex = 0
    /// True when the pattern is a regex that will not compile.
    @Published private(set) var hasInvalidRegex = false
    @Published private(set) var isVisible = false

    private let search = TextSearch()
    private var matches: [TextSearch.Match] = []
    /// Supplies the document being searched; set by the window.
    var documentProvider: () -> DocumentModel? = { nil }

    var options: TextSearch.Options {
        TextSearch.Options(caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex)
    }

    /// 1-based position of the selected match, for the "2 of 7" readout.
    var currentMatchNumber: Int {
        matches.isEmpty ? 0 : currentIndex + 1
    }

    // MARK: - Visibility

    func show(replacing: Bool) {
        showsReplace = replacing
        isVisible = true
        // Start from whatever is selected: selecting a word and pressing ⌘F is
        // how most people search for the identifier under the caret.
        if let textView = documentProvider()?.engine.textView {
            let selected = textView.selectedRange()
            if selected.length > 0, selected.length < 200 {
                query = (textView.string as NSString).substring(with: selected)
            }
        }
        searchChanged()
    }

    func dismiss() {
        isVisible = false
        clearHighlights()
        documentProvider()?.engine.textView.hideFindHighlights()
    }

    // MARK: - Searching

    private func searchChanged() {
        guard isVisible, let document = documentProvider() else {
            matchCount = 0
            currentIndex = 0
            return
        }
        hasInvalidRegex = false
        if isRegex, !query.isEmpty {
            hasInvalidRegex = (try? NSRegularExpression(pattern: query)) == nil
        }
        let found = search.matches(of: query, in: document.text, options: options)
        matches = found
        matchCount = found.count
        currentIndex = min(currentIndex, max(0, found.count - 1))
        applyHighlights(in: document)
    }

    /// Paints every match, with the selected one distinguished.
    private func applyHighlights(in document: DocumentModel) {
        let textView = document.engine.textView
        textView.showFindHighlights(matches.map(\.range),
                                    current: matches.isEmpty ? nil : matches[currentIndex].range)
    }

    private func clearHighlights() {
        documentProvider()?.engine.textView.hideFindHighlights()
    }

    // MARK: - Navigation

    func findNext() {
        guard !matches.isEmpty, let document = documentProvider() else { return }
        let caret = document.engine.textView.selectedRange().location
        // From a fresh search, keep the match that is already selected.
        let target: TextSearch.Match?
        if matches.indices.contains(currentIndex),
           matches[currentIndex].range.location == caret,
           matches[currentIndex].range.length == document.engine.textView.selectedRange().length,
           caret != 0 || currentIndex > 0 {
            target = search.nextMatch(after: matches[currentIndex].range.location, in: matches)
        } else {
            target = search.nextMatch(after: caret - 1, in: matches)
        }
        select(target, in: document)
    }

    func findPrevious() {
        guard !matches.isEmpty, let document = documentProvider() else { return }
        let caret = document.engine.textView.selectedRange().location
        let target = search.previousMatch(before: caret, in: matches)
        select(target, in: document)
    }

    private func select(_ match: TextSearch.Match?, in document: DocumentModel) {
        guard let match, let index = matches.firstIndex(where: { $0.range == match.range }) else {
            return
        }
        currentIndex = index
        let textView = document.engine.textView
        textView.setSelectedRange(match.range)
        textView.scrollRangeToVisible(match.range)
        applyHighlights(in: document)
    }

    // MARK: - Replacing

    func replaceCurrent() {
        guard matches.indices.contains(currentIndex), let document = documentProvider() else { return }
        let target = matches[currentIndex]
        let textView = document.engine.textView
        let whole = NSRange(location: 0, length: (document.text as NSString).length)
        // One edit, so a single undo restores the previous text.
        let updated = (document.text as NSString).replacingCharacters(in: target.range,
                                                                     with: replacement)
        if textView.shouldChangeText(in: whole, replacementString: updated) {
            textView.replaceCharacters(in: whole, with: updated)
            textView.didChangeText()
        }
        searchChanged()
        // Stay on the match that replaced the text the user just handled.
        if matches.indices.contains(currentIndex) {
            let next = matches[currentIndex].range
            textView.setSelectedRange(next)
            textView.scrollRangeToVisible(next)
        }
    }

    func replaceAll() {
        guard !matches.isEmpty, let document = documentProvider() else { return }
        let textView = document.engine.textView
        let whole = NSRange(location: 0, length: (document.text as NSString).length)
        let updated = search.replacingAll(in: document.text, query: query,
                                          with: replacement, options: options)
        guard updated != document.text else { return }
        if textView.shouldChangeText(in: whole, replacementString: updated) {
            textView.replaceCharacters(in: whole, with: updated)
            textView.didChangeText()
        }
        searchChanged()
    }
}
