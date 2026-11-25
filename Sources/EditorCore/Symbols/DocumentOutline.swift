import Foundation

/// One navigable item in the document outline (a function, struct, class, …).
public struct OutlineItem: Identifiable, Equatable, Sendable {
    public let id: String
    /// Name as written in the source (`main`, `Point`, …).
    public let name: String
    /// Extra context shown next to the name, e.g. the signature's parameters.
    public let detail: String?
    public let kind: OutlineKind
    /// 1-based line number, used to jump to the declaration.
    public let line: Int

    public init(name: String, detail: String?, kind: OutlineKind, line: Int) {
        self.id = "\(line):\(name)"
        self.name = name
        self.detail = detail
        self.kind = kind
        self.line = line
    }
}

public enum OutlineKind: String, Sendable {
    case function
    case structure
    case `class`
    case enumeration
    case variable
    case include

    /// SF Symbol name for the sidebar.
    /// SF Symbol for the sidebar. Kept to symbols available on macOS 14; the
    /// sidebar falls back to a text glyph when a symbol is missing.
    public var symbolName: String {
        switch self {
        case .function: return "f.cursive"
        case .structure: return "square.stack.3d.up"
        case .class: return "cube"
        case .enumeration: return "list.bullet.rectangle"
        case .variable: return "square"
        case .include: return "number"
        }
    }

    /// Single-letter tag shown in the sidebar, used when the SF Symbol is absent
    /// and to keep rows visually compact.
    public var tag: String {
        switch self {
        case .function: return "fn"
        case .structure: return "st"
        case .class: return "cl"
        case .enumeration: return "en"
        case .variable: return "vr"
        case .include: return "in"
        }
    }
}

/// Builds a lightweight outline of a C++ document for the sidebar.
///
/// This is a textual scan, not a parser: it recognises the declaration shapes that
/// matter for navigation (`struct`/`class`/`enum`, function definitions, includes)
/// and reports their line numbers. Being fast matters more than being exhaustive
/// here, because it runs on every edit.
public enum DocumentOutline {

    public static func items(in document: String) -> [OutlineItem] {
        let code = DocumentSymbolIndex.strippingCommentsAndLiterals(document)
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        var items: [OutlineItem] = []
        var seen = Set<String>()

        func add(_ name: String, _ detail: String?, _ kind: OutlineKind, _ line: Int) {
            let key = "\(line):\(name)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            items.append(OutlineItem(name: name, detail: detail, kind: kind, line: line))
        }

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // #include <header>
            if line.hasPrefix("#include"), let open = line.firstIndex(where: { $0 == "<" || $0 == "\"" }) {
                let closer: Character = line[open] == "<" ? ">" : "\""
                if let close = line[line.index(after: open)...].firstIndex(of: closer) {
                    let header = String(line[line.index(after: open)..<close])
                    add(header, nil, .include, lineNumber)
                }
                continue
            }

            // struct / class / union / enum [class] Name
            for keyword in ["struct", "class", "union", "enum class", "enum"] {
                guard line.hasPrefix(keyword) else { continue }
                let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                let name = leadingIdentifier(rest)
                guard let name, !name.isEmpty, name != "class" else { continue }
                let kind: OutlineKind = keyword.hasPrefix("struct") || keyword.hasPrefix("union")
                    ? .structure
                    : (keyword.hasPrefix("enum") ? .enumeration : .class)
                add(name, nil, kind, lineNumber)
                break
            }

            // Global variables: `Type name = …;` / `Type name;` at column 0 only,
            // so locals inside a function body do not clutter the outline.
            if rawLine.first.map({ $0 != " " && $0 != "\t" }) == true,
               line.hasSuffix(";"), !line.contains("("),
               let declaration = globalVariable(line) {
                add(declaration, nil, .variable, lineNumber)
            }

            // Functions: `Type name(args) {` or `Type name(args);`, at any indent.
            guard !line.hasPrefix("//") else { continue }
            if let open = line.firstIndex(of: "("),
               let name = identifierBeforeParen(line, open: open),
               !isControlFlow(name),
               !line.hasSuffix(";") || hasTypePrefix(line, name: name) {
                let params = parameterList(line, from: open)
                add(name, params, .function, lineNumber)
            }
        }
        return items
    }

    /// `Type name = …;` or `Type name;` — a plausible global declaration.
    private static func globalVariable(_ line: String) -> String? {
        let body = line.hasSuffix(";") ? String(line.dropLast()) : line
        let stopped = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = stopped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2, parts.count <= 4 else { return nil }
        guard let name = parts.last, leadingIdentifier(name) == name else { return nil }
        let typeToken = parts[0]
        let looksLikeType = typeToken.contains("::") || typeToken.contains("<")
            || typeToken.first.map { $0.isUppercase } == true
            || ["int", "double", "float", "char", "bool", "long", "string", "auto"].contains(typeToken)
        guard looksLikeType else { return nil }
        guard !isControlFlow(name), name != "return" else { return nil }
        // A statement inside a function ends with `)` or a call; skip those shapes.
        guard !body.hasSuffix(")") else { return nil }
        return name
    }

    private static func identifierBeforeParen(_ line: String, open: String.Index) -> String? {
        var end = open
        while end > line.startIndex, line[line.index(before: end)] == " " { end = line.index(before: end) }
        var start = end
        while start > line.startIndex {
            let character = line[line.index(before: start)]
            if character.isLetter || character.isNumber || character == "_" || character == "~" {
                start = line.index(before: start)
            } else {
                break
            }
        }
        guard start < end else { return nil }
        let name = String(line[start..<end])
        return name.isEmpty ? nil : name
    }

    /// A definition has a return type before the name; a bare call does not.
    private static func hasTypePrefix(_ line: String, name: String) -> Bool {
        guard let range = line.range(of: name) else { return false }
        let prefix = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return !prefix.isEmpty || name.hasSuffix("::" + name) == false
    }

    private static func parameterList(_ line: String, from open: String.Index) -> String? {
        guard let close = line[open...].firstIndex(of: ")") else { return nil }
        let inner = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        // `main()` reads better than `main ()`; the parentheses only earn their
        // space when they carry parameters.
        return inner.isEmpty ? nil : "(\(inner))"
    }

    private static func leadingIdentifier(_ text: String) -> String? {
        var result = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                result.append(character)
            } else {
                break
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func isControlFlow(_ name: String) -> Bool {
        ["if", "for", "while", "switch", "catch", "return", "sizeof", "do"].contains(name)
    }
}
