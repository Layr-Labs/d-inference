import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Startup warmup performance evidence", .serialized)
struct StartupPerformanceEvidenceTests {
    private func fixture() -> (EngineV2Bridge, PrefillScriptEngine) {
        let engine = PrefillScriptEngine()
        return (EngineV2Bridge(engine: engine, modelId: "startup-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: []), engine)
    }

    private func waitForSubmission(_ engine: PrefillScriptEngine, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.continuations.count < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(engine.continuations.count == count)
    }

    private func finish(_ engine: PrefillScriptEngine, index: Int, tokens: Int, milliseconds: UInt64) {
        engine.completeColdPrefill(index: index, milliseconds: milliseconds)
        let continuation = engine.continuations[index]
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(reason: .length,
            usage: CBv2Usage(promptTokens: tokens, completionTokens: 1)))
        continuation.finish()
    }

    @Test("the real startup adapter does not turn one-token first-use timing into a deadline rate")
    func warmupDoesNotSeedDeadlineOrHeartbeat() async throws {
        let (bridge, engine) = fixture()
        let adapter = MultiModelBatchSchedulerEngine(registryProvider: {
            ["startup-fixture": .init(tokenizer: TokenizerHandle(PrefillStubTokenizer()),
                engineV2Bridge: bridge)]
        }, measurementPurpose: .startupWarmup)
        let service = MLXOpenAIService(engine: adapter)
        let request = OpenAIChatCompletionRequest(model: "startup-fixture",
            messages: [.init(role: .user, content: .text("Hi"))],
            stream: true, temperature: 0, maxTokens: 1)
        let warmup = Task { () throws -> Int in
            let frames = try await service.streamChatCompletionFrames(request: request)
            var count = 0
            for try await _ in frames { count += 1 }
            return count
        }
        try await waitForSubmission(engine, count: 1)
        // This valid but tiny 300-token/s sample previously became the global
        // model rate; a large prompt was then refused before it could refresh it.
        finish(engine, index: 0, tokens: 3, milliseconds: 10)
        #expect(try await warmup.value > 0)
        let snapshot = await bridge.backendSlotCapacity()
        #expect(snapshot.observedPrefillTps == 0)
        #expect(snapshot.observedDecodeTps == 0)
        #expect(snapshot.performanceMeasurements?.isolatedPrefill == nil)
        #expect(await bridge.firstTokenDeadlineAdmission(
            deadline: .init(relativeBudgetMilliseconds: 16_000), isMultimodal: false) == nil)

        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 200),
            request: ChatCompletionRequest(model: "startup-fixture", messages: [], max_tokens: 1),
            requestId: "ordinary")
        finish(engine, index: 1, tokens: 200, milliseconds: 50)
        for await _ in stream {}
        #expect(await bridge.backendSlotCapacity().observedPrefillTps == 4_000)
        await bridge.shutdown()
    }

    @Test("a warmup never suppresses another request's valid measurement")
    func warmupScopeIsPerRequest() async throws {
        let (bridge, engine) = fixture()
        let warmup = await bridge.submitTokenized(promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(model: "startup-fixture", messages: [], max_tokens: 1),
            requestId: "warmup", measurementPurpose: .startupWarmup)
        let ordinary = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 200),
            request: ChatCompletionRequest(model: "startup-fixture", messages: [], max_tokens: 1),
            requestId: "ordinary")
        finish(engine, index: 1, tokens: 200, milliseconds: 50)
        for await _ in ordinary {}
        finish(engine, index: 0, tokens: 3, milliseconds: 10)
        for await _ in warmup {}
        let snapshot = await bridge.backendSlotCapacity()
        #expect(snapshot.observedPrefillTps == 4_000)
        // Overlapping real work remains a contended sample, never a fabricated
        // isolated rate. Excluding warmup does not erase physical contention.
        #expect(snapshot.performanceMeasurements?.contendedPrefill?.sampleCount == 1)
        #expect(snapshot.performanceMeasurements?.isolatedPrefill == nil)
        await bridge.shutdown()
    }
}
