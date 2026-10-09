import Foundation
import Testing
@testable import ProviderCore

/// The `cluster_membership` claim in the member `register` frame, checked on
/// the bytes the provider emits against what the coordinator accepts
/// (coordinator/protocol/execution_role.go, `ClusterMembership.Validate`).
@Suite("Cluster membership registration")
struct ClusterMembershipTests {
    private static let policy = String(repeating: "ab", count: 32)
    private static let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4,
        chipTier: .pro, memoryGb: 24, memoryAvailableGb: 20,
        cpuCores: .init(total: 12, performance: 8, efficiency: 4), gpuCores: 16, memoryBandwidthGbs: 200)

    private func config(role: ProviderExecutionRole, membership: ClusterMembership?,
                        attested: Bool) -> CoordinatorClientConfig {
        .init(url: "wss://coordinator.invalid/ws", hardware: Self.hardware,
              models: [.init(id: "fixture-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
              backendName: "mlx-swift",
              attestation: attested ? .init(rawBytes: Data(#"{"signed":"fixture"}"#.utf8)) : nil,
              executionRole: role, clusterMembership: membership)
    }
    private func frame(role: ProviderExecutionRole, membership: ClusterMembership?, attested: Bool) throws -> String {
        String(decoding: try CoordinatorClientCodec.encodeRegistration(
            from: config(role: role, membership: membership, attested: attested),
            memberRegistrationNonce: String(repeating: "0", count: 64)), as: UTF8.self)
    }

    @Test("Member register carries the exact claim on both encoder paths", arguments: [false, true])
    func memberRegisterCarriesTheExactClaim(attested: Bool) throws {
        for rank in 0..<2 {
            let membership = try ClusterMembership(clusterID: "pair-a.1_x", rank: rank, policySHA256: Self.policy)
            let text = try frame(role: .clusterMember, membership: membership, attested: attested)
            // Go decodes by key, so only the object's own bytes are pinned.
            #expect(text.contains(#""cluster_membership":{"cluster_id":"pair-a.1_x","policy_sha256":"\#(Self.policy)","rank":\#(rank)}"#))
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let claim = try #require(object["cluster_membership"] as? [String: Any])
            #expect(Set(claim.keys) == ["cluster_id", "rank", "policy_sha256"])
            #expect(object["execution_role"] as? String == "cluster_member")
            #expect((object["models"] as? [Any])?.isEmpty == true)
            guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: Data(text.utf8)) else {
                Issue.record("wrong registration type"); return
            }
            #expect(decoded.clusterMembership == membership)
        }
    }

    @Test("Solo never carries the claim and a member may omit it", arguments: [false, true])
    func soloNeverCarriesTheClaim(attested: Bool) throws {
        let membership = try ClusterMembership(clusterID: "pair-a", rank: 0, policySHA256: Self.policy)
        // A solo configuration that was handed a claim still registers none:
        // the coordinator refuses member fields on a solo registration.
        #expect(!(try frame(role: .solo, membership: membership, attested: attested)).contains("cluster_membership"))
        #expect(!(try frame(role: .solo, membership: nil, attested: attested)).contains("cluster_membership"))
        let member = try frame(role: .clusterMember, membership: nil, attested: attested)
        #expect(!member.contains("cluster_membership") && member.contains(#""execution_role":"cluster_member""#))
    }

    @Test func malformedClaimsCannotBeBuiltOrDecoded() throws {
        let long = String(repeating: "a", count: 129)
        for (cluster, rank, policy) in [("", 0, Self.policy), ("-lead", 0, Self.policy), ("pair a", 0, Self.policy),
                ("pair/a", 0, Self.policy), ("päir", 0, Self.policy), (long, 0, Self.policy),
                ("pair-a", 2, Self.policy), ("pair-a", -1, Self.policy),
                ("pair-a", 0, String(repeating: "AB", count: 32)), ("pair-a", 0, String(repeating: "a", count: 63)),
                ("pair-a", 0, String(repeating: "a", count: 65)), ("pair-a", 0, String(repeating: "g", count: 64))] {
            #expect(throws: ClusterMemberControlError.invalidMembership) {
                _ = try ClusterMembership(clusterID: cluster, rank: rank, policySHA256: policy)
            }
            let raw = try JSONSerialization.data(withJSONObject: ["cluster_id": cluster, "rank": rank, "policy_sha256": policy])
            #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(ClusterMembership.self, from: raw) }
        }
        _ = try ClusterMembership(clusterID: String(repeating: "a", count: 128), rank: 1, policySHA256: Self.policy)
    }
}
