import Foundation

/// Initial chunk + candidate ladder produced by the hardware roofline seed.
public struct AdaptivePrefillSeedPlan: Sendable, Equatable {
    public let initialChunkSize: Int
    public let ladder: [Int]

    public init(initialChunkSize: Int, ladder: [Int]) {
        self.initialChunkSize = initialChunkSize
        self.ladder = ladder
    }
}

/// Physics-derived starting point for the adaptive-prefill climber.
///
/// The whole-model roofline (`C* = (W/BW)·(Π/2·P_active)`) underestimates the
/// optimal MoE prefill chunk by 16–34×, because it treats the forward pass as a
/// single GEMM. It is not: the MLP is `E` grouped expert GEMMs and top-`k`
/// routing puts only `Bₑ = C·k/E` tokens into each expert. Applying the ridge
/// **per expert** cancels the expert weight shape, leaving
/// `Bₑ* = bpp·Π/(2·BW)`, so the chunk must be `E/k`× larger just to give each
/// expert a compute-bound batch:
///
///     C_seed = (E/k) · Bₑ_target,    Bₑ_target = γ · Bₑ_floor
///     Bₑ_floor = bpp · peakFLOPS / (2 · BW)
///
/// For an M4 Max + gpt-oss-20b (E=32, k=4 ⇒ E/k=8) this lands ≈1536, matching
/// the measured U-curve minimum. The seed is a *start*, not a setting — the
/// empirical climber refines it and is the safety net for every uncertainty
/// here (γ, bpp, M5 matrix-unit dispatch). Unknown hardware ⇒ no seed (`nil`),
/// and the caller falls back to the generic empirical ladder.
public enum AdaptivePrefillSeed {

    /// Empirical grouped-GEMM saturation factor: the multiplier from the
    /// theoretical per-expert roofline knee (Bₑ_floor ≈ 17 tok/expert on M4 Max)
    /// to the measured saturation point (≈192 tok/expert). Calibrated to the
    /// M4 Max + gpt-oss-20b anchor (C_seed = 8 × 192 ≈ 1536).
    static let groupedGemmSaturationFactor = 11.4

    /// Clamp band for Bₑ_target (tokens/expert) to keep the seed sane across the
    /// fleet even when γ·Bₑ_floor drifts.
    static let beTargetMin = 64.0
    static let beTargetMax = 1024.0

    /// Candidate chunk rungs (tokens). 1536 is the measured MoE sweet spot; the
    /// 8192 top rung is appended only behind the ridge + env gate (see Phase 4).
    static let baseCandidates = [512, 1024, 1536, 2048, 3072, 4096]
    static let topGatedRung = 8192

    public struct Guardrails: Sendable {
        /// Allow the 8192 top rung into the candidate ladder (gated).
        public var allow8192: Bool
        /// Ridge (FLOP/byte) above which the 8192 rung is even considered. M1–M4
        /// (ridge ≈52–86) stay below it by construction; M5 matrix-unit territory
        /// (ridge ≈115–250) clears it.
        public var ridgeThresholdFor8192: Double
        /// Effective model weight bytes/param (quantization). 4-bit ≈ 0.5.
        public var bytesPerParam: Double
        /// Fraction of available memory budgeted for transient prefill activations.
        public var memoryHeadroomFraction: Double
        /// Layer/attention scratch multiplier on the per-token activation estimate.
        public var activationOverhead: Double

        public init(
            allow8192: Bool = false,
            ridgeThresholdFor8192: Double = 120,
            bytesPerParam: Double = 0.5,
            memoryHeadroomFraction: Double = 0.25,
            activationOverhead: Double = 8
        ) {
            self.allow8192 = allow8192
            self.ridgeThresholdFor8192 = ridgeThresholdFor8192
            self.bytesPerParam = max(0.0001, bytesPerParam)
            self.memoryHeadroomFraction = min(max(memoryHeadroomFraction, 0.01), 1.0)
            self.activationOverhead = max(1, activationOverhead)
        }

        public static func from(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Guardrails {
            Guardrails(
                allow8192: AdaptivePrefillPolicy.envFlag(
                    environment["DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192"])
            )
        }
    }

    /// Compute the seed plan, or `nil` when the hardware peak FLOPS / bandwidth
    /// are unknown (⇒ skip seeding, fall back to the empirical default).
    public static func plan(
        hardware: HardwareInfo,
        model: ModelArchitecture,
        guardrails: Guardrails = Guardrails()
    ) -> AdaptivePrefillSeedPlan? {
        let peak = hardware.estimatedPeakFp16Flops
        let bandwidthBytes = Double(hardware.memoryBandwidthGbs) * 1e9
        guard peak > 0, bandwidthBytes > 0 else { return nil }

        // E/k expert fan-out (dense ⇒ 1).
        let experts = max(1, model.numLocalExperts ?? 1)
        let activePerTok = max(1, model.numExpertsPerTok ?? 1)
        let expertFanout = Double(experts) / Double(activePerTok)

        // Per-expert compute-bound batch floor, lifted to the empirical
        // saturation point and clamped.
        let beFloor = guardrails.bytesPerParam * peak / (2 * bandwidthBytes)
        let beTarget = min(max(groupedGemmSaturationFactor * beFloor, beTargetMin), beTargetMax)
        let cSeed = expertFanout * beTarget

        let ridge = hardware.rooflineRidgeFlopPerByte
        let ladder = candidateLadder(
            hardware: hardware, model: model, ridge: ridge, guardrails: guardrails)
        guard let initial = nearest(in: ladder, to: Int(cSeed.rounded())) else { return nil }
        return AdaptivePrefillSeedPlan(initialChunkSize: initial, ladder: ladder)
    }

    /// Build a seeded policy, falling back to the generic empirical policy when
    /// the hardware is unknown. The single construction path shared by the
    /// scheduler and the benchmark so they stay in lock-step.
    public static func policy(
        hardware: HardwareInfo,
        model: ModelArchitecture,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AdaptivePrefillPolicy {
        let guardrails = Guardrails.from(environment: environment)
        if let plan = plan(hardware: hardware, model: model, guardrails: guardrails) {
            return .seeded(plan)
        }
        return .liveDefault(environment: environment)
    }

    // MARK: - Ladder construction

    private static func candidateLadder(
        hardware: HardwareInfo,
        model: ModelArchitecture,
        ridge: Double,
        guardrails: Guardrails
    ) -> [Int] {
        var candidates = baseCandidates
        if guardrails.allow8192, ridge >= guardrails.ridgeThresholdFor8192 {
            candidates.append(topGatedRung)
        }
        let ceiling = memoryCeilingChunk(
            hardware: hardware, model: model, guardrails: guardrails)
        let filtered = candidates.filter { $0 <= ceiling }
        // Always keep at least the smallest rung so the ladder is never empty.
        return filtered.isEmpty ? [candidates.first ?? 512] : filtered
    }

    /// Upper bound on chunk size from a per-token transient-activation estimate
    /// against a fraction of available memory. Non-binding on normal hardware;
    /// guards pathological low-memory configs. Returns `.max` when dimensions
    /// are unknown (no clamp).
    private static func memoryCeilingChunk(
        hardware: HardwareInfo,
        model: ModelArchitecture,
        guardrails: Guardrails
    ) -> Int {
        guard let hidden = model.hiddenSize, hidden > 0 else { return Int.max }
        let activePerTok = max(1, model.numExpertsPerTok ?? 1)
        let intermediate = model.intermediateSize ?? hidden
        // hidden residual + the k routed experts' MLP inner activations, fp16.
        let perTokenBytes = Double(hidden + activePerTok * intermediate)
            * 2.0 * guardrails.activationOverhead
        guard perTokenBytes > 0 else { return Int.max }
        let headroomBytes = Double(hardware.memoryAvailableGb) * 1e9 * guardrails.memoryHeadroomFraction
        let maxChunk = headroomBytes / perTokenBytes
        if maxChunk >= Double(Int.max) { return Int.max }
        return max(0, Int(maxChunk))
    }

    private static func nearest(in ladder: [Int], to value: Int) -> Int? {
        ladder.min(by: { abs($0 - value) < abs($1 - value) })
    }
}
