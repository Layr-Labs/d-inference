import Foundation
import Testing
@testable import ProviderCore

// MARK: - TrustReasonCatalog

@Test func trustReasonCatalogMapsKnownReasons() {
    // Every reason string the coordinator emits must produce a non-empty,
    // operator-actionable message (and a fix for the actionable ones).
    let reasons = [
        "SE attestation verified, awaiting MDM/ACME upgrade",
        "MDM verification passed",
        "ACME device attestation verified",
        "recovered after transient deroute",
        "timeout", "no response", "nonce mismatch", "public key mismatch",
        "empty signature", "SIP status not reported", "SIP disabled",
        "Secure Boot disabled", "RDMA status not reported — provider must update to v0.2.0+",
        "binary hash mismatch", "binary hash changed from registration attestation",
        "attested binary hash missing", "binary hash missing",
        "valid attestation required for binary hash policy",
        "active model weight hash mismatch",
    ]
    for r in reasons {
        let advice = TrustReasonCatalog.advice(level: "self_signed", status: "untrusted", reason: r)
        #expect(!advice.message.isEmpty, "empty message for reason \(r)")
    }
}

@Test func trustReasonCatalogPrefixMatchesSignatureFailures() {
    let a = TrustReasonCatalog.advice(level: "hardware", status: "untrusted",
                                      reason: "signature verification failed: bad point")
    #expect(a.message.lowercased().contains("signature"))
    #expect(a.fix != nil)

    let b = TrustReasonCatalog.advice(level: "hardware", status: "untrusted",
                                      reason: "status signature verification failed: canonical mismatch")
    #expect(b.fix != nil)
}

@Test func trustReasonCatalogEchoesUnknownReasonVerbatim() {
    let novel = "some-brand-new-coordinator-reason-v9"
    let advice = TrustReasonCatalog.advice(level: "self_signed", status: "online", reason: novel)
    #expect(advice.message.contains(novel), "unknown reason must be surfaced verbatim, not hidden")
}

@Test func trustReasonCatalogLevels() {
    #expect(TrustReasonCatalog.level(trustLevel: "hardware", status: "online") == .pass)
    #expect(TrustReasonCatalog.level(trustLevel: "self_signed", status: "online") == .warn)
    #expect(TrustReasonCatalog.level(trustLevel: "hardware", status: "untrusted") == .fail)
}

// MARK: - OSStatusCatalog

@Test func osStatusCatalogMapsLockedKey() {
    let a = OSStatusCatalog.advice(osStatus: -25308)
    #expect(a.message.contains("-25308"))
    #expect(a.fix?.contains("console") == true)
}

@Test func osStatusCatalogMapsMissingEntitlement() {
    let a = OSStatusCatalog.advice(osStatus: -34018)
    #expect(a.message.lowercased().contains("entitlement"))
}

@Test func osStatusCatalogUnknownEchoesCode() {
    let a = OSStatusCatalog.advice(osStatus: -99999)
    #expect(a.message.contains("-99999"))
}

// MARK: - ModelFitDiagnostic

@Test func modelFitFailsWhenTooLarge() {
    // Cap-aware gate: required = weights + loadHeadroom (activation reserve 3 GB
    // + min serveable KV 1 GB = 4 GB). 25 GB weights needs 29 GB > 21 usable → fail.
    let d = ModelFitDiagnostic.diagnose(modelID: "big", weightGb: 25.0, usableGb: 21.0)
    #expect(d.level == .fail)
    #expect(d.message.contains("29"))
}

@Test func modelFitPassesWhenItFits() {
    // 5 GB weights needs 5 + 4 = 9 GB ≤ 21 usable → pass.
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
    // Parity with the runtime gate, cap-aware: gpt-oss (~13.5 GB weights) now
    // needs 13.5 + 4 (activation 3 + min-KV 1) = 17.5 GB. On a 24 GB box with the
    // OS reporting ~22 GB free it FITS — usable 22 − 4 = 18 ≥ 17.5 — matching
    // ProviderLoop, which would load it with serveable KV headroom.
    let usable = ModelFitDiagnostic.usableInferenceGb(totalGb: 24, reserveGb: 4, systemAvailableGb: 22)
    let ok = ModelFitDiagnostic.diagnose(modelID: "gpt-oss", weightGb: 13.5, usableGb: usable)
    #expect(ok.level == .pass, "doctor must agree with the runtime gate that gpt-oss fits with serveable KV")
    // But a tighter box (OS only 18 GB free → usable 14) must FAIL: 14 < 17.5.
    // Pre-cap-aware this wrongly "passed" at 15.5, then the runtime KV gate would
    // have rejected every request — the bug this stricter headroom fixes.
    let tight = ModelFitDiagnostic.usableInferenceGb(totalGb: 24, reserveGb: 4, systemAvailableGb: 18)
    let bad = ModelFitDiagnostic.diagnose(modelID: "gpt-oss", weightGb: 13.5, usableGb: tight)
    #expect(bad.level == .fail)
}

@Test func modelFitSuggestsFittingAlternatives() {
    let alts = [
        ModelFitDiagnostic.ModelOption(id: "small", weightGb: 5.0),
        ModelFitDiagnostic.ModelOption(id: "huge", weightGb: 40.0),
    ]
    // huge needs 42 > 21 → fail; small needs 7 ≤ 21 → suggested.
    let d = ModelFitDiagnostic.diagnose(modelID: "huge", weightGb: 40.0, usableGb: 21.0, alternatives: alts)
    #expect(d.level == .fail)
    #expect(d.fix?.contains("small") == true)
    #expect(d.fix?.contains("huge") != true) // huge doesn't fit, must not be suggested
}

// MARK: - VersionDiagnostic

@Test func versionParseAndCompare() {
    #expect(VersionDiagnostic.parse("v1.2.3") == [1, 2, 3])
    #expect(VersionDiagnostic.parse("0.5.15-beta") == [0, 5, 15])
    #expect(VersionDiagnostic.parse("garbage") == nil)
    #expect(VersionDiagnostic.compare("0.5.15", "0.6.0") == -1)
    #expect(VersionDiagnostic.compare("1.0.0", "1.0.0") == 0)
    #expect(VersionDiagnostic.compare("2.0.0", "1.9.9") == 1)
}

@Test func versionDiagnoseBelowMinimumFails() {
    let d = VersionDiagnostic.diagnose(current: "0.5.15", minimum: "0.6.0", latest: "0.7.0")
    #expect(d.level == .fail)
}

@Test func versionDiagnoseBehindLatestWarns() {
    let d = VersionDiagnostic.diagnose(current: "0.6.0", minimum: "0.5.0", latest: "0.7.0")
    #expect(d.level == .warn)
}

@Test func versionDiagnoseCurrentPasses() {
    let d = VersionDiagnostic.diagnose(current: "0.7.0", minimum: "0.5.0", latest: "0.7.0")
    #expect(d.level == .pass)
}

// MARK: - DaemonStateFile

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dstate-\(UUID().uuidString).json")
}

@Test func daemonStateRoundTrips() {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let state = DaemonState(
        pid: 4711, version: "0.5.15", writtenAt: 1000, startedAt: 900,
        trust: .init(trustLevel: "self_signed", status: "online", reason: "awaiting", receivedAt: 950),
        currentModel: "qwen", warmModels: ["qwen"], inferenceActive: true,
        stats: .init(requestsServed: 412, tokensGenerated: 98231, usageGaps: 3))
    DaemonStateFile.write(state, to: url)
    let read = DaemonStateFile.read(from: url)
    #expect(read?.pid == 4711)
    #expect(read?.trust?.reason == "awaiting")
    #expect(read?.stats.usageGaps == 3)
    #expect(read?.currentModel == "qwen")
}

@Test func daemonStateStaleness() {
    let state = DaemonState(pid: 1, version: "x", writtenAt: 1000, startedAt: 1000)
    #expect(state.isStale(now: 1030) == false) // 30s
    #expect(state.isStale(now: 1100) == true)  // 100s > 90s
    #expect(state.uptimeSeconds(now: 1100) == 100)
}

@Test func daemonStateReadHandlesGarbageAndMissing() {
    let missing = tmpStateURL()
    #expect(DaemonStateFile.read(from: missing) == nil)

    let garbage = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: garbage) }
    try? "{not json".data(using: .utf8)!.write(to: garbage)
    #expect(DaemonStateFile.read(from: garbage) == nil)
}

@Test func daemonStateRejectsWrongSchema() {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var state = DaemonState(pid: 1, version: "x", writtenAt: 1, startedAt: 1)
    state.schema = 999
    DaemonStateFile.write(state, to: url)
    #expect(DaemonStateFile.read(from: url) == nil, "future schema must be rejected, not mis-decoded")
}

@Test func daemonProcessAliveForSelfAndDeadPid() {
    #expect(daemonProcessAlive(pid: getpid()) == true)
    #expect(daemonProcessAlive(pid: 0) == false)
    #expect(daemonProcessAlive(pid: 999_999) == false) // almost certainly dead
}

// MARK: - WarmModelsFormat

@Test func warmModelsLineListsEveryResidentModel() {
    // The whole point of the fix: a box keeps multiple models warm and the CLI
    // must show all of them, not just the LRU slot.
    let line = WarmModelsFormat.warmModelsLine(
        warmModels: ["gemma-4-26b", "gpt-oss-20b"],
        currentModel: "gpt-oss-20b")
    #expect(line == "gemma-4-26b, gpt-oss-20b")
}

@Test func warmModelsLineFallsBackToCurrentWhenWarmSetEmpty() {
    // Back-compat: a daemon predating the warm_models field reports only
    // currentModel; the line must still show that one model, not "none loaded".
    let line = WarmModelsFormat.warmModelsLine(warmModels: [], currentModel: "qwen")
    #expect(line == "qwen")
}

@Test func warmModelsLineEmptyWhenNothingLoaded() {
    #expect(WarmModelsFormat.warmModelsLine(warmModels: [], currentModel: nil) == "none loaded")
    // Custom placeholder is honored.
    #expect(WarmModelsFormat.warmModelsLine(
        warmModels: [], currentModel: nil, emptyPlaceholder: "—") == "—")
}

@Test func warmModelsLineDeduplicatesAndDropsBlanks() {
    let line = WarmModelsFormat.warmModelsLine(
        warmModels: ["a", "", "a", "b"], currentModel: "a")
    #expect(line == "a, b")
}

@Test func mostRecentlyUsedLineReportsLRUSlot() {
    #expect(WarmModelsFormat.mostRecentlyUsedLine(currentModel: "gpt-oss-20b") == "gpt-oss-20b")
    #expect(WarmModelsFormat.mostRecentlyUsedLine(currentModel: nil) == "none loaded")
    #expect(WarmModelsFormat.mostRecentlyUsedLine(currentModel: "") == "none loaded")
}

@Test func mostRecentlyUsedLabelIsRelabeled() {
    // Regression guard: the single value must not be labeled "Current model",
    // which implied the box served only one model.
    #expect(WarmModelsFormat.mostRecentlyUsedLabel == "Most recently used")
    #expect(WarmModelsFormat.mostRecentlyUsedLabel != "Current model")
}
