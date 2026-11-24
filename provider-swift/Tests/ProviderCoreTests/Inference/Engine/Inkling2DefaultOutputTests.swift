import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A request to Inkling 2 Mini that names no `max_tokens` may write 65,536
/// tokens (cut to what its prompt leaves of the window), not the standard
/// request's 32,768: its long reasoning runs past 32,768 and was cut off as
/// `length`. A request that names `max_tokens` is unchanged, and so is every
/// other model's default.
@Suite("Inkling 2 default output")
struct Inkling2DefaultOutputTests {
    /// The served window as the slot factory derives it from the pinned configuration.
    private static func window() throws -> Int {
        let url = try #require(Bundle.module.url(
            forResource: "config.json", withExtension: nil, subdirectory: "Fixtures/Inkling2"))
        return try #require(KVEstimation.parseModelArchitecture(at: url).maxContextLength)
    }

    @Test(arguments: [
        // (window, Inkling 2, slot default)
        (524_288, true, 65_536),
        (40_000, true, 40_000),
        (524_288, false, 32_768),
        (262_144, false, 32_768),
    ])
    func theSlotDefaultIsTheModelsDefaultOutputCutToTheWindow(window: Int, inkling: Bool, output: Int) {
        #expect(SlotSizingSnapshot.defaultMaxTokens(maxContext: window, servesInkling2: inkling, fallback: 4_096)
            == output)
    }

    @Test func anUnknownWindowKeepsTheFallback() {
        #expect(SlotSizingSnapshot.defaultMaxTokens(maxContext: 0, servesInkling2: true, fallback: 4_096) == 4_096)
    }

    private static func bridge(_ engine: OutputRecordingEngine, inkling: Bool, window: Int) -> EngineV2Bridge {
        EngineV2Bridge(engine: engine, modelId: inkling ? "thinkingmachines/Inkling-2-Mini" : "other/model",
            tokenizer: TokenizerHandle(FixedLengthTokenizer()), eosTokenIds: [],
            defaultMaxTokens: SlotSizingSnapshot.defaultMaxTokens(
                maxContext: window, servesInkling2: inkling, fallback: 4_096),
            defaultMaxTokensContextLimit: window, maxConcurrentRequests: 1, kvBudget: roomyKVBudget())
    }

    /// The engine request, and so the admission reservation, carries the output resolved here.
    @Test(arguments: [
        // (prompt, max_tokens asked, max_tokens the engine is asked for)
        (1_000, Optional<Int>.none, 65_536),
        (1_000, Optional(1_000), 1_000),
        (1_000, Optional(100_000), 100_000),
        (500_000, Optional<Int>.none, 24_288),
    ])
    func anInklingRequestWithoutMaxTokensMayWrite65536(prompt: Int, requested: Int?, output: Int) async throws {
        let engine = OutputRecordingEngine()
        let bridge = Self.bridge(engine, inkling: true, window: try Self.window())
        let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
            request: .init(model: "thinkingmachines/Inkling-2-Mini", messages: [], max_tokens: requested),
            requestId: "inkling-default-output", firstContentDeadline: nil)
        for await _ in stream {}
        #expect(engine.submittedOutputs == [output])
        await bridge.shutdown()
    }

    @Test func anotherModelKeepsThe32768Default() async throws {
        let engine = OutputRecordingEngine()
        let bridge = Self.bridge(engine, inkling: false, window: 262_144)
        let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 1_000),
            request: .init(model: "other/model", messages: [], max_tokens: nil),
            requestId: "other-default-output", firstContentDeadline: nil)
        for await _ in stream {}
        #expect(engine.submittedOutputs == [32_768])
        await bridge.shutdown()
    }
}
