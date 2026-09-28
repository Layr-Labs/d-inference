import Foundation

enum LayerStageResponsibility: String, Codable {
    case ingressResidual, finalLogits
}

struct Gemma4StageConstructionDescriptor: Encodable, Equatable {
    struct Layer: Encodable, Equatable {
        let globalIndex: Int
        let localIndex: Int
        let kind: Gemma4StageAttentionKind
    }
    struct QuantizationMapping: Encodable, Equatable {
        let sourcePath: String
        let localPath: String
        let policy: Gemma4AffineQuantization
    }
    let originalConfiguration: Data
    let sourceConfigurationSHA256: String
    let rank: Int
    let sourceLayerStart: Int
    let sourceLayerEnd: Int
    let globalLayerCount: Int
    let layers: [Layer]
    let responsibility: LayerStageResponsibility
    /// Quantizer-only table. Never use it to rewrite the full decoder's geometry.
    let localQuantization: Data
    let quantizationMappings: [QuantizationMapping]
    let fingerprint: String
    let nativeExecutionAuthorized = false

    var sourceLayerRange: Range<Int> { sourceLayerStart..<sourceLayerEnd }
    var finalPromptLayerGlobalIndex: Int? { responsibility == .finalLogits ? globalLayerCount - 1 : nil }

    init(artifact: Gemma4ArtifactMetadata, rank: Int, sourceLayerRange: Range<Int>) throws {
        let count = artifact.text.globalLayerCount
        guard (0...1).contains(rank), !sourceLayerRange.isEmpty,
              sourceLayerRange.lowerBound >= 0, sourceLayerRange.upperBound <= count,
              (rank == 0 ? sourceLayerRange.lowerBound == 0 && sourceLayerRange.upperBound < count
                         : sourceLayerRange.lowerBound > 0 && sourceLayerRange.upperBound == count) else {
            throw ProbeError("Gemma stage role/range is invalid")
        }
        let layers = sourceLayerRange.map {
            Layer(globalIndex: $0, localIndex: $0 - sourceLayerRange.lowerBound, kind: artifact.text.layerKinds[$0])
        }
        var table = artifact.text.quantizationDefaults.jsonObject
        var mappings: [QuantizationMapping] = []
        for path in artifact.text.quantizationOverrides.keys.sorted() {
            guard let location = Self.layerPath(path) else { throw ProbeError("Gemma quantization path is not canonical") }
            if sourceLayerRange.contains(location.index) {
                let local = Gemma4TensorInventory.prefix + "layers.\(location.index - sourceLayerRange.lowerBound)." + location.suffix
                guard table[local] == nil, let policy = artifact.text.quantizationOverrides[path] else {
                    throw ProbeError("Gemma local quantization path collides")
                }
                // Preserve the source spelling: mode inherits affine from the default.
                table[local] = ["bits": policy.bits, "group_size": policy.groupSize]
                mappings.append(.init(sourcePath: path, localPath: local, policy: policy))
            }
        }
        let local = try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])
        let responsibility: LayerStageResponsibility = rank == 0 ? .ingressResidual : .finalLogits
        let identity = ["gemma4-stage-construction-descriptor-v1", artifact.fingerprint,
            Gemma4ArtifactMetadata.configurationSHA256, "rank=\(rank)",
            "globalLayers=\(count)", "range=\(sourceLayerRange.lowerBound):\(sourceLayerRange.upperBound)",
            responsibility.rawValue, sha256(try canonicalJSONData(layers)), sha256(local),
            sha256(try canonicalJSONData(mappings)), "executionAuthorized=false"]
        originalConfiguration = artifact.originalConfiguration
        sourceConfigurationSHA256 = Gemma4ArtifactMetadata.configurationSHA256
        self.rank = rank; sourceLayerStart = sourceLayerRange.lowerBound; sourceLayerEnd = sourceLayerRange.upperBound
        globalLayerCount = count; self.layers = layers; self.responsibility = responsibility
        localQuantization = local; quantizationMappings = mappings
        fingerprint = sha256(Data(identity.joined(separator: "\n").utf8))
    }

    static func layerPath(_ name: String) -> (index: Int, suffix: String)? {
        let prefix = Gemma4TensorInventory.prefix + "layers."
        guard name.hasPrefix(prefix) else { return nil }
        let fields = name.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count > 1, let first = fields.first, let index = Int(first),
              String(index) == String(first), (0..<30).contains(index), fields.allSatisfy({ !$0.isEmpty }) else { return nil }
        return (index, fields.dropFirst().joined(separator: "."))
    }
}
