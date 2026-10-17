import Foundation

/// A stored tensor dtype: the safetensors spelling a canonical inventory uses
/// and the native spelling the loader's records and receipts use.
enum QwenStageStoredDType: String, CaseIterable {
    case uint32 = "U32", float32 = "F32", float16 = "F16", bfloat16 = "BF16"

    var nativeName: String {
        switch self {
        case .uint32: "uint32"
        case .float32: "float32"
        case .float16: "float16"
        case .bfloat16: "bfloat16"
        }
    }

    var elementBytes: Int { self == .uint32 || self == .float32 ? 4 : 2 }

    init?(nativeName: String) {
        guard let match = Self.allCases.first(where: { $0.nativeName == nativeName }) else { return nil }
        self = match
    }
}

/// The loader's source-tensor manifest, rebuilt from a content inventory with
/// no file open. A local load derives these same records from its verified
/// descriptors (`finishPreparedQwenLayerSource`) and hashes them into the
/// storage commitment, so a rank that holds only a pinned inventory commits to
/// the same storage. Registered dense artifacts store one part per tensor.
enum QwenStageSourceTensorManifest {
    static func tensors(_ inventory: LayerStageTensorContentInventory,
                        bf16ConversionEnabled: Bool) throws -> [QwenStageSourceTensor] {
        try inventory.records.map(\.source).sorted { $0.layout.canonicalName < $1.layout.canonicalName }.map { source in
            let layout = source.layout
            guard let stored = QwenStageStoredDType(rawValue: layout.sourceDType) else {
                throw ProbeError("Stage content inventory has an unsupported source dtype")
            }
            let loaded = bf16ConversionEnabled && stored == .float16 ? QwenStageStoredDType.bfloat16 : stored
            return QwenStageSourceTensor(sourceName: layout.canonicalName, canonicalPartName: layout.canonicalName,
                file: source.sourceFile, offset: source.sourceOffset, shape: layout.shape,
                sourceDType: stored.nativeName, loadedDType: loaded.nativeName, byteCount: layout.byteCount)
        }
    }

    /// `PreparedQwenLayerSource.sourceTensorManifestSHA256` for those records.
    static func fingerprint(_ inventory: LayerStageTensorContentInventory,
                            bf16ConversionEnabled: Bool) throws -> String {
        sha256(try canonicalJSONData(tensors(inventory, bf16ConversionEnabled: bf16ConversionEnabled)))
    }
}
