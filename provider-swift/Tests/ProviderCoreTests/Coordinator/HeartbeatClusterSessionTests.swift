import Foundation
import Testing

@testable import ProviderCore

/// S16: a cluster member reports, on every heartbeat, the coordinator-formed
/// session its owner runs and whether that session's data plane is encrypted
/// and its peer verified against the pin (`cluster_session`, mirrored by the
/// coordinator's `protocol.ClusterSessionStatus`). Absent while no owner runs.
@Suite("Heartbeat cluster_session")
struct HeartbeatClusterSessionTests {
    private static let epoch = "00112233445566778899aabbccddeeff"

    private func encodedObject(_ session: ClusterSessionStatus?) throws -> [String: Any] {
        let message = CoordinatorClientCodec.heartbeatMessage(
            status: .idle, activeModel: nil, warmModels: [],
            stats: ProviderStats(requestsServed: 0, tokensGenerated: 0),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            backendCapacity: nil, clusterSession: session)
        let data = try ProviderProtocolCodec.encodeProviderMessage(message)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a running session is reported with the coordinator's field names")
    func reportedWithCoordinatorNames() throws {
        let object = try encodedObject(.init(epoch: Self.epoch, generation: 3, encryptedDataPlane: true, peerVerified: true))
        let session = try #require(object["cluster_session"] as? [String: Any])
        #expect(Set(session.keys) == ["epoch", "generation", "encrypted_data_plane", "peer_verified"])
        #expect(session["epoch"] as? String == Self.epoch)
        #expect(session["generation"] as? Int == 3)
        #expect(session["encrypted_data_plane"] as? Bool == true)
        #expect(session["peer_verified"] as? Bool == true)
    }

    @Test("no owner, no field: the legacy wire shape")
    func omittedWithoutOwner() throws {
        #expect(try encodedObject(nil)["cluster_session"] == nil)
    }

    @Test("a verified peer is never claimed on a plaintext data plane")
    func verifiedOnlyWhenEncrypted() throws {
        let value = ClusterSessionStatus(epoch: Self.epoch, generation: 1, encryptedDataPlane: false, peerVerified: true)
        #expect(value.peerVerified == false)
        let session = try #require(try encodedObject(value)["cluster_session"] as? [String: Any])
        #expect(session["encrypted_data_plane"] as? Bool == false)
        #expect(session["peer_verified"] as? Bool == false)
    }

    @Test("the report round-trips and names a session the way its frames do")
    func roundTripAndValidity() throws {
        let value = ClusterSessionStatus(epoch: Self.epoch, generation: 7, encryptedDataPlane: true, peerVerified: false)
        let message = CoordinatorClientCodec.heartbeatMessage(
            status: .serving, activeModel: nil, warmModels: [],
            stats: ProviderStats(requestsServed: 1, tokensGenerated: 1),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            backendCapacity: nil, clusterSession: value)
        let decoded = try JSONDecoder().decode(ProviderMessage.self,
            from: try ProviderProtocolCodec.encodeProviderMessage(message))
        guard case .heartbeat(let heartbeat) = decoded else { Issue.record("expected a heartbeat"); return }
        #expect(heartbeat.clusterSession == value)
        #expect(value.isValid)
        #expect(!ClusterSessionStatus(epoch: Self.epoch.uppercased(), generation: 7, encryptedDataPlane: true, peerVerified: true).isValid)
        #expect(!ClusterSessionStatus(epoch: String(repeating: "0", count: 32), generation: 7, encryptedDataPlane: true, peerVerified: true).isValid)
        #expect(!ClusterSessionStatus(epoch: Self.epoch, generation: 0, encryptedDataPlane: true, peerVerified: true).isValid)
        #expect(!ClusterSessionStatus(epoch: "0011", generation: 1, encryptedDataPlane: true, peerVerified: true).isValid)
    }
}
