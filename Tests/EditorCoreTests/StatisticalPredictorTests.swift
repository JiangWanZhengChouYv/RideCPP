import XCTest
@testable import EditorCore

/// The offline predictor: fast, quiet, and never nonsense.
final class StatisticalPredictorTests: XCTestCase {

    private func makePredictor() -> StatisticalPredictor {
        // No storage URL: each test starts from an empty memory.
        StatisticalPredictor(storageURL: nil)
    }

    func testLearnsTheLinesTheUserActuallyWrites() {
        let predictor = makePredictor()
        predictor.learn(from: """
        int main() {
            for (int i = 0; i < n; ++i) {
                cout << a[i] << " ";
            }
        }
        """)
        // Give the learning queue a moment to finish.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(predictor.templateCountForTesting, 0)
        let suggestion = predictor.predict(prefixBeforeCaret: "    for",
                                           document: "int main() {\n    for",
                                           suffixAfterCaret: "\n}")
        XCTAssertEqual(suggestion, " (int i = 0; i < n; ++i) {")
    }

    /// Learned shapes win over generic ones: the user's own idiom is what they
    /// expect to see continued.
    func testLearnedShapeBeatsTheGenericTemplate() {
        let predictor = makePredictor()
        predictor.learn(from: """
        for (int i = 1; i <= n; i++) {
        """)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let suggestion = predictor.predict(prefixBeforeCaret: "for",
                                           document: "for",
                                           suffixAfterCaret: "\n")
        XCTAssertEqual(suggestion, " (int i = 1; i <= n; i++) {")
    }

    func testStructuralFallbacksForCommonConstructs() {
        let predictor = makePredictor()
        let document = "int main() {\n    int n;\n    cin >> n;\n"
        let cases: [(typed: String, expected: String)] = [
            ("for", " (int i = 0; i < n; ++i) {"),
            ("while", " (cin >> n) {"),
            ("return", " 0;"),
            ("ios", "::sync_with_stdio(false);")
        ]
        for (typed, expected) in cases {
            let got = predictor.predict(prefixBeforeCaret: typed, document: document,
                                        suffixAfterCaret: "\n")
            XCTAssertEqual(got, expected, "wrong suggestion for \(typed)")
        }
    }

    func testSuggestionUsesIdentifiersFromTheFile() {
        let predictor = makePredictor()
        let document = "int main() {\n    int n;\n    int total;\n"
        let got = predictor.predict(prefixBeforeCaret: "    cin", document: document,
                                    suffixAfterCaret: "\n")
        XCTAssertEqual(got, " >> n;")
        let cout = predictor.predict(prefixBeforeCaret: "    cout", document: document,
                                     suffixAfterCaret: "\n")
        XCTAssertEqual(cout, " << n << endl;")
    }

    func testSaysNothingWhenItHasNothingUseful() {
        let predictor = makePredictor()
        XCTAssertEqual(predictor.predict(prefixBeforeCaret: "qwerty", document: "qwerty",
                                         suffixAfterCaret: ""), "")
        XCTAssertEqual(predictor.predict(prefixBeforeCaret: "", document: "",
                                         suffixAfterCaret: ""), "")
    }

    /// A suggestion must never repeat text that is already on the line.
    func testDoesNotSuggestWhatIsAlreadyThere() {
        let predictor = makePredictor()
        predictor.learn(from: "for (int i = 0; i < n; ++i) {\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let got = predictor.predict(prefixBeforeCaret: "for",
                                    document: "for",
                                    suffixAfterCaret: " (int i = 0; i < n; ++i) {")
        XCTAssertTrue(got.isEmpty || !got.hasPrefix(" (int i = 0; i < n; ++i) {"),
                      "must not duplicate the existing text, got \(got)")
    }

    func testIgnoresCommentsAndIncludes() {
        let predictor = makePredictor()
        predictor.learn(from: """
        // for (int i = 0; i < n; ++i) {
        #include <vector>
        """)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(predictor.templateCountForTesting, 0)
    }

    func testSplitFindsTheTokenBoundary() {
        let parts = StatisticalPredictor.split("    for (int i = 0; i < n; ++i) {")
        XCTAssertEqual(parts?.prefix, "for")
        XCTAssertEqual(parts?.completion, " (int i = 0; i < n; ++i) {")
    }

    func testIdentifiersAreExtractedInOrder() {
        let names = StatisticalPredictor.identifiers(in: "int n;\nint m;\nlong long total;\n")
        XCTAssertEqual(names, ["n", "m", "total"])
    }
}
