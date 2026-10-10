import DarkbloomClusterProtocol
import Foundation

/// The registered models the resident adapter executes: one closed row per
/// `QwenRegisteredDenseModel` case. Selection is by that enumeration only. A
/// model ID outside it has no definition and cannot be admitted, described or
/// loaded; there is no open-ended model ID and no caller-supplied geometry.
/// Describing a model allocates nothing and admits no request. The model's
/// byte ceilings are `QwenResidentResourceCeilings`, kept apart so that
/// describing a model needs none of the loader's storage sources.
struct QwenResidentModelDefinition {
    let specification: QwenDenseRegisteredSpecification
    let profileID: String
    /// Stage 0 layer counts a pair may be loaded at, ascending.
    let supportedCuts: [Int]
    let supportedPrefillSchedules: [ClusterPrefillSchedule]
    /// How a request on this model may be divided between the ranks, the
    /// pipeline first. A mode outside this row is refused at load.
    let supportedGenerationModes: [ClusterGenerationMode]
    /// The protocol adapter that registers this model, and the arithmetic
    /// contract its ranks are started under. Both follow from the row.
    let adapter: ClusterRuntimeAdapter
    let arithmetic: QwenResidentArithmeticPolicy

    init(model: QwenRegisteredDenseModel) throws {
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }) else {
            throw QwenDenseProfileError("Registered model has no specification")
        }
        let geometry = try specification.expectedGeometry()
        let structural = try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
            fullAttentionInterval: geometry.fullAttentionInterval)
        switch model {
        case .qwen35NineB:
            // The original resident scope, defined where it always was.
            profileID = QwenResidentAdapterDefinition.profileID
            supportedCuts = QwenResidentAdapterDefinition.supportedCuts
        case .qwen38TwentySevenB:
            // Every whole-interval partition of the registered 64 layers:
            // 4, 8, ... 60. A structural cut is not a memory or speed claim.
            profileID = "registered_qwen38_27b_greedy_generation_v1"
            supportedCuts = structural
        case .qwen35ThirtyFiveBA3B:
            // Every whole-interval partition of the registered 40 layers:
            // 4, 8, ... 36. As for the 27B, structural and nothing more.
            profileID = "registered_qwen35_35b_a3b_greedy_generation_v1"
            supportedCuts = structural
        case .qwen36ThirtyFiveBA3B:
            profileID = "registered_qwen36_35b_a3b_greedy_generation_v1"
            supportedCuts = structural
        }
        // Routed experts are token-local, so they change neither the state a
        // mode moves nor its framing; what they need is their own arithmetic
        // contract and the adapter that names it.
        let arithmetic: QwenResidentArithmeticPolicy = specification.routedExperts == nil ? .dense : .routedExperts
        let registered = (runtimeModelID: model.rawValue, profileID: profileID)
        guard let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: model.rawValue),
              adapter.registeredProfiles.contains(where: { $0 == registered }),
              adapter.arithmeticPolicyID == arithmetic.contract else {
            throw QwenDenseProfileError("Registered model differs from its protocol adapter's row")
        }
        self.adapter = adapter; self.arithmetic = arithmetic
        supportedPrefillSchedules = QwenResidentAdapterDefinition.supportedPrefillSchedules
        // Compact decode framing and the phase split depend on the model only
        // through its registered geometry (state shapes and sizes follow from
        // the layer kinds and head counts), so both rows carry every mode. A
        // model that must not run one drops it from its own row here.
        switch model {
        case .qwen35NineB, .qwen38TwentySevenB, .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B:
            supportedGenerationModes = [.pipeline, .pipelineCompactDecode, .phaseSplit]
        }
        guard supportedGenerationModes.first == .pipeline,
              supportedGenerationModes == ClusterGenerationMode.allCases.filter(supportedGenerationModes.contains) else {
            throw QwenDenseProfileError("Resident generation modes must list the pipeline first, each once, in order")
        }
        guard !supportedCuts.isEmpty, supportedCuts == Array(Set(supportedCuts)).sorted(),
              supportedCuts.allSatisfy(structural.contains) else {
            throw QwenDenseProfileError("Resident cuts differ from the registered layer geometry")
        }
        self.specification = specification
    }

    /// The `modelID` of a worker identity. Anything but a registered ID is refused.
    init(runtimeModelID: String) throws {
        guard let model = QwenRegisteredDenseModel(rawValue: runtimeModelID) else {
            throw QwenDenseProfileError("Model ID is not a registered resident model")
        }
        try self.init(model: model)
    }

    /// The registered model whose pinned configuration these bytes are.
    init(configuration: Data) throws {
        let digest = QwenDenseProfileIdentity.sha256(configuration)
        guard (1...1_048_576).contains(configuration.count),
              let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.configurationSHA256 == digest }) else {
            throw QwenDenseProfileError("Configuration is not a registered resident model's")
        }
        try self.init(model: specification.model)
    }
}
