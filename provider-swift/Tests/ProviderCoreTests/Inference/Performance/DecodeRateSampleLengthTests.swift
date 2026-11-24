import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Only a request that generated at least 32 tokens moves the published decode
/// rate (`observed_decode_tps`) and, once such a request has moved it, the
/// deadline decode rate. A shorter one still feeds the rate's age, and moves the
/// deadline rate until then. Completed requests run through a scripted engine; no model
/// or GPU is involved.
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

    /// The heartbeat's encoded `observed_decode_tps` entry: nil when omitted.
    private func publishedEntry(_ capacity: BackendSlotCapacity) throws -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(capacity)) as? [String: Any])
        return object["observed_decode_tps"].map { "\($0)" }
    }

    @Test("a slot that served only short requests puts on the wire what a never-served slot does")
    func shortOnlySlotPublishesTheColdValue() async throws {
        let (cold, _) = makeBridge()
        let never = try publishedEntry(await cold.backendSlotCapacity())
        #expect(never == nil, "a never-served slot omits observed_decode_tps")
        let (bridge, engine) = makeBridge()
        for (index, tokens) in [2, 8, 16, 31].enumerated() {
            try await serve(bridge, engine, tokens: tokens, id: "short-\(index)")
        }
        #expect(try publishedEntry(await bridge.backendSlotCapacity()) == never)
        // The deadline decode rate still has its first sample, as before.
        #expect(await bridge.ewmaInitialized)
        #expect(await bridge.observedDecodeTpsEwma > 0)
        await cold.shutdown()
        await bridge.shutdown()
    }

    @Test("a short request after a counted one moves neither the published nor the deadline rate")
    func shortRequestMovesNeitherRate() async throws {
        let (bridge, engine) = makeBridge()
        try await serve(bridge, engine, tokens: 101, id: "long")
        #expect(await bridge.backendSlotCapacity().observedDecodeTps == 1_000)
        let expiration = try #require(await bridge.performanceMeasurements.rateExpiration("decode"))
        try await serve(bridge, engine, tokens: 11, id: "short")
        #expect(await bridge.backendSlotCapacity().observedDecodeTps == 1_000)
        #expect(await bridge.observedDecodeTpsEwma == 1_000)
        #expect(await bridge.observedDecodeStep.tokensPerSecond == 1_000)
        // The rate's age still refreshes.
        let refreshed = try #require(await bridge.performanceMeasurements.rateExpiration("decode"))
        #expect(refreshed >= expiration)
        await bridge.shutdown()
    }

    @Test("a short-only slot's deadline rate follows its short replies, as before")
    func shortOnlySlotDeadlineRateFollowsShortReplies() async throws {
        let alpha = 0.3
        let (bridge, engine) = makeBridge()
        try await serve(bridge, engine, tokens: 11, id: "short-first")
        #expect(await bridge.observedDecodeTpsEwma == 100)
        try await serve(bridge, engine, tokens: 5, id: "short-second")
        let second = alpha * 40 + (1 - alpha) * 100
        #expect(await bridge.observedDecodeTpsEwma == second)
        try await serve(bridge, engine, tokens: 3, id: "short-third")
        #expect(await bridge.observedDecodeTpsEwma == alpha * 20 + (1 - alpha) * second)
        await bridge.shutdown()
    }

    // It expected a later short reply to leave a rate set by a short one, which
    // froze a short-only slot's rate at its first reply; only a counted reply
    // stops short ones moving it.
    @Test("a short reply starts the deadline rate; once a counted reply has moved it, short ones leave it")
    func firstShortReplyStartsTheDeadlineRate() async throws {
        let alpha = 0.3
        let (bridge, engine) = makeBridge()
        try await serve(bridge, engine, tokens: 11, id: "short-first")
        #expect(await bridge.observedDecodeTpsEwma == 100)
        try await serve(bridge, engine, tokens: 33, id: "counted")
        let counted = alpha * 320 + (1 - alpha) * 100
        #expect(await bridge.observedDecodeTpsEwma == counted)
        try await serve(bridge, engine, tokens: 5, id: "short-after")
        #expect(await bridge.observedDecodeTpsEwma == counted)
        await bridge.shutdown()
    }

    @Test("after the decode evidence expires a short reply starts the deadline rate again")
    func shortReplyRestartsAnExpiredDeadlineRate() async {
        let (bridge, _) = makeBridge()
        let now = ContinuousClock.now
        await bridge.applyRateObservation(EngineRateObservation(phase: "decode", tps: 80, prompt: 200,
            context: 300, cache: "cold", overlap: .init(), at: now - .seconds(300), postureEpoch: nil,
            aggregate: true), requestID: "old-long", calibration: false)
        #expect(await bridge.observedDecodeTpsEwma == 80)
        await bridge.applyRateObservation(EngineRateObservation(phase: "decode", tps: 20, prompt: 200,
            context: 300, cache: "cold", overlap: .init(), at: now, postureEpoch: nil,
            aggregate: true, setsPublishedDecode: false), requestID: "short", calibration: false)
        #expect(await bridge.observedDecodeTpsEwma == 20)
        await bridge.shutdown()
    }

    @Test("31 tokens leave the published rate unchanged; 32 and 33 publish the same EWMA as every sample")
    func boundaryAt32Tokens() async throws {
        let alpha = 0.3
        // Only counted samples: the published value is the EWMA of every sample.
        let (counted, countedEngine) = makeBridge()
        try await serve(counted, countedEngine, tokens: 32, id: "tokens-32")
        #expect(await counted.backendSlotCapacity().observedDecodeTps == 310)
        #expect(await counted.observedDecodeTpsEwma == 310)
        try await serve(counted, countedEngine, tokens: 33, id: "tokens-33")
        let expected = alpha * 320 + (1 - alpha) * 310
        #expect(await counted.observedDecodeTpsEwma == expected)
        #expect(await counted.backendSlotCapacity().observedDecodeTps == expected)
        await counted.shutdown()

        // 31 tokens between them move the deadline rate only.
        let (mixed, mixedEngine) = makeBridge()
        try await serve(mixed, mixedEngine, tokens: 31, id: "tokens-31-first")
        #expect(await mixed.backendSlotCapacity().observedDecodeTps == 0)
        #expect(await mixed.observedDecodeTpsEwma == 300)
        try await serve(mixed, mixedEngine, tokens: 32, id: "tokens-32")
        #expect(await mixed.backendSlotCapacity().observedDecodeTps == 310)
        try await serve(mixed, mixedEngine, tokens: 31, id: "tokens-31-again")
        #expect(await mixed.backendSlotCapacity().observedDecodeTps == 310)
        try await serve(mixed, mixedEngine, tokens: 33, id: "tokens-33")
        #expect(await mixed.backendSlotCapacity().observedDecodeTps == expected)
        await mixed.shutdown()
    }

    @Test("short requests keep refreshing the rate's age, so a serving slot never ages out between them")
    func shortRequestsKeepTheAgeFresh() async throws {
        let (bridge, engine) = makeBridge()
        // A long sample from 2,000 s ago: on an idle slot it has aged out.
        await bridge.applyRateObservation(EngineRateObservation(phase: "decode", tps: 80, prompt: 200,
            context: 300, cache: "cold", overlap: .init(), at: .now - .seconds(2_000), postureEpoch: nil,
            aggregate: true), requestID: "old-long", calibration: false)
        #expect(await bridge.backendSlotCapacity().observedDecodeTps == 0)
        // Each short request refreshes the age as before.
        for index in 0 ..< 3 {
            let before = await bridge.performanceMeasurements.rateExpiration("decode")
            try await serve(bridge, engine, tokens: 5, id: "short-\(index)")
            let after = try #require(await bridge.performanceMeasurements.rateExpiration("decode"))
            #expect(before.map { after >= $0 } ?? true)
            // Heartbeats between requests, while the slot is idle, keep publishing a rate.
            for offset in [1, 60, 600] {
                #expect(await bridge.backendSlotCapacity(now: .now + .seconds(offset)).observedDecodeTps > 0)
            }
        }
        await bridge.shutdown()
    }
}
