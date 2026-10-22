import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Engine measurement observation ordering")
struct EngineMeasurementOrderingTests {
    @Test("late completed work cannot expire newer aggregate, qualified or shape evidence")
    func delayedObservationPreservesFreshness() throws {
        var measurements = EnginePerformanceMeasurements()
        let at = ContinuousClock.now
        let posture = UUID()
        measurements.observe("isolated_prefill", tps: 2_000, prompt: 1_000, context: 1_000,
            cache: "cold", overlap: .init(), at: at, deadlinePostureEpoch: posture)
        measurements.observe("isolated_prefill", tps: 100, prompt: 1_000, context: 1_000,
            cache: "cold", overlap: .init(), at: at - .seconds(121), deadlinePostureEpoch: posture)

        let now = at + .seconds(1)
        let snapshot = measurements.snapshot(now: now)
        let rate = try #require(snapshot.isolatedPrefill)
        // Arrival-order EWMA and completed-observation identity stay intact.
        #expect(rate.tokensPerSecond == 1_430)
        #expect(rate.sampleCount == 2)
        #expect(rate.sampleAgeMs == 1_000)
        #expect(measurements.rateExpiration("isolated_prefill") == at + .seconds(120))
        #expect(measurements.freshRate("isolated_prefill", now: now) == 1_430)
        #expect(measurements.freshIsolatedPrefillRate(promptTokens: 1_000, now: now) == 1_430)
        #expect(snapshot.workloadBuckets.first?.observation.sampleAgeMs == 1_000)
        #expect(measurements.freshDeadlineRate("isolated_prefill", postureEpoch: posture, now: now) == 1_430)
        #expect(measurements.deadlineRateExpiration("isolated_prefill", postureEpoch: posture) == at + .seconds(120))
        #expect(measurements.deadlineSnapshot(now: now, postureEpoch: posture).isolatedPrefill?.sampleAgeMs == 1_000)
        #expect(measurements.freshRate("isolated_prefill", now: at + .seconds(121)) == nil)

        // The late receipt must not manufacture an evidence gap for the next
        // genuinely newer sample and discard the current EWMA.
        measurements.observe("isolated_prefill", tps: 500, prompt: 1_000, context: 1_000,
            cache: "cold", overlap: .init(), at: at + .seconds(1), deadlinePostureEpoch: posture)
        let next = measurements.snapshot(now: at + .seconds(2)).isolatedPrefill
        #expect(next?.tokensPerSecond == 1_151)
        #expect(next?.sampleCount == 3)
        #expect(next?.sampleAgeMs == 1_000)
    }

    @Test("new and equal timestamps preserve averaging, identity and forward-gap reseeding")
    func orderedAndEqualObservations() {
        var measurements = EnginePerformanceMeasurements()
        let at = ContinuousClock.now
        for (offset, tps) in [(0, 100.0), (1, 200.0), (1, 130.0)] {
            measurements.observe("decode", tps: tps, prompt: 500, context: 600,
                cache: "cold", overlap: .init(), at: at + .seconds(offset))
        }
        let beforeGap = measurements.snapshot(now: at + .seconds(2)).decode
        #expect(beforeGap?.tokensPerSecond == 130)
        #expect(beforeGap?.sampleCount == 3)
        #expect(beforeGap?.sampleAgeMs == 1_000)
        measurements.observe("decode", tps: 900, prompt: 500, context: 600,
            cache: "cold", overlap: .init(), at: at + .seconds(122))
        let afterGap = measurements.snapshot(now: at + .seconds(123)).decode
        #expect(afterGap?.tokensPerSecond == 900)
        #expect(afterGap?.sampleCount == 4)
        #expect(afterGap?.sampleAgeMs == 1_000)
    }

    @Test("independent shape observations retain their own clocks without replacing aggregate evidence")
    func independentShapeClocks() throws {
        var measurements = EnginePerformanceMeasurements()
        let at = ContinuousClock.now
        measurements.observe("decode", tps: 100, prompt: 500, context: 600,
            cache: "cold", overlap: .init(), at: at)
        measurements.observe("decode", tps: 50, prompt: 4_000, context: 4_100,
            cache: "cold", overlap: .init(contended: true, peakRequests: 2),
            at: at - .seconds(10), recordAggregate: false)
        let snapshot = measurements.snapshot(now: at + .seconds(1))
        #expect(snapshot.decode?.tokensPerSecond == 100)
        #expect(snapshot.decode?.sampleCount == 1)
        #expect(snapshot.decode?.sampleAgeMs == 1_000)
        #expect(snapshot.workloadBuckets.count == 2)
        let olderShape = try #require(snapshot.workloadBuckets.first { $0.promptTokenBucket == 4_096 })
        #expect(olderShape.observation.tokensPerSecond == 50)
        #expect(olderShape.observation.sampleAgeMs == 11_000)
    }

    @Test("reversed real bridge terminal delivery preserves latest engine observation and all work")
    func delayedTerminalPreservesFreshness() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [])
        let request = ChatCompletionRequest(model: "gpt-oss-20b",
            messages: [.init(role: "user", content: "hi")], max_tokens: 32)
        let first = await bridge.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
            request: request, requestId: "older-engine-observation")
        let firstConsumer = Task { for await _ in first {} }
        let second = await bridge.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
            request: request, requestId: "newer-engine-observation")
        let secondConsumer = Task { for await _ in second {} }
        let continuations = engine.continuations
        #expect(continuations.count == 2)
        guard continuations.count == 2 else { return }
        defer { continuations.forEach { $0.finish() } }

        func completedUsage(tokens: Int) -> CBv2Usage {
            var usage = CBv2Usage(promptTokens: 200, completionTokens: tokens)
            var timing = CBv2RequestTiming()
            timing.firstTokenNanos = 1_000_000
            timing.lastTokenNanos = 101_000_000
            timing.lastTokenUptimeNanos = DispatchTime.now().uptimeNanoseconds
            timing.decodeSteps = UInt32(tokens - 1)
            usage.timing = timing
            return usage
        }
        // Both requests are actually submitted before their observation stamps.
        // The scripted engine holds A's terminal while B finishes and is consumed.
        try await Task.sleep(for: .milliseconds(110))
        let older = completedUsage(tokens: 11)
        try await Task.sleep(for: .milliseconds(20))
        let newer = completedUsage(tokens: 21)
        #expect(newer.timing.lastTokenUptimeNanos > older.timing.lastTokenUptimeNanos)
        continuations[1].yield(.finished(reason: .stop, usage: newer))
        continuations[1].finish()
        await secondConsumer.value
        let newestExpiration = try #require(await bridge.performanceMeasurements.rateExpiration("decode"))
        let before = await bridge.backendSlotCapacity()
        #expect(before.performanceMeasurements?.decode?.tokensPerSecond == 200)
        #expect(before.telemetry?.generationRequestsTotal == 1)

        continuations[0].yield(.finished(reason: .stop, usage: older))
        continuations[0].finish()
        await firstConsumer.value
        let after = await bridge.backendSlotCapacity()
        #expect(await bridge.performanceMeasurements.rateExpiration("decode") == newestExpiration)
        #expect(after.performanceMeasurements?.decode?.sampleCount == 2)
        #expect(after.performanceMeasurements?.decode?.tokensPerSecond == 170)
        #expect(after.observedDecodeTps == 170)
        #expect(after.telemetry?.generationRequestsTotal == 2)
        #expect(after.telemetry?.generatedTokensTotal == 32)
        await bridge.shutdown()
    }
}
