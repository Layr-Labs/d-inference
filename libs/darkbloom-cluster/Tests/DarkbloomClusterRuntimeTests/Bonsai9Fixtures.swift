import DarkbloomClusterProtocol
import Foundation
@testable import DarkbloomClusterRuntime

/// Byte-exact public metadata; the header describes the artifact, never its payload.
enum Bonsai9Fixture {
    static let model = QwenRegisteredDenseModel.ternaryBonsai2NineB
    static let cuts = Array(stride(from: 4, through: 28, by: 4))
    static func data(_ name: String) throws -> Data { try BonsaiFixture.data("ternary-bonsai-2-9b", name) }
    static func specification() throws -> QwenDenseRegisteredSpecification { try BonsaiFixture.specification(model) }

    struct HeaderTensor: Decodable {
        let shape: [Int], dtype: String, data_offsets: [Int]
        var bytes: Int { data_offsets[1] - data_offsets[0] }
    }
    static func header() throws -> [String: HeaderTensor] {
        // __metadata__ is not a tensor. Decode only tensor records.
        let root = try JSONSerialization.jsonObject(with: data("header")) as! [String: Any]
        return try JSONDecoder().decode([String: HeaderTensor].self,
            from: JSONSerialization.data(withJSONObject: root.filter { $0.key != "__metadata__" }))
    }
    static func inventory() throws -> [QwenDenseCanonicalTensor] {
        try header().filter { $0.key.hasPrefix("language_model.") && !$0.key.hasSuffix(".signs") }
            .map { .init(name: $0.key, shape: $0.value.shape, sourceDType: $0.value.dtype, byteCount: $0.value.bytes) }
            .sorted { $0.name < $1.name }
    }
    static func identity(epoch: UUID = UUID(), modelID: String = model.rawValue) throws -> ClusterWorkerIdentity {
        let spec = try specification()
        return .init(membershipEpoch: epoch, modelID: modelID, artifactSHA256: spec.artifactSHA256,
            configurationSHA256: spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }
    static func admit(rank: Int = 0, cut: Int = 16, identity: ClusterWorkerIdentity? = nil,
                      configuration: Data? = nil, manifest: Data? = nil) throws -> QwenResidentAdmission {
        try BonsaiFixture.admit(BonsaiFixture.configuration(rank: rank, cut: cut, identity: try identity ?? Self.identity()),
            config: try configuration ?? data("configuration"), manifest: try manifest ?? data("manifest"))
    }
}
