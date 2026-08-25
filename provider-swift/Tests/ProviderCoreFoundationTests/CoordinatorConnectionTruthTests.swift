import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Coordinator connection truth")
struct CoordinatorConnectionTruthTests {
    @Test("verified trust is revoked on disconnect and only a fresh status restores it")
    func verifiedDisconnectReconnectVerified() {
        var truth = CoordinatorConnectionTruth()

        truth.recordConnected(at: 100)
        #expect(truth.recordTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "MDM verification passed",
            at: 101
        ))
        #expect(truth.trust?.status == "verified")
        #expect(truth.connectivity.status == .connected)

        truth.recordDisconnected(reason: "transport reset", at: 102)
        #expect(truth.trust?.trustLevel == "hardware")
        #expect(truth.trust?.status == "offline")
        #expect(truth.trust?.reason == "transport reset")
        #expect(truth.connectivity.status == .disconnected)
        #expect(truth.connectivity.reconnectCount == 1)

        truth.recordConnected(at: 103)
        #expect(truth.connectivity.status == .connected)
        #expect(truth.trust?.status == "offline")

        #expect(truth.recordTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "fresh verification",
            at: 104
        ))
        #expect(truth.trust?.status == "verified")
        #expect(truth.trust?.receivedAt == 104)
    }

    @Test("trust statuses without a connected transport fail closed")
    func disconnectedTrustStatusIsIgnored() {
        var truth = CoordinatorConnectionTruth()

        #expect(!truth.recordTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "late status",
            at: 100
        ))
        #expect(truth.trust == nil)

        truth.recordDisconnected(reason: "offline", at: 101)
        #expect(!truth.recordTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "late status",
            at: 102
        ))
        #expect(truth.trust?.status == "offline")
    }

    @Test("non-reconnect lifecycle transitions do not inflate reconnect count")
    func scheduledDowntimeDoesNotCountAsReconnect() {
        var truth = CoordinatorConnectionTruth()
        truth.recordConnected(at: 100)
        truth.recordDisconnected(
            reason: "scheduled downtime",
            at: 101,
            incrementsReconnectCount: false
        )

        #expect(truth.connectivity.reconnectCount == 0)
        #expect(truth.connectivity.status == .disconnected)
        #expect(truth.trust?.status == "offline")
    }

    @Test("authoritative connection and trust fields round-trip through the daemon store")
    func daemonStateRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-truth-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("daemon-state.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var truth = CoordinatorConnectionTruth()
        truth.recordConnected(at: 100)
        _ = truth.recordTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "verified",
            at: 101
        )
        truth.recordDisconnected(reason: "transport reset", at: 102)
        DaemonStateFile.write(DaemonState(
            pid: 42,
            version: "test",
            writtenAt: 102,
            startedAt: 90,
            trust: truth.trust,
            connectivity: truth.connectivity
        ), to: url)

        let restored = try #require(DaemonStateFile.read(from: url))
        #expect(restored.trust?.status == "offline")
        #expect(restored.connectivity?.status == .disconnected)
        #expect(restored.connectivity?.changedAt == 102)
        #expect(restored.connectivity?.reconnectCount == 1)
    }
}
