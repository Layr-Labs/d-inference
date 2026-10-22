import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A stored tensor known only from a pinned content record: its geometry and
/// where a verified artifact keeps it. There is no file behind it to read.
struct QwenPinnedTensorDescriptor: QwenStoredTensorDescribing {
    let shape: [Int]
    let dtype: DType
    let byteCount: Int
    let storedFile: String
    let storedOffset: Int

    init(_ record: LayerStageTensorContentRecord) throws {
        let layout = record.source.layout
        guard let stored = QwenStageStoredDType(rawValue: layout.sourceDType) else {
            throw ProbeError("Unsupported pinned tensor dtype \(layout.sourceDType)")
        }
        dtype = stored.native
        shape = layout.shape; byteCount = layout.byteCount
        storedFile = record.source.sourceFile; storedOffset = record.source.sourceOffset
    }
}

/// The resident source metadata a local load derives, from the registered
/// model's pinned content inventory and the admitted configuration and
/// manifest bytes alone. No weight file is opened, so the aggregate it carries
/// is the registered one, not one this rank hashed. The payload comes from
/// elsewhere and is checked tensor by tensor against the same inventory.
func prepareQwenResidentPinnedSource(_ admission: QwenResidentAdmission,
                                    check: () throws -> Void) throws -> QwenResidentSource {
    guard !_qwen35MTPEnabled else { throw ProbeError("Resident generation requires MTP disabled") }
    let inventory = try QwenRegisteredContentInventory.require(admission.specification)
    let pinned = try Dictionary(uniqueKeysWithValues: inventory.records.map {
        ($0.source.layout.canonicalName, try QwenPinnedTensorDescriptor($0))
    })
    // Admission has already held both byte strings to the specification's pins.
    return try prepareQwenResidentMetadata(admission,
        artifact: .init(aggregateSHA256: admission.specification.artifactSHA256,
            configurationSHA256: sha256(admission.configBytes), verifiedManifestSHA256: sha256(admission.manifestBytes)),
        check: check, confirmUnchanged: {}) { model, policy in
            try PreparedQwenCheckpoint(model: model, descriptors: pinned, policy: policy)
        }.source
}
