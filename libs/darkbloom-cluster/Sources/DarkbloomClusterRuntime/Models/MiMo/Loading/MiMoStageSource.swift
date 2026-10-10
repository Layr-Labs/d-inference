import Foundation
import MLX
import MLXLLM

/// This Mac's verified MiMo artifact as a stage loader needs it: pinned
/// descriptors and scalar metadata. It retains the verified files (so a path
/// replaced during the load cannot be read) and no model or tensor.
struct MiMoResidentSource {
    let checkpoint: VerifiedCheckpoint
    let profile: MiMoRegisteredModelProfile
    let plan: MiMoLayerStagePlan
    /// The text tensors by indexed name.
    let descriptors: [String: TensorDescriptor]
    let tensors: [QwenStageSourceTensor]
    let mappings: [MiMoLayerStagePlan.Parameter]
    let sourceTensorManifestSHA256: String
    let sourceParameterLayoutSHA256: String
    let activationDType = DType.bfloat16

    var specification: MiMoRegisteredSpecification { profile.specification }
}

extension TensorDescriptor {
    /// The stored dtype as its shard header spells it.
    var storedDTypeName: String {
        get throws {
            switch dtype {
            case .uint32: return "U32"
            case .uint8: return "U8"
            case .float32: return "F32"
            case .bfloat16: return "BF16"
            default: throw ProbeError("MiMo stage source has an unsupported stored dtype")
            }
        }
    }
}

/// Hashes the whole artifact against the pinned manifest, then admits its
/// configuration, manifest and indexed headers as the registered model and
/// derives the selected Plan's ownership of every text tensor. No tensor
/// payload is read here beyond the hash pass.
func prepareMiMoResidentSource(directory: URL, configuration: Data, manifest: Data,
                               specification: MiMoRegisteredSpecification, plan: MiMoLayerStagePlan,
                               check: () throws -> Void) throws -> MiMoResidentSource {
    try check()
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: configuration,
        expectedAggregateSHA256: specification.artifactSHA256,
        maximumPayloadBytes: specification.maximumManifestPayloadBytes,
        expectedManifestSHA256: specification.manifestSHA256,
        hashingConcurrency: MiMoRegisteredSpecification.hashingConcurrency)
    try checkpoint.requireConfiguration(configuration)
    try check()
    // The audio tokenizer's own `.safetensors` is in the manifest and was
    // hashed above; it is not part of the indexed checkpoint.
    let indexed = try tensorDescriptors(checkpoint: checkpoint,
        scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
    let canonical = try indexed.map { name, tensor in
        MiMoCanonicalTensor(name: name, shape: tensor.shape, sourceDType: try tensor.storedDTypeName,
                            byteCount: tensor.byteCount)
    }
    let profile = try MiMoRegisteredModelProfile.admit(configuration: configuration, manifest: manifest,
        expectedArtifactAggregateSHA256: checkpoint.aggregate, indexedTensors: canonical)
    guard profile.specification.model == specification.model, plan.originalConfiguration == configuration,
          checkpoint.verifiedManifestSHA256 == specification.manifestSHA256 else {
        throw ProbeError("MiMo resident source differs from the exact registered model and selected Plan")
    }
    let mappings = try plan.parameters(sourceNames: canonical.map(\.name))
    var descriptors: [String: TensorDescriptor] = [:]
    var tensors: [QwenStageSourceTensor] = []
    for entry in profile.tensors {
        guard let tensor = indexed[entry.name] else { throw ProbeError("MiMo stage descriptor disappeared") }
        descriptors[entry.name] = tensor
        // Nothing is converted on load: the artifact is native bfloat16.
        tensors.append(QwenStageSourceTensor(sourceName: entry.name, canonicalPartName: entry.name,
            file: tensor.file.path, offset: tensor.offset, shape: tensor.shape,
            sourceDType: String(describing: tensor.dtype), loadedDType: String(describing: tensor.dtype),
            byteCount: tensor.byteCount))
    }
    guard mappings.count == tensors.count, Set(mappings.map(\.sourceName)) == Set(tensors.map(\.sourceName)) else {
        throw ProbeError("Every MiMo text tensor must have exactly one layer-stage owner")
    }
    try checkpoint.checkUnchanged()
    try check()
    return MiMoResidentSource(checkpoint: checkpoint, profile: profile, plan: plan, descriptors: descriptors,
        tensors: tensors, mappings: mappings, sourceTensorManifestSHA256: sha256(try canonicalJSONData(tensors)),
        sourceParameterLayoutSHA256: qwenStageLayout(tensors.map { "\($0.sourceName):\($0.loadedDType):\($0.shape)" }))
}
