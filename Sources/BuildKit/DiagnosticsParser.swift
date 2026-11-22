import Foundation

/// One compiler diagnostic.
public struct Diagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable, Comparable {
        case error
        case warning
        case note

        public var sortOrder: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.sortOrder < rhs.sortOrder
        }
    }

    public let id = UUID()
    public let severity: Severity
    public let file: String
    public let line: Int
    public let column: Int
    public let message: String
    /// The raw line the diagnostic came from, kept for the output panel.
    public let rawText: String

    public init(severity: Severity, file: String, line: Int, column: Int, message: String, rawText: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.rawText = rawText
    }

    /// "main.cpp:12:5"
    public var locationDescription: String {
        guard !file.isEmpty else { return "" }
        return "\(file):\(line):\(column)"
    }
}

/// Parses clang/gcc style diagnostics out of compiler output.
public enum DiagnosticsParser {

    /// Matches `path:line:col: severity: message` and the column-less variants.
    /// Handles Windows-style drive letters only incidentally; this IDE is macOS
    /// only, but paths with spaces and colons in folder names still work because
    /// the number groups anchor the match from the right.
    private static let diagnosticRegex = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(?:(\d+):)?\s*(error|warning|note|fatal error)\s*:\s*(.*)$"#,
        options: [.anchorsMatchLines]
    )

    private static let caretRegex = try! NSRegularExpression(
        pattern: #"^\s*(\^|~+)\s*$"#,
        options: [.anchorsMatchLines]
    )

    /// Parses all diagnostics in `output`, in the order they appear.
    public static func parse(_ output: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .newlines)
            guard !line.isEmpty else { continue }
            // `In file included from ...` and `required from here` are context,
            // not problems.
            if line.hasPrefix("In file included from") { continue }
            if line.contains("required from here") { continue }
            if caretRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil {
                continue
            }
            let ns = line as NSString
            guard let match = diagnosticRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges >= 6 else { continue }

            let file = ns.substring(with: match.range(at: 1))
            let lineNumber = Int(ns.substring(with: match.range(at: 2))) ?? 1
            var column = 1
            if match.range(at: 3).location != NSNotFound {
                column = Int(ns.substring(with: match.range(at: 3))) ?? 1
            }
            let severityText = ns.substring(with: match.range(at: 4))
            let message = ns.substring(with: match.range(at: 5))

            let severity: Diagnostic.Severity
            switch severityText {
            case "error", "fatal error": severity = .error
            case "warning": severity = .warning
            default: severity = .note
            }

            diagnostics.append(Diagnostic(severity: severity,
                                          file: file,
                                          line: lineNumber,
                                          column: column,
                                          message: message,
                                          rawText: line))
        }
        return diagnostics
    }

    /// Diagnostics whose file matches `sourcePath`, comparing resolved paths so
    /// clang's relative paths still line up with the document.
    public static func diagnostics(_ diagnostics: [Diagnostic],
                                  matching sourcePath: String,
                                  workingDirectory: String? = nil) -> [Diagnostic] {
        let target = canonicalPath(sourcePath, workingDirectory: nil)
        return diagnostics.filter { diagnostic in
            canonicalPath(diagnostic.file, workingDirectory: workingDirectory) == target
        }
    }

    /// Resolves a possibly relative path against a working directory and
    /// standardizes it.
    public static func canonicalPath(_ path: String, workingDirectory: String?) -> String {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        if let workingDirectory, !workingDirectory.isEmpty {
            return ((workingDirectory as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }
        return (path as NSString).standardizingPath
    }
}
