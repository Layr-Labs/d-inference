import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Inkling 2 Mini's slot serves the checkpoint's context (`model_max_length`,
/// 1,048,576 tokens of prompt plus output, as `KVEstimation` parses it). A long
/// prompt reaches the engine with the output it asked for: the DSpark
/// drafter's per-request pool is now sized from the paged pool's own segment
/// arithmetic, so prompt plus output past 41,432 tokens no longer fails.
@Suite("Inkling 2 serves its checkpoint's context")
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

    @Test func theWindowIsTheCheckpointContext() throws {
        #expect(try Self.window() == 1_048_576)
    }

    @Test(arguments: [
        // (prompt, max_tokens asked): the engine is asked for exactly that output
        (40_000, 4_096),
        (45_984, 64),
        (46_966, 16),
        (86_965, 64),
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
}
