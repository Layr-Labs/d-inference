import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// A cluster approval that pins no build (a model approval): its two entry shapes, its canonical bytes under
/// `darkbloom/coordinator-cluster-model-approval/v1`, and the member's strict reader of those bytes. The golden
/// vectors are the ones the coordinator's encoder pins for the same inputs.
@Suite("Cluster model approval")
struct ClusterModelApprovalTests {
    static let artifact = SHA256.hash(data: Data("artifact".utf8)).map { String(format: "%02x", $0) }.joined()

    /// The golden inputs: 14 fields, no runtime digest.
    static func entry(classes: [String] = [], changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["id": "devnet/fixture-model/s1", "model": "fixture-model", "generation": 1,
            "artifact_sha256": artifact, "schedule": 1, "maximum_transport_frame": 1_048_616, "maximum_plaintext": 1_048_576,
            "maximum_records": 1_048_576, "maximum_cumulative_plaintext": 4_294_967_296, "allowed_numerics_classes": classes,
            "minimum_members": 2, "maximum_members": 2, "minimum_member_usable_bytes": 1, "not_after": "2026-11-13T10:44:04Z"]
        changes.forEach { value[$0] = $1 }
        return value
    }

    /// The same entry pinned to one build: the seven runtime digests added.
    static func pinned() -> [String: Any] {
        var value = entry()
        for (index, key) in ClusterRuntimeApproval.runtimeKeys.enumerated() {
            value[key.rawValue] = String(repeating: String(format: "%02x", index + 1), count: 32)
        }
        return value
    }

    static func approval(_ object: [String: Any]) throws -> ClusterRuntimeApproval {
        try JSONDecoder().decode(ClusterRuntimeApproval.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func canonicalBytesAreTheGoldenVectors() throws {
        let first = try Self.approval(Self.entry()).canonicalPolicy()
        #expect(first.count == 205)
        #expect(ClusterConfigurationCodec.sha256(first) == "58aee08d621431662b7fd667538e59ea8be1af98087e783a3add313cee17799b")
        #expect(memberHex(first) == "6461726b626c6f6f6d2f636f6f7264696e61746f722d636c75737465722d6d6f64656c2d617070726f76616c2f763100000000176465766e65742f666978747572652d6d6f64656c2f73310000000d666978747572652d6d6f64656c0000000000000001c7c5c1d70c5dec4416ab6158afd0b223ef40c29b1dc1f97ed9428b94d4cadb1c01010100100028001000000000000000100000000000010000000018e794dacd6288000202000000000000000100000009502f90000000001bf08eb00000000014f46b040000000000")
        let second = try Self.approval(Self.entry(classes: ["apple-m5-nax0", "apple-m5-nax1"])).canonicalPolicy()
        #expect(second.count == 239)
        #expect(ClusterConfigurationCodec.sha256(second) == "368372b60ed1615eb14b7f32951c486104dcedf6c7b88c0e1b0805d97e914bf8")
        // The same terms pinned to a build keep the build-pinned domain and layout.
        let build = try Self.approval(Self.pinned()).canonicalPolicy()
        #expect(build.starts(with: NativePairMemberPolicy.clusterDomain) && build.count == first.count + 7 * 32 + 2)
    }

    @Test func theMemberReaderReadsTheModelDomain() throws {
        let policy = try NativePairMemberPolicy(try Self.approval(Self.entry(classes: ["apple-m5-nax0"])).canonicalPolicy())
        #expect(policy.model == "fixture-model" && policy.generation == 1 && policy.schedule == 1)
        #expect(memberHex(policy.artifact) == Self.artifact)
        #expect(policy.pinnedPlan == nil && policy.runtime == nil && policy.chips.isEmpty)
        let terms = try #require(policy.cluster)
        #expect(terms.minimumMembers == 2 && terms.maximumMembers == 2 && terms.minimumMemberUsableBytes == 1)
        #expect(terms.leaseTermsNanoseconds == ClusterRuntimeApproval.leaseTermsNanoseconds)
        #expect(terms.numericsClasses == ["apple-m5-nax0"])
        #expect(policy.maximumFrame == 1_048_616 && policy.maximumPlaintext == 1_048_576)
        #expect(policy.maximumRecords == 1_048_576 && policy.maximumCumulative == 4_294_967_296)
        #expect(policy.notAfter == ClusterPairApproval.unixNanoseconds(rfc3339: "2026-11-13T10:44:04Z"))
        // A build-pinned entry still reads all of its digests by name.
        let build = try NativePairMemberPolicy(try Self.approval(Self.pinned()).canonicalPolicy())
        #expect(build.pinnedPlan.map(memberHex) == String(repeating: "01", count: 32))
        #expect(build.runtime.map { memberHex($0.profile) } == String(repeating: "07", count: 32))
    }

    @Test func theReaderRefusesTrailingTruncatedSwappedAndZeroBytes() throws {
        let bytes = try Self.approval(Self.entry()).canonicalPolicy()
        let artifactOffset = NativePairMemberPolicy.modelDomain.count + 4 + 23 + 4 + 13 + 8
        #expect(bytes.subdata(in: artifactOffset..<(artifactOffset + 32)) == memberDigest("artifact"))
        var zeroArtifact = bytes; zeroArtifact.replaceSubrange(artifactOffset..<(artifactOffset + 32), with: Data(count: 32))
        var modelUnderCluster = bytes
        modelUnderCluster.replaceSubrange(0..<NativePairMemberPolicy.modelDomain.count, with: NativePairMemberPolicy.clusterDomain)
        let build = try Self.approval(Self.pinned()).canonicalPolicy()
        var clusterUnderModel = build
        clusterUnderModel.replaceSubrange(0..<NativePairMemberPolicy.clusterDomain.count, with: NativePairMemberPolicy.modelDomain)
        let refused: [(String, Data)] = [("a trailing byte", bytes + Data([0])), ("a missing last byte", bytes.dropLast()),
            ("a zero artifact", zeroArtifact), ("model bytes under the cluster domain", modelUnderCluster),
            ("cluster bytes under the model domain", clusterUnderModel), ("over 8192 bytes", bytes + Data(count: 8192))]
        for (name, value) in refused {
            #expect(throws: NativePairMemberError.binding, "\(name) must be refused") { _ = try NativePairMemberPolicy(Data(value)) }
        }
    }

    @Test func entriesOutsideTheCoordinatorsBoundsNeverEncode() throws {
        let refused: [(String, Any)] = [("generation", 0), ("schedule", 0), ("schedule", 3), ("id", ""),
            ("artifact_sha256", String(repeating: "0", count: 64)), ("artifact_sha256", String(repeating: "A", count: 64)),
            ("minimum_members", 1), ("maximum_members", 5), ("minimum_members", 3), ("minimum_member_usable_bytes", 0),
            ("maximum_plaintext", 0), ("maximum_transport_frame", 1_048_615), ("maximum_records", 0),
            ("maximum_cumulative_plaintext", 4_294_967_297), ("allowed_numerics_classes", ["b", "a"]),
            ("allowed_numerics_classes", ["a", "a"]), ("allowed_numerics_classes", ["é"]),
            ("allowed_numerics_classes", (0..<17).map { "class-\(String(format: "%02d", $0))" }), ("not_after", "tomorrow")]
        for (key, value) in refused {
            #expect(throws: ClusterConfigurationError.self, "\(key) = \(value) must be refused") {
                _ = try Self.approval(Self.entry(changes: [key: value])).canonicalPolicy()
            }
        }
    }

    @Test func eitherShapeRoundTripsByteForByte() throws {
        // The saved setup's encoder (`ClusterConfigurationCodec.encode`).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for object in [Self.entry(classes: ["apple-m5-nax0"]), Self.pinned()] {
            let approval = try Self.approval(object)
            #expect(approval.isModelApproval == (object.count == 14))
            let saved = try encoder.encode(approval)
            let fields = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
            #expect(Set(fields.keys) == Set(object.keys))
            #expect(try encoder.encode(JSONDecoder().decode(ClusterRuntimeApproval.self, from: saved)) == saved)
            #expect(try JSONDecoder().decode(ClusterRuntimeApproval.self, from: saved) == approval)
            #expect(ClusterRuntimeApproval.isEntry(object.keys))
        }
        #expect(ClusterRuntimeApproval.modelFields.count == 14 && ClusterRuntimeApproval.fields.count == 21)
    }

    @Test func someButNotAllRuntimeDigestsAndUnknownFieldsAreRefused() throws {
        let build = Self.pinned()
        for key in ClusterRuntimeApproval.runtimeKeys.map(\.rawValue) {
            var added = Self.entry(); added[key] = build[key]
            var removed = build; removed.removeValue(forKey: key)
            for partial in [added, removed] {
                #expect(!ClusterRuntimeApproval.isEntry(partial.keys), "\(key)")
                #expect(throws: DecodingError.self, "\(key)") { _ = try Self.approval(partial) }
                #expect(throws: ClusterConfigurationError.self, "\(key)") {
                    try ClusterNativeMemberAttachment.validateObject(Self.attachment(partial))
                }
            }
        }
        // Null digests are not an absent set.
        var nulls = build
        for key in ClusterRuntimeApproval.runtimeKeys { nulls[key.rawValue] = NSNull() }
        #expect(throws: DecodingError.self) { _ = try Self.approval(nulls) }
        // A value built in code with only some digests set never encodes.
        let model = try Self.approval(Self.entry())
        let partial = ClusterRuntimeApproval(id: model.id, model: model.model, generation: model.generation,
            placementPolicySHA256: nil, artifactSHA256: model.artifactSHA256, nativeRuntimeSHA256: String(repeating: "ab", count: 32),
            metallibSHA256: nil, resourceLibrarySHA256: nil, capabilitySHA256: nil, resourcePolicySHA256: nil, profileSHA256: nil,
            schedule: model.schedule, maximumTransportFrame: model.maximumTransportFrame, maximumPlaintext: model.maximumPlaintext,
            maximumRecords: model.maximumRecords, maximumCumulativePlaintext: model.maximumCumulativePlaintext,
            allowedNumericsClasses: [], minimumMembers: 2, maximumMembers: 2, minimumMemberUsableBytes: 1, notAfter: model.notAfter)
        #expect(partial.runtimeDigests == nil && !partial.isModelApproval)
        #expect(throws: ClusterConfigurationError.self) { _ = try partial.canonicalPolicy() }
        // An unknown field, or a missing one of the model shape, is refused; both shapes are accepted.
        var unknown = Self.entry(); unknown["granted"] = true
        var missing = Self.entry(); missing.removeValue(forKey: "allowed_numerics_classes")
        for refused in [unknown, missing] {
            #expect(!ClusterRuntimeApproval.isEntry(refused.keys))
            #expect(throws: ClusterConfigurationError.self) { try ClusterNativeMemberAttachment.validateObject(Self.attachment(refused)) }
        }
        for accepted in [Self.entry(), build] { try ClusterNativeMemberAttachment.validateObject(Self.attachment(accepted)) }
    }

    /// A roster registration's saved fields around `approval` (only their names are read here).
    static func attachment(_ approval: [String: Any]) -> [String: Any] {
        ["schema": ClusterNativeMemberAttachment.rosterSchemaName, "ownerSHA256": String(repeating: "1", count: 64),
         "metallibPath": "/fixture/mlx.metallib", "resourceLibraryPath": "/fixture/resource.metallib",
         "clusterApproval": approval, "roster": [String: Any](), "memberPins": [String]()]
    }
}
