import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// The optional `nativeMember` part of a saved cluster setup: where a Mac
/// keeps the coordinator's approval entry so it can register a membership.
@Suite("Saved native member attachment")
struct ClusterNativeMemberAttachmentTests {
    @Test func omissionKeepsTheExistingSetupAndItsExactBytes() throws {
        let f = try Fixture()
        let original = try f.decode(f.configuration)
        #expect(original.nativeMember == nil)
        try original.requireOrdinarySessionRoute()
        let bytes = try ClusterConfigurationCodec.encode(original, capability: f.capability, capabilitySHA256: f.capabilityHash)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("nativeMember"))
        #expect(try f.decode(JSONSerialization.jsonObject(with: bytes) as! [String: Any]) == original)
    }

    @Test func attachmentRoundTripsForBothRanksAndYieldsTheCoordinatorsPolicy() throws {
        let f = try Fixture()
        for rank in 0..<2 {
            var object = f.configuration; object["nativeMember"] = f.attachment
            object["role"] = rank == 0 ? "leader" : "follower"; object["memberID"] = "peer-\(rank)"
            let decoded = try f.decode(object)
            let attachment = try #require(decoded.nativeMember)
            // The saved entry encodes to the same bytes the coordinator derives.
            #expect(try attachment.policyBytes == ClusterPairApprovalTests.approval(f.approval).canonicalPolicy())
            #expect(decoded.localRank == rank)
            let encoded = try ClusterConfigurationCodec.encode(decoded, capability: f.capability, capabilitySHA256: f.capabilityHash)
            #expect(try f.decode(JSONSerialization.jsonObject(with: encoded) as! [String: Any]) == decoded)
        }
    }

    @Test func attachmentRefusesUnknownNullAndMalformedFields() throws {
        let f = try Fixture()
        let changes: [[String: Any]] = [
            ["schema": "other"], ["ownerSHA256": "not-a-hash"], ["ownerSHA256": NSNull()],
            ["metallibPath": "/tmp/../other"], ["metallibPath": "relative/mlx.metallib"],
            ["resourceLibraryPath": "/fixture/native"], ["resourceLibraryPath": "/fixture/mlx.metallib"],
            ["metallibPath": "/fixture/owner"],
            ["privateKey": "never accepted"], ["environment": ["APPROVE": "true"]],
            ["coordinatorPolicyBase64": "AAAA"], ["approval": NSNull()], ["approval": "golden"]]
        for change in changes {
            var attachment = f.attachment; change.forEach { attachment[$0] = $1 }
            var object = f.configuration; object["nativeMember"] = attachment
            #expect(throws: (any Error).self, "\(change.keys) must be refused") { try f.decode(object) }
        }
        for change in [["unreviewed": true], ["not_after": "tomorrow"], ["schedule": 3], ["allowed_chips": ["b", "a"]]] as [[String: Any]] {
            var approval = f.approval; change.forEach { approval[$0] = $1 }
            var attachment = f.attachment; attachment["approval"] = approval
            var object = f.configuration; object["nativeMember"] = attachment
            #expect(throws: (any Error).self, "approval \(change.keys) must be refused") { try f.decode(object) }
        }
        var missing = f.approval; missing.removeValue(forKey: "resource_policy_sha256")
        var attachment = f.attachment; attachment["approval"] = missing
        var object = f.configuration; object["nativeMember"] = attachment
        #expect(throws: (any Error).self) { try f.decode(object) }
        for value in [NSNull(), true, "native"] as [Any] {
            var object = f.configuration; object["nativeMember"] = value
            #expect(throws: (any Error).self) { try f.decode(object) }
        }
    }

    @Test func approvalMustMatchTheSavedModelRuntimePlanProfileAndSchedule() throws {
        let f = try Fixture()
        let other = Fixture.hash("0")
        // Each digest the saved setup pins itself, the model and the schedule.
        for change in [["plan_sha256": other], ["artifact_sha256": other], ["native_runtime_sha256": other],
                       ["capability_sha256": other], ["profile_sha256": other],
                       ["model": "different-model"], ["schedule": 2]] as [[String: Any]] {
            var approval = f.approval; change.forEach { approval[$0] = $1 }
            var attachment = f.attachment; attachment["approval"] = approval
            var object = f.configuration; object["nativeMember"] = attachment
            #expect(throws: (any Error).self, "approval \(change.keys) must be refused") { try f.decode(object) }
        }
        // Digests only the approval knows are accepted here and checked
        // against the installed files when the member starts.
        for key in ["metallib_sha256", "resource_library_sha256", "resource_policy_sha256"] {
            var approval = f.approval; approval[key] = other.replacingOccurrences(of: "0", with: "7")
            var attachment = f.attachment; attachment["approval"] = approval
            var object = f.configuration; object["nativeMember"] = attachment
            _ = try f.decode(object)
        }
    }

    @Test func setupSavedForCoordinatorPairingCannotRunTheLocalSession() throws {
        let f = try Fixture()
        var attached = f.configuration; attached["nativeMember"] = f.attachment
        #expect(throws: (any Error).self) { try f.decode(attached).requireOrdinarySessionRoute() }
    }

    private struct Fixture {
        let capability: ClusterRuntimeCapability
        let capabilityHash: String
        let configuration: [String: Any]
        let approval: [String: Any]
        let attachment: [String: Any]
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
                arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: h("5"), maxLifetimeSeconds: 300, maxRequests: 16)
            capabilityHash = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(capability))
            func peer(_ rank: Int) -> [String: Any] {
                ["id": "peer-\(rank)", "rank": rank, "host": "peer-\(rank).local", "port": 22, "user": "fixture",
                 "ownerExecutable": "/fixture/owner", "workerExecutable": "/fixture/native", "modelDirectory": "/fixture/model",
                 "runtimeBinarySHA256": h("a"), "jacclDevice": "rdma_en\(rank)"]
            }
            configuration = ["schema": ClusterConfiguration.schemaName, "clusterID": "fixture", "memberID": "peer-0", "role": "leader",
                "publicModelID": "fixture/qwen", "capabilitySHA256": capabilityHash, "selectedPlanSHA256": h("f"),
                "chunkTokens": 16, "requestTimeoutSeconds": 300, "peers": [peer(0), peer(1)],
                "coordinator": ["address": "192.168.2.1", "port": 12345],
                "trust": ["identityFile": "/fixture/key", "knownHostsFile": "/fixture/known_hosts", "knownHostsSHA256": h("8")],
                "tokenizerFiles": [["path": "tokenizer.json", "sha256": h("6"), "purpose": "tokenizer"]]]
            approval = ["id": "fixture-approval", "model": "fixture/qwen", "generation": 1,
                "plan_sha256": h("f"), "artifact_sha256": h("b"), "native_runtime_sha256": h("a"),
                "metallib_sha256": h("3"), "resource_library_sha256": h("4"), "capability_sha256": capabilityHash,
                "resource_policy_sha256": h("9"), "profile_sha256": h("e"),
                "schedule": 1, "maximum_transport_frame": 131_112, "maximum_plaintext": 131_072,
                "maximum_records": 1024, "maximum_cumulative_plaintext": 16_777_216,
                "allowed_chips": ["Apple M4"], "not_after": "2033-05-18T03:33:20Z"]
            attachment = ["schema": ClusterNativeMemberAttachment.schemaName, "ownerSHA256": h("1"),
                "metallibPath": "/fixture/mlx.metallib", "resourceLibraryPath": "/fixture/resource.metallib",
                "approval": approval]
        }
        @discardableResult
        func decode(_ object: [String: Any]) throws -> ClusterConfiguration {
            try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                capability: capability, capabilitySHA256: capabilityHash)
        }
    }
}
