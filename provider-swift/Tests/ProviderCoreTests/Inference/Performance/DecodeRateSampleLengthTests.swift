import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Only a request that generated at least 32 tokens sets the published decode
/// rate (`observed_decode_tps`). Completed requests run through a scripted
/// engine; no model or GPU is involved.
@Suite("Decode rate sample length")
struct DecodeRateSampleLengthTests {
    private func makeBridge() -> (EngineV2Bridge, PrefillScriptEngine) {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], admissionFixes: true)
        return (bridge, engine)
    }

    /// Completes one request that generated `tokens` tokens over 0.1 s of
    /// decode, so its measured rate is `(tokens - 1) * 10` tok/s.
    private func serve(_ bridge: EngineV2Bridge, _ engine: PrefillScriptEngine, tokens: Int,
                       id: String) async throws {
        let request = ChatCompletionRequest(model: "gpt-oss-20b",
            messages: [.init(role: "user", content: "hi")], max_tokens: 2_048)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
            request: request, requestId: id)
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.last)
        var usage = CBv2Usage(promptTokens: 200, completionTokens: tokens)
        var timing = CBv2RequestTiming()
        timing.firstTokenNanos = 1_000_000
        timing.lastTokenNanos = 101_000_000
        timing.lastTokenUptimeNanos = DispatchTime.now().uptimeNanoseconds
        timing.decodeSteps = UInt32(tokens - 1)
        usage.timing = timing
        continuation.yield(.finished(reason: .stop, usage: usage))
        continuation.finish()
        await consumer.value
    }

    @Test("a slot that served only short requests publishes what a slot with no samples publishes")
    func coldSlotKeepsNoSampleValue() async throws {
        let (bridge, engine) = makeBridge()
        let before = await bridge.backendSlotCapacity()
        for (index, tokens) in [2, 8, 16, 31].enumerated() {
            try await serve(bridge, engine, tokens: tokens, id: "short-\(index)")
        }
        let after = await bridge.backendSlotCapacity()
        #expect(after.observedDecodeTps == before.observedDecodeTps)
        #expect(after.performanceMeasurements?.decode == before.performanceMeasurements?.decode)
        #expect(await bridge.ewmaInitialized == false)
        #expect(await bridge.performanceMeasurements.rateExpiration("decode") == nil)
        // The work itself is still counted.
        #expect(after.telemetry?.generationRequestsTotal == 4)
        await bridge.shutdown()
    }

    @Test("31 tokens leave the published rate unchanged; 32 and 33 update it as before")
    func boundaryAt32Tokens() async throws {
        let alpha = 0.3
        let (bridge, engine) = makeBridge()
        let empty = await bridge.backendSlotCapacity()
        try await serve(bridge, engine, tokens: 31, id: "tokens-31")
        let after31 = await bridge.backendSlotCapacity()
        #expect(after31.observedDecodeTps == empty.observedDecodeTps)
        #expect(await bridge.observedDecodeTpsEwma == 0)

        try await serve(bridge, engine, tokens: 32, id: "tokens-32")
        // The first counted sample seeds the estimate at its own rate.
        #expect(await bridge.observedDecodeTpsEwma == 310)
        #expect(await bridge.backendSlotCapacity().observedDecodeTps == 310)
        let expiration32 = try #require(await bridge.performanceMeasurements.rateExpiration("decode"))

        try await serve(bridge, engine, tokens: 31, id: "tokens-31-again")
        #expect(await bridge.observedDecodeTpsEwma == 310)
        #expect(await bridge.backendSlotCapacity().observedDecodeTps == 310)
        #expect(await bridge.performanceMeasurements.rateExpiration("decode") == expiration32)

        try await serve(bridge, engine, tokens: 33, id: "tokens-33")
        let expected = alpha * 320 + (1 - alpha) * 310
        #expect(await bridge.observedDecodeTpsEwma == expected)
        #expect(await bridge.backendSlotCapacity().observedDecodeTps == expected)
        await bridge.shutdown()
    }

    @Test("a short request after long ones leaves the published rate unchanged")
    func shortTailAfterLongRequests() async throws {
        let (bridge, engine) = makeBridge()
        try await serve(bridge, engine, tokens: 801, id: "long-1")
        try await serve(bridge, engine, tokens: 1_001, id: "long-2")
        let before = await bridge.backendSlotCapacity()
        let ewma = await bridge.observedDecodeTpsEwma
        let expiration = await bridge.performanceMeasurements.rateExpiration("decode")
        #expect(ewma > 8_000)
        // A two-token reply, measured at 10 tok/s.
        try await serve(bridge, engine, tokens: 2, id: "short-tail")
        let after = await bridge.backendSlotCapacity()
        #expect(await bridge.observedDecodeTpsEwma == ewma)
        #expect(after.observedDecodeTps == before.observedDecodeTps)
        #expect(after.performanceMeasurements?.decode?.tokensPerSecond
            == before.performanceMeasurements?.decode?.tokensPerSecond)
        #expect(after.performanceMeasurements?.decode?.sampleCount
            == before.performanceMeasurements?.decode?.sampleCount)
        #expect(await bridge.performanceMeasurements.rateExpiration("decode") == expiration)
        await bridge.shutdown()
    }
}
