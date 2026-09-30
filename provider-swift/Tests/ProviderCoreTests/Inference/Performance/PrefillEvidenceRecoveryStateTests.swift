import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Expired prefill evidence state")
struct PrefillEvidenceRecoveryStateTests {
    @Test("failed or cache-only recovery waits; a later owner's cold sample clears backoff only at retirement")
    func permissionIsBoundToItsActualOwner() {
        let now = ContinuousClock.now
        var recovery = PrefillEvidenceRecovery()
        recovery.acquire("first", evidenceGuard: nil)
        recovery.beginSubmission("first")
        recovery.observe("wrong-owner")
        recovery.retire("wrong-owner", at: now)
        #expect(recovery.owner == "first" && !recovery.available(at: now + .seconds(1_000)))
        recovery.retire("first", at: now)
        #expect(!recovery.available(at: now + .seconds(119)))
        #expect(recovery.available(at: now + .seconds(120)))
        recovery.acquire("second", evidenceGuard: nil)
        recovery.beginSubmission("second")
        recovery.observe("first")
        recovery.observe("second")
        #expect(!recovery.available(at: now + .seconds(1_000)))
        recovery.retire("second", at: now + .seconds(121))
        #expect(recovery.available(at: now + .seconds(121)))
    }

    @Test("refusal before any engine submit leaves the recovery opportunity available")
    func preSubmitRefusalDoesNotBackOff() {
        var recovery = PrefillEvidenceRecovery()
        recovery.acquire("invalid-client-request", evidenceGuard: nil)
        recovery.retire("invalid-client-request")
        #expect(recovery.available())
    }

    @Test("new evidence reseeds an expired EWMA without resetting observation identity")
    func expiredEstimatesResetOnlyOnMeasuredWork() {
        var measurements = EnginePerformanceMeasurements()
        let at = ContinuousClock.now
        func observe(_ rate: Double, _ age: Duration) {
            measurements.observe("isolated_prefill", tps: rate, prompt: 384, context: 384,
                cache: "cold", overlap: .init(), at: at + age)
        }
        observe(6.1, .zero)
        #expect(measurements.freshRate("isolated_prefill", now: at + .seconds(120)) == 6.1)
        #expect(measurements.freshRate("isolated_prefill", now: at + .seconds(121)) == nil)
        #expect(measurements.snapshot(now: at + .seconds(1_200)).isolatedPrefill?.sampleCount == 1)
        observe(900, .seconds(1_201))
        let resumed = measurements.snapshot(now: at + .seconds(1_201))
        #expect(resumed.isolatedPrefill?.tokensPerSecond == 900)
        #expect(resumed.isolatedPrefill?.sampleCount == 2 && resumed.isolatedPrefill?.sampleAgeMs == 0)
        observe(1_000, .seconds(1_202))
        #expect(measurements.snapshot(now: at + .seconds(1_202)).isolatedPrefill?.tokensPerSecond == 930)
    }

}
