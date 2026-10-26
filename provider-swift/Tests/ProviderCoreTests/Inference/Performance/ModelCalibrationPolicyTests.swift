import Foundation
import Testing
@testable import ProviderCore

@Suite("Model calibration work bounds")
struct ModelCalibrationPolicyTests {
    @Test func ordinaryStartupHasOneExcludedWarmupAndTwoBoundedSoloMeasurements() {
        let cells = ModelCalibrationPolicy.startup
        #expect(cells.count == 3)
        #expect(cells.map(\.promptTokens) == [128, 512, 512])
        #expect(cells.map(\.outputTokens) == [8, 32, 32])
        #expect(cells.map(\.warmup) == [true, false, false])
        #expect(cells.allSatisfy { $0.width == 1 })
    }

    @Test func shapeWarmupReachesStripeLoopedKeysAndServedWidth() {
        typealias Policy = ModelCalibrationPolicy
        for stripe in [2_048, 4_096] {
            let cells = Policy.shapeWarmup(stripeTokens: stripe, chunkTokens: 512, width: 8,
                contextTokens: 262_144)
            #expect(cells.map(\.promptTokens) == [4_796, 576])
            #expect(cells.map(\.width) == [1, 8])
            #expect(cells.map(\.outputTokens) == [16, 24])
            #expect(cells.allSatisfy { $0.warmup && $0.sampled })
            // Full stripes, keys past MLX's looped-softmax limit, an unaligned tail.
            #expect(cells[0].promptTokens >= stripe + 512)
            #expect(cells[0].promptTokens > Policy.attentionLoopedKeys + 512)
            #expect(!cells[0].promptTokens.isMultiple(of: 64))
            // The first decoding row outlives the last row's two prefill steps.
            #expect(cells[1].outputTokens > 2 * (cells[1].width - 1))
        }
        #expect(Policy.shapeWarmup(stripeTokens: nil, chunkTokens: 512, width: 1,
            contextTokens: nil).map(\.width) == [1])
        #expect(Policy.shapeWarmup(stripeTokens: 2_048, chunkTokens: 512, width: 4,
            contextTokens: 2_048).map(\.promptTokens) == [2_032, 576])
        #expect(Policy.shapeWarmup(stripeTokens: 2_048, chunkTokens: 512, width: 4,
            contextTokens: 400).isEmpty)
    }

    @Test func cellOutcomeOrdersRowsWorstFirstAndBoundsEarlyStopRetries() {
        typealias Outcome = ModelCalibrationPolicy.CellOutcome
        // A cell reports its worst row: any failure fails it, any early stop marks it short.
        #expect(Outcome.failed < .stoppedEarly && Outcome.stoppedEarly < .reachedLength)
        #expect([Outcome.reachedLength, .stoppedEarly, .reachedLength].min() == .stoppedEarly)
        #expect(ModelCalibrationPolicy.shapeWarmupCellTries > 1 && ModelCalibrationPolicy.shapeWarmupCellTries <= 3)
    }

    @Test func shapeWarmupKillSwitchReachesTheProviderJob() {
        typealias Policy = ModelCalibrationPolicy
        let key = Policy.shapeWarmupEnvironmentKey
        #expect(key == "DARKBLOOM_TTFT_SHAPE_WARMUP")
        for probed in [[:], [key: "1"], [key: ""], [key: "on"]] {
            #expect(Policy.shapeWarmupMode(environment: probed) == .probed)
        }
        #expect(Policy.shapeWarmupMode(environment: [key: " Always "]) == .always)
        for rollback in ["0", "false", " OFF ", "no"] {
            #expect(Policy.shapeWarmupMode(environment: [key: rollback]) == .off)
        }
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"]) == [key: "0"])
    }

    @Test func shaderCacheProbeSeparatesCompilesFromFirstUseNoise() {
        typealias Policy = ModelCalibrationPolicy
        #expect(Policy.shaderCacheProbe.promptTokens == 128 && Policy.shaderCacheProbe.outputTokens == 2)
        #expect(Policy.shaderCacheProbe.width == 1)
        #expect(Policy.shaderCacheProbe.warmup && !Policy.shaderCacheProbe.sampled)
        // Warm cache: a fresh engine's other first-use work adds up to a few hundred ms.
        #expect(!Policy.shaderCacheLooksCold(first: .milliseconds(120), repeated: .milliseconds(80)))
        #expect(!Policy.shaderCacheLooksCold(first: .milliseconds(410), repeated: .milliseconds(73)))
        #expect(!Policy.shaderCacheLooksCold(first: .milliseconds(800), repeated: .milliseconds(90)))
        // A slow Mac's repeat is long; only a gap beyond the repeat itself counts.
        #expect(!Policy.shaderCacheLooksCold(first: .milliseconds(1_100), repeated: .milliseconds(600)))
        // Cold cache: tens of kernels compile from source in the first run.
        #expect(Policy.shaderCacheLooksCold(first: .milliseconds(2_340), repeated: .milliseconds(69)))
        #expect(Policy.shaderCacheLooksCold(first: .milliseconds(1_000), repeated: .milliseconds(90)))
        #expect(Policy.shaderCacheLooksCold(first: .milliseconds(4_000), repeated: .milliseconds(950)))
        #expect(!Policy.shaderCacheLooksCold(first: .milliseconds(90), repeated: .milliseconds(1_400)))
    }

    @Test func expensiveCellsRequireMeasuredRatesAndStayWithinExistingCap() {
        let cells = ModelCalibrationPolicy.bootstrap(maximumConcurrency: 3)
        #expect(cells.allSatisfy { $0.width <= 3 })
        #expect(cells.filter { $0.width > 1 }.map(\.width) == [2])
        #expect(ModelCalibrationPolicy.maintenance.allSatisfy { $0.width == 1 })
        #expect(ModelCalibrationPolicy.maintenance.map(\.promptTokens) == [512, 4_096, 512])
        let long = ModelCalibrationPolicy.Cell(promptTokens: 4_096, outputTokens: 32, width: 1)
        #expect(!ModelCalibrationPolicy.affordable(long, prefill: nil, decode: 60))
        #expect(!ModelCalibrationPolicy.affordable(long, prefill: 6, decode: 60))
        #expect(ModelCalibrationPolicy.affordable(long, prefill: 900, decode: 60))
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
