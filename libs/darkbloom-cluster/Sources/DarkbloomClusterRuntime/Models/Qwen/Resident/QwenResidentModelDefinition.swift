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
    /// The decode speed-up a placement planner credits the model's own
    /// speculative head with (`ClusterModelLayout.speculativeDecodeFactor`):
    /// the smallest speed-up the pair measured with the head over the same
    /// phase split without it. Nil for a row without `phase_split_mtp_v1`.
    let speculativeDecodeFactor: Double?

    init(model: QwenRegisteredDenseModel) throws {
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }) else {
            throw QwenDenseProfileError("Registered model has no specification")
        }
        let geometry = try specification.expectedGeometry()
        // Nemotron's layer kinds follow no interval; its structural cuts are its own.
        let structural = model == .nemotron35Lightning
            ? NemotronStageMetadata.structuralCuts(NemotronRegisteredLightning.kinds)
            : try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
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
        case .ternaryBonsai2TwentySevenB:
            // The 27B's geometry, so the 27B's cuts: 4, 8, ... 60.
            profileID = "registered_ternary_bonsai_2_27b_greedy_generation_v1"
            supportedCuts = structural
        case .nemotron35Lightning:
            // A closed list of its structural cuts, not all 32 of them: a
            // capability carries at most sixteen partitions.
            profileID = NemotronRegisteredLightning.profileID
            supportedCuts = NemotronRegisteredLightning.supportedCuts
        }
        // Routed experts are token-local, so they change neither the state a
        // mode moves nor its framing; what they need is their own arithmetic
        // contract and the adapter that names it. A Prism pack's arithmetic
        // depends on two more switches of the process environment, so it has
        // its own contract and the adapter that names it too; so does Nemotron.
        let arithmetic: QwenResidentArithmeticPolicy = model == .nemotron35Lightning ? .nemotronHybrid
            : specification.routedExperts != nil ? .routedExperts
            : model.pack == .prismHadamard ? .prismHadamard : .dense
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
        case .qwen35NineB, .qwen38TwentySevenB:
            // Both artifacts ship the product's inline speculative head
            // (`mtplx_mtp.included`, one dense decoder layer under `mtp.`),
            // which the decoding rank of a phase split runs as the product does,
            // and the last rank of a speculative pipeline beside its stage (with
            // a copy of the token embedding). Both are dense: the worker runs
            // tensor parallel on them (`QwenTensorParallelResidentRuntime`).
            supportedGenerationModes = [.pipeline, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP, .tensorParallel,
                                        .pipelineMTP]
        case .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B:
            // Both artifacts ship the product's inline head too (one routed-
            // expert decoder layer under `mtp.`, split gate and up as the SDK's
            // `Qwen35MTPDecoderLayer` keys them); the decoding rank runs it the
            // same way, and so does the last rank of a speculative pipeline.
            supportedGenerationModes = [.pipeline, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP, .pipelineMTP]
        case .ternaryBonsai2TwentySevenB:
            // The Prism pack's state has the 27B's shapes in F32; the hand-off
            // carries each component in the profile's activation dtype. Its
            // artifact ships no head (`mtp_num_hidden_layers` 0).
            supportedGenerationModes = [.pipeline, .pipelineCompactDecode, .phaseSplit]
        case .nemotron35Lightning:
            // Its state shapes are the ones a hand-off already carries (KV of
            // an attention block, convolution and SSM state of a Mamba block)
            // and an expert block has none, so the phase split is admissible.
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
        // Measured on the pair (M3 Ultra rank 0, M5 Max decoding), all four
        // lanes, median of requests 2 to 4, 128 tokens; the smallest of each
        // model's measured speed-ups, so a plan never counts on more: the 9B
        // at 1,024 tokens (115.4 against 79.9 tok/s; 1.59x at 5,120), the 27B
        // at 5,120 (42.4 against 27.1; 1.70x at 1,024), the Qwen3.6 35B A3B at
        // 4,096 with depth 3 (105.8 against 73.3; the Qwen3.5 row 1.64x).
        let measuredSpeculativeSpeedup: Double? = switch model {
        case .qwen35NineB: 1.44
        case .qwen38TwentySevenB: 1.56
        case .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B: 1.44
        case .ternaryBonsai2TwentySevenB, .nemotron35Lightning: nil
        }
        speculativeDecodeFactor = supportedGenerationModes.contains(.phaseSplitMTP) ? measuredSpeculativeSpeedup : nil
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
