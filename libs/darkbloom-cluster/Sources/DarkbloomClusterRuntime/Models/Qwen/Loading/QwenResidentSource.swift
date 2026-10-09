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

/// The artifact identities a source's descriptors belong to. A file-backed
/// source hashed them; a pinned one takes them from the registered specification.
struct QwenResidentArtifactIdentity {
    let aggregateSHA256: String
    let configurationSHA256: String
    let verifiedManifestSHA256: String?
}

/// A resident source whose payload is this Mac's verified artifact.
struct QwenResidentLocalSource {
    let metadata: QwenResidentSource
    let payload: QwenVerifiedCheckpointPayload
}

/// Registered descriptor preparation extracted from the constructor probe's
/// actual sanitizer/quantization path. The selected legal Plan is rebuilt from
/// the admitted profile; no constructor-observation/report API enters runtime.
func prepareQwenResidentSource(_ admission: QwenResidentAdmission,
                              check: () throws -> Void) throws -> QwenResidentLocalSource {
    guard !_qwen35MTPEnabled else { throw ProbeError("Resident generation requires MTP disabled") }
    let ceilings = try QwenResidentResourceCeilings(specification: admission.specification)
    let checkpoint = try VerifiedCheckpoint(directory: admission.configuration.modelDirectory,
        configurationData: admission.configBytes, expectedAggregateSHA256: admission.specification.artifactSHA256,
        maximumPayloadBytes: ceilings.maximumManifestPayloadBytes,
        expectedManifestSHA256: admission.specification.manifestSHA256)
    try checkpoint.requireConfiguration(admission.configBytes)
    let prepared = try prepareQwenResidentMetadata(admission,
        artifact: .init(aggregateSHA256: checkpoint.aggregate, configurationSHA256: checkpoint.configurationSHA256,
                        verifiedManifestSHA256: checkpoint.verifiedManifestSHA256),
        check: check, confirmUnchanged: checkpoint.checkUnchanged) { model, policy in
            try PreparedQwenCheckpoint(model: model, checkpoint: checkpoint,
                originalConfiguration: admission.configBytes, policy: policy)
        }
    return .init(metadata: prepared.source, payload: .init(checkpoint: checkpoint, canonical: prepared.canonical))
}

/// The registered checks every origin of descriptors passes: the sanitizer and
/// quantization path over a lazily constructed model, the closed profile, the
/// rebuilt Plan and the validated read plan. `confirmUnchanged` runs once the
/// scalar records are assembled; a file-backed origin checks its files there.
func prepareQwenResidentMetadata<Stored>(_ admission: QwenResidentAdmission,
    artifact: QwenResidentArtifactIdentity,
    check: () throws -> Void, confirmUnchanged: () throws -> Void,
    prepare: (any LanguageModel, BaseConfiguration.PerLayerQuantization) throws -> PreparedQwenCheckpoint<Stored>
) throws -> (source: QwenResidentSource, canonical: [String: QwenCheckpointTensor<Stored>]) {
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
            let prepared = try prepare(model, policy)
            let observed = observedQwenDenseSource(prepared, model: model)
            let profile = try QwenRegisteredDenseModelProfile.admit(configuration: admission.configBytes,
                manifest: admission.manifestBytes, expectedArtifactAggregateSHA256: artifact.aggregateSHA256,
                canonicalTensors: observed.map(\.canonical))
            let rebuilt = try profile.makePlanningPlan(stageCut: admission.configuration.stageCut)
            guard profile.model == admission.specification.model, rebuilt.fingerprint == admission.plan.fingerprint else {
                throw ProbeError("Resident source differs from the exact registered model and selected Plan")
            }
            let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: rebuilt, role: .sequentialPair)
            // What the registered pack stores decides the load conversion and
            // the dtype every stage must then be found to run in.
            let pack = profile.model.pack
            let identity = QwenDenseObservedSourceIdentity(aggregateSHA256: artifact.aggregateSHA256,
                configurationSHA256: artifact.configurationSHA256,
                verifiedManifestSHA256: artifact.verifiedManifestSHA256,
                retainedSourceCount: prepared.sourceTensorCount, bf16ConversionEnabled: pack.convertsFloat16ToBFloat16)
            let validation = try QwenDenseObservedSourceValidation.validateRegistered(observed,
                identity: identity, profile: profile, requirement: pair, plan: rebuilt)
            let source = try finishPreparedQwenLayerSource(prepared: prepared,
                verifiedAggregateSHA256: artifact.aggregateSHA256, model: model,
                plan: rebuilt, policy: policy, convert: pack.convertsFloat16ToBFloat16, validated: validation, root: root,
                hidden: profile.geometry.hiddenSize, vocabulary: profile.vocabularySize, check: check)
            try confirmUnchanged()
            guard String(describing: source.activationDType) == pack.activationDType,
                  (source.prism != nil) == (pack == .prismHadamard) else {
                throw ProbeError(pack == .affineBFloat16 ? "Resident source is not native BF16"
                    : "Resident source does not run in its registered pack's activation dtype")
            }
            return (QwenResidentSource(source: source, validation: validation, profile: profile, pairRequirement: pair),
                    prepared.canonical)
        }
    }
    guard retired == nil else { throw ProbeError("Resident full metadata model remained retained") }
    try check()
    return result
}
