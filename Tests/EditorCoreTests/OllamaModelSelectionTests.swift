import XCTest
@testable import EditorCore

/// Model choice: the lightest code model is the default, and any installed one
/// can be selected.
final class OllamaModelSelectionTests: XCTestCase {

    func testDefaultModelIsTheLightestCodeModel() {
        XCTAssertEqual(OllamaClient.defaultModels.first, "qwen2.5-coder:0.5b",
                       "the default must stay the cool, quick option")
        XCTAssertTrue(OllamaClient.defaultModels.contains("qwen2.5-coder:1.5b"),
                      "the larger model must remain available")
    }

    /// Selecting a model by name must reach the request unchanged.
    func testExplicitModelOverridesTheDefault() {
        guard let client = OllamaClient(config: OllamaClient.Config(
            preferredModels: ["qwen2.5-coder:0.5b"])) as OllamaClient? else {
            return XCTFail("client")
        }
        XCTAssertEqual(client.config.preferredModels.first, "qwen2.5-coder:0.5b")
        // The prompt builder is what a chosen model is given.
        let prompt = OllamaClient.prompt(prefix: "for", suffix: "}")
        XCTAssertTrue(prompt.hasPrefix("<|fim_prefix|>"))
        XCTAssertTrue(prompt.contains("<|fim_middle|>"))
    }

    func testPromptUsesFillInTheMiddle() {
        let prompt = OllamaClient.prompt(prefix: "int a", suffix: "b;")
        XCTAssertEqual(prompt, "<|fim_prefix|>int a<|fim_suffix|>b;<|fim_middle|>")
    }
}
