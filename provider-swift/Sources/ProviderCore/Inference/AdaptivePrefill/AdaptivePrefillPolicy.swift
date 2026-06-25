import Foundation

/// Self-calibrating cold-prefill chunk sizer.
///
/// The policy hill-climbs on **measured ms/token** (throughput), not on chunk
/// duration. Duration is monotonic in chunk size by construction, so it can
/// never tell whether a larger chunk is more efficient *per token*; ms/token
/// can. The starting rung is supplied by the hardware roofline seed
/// (`AdaptivePrefillSeed`); from there the climber only trusts first-chunk,
/// uncontended, uncapped samples (`AdaptivePrefillSample` "clean" gate) so the
/// O(N²) attention growth of later chunks can never masquerade as a chunk-size
/// effect.
///
/// Invariants:
///   * Grow to the next rung only when it is faster by > `epsNoise` (relative).
///   * A flat band (|Δ| ≤ `epsNoise`) prefers the **smaller** rung.
///   * A larger rung is abandoned only after `regressionConfirmations`
///     consecutive slower readings.
///   * Memory / thermal / decode / resource harm forces an immediate one-rung
///     back-off and locks a ceiling so the climber cannot re-grow into the wall.
public struct AdaptivePrefillPolicy: Sendable, Equatable {
    /// Algorithm + wire-state version. Folded into the store key's
    /// `policyIdentity` and stamped into `AdaptivePrefillState.policyVersion`;
    /// bump this whenever the decision math or state shape changes so stale
    /// learned rungs re-seed cleanly instead of blocking adoption.
    public static let algorithmIdentity = "throughput-hillclimb.v2"

    /// Generic fallback ladder (unknown hardware / no seed).
    public static let defaultLadder = [512, 1024, 2048, 4096]
    public static let experimentalLadder = [512, 1024, 2048, 4096, 8192]

    public let ladder: [Int]
    public let initialChunkSize: Int
    /// EWMA smoothing factor for per-rung ms/token (0 < α ≤ 1).
    public let alpha: Double
    /// Relative noise band; differences within ±`epsNoise` are "flat".
    public let epsNoise: Double
    /// Clean samples required before a rung's EWMA is trusted for a decision.
    public let minCleanSamplesPerRung: Int
    /// Clean samples ignored (gathered only) immediately after a rung change.
    public let cooldownSampleCount: Int
    /// Consecutive slower readings required to confirm a regression.
    public let regressionConfirmations: Int
    /// Clean samples between optional upward re-probes (0 ⇒ disabled).
    public let reexploreInterval: Int

    public init(
        ladder: [Int] = AdaptivePrefillPolicy.defaultLadder,
        initialChunkSize: Int? = nil,
        alpha: Double = 0.3,
        epsNoise: Double = 0.04,
        minCleanSamplesPerRung: Int = 5,
        cooldownSampleCount: Int = 3,
        regressionConfirmations: Int = 2,
        reexploreInterval: Int = 0
    ) {
        let sanitized = Array(Set(ladder.filter { $0 > 0 })).sorted()
        self.ladder = sanitized.isEmpty ? Self.defaultLadder : sanitized
        self.initialChunkSize = Self.resolveInitialChunkSize(initialChunkSize, ladder: self.ladder)
        self.alpha = min(max(alpha, 0.01), 1.0)
        self.epsNoise = max(0, epsNoise)
        self.minCleanSamplesPerRung = max(1, minCleanSamplesPerRung)
        self.cooldownSampleCount = max(0, cooldownSampleCount)
        self.regressionConfirmations = max(1, regressionConfirmations)
        self.reexploreInterval = max(0, reexploreInterval)
    }

    // MARK: - Factories

    /// Generic, hardware-agnostic policy. Used when the roofline seed is
    /// unavailable (unknown chip/model) — preserves the pre-seed behavior of
    /// starting empirical from the smallest rung.
    public static func liveDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AdaptivePrefillPolicy {
        let allow8192 = envFlag(environment["DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192"])
        return AdaptivePrefillPolicy(ladder: allow8192 ? experimentalLadder : defaultLadder)
    }

    /// Build a policy from a hardware roofline seed: the seed's candidate
    /// ladder + initial rung, with the measured-climb tuning applied.
    public static func seeded(_ plan: AdaptivePrefillSeedPlan) -> AdaptivePrefillPolicy {
        AdaptivePrefillPolicy(ladder: plan.ladder, initialChunkSize: plan.initialChunkSize)
    }

    // MARK: - State seeding

    public func initialState(persisted: AdaptivePrefillState? = nil) -> AdaptivePrefillState {
        let fresh = AdaptivePrefillState(
            currentChunkSize: initialChunkSize,
            policyVersion: Self.algorithmIdentity
        )
        guard let persisted,
              persisted.policyVersion == Self.algorithmIdentity,
              ladder.contains(persisted.currentChunkSize)
        else {
            return fresh
        }
        // Restore the converged rung + any learned ceiling; reset the volatile
        // counters and EWMA so the climber re-confirms by measurement.
        var restored = fresh
        restored.currentChunkSize = persisted.currentChunkSize
        if let ceiling = persisted.ceiling, ladder.contains(ceiling) {
            restored.ceiling = ceiling
        }
        restored.lastDecisionReason = .steady
        return restored
    }

    public func proposedChunkSize(state: AdaptivePrefillState) -> Int {
        let cur = ladder.contains(state.currentChunkSize) ? state.currentChunkSize : (ladder.first ?? 512)
        if let ceiling = state.ceiling { return max(1, min(cur, ceiling)) }
        return max(1, cur)
    }

    // MARK: - Decision

    public func record(sample: AdaptivePrefillSample, state: AdaptivePrefillState) -> AdaptivePrefillTransition {
        var next = normalized(state)
        let previousSize = next.currentChunkSize

        // 1. Harm: immediate, unconditional one-rung back-off + ceiling lock.
        if let reason = harmReason(sample) {
            let shrunk = shrink(next.currentChunkSize)
            next.currentChunkSize = shrunk
            next.ceiling = effectiveCeiling(lockingAt: shrunk, existing: next.ceiling)
            next.cleanSamplesAtCurrentSize = 0
            next.cooldownSamplesRemaining = cooldownSampleCount
            next.regressionConfirmations = 0
            next.samplesSinceReexplore = 0
            return finish(&next, reason, changed: shrunk != previousSize)
        }

        // 2. Non-clean sample: cannot calibrate throughput on it — leave the ladder be.
        guard isClean(sample, rung: next.currentChunkSize) else {
            let capped = sample.cappedByBudget || sample.cappedByCheckpoint || sample.cappedByRemaining
            return finish(&next, capped ? .capped : .steady, changed: false)
        }

        // 3. Clean sample → fold ms/token into this rung's EWMA.
        next.rungMsPerToken[next.currentChunkSize] = ewma(
            next.rungMsPerToken[next.currentChunkSize], sample.msPerToken)
        next.cleanSamplesAtCurrentSize += 1
        next.samplesSinceReexplore += 1

        // 4. Cooldown after a recent rung change: gather, don't decide.
        if next.cooldownSamplesRemaining > 0 {
            next.cooldownSamplesRemaining -= 1
            return finish(&next, .cooldown, changed: false)
        }

        // 5. Not enough clean samples to trust this rung yet.
        if next.cleanSamplesAtCurrentSize < minCleanSamplesPerRung {
            return finish(&next, .steady, changed: false)
        }

        // 6. Periodic re-exploration: drop the soft ceiling so the climber can
        //    re-probe upward in case conditions changed. Disabled when 0.
        if reexploreInterval > 0, next.ceiling != nil, next.samplesSinceReexplore >= reexploreInterval {
            next.ceiling = nil
            next.regressionConfirmations = 0
            next.samplesSinceReexplore = 0
            return finish(&next, .steady, changed: false)
        }

        // 7. Hill-climb on neighbour ms/token.
        return decide(&next, previousSize: previousSize)
    }

    // MARK: - Hill-climb core

    private func decide(_ next: inout AdaptivePrefillState, previousSize: Int) -> AdaptivePrefillTransition {
        let cur = next.currentChunkSize
        guard let curMs = next.rungMsPerToken[cur] else {
            return finish(&next, .steady, changed: false)
        }
        let lower = rungBelow(cur)
        let upper = rungAbove(cur, ceiling: next.ceiling)

        // (A) Validate the most recent growth against the rung climbed from.
        if let lower, let lowMs = next.rungMsPerToken[lower] {
            if curMs > lowMs * (1 + epsNoise) {
                // Current rung is slower than the smaller one below → regression.
                next.regressionConfirmations += 1
                if next.regressionConfirmations >= regressionConfirmations {
                    return moveTo(&next, lower, reason: .shrinkThroughputRegression,
                                  ceiling: effectiveCeiling(lockingAt: lower, existing: next.ceiling),
                                  previousSize: previousSize)
                }
                return finish(&next, .steady, changed: false)  // await confirmation
            } else if curMs > lowMs * (1 - epsNoise) {
                // Flat band: no real gain over the smaller rung → prefer smaller.
                return moveTo(&next, lower, reason: .holdOptimum,
                              ceiling: effectiveCeiling(lockingAt: lower, existing: next.ceiling),
                              previousSize: previousSize)
            }
            // Current rung is genuinely faster than below: the growth paid off.
            next.regressionConfirmations = 0
        }

        // (B) Climb / probe upward.
        if let upper {
            if let upMs = next.rungMsPerToken[upper] {
                if upMs < curMs * (1 - epsNoise) {
                    return moveTo(&next, upper, reason: .grow, ceiling: next.ceiling,
                                  previousSize: previousSize)
                }
                // Upper measured and not better → current rung is the optimum.
                next.ceiling = effectiveCeiling(lockingAt: cur, existing: next.ceiling)
                return finish(&next, .holdOptimum, changed: false)
            }
            // Upper unexplored → probe it.
            return moveTo(&next, upper, reason: .grow, ceiling: next.ceiling, previousSize: previousSize)
        }

        // (C) Nowhere left to climb (ceiling / top) → settled.
        return finish(&next, .holdOptimum, changed: false)
    }

    private func moveTo(
        _ next: inout AdaptivePrefillState,
        _ size: Int,
        reason: AdaptivePrefillDecisionReason,
        ceiling: Int?,
        previousSize: Int
    ) -> AdaptivePrefillTransition {
        next.currentChunkSize = size
        next.ceiling = ceiling
        next.cleanSamplesAtCurrentSize = 0
        next.cooldownSamplesRemaining = cooldownSampleCount
        next.regressionConfirmations = 0
        return finish(&next, reason, changed: size != previousSize)
    }

    private func finish(
        _ next: inout AdaptivePrefillState,
        _ reason: AdaptivePrefillDecisionReason,
        changed: Bool
    ) -> AdaptivePrefillTransition {
        next.lastDecisionReason = reason
        return AdaptivePrefillTransition(state: next, reason: reason, changedChunkSize: changed)
    }

    // MARK: - Helpers

    private func ewma(_ old: Double?, _ sample: Double) -> Double {
        guard let old else { return sample }
        return alpha * sample + (1 - alpha) * old
    }

    private func isClean(_ sample: AdaptivePrefillSample, rung: Int) -> Bool {
        sample.positionOffset == 0
            && sample.decodeBatchSize == 0
            && !sample.cappedByBudget
            && !sample.cappedByCheckpoint
            && !sample.cappedByRemaining
            && sample.actualChunkSize == sample.requestedChunkSize
            && sample.actualChunkSize == rung
    }

    private func harmReason(_ sample: AdaptivePrefillSample) -> AdaptivePrefillDecisionReason? {
        if sample.resourceError { return .shrinkResourceError }
        if sample.memorySignal == .high || sample.memorySignal == .critical {
            return .shrinkMemoryPressure
        }
        if sample.thermalSignal == .serious || sample.thermalSignal == .critical {
            return .shrinkThermalPressure
        }
        if sample.decodeLatencyHarmed { return .shrinkDecodeHarm }
        return nil
    }

    /// Tighten (never loosen) the ceiling to at most `size`.
    private func effectiveCeiling(lockingAt size: Int, existing: Int?) -> Int {
        min(existing ?? (ladder.last ?? size), size)
    }

    private func rungBelow(_ value: Int) -> Int? {
        guard let index = ladder.firstIndex(of: value), index > 0 else { return nil }
        return ladder[index - 1]
    }

    private func rungAbove(_ value: Int, ceiling: Int?) -> Int? {
        guard let index = ladder.firstIndex(of: value), index + 1 < ladder.count else { return nil }
        let candidate = ladder[index + 1]
        if let ceiling, candidate > ceiling { return nil }
        return candidate
    }

    private func shrink(_ value: Int) -> Int {
        guard let index = ladder.firstIndex(of: value), index > 0 else { return ladder.first ?? value }
        return ladder[index - 1]
    }

    private func normalized(_ state: AdaptivePrefillState) -> AdaptivePrefillState {
        var s = state
        if !ladder.contains(s.currentChunkSize) {
            s.currentChunkSize = nearestRung(to: s.currentChunkSize)
        }
        if let ceiling = s.ceiling, s.currentChunkSize > ceiling {
            s.currentChunkSize = nearestRung(to: ceiling)
        }
        return s
    }

    private func nearestRung(to value: Int) -> Int {
        ladder.min(by: { abs($0 - value) < abs($1 - value) }) ?? (ladder.first ?? value)
    }

    private static func resolveInitialChunkSize(_ requested: Int?, ladder: [Int]) -> Int {
        guard let requested else { return ladder.first ?? 512 }
        if ladder.contains(requested) { return requested }
        return ladder.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? (ladder.first ?? 512)
    }

    static func envFlag(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}
