import Foundation
import MLX

/// This Mac's verified GPT-OSS artifact as a stage loader reads it: pinned
/// file descriptors, one descriptor per stored tensor and the scalar records
/// both ranks commit to. No tensor payload has been read.
struct GPTOSSResidentSource {
    let checkpoint: VerifiedCheckpoint
    let specification: GPTOSSRegisteredSpecification
    let plan: GPTOSSLayerStagePlan
    let descriptors: [String: TensorDescriptor]
    let tensors: [QwenStageSourceTensor]
    let mappings: [GPTOSSLayerStagePlan.Parameter]
    let activationDType: DType
    let sourceTensorManifestSHA256: String
    let sourceParameterLayoutSHA256: String
}

/// Hashes every manifest file against the registered pins, then holds the
/// artifact's own tensor headers to the closed inventory the registered
/// geometry produces: the same names, dtypes, shapes and byte counts, nothing
/// missing and nothing extra. The artifact stores every tensor under the name
/// the product class gives its parameter, so no sanitizer runs and no name is
/// guessed; in particular the gate and up expert projections stay separate.
func prepareGPTOSSResidentSource(directory: URL, configuration: Data, manifest: Data,
                                 specification spec: GPTOSSRegisteredSpecification, plan: GPTOSSLayerStagePlan,
                                 check: () throws -> Void) throws -> GPTOSSResidentSource {
    guard sha256(configuration) == spec.configurationSHA256, sha256(manifest) == spec.manifestSHA256,
          plan.originalConfiguration == configuration, plan.specification.model == spec.model else {
        throw ProbeError("GPT-OSS source differs from the registered model or its admitted Plan")
    }
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: configuration,
        expectedAggregateSHA256: spec.artifactSHA256, maximumPayloadBytes: spec.manifestBytes,
        expectedManifestSHA256: spec.manifestSHA256)
    try checkpoint.requireConfiguration(configuration)
    try check()
    guard checkpoint.files.count == spec.manifestFileCount, checkpoint.aggregate == spec.artifactSHA256,
          checkpoint.verifiedManifestSHA256 == spec.manifestSHA256 else {
        throw ProbeError("Verified GPT-OSS artifact differs from the registered manifest")
    }
    let descriptors = try tensorDescriptors(checkpoint: checkpoint, scope: .init(acceptsUInt8: true))
    try check()
    guard descriptors.count == plan.tensors.count else {
        throw ProbeError("GPT-OSS artifact stores \(descriptors.count) tensors; the registered inventory has \(plan.tensors.count)")
    }
    var tensors: [QwenStageSourceTensor] = []
    for expected in plan.tensors {
        guard let descriptor = descriptors[expected.name], descriptor.shape == expected.shape,
              String(describing: descriptor.dtype) == GPTOSSStageMetadata.nativeName(expected.sourceDType),
              descriptor.byteCount == expected.byteCount else {
            throw ProbeError("GPT-OSS stored tensor differs from the registered inventory: \(expected.name)")
        }
        let native = String(describing: descriptor.dtype)
        tensors.append(QwenStageSourceTensor(sourceName: expected.name, canonicalPartName: expected.name,
            file: descriptor.file.path, offset: descriptor.offset, shape: descriptor.shape,
            sourceDType: native, loadedDType: native, byteCount: descriptor.byteCount))
    }
    // The stream's dtype is the one the embedding dequantizes into.
    guard let scales = descriptors[GPTOSSLayerStagePlan.embedding + ".scales"], scales.dtype == .bfloat16,
          String(describing: scales.dtype) == GPTOSSRegisteredSpecification.activationDType else {
        throw ProbeError("GPT-OSS source is not native BF16")
    }
    let mappings = try plan.parameters()
    try checkpoint.checkUnchanged()
    try check()
    return GPTOSSResidentSource(checkpoint: checkpoint, specification: spec, plan: plan,
        descriptors: descriptors, tensors: tensors, mappings: mappings, activationDType: scales.dtype,
        sourceTensorManifestSHA256: sha256(try canonicalJSONData(tensors)),
        sourceParameterLayoutSHA256: qwenStageLayout(tensors.map { "\($0.sourceName):\($0.loadedDType):\($0.shape)" }))
}
