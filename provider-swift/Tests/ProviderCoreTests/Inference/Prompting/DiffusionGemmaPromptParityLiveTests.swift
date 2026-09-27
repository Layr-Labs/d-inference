import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Real selected tokenizer/template, no weights or GPU inference. The shared
/// corpus remains unchanged; this isolates a native request-shape failure.
@Suite("DiffusionGemma actual prompt contract", .serialized)
struct DiffusionGemmaPromptParityLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PROMPT_PARITY"] == "1"))
    func actualTemplateAcceptsSupportedToolTurnAndSchema() async throws {
        let path = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PROMPT_DIRECTORY"]
        let corpusPath = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PROMPT_CORPUS"]
        let directory = URL(fileURLWithPath: try #require(path))
        let corpusURL = URL(fileURLWithPath: try #require(corpusPath))
        let corpus = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any])
        let cases = try #require(corpus["cases"] as? [[String: Any]])
        let fixture = try #require(cases.first { $0["id"] as? String == "gemma_tool_turn" })
        var body = try #require(fixture["body"] as? [String: Any])
        body["model"] = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
            JSONSerialization.data(withJSONObject: body), tokenizer: tokenizer, modelType: "diffusion_gemma")
        #expect(!tokens.isEmpty)
        let rendered = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        #expect(rendered.contains("weather") && rendered.contains("forecast"))
        #expect(rendered.contains("sunny now") && rendered.contains("warm tomorrow"))
        #expect(!Gemma4ToolConstraintContract.supports(modelType: "diffusion_gemma"),
            "Sharing a native tool template must not enable autoregressive constraints")
    }
}
