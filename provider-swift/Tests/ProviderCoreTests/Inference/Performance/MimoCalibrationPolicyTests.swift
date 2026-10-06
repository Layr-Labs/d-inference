import Foundation
import Testing
@testable import ProviderCore

@Suite("MiMo calibration work bounds")
struct MimoCalibrationPolicyTests {
    @Test func expensiveCellsRequireMeasuredRatesAndStayWithinExistingCap() {
        let cells = MimoCalibrationPolicy.bootstrap(maximumConcurrency: 3)
        #expect(cells.allSatisfy { $0.width <= 3 })
        #expect(cells.filter { $0.width > 1 }.map(\.width) == [2])
        #expect(MimoCalibrationPolicy.maintenance.allSatisfy { $0.width == 1 })
        #expect(MimoCalibrationPolicy.maintenance.map(\.promptTokens) == [512, 4_096, 512])
        let long = MimoCalibrationPolicy.Cell(promptTokens: 4_096, outputTokens: 32, width: 1)
        #expect(!MimoCalibrationPolicy.affordable(long, prefill: nil, decode: 60))
        #expect(!MimoCalibrationPolicy.affordable(long, prefill: 6, decode: 60))
        #expect(MimoCalibrationPolicy.affordable(long, prefill: 900, decode: 60))
    }

    @Test func batchedEvidenceDoesNotOverwriteSoloRates() {
        var rates = EnginePerformanceMeasurements()
        let now = ContinuousClock.now
        rates.observe("decode", tps: 60, prompt: 512, context: 544, cache: "cold", overlap: .init(), at: now)
        for width in [2, 4, 8] {
            rates.observe("decode", tps: 20, prompt: 512, context: 544, cache: "cold",
                overlap: .init(contended: true, otherModel: false, peakRequests: width), at: now, recordAggregate: false)
        }
        let snapshot = rates.snapshot(now: now)
        #expect(snapshot.decode?.tokensPerSecond == 60 && snapshot.decode?.sampleCount == 1)
        #expect(snapshot.workloadBuckets.map(\.concurrentRequests) == [1, 2, 4, 8])
    }

    @Test func shapeEvidenceIsFreshColdIsolatedAndNeverExtrapolated() {
        var rates = EnginePerformanceMeasurements()
        let now = ContinuousClock.now
        rates.observe("isolated_prefill", tps: 100, prompt: 4_000, context: 4_000,
            cache: "cold", overlap: .init(), at: now)
        rates.observe("reuse_prefill", tps: 1, prompt: 500, context: 500,
            cache: "reused", overlap: .init(), at: now)
        rates.observe("contended_prefill", tps: 2, prompt: 4_000, context: 4_000,
            cache: "cold", overlap: .init(contended: true), at: now)
        #expect(rates.freshIsolatedPrefillRate(promptTokens: 4_096, now: now) == 100)
        #expect(rates.freshIsolatedPrefillRate(promptTokens: 512, now: now) == nil)
        #expect(rates.freshIsolatedPrefillRate(promptTokens: 16_000, now: now) == nil)
        #expect(rates.freshIsolatedPrefillRate(promptTokens: 4_096, now: now + .seconds(121)) == nil)
    }

    @Test func measuredCalibrationReplacesBadBaselineWithoutResettingIdentityOrCount() {
        var rates = EnginePerformanceMeasurements()
        let now = ContinuousClock.now
        rates.observe("isolated_prefill", tps: 6.1, prompt: 512, context: 512,
            cache: "cold", overlap: .init(), at: now)
        let epoch = rates.epoch
        rates.observe("isolated_prefill", tps: 900, prompt: 512, context: 512,
            cache: "cold", overlap: .init(), at: now + .seconds(90), restartEstimate: true)
        let snapshot = rates.snapshot(now: now + .seconds(90))
        #expect(snapshot.epoch == epoch)
        #expect(snapshot.isolatedPrefill?.tokensPerSecond == 900 && snapshot.isolatedPrefill?.sampleCount == 2)
        #expect(rates.freshIsolatedPrefillRate(promptTokens: 512, now: now + .seconds(90)) == 900)
    }
}
