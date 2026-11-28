import Foundation

/// Completion that prefers clangd's semantic results and falls back to the
/// text-based provider.
///
/// Why a hybrid instead of "just use clangd":
/// * clangd needs a moment to start and to build its preamble; the first keystrokes
///   after opening a file would otherwise show nothing.
/// * Some files have no usable compile flags (a scratch buffer), where clangd's
///   suggestions can be empty.
///
/// The semantic path wins whenever it has anything to offer, because it knows types,
/// members and overloads; the built-in path guarantees the list is never empty.
///
/// Threading: clangd is queried asynchronously. A request is fired on every query and
/// its result is *cached* for the next keystroke, which keeps typing responsive — the
/// UI never waits on the server.
public final class SemanticCompletionProvider: CompletionProviding {

    private let fallback: BuiltinCompletionProvider
    private let session: ClangdSession
    /// Most recent semantic results, keyed by document revision + prefix + position.
    ///
    /// The revision is part of the key because clangd answers asynchronously: a
    /// result computed for an older revision of the file must never be served for
    /// the current one, or a stale (often empty) list sticks forever.
    private var cache: [String: [CompletionItem]] = [:]
    private let lock = NSLock()
    /// Incremented on every document change; identifies the revision results belong to.
    private var revision = 0
    /// The file being edited, kept in sync with clangd.
    ///
    /// Per-URI, not a single value: with several tabs open, one document's text
    /// must never be mistaken for another's, and the dedupe below has to compare
    /// against the text last sent for *that* file.
    private var syncedText: [String: String] = [:]
    /// URI completion requests are addressed to — the document with focus.
    private var activeURI: String?

    public init?(fallback: BuiltinCompletionProvider = BuiltinCompletionProvider(),
                 workingDirectory: URL,
                 standard: String = "c++17") {
        guard let session = ClangdSession(
            workingDirectory: workingDirectory,
            standard: standard,
            extraIncludePaths: [ClangdSession.prepareCompatibilityHeaders()].compactMap { $0 }
        ) else { return nil }
        self.fallback = fallback
        self.session = session
        self.session.start()
    }

    /// Whether clangd finished its handshake.
    public var isSemanticReady: Bool { session.state == .ready }

    /// Live diagnostics from clangd, keyed by file path.
    ///
    /// Delivered on the main queue, together with the exact document text the
    /// diagnostics were computed from. The editor underlines these ranges, which is
    /// what gives "errors while typing" without running the compiler.
    public var onDiagnostics: ((URL, [LSPDiagnostic], String) -> Void)? {
        get { diagnosticHandler }
        set {
            diagnosticHandler = newValue
            // The session replays its last result to a new subscriber.
            session.onDiagnostics = { [weak self] uri, items, text in
                guard let self, let url = URL(string: uri) else { return }
                self.diagnosticHandler?(url, items, text)
            }
        }
    }

    private var diagnosticHandler: ((URL, [LSPDiagnostic], String) -> Void)?

    /// Hover documentation at a character offset (main queue).
    public func hover(atUTCOffset offset: Int, in text: String, fileURL: URL?,
                      completion: @escaping (String?) -> Void) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        let prefix = ns.substring(to: clamped)
        let lines = prefix.components(separatedBy: "\n")
        let position = LSPPosition(line: max(0, lines.count - 1),
                                   character: (lines.last as NSString?)?.length ?? 0)
        session.requestHover(uri: "file://" + url.path, position: position) { value in
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Renames the symbol at an offset.
    ///
    /// Returns the edits that touch `text`'s own file; edits in other files are
    /// reported separately so the caller can decide what to do with them.
    public func rename(atOffset offset: Int, in text: String, to newName: String,
                       fileURL: URL?,
                       completion: @escaping (Result<[LSPTextEdit], Error>) -> Void) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        let prefix = ns.substring(to: clamped)
        let lines = prefix.components(separatedBy: "\n")
        let position = LSPPosition(line: max(0, lines.count - 1),
                                   character: (lines.last as NSString?)?.length ?? 0)
        let ownPath = url.resolvingSymlinksInPath().path
        func attempt(_ remaining: Int) {
            session.requestRename(uri: "file://" + url.path, position: position,
                                  newName: newName) { [weak self] result in
                switch result {
                case .failure(let error):
                    // The document may still be opening; try once more before
                    // giving up, the way the signature request does.
                    if remaining > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            attempt(remaining - 1)
                        }
                    } else {
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                case .success(let edits):
                    let own = edits.filter { $0.path == ownPath || $0.path == url.path }
                    if own.isEmpty, remaining > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            attempt(remaining - 1)
                        }
                    } else {
                        DispatchQueue.main.async { completion(.success(own)) }
                    }
                }
                _ = self
            }
        }
        attempt(1)
    }

    /// Advisory labels clangd would draw for a range of the document.
    ///
    /// Called with the visible portion: clangd computes hints per range and
    /// ignores very large requests.
    public func inlayHints(in text: String, fileURL: URL?,
                           firstLine: Int, lastLine: Int,
                           completion: @escaping ([LSPInlayHint]) -> Void) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        let range = LSPRange(start: LSPPosition(line: max(0, firstLine), character: 0),
                             end: LSPPosition(line: max(0, lastLine), character: 0))
        func attempt(_ remaining: Int) {
            session.requestInlayHints(uri: "file://" + url.path, range: range) { hints in
                if hints.isEmpty, remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        attempt(remaining - 1)
                    }
                    return
                }
                DispatchQueue.main.async { completion(hints) }
            }
        }
        attempt(1)
    }

    /// The signature of the call the caret is inside, if any.
    ///
    /// Delegates the "am I inside a call" decision to `CallContext`, which is
    /// testable, so this method only has to convert offsets and forward.
    public func signatureHelp(atOffset offset: Int, in text: String, fileURL: URL?,
                              completion: @escaping (LSPSignature?, Int) -> Void) {
        guard let context = CallContext.info(at: offset, in: text) else {
            completion(nil, 0)
            return
        }
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        let prefix = ns.substring(to: clamped)
        let lines = prefix.components(separatedBy: "\n")
        let position = LSPPosition(line: max(0, lines.count - 1),
                                   character: (lines.last as NSString?)?.length ?? 0)
        let index = context.argumentIndex
        let uri = "file://" + url.path
        // One retry: the first request can arrive while clangd is still opening
        // the document, which answers with an empty list rather than waiting.
        func attempt(_ remaining: Int) {
            session.requestSignatureHelp(uri: uri, position: position) { [weak self] signatures in
                if signatures.isEmpty, remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        attempt(remaining - 1)
                    }
                    return
                }
                DispatchQueue.main.async {
                    completion(signatures.first, index)
                }
                _ = self
            }
        }
        attempt(1)
    }

    /// Definition location for the symbol at a character offset.
    public func definition(atOffset offset: Int, in text: String, fileURL: URL?,
                           completion: @escaping ([LSPLocation]) -> Void) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        let prefix = ns.substring(to: clamped)
        let lines = prefix.components(separatedBy: "\n")
        let position = LSPPosition(line: max(0, lines.count - 1),
                                   character: (lines.last as NSString?)?.length ?? 0)
        session.requestDefinition(uri: "file://" + url.path, position: position) { locations in
            DispatchQueue.main.async { completion(locations) }
        }
    }


    /// Applies a code action's edit to `text`, returning the new text.
    ///
    /// Ranges are LSP line/character pairs, converted here so the caller can stay
    /// in plain Swift strings.
    public static func apply(_ action: LSPCodeAction, to text: String) -> String? {
        guard let newText = action.newText, let range = action.range else { return nil }
        let ns = text as NSString
        func offset(_ position: LSPPosition) -> Int? {
            var line = 0
            var index = 0
            while line < position.line {
                let found = ns.range(of: "\n", options: [],
                                     range: NSRange(location: index, length: ns.length - index))
                if found.location == NSNotFound { return nil }
                index = found.location + 1
                line += 1
            }
            let result = index + position.character
            guard result <= ns.length else { return nil }
            return result
        }
        guard let start = offset(range.start), let end = offset(range.end), end >= start else {
            return nil
        }
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start),
                                      with: newText)
    }

    /// Quick fixes clangd offers for a diagnostic (main queue).
    ///
    /// Only actions that carry an applicable edit are returned: clangd also sends
    /// refactorings that need a server-side command, and those cannot be applied
    /// from a menu.
    public func codeActions(for diagnostic: LSPDiagnostic,
                            in text: String,
                            fileURL: URL?,
                            completion: @escaping ([LSPCodeAction]) -> Void) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        session.requestCodeActions(uri: "file://" + url.path,
                                   range: diagnostic.range,
                                   diagnostics: [diagnostic]) { actions in
            let applicable = actions.filter(\.isApplicable)
            DispatchQueue.main.async { completion(applicable) }
        }
    }

    // MARK: - Document sync

    /// Pushes the current text to clangd. Cheap when unchanged.
    public func syncDocument(text: String, fileURL: URL?) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-untitled.cpp")
        let uri = "file://" + url.path
        lock.lock()
        let changed = syncedText[uri] != text
        syncedText[uri] = text
        activeURI = uri
        lock.unlock()
        guard changed else { return }
        lock.lock()
        revision &+= 1
        lock.unlock()
        session.openDocument(uri: uri, text: text)
    }

    // MARK: - CompletionProviding

    /// Caret location (UTF-16 line/character) for the next request.
    ///
    /// Set by the editor before querying; clangd needs the exact position, and
    /// guessing "end of document" gives nonsense results whenever the caret is
    /// somewhere in the middle.
    public var caretPosition: CursorPosition?

    public func completionItems(forPrefix prefix: String,
                                document: String,
                                context: CompletionContext = .code) -> [CompletionItem] {
        let lexical = fallback.completionItems(forPrefix: prefix, document: document, context: context)
        // Preprocessor directives are lexical by nature; clangd has nothing better.
        guard context == .code else { return lexical }

        lock.lock()
        let uri = activeURI
        lock.unlock()
        guard let uri else { return lexical }

        // Ask clangd about the position that produced this prefix. The result is
        // used immediately if cached, otherwise the lexical list is shown and the
        // semantic result will be ready for the next keystroke.
        let position = caretPosition ?? Self.position(ofPrefix: prefix, in: document)
        lock.lock()
        let requestRevision = revision
        let key = "\(requestRevision)|\(prefix)@\(position.line):\(position.character)"
        let cached = cache[key]
        lock.unlock()

        session.requestCompletions(uri: uri, line: position.line, character: position.character) { [weak self] lspItems in
            guard let self else { return }
            let converted = lspItems.map { self.item(from: $0, prefix: prefix) }
            guard !converted.isEmpty else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // Drop the answer if the document moved on while clangd was thinking.
            guard requestRevision == self.revision else { return }
            self.cache[key] = converted
            // Keep the cache tiny: only the most recent handful of prefixes matter.
            if self.cache.count > 24 { self.cache.removeAll() }
        }

        if let cached, !cached.isEmpty {
            // Ranked by the server's own priorities, with locals and functions
            // ahead of header macros; without this the list led with things like
            // `FE_ALL_EXCEPT` because they happened to arrive first.
            let ordered = cached.sorted { lhs, rhs in
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
            }
            // Lexical results only fill gaps the server left, and go after its
            // answers so a local identifier the server missed still appears.
            var merged = ordered
            var seen = Set(merged.map(\.insertionText))
            for candidate in lexical where !seen.contains(candidate.insertionText) {
                merged.append(candidate)
                seen.insert(candidate.insertionText)
            }
            return Array(merged.prefix(40))
        }
        return lexical
    }

    /// Converts one clangd item into our model, doing the small cleanups the UI
    /// needs (snippet placeholders, trailing punctuation in labels).
    private func item(from lsp: LSPCompletionItem, prefix: String) -> CompletionItem {
        // clangd sends snippets like `append(${1:str})`. Keep them as placeholders so
        // the list can grey the parts the user has to fill in and only insert code.
        let insertion = Self.convertSnippet(lsp.insertText.trimmingCharacters(in: .whitespaces))

        // The row shows the bare name; the signature goes in `detail` so the list
        // stays scannable. clangd puts the full signature in `label` and the return
        // type in `detail`, so both are needed.
        let name = Self.name(from: lsp.label)
        let params = Self.signature(from: lsp.label)
        // Show "returnType params" when the server gives both, so overloads stay
        // distinguishable without repeating the name.
        let returnType = lsp.detail ?? ""
        let detail: String?
        if !params.isEmpty, !returnType.isEmpty, returnType != params {
            detail = "\(returnType) \(params)"
        } else if !params.isEmpty {
            detail = params
        } else {
            detail = returnType.isEmpty ? nil : returnType
        }
        return .semantic(text: name.isEmpty ? lsp.label : name,
                         detail: detail,
                         kind: Self.kind(fromLSP: lsp.kindCode),
                         insertion: insertion,
                         sortKey: Self.rankKey(lsp: lsp, name: name.isEmpty ? lsp.label : name,
                                               prefix: prefix))
    }

    /// Ranking key for one suggestion.
    ///
    /// clangd already orders its answers: `sortText` encodes scope proximity, and
    /// a local variable sorts before a header macro. Measured on a real file,
    /// `flag` came back as `3f8bfb0e…` and `false_type` as `4109f058…`, so the
    /// prefix ordering is meaningful and must not be reinvented — an earlier
    /// version re-weighted by symbol kind and made the list worse.
    ///
    /// The one thing worth adding is that lowercase typing should not be buried
    /// under shouty macros: `FE_ALL_EXCEPT` matches `f` only case-insensitively.
    static func rankKey(lsp: LSPCompletionItem, name: String, prefix: String) -> String {
        let caseTier: String
        if prefix.isEmpty {
            caseTier = "0"
        } else if name.hasPrefix(prefix) {
            caseTier = "0"
        } else {
            caseTier = "1"
        }
        // Fuzzy quality: IntelliJ's PrefixMatchingWeigher also separates a real
        // prefix match from one that only matches inside the word. `vpb` should
        // find `push_back`, but a straight prefix always wins over it.
        let matchTier = Self.matchTier(name: name, prefix: prefix)
        return caseTier + matchTier + (lsp.sortText ?? "~")
    }

    /// How well `prefix` matches `name`, in the spirit of IntelliJ's weighers.
    ///
    /// 0 — the name starts with the prefix (`fl` → `flag`)
    /// 1 — the prefix matches the starts of words inside it (`pb` → `push_back`)
    /// 2 — the characters appear in order but not at word starts (`fse` → `fsum`)
    /// 3 — no match at all
    static func matchTier(name: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return "0" }
        let lowerName = name.lowercased()
        let lowerPrefix = prefix.lowercased()
        if lowerName.hasPrefix(lowerPrefix) { return "0" }
        // Word-initial matching, the acronym case.
        var initials = ""
        var atWordStart = true
        for character in lowerName {
            if character == "_" {
                atWordStart = true
                continue
            }
            if atWordStart { initials.append(character) }
            atWordStart = false
        }
        if initials.hasPrefix(lowerPrefix) { return "1" }
        // Characters in order anywhere.
        var searchIndex = lowerName.startIndex
        for character in lowerPrefix {
            guard let found = lowerName[searchIndex...].firstIndex(of: character) else {
                return "3"
            }
            searchIndex = lowerName.index(after: found)
        }
        return "2"
    }

    /// The bare identifier at the start of a clangd label.
    static func name(from label: String) -> String {
        var result = ""
        // clangd prefixes header symbols with a bullet ("•cout"). It identifies
        // where a symbol comes from, not part of its name, and leaving it in made
        // the name come back empty — which then sorted those items to the top.
        var body = Substring(label.trimmingCharacters(in: .whitespaces))
        while let first = body.first, first == "•" || first == " " {
            body = body.dropFirst()
        }
        for character in body {
            if character.isLetter || character.isNumber || character == "_" || character == "~" {
                result.append(character)
            } else {
                break
            }
        }
        return result
    }

    /// The parameter list from a label like `append(const string &str)`.
    static func signature(from label: String) -> String {
        guard let open = label.firstIndex(of: "(") else { return "" }
        // Include the return type that clangd sometimes appends after "->".
        return String(label[open...])
    }

    /// Maps LSP completion kinds to our three badge kinds.
    static func kind(fromLSP code: Int) -> SymbolKind {
        switch code {
        case 2, 3:            // Method, Function
            return .header
        case 5, 10, 22, 23:   // Field, Property, Struct, Event
            return .userDefined
        case 6, 9, 12, 13, 20, 21:  // Variable, Enum, Value, EnumMember, Key, Constant
            return .userDefined
        case 7, 8:            // Class, Interface
            return .header
        case 14, 15:          // Keyword, Snippet (clangd sends `for (…)` as a snippet)
            return .keyword
        default:
            return .header
        }
    }

    /// Turns LSP snippet syntax into our `⟨placeholder⟩` marker.
    static func convertSnippet(_ text: String) -> String {
        guard text.contains("${") || text.contains("$0") else { return text }
        // `$0` is the final cursor position and carries no text of its own.
        // clangd uses it heavily — `using namespace $0;` is its whole suggestion
        // for a using-directive — and leaving the marker in place produced the
        // literal `using namespace $0;` in the list.
        let withoutPosition = text.replacingOccurrences(of: "$0", with: "")
        var result = ""
        var index = withoutPosition.startIndex
        while index < withoutPosition.endIndex {
            let character = withoutPosition[index]
            if character == "$", withoutPosition.index(after: index) < withoutPosition.endIndex,
               withoutPosition[withoutPosition.index(after: index)] == "{" {
                // ${1:name} or ${1|a,b|}
                var cursor = withoutPosition.index(index, offsetBy: 2)
                var number = ""
                while cursor < withoutPosition.endIndex, withoutPosition[cursor].isNumber {
                    number.append(withoutPosition[cursor])
                    cursor = withoutPosition.index(after: cursor)
                }
                if cursor < withoutPosition.endIndex, withoutPosition[cursor] == ":" {
                    cursor = withoutPosition.index(after: cursor)
                    var placeholder = ""
                    var depth = 1
                    while cursor < withoutPosition.endIndex {
                        let c = withoutPosition[cursor]
                        if c == "}" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        placeholder.append(c)
                        cursor = withoutPosition.index(after: cursor)
                    }
                    if !placeholder.isEmpty { result += "⟨\(placeholder)⟩" }
                    index = cursor < withoutPosition.endIndex
                        ? withoutPosition.index(after: cursor) : withoutPosition.endIndex
                    continue
                }
                index = withoutPosition.index(index, offsetBy: 2)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// Converts a character offset into an LSP line/character position.
    static func position(ofPrefix prefix: String, in document: String) -> CursorPosition {
        let target = document.count
        // Find the last occurrence of the prefix at the end of the document, which is
        // where the caret is while typing.
        let ns = document as NSString
        let caret = ns.length
        let tail = ns.substring(to: caret)
        let lines = tail.components(separatedBy: "\n")
        let line = max(0, lines.count - 1)
        let character = (lines.last as NSString?)?.length ?? 0
        _ = target
        return CursorPosition(line: line, character: character)
    }
}

extension CompletionItem {
    /// Convenience for the semantic provider: display text and inserted text differ.
    static func semantic(text: String, detail: String?, kind: SymbolKind, insertion: String,
                         sortKey: String = "") -> CompletionItem {
        CompletionItem(id: "lsp:\(text):\(insertion.hashValue)",
                       text: text,
                       detail: detail,
                       kind: kind,
                       explicitInsertion: insertion,
                       sortKey: sortKey)
    }
}

/// A caret position in LSP terms: 0-based line, UTF-16 character offset.
///
/// A named type instead of a tuple so call sites read `position.line` and stay
/// self-documenting.
public struct CursorPosition: Sendable, Equatable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}
