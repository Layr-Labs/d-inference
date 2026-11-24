import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Inkling 2 Mini's slot serves 524,288 tokens of prompt plus output, half the
/// checkpoint's `model_max_length` (as `KVEstimation` parses it). A long prompt
/// inside the window reaches the engine with the output it asked for, an
/// output that would pass the window is cut to what the prompt leaves, and a
/// prompt that fills the window is refused as a context error (400) without
/// reaching the engine.
@Suite("Inkling 2 serves a 524,288-token window")
struct Inkling2ContextWindowTests {
    /// The window as the slot factory derives it: the pinned configuration's
    /// architecture, as `defaultMaxTokensContextLimit`.
    private static func window() throws -> Int {
        let url = try #require(Bundle.module.url(
            forResource: "config.json", withExtension: nil, subdirectory: "Fixtures/Inkling2"))
        return try #require(KVEstimation.parseModelArchitecture(at: url).maxContextLength)
    }

    private static func bridge(_ engine: OutputRecordingEngine) throws -> EngineV2Bridge {
        EngineV2Bridge(engine: engine, modelId: "thinkingmachines/Inkling-2-Mini",
            tokenizer: TokenizerHandle(FixedLengthTokenizer()), eosTokenIds: [], defaultMaxTokens: 32_768,
            defaultMaxTokensContextLimit: try window(), maxConcurrentRequests: 1, kvBudget: roomyKVBudget())
    }

    @Test func theWindowIsHalfTheCheckpointContext() throws {
        #expect(try Self.window() == 524_288)
        #expect(Inkling2ModelIdentity.servedContextTokens == 524_288)
    }

    /// The window is Inkling 2's alone: every other served architecture parses
    /// its own declared context, unchanged.
    @Test(arguments: ["flint", "gemma4", "gemma4_text", "glm5_next", "gpt_oss", "mimo_v2", "nemotron_h",
                      "nemotron_h_omni", "prism_hadamard_qwen35", "qwen3_5", "qwen3_5_moe", "qwen3_vl_moe",
                      "qwen4_exp", "inkling2"])
    func otherArchitecturesKeepTheirContext(modelType: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkling-window-\(modelType)-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let config: [String: Any] = ["model_type": modelType, "max_position_embeddings": 1_048_576,
                                     "hidden_size": 4_096, "num_hidden_layers": 32,
                                     "num_attention_heads": 32, "num_key_value_heads": 8]
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        #expect(KVEstimation.parseModelArchitecture(at: url).maxContextLength == 1_048_576)
    }

    @Test(arguments: [
        // (prompt, max_tokens asked): the engine is asked for exactly that output
        (40_000, 4_096),
        (45_984, 64),
        (46_966, 16),
        (86_965, 64),
        (262_079, 64),
        (524_222, 64),
    ])
    func aLongPromptKeepsItsOutput(prompt: Int, requested: Int) async throws {
        let engine = OutputRecordingEngine()
        let bridge = try Self.bridge(engine)
        let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
            request: .init(model: "thinkingmachines/Inkling-2-Mini", messages: [], max_tokens: requested),
            requestId: "inkling-long-prompt", firstContentDeadline: nil)
        for await _ in stream {}
        #expect(engine.submittedOutputs == [requested])
        await bridge.shutdown()
    }

    @Test(arguments: [
        // (prompt, max_tokens asked, max_tokens the engine is asked for)
        (524_000, 4_096, 288),
        (524_287, 64, 1),
    ])
    func anOutputPastTheWindowIsCut(prompt: Int, requested: Int, output: Int) async throws {
        let engine = OutputRecordingEngine()
        let bridge = try Self.bridge(engine)
        let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
            request: .init(model: "thinkingmachines/Inkling-2-Mini", messages: [], max_tokens: requested),
            requestId: "inkling-window", firstContentDeadline: nil)
        for await _ in stream {}
        #expect(engine.submittedOutputs == [output])
        await bridge.shutdown()
    }

    @Test(arguments: [524_288, 600_000, 1_048_511])
    func aPromptThatFillsTheWindowIsAContextError(prompt: Int) async throws {
        let engine = OutputRecordingEngine()
        let bridge = try Self.bridge(engine)
        do {
            let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: "thinkingmachines/Inkling-2-Mini", messages: [], max_tokens: 64),
                requestId: "inkling-over-window", firstContentDeadline: nil)
            for await _ in stream {}
            Issue.record("a \(prompt)-token prompt reached the engine")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == windowRefusal(524_288))
            #expect(ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation).statusCode == 400)
            #expect(InferenceRefusalReason(promptRefusal: error) == .requestExceedsContext)
        }
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }
}
