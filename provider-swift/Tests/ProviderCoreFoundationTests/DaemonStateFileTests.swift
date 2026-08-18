import Foundation
import Testing
@testable import ProviderCoreFoundation

// DaemonState / DaemonStateFile live in ProviderCoreFoundation so the
// Darkbloom macOS app links the contract without MLX; these are the pure
// round-trip/staleness/schema tests (moved from ProviderCoreTests when the
// types moved down).

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dstate-\(UUID().uuidString).json")
}

@Test func daemonStateRoundTrips() {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let state = DaemonState(
        pid: 4711, version: "0.5.15", writtenAt: 1000, startedAt: 900,
        attestationPublicKey: "active-signer-key",
        trust: .init(trustLevel: "self_signed", status: "online", reason: "awaiting", receivedAt: 950),
        currentModel: "qwen", warmModels: ["qwen"], inferenceActive: true,
        stats: .init(requestsServed: 412, tokensGenerated: 98231, usageGaps: 3))
    DaemonStateFile.write(state, to: url)
    let read = DaemonStateFile.read(from: url)
    #expect(read?.pid == 4711)
    #expect(read?.trust?.reason == "awaiting")
    #expect(read?.stats.usageGaps == 3)
    #expect(read?.currentModel == "qwen")
    #expect(read?.attestationPublicKey == "active-signer-key")
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

@Test("daemon state written before signer identity was added still decodes")
func legacyDaemonStateWithoutAttestationIdentityDecodes() throws {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let legacyJSON = """
        {
          "schema": 1,
          "pid": 4711,
          "version": "0.8.1",
          "written_at": 1000,
          "started_at": 900,
          "warm_models": [],
          "inference_active": false,
          "stats": {
            "requests_served": 0,
            "tokens_generated": 0,
            "usage_gaps": 0
          }
        }
        """
    try Data(legacyJSON.utf8).write(to: url)

    let state = try #require(DaemonStateFile.read(from: url))
    #expect(state.pid == 4711)
    #expect(state.attestationPublicKey == nil)
}

