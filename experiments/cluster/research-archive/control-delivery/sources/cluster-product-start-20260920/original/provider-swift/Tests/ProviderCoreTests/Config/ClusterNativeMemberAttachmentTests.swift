import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

@Suite("Saved native cluster attachment")
struct ClusterNativeMemberAttachmentTests {
    @Test func savedNumericalEvidenceDirectoryIsExplicitLocalAndOptional() throws {
        let f = try Fixture()
        var object = f.configuration; object["nativeMember"] = f.attachment
        let omitted = try f.decode(object)
        #expect(omitted.nativeMember?.numericalEvidenceDirectory == nil)
        let old = try ClusterConfigurationCodec.encode(omitted, capability: f.capability, capabilitySHA256: f.capabilityHash)
        #expect(!String(decoding: old, as: UTF8.self).contains("numericalEvidenceDirectory"))
        var attachment = f.attachment; attachment["numericalEvidenceDirectory"] = "/fixture/private-evidence"
        object["nativeMember"] = attachment
        let enabled = try f.decode(object)
        #expect(enabled.nativeMember?.numericalEvidenceDirectory == "/fixture/private-evidence")
        let encoded = try ClusterConfigurationCodec.encode(enabled, capability: f.capability, capabilitySHA256: f.capabilityHash)
        #expect(try f.decode(JSONSerialization.jsonObject(with: encoded) as! [String: Any]) == enabled)
        for bad in [NSNull(), false, "relative", "/tmp/../escape", "/fixture/native", "/fixture/owner",
                    "/fixture/mlx.metallib", "/fixture/resource.metallib", "/tmp/line\nfeed"] as [Any] {
            attachment["numericalEvidenceDirectory"] = bad; object["nativeMember"] = attachment
            #expect(throws: (any Error).self) { try f.decode(object) }
        }
    }
    @Test func omissionRetainsExactLegacyConfigurationBytes() throws {
        let f = try Fixture()
        let original = try f.decode(f.configuration)
        #expect(original.nativeMember == nil)
        let bytes = try ClusterConfigurationCodec.encode(original, capability: f.capability, capabilitySHA256: f.capabilityHash)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("nativeMember"))
        #expect(try f.decode(JSONSerialization.jsonObject(with: bytes) as! [String: Any]) == original)
    }

    @Test func savedNativeChoiceRoundTripsWithBothLocalRanks() throws {
        let f = try Fixture()
        for rank in 0..<2 {
            var object = f.configuration; object["nativeMember"] = f.attachment
            object["role"] = rank == 0 ? "leader" : "follower"; object["memberID"] = "peer-\(rank)"
            let decoded = try f.decode(object)
            #expect(try decoded.nativeMember?.policyBytes == f.policy)
            #expect(decoded.localRank == rank)
            let encoded = try ClusterConfigurationCodec.encode(decoded, capability: f.capability, capabilitySHA256: f.capabilityHash)
            #expect(try f.decode(JSONSerialization.jsonObject(with: encoded) as! [String: Any]) == decoded)
        }
    }

    @Test func attachmentRefusesUnknownNullSecretsAndMalformedPins() throws {
        let f = try Fixture()
        let changes: [[String: Any]] = [
            ["schema": "other"], ["bootstrapProfile": "jaccl_mesh2_i32le_destination32_v1"],
            ["workerProfile": "unrestricted"], ["ownerSHA256": "not-a-hash"], ["coordinatorPolicySHA256": Fixture.hash("0")],
            ["coordinatorPolicyBase64": f.policy.base64EncodedString() + "\n"],
            ["privateKey": "never accepted"], ["environment": ["APPROVE": "true"]],
            ["metallib": ["path": "/tmp/../other", "sha256": Fixture.hash("3")]],
            ["resourceLibrary": ["path": "/fixture/native", "sha256": Fixture.hash("4")]],
            ["protectedRuntimeDescriptionSHA256": NSNull()]]
        for change in changes {
            var attachment = f.attachment; change.forEach { attachment[$0] = $1 }
            var object = f.configuration; object["nativeMember"] = attachment
            #expect(throws: (any Error).self) { try f.decode(object) }
        }
        for value in [NSNull(), true, "native"] as [Any] {
            var object = f.configuration; object["nativeMember"] = value
            #expect(throws: (any Error).self) { try f.decode(object) }
        }
    }

    @Test func policyModelAndEveryRuntimeCommitmentAreBoundToSavedSetup() throws {
        let f = try Fixture()
        for index in 0..<8 {
            var bytes = f.policy; bytes[f.hashOffset + index * 32] ^= 1
            var attachment = f.attachment; attachment["coordinatorPolicyBase64"] = bytes.base64EncodedString()
            attachment["coordinatorPolicySHA256"] = ClusterConfigurationCodec.sha256(bytes)
            var object = f.configuration; object["nativeMember"] = attachment
            #expect(throws: (any Error).self) { try f.decode(object) }
        }
        var object = f.configuration; object["nativeMember"] = f.attachment; object["publicModelID"] = "different-model"
        #expect(throws: (any Error).self) { try f.decode(object) }
        object = f.configuration; object["nativeMember"] = f.attachment; object["chunkTokens"] = 32
        #expect(throws: (any Error).self) { try f.decode(object) }
    }

    @Test func protectedSetupCannotSelectOrdinarySessionRoute() throws {
        let f = try Fixture()
        try f.decode(f.configuration).requireOrdinarySessionRoute()
        var attached = f.configuration; attached["nativeMember"] = f.attachment
        #expect(throws: (any Error).self) { try f.decode(attached).requireOrdinarySessionRoute() }
    }

    @Test func protectedDescriptionRequiresExactProducerContractAndSavedDigest() throws {
        let f = try Fixture()
        let object = try f.description()
        func check(_ value: [String: Any], pinOriginal: Bool = false) throws {
            var raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]); raw.append(10)
            var expected = f.attachment
            var original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); original.append(10)
            expected["protectedRuntimeDescriptionSHA256"] = ClusterConfigurationCodec.sha256(pinOriginal ? original : raw)
            let attachment = try JSONDecoder().decode(ClusterNativeMemberAttachment.self, from: JSONSerialization.data(withJSONObject: expected))
            try DistributedInstalledNativeAttachment.validateDescription(raw, attachment: attachment,
                capability: f.capability, capabilitySHA256: f.capabilityHash, planSHA256: Fixture.hash("f"))
        }
        try check(object)
        let changes: [[String: Any]] = [["servingEnabled": true], ["servingEnabled": 0],
            ["experimentalExecutionOnly": 1], ["wholeProcessPeakProven": true], ["rdmaMeasured": true],
            ["stopTokenIDs": [1]], ["stageCut": 4], ["prefillSchedule": "lookahead"],
            ["maximumPlaintextBytes": 131073], ["maximumRecordsPerDirection": 1025],
            ["runtimeBinarySHA256": Fixture.hash("0")], ["selectedPlanSHA256": Fixture.hash("0")],
            ["profileFingerprint": Fixture.hash("0")], ["resourcePolicyBase64": Data("wrong".utf8).base64EncodedString()],
            ["ordinaryCapabilityBase64": ""], ["sourceBindings": [:]], ["unknown": true]]
        for change in changes {
            var changed = object; change.forEach { changed[$0] = $1 }
            #expect(throws: (any Error).self) { try check(changed) }
            #expect(throws: (any Error).self) { try check(changed, pinOriginal: true) }
        }
    }

    private struct Fixture {
        let capability: ClusterRuntimeCapability
        let capabilityHash: String
        let configuration: [String: Any]
        let attachment: [String: Any]
        let policy: Data
        let hashOffset: Int
        let resource = Data("fixture-only resource commitment; no allocation claim".utf8)
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
            var p = Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8)
            func integer<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
                for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { p.append(UInt8(truncatingIfNeeded: value >> shift)) }
            }
            func text(_ value: String) { let raw = Data(value.utf8); integer(UInt32(raw.count)); p.append(raw) }
            func digest(_ value: String) {
                let a = Array(value); p.append(contentsOf: stride(from: 0, to: 64, by: 2).map { UInt8(String(a[$0...$0+1]), radix: 16)! })
            }
            text("fixture-policy"); text("fixture/qwen"); integer(UInt64(1)); hashOffset = p.count
            [h("f"), h("b"), h("a"), h("3"), h("4"), capabilityHash, ClusterConfigurationCodec.sha256(resource), h("e")].forEach(digest)
            p.append(contentsOf: [1,1,1]); integer(UInt32(131112)); integer(UInt32(131072)); integer(UInt64(1024)); integer(UInt64(16777216))
            integer(UInt64(2_000_000_000_000_000_000)); integer(UInt32(1)); text("Apple M4")
            policy = p
            attachment = ["schema": ClusterNativeMemberAttachment.schemaName, "bootstrapProfile": "native_key_prelude_mesh2_v1",
                "workerProfile": ClusterNativeMemberAttachment.protectedProfile, "ownerSHA256": h("1"),
                "metallib": ["path": "/fixture/mlx.metallib", "sha256": h("3")],
                "resourceLibrary": ["path": "/fixture/resource.metallib", "sha256": h("4")],
                "resourcePolicySHA256": ClusterConfigurationCodec.sha256(resource), "coordinatorPolicyBase64": p.base64EncodedString(),
                "coordinatorPolicySHA256": ClusterConfigurationCodec.sha256(p), "protectedRuntimeDescriptionSHA256": h("9")]
        }
        func description() throws -> [String: Any] {
            ["schema": "qwen9b_protected_runtime_description_v1", "staticProfile": ClusterNativeMemberAttachment.protectedProfile,
             "runtimeBinarySHA256": capability.runtimeBinarySHA256,
             "ordinaryCapabilityBase64": try ClusterRuntimeCapabilityCodec.encode(capability).base64EncodedString(),
             "capabilitySHA256": capabilityHash, "selectedPlanSHA256": Self.hash("f"),
             "profileFingerprint": capability.profileFingerprint,
             "resourcePolicySHA256": ClusterConfigurationCodec.sha256(resource), "resourcePolicyBase64": resource.base64EncodedString(),
             "stageCut": 16, "prefillSchedule": "serial_v1", "promptTokens": 32, "chunkTokens": 16, "outputTokens": 2,
             "stopTokenIDs": [Int](), "maximumPlaintextBytes": 131072, "maximumFrameBytes": 131112,
             "maximumRecordsPerDirection": 1024, "maximumCumulativePlaintextBytesPerDirection": 16777216,
             "bootstrapProfile": "native_key_prelude_mesh2_v1", "sourceBindings": ["fixtureOnly": Self.hash("1")],
             "allocationReviews": [Self.hash("2"), Self.hash("3")], "experimentalExecutionOnly": true,
             "wholeProcessPeakProven": false, "rdmaMeasured": false, "servingEnabled": false]
        }
        func decode(_ object: [String: Any]) throws -> ClusterConfiguration {
            try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                capability: capability, capabilitySHA256: capabilityHash)
        }
    }
}
