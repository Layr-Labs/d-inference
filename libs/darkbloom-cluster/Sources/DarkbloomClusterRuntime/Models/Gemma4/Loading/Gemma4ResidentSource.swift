import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// A registered Gemma artifact's verified descriptors and what the product's
/// own model says about its configuration. Scalar metadata only: the full
/// metadata model and its lazy parameters are released before this is returned.
struct Gemma4ResidentSource {
    let source: PreparedQwenLayerSource
    let specification: Gemma4RegisteredSpecification
    let textConfiguration: Gemma4TextConfiguration
    /// The product model's own resolution of the weighted expert reduction for
    /// this configuration in this process; a stage's layers are built with it.
    let fuseWeightedUnsort: Bool
}

/// A resident source whose payload is this Mac's verified artifact.
struct Gemma4ResidentLocalSource {
    let metadata: Gemma4ResidentSource
    let payload: QwenVerifiedCheckpointPayload
}

/// Hashes the whole artifact against its registered manifest, then holds its
/// text tensors to the registered inventory through the product model's own
/// sanitizer and quantization path. No tensor payload is read here.
func prepareGemma4ResidentSource(_ admission: Gemma4ResidentAdmission,
                                check: () throws -> Void) throws -> Gemma4ResidentLocalSource {
    let spec = admission.specification
    let ceilings = try Gemma4ResidentResourceCeilings(specification: spec)
    let checkpoint = try VerifiedCheckpoint(directory: admission.configuration.modelDirectory,
        configurationData: admission.configBytes, expectedAggregateSHA256: spec.artifactSHA256,
        maximumPayloadBytes: ceilings.maximumManifestPayloadBytes, expectedManifestSHA256: spec.manifestSHA256)
    try checkpoint.requireConfiguration(admission.configBytes)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: admission.configBytes)
    let policy = base.perLayerQuantization ?? .init(perLayerQuantization: [:])
    weak var retired: Module?
    let result = try autoreleasepool {
        try withRandomState(MLXRandom.RandomState(seed: 7)) {
            // The product's wrapper for this model type: its parameter names are
            // the artifact's, and it drops the vision tower itself.
            let model = Gemma4Model(try JSONDecoder().decode(Gemma4Configuration.self, from: admission.configBytes))
            retired = model
            try check()
            let prepared = try PreparedQwenCheckpoint(model: model, checkpoint: checkpoint,
                originalConfiguration: admission.configBytes, policy: policy)
            let tensors = try registeredGemma4SourceTensors(prepared, model: model, specification: spec)
            let mappings = try Gemma4LayerStagePlanning.parameters(plan: admission.plan,
                canonicalSourceNames: tensors.map(\.sourceName))
            var quantization: [String: BaseConfiguration.Quantization] = [:]
            for (path, module) in model.leafModules().flattened() where prepared.canonical[path + ".scales"] != nil {
                guard let actual = module as? any Quantized, actual.mode == .affine,
                      let declared = resolveQuantization(path: path, perLayerQuantization: policy, aliasing: nil),
                      declared.mode == actual.mode, declared.bits == actual.bits,
                      declared.groupSize == actual.groupSize else {
                    throw ProbeError("Gemma stages require the exact declared affine projection: \(path)")
                }
                quantization[path] = declared
            }
            guard let scales = prepared.canonical[Gemma4LayerStagePlanning.embeddingModule + ".scales"],
                  let biases = prepared.canonical[Gemma4LayerStagePlanning.embeddingModule + ".biases"],
                  scales.dtype == .bfloat16, biases.dtype == .bfloat16 else {
                throw ProbeError("Gemma stage embedding is not native BF16")
            }
            let text = model.textModel.configuration
            try checkpoint.checkUnchanged()
            try check()
            let source = PreparedQwenLayerSource(verifiedAggregateSHA256: checkpoint.aggregate,
                sourceTensorCount: prepared.sourceTensorCount, tensors: tensors, mappings: mappings,
                quantization: quantization, activationDType: .bfloat16,
                hiddenSize: Gemma4StageGeometry.hiddenSize, vocabularySize: Gemma4StageGeometry.vocabularySize,
                bf16ConversionEnabled: true, sourceBytes: spec.sourceBytes,
                largestSourceBytes: spec.largestTensorBytes,
                sourceTensorManifestSHA256: sha256(try canonicalJSONData(tensors)),
                sourceParameterLayoutSHA256: qwenStageLayout(tensors.map {
                    "\($0.sourceName):\($0.loadedDType):\($0.shape)"
                }))
            return (Gemma4ResidentSource(source: source, specification: spec, textConfiguration: text,
                        fuseWeightedUnsort: model.textModel.weightedExpertUnsortEffective),
                    prepared.canonical)
        }
    }
    guard retired == nil else { throw ProbeError("Gemma full metadata model remained retained") }
    try check()
    return .init(metadata: result.0, payload: .init(checkpoint: checkpoint, canonical: result.1))
}

/// Every descriptor the sanitizer kept, as loader records in name order, after
/// it has been held to the registered inventory: one stored part per tensor,
/// the shape the quantized constructor expects, a packed weight exactly where
/// the constructor has one, and the pinned fingerprint over all of them.
private func registeredGemma4SourceTensors(_ prepared: PreparedQwenCheckpoint<TensorDescriptor>,
    model: Module, specification spec: Gemma4RegisteredSpecification
) throws -> [QwenStageSourceTensor] {
    let observed = observedQwenDenseSource(prepared, model: model)
    guard observed.count == spec.tensorCount, prepared.sourceTensorCount == spec.tensorCount else {
        throw ProbeError("Gemma source tensor count differs from its registered inventory")
    }
    var identities: [String] = [], tensors: [QwenStageSourceTensor] = [], total = 0, largest = 0
    for entry in observed {
        let canonical = entry.canonical
        try canonical.validate()
        guard entry.sourcePartCount == 1, canonical.shape == entry.preparedExpectedShape,
              let packed = entry.constructorParameterIsPacked, (canonical.sourceDType == "U32") == packed,
              ["U32", "BF16"].contains(canonical.sourceDType),
              let stored = QwenStageStoredDType(rawValue: canonical.sourceDType),
              let tensor = prepared.canonical[canonical.name] else {
            throw ProbeError("Gemma source requires an exact full tensor shape and dtype: \(canonical.name)")
        }
        identities.append(canonical.identity)
        total = try QwenLongPrefillCheckedBytes.sum([total, canonical.byteCount])
        largest = max(largest, canonical.byteCount)
        let part = tensor.parts[0]
        // Every float in these artifacts is already BF16: nothing is converted.
        tensors.append(.init(sourceName: canonical.name, canonicalPartName: part.name,
            file: part.tensor.storedFile, offset: part.tensor.storedOffset, shape: canonical.shape,
            sourceDType: stored.nativeName, loadedDType: stored.nativeName, byteCount: canonical.byteCount))
    }
    // `observed` is in name order, which is the order the fingerprint is pinned over.
    guard QwenDenseProfileIdentity.fingerprint(identities) == spec.inventorySHA256,
          total == spec.sourceBytes, largest == spec.largestTensorBytes else {
        throw ProbeError("Gemma source differs from the registered inventory in name, shape, dtype or bytes")
    }
    return tensors
}
