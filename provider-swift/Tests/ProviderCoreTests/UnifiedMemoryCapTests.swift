import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// MARK: - hardCapBytes

@Test func capIsNinetyPercentOfPhysicalByDefault() {
    // 128 GiB box → 90% = 115.2 GiB.
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: 128 * gib)
    #expect(cap == UInt64(Double(128 * gib) * 0.90))
    #expect(cap < 128 * gib)  // never the whole machine
}

@Test func capHonorsExplicitFraction() {
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: 100 * gib, capFraction: 0.5)
    #expect(cap == 50 * gib)
}

@Test func capNeverLeavesLessThanMinimumReserve() {
    // On a small box the absolute floor binds: 8 GiB box at 90% would leave only
    // 0.8 GiB for the OS, but the 2 GiB floor forces the cap down to 6 GiB.
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: 8 * gib)
    #expect(cap == 6 * gib)  // 8 - 2 (floor), not 7.2 (90%)
}

@Test func capFractionClampsOutOfRange() {
    // > 1 clamps to 1 (then the min-reserve floor still applies); < 0 clamps to 0.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: 1.5, env: [:]) == 1.0)
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: -0.2, env: [:]) == 0.0)
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: [:]) == 0.90)
}

@Test func capFractionReadsEnv() {
    #expect(UnifiedMemoryCap.resolvedCapFraction(
        explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "0.8"]) == 0.8)
    // Explicit beats env.
    #expect(UnifiedMemoryCap.resolvedCapFraction(
        explicit: 0.6, env: ["DARKBLOOM_MEM_CAP_FRACTION": "0.8"]) == 0.6)
}

// MARK: - kvBudgetBytes (cap − Σweights − activations − ramPrefix)

@Test func kvBudgetIsCapMinusWeightsActivationsAndPrefix() {
    // 128 GiB → cap 115.2 GiB. Two models 13.8 + 11.25 = 25.05 GiB, 3 GiB
    // activations, 0 prefix. KV budget = 115.2 − 25.05 − 3 ≈ 87.15 GiB.
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: 128 * gib)
    let weights = UInt64(25.05 * Double(gib))
    let activations = 3 * gib
    let kv = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: 128 * gib,
        residentWeightBytes: weights,
        activationReserveBytes: activations,
        ramPrefixAllowanceBytes: 0)
    #expect(kv == cap - weights - activations)
}

@Test func kvBudgetRisesWhenAModelUnloads() {
    // Same box, drop one model's weights → KV budget grows by exactly that much.
    let phys = 64 * gib
    let both = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: phys, residentWeightBytes: 25 * gib, activationReserveBytes: 3 * gib)
    let one = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: phys, residentWeightBytes: 13 * gib, activationReserveBytes: 3 * gib)
    #expect(one == both + 12 * gib)
}

@Test func kvBudgetClampsToZeroNeverNegative() {
    // Weights + activations exceed the cap → KV budget is 0, not an underflow.
    let kv = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: 36 * gib,
        residentWeightBytes: 40 * gib,  // already over the ~32.4 GiB cap
        activationReserveBytes: 3 * gib)
    #expect(kv == 0)
}

@Test func activationReserveDefaultsToFloorAndReadsEnv() {
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: [:]) == 3 * gib)
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(
        explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "2"]) == 2 * gib)
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: 5 * gib, env: [:]) == 5 * gib)
}

// MARK: - canAdmit (the general N-model load gate)

@Test func canAdmitBothModelsWhenTheyFitUnderCap() {
    // 128 GiB: Gemma 13.8 resident, admit GPT-OSS 11.25 with 5 GiB min-KV +
    // 3 GiB activations → 13.8 + 11.25 + 3 + 5 = 33.05 << 115.2 cap. Fits.
    let ok = UnifiedMemoryCap.canAdmit(
        physicalBytes: 128 * gib,
        currentResidentWeightBytes: UInt64(13.8 * Double(gib)),
        candidateWeightBytes: UInt64(11.25 * Double(gib)),
        minimumKVBytes: 5 * gib,
        activationReserveBytes: 3 * gib)
    #expect(ok)
}

@Test func cannotAdmitSecondModelWhenItWouldBlowTheCap() {
    // 36 GiB: cap 32.4. 8-bit Gemma 26 resident; admitting GPT-OSS 11.25 with
    // 3 GiB activations + 2 GiB min-KV = 42.25 > 32.4 → reject (Case B: one only).
    let ok = UnifiedMemoryCap.canAdmit(
        physicalBytes: 36 * gib,
        currentResidentWeightBytes: 26 * gib,
        candidateWeightBytes: UInt64(11.25 * Double(gib)),
        minimumKVBytes: 2 * gib,
        activationReserveBytes: 3 * gib)
    #expect(!ok)
}

@Test func canAdmitFirstModelOnTightBoxWithRoomForKV() {
    // 36 GiB, nothing resident, load 13.8 GiB Gemma-qat-4bit: 13.8 + 3 + 2 = 18.8
    // ≤ 32.4 cap → admit, with KV headroom to spare.
    let ok = UnifiedMemoryCap.canAdmit(
        physicalBytes: 36 * gib,
        currentResidentWeightBytes: 0,
        candidateWeightBytes: UInt64(13.8 * Double(gib)),
        minimumKVBytes: 2 * gib,
        activationReserveBytes: 3 * gib)
    #expect(ok)
}

// MARK: - cap-fraction env edge cases (mirror MLXMemoryGuard.resolvedReserveBytes)

@Test func capFractionEnvEdgeCasesDegradeToDefault() {
    let def = UnifiedMemoryCap.defaultCapFraction
    // junk / empty / non-numeric → default.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "abc"]) == def)
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": ""]) == def)
    // negative → clamped to 0.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "-0.5"]) == 0.0)
    // > 1 (huge) → clamped to 1.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "9999"]) == 1.0)
    // NaN / inf → not finite → default.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "nan"]) == def)
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "inf"]) == def)
    // explicit NaN → default (clampFraction finite-guard).
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: .nan, env: [:]) == def)
}

// MARK: - activation-reserve env edge cases (mirror MLXMemoryGuard coverage)

@Test func activationReserveEnvEdgeCases() {
    let def = UnifiedMemoryCap.defaultActivationReserveBytes
    // junk / negative / NaN / inf → default floor.
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "junk"]) == def)
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "-3"]) == def)
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "nan"]) == def)
    // 0 is accepted (no activation reserve) — distinct from "unset".
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "0"]) == 0)
    // Absurdly huge finite GB saturates to UInt64.max without trapping.
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "1e308"]) == .max)
}

// MARK: - saturation / no-trap paths in UnifiedMemoryCap itself

@Test func scaleSaturatesAndNeverTrapsOnExtremePhysical() {
    // physical = UInt64.max with fraction 1.0: the byFraction path would trap on
    // UInt64(Double(UInt64.max)); the >= 2^64 guard saturates it to .max instead.
    // The cap is then min(byFraction=.max, byFloor=physical−2GiB), so the 2 GiB
    // OS floor STILL binds even at fraction 1.0 — the result is .max − 2 GiB, and
    // crucially the call returns without trapping.
    #expect(UnifiedMemoryCap.hardCapBytes(physicalBytes: .max, capFraction: 1.0)
        == .max - UnifiedMemoryCap.minimumReserveBytes)
    // fraction 0 → byFraction 0 → min picks 0.
    #expect(UnifiedMemoryCap.hardCapBytes(physicalBytes: 128 * gib, capFraction: 0.0) == 0)
}

// MARK: - liveKVHeadroomBytes (the runtime gate's ceiling)

@Test func liveHeadroomIsCapMinusMlxUsedMinusActivations() {
    // 128 GiB, 0.90 cap = 115.2 GiB. MLX already holds 30 GiB (weights+KV).
    // OS not the binding view. 3 GiB activations. Headroom = 115.2 − 30 − 3.
    let cap = UInt64(Double(128 * gib) * 0.90)
    let headroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: 128 * gib,
        mlxUsedBytes: 30 * gib,
        systemAvailableBytes: .max,
        activationReserveBytes: 3 * gib)
    #expect(headroom == cap - 30 * gib - 3 * gib)
}

@Test func liveHeadroomClampsToOSAvailableWhenTighter() {
    // Under-cap says lots free, but the OS only has 5 GiB → bind to 5 − 3 = 2.
    let headroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: 128 * gib,
        mlxUsedBytes: 30 * gib,
        systemAvailableBytes: 5 * gib,
        activationReserveBytes: 3 * gib)
    #expect(headroom == 2 * gib)
}

@Test func liveHeadroomIsZeroWhenMlxUsageAlreadyAtCap() {
    // MLX holds more than the cap (over-committed) → no further KV, never negative.
    let headroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: 64 * gib,
        mlxUsedBytes: 60 * gib,  // > 0.90×64 = 57.6
        systemAvailableBytes: .max,
        activationReserveBytes: 3 * gib)
    #expect(headroom == 0)
}

@Test func liveHeadroomHasNoAbsoluteFloorUnlikeHardCap() {
    // liveKVHeadroom uses capFraction×physical WITHOUT the 2 GiB OS floor that
    // hardCapBytes applies (the floor is a load-time concern). So at fraction 1.0
    // with no MLX usage and infinite OS, headroom = full physical − activations.
    let headroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: 8 * gib, mlxUsedBytes: 0, systemAvailableBytes: .max,
        activationReserveBytes: 0, capFraction: 1.0)
    #expect(headroom == 8 * gib)  // not 6 GiB (which hardCapBytes would give)
}

@Test func kvBudgetAndAdmitSaturateOnMaxOperands() {
    // .max weights must clamp the KV budget to 0, not underflow/trap.
    #expect(UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: 128 * gib, residentWeightBytes: .max, activationReserveBytes: .max) == 0)
    // .max candidate weights cannot be admitted (saturating need > cap), no trap.
    #expect(!UnifiedMemoryCap.canAdmit(
        physicalBytes: 128 * gib, currentResidentWeightBytes: .max,
        candidateWeightBytes: .max, minimumKVBytes: .max, activationReserveBytes: .max))
}
