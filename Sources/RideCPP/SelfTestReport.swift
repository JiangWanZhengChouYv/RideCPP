import Foundation

/// Collects self-test results and writes the JSON report.
///
/// Extracted from `SelfTestRunner` so the runner only describes checks, and the
/// reporting format lives in one place. Keeping the two apart also keeps each file
/// to a readable size.
struct SelfTestReport {

    struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    private(set) var checks: [Check] = []
    let path: String

    init(path: String) {
        self.path = path
    }

    var allPassed: Bool { checks.allSatisfy(\.passed) }

    /// Records one check and echoes it to stdout for the CI log.
    mutating func record(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(name: name, passed: passed, detail: detail))
        print("[selftest] \(passed ? "PASS" : "FAIL") \(name) — \(detail)")
    }

    /// Writes the JSON report and prints the summary line.
    func finish() {
        let json = Self.json(checks: checks, passed: allPassed)
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("[selftest] \(allPassed ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED") -> \(path)")
    }

    /// Escapes a string for the JSON report and for single-line log output.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Builds the report body. Kept pure so it can be tested without a run.
    static func json(checks: [Check], passed: Bool) -> String {
        let entries = checks.map { check in
            """
                {"name": "\(escaped(check.name))", "passed": \(check.passed), \
            "detail": "\(escaped(check.detail))"}
            """
        }
        return """
        {
          "passed": \(passed),
          "checks": [
        \(entries.joined(separator: ",\n"))
          ]
        }

        """
    }
}
