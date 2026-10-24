import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// The leader reads its rank-0 session through the status codec. A Qwen27
/// tensor-parallel resident assistant runs under a generation mode that names
/// no head, so the saved setup's binding carries the speculation the session
/// derives; an MTP-serving pair must read as ready, never as stale.
@Suite("Cluster status speculation")
struct ClusterStatusSpeculationTests {
    private static let nonce = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

    private func binding(mode: ClusterGenerationMode, enabled: Bool, reason: String) throws -> ClusterStatusBinding {
        func pin(_ character: Character) -> String { String(repeating: String(character), count: 64) }
        let peers = (0..<2).map { rank -> [String: Any] in
            ["id": "peer-\(rank)", "rank": rank, "runtimeBinarySHA256": pin("3"),
             "supportedGenerationModes": [ClusterGenerationMode.pipeline.rawValue, mode.rawValue]]
        }
        return try JSONDecoder().decode(ClusterStatusBinding.self, from: JSONSerialization.data(withJSONObject: [
            "clusterID": "fixture-cluster", "memberID": "peer-0", "role": "leader", "configurationSHA256": pin("d"),
            "capabilitySHA256": pin("1"), "publicModelID": "EigenLabs/Qwen3.8-27B-4bit-mtp",
            "runtimeModelID": "registered_qwen38_27b", "artifactSHA256": pin("b"),
            "configurationModelSHA256": pin("2"), "planSHA256": pin("c"), "prefillSchedule": ClusterPrefillSchedule.serial.rawValue,
            "generationMode": mode.rawValue, "speculationEnabled": enabled, "speculationOffReason": reason, "peers": peers,
        ] as [String: Any]))
    }

    private func status(_ binding: ClusterStatusBinding, mtp: Bool, reason: String) -> ClusterLiveStatus {
        .init(schema: ClusterLiveStatus.schemaName, nonce: Self.nonce, binding: binding, authenticationConfigured: true,
            hostPhase: "serving",
            session: .init(binding: binding, phase: "ready", observedMembershipEpoch: "11111111-2222-3333-4444-555555555555",
                observedPrefillSchedule: .serial, observedGenerationMode: binding.generationMode, ready: true,
                admission: .init(requestsServed: 0, keepWarmExchanges: 0, activeRequest: false, draining: false, valid: true),
                members: (0..<2).map { .init(peerID: "peer-\($0)", rank: $0, transport: $0 == 0 ? .localPipes : .authenticatedSSH,
                    nativeReady: true, requestCapacityBytes: 1024, nativeCleanupObserved: false,
                    ownerReleaseAcknowledged: false, ownerTermination: nil) },
                mtpEnabled: mtp, mtpOffReason: reason, nativeBootstrap: .directNative,
                collectiveProgressLimitMilliseconds: 60_000),
            boundPort: 8000, acquisitions: 0, failed: false, ready: true, admissionAvailable: true, quarantined: false)
    }

    private func decode(_ value: ClusterLiveStatus, expecting binding: ClusterStatusBinding) throws -> ClusterLiveStatus {
        try ClusterStatusCodec.decode(try ClusterStatusCodec.encode(value), nonce: Self.nonce, binding: binding,
            authenticationConfigured: true, port: 8000)
    }

    @Test func aRunningTensorAssistantReadsAsReadyNotStale() throws {
        let assisted = try binding(mode: .tensorParallel, enabled: true, reason: DistributedInstalledSpeculation.enabledReason)
        let read = try decode(status(assisted, mtp: true, reason: "none"), expecting: assisted)
        #expect(read.session.mtpEnabled && read.ready)
        // The session must report what the saved setup runs, either way.
        #expect(throws: (any Error).self) {
            _ = try decode(status(assisted, mtp: false, reason: "generationModeRunsNoHead"), expecting: assisted)
        }
    }

    @Test func anOrdinaryTensorSetupStillRefusesAClaimedHead() throws {
        let plain = try binding(mode: .tensorParallel, enabled: false, reason: "generationModeRunsNoHead")
        #expect(try !decode(status(plain, mtp: false, reason: "generationModeRunsNoHead"), expecting: plain).session.mtpEnabled)
        #expect(throws: (any Error).self) { _ = try decode(status(plain, mtp: true, reason: "none"), expecting: plain) }
        // A status bound to another setup's speculation is another setup.
        let assisted = try binding(mode: .tensorParallel, enabled: true, reason: "none")
        #expect(throws: (any Error).self) { _ = try decode(status(assisted, mtp: true, reason: "none"), expecting: plain) }
    }

    @Test func anUnknownOffReasonIsRefused() throws {
        let odd = try binding(mode: .tensorParallel, enabled: false, reason: "invented")
        #expect(throws: (any Error).self) { _ = try decode(status(odd, mtp: false, reason: "invented"), expecting: odd) }
    }
}
