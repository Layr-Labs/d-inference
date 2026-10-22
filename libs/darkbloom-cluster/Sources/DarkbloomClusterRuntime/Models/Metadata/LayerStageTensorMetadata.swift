import Foundation

/// Metadata only. This value owns neither a verified file nor a native array.
struct LayerStageTensorLayout: Encodable, Equatable {
    let canonicalName: String
    let shape: [Int]
    let sourceDType: String
    let byteCount: Int

    init(canonicalName: String, shape: [Int], sourceDType: String, byteCount: Int) throws {
        // Reuse the existing bounded shape/dtype validator without admitting a Qwen profile.
        try QwenDenseCanonicalTensor(name: canonicalName, shape: shape,
            sourceDType: sourceDType, byteCount: byteCount).validate()
        self.canonicalName = canonicalName; self.shape = shape
        self.sourceDType = sourceDType; self.byteCount = byteCount
    }

    var identity: String {
        [canonicalName, sourceDType, shape.map(String.init).joined(separator: ","), String(byteCount)]
            .joined(separator: "|")
    }
}

struct LayerStageSourceTensor: Encodable, Equatable {
    let layout: LayerStageTensorLayout
    let sourceFile: String
    /// Absolute offset, including the eight-byte safetensors prefix and header.
    let sourceOffset: Int
    let identity: String

    init(layout: LayerStageTensorLayout, sourceFile: String, sourceOffset: Int) throws {
        guard (1...256).contains(sourceFile.utf8.count), sourceFile.hasSuffix(".safetensors"),
              !sourceFile.contains("/"), !sourceFile.contains("\\"),
              sourceFile.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              sourceOffset >= 8 else { throw ProbeError("Invalid stage source location") }
        _ = try QwenLongPrefillCheckedBytes.sum([sourceOffset, layout.byteCount])
        self.layout = layout; self.sourceFile = sourceFile; self.sourceOffset = sourceOffset
        self.identity = sha256(Data(["layer-stage-source-tensor-v1", sourceFile,
            String(sourceOffset), layout.identity].joined(separator: "\n").utf8))
    }
}

enum LayerStageTensorRole: String, Codable {
    case layer, ingressEmbedding, tiedOutputEmbedding, finalNorm, outputProjection
}

struct LayerStageTensorDestination: Codable, Equatable {
    let rank: Int
    let localName: String
    let role: LayerStageTensorRole
    let globalLayerIndex: Int?
}

struct LayerStageTensorMapping: Encodable, Equatable {
    let source: LayerStageSourceTensor
    let destinations: [LayerStageTensorDestination]
    let replicationGroupID: String?
}

/// Model admission supplies these exact members; generic accounting cannot create a group.
struct LayerStageTiedEmbeddingReplication: Encodable, Equatable {
    let id: String
    let canonicalModule: String
    let sourceNames: [String]
    let ingressRank: Int
    let outputRank: Int
}
