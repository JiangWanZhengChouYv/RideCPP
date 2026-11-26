import XCTest
@testable import EditorCore

/// Guards against the editor inventing errors: correct code must stay clean.
///
/// These run the real `clangd`, so they are the only tests that can catch a wrong
/// fallback language standard or a missing `bits/stdc++.h`, both of which made
/// perfectly valid competitive-programming code light up red.
final class ClangdFalsePositiveTests: XCTestCase {

    /// Generous: clangd must start, build a preamble and parse.
    private let timeout: TimeInterval = 25

    private func isClangdAvailable() -> Bool {
        ClangdSession.findClangd() != nil
    }

    /// Collects the last diagnostics clangd publishes for one source string.
    private func diagnostics(for source: String,
                             fileManager: FileManager = .default) throws -> [LSPDiagnostic] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-fp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("case.cpp")
        try source.write(to: file, atomically: true, encoding: .utf8)

        guard let provider = SemanticCompletionProvider(workingDirectory: directory,
                                                        standard: "c++17") else {
            throw XCTSkip("clangd not available")
        }
        let published = expectation(description: "clangd published diagnostics")
        final class Box: @unchecked Sendable {
            var latest: [LSPDiagnostic] = []
        }
        let box = Box()
        provider.onDiagnostics = { _, items, _ in
            box.latest = items
            published.fulfill()
        }
        provider.syncDocument(text: source, fileURL: file)
        wait(for: [published], timeout: timeout)
        // Let any follow-up publish (preamble rebuild) replace the first result.
        Thread.sleep(forTimeInterval: 0.8)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return box.latest
    }

    /// The header GCC ships and Apple's toolchain does not. Without a stand-in,
    /// every `std` name in the file is reported as undeclared.
    func testBitsHeaderProducesNoErrors() throws {
        guard isClangdAvailable() else { throw XCTSkip("clangd not available") }
        let source = """
        #include <bits/stdc++.h>
        using namespace std;

        int main() {
            int n;
            cin >> n;
            vector<int> a(n);
            for (int &x : a) cin >> x;
            sort(a.begin(), a.end());
            long long sum = accumulate(a.begin(), a.end(), 0LL);
            cout << sum << endl;
            return 0;
        }
        """
        let errors = try diagnostics(for: source).filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,
                      "valid code reported errors: \(errors.map { "\($0.code ?? "-"): \($0.message)" })")
    }

    /// clangd defaults to C++14; the editor compiles with C++17.
    func testModernCxxProducesNoErrors() throws {
        guard isClangdAvailable() else { throw XCTSkip("clangd not available") }
        let source = """
        #include <vector>
        #include <string>
        #include <optional>
        #include <map>

        struct P { int x; int y; };

        int main() {
            auto [a, b] = std::make_pair(1, 2);
            std::optional<int> o = 3;
            if (auto v = o; v.has_value()) { (void)v; }
            std::map<std::string, std::vector<int>> m;
            m["k"].push_back(a + b);
            P p{1, 2};
            auto f = [&](int n) { return n * p.x; };
            return f(2);
        }
        """
        let errors = try diagnostics(for: source).filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,
                      "C++17 code reported errors: \(errors.map { "\($0.code ?? "-"): \($0.message)" })")
    }

    /// The other half of the contract: suppressing false positives must not
    /// suppress real ones.
    func testRealErrorIsStillReported() throws {
        guard isClangdAvailable() else { throw XCTSkip("clangd not available") }
        let source = """
        #include <bits/stdc++.h>
        using namespace std;

        struct Point { int x; int y; };

        int main() {
            Point p;
            p.notAMember();
            return 0;
        }
        """
        let errors = try diagnostics(for: source).filter { $0.severity == .error }
        XCTAssertEqual(errors.count, 1, "expected exactly the missing-member error, got \(errors.count)")
        XCTAssertTrue(errors.contains { $0.code == "no_member" },
                      "expected no_member, got \(errors.map { $0.code ?? "-" })")
    }

    /// Filters out false positives from walrus operator etc.
    func testCompatibilityHeaderCoversCommonHeaders() throws {
        guard let directory = ClangdSession.prepareCompatibilityHeaders() else {
            throw XCTSkip("cannot write compatibility headers")
        }
        let header = URL(fileURLWithPath: directory).appendingPathComponent("bits/stdc++.h")
        let contents = try String(contentsOf: header, encoding: .utf8)
        for expected in ["<vector>", "<string>", "<algorithm>", "<iostream>", "<numeric>"] {
            XCTAssertTrue(contents.contains(expected), "compatibility header missing \(expected)")
        }
    }
}
