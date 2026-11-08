import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Which member hosts its pair's slot (`ClusterMemberPreparation.hostsPairSlot`), and so may run the pair's local API
/// beside Darkbloom: rank 0 of a setup saved for coordinator pairing (`nativeMember`) over the link control channel.
/// Every other member reads a key for no API (#1884 review, N6: mutant M17, "every member is the slot's host").
@Suite("Cluster pair: the member that hosts the pair's slot")
struct ClusterPairSlotHostTests {
    @Test func onlyRankZeroOfACoordinatorPairedSetupOverTheLinkHostsTheSlot() throws {
        let f = try Fixture()
        #expect(ClusterMemberPreparation.hostsPairSlot(try f.setup(rank: 0, paired: true, link: true)))
        #expect(!ClusterMemberPreparation.hostsPairSlot(try f.setup(rank: 1, paired: true, link: true)), "the other rank")
        #expect(!ClusterMemberPreparation.hostsPairSlot(try f.setup(rank: 0, paired: false, link: true)), "not coordinator-paired")
        #expect(!ClusterMemberPreparation.hostsPairSlot(try f.setup(rank: 0, paired: true, link: false)), "reached over SSH")
    }

    /// A saved setup as `ClusterConfigurationCodec` decodes it, on the shape of the native member attachment's tests.
    private struct Fixture {
        let capability: ClusterRuntimeCapability
        let capabilityHash: String
        static func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

        init() throws {
            let h = Self.hash
            let profile = ClusterWorkerProfile(id: "registered_qwen35_9b_greedy_generation_v1", vocabularySize: 248320,
                maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
            capability = try ClusterRuntimeCapability(runtimeBinarySHA256: h("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
                runtimeModelID: "registered_qwen35_9b", artifactSHA256: h("b"), configurationSHA256: h("c"), manifestSHA256: h("d"),
                profile: profile, profileFingerprint: h("e"), partitions: [.init(planSHA256: h("f"), stages: [
                    .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 16, stagePlanSHA256: h("1"), constructionConfigurationSHA256: h("2")),
                    .init(rank: 1, sourceLayerStart: 16, sourceLayerEnd: 32, stagePlanSHA256: h("3"), constructionConfigurationSHA256: h("4"))])],
                arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: h("5"))
            capabilityHash = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(capability))
        }

        /// The setup of the Mac that runs `rank`: with the coordinator's approval entry when `paired`, and reaching the
        /// other Mac over the link control channel when `link` (else over SSH).
        func setup(rank: Int, paired: Bool, link: Bool) throws -> ClusterConfiguration {
            let h = Self.hash
            func peer(_ rank: Int) -> [String: Any] {
                ["id": "peer-\(rank)", "rank": rank, "host": "peer-\(rank).local", "port": 22, "user": "fixture",
                 "ownerExecutable": "/fixture/owner", "workerExecutable": "/fixture/native", "modelDirectory": "/fixture/model",
                 "runtimeBinarySHA256": h("a"), "jacclDevice": "rdma_en\(rank)"]
            }
            var object: [String: Any] = ["schema": ClusterConfiguration.schemaName, "clusterID": "fixture",
                "memberID": "peer-\(rank)", "role": rank == 0 ? "leader" : "follower",
                "publicModelID": "fixture/qwen", "capabilitySHA256": capabilityHash, "selectedPlanSHA256": h("f"),
                "chunkTokens": 16, "requestTimeoutSeconds": 300, "peers": [peer(0), peer(1)],
                "coordinator": ["address": "192.168.2.1", "port": 12345],
                "tokenizerFiles": [["path": "tokenizer.json", "sha256": h("6"), "purpose": "tokenizer"]]]
            if link {
                object["linkControl"] = ["schema": ClusterLinkControlAttachment.schemaName, "port": 47999,
                                         "linkEpoch": "00000000-0000-4000-8000-000000000001",
                                         "edgeID": "00000000-0000-4000-8000-000000000002", "secretFile": "/fixture/link.secret"]
            } else {
                object["trust"] = ["identityFile": "/fixture/key", "knownHostsFile": "/fixture/known_hosts", "knownHostsSHA256": h("8")]
            }
            if paired {
                let approval: [String: Any] = ["id": "fixture-approval", "model": "fixture/qwen", "generation": 1,
                    "plan_sha256": h("f"), "artifact_sha256": h("b"), "native_runtime_sha256": h("a"),
                    "metallib_sha256": h("3"), "resource_library_sha256": h("4"), "capability_sha256": capabilityHash,
                    "resource_policy_sha256": h("9"), "profile_sha256": h("e"),
                    "schedule": 1, "maximum_transport_frame": 131_112, "maximum_plaintext": 131_072,
                    "maximum_records": 1024, "maximum_cumulative_plaintext": 16_777_216,
                    "allowed_chips": ["Apple M4"], "not_after": "2033-05-18T03:33:20Z"]
                object["nativeMember"] = ["schema": ClusterNativeMemberAttachment.schemaName, "ownerSHA256": h("1"),
                    "metallibPath": "/fixture/mlx.metallib", "resourceLibraryPath": "/fixture/resource.metallib",
                    "approval": approval]
            }
            return try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                capability: capability, capabilitySHA256: capabilityHash)
        }
    }
}
