import Foundation
import Testing

@testable import ProviderCore


@Test func modelFitFailsWhenTooLarge() {
    // Cap-aware gate: required = weights + loadHeadroom (activation reserve
    // 5.5 GB + min serveable KV 1 GB = 6.5 GB). 25 GB weights needs 31.5 GB
    // > 21 usable → fail.
    let d = ModelFitDiagnostic.diagnose(modelID: "big", weightGb: 25.0, usableGb: 21.0)
    #expect(d.level == .fail)
    #expect(d.message.contains("31.5"))
}

@Test func modelFitPassesWhenItFits() {
    // 5 GB weights needs 5 + 6.5 = 11.5 GB ≤ 21 usable → pass.
    let d = ModelFitDiagnostic.diagnose(modelID: "small", weightGb: 5.0, usableGb: 21.0)
    #expect(d.level == .pass)
}

@Test func usableInferenceGbMatchesProviderAccounting() {
    // Delegates to ModelLoadAdmission.freeForLoadGb. Must match
    // ProviderLoop.availableMemoryGb(): real free minus reserve, NO 0.7 discount.
    // 32 GB box, 4 GB reserve, idle, OS-available unknown: 32 − 4 = 28.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4) - 28.0) < 0.01)
    // With 5 GB GPU active: 32 − 5 − 4 = 23.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, gpuActiveGb: 5) - 23.0) < 0.01)
    // Clamped to live OS-available memory when that is the tighter bound:
    // 32 GB box but OS reports only 10 GB available → 10 − 4 = 6.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, systemAvailableGb: 10) - 6.0) < 0.01)
    // Never negative.
    #expect(ModelFitDiagnostic.usableInferenceGb(totalGb: 8, reserveGb: 16) == 0)
}

@Test func usableInferenceGbHonorsThe90PercentCapOnBigBoxes() {
    // On a big box the 90% unified cap holds back MORE than the 4 GB config
    // reserve, and the doctor verdict must reflect that (matching the runtime
    // gate's loadReserveBytes). 128 GB box: cap = 115.2 GB → reserve = 12.8 GB,
    // so usable = 128 − 12.8 = 115.2, NOT 128 − 4 = 124.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 128, reserveGb: 4) - 115.2) < 0.05)
    // 64 GB box: cap 57.6 → usable 57.6, not 60.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 64, reserveGb: 4) - 57.6) < 0.05)
    // Small/mid box where config reserve already exceeds the cap's 10%: config
    // wins, behavior unchanged (32 − 4 = 28, since cap-implied 3.2 < 4).
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4) - 28.0) < 0.01)
}

@Test func modelFitMatchesRuntimeGateNotRawAvailable() {
    // Parity with the runtime gate, cap-aware: gpt-oss (~13.5 GB weights)
    // needs 13.5 + 6.5 (activation 5.5 + min-KV 1) = 20 GB. On a 32 GB box
    // with the OS reporting ~30 GB free it FITS — usable 30 − 4 = 26 ≥ 20 —
    // matching ProviderLoop, which would load it with serveable KV headroom.
    // (A 24 GB box no longer clears this bar at all under the v0.8.0
    // reserve: 22 − 4 = 18 < 20. That refusal is the point of the raise —
    // the daemon was spending the memory at B=8 whether or not the ledger
    // admitted it.)
    let usable = ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, systemAvailableGb: 30)
    let ok = ModelFitDiagnostic.diagnose(modelID: "gpt-oss", weightGb: 13.5, usableGb: usable)
    #expect(ok.level == .pass, "doctor must agree with the runtime gate that gpt-oss fits with serveable KV")
    // But a tighter box (OS only 22 GB free → usable 18) must FAIL: 18 < 20.
    // Pre-cap-aware this wrongly "passed", then the runtime KV gate would
    // have rejected every request — the bug this stricter headroom fixes.
    let tight = ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, systemAvailableGb: 22)
    let bad = ModelFitDiagnostic.diagnose(modelID: "gpt-oss", weightGb: 13.5, usableGb: tight)
    #expect(bad.level == .fail)
}

@Test func modelFitSuggestsFittingAlternatives() {
    let alts = [
        ModelFitDiagnostic.ModelOption(id: "small", weightGb: 5.0),
        ModelFitDiagnostic.ModelOption(id: "huge", weightGb: 40.0),
    ]
    // huge needs 46.5 > 21 → fail; small needs 11.5 ≤ 21 → suggested.
    let d = ModelFitDiagnostic.diagnose(modelID: "huge", weightGb: 40.0, usableGb: 21.0, alternatives: alts)
    #expect(d.level == .fail)
    #expect(d.fix?.contains("small") == true)
    #expect(d.fix?.contains("huge") != true) // huge doesn't fit, must not be suggested
}

// MARK: - VersionDiagnostic
