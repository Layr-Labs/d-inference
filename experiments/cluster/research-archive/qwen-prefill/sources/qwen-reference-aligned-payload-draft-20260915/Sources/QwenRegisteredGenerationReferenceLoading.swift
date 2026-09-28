import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Registered descriptor admission around the existing full-width materializer.
/// The legacy diagnostic loader's limits and all actual request math stay intact.
func loadQwenRegisteredGenerationReferenceBaseline(directory: URL,
    preflight: QwenFullGenerationReferencePreflight, resources: QwenFullGenerationReferenceResources,
    check: () throws -> Void) throws -> LoadedModel {
    try withoutActuallyEscaping(check) { borrowedCheck in
        try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try borrowedCheck(); try nativeError.check() }
            do {
                try checked()
                guard !_qwen35MTPEnabled else { throw ProbeError("Full generation reference requires MTP disabled") }
                let source = preflight.admission.source, specification = source.specification
                let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: source.configuration,
                    expectedAggregateSHA256: specification.artifactSHA256,
                    maximumPayloadBytes: source.resource.maximumManifestPayloadBytes,
                    expectedManifestSHA256: specification.manifestSHA256)
                try checkpoint.requireConfiguration(source.configuration); try checked()
                let base = try JSONDecoder().decode(BaseConfiguration.self, from: source.configuration)
                guard let policy = base.perLayerQuantization else { throw ProbeError("Registered reference lacks quantization policy") }
                return try withRandomState(MLXRandom.RandomState(seed: 7)) {
                    let model = try constructQwenModel(source.configuration)
                    let layers = try validateDiagnosticQwen(model: model, configuration: source.configuration, policy: policy)
                    guard layers == specification.layers else { throw ProbeError("Registered reference constructor layer count differs") }
                    try checked()
                    let prepared = try PreparedQwenCheckpoint(model: model, checkpoint: checkpoint,
                        originalConfiguration: source.configuration, policy: policy)
                    let observed = observedQwenDenseSource(prepared, model: model)
                    let profile = try QwenRegisteredDenseModelProfile.admit(configuration: source.configuration,
                        manifest: source.manifest, expectedArtifactAggregateSHA256: checkpoint.aggregate,
                        canonicalTensors: observed.map(\.canonical), residentDefinition: source.definition)
                    let requirement = try QwenDenseStorageRequirement.derive(profile: profile,
                        plan: source.plan, role: .fullReference)
                    let identity = QwenDenseObservedSourceIdentity(aggregateSHA256: checkpoint.aggregate,
                        configurationSHA256: checkpoint.configurationSHA256,
                        verifiedManifestSHA256: checkpoint.verifiedManifestSHA256,
                        retainedSourceCount: prepared.sourceTensorCount, bf16ConversionEnabled: true)
                    let storage = try QwenDenseObservedSourceValidation.validateRegistered(observed,
                        identity: identity, profile: profile, requirement: requirement, plan: source.plan)
                    _ = try validatedQwenFeedForwardScaleTypes(model, layers: layers,
                        isMoE: false, requireTwoWaySplit: false)
                    try resources.prepared(prepared, storage: storage); try checked()
                    // Reduce file-cache duplication during verified weight reads.
                    // This requests the same descriptor-local cache policy and
                    // bounded aligned reader used by selected-stage loading; its
                    // scratch is included in this reference's free-memory ledger.
                    try checkpoint.bypassTensorPayloadCache(); try checked()
                    let receipt = try materializeVerifiedQwenDiagnostic(model: model, prepared: prepared,
                        originalConfiguration: source.configuration, storage: storage, convertBF16: true,
                        check: checked, beforeTensor: { name, tensor in
                            try resources.beforeTensor(name, tensor: tensor); try checked()
                        })
                    try checkpoint.checkUnchanged(); try checked()
                    let geometry = try QwenDenseShortBaselineGeometry(configuration: source.configuration)
                    let loaded = try finishVerifiedQwenLayerStageBaseline(model: model,
                        originalConfiguration: source.configuration, receipt: receipt,
                        expectedAggregateSHA256: checkpoint.aggregate, label: "registered-generation-reference",
                        layers: specification.layers, hidden: specification.hidden,
                        vocabulary: source.request.profile.vocabularySize, namespace: geometry.namespace, check: checked)
                    try checkpoint.checkUnchanged(); try checked()
                    return loaded
                }
            } catch { try nativeError.check(); throw error }
        }
    }
}

/// The complete loaded target must match the selected registered profile.
/// No legacy six-GiB ceiling is enlarged to admit the larger model.
func admitQwenRegisteredGenerationReferenceSource(loaded: LoadedModel,
    admission: QwenRegisteredGenerationReferenceSource
) throws -> (QwenLongPrefillReferenceSource, VerifiedQwenDiagnosticReceipt) {
    let specification = admission.specification
    guard let receipt = loaded.verifiedDiagnosticLoad, receipt.schemaVersion == 1,
          loaded.family == .qwen35, loaded.feedForwardKind == "dense", loaded.gemmaTrace == nil,
          loaded.partitionPlan == nil, loaded.partitionStorage == nil, loaded.directShardLoad == nil,
          loaded.configurationData == admission.configuration,
          loaded.configHash == specification.configurationSHA256,
          receipt.configurationSHA256 == loaded.configHash,
          receipt.verifiedAggregateSHA256 == specification.artifactSHA256,
          receipt.parameterLayoutSHA256 == loaded.parameterLayoutSHA256,
          modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256,
          receipt.bf16ConversionEnabled, loaded.bf16ConversionEnabled,
          loaded.embeddingActivationDType == "bfloat16",
          receipt.loadedTensorBytes == specification.sourceBytes,
          receipt.sourceModelTensorBytes == specification.sourceBytes,
          receipt.largestHostTensorBytes == specification.largestTensorBytes,
          receipt.tensorCount == specification.tensorCount, receipt.sourceTensorCount == specification.tensorCount,
          loaded.layerCount == specification.layers, loaded.layerCount == admission.plan.layers,
          loaded.vocabularySize == admission.request.profile.vocabularySize,
          loaded.model.trainableParameters().flattened().isEmpty,
          !loaded.model.namedModules().contains(where: { $0.0 == "mtp" || $0.0.hasSuffix(".mtp") }) else {
        throw ProbeError("Full generation reference differs from its verified registered target")
    }
    return (.init(artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
        sourceConfigurationSHA256: loaded.configHash, sourceParameterLayoutSHA256: loaded.parameterLayoutSHA256,
        planSHA256: admission.plan.fingerprint, arithmeticEnvironmentSHA256: admission.arithmeticEnvironmentSHA256,
        bf16ConversionEnabled: loaded.bf16ConversionEnabled, embeddingActivationDType: loaded.embeddingActivationDType,
        sourceModelTensorBytes: receipt.sourceModelTensorBytes, layerCount: loaded.layerCount,
        vocabularySize: loaded.vocabularySize), receipt)
}
