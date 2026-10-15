import Foundation

/// Exact small registered metadata, before any assistant construction/read.
struct Gemma4AssistantArtifact {
    private struct Manifest: Decodable {
        struct Entry: Decodable { let path: String, sha256: String; let size_bytes: Int }
        let aggregate_sha256: String
        let file_count: Int, total_size_bytes: Int
        let files: [Entry]
    }
    struct Tensor: Equatable, Encodable {
        let name: String, sourceDType: String
        let shape: [Int]
        let offset: Int, bytes: Int
    }
    static let aggregateSHA256 = "d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34"
    static let configSHA256 = "0cd54ff36e53a258532c5c1433bc44b88ba758cfe9b59bb4e6eecfd5453fabcf"
    static let manifestSHA256 = "8b7c00b7f131345156f5f20fa9c94a895c5340f16d9331bafb9e59628bf45bf2"
    static let weightSHA256 = "3c4d43863abbbf455ec537c726eff7abeb88bb361e3ab23ff0d2d6006f620f74"
    // Retained original 10,256-byte safetensors header, read independently of payload.
    static let headerSHA256 = "10d334e77823aa68ac038bac6a0ae3363a92642335439bd2a4fa46db6db316e4"
    let configuration: Data
    let tensors: [Tensor]
    let quantizedPaths: Set<String>
    let parameterLayoutSHA256: String

    init(configuration: Data, manifest: Data, header: Data) throws {
        guard configuration.count == 2961, header.count == 10256, manifest.count <= 16384,
              sha256(configuration) == Self.configSHA256, sha256(manifest) == Self.manifestSHA256,
              sha256(header) == Self.headerSHA256 else { throw ProbeError("Assistant registered metadata identity differs") }
        let declared = try JSONDecoder().decode(Manifest.self, from: manifest)
        guard declared.aggregate_sha256 == Self.aggregateSHA256, declared.file_count == 2,
              declared.total_size_bytes == 236_127_665, declared.files.count == 2,
              Set(declared.files.map(\.path)) == ["config.json","model.safetensors"],
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == Self.configSHA256,
              declared.files.first(where: { $0.path == "config.json" })?.size_bytes == 2961,
              declared.files.first(where: { $0.path == "model.safetensors" })?.sha256 == Self.weightSHA256,
              declared.files.first(where: { $0.path == "model.safetensors" })?.size_bytes == 236_124_704,
              let object = try JSONSerialization.jsonObject(with:header) as? [String:Any] else {
            throw ProbeError("Assistant manifest/header structure differs")
        }
        var tensors: [Tensor] = []
        for (name, raw) in object where name != "__metadata__" {
            guard let item = raw as? [String:Any], let shape = item["shape"] as? [Int],
                  !shape.isEmpty, shape.allSatisfy({ $0 > 0 && $0 <= 262144 }),
                  let dtype = item["dtype"] as? String, ["U32","BF16"].contains(dtype),
                  let offsets = item["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= 236_114_440 else {
                throw ProbeError("Assistant tensor header differs")
            }
            let bytes = try QwenLongPrefillCheckedBytes.product(shape + [dtype == "U32" ? 4 : 2])
            guard bytes == offsets[1] - offsets[0] else { throw ProbeError("Assistant packed byte geometry differs") }
            tensors.append(.init(name:name,sourceDType:dtype,shape:shape,offset:10264+offsets[0],bytes:bytes))
        }
        tensors.sort { $0.name < $1.name }
        let paths = Set(tensors.filter { $0.name.hasSuffix(".scales") }.map { String($0.name.dropLast(7)) })
        guard tensors.count == 94, paths.count == 23,
              tensors.filter({ $0.sourceDType == "U32" }).count == 23,
              try QwenLongPrefillCheckedBytes.sum(tensors.map(\.bytes)) == 236_114_440,
              !tensors.contains(where: { tensor in tensor.name.hasPrefix("masked_embedding.") || tensor.name.hasPrefix("lm_head.")
                || [".self_attn.k_proj", ".self_attn.v_proj", ".self_attn.k_norm", ".self_attn.v_norm"].contains(where: { tensor.name.contains($0) }) }) else {
            throw ProbeError("Assistant exact inventory or shared-KV contract differs")
        }
        for path in paths {
            guard let weight = tensors.first(where: { $0.name == path+".weight" }), weight.sourceDType == "U32",
                  let scales = tensors.first(where: { $0.name == path+".scales" }), scales.sourceDType == "BF16",
                  let biases = tensors.first(where: { $0.name == path+".biases" }), biases.shape == scales.shape,
                  biases.sourceDType == "BF16", weight.shape.count == 2, scales.shape.count == 2,
                  scales.shape == [weight.shape[0],weight.shape[1]/8] else {
                throw ProbeError("Assistant affine4/group64 triplet differs")
            }
        }
        self.configuration = configuration; self.tensors = tensors; quantizedPaths = paths
        parameterLayoutSHA256 = sha256(Data(tensors.map { "\($0.name):\($0.sourceDType):\($0.shape):\($0.bytes)" }.joined(separator:"\n").utf8))
    }
}
