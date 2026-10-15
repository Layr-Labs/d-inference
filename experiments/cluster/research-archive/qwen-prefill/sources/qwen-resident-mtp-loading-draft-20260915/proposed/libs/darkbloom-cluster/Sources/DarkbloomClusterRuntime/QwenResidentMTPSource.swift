import Foundation
import MLX

/// Retains the same verified descriptor owner as the MTP-off target source.
/// Artifact checksum verification is unchanged. This preparation creates only
/// metadata/descriptors, with no selected tensor allocation or model evaluation.
struct PreparedQwenResidentMTPSource {
    let target: QwenResidentSource
    let placement: QwenResidentMTPPlacement
    let descriptors: [String: TensorDescriptor]
    let resources: QwenResidentMTPLoadResources

    init(admission: QwenResidentAdmission, check: () throws -> Void) throws {
        try QwenResidentMTPPlacement.requireOwner(rank: admission.configuration.rank)
        try QwenResidentResourceEnvironment.require(); try check()
        target = try prepareQwenResidentSource(admission, check: check)
        let checkpoint = target.source.prepared.checkpoint
        let all = try tensorDescriptors(checkpoint: checkpoint)
        var selected = all.filter { $0.key.hasPrefix("mtp.") }
        let replica = target.profile.canonicalTensors.filter {
            $0.name.hasPrefix(QwenResidentMTPPlacement.embeddingRoot + ".")
        }
        for entry in replica {
            guard let tensor = target.source.prepared.canonical[entry.name],
                  tensor.parts.count == 1, tensor.shape == entry.shape,
                  tensor.byteCount == entry.byteCount, selected[entry.name] == nil else {
                throw ProbeError("MTP replica differs from verified target embedding descriptors")
            }
            selected[entry.name] = tensor.parts[0].tensor
        }
        let head = try selected.keys.filter { $0.hasPrefix("mtp.") }.sorted().map { name in
            let value = selected[name]!
            let dtype: String
            switch value.dtype {
            case .uint32: dtype = "U32"
            case .bfloat16: dtype = "BF16"
            default: throw ProbeError("Registered MTP descriptor has an unsupported source dtype")
            }
            return QwenDenseCanonicalTensor(name: name, shape: value.shape,
                sourceDType: dtype, byteCount: value.byteCount)
        }
        placement = try .derive(configuration: admission.configBytes, plan: admission.plan,
            head: head, embedding: replica)
        guard Set(selected.keys) == Set(placement.tensorsInReadOrder.map(\.name)) else {
            throw ProbeError("MTP selected descriptor coverage differs")
        }
        descriptors = selected
        resources = try .init(placement: placement, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
            bound: QwenResidentResourceEnvironment.allocationBound)
        try checkpoint.checkUnchanged(); try check()
    }
}
