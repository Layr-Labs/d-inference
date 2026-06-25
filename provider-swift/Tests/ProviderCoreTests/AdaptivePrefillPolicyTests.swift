import Foundation
import Testing
@testable import ProviderCore

@Suite("Adaptive prefill policy — ms/token hill-climb")
struct AdaptivePrefillPolicyTests {
    // Small, deterministic tuning for fast convergence in tests.
    private let ladder = [512, 1024, 1536, 2048]
    private func policy(
        minClean: Int = 2,
        cooldown: Int = 1,
        regression: Int = 2,
        eps: Double = 0.04,
        reexplore: Int = 0
    ) -> AdaptivePrefillPolicy {
        AdaptivePrefillPolicy(
            ladder: ladder,
            epsNoise: eps,
            minCleanSamplesPerRung: minClean,
            cooldownSampleCount: cooldown,
            regressionConfirmations: regression,
            reexploreInterval: reexplore
        )
    }

    /// A "clean" first-chunk sample at `rung` with the given ms/token.
    private func clean(_ rung: Int, msPerToken: Double) -> AdaptivePrefillSample {
        AdaptivePrefillSample(
            requestedChunkSize: rung,
            actualChunkSize: rung,
            totalTokens: rung,
            durationMs: msPerToken * Double(rung),
            positionOffset: 0,
            decodeBatchSize: 0
        )
    }

    /// Drive the policy with clean samples whose ms/token is a function of the
    /// current rung, returning the settled state.
    private func drive(
        _ policy: AdaptivePrefillPolicy,
        msByRung: [Int: Double],
        start: AdaptivePrefillState,
        steps: Int
    ) -> AdaptivePrefillState {
        var state = start
        for _ in 0..<steps {
            let rung = state.currentChunkSize
            let ms = msByRung[rung] ?? 1_000
            state = policy.record(sample: clean(rung, msPerToken: ms), state: state).state
        }
        return state
    }

    // MARK: - Seeding

    @Test("initial state starts at the smallest rung by default")
    func initialState() {
        let p = policy()
        #expect(p.initialState().currentChunkSize == 512)
        #expect(p.proposedChunkSize(state: p.initialState()) == 512)
    }

    @Test("seeded initial chunk is honoured")
    func seededInitial() {
        let p = AdaptivePrefillPolicy(ladder: ladder, initialChunkSize: 1536)
        #expect(p.initialState().currentChunkSize == 1536)
    }

    @Test("persisted converged rung is restored when the policy version matches")
    func persistedRestored() {
        let p = policy()
        let persisted = AdaptivePrefillState(
            currentChunkSize: 1536, ceiling: 1536,
            policyVersion: AdaptivePrefillPolicy.algorithmIdentity)
        let restored = p.initialState(persisted: persisted)
        #expect(restored.currentChunkSize == 1536)
        #expect(restored.ceiling == 1536)
        #expect(restored.cleanSamplesAtCurrentSize == 0)  // EWMA/counters reset
    }

    @Test("persisted state from a different policy version is ignored")
    func persistedVersionMismatchIgnored() {
        let p = policy()
        let stale = AdaptivePrefillState(currentChunkSize: 2048, policyVersion: "duration.v1")
        #expect(p.initialState(persisted: stale).currentChunkSize == 512)
    }

    // MARK: - Convergence

    @Test("a U-shaped ms/token curve converges to the minimum rung")
    func convergesToMinimum() {
        // Minimum at 1536; both shoulders strictly worse.
        let curve = [512: 3.0, 1024: 2.0, 1536: 1.0, 2048: 2.0]
        let settled = drive(policy(), msByRung: curve,
                            start: policy().initialState(), steps: 40)
        #expect(settled.currentChunkSize == 1536)
    }

    @Test("seeded at the optimum, a flat upper neighbour holds (does not grow)")
    func holdsAtSeededOptimum() {
        // Mirrors the real M4 Max curve where 2048 is within the noise band of
        // 1536: the climber probes up once, finds no gain, and settles back.
        let p = AdaptivePrefillPolicy(
            ladder: ladder, initialChunkSize: 1536,
            minCleanSamplesPerRung: 2, cooldownSampleCount: 1)
        let curve = [1024: 1.101, 1536: 1.087, 2048: 1.127]
        let settled = drive(p, msByRung: curve, start: p.initialState(), steps: 40)
        #expect(settled.currentChunkSize == 1536)
        #expect(settled.ceiling == 1536)  // locked so it stops re-probing up
    }

    @Test("flat band prefers the smaller rung")
    func flatBandPrefersSmaller() {
        // 1024 is only ~1% faster than 512 — inside the 4% band → prefer 512.
        let p = AdaptivePrefillPolicy(
            ladder: [512, 1024], minCleanSamplesPerRung: 2, cooldownSampleCount: 1)
        let curve = [512: 1.0, 1024: 0.99]
        let settled = drive(p, msByRung: curve, start: p.initialState(), steps: 30)
        #expect(settled.currentChunkSize == 512)
    }

    @Test("climbs upward while each rung is strictly faster, into 8192 when allowed")
    func climbsThroughExperimentalLadder() {
        let p = AdaptivePrefillPolicy(
            ladder: AdaptivePrefillPolicy.experimentalLadder,
            minCleanSamplesPerRung: 2, cooldownSampleCount: 1)
        // Strictly improving all the way up.
        let curve = [512: 5.0, 1024: 4.0, 2048: 3.0, 4096: 2.0, 8192: 1.0]
        let settled = drive(p, msByRung: curve, start: p.initialState(), steps: 60)
        #expect(settled.currentChunkSize == 8192)
    }

    @Test("default (production) ladder cannot reach 8192")
    func defaultLadderCapsAt4096() {
        let p = AdaptivePrefillPolicy(
            ladder: AdaptivePrefillPolicy.defaultLadder,
            minCleanSamplesPerRung: 2, cooldownSampleCount: 1)
        let curve = [512: 5.0, 1024: 4.0, 2048: 3.0, 4096: 2.0]
        let settled = drive(p, msByRung: curve, start: p.initialState(), steps: 60)
        #expect(settled.currentChunkSize == 4096)
    }

    // MARK: - Clean gate

    @Test("samples with positionOffset > 0 never move the ladder")
    func positionOffsetSamplesIgnored() {
        let p = policy()
        var state = AdaptivePrefillState(currentChunkSize: 1024)
        for _ in 0..<20 {
            let drifted = AdaptivePrefillSample(
                requestedChunkSize: 1024, actualChunkSize: 1024,
                totalTokens: 1024, durationMs: 100, positionOffset: 1024)
            let t = p.record(sample: drifted, state: state)
            #expect(!t.changedChunkSize)
            #expect(t.reason == .steady)
            state = t.state
        }
        #expect(state.currentChunkSize == 1024)
        #expect(state.rungMsPerToken.isEmpty)  // never folded into the EWMA
    }

    @Test("samples overlapping decode are not clean")
    func decodeOverlapIgnored() {
        let p = policy()
        let state = AdaptivePrefillState(currentChunkSize: 1024)
        let overlap = AdaptivePrefillSample(
            requestedChunkSize: 1024, actualChunkSize: 1024,
            totalTokens: 1024, durationMs: 100, positionOffset: 0, decodeBatchSize: 8)
        let t = p.record(sample: overlap, state: state)
        #expect(!t.changedChunkSize)
        #expect(t.state.rungMsPerToken.isEmpty)
    }

    @Test("capped samples do not move the ladder")
    func cappedIgnored() {
        let p = policy()
        var state = p.initialState()
        for _ in 0..<6 {
            let capped = AdaptivePrefillSample(
                requestedChunkSize: 512, actualChunkSize: 256,
                totalTokens: 256, durationMs: 20, cappedByCheckpoint: true)
            let t = p.record(sample: capped, state: state)
            #expect(t.reason == .capped)
            state = t.state
        }
        #expect(state.currentChunkSize == 512)
    }

    // MARK: - Cooldown + min-samples

    @Test("cooldown defers decisions for N clean samples after a change")
    func cooldownDefersDecisions() {
        let p = AdaptivePrefillPolicy(
            ladder: ladder, minCleanSamplesPerRung: 1, cooldownSampleCount: 3)
        // First clean sample at the seed triggers a probe-up (rung change),
        // arming a 3-sample cooldown.
        var state = p.initialState()
        state = p.record(sample: clean(512, msPerToken: 2.0), state: state).state
        #expect(state.currentChunkSize == 1024)  // probed up
        for _ in 0..<3 {
            let t = p.record(sample: clean(1024, msPerToken: 1.0), state: state)
            #expect(t.reason == .cooldown)
            #expect(!t.changedChunkSize)
            state = t.state
        }
        #expect(state.cooldownSamplesRemaining == 0)
    }

    @Test("a rung is not trusted until min clean samples accumulate")
    func minSamplesRespected() {
        let p = AdaptivePrefillPolicy(
            ladder: ladder, initialChunkSize: 1024,
            minCleanSamplesPerRung: 5, cooldownSampleCount: 0)
        var state = p.initialState()
        for i in 1...4 {
            let t = p.record(sample: clean(1024, msPerToken: 1.0), state: state)
            #expect(!t.changedChunkSize, "no decision before min samples (i=\(i))")
            state = t.state
        }
        // 5th clean sample is the first decision point → probe upward.
        let t = p.record(sample: clean(1024, msPerToken: 1.0), state: state)
        #expect(t.changedChunkSize)
        #expect(t.reason == .grow)
    }

    @Test("a larger rung is abandoned only after the regression is confirmed")
    func regressionRequiresConfirmation() {
        let p = AdaptivePrefillPolicy(
            ladder: [1024, 2048], initialChunkSize: 2048,
            minCleanSamplesPerRung: 1, cooldownSampleCount: 0, regressionConfirmations: 2)
        // Prime a fast lower rung so the climber has a baseline to regress against.
        var state = AdaptivePrefillState(currentChunkSize: 2048)
        state.rungMsPerToken[1024] = 1.0
        // First slow reading at 2048: regression seen once, not yet confirmed.
        var t = p.record(sample: clean(2048, msPerToken: 2.0), state: state)
        #expect(!t.changedChunkSize)
        #expect(t.state.regressionConfirmations == 1)
        state = t.state
        // Second slow reading confirms → shrink to 1024 + lock the ceiling.
        t = p.record(sample: clean(2048, msPerToken: 2.0), state: state)
        #expect(t.changedChunkSize)
        #expect(t.reason == .shrinkThroughputRegression)
        #expect(t.state.currentChunkSize == 1024)
        #expect(t.state.ceiling == 1024)
    }

    // MARK: - Harm back-off

    @Test("memory / thermal / decode / resource harm shrinks immediately and locks a ceiling")
    func harmShrinksAndLocksCeiling() {
        let p = policy()
        func harm(_ build: (inout AdaptivePrefillSample) -> Void) -> AdaptivePrefillTransition {
            var s = AdaptivePrefillSample(
                requestedChunkSize: 2048, actualChunkSize: 2048,
                totalTokens: 2048, durationMs: 40)
            build(&s)
            return p.record(sample: s, state: AdaptivePrefillState(currentChunkSize: 2048))
        }
        #expect(harm { $0.memorySignal = .high }.reason == .shrinkMemoryPressure)
        #expect(harm { $0.thermalSignal = .serious }.reason == .shrinkThermalPressure)
        #expect(harm { $0.decodeLatencyHarmed = true }.reason == .shrinkDecodeHarm)
        let resource = harm { $0.resourceError = true }
        #expect(resource.reason == .shrinkResourceError)
        #expect(resource.state.currentChunkSize == 1536)  // one rung down
        #expect(resource.state.ceiling == 1536)
    }

    @Test("after harm the climber cannot re-grow into the locked wall")
    func ceilingBlocksRegrowth() {
        let p = AdaptivePrefillPolicy(
            ladder: [512, 1024, 2048, 4096], minCleanSamplesPerRung: 2, cooldownSampleCount: 1)
        // Harm at 2048 → shrink to 1024, ceiling 1024.
        var state = AdaptivePrefillState(currentChunkSize: 2048)
        let harm = AdaptivePrefillSample(
            requestedChunkSize: 2048, actualChunkSize: 2048,
            totalTokens: 2048, durationMs: 40, memorySignal: .critical)
        state = p.record(sample: harm, state: state).state
        #expect(state.currentChunkSize == 1024)
        #expect(state.ceiling == 1024)
        // Even with strictly-improving samples above, it must never exceed 1024.
        let settled = drive(p, msByRung: [512: 5, 1024: 1, 2048: 0.5, 4096: 0.25],
                            start: state, steps: 40)
        #expect(settled.currentChunkSize <= 1024)
    }
}
