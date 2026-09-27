import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

private final class DiffusionRawCaseBundleAnchor: NSObject {}

/// Synthetic request attribution before parsing. Use an isolated guarded lane;
/// raw output is private diagnostic data, not a semantic or hosted gate pass.
@Suite("DiffusionGemma retained API case attribution", .serialized)
struct DiffusionGemmaRawCaseLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_RAW_CASE_DIAGNOSTIC"] == "1"))
    func retainedSyntheticCasesExposeGenerationAndParserBoundaries() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        let cases = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_RAW_CASES_DIR"]))
        _ = Bundle(for: DiffusionRawCaseBundleAnchor.self).bundleURL
        let container = try await DiffusionGemmaModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        for name in ["chat-opaque-off-plain", "chat-opaque-on-plain", "responses-four-on-stream"] {
            let envelope = try #require(try JSONSerialization.jsonObject(
                with: Data(contentsOf: cases.appendingPathComponent(name + ".json"))) as? [String: Any])
            try #require(envelope["case"] as? String == name)
            let body = try #require(envelope["request"] as? [String: Any])
            try #require(body["model"] as? String == "mlx-community/diffusiongemma-26B-A4B-it-4bit")
            let encoded = try JSONSerialization.data(withJSONObject: body)
            let request: OpenAIChatCompletionRequest
            if name.hasPrefix("responses-") {
                request = try JSONDecoder().decode(OpenAIResponseRequest.self, from: encoded).chatCompletionRequest
            } else {
                request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: encoded)
            }
            let payload = try JSONEncoder().encode(request)
            let requestedTokens = try #require(request.maxTokens)
            let originalSeed = request.seed
            let seeds: [UInt64] = originalSeed.map { [$0] } ?? [7419, 7420, 7421]
            for seed in seeds {
                let data = try await container.perform { context -> Data in
                    let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                        payload, tokenizer: context.tokenizer, modelType: "diffusion_gemma")
                    let base = context.generationConfiguration
                    let generation = try DiffusionGemmaGenerationConfiguration(maxNewTokens: requestedTokens,
                        maxDenoisingSteps: base.maxDenoisingSteps, sampler: base.sampler,
                        minimumTemperature: base.minimumTemperature, maximumTemperature: base.maximumTemperature,
                        stabilityThreshold: base.stabilityThreshold, confidenceThreshold: base.confidenceThreshold,
                        bosTokenId: base.bosTokenId, padTokenId: base.padTokenId, eosTokenIds: base.eosTokenIds)
                    let result = try context.model.generateNative(
                        promptTokenIds: MLXArray(tokens.map(Int32.init)).reshaped(1, tokens.count),
                        generation: generation, seed: seed, prefillChunkSize: 512)
                    let raw = context.tokenizer.decode(tokenIds: result.tokenIds.map(Int.init), skipSpecialTokens: false)
                    let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "diffusion_gemma")
                    let handler = try ToolStreamPreparation.makeHandler(request: request,
                        prepared: prepared, modelType: "diffusion_gemma")
                    var router = NativeToolStreamRouter(handler: handler,
                        requiresToolCall: prepared.requiresToolCall, nativePrefix: nil, nativeGemmaChannels: true,
                        nativeGemmaReasoningEnabled: DiffusionGemmaReasoningControl.enabled(for: request, controls: .init()))
                    var errorText = ""
                    do {
                        _ = try router.process(raw)
                        _ = try router.finishText()
                    } catch { errorText = String(describing: error) }
                    let calls = handler?.finish() ?? []
                    do { try ToolConstraintValidation.validate(calls, prepared: prepared) }
                    catch { errorText += " | " + String(describing: error) }
                    let parsed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(calls))
                    return try JSONSerialization.data(withJSONObject: ["case": name, "seed": seed,
                        "seedWasInAPIRequest": originalSeed != nil, "promptTokenIds": tokens,
                        "renderedPrompt": context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false),
                        "rawTokenIds": result.tokenIds, "rawText": raw, "parsedCalls": parsed,
                        "validationError": errorText, "finish": result.finishReason,
                        "scope": "native diagnostic before HTTP; unseeded API failures are not exact-seed replays",
                        "qualityQualification": false], options: [.sortedKeys])
                }
                print("DIFFUSION_RAW_CASE " + String(decoding: data, as: UTF8.self))
            }
        }
    }
}
