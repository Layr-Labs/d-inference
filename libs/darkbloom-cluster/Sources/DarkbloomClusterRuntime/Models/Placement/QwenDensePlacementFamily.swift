import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The Qwen resident runtime's answers to the planner's questions for its
/// interval-phased hybrid models: the dense models, the routed-expert models
/// (Qwen3.5 and Qwen3.6 35B A3B) and the Prism Hadamard pack (Ternary Bonsai
/// 2 27B). Each answer is read from the artifact's own configuration through
/// `QwenLayerStagePlan` and the registered model's row. Pure metadata: no
/// checkpoint payload and no GPU.
struct QwenDensePlacementFamily: ClusterPlacementFamily {
    let definition: QwenResidentModelDefinition
    let geometry: QwenLongPrefillBudgetGeometry
    let profile: QwenLayerStageGenerationProfile
    let pack: QwenRegisteredPack
    let layerPrefix: String
    /// One two-stage plan per position the plan's own rule allows.
    let plans: [Int: QwenLayerStagePlan]
    let structuralCuts: [Int]
    /// The tensor-parallel plan (`QwenTensorParallelPlan`, two shards by heads
    /// and channels; routed experts by every expert's channels) when it covers
    /// this artifact: a dense `qwen3_5_text` or routed-expert
    /// `qwen3_5_moe_text` model, affine 4- or 8-bit, an untied head, every
    /// head and channel count divisible. Nil otherwise, with the plan's own
    /// reason in `tensorParallelRefusal` (a Prism pack, ...).
    let tensorParallel: QwenTensorParallelPlan?
    let tensorParallelRefusal: String?
    /// Unequal share weights the plan accepts for this artifact (tried from
    /// `QwenTensorParallelPlan.candidateShares`; each part in whole units).
    let tensorParallelShareOptions: [[Int]]

    init(configuration: Data) throws {
        definition = try QwenResidentModelDefinition(configuration: configuration)
        guard definition.specification.model != .nemotron35Lightning else {
            throw ProbeError("Nemotron is placed by its own family")
        }
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("Placement needs the artifact's configuration object")
        }
        let nested = root["text_config"] as? [String: Any]
        let text = nested ?? root
        func n(_ key: String) throws -> Int { try QwenStageMetadata.integer(text, key, limit: 1_048_576) }
        // The geometry is the artifact's own; the registered row only names the model.
        geometry = try .init(layers: n("num_hidden_layers"), fullAttentionInterval: n("full_attention_interval"),
            hiddenSize: n("hidden_size"), queryHeads: n("num_attention_heads"), kvHeads: n("num_key_value_heads"),
            headDimension: n("head_dim"), linearKeyHeads: n("linear_num_key_heads"),
            linearValueHeads: n("linear_num_value_heads"), linearKeyDimension: n("linear_key_head_dim"),
            linearValueDimension: n("linear_value_head_dim"), convolutionKernel: n("linear_conv_kernel_dim"))
        profile = try QwenResidentAdapterDefinition.profile(specification: definition.specification)
        pack = definition.specification.model.pack
        // The wrapper types (the dense and routed-expert wrappers, a Prism
        // pack) construct the text model under `language_model.`.
        let wrappers = QwenRoutedExpertStageMetadata.wrapperModelTypes + [QwenPrismStageConfiguration.rootModelType]
        layerPrefix = (wrappers.contains(root["model_type"] as? String ?? "") ? "language_model." : "") + "model.layers."
        let cuts = try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
            fullAttentionInterval: geometry.fullAttentionInterval)
        var plans: [Int: QwenLayerStagePlan] = [:]
        for cut in cuts {
            plans[cut] = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<geometry.layers])
        }
        self.plans = plans; structuralCuts = cuts
        let quantization = root["quantization"] as? [String: Any] ?? [:]
        do {
            tensorParallel = try QwenTensorParallelPlan(textConfiguration: text, quantization: quantization, size: 2)
            tensorParallelRefusal = nil
        } catch {
            tensorParallel = nil; tensorParallelRefusal = "\(error)"
        }
        tensorParallelShareOptions = tensorParallel == nil ? [] : QwenTensorParallelPlan.candidateShares.filter { shares in
            (try? QwenTensorParallelPlan(textConfiguration: text, quantization: quantization, size: 2, shares: shares)) != nil
        }
    }

    var tensorParallelPlan: ClusterTensorParallelFamilyPlan? {
        tensorParallel.map { plan in
            // One reduction per row-parallel module of a layer (the mixer's
            // output and the MLP's down projection), float32 partials of the
            // residual width, and the head's distributed selection per step.
            ClusterTensorParallelFamilyPlan(
                plan: plan.routedExperts ? "qwen_moe_heads_and_expert_channels_v1" : "qwen_dense_heads_and_channels_v1",
                ranks: [plan.size],
                reductionsPerLayer: plan.reductionsPerForward / plan.layerCount, reductionsPerStep: 1,
                partialBytesPerToken: plan.hiddenSize * 4, stateDividesByHeads: true,
                shareOptions: tensorParallelShareOptions)
        }
    }

    /// The plan's cut for a stored tensor (it is the same for every rank):
    /// a whole tensor every rank holds, or rows or input columns divided.
    func tensorParallelCut(ofStoredTensor name: String) -> ClusterTensorParallelTensorCut? {
        guard let plan = tensorParallel, let disposition = try? plan.disposition(key: name, rank: 0) else { return nil }
        switch disposition {
        case .skip: return nil
        case .load(.replicate): return .replicated
        case .load(.rows), .load(.inputColumns), .load(.expertRows), .load(.expertInputColumns): return .divided
        }
    }

    var runtimeModelID: String { definition.specification.model.rawValue }
    var layerCount: Int { geometry.layers }
    var admittedCuts: [Int] { definition.supportedCuts }
    var generationModes: [ClusterGenerationMode] { definition.supportedGenerationModes }
    var prefillSchedules: [ClusterPrefillSchedule] { definition.supportedPrefillSchedules }
    var speculativeDecodeFactor: Double? { definition.speculativeDecodeFactor }
    /// The inline head every row with `phase_split_mtp_v1` ships, under `mtp.`
    /// (`QwenMTPHeadFiles`); no stage loads it.
    func isSpeculativeHead(storedTensor name: String) -> Bool { name.hasPrefix("mtp.") }
    /// The request a placement is planned and fitted for: the earlier
    /// reservation (8,192 prompt, 128 output, 8,320 context), not the profile's
    /// derived limits (up to 32,768 context, `QwenResidentContextLimits`). A
    /// placement that fits now holds the model and such a request; each rank
    /// then admits the largest context its Mac holds at load and gates every
    /// longer request live (`QwenResidentRuntime.admittedContext`). Planning
    /// memory and time for a longer planned request is a follow-up.
    static let planningLimits = ClusterPlacementPlanningLimits.reservation
    var maximumPromptTokens: Int { ClusterPlacementPlanningLimits.prompt(profile.maximumPromptTokens) }
    var maximumOutputTokens: Int { ClusterPlacementPlanningLimits.output(profile.maximumOutputTokens) }
    var maximumChunkTokens: Int { ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens) }
    var boundaryBytesPerToken: Int { geometry.hiddenSize * ((try? qwenStageWireElementBytes(profile.activationDType)) ?? 4) }

    /// `QwenResidentRequestAllowance` charges the whole model's conservative
    /// state to either rank.
    var requestChargeEveryRankBytes: Int {
        QwenPlacementCharge.wholeModelStateBytes(geometry: geometry, profile: profile)
    }
    var requestChargeEveryRankBytesPerToken: Int? {
        QwenPlacementCharge.wholeModelStateBytesPerToken(geometry: geometry, profile: profile)
    }

    /// The model's largest context (`QwenResidentContextLimits`), which ranks
    /// admit at load when memory allows; a placement may be planned for it.
    var largestContextTokens: Int { profile.maximumContextTokens }

    /// The same charge at another context: what a placement planned for that
    /// request has to fit on every rank.
    func requestChargeEveryRankBytes(contextTokens: Int) -> Int {
        QwenPlacementCharge.wholeModelStateBytes(geometry: geometry, contextTokens: contextTokens, chunk: maximumChunkTokens)
    }

    /// The name a stored tensor loads as. A routed bank's gate and up halves
    /// are stored apart and load as one fused tensor (`composeQwenCheckpointTensors`).
    static func canonicalName(ofStoredTensor name: String) -> String {
        for half in [".switch_mlp.gate_proj.", ".switch_mlp.up_proj."] where name.contains(half) {
            return name.replacingOccurrences(of: half, with: ".switch_mlp.gate_up_proj.")
        }
        return name
    }

    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        guard let plan = plans[cut] else { throw ProbeError("Not a cut of the Qwen stage plan: \(cut)") }
        return try plan.parameter(canonicalSourceName: Self.canonicalName(ofStoredTensor: name))?.stage
    }

    /// The layer of a tensor some stage loads; nil for one no stage loads (a
    /// Prism pack's transform signs, the MTP head, the vision tower).
    func layer(ofStoredTensor name: String) -> Int? {
        guard name.hasPrefix(layerPrefix),
              let first = name.dropFirst(layerPrefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first),
              let cut = structuralCuts.first, (try? stage(ofStoredTensor: name, cut: cut)) != nil else { return nil }
        return layer
    }

    func layerKind(_ layer: Int) -> String {
        (layer + 1) % geometry.fullAttentionInterval == 0 ? "full_attention" : "linear_attention"
    }

    /// The logical request state of one layer, as `QwenDenseStateBudget.finalState`
    /// shapes it: keys and values per token for a full-attention layer, a
    /// convolution window and a recurrent matrix for a linear one, in the
    /// pack's activation dtype (a Prism pack's state is float32).
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        let g = geometry, element = pack.activationElementBytes
        if (layer + 1) % g.fullAttentionInterval == 0 {
            return .init(fixedBytes: 4, bytesPerToken: 2 * g.kvHeads * g.headDimension * element)
        }
        let channels = 2 * g.linearKeyHeads * g.linearKeyDimension + g.linearValueHeads * g.linearValueDimension
        return .init(fixedBytes: (g.convolutionKernel - 1) * channels * element
            + g.linearValueHeads * g.linearValueDimension * g.linearKeyDimension * 4, bytesPerToken: 0)
    }

    /// A full-attention layer's frame materializes float32 scores over every
    /// key (head dimension 256 takes MLX's unfused path); a linear one has no
    /// score matrix.
    func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient {
        guard (layer + 1) % geometry.fullAttentionInterval == 0 else { return .none }
        return .attention(queryHeads: geometry.queryHeads, headDimension: geometry.headDimension)
    }

    /// What exists a second time while a request runs. An affine pack fuses
    /// a linear-attention layer's four input projections into one bank, and
    /// both exist while it is built. A Prism pack fuses nothing; its first
    /// forward keeps one float32 copy of every packed projection's float16
    /// scales and biases (not the embedding's), twice their stored bytes.
    func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int {
        let parts = name.split(separator: ".")
        guard parts.count >= 2 else { return 0 }
        if pack == .prismHadamard {
            guard ["scales", "biases"].contains(String(parts[parts.count - 1])),
                  !name.contains(QwenPrismStageConfiguration.embeddingPath + ".") else { return 0 }
            return 2 * storedBytes
        }
        guard pack.fusesGatedDeltaInputProjections, parts.contains("linear_attn"),
              ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"].contains(String(parts[parts.count - 2])) else { return 0 }
        return storedBytes
    }

    /// The tensors a stage loads, as the loader composes them, against the
    /// registered inventory: the same names, shapes, dtypes and bytes.
    func requireRegisteredInventory(_ tensors: [ClusterPlacementStoredTensor]) throws {
        guard let cut = structuralCuts.first else { throw ProbeError("The model has no cut") }
        var canonical: [String: QwenDenseCanonicalTensor] = [:]
        for tensor in tensors.sorted(by: { $0.name < $1.name }) where try stage(ofStoredTensor: tensor.name, cut: cut) != nil {
            let name = Self.canonicalName(ofStoredTensor: tensor.name)
            guard let first = canonical[name] else {
                canonical[name] = .init(name: name, shape: tensor.shape, sourceDType: tensor.dtype, byteCount: tensor.byteCount)
                continue
            }
            // The gate half sorts first; the up half follows it along axis 1.
            guard name != tensor.name, first.sourceDType == tensor.dtype, first.shape.count == tensor.shape.count,
                  first.shape.count >= 2, first.shape[0] == tensor.shape[0],
                  Array(first.shape.dropFirst(2)) == Array(tensor.shape.dropFirst(2)) else {
                throw ProbeError("The routed bank's two halves differ: \(name)")
            }
            var shape = first.shape; shape[1] += tensor.shape[1]
            canonical[name] = .init(name: name, shape: shape, sourceDType: first.sourceDType,
                                    byteCount: first.byteCount + tensor.byteCount)
        }
        let loaded = canonical.values.sorted { $0.name < $1.name }
        let specification = definition.specification
        guard loaded.count == specification.tensorCount,
              QwenDenseProfileIdentity.fingerprint(loaded.map(\.identity)) == specification.inventorySHA256 else {
            throw ProbeError("The artifact's tensor headers are not the registered model's inventory")
        }
    }
}

/// The whole-model request charge the Qwen resident allowance puts on either
/// rank (`QwenResidentRequestAllowance.derive`): the same named arrays at the
/// model's largest request, each rounded up by at most one 16 KiB page, with
/// one prefill frame's attention transient.
/// The request every family's placement is planned and fitted for: the earlier
/// reservation (8,192 prompt, 128 output, 8,320 context, chunks of 512), capped
/// by the family's own profile, not the profile's derived limits (up to 65,536
/// context). A placement that fits now holds the model and such a request; each
/// rank then admits the largest context its Mac holds at load and gates every
/// longer request live. Planning memory and time for a longer planned request
/// is a follow-up (integration 644271f53, applied to every family).
enum ClusterPlacementPlanningLimits {
    static let reservation = QwenResidentContextLimits.reservation
    static func prompt(_ profileMaximum: Int) -> Int { min(profileMaximum, reservation.maximumPromptTokens) }
    static func output(_ profileMaximum: Int) -> Int { min(profileMaximum, reservation.maximumOutputTokens) }
    static func chunk(_ profileMaximum: Int) -> Int { min(profileMaximum, reservation.maximumChunkTokens) }
    static func context(_ profileMaximum: Int) -> Int { min(profileMaximum, reservation.maximumContextTokens) }
}

enum QwenPlacementCharge {
    /// At the planned request's context (`ClusterPlacementPlanningLimits`).
    static func wholeModelStateBytes(geometry: QwenLongPrefillBudgetGeometry,
                                     profile: QwenLayerStageGenerationProfile) -> Int {
        wholeModelStateBytes(geometry: geometry, contextTokens: ClusterPlacementPlanningLimits.context(profile.maximumContextTokens),
            chunk: ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens))
    }

    /// What each context token below the planned request saves: the slope of
    /// the same charge between half the planned context and all of it (the
    /// keys and values grow with the context; the recurrent state does not).
    static func wholeModelStateBytesPerToken(geometry: QwenLongPrefillBudgetGeometry,
                                             profile: QwenLayerStageGenerationProfile) -> Int? {
        let chunk = ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens)
        let high = ClusterPlacementPlanningLimits.context(profile.maximumContextTokens), low = max(chunk + 1, high / 2)
        guard high > low else { return nil }
        let a = wholeModelStateBytes(geometry: geometry, contextTokens: high, chunk: chunk)
        let b = wholeModelStateBytes(geometry: geometry, contextTokens: low, chunk: chunk)
        return max(0, (a - b) / (high - low))
    }

    static func wholeModelStateBytes(geometry: QwenLongPrefillBudgetGeometry, contextTokens: Int, chunk: Int) -> Int {
        guard let b = try? QwenLongPrefillTensorBudget.estimate(geometry: geometry,
            maximumTokens: contextTokens, chunkSize: chunk) else { return 0 }
        let arrays = 6 * b.recurrentLayers + 3 * b.attentionLayers + 3
        return 3 * b.recurrentLayers * (b.convolutionBytesPerLayer + b.ssmBytesPerLayer)
            + b.attentionLayers * (b.kvCapacityBytesPerAttentionLayer + 4)
            + b.largestSingleHostStateComponentBytes + 2 * b.boundaryBytes + arrays * 16_384
    }
}

/// The fingerprint every family pins its inventory with: `name|dtype|shape|bytes`
/// lines of the tensors its stages load, in name order.
enum ClusterPlacementInventory {
    static func fingerprint(_ tensors: [ClusterPlacementStoredTensor]) -> String {
        QwenDenseProfileIdentity.fingerprint(tensors.sorted { $0.name < $1.name }.map {
            $0.name + "|" + $0.dtype + "|" + $0.shape.map(String.init).joined(separator: ",") + "|" + String($0.byteCount)
        })
    }
}

/// Layouts of every family this build places, chosen by the artifact's own
/// configuration (and, for two catalog entries that share one, its manifest).
/// Each family answers from its own stage plan; the builder, the planner, the
/// command and the provider step know no family.
public enum ClusterPlacementLayouts {
    /// The layout of the artifact these headers and this configuration belong
    /// to. `tensors` are every stored tensor of the artifact, as its
    /// safetensors headers name them; the tensors its stages load must be
    /// exactly the registered inventory. `manifest` picks between catalog
    /// entries that share a configuration (Gemma 4 26B and its 8-bit entry).
    public static func layout(configuration: Data, tensors: [ClusterPlacementStoredTensor],
                              manifest: Data? = nil, runtimeProfile: String? = nil) throws -> ClusterModelLayout {
        guard runtimeProfile == nil || runtimeProfile == ClusterMiMoImageCandidate.profileID || runtimeProfile == ClusterGLMImageCandidate.profileID else {
            throw ProbeError("Unknown placement runtime profile")
        }
        if runtimeProfile == ClusterMiMoImageCandidate.profileID, !MiMoPlacementFamily.handles(configuration: configuration) {
            throw ProbeError("MiMo candidate placement cannot describe another model")
        }
        #if canImport(MLXLLM)
        if runtimeProfile == ClusterGLMImageCandidate.profileID,
           !GLM5NextPlacementFamily.handles(configuration: configuration) {
            throw ProbeError("GLM candidate placement cannot describe another model")
        }
        #else
        guard runtimeProfile != ClusterGLMImageCandidate.profileID else { throw ProbeError("GLM runtime is unavailable") }
        #endif
        if MiMoPlacementFamily.handles(configuration: configuration) {
            let family = try MiMoPlacementFamily(configuration: configuration, imageCandidate: runtimeProfile != nil)
            try family.requireRegisteredInventory(tensors)
            return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
                artifactSHA256: family.specification.artifactSHA256,
                configurationSHA256: family.specification.configurationSHA256)
        }
        // GLM's configuration types live in MLXLLM, which the model-free
        // placement checks do not compile.
        #if canImport(MLXLLM)
        if GLM5NextPlacementFamily.handles(configuration: configuration) {
            let family = try GLM5NextPlacementFamily(configuration: configuration, imageCandidate: runtimeProfile == ClusterGLMImageCandidate.profileID)
            try family.requireRegisteredInventory(tensors)
            return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
                artifactSHA256: family.specification.artifactSHA256,
                configurationSHA256: family.specification.configurationSHA256)
        }
        #endif
        if GPTOSSRegisteredSpecification.handles(configuration: configuration) {
            let family = try GPTOSSPlacementFamily(configuration: configuration)
            try family.requireRegisteredInventory(tensors)
            return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
                artifactSHA256: family.specification.artifactSHA256,
                configurationSHA256: family.specification.configurationSHA256)
        }
        if Gemma4RegisteredSpecification.isRegistered(configuration: configuration) {
            let family = try Gemma4PlacementFamily(configuration: configuration, manifest: manifest)
            try family.requireRegisteredInventory(tensors)
            return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
                artifactSHA256: family.specification.artifactSHA256,
                configurationSHA256: family.specification.configurationSHA256)
        }
        let definition = try QwenResidentModelDefinition(configuration: configuration)
        if definition.specification.model == .nemotron35Lightning {
            let family = try NemotronPlacementFamily(configuration: configuration)
            try family.requireRegisteredInventory(tensors)
            return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
                artifactSHA256: definition.specification.artifactSHA256,
                configurationSHA256: definition.specification.configurationSHA256)
        }
        let family = try QwenDensePlacementFamily(configuration: configuration)
        try family.requireRegisteredInventory(tensors)
        let specification = family.definition.specification
        return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
            artifactSHA256: specification.artifactSHA256, configurationSHA256: specification.configurationSHA256)
    }
}
