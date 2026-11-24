import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The idle age of the published decode rate (`DecodeRateIdleAge`), with
/// synthetic observations and a scripted engine. No model or GPU is involved.
@Suite("Decode rate idle age")
struct DecodeRateIdleAgeTests {
    private func decode(_ tps: Double, at: ContinuousClock.Instant, batchRows: Int) -> EngineRateObservation {
        EngineRateObservation(phase: "decode", tps: tps, prompt: 1_024, context: 1_024, cache: "cold",
            overlap: .init(contended: batchRows > 1, peakRequests: batchRows), at: at,
            postureEpoch: nil, aggregate: true, decodeShape: .init(batchRows: Double(batchRows)))
    }

    @Test("unset is 30 minutes, a positive whole number of seconds sets it, an off word disables it")
    func switchParsing() {
        let key = DecodeRateIdleAge.environmentKey
        #expect(key == "DARKBLOOM_DECODE_RATE_IDLE_MAX_AGE_SECONDS")
        #expect(DecodeRateIdleAge.resolve(environment: [:]) == Duration.seconds(1_800))
        #expect(DecodeRateIdleAge.resolve(environment: [key: " "]) == Duration.seconds(1_800))
        #expect(DecodeRateIdleAge.resolve(environment: [key: "900"]) == Duration.seconds(900))
        for off in ["0", "false", " OFF ", "no"] {
            #expect(DecodeRateIdleAge.resolve(environment: [key: off]) == nil)
        }
        for invalid in ["-5", "1.5", "soon"] {
            #expect(DecodeRateIdleAge.resolve(environment: [key: invalid]) == Duration.seconds(1_800))
        }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
    }

    @Test("only an idle slot with a sample older than the maximum stops publishing")
    func publishedRate() {
        let maximum = Duration.seconds(1_800)
        #expect(DecodeRateIdleAge.published(ewma: 16, newestSampleAge: .seconds(1_801), idle: true,
            maximum: maximum) == 0)
        #expect(DecodeRateIdleAge.published(ewma: 16, newestSampleAge: .seconds(1_800), idle: true,
            maximum: maximum) == 16)
        #expect(DecodeRateIdleAge.published(ewma: 16, newestSampleAge: .seconds(7_200), idle: false,
            maximum: maximum) == 16)
        #expect(DecodeRateIdleAge.published(ewma: 16, newestSampleAge: .seconds(7_200), idle: true,
            maximum: nil) == 16)
        #expect(DecodeRateIdleAge.published(ewma: 0, newestSampleAge: nil, idle: true,
            maximum: maximum) == 0)
    }

    @Test("an idle slot stops advertising a stacked rate after 30 minutes, and the next sample is published as measured")
    func staleStackedRateAgesOut() async throws {
        let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], admissionFixes: true)
        let start = ContinuousClock.now
        // Measured while four requests shared the slot.
        await bridge.applyRateObservation(decode(16, at: start, batchRows: 4),
            requestID: "stacked", calibration: false)
        let fresh = await bridge.backendSlotCapacity(now: start + .seconds(60))
        let edge = await bridge.backendSlotCapacity(now: start + .seconds(1_799))
        let aged = await bridge.backendSlotCapacity(now: start + .seconds(1_801))
        #expect(fresh.observedDecodeTps == 16)
        #expect(edge.observedDecodeTps == 16)
        #expect(aged.observedDecodeTps == 0)

        // A solo sample after the gap restarts the estimate and is published.
        await bridge.applyRateObservation(decode(80, at: start + .seconds(1_900), batchRows: 1),
            requestID: "solo", calibration: false)
        let resumed = await bridge.backendSlotCapacity(now: start + .seconds(1_901))
        #expect(resumed.observedDecodeTps == 80)
        await bridge.shutdown()
    }
}
