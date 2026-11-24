import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Inkling 2 Mini's slot holds every request to the window its configuration
/// is sized for (`KVEstimation`), 40,960 tokens of prompt plus output: an
/// output that would pass it is cut to what the prompt leaves, and a prompt
/// that fills it is refused as a context error (400), never sent to the
/// engine. Past 41,432 tokens the DSpark drafter's per-request pool cannot be
/// reserved, and the request failed as an untyped generation error (500).
@Suite("Inkling 2 holds every request to its served window")
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

    @Test(arguments: [
        // (prompt, max_tokens asked, max_tokens the engine is asked for)
        (40_000, 4_096, 960),
        (40_959, 64, 1),
        (36_864, 4_096, 4_096),
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

    @Test(arguments: [40_960, 46_966, 86_965])
    func aPromptThatFillsTheWindowIsAContextError(prompt: Int) async throws {
        let engine = OutputRecordingEngine()
        let bridge = try Self.bridge(engine)
        do {
            let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: "thinkingmachines/Inkling-2-Mini", messages: [], max_tokens: 16),
                requestId: "inkling-over-window", firstContentDeadline: nil)
            for await _ in stream {}
            Issue.record("a \(prompt)-token prompt reached the engine")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == windowRefusal(40_960))
            #expect(ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation).statusCode == 400)
            #expect(InferenceRefusalReason(promptRefusal: error) == .requestExceedsContext)
        }
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }
}
