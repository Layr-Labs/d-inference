import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The idle age of the published decode rate (`DecodeRateIdleAge`), with
/// synthetic observations and a scripted engine. No model or GPU is involved.
@Suite("Decode rate idle age")
struct DecodeRateIdleAgeTests {
    private func decode(_ tps: Double, at: ContinuousClock.Instant, batchRows: Int,
                        setsPublishedDecode: Bool = true) -> EngineRateObservation {
        EngineRateObservation(phase: "decode", tps: tps, prompt: 1_024, context: 1_024, cache: "cold",
            overlap: .init(contended: batchRows > 1, peakRequests: batchRows), at: at,
            postureEpoch: nil, aggregate: true, decodeShape: .init(batchRows: Double(batchRows)),
            setsPublishedDecode: setsPublishedDecode)
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

    @Test("the heartbeat sends the published rate's own age: a short reply neither moves nor dates it")
    func publishedRateCarriesItsAge() async throws {
        let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], admissionFixes: true)
        let start = ContinuousClock.now
        let unmeasured = await bridge.backendSlotCapacity(now: start)
        #expect(unmeasured.observedDecodeTps == 0 && unmeasured.observedDecodeTpsAgeMs == nil)
        await bridge.applyRateObservation(decode(40, at: start, batchRows: 1),
            requestID: "long", calibration: false)
        let fresh = await bridge.backendSlotCapacity(now: start + .seconds(60))
        #expect(fresh.observedDecodeTps == 40 && fresh.observedDecodeTpsAgeMs == 60_000)
        // A reply under 32 tokens feeds the other estimates but not the published rate or its age.
        await bridge.applyRateObservation(decode(10, at: start + .seconds(100), batchRows: 1, setsPublishedDecode: false),
            requestID: "short", calibration: false)
        let afterShort = await bridge.backendSlotCapacity(now: start + .milliseconds(160_500))
        #expect(afterShort.observedDecodeTps == 40, "the published rate itself is unchanged")
        #expect(afterShort.observedDecodeTpsAgeMs == 160_500)
        // With no rate published there is no age.
        let aged = await bridge.backendSlotCapacity(now: start + .seconds(1_801 + 100))
        #expect(aged.observedDecodeTps == 0 && aged.observedDecodeTpsAgeMs == nil)
        await bridge.shutdown()
    }

    @Test("the age goes on the wire only with a published rate")
    func ageWireShape() throws {
        var slot = BackendSlotCapacity(model: "m", state: "idle", numRunning: 0, numWaiting: 0,
            activeTokens: 0, maxTokensPotential: 0, observedDecodeTps: 40)
        func object() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(slot)) as? [String: Any])
        }
        #expect(try object()["observed_decode_tps_age_ms"] == nil)
        slot.observedDecodeTpsAgeMs = 1_234
        #expect(try object()["observed_decode_tps_age_ms"] as? Int == 1_234)
        let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: JSONEncoder().encode(slot))
        #expect(decoded.observedDecodeTpsAgeMs == 1_234 && decoded == slot)
    }
}
