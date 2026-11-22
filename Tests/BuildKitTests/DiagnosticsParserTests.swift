import XCTest
@testable import BuildKit

final class DiagnosticsParserTests: XCTestCase {

    func testClangErrorWithColumn() {
        let output = "/tmp/main.cpp:12:5: error: use of undeclared identifier 'foo'"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = diagnostics[0]
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.file, "/tmp/main.cpp")
        XCTAssertEqual(diagnostic.line, 12)
        XCTAssertEqual(diagnostic.column, 5)
        XCTAssertEqual(diagnostic.message, "use of undeclared identifier 'foo'")
    }

    func testGCCWarningWithColumn() {
        let output = "main.cpp:3:9: warning: unused variable 'x' [-Wunused-variable]"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .warning)
        XCTAssertEqual(diagnostics[0].line, 3)
        XCTAssertEqual(diagnostics[0].column, 9)
    }

    func testDiagnosticWithoutColumn() {
        let output = "main.cpp:7: error: expected ';'"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].line, 7)
        XCTAssertEqual(diagnostics[0].column, 1)
    }

    func testFatalErrorIsErrorSeverity() {
        let output = "main.cpp:1:10: fatal error: 'missing.h' file not found"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
    }

    func testPathWithSpaces() {
        let output = "/Users/me/My Projects/main.cpp:4:2: error: bad"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics[0].file, "/Users/me/My Projects/main.cpp")
    }

    func testIncludeContextIsIgnored() {
        let output = """
        In file included from main.cpp:2:
        /usr/include/vector:10:1: error: real problem
        required from here
        """
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].message, "real problem")
    }

    func testCaretLinesAreIgnored() {
        let output = """
        main.cpp:3:5: error: bad
            ^
            ~~~~
        """
        XCTAssertEqual(DiagnosticsParser.parse(output).count, 1)
    }

    func testNotesAreParsed() {
        let output = "main.cpp:9:3: note: candidate function not viable"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics[0].severity, .note)
    }

    func testMultipleDiagnosticsPreserveOrder() {
        let output = """
        main.cpp:1:1: error: first
        main.cpp:2:2: warning: second
        main.cpp:3:3: error: third
        """
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.map(\.message), ["first", "second", "third"])
    }

    func testShortFormsFromHomebrewGCC() {
        // Homebrew GCC 13+ prints a slightly different prefix ("error: " with a
        // trailing space after the severity is the same, but it may also use
        // "warning: " for notes).
        let output = "/opt/homebrew/bin/../include/c++/16/bits/stl_algobase.h:1200:5: note: here"
        let diagnostics = DiagnosticsParser.parse(output)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .note)
    }

    func testMatchingByRelativePath() {
        let output = "main.cpp:1:1: error: bad"
        let diagnostics = DiagnosticsParser.parse(output)
        let matched = DiagnosticsParser.diagnostics(diagnostics,
                                                    matching: "/tmp/project/main.cpp",
                                                    workingDirectory: "/tmp/project")
        XCTAssertEqual(matched.count, 1)
    }

    func testMatchingRejectsOtherFiles() {
        let output = "other.cpp:1:1: error: bad"
        let diagnostics = DiagnosticsParser.parse(output)
        let matched = DiagnosticsParser.diagnostics(diagnostics,
                                                    matching: "/tmp/project/main.cpp",
                                                    workingDirectory: "/tmp/project")
        XCTAssertTrue(matched.isEmpty)
    }

    func testCanonicalPathStandardizes() {
        XCTAssertEqual(DiagnosticsParser.canonicalPath("/tmp/./a/../b.cpp", workingDirectory: nil), "/tmp/b.cpp")
        XCTAssertEqual(DiagnosticsParser.canonicalPath("b.cpp", workingDirectory: "/tmp"), "/tmp/b.cpp")
    }

    func testEmptyOutputHasNoDiagnostics() {
        XCTAssertTrue(DiagnosticsParser.parse("").isEmpty)
        XCTAssertTrue(DiagnosticsParser.parse("garbage without location").isEmpty)
    }
}
