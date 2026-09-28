import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

struct QwenDenseConstructorSource {
    let source: PreparedQwenLayerSource
    let validation: QwenDenseSourceReadPlan
    let profile: QwenRegisteredDenseModelProfile
    let requirement: QwenDenseStorageRequirement
    let constructor: QwenDenseConstructorObservation
}

/// The full model exists only to run its actual sanitizer and lazy quantization
/// topology. No source tensor is read through TensorDescriptor.read or installed.
func prepareQwenDenseConstructorSource(checkpoint: VerifiedCheckpoint,
    admission: QwenDenseConstructorAdmission, check: () throws -> Void
) throws -> QwenDenseConstructorSource {
    guard !_qwen35MTPEnabled,
          checkpoint.aggregate == admission.specification.artifactSHA256,
          checkpoint.verifiedManifestSHA256 == admission.specification.manifestSHA256 else {
        throw ProbeError("Constructor probe requires exact verified checkpoint identity and MTP disabled")
    }
    try checkpoint.requireConfiguration(admission.configuration)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: admission.configuration)
    let policy = base.perLayerQuantization ?? .init(perLayerQuantization: [:])
    guard let root = try JSONSerialization.jsonObject(with: admission.configuration) as? [String: Any] else {
        throw ProbeError("Constructor probe configuration is not an object")
    }
    weak var retired: Module?
    let result = try {
        do {
            return try autoreleasepool {
                try withRandomState(MLXRandom.RandomState(seed: 7)) {
                    let model = try constructQwenModel(admission.configuration)
                    retired = model
                    try check()
                    try validateQwenStageDenseModel(model, layerCount: admission.plan.layers)
                    let prepared = try PreparedQwenCheckpoint(model: model, checkpoint: checkpoint,
                        originalConfiguration: admission.configuration, policy: policy)
                    try check()
                    let observed = observedQwenDenseSource(prepared, model: model)
                    let profile = try QwenRegisteredDenseModelProfile.admit(configuration: admission.configuration,
                        manifest: admission.manifest, expectedArtifactAggregateSHA256: checkpoint.aggregate,
                        canonicalTensors: observed.map(\.canonical))
                    let observedPlan = try profile.makePlanningPlan()
                    guard profile.model == admission.specification.model,
                          observedPlan.fingerprint == admission.plan.fingerprint else {
                        throw ProbeError("Observed constructor source differs from the selected registered Plan")
                    }
                    let requirement = try QwenDenseStorageRequirement.derive(profile: profile, plan: admission.plan,
                        role: .sequentialPair)
                    let identity = QwenDenseObservedSourceIdentity(aggregateSHA256: checkpoint.aggregate,
                        configurationSHA256: checkpoint.configurationSHA256,
                        verifiedManifestSHA256: checkpoint.verifiedManifestSHA256,
                        retainedSourceCount: prepared.sourceTensorCount, bf16ConversionEnabled: true)
                    let validated = try QwenDenseObservedSourceValidation.validateRegistered(observed,
                        identity: identity, profile: profile, requirement: requirement, plan: admission.plan)
                    let source = try finishPreparedQwenLayerSource(prepared: prepared, model: model,
                        plan: admission.plan, policy: policy, convert: true, validated: validated,
                        root: root, hidden: profile.geometry.hiddenSize, vocabulary: profile.vocabularySize,
                        check: check)
                    guard source.activationDType == .bfloat16 else {
                        throw ProbeError("Registered constructor source expected activation is not BF16")
                    }
                    let observation = try observeQwenDenseConstructor(model, role: "full", layerCount: admission.plan.layers,
                        configuration: admission.configuration)
                    try check()
                    return QwenDenseConstructorSource(source: source, validation: validated, profile: profile,
                        requirement: requirement, constructor: observation)
                }
            }
        } catch {
            let primary = error
            guard retired == nil else {
                throw ProbeError("Constructor metadata failure (\(primary)); model remained retained")
            }
            throw primary
        }
    }()
    guard retired == nil else { throw ProbeError("Full constructor probe model remained retained") }
    try check()
    return result
}
