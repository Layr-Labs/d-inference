import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

struct QwenResidentSource {
    let source: PreparedQwenLayerSource
    let validation: QwenDenseSourceReadPlan
    let profile: QwenRegisteredDenseModelProfile
    let pairRequirement: QwenDenseStorageRequirement
}

/// Registered descriptor preparation extracted from the constructor probe's
/// actual sanitizer/quantization path. The selected legal Plan is rebuilt from
/// the admitted profile; no constructor-observation/report API enters runtime.
func prepareQwenResidentSource(_ admission: QwenResidentAdmission,
                              check: () throws -> Void) throws -> QwenResidentSource {
    guard !_qwen35MTPEnabled else { throw ProbeError("Resident generation requires MTP disabled") }
    let resources = try QwenDenseRegisteredResourceProfile(specification: admission.specification)
    let checkpoint = try VerifiedCheckpoint(directory: admission.configuration.modelDirectory,
        configurationData: admission.configBytes, expectedAggregateSHA256: admission.specification.artifactSHA256,
        maximumPayloadBytes: resources.maximumManifestPayloadBytes,
        expectedManifestSHA256: admission.specification.manifestSHA256)
    try checkpoint.requireConfiguration(admission.configBytes)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: admission.configBytes)
    let policy = base.perLayerQuantization ?? .init(perLayerQuantization: [:])
    guard let root = try JSONSerialization.jsonObject(with: admission.configBytes) as? [String: Any] else {
        throw ProbeError("Resident source configuration is not an object")
    }
    weak var retired: Module?
    let result = try autoreleasepool {
        try withRandomState(MLXRandom.RandomState(seed: 7)) {
            let model = try constructQwenModel(admission.configBytes)
            retired = model
            try check()
            try validateQwenStageDenseModel(model, layerCount: admission.plan.layers)
            let prepared = try PreparedQwenCheckpoint(model: model, checkpoint: checkpoint,
                originalConfiguration: admission.configBytes, policy: policy)
            let observed = observedQwenDenseSource(prepared, model: model)
            let profile = try QwenRegisteredDenseModelProfile.admit(configuration: admission.configBytes,
                manifest: admission.manifestBytes, expectedArtifactAggregateSHA256: checkpoint.aggregate,
                canonicalTensors: observed.map(\.canonical))
            let rebuilt = try profile.makePlanningPlan(stageCut: admission.configuration.stageCut)
            guard profile.model == .qwen35NineB, rebuilt.fingerprint == admission.plan.fingerprint else {
                throw ProbeError("Resident source differs from the exact registered model and selected Plan")
            }
            let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: rebuilt, role: .sequentialPair)
            let identity = QwenDenseObservedSourceIdentity(aggregateSHA256: checkpoint.aggregate,
                configurationSHA256: checkpoint.configurationSHA256,
                verifiedManifestSHA256: checkpoint.verifiedManifestSHA256,
                retainedSourceCount: prepared.sourceTensorCount, bf16ConversionEnabled: true)
            let validation = try QwenDenseObservedSourceValidation.validateRegistered(observed,
                identity: identity, profile: profile, requirement: pair, plan: rebuilt)
            let source = try finishPreparedQwenLayerSource(prepared: prepared, model: model,
                plan: rebuilt, policy: policy, convert: true, validated: validation, root: root,
                hidden: profile.geometry.hiddenSize, vocabulary: profile.vocabularySize, check: check)
            guard source.activationDType == .bfloat16 else { throw ProbeError("Resident source is not native BF16") }
            return QwenResidentSource(source: source, validation: validation, profile: profile, pairRequirement: pair)
        }
    }
    guard retired == nil else { throw ProbeError("Resident full metadata model remained retained") }
    try check()
    return result
}
