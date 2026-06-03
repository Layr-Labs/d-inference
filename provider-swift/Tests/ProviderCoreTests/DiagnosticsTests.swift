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
    let d = ModelFitDiagnostic.diagnose(modelID: "big", weightGb: 19.0, usableGb: 21.0)
    // needs 19*2=38 > 21 → fail
    #expect(d.level == .fail)
    #expect(d.message.contains("38"))
}

@Test func modelFitPassesWhenItFits() {
    let d = ModelFitDiagnostic.diagnose(modelID: "small", weightGb: 5.0, usableGb: 21.0)
    #expect(d.level == .pass)
}

@Test func usableInferenceGbMatchesProviderAccounting() {
    // (total − reserve − gpuActive − cache) × 0.7. Must match
    // ProviderLoop.availableMemoryGb() so doctor and the provider agree.
    // 32 GB box, 4 GB reserve, idle: (32 − 4) × 0.7 = 19.6.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4) - 19.6) < 0.001)
    // With 5 GB GPU active: (32 − 4 − 5) × 0.7 = 16.1.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, gpuActiveGb: 5) - 16.1) < 0.001)
    // Never negative.
    #expect(ModelFitDiagnostic.usableInferenceGb(totalGb: 8, reserveGb: 16) == 0)
}

@Test func modelFitUsesProviderUsableMemoryNotRawAvailable() {
    // Regression for the review finding: a 9 GB-weight model (needs 18 GB) on a
    // 24 GB box must FAIL — usable is (24−4)×0.7 = 14 GB, NOT the raw 20 GB.
    let usable = ModelFitDiagnostic.usableInferenceGb(totalGb: 24, reserveGb: 4)
    let d = ModelFitDiagnostic.diagnose(modelID: "mid", weightGb: 9.0, usableGb: usable)
    #expect(d.level == .fail, "must reflect the provider's 0.7 gate, not total−reserve")
}

@Test func modelFitSuggestsFittingAlternatives() {
    let alts = [
        ModelFitDiagnostic.ModelOption(id: "small", weightGb: 5.0),
        ModelFitDiagnostic.ModelOption(id: "huge", weightGb: 40.0),
    ]
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
