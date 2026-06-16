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
    // negative env → UNSET → default (NOT clamped to 0: a 0 cap would reject
    // every request and silently brick the provider from one bad env var).
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "-0.5"]) == def)
    // zero env → UNSET → default (same reason).
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "0"]) == def)
    // > 1 (huge) → a real positive value → clamped to 1.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "9999"]) == 1.0)
    // NaN / inf → not finite → default.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "nan"]) == def)
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "inf"]) == def)
    // An EXPLICIT programmatic value is still clamped as given (tests pin it):
    // out-of-range explicit values clamp rather than fall back.
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: -0.2, env: [:]) == 0.0)
    #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: 1.5, env: [:]) == 1.0)
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
    // zero env → UNSET → default floor: an operator can RAISE the reserve but not
    // silently disable the activation headroom the cap exists to guarantee.
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: nil, env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "0"]) == def)
    // An EXPLICIT 0 (programmatic, used by tests that pin no reserve) is honored.
    #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(explicit: 0, env: [:]) == 0)
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

@Test func liveHeadroomHonorsTheHardCapFloorAsKVGrows() {
    // liveKVHeadroom uses the SAME hardCapBytes ceiling (incl. the 2 GiB OS
    // floor) as the load gate, so on a small box the floor binds even at
    // fraction 1.0 — KV growing during serving can't push past physical − 2 GiB.
    // 8 GiB box, fraction 1.0, no MLX usage, infinite OS, 0 activations:
    // cap = min(8, 8−2) = 6 GiB → headroom 6 GiB, NOT the full 8.
    let headroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: 8 * gib, mlxUsedBytes: 0, systemAvailableBytes: .max,
        activationReserveBytes: 0, capFraction: 1.0)
    #expect(headroom == 6 * gib)
    // The exact over-admission Codex flagged: 8 GiB host, 2 GiB resident weights,
    // 3 GiB activations. Pre-fix headroom was 7.2−2−3 = 2.2 GiB (→ 2+2.2+3 = 7.2,
    // OS < 1 GiB). With the floor it's 6−2−3 = 1 GiB, keeping ≥2 GiB for the OS.
    let constrained = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: 8 * gib, mlxUsedBytes: 2 * gib, systemAvailableBytes: .max,
        activationReserveBytes: 3 * gib)
    #expect(constrained == 1 * gib)
}

// MARK: - loadReserveBytes (cap-aware model-load gate reserve)

@Test func loadReserveIsCapImpliedWhenLargerThanConfig() {
    // 128 GiB, 90% cap = 115.2 GiB → cap-implied reserve = 12.8 GiB, which
    // dominates a 4 GiB configured reserve. The load gate must hold back the
    // bigger one so loads can't push past the cap.
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: 128 * gib)
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: 128 * gib, configReserveBytes: 4 * gib)
    #expect(reserve == 128 * gib - cap)        // = 12.8 GiB
    #expect(reserve > 4 * gib)
}

@Test func loadReserveIsConfigWhenLargerThanCapImplied() {
    // A box where the operator set a reserve bigger than the cap's 10%: keep the
    // more conservative configured value. 16 GiB box: cap-implied = 1.6 GiB, but
    // floor makes cap = 14 GiB → cap-implied = 2 GiB; config 8 GiB wins.
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: 16 * gib, configReserveBytes: 8 * gib)
    #expect(reserve == 8 * gib)
}

@Test func loadReserveHonorsCapEvenWithZeroConfig() {
    // Standalone mode passes configReserve 0 — the cap-implied reserve still
    // holds memory back so a load can't exceed the cap.
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: 64 * gib)
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: 64 * gib, configReserveBytes: 0)
    #expect(reserve == 64 * gib - cap)         // = 6.4 GiB, not 0
    #expect(reserve > 0)
}

// MARK: - loadHeadroomBytes (load gate must not under-reserve vs runtime KV)

@Test func loadHeadroomCoversActivationReservePlusMinKV() {
    // Regression for the cross-phase bug: the load gate's old flat 2 GiB headroom
    // was LESS than the 3 GiB activation reserve, so a near-cap model could load
    // but GlobalKVCacheBudget rejected every request. loadHeadroomBytes must be
    // activationReserve + minimumLoadKV, so a model that passes the gate can
    // actually serve.
    let headroom = UnifiedMemoryCap.loadHeadroomBytes(activationReserveBytes: 3 * gib)
    #expect(headroom == 3 * gib + UnifiedMemoryCap.minimumLoadKVBytes)
    #expect(headroom >= 3 * gib, "load headroom must cover at least the activation reserve")
    // Honors the env-resolved activation reserve by default.
    #expect(UnifiedMemoryCap.loadHeadroomBytes()
        == UnifiedMemoryCap.defaultActivationReserveBytes + UnifiedMemoryCap.minimumLoadKVBytes)
}

@Test func aModelThatPassesTheLoadGateHasServeableKV() {
    // End-to-end invariant: if canAdmit-style load room exists (weights + load
    // headroom ≤ cap), then kvBudget after load is ≥ the minimum KV. 64 GiB box,
    // cap 57.6. A 50 GiB model: load needs 50 + (3+1)=54 ≤ 57.6 → admit. Post-load
    // KV budget = 57.6 − 50 − 3 = 4.6 GiB ≥ 1 GiB min. Good.
    let phys = 64 * gib
    let weights = 50 * gib
    let loadHeadroom = UnifiedMemoryCap.loadHeadroomBytes(activationReserveBytes: 3 * gib)
    let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: phys)
    let admits = weights + loadHeadroom <= cap
    #expect(admits)
    let kv = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: phys, residentWeightBytes: weights, activationReserveBytes: 3 * gib)
    #expect(kv >= UnifiedMemoryCap.minimumLoadKVBytes,
        "a model that passes the load gate must have at least minimum serveable KV")
}

// MARK: - Post-load guard decision (measured headroom vs minimum serveable KV)

@Test func postLoadGuardRejectsWhenMeasuredHeadroomBelowMinimum() {
    // The post-load guard (BatchScheduler.hasServeableKVHeadroom) is exactly
    // `measuredLiveKVHeadroomBytes >= minimumLoadKVBytes`, where the measured
    // headroom is liveKVHeadroomBytes(real MLX usage). Pin that boundary here
    // (the BatchScheduler accessor reads real MLX globals, not injectable).
    let phys = 64 * gib                       // cap 57.6
    let activation = 3 * gib
    // Estimate said the model fit, but MEASURED residency turned out larger:
    // 55.5 GiB actually resident → headroom = 57.6 − 55.5 − 3 = clamped to 0.
    let measuredOverHeadroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: phys, mlxUsedBytes: UInt64(55.5 * Double(gib)),
        systemAvailableBytes: .max, activationReserveBytes: activation)
    #expect(measuredOverHeadroom < UnifiedMemoryCap.minimumLoadKVBytes,
        "an over-estimate-residency model must be rejected by the post-load guard")

    // A model whose real residency leaves room keeps serveable KV → admitted.
    // 50 GiB resident → headroom = 57.6 − 50 − 3 = 4.6 GiB ≥ 1 GiB min.
    let measuredOkHeadroom = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: phys, mlxUsedBytes: 50 * gib,
        systemAvailableBytes: .max, activationReserveBytes: activation)
    #expect(measuredOkHeadroom >= UnifiedMemoryCap.minimumLoadKVBytes,
        "a model with real serveable KV must pass the post-load guard")

    // The guard's actual decision function (what BatchScheduler.hasServeableKV
    // Headroom delegates to): reject below the minimum, admit at/above it.
    #expect(!UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: measuredOverHeadroom))
    #expect(UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: measuredOkHeadroom))
    // Exact boundary: one byte below min rejects; exactly min admits.
    #expect(!UnifiedMemoryCap.loadIsServeable(
        measuredLiveKVHeadroomBytes: UnifiedMemoryCap.minimumLoadKVBytes - 1))
    #expect(UnifiedMemoryCap.loadIsServeable(
        measuredLiveKVHeadroomBytes: UnifiedMemoryCap.minimumLoadKVBytes))
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
