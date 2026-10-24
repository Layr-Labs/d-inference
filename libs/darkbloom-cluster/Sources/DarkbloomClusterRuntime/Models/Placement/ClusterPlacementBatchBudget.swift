import DarkbloomClusterPlacement
import Foundation

/// Metadata-only quotation of the native independent-history owners. Each
/// lane keeps its complete allowance; shared decode workspace is charged once.
/// A cut-independent quote takes maxima over every admitted nonempty stage,
/// plus the whole-model layer-state floor used by the placement policy.
enum ClusterPlacementBatchBudget {
    struct Charge { let request: Int; let shared: Int }

    static func gptoss(_ family: GPTOSSPlacementFamily, prompt: Int, output: Int, chunk: Int, lanes: Int,
                       bound: (Int) throws -> Int) throws -> Charge {
        try validate(profile: family.profile, prompt: prompt, output: output, chunk: chunk, lanes: lanes)
        let maximum = prompt + output, frame = min(prompt, chunk)
        var perLane = try layerFloor(family, maximum: maximum), shared = 0
        for cut in family.admittedCuts {
            guard let plan = family.plans[cut] else { throw ProbeError("Missing admitted GPT-OSS batch cut") }
            for stage in plan.stages {
                let state = try GPTOSSRequestStateBudget.estimate(specification: family.specification,
                    layers: stage.layers, rank: stage.index, maximumTokens: maximum, chunkSize: frame, bound: bound)
                let prefill = try QwenGenerationPrefillAllowance.derive(rank: stage.index, promptCount: prompt,
                    chunkSize: frame, hiddenSize: family.specification.hidden, elementBytes: 4, bound: bound)
                let work = try GPTOSSBatchWorkspace.estimate(spec: family.specification, localLayers: stage.layers.count,
                    rank: stage.index, lanes: lanes, bound: bound)
                perLane = max(perLane, try QwenLongPrefillCheckedBytes.sum([state.reservedBytes, prefill.reservedBytes]))
                shared = max(shared, try QwenLongPrefillCheckedBytes.sum([work.native, work.host]))
            }
        }
        return .init(request: perLane, shared: shared)
    }

    static func mimo(_ family: MiMoPlacementFamily, prompt: Int, output: Int, chunk: Int, lanes: Int,
                     bound: (Int) throws -> Int) throws -> Charge {
        try validate(profile: family.profile, prompt: prompt, output: output, chunk: chunk, lanes: lanes)
        guard !family.imageCandidate else { throw ProbeError("Image candidates cannot borrow a text batch quote") }
        let maximum = prompt + output, frame = min(prompt, chunk)
        var perLane = try layerFloor(family, maximum: maximum), shared = 0
        for cut in family.admittedCuts {
            guard let plan = family.plans[cut] else { throw ProbeError("Missing admitted MiMo batch cut") }
            for stage in plan.stages {
                let range = stage.sourceRange
                let state = try MiMoRequestStateBudget.estimate(specification: family.specification, layers: range,
                    rank: stage.index, maximumTokens: maximum, chunkSize: frame, bound: bound)
                let pages = try MiMoPagedKVAllowance.pages(spec: family.specification, layers: range,
                    maximumTokens: maximum, chunkSize: frame, bound: bound)
                let history = try MiMoBatchMemory.historyBytes(maximumTokens: maximum)
                let work = try MiMoBatchMemory.workspace(spec: family.specification, localLayers: stage.layers.count,
                    rank: stage.index, lanes: lanes, bound: bound)
                perLane = max(perLane, try QwenLongPrefillCheckedBytes.sum([state.reservedBytes, pages, history]))
                shared = max(shared, try QwenLongPrefillCheckedBytes.sum([work.native, work.host]))
            }
        }
        return .init(request: perLane, shared: shared)
    }

    private static func validate(profile: QwenLayerStageGenerationProfile, prompt: Int, output: Int,
                                 chunk: Int, lanes: Int) throws {
        guard [2, 4, 8].contains(lanes), (1...profile.maximumChunkTokens).contains(chunk),
              (1...profile.maximumPromptTokens).contains(prompt), (1...profile.maximumOutputTokens).contains(output),
              prompt <= profile.maximumContextTokens - output else {
            throw ProbeError("Native batch quote is outside the registered request scope")
        }
    }

    private static func layerFloor<F: ClusterPlacementFamily>(_ family: F, maximum: Int) throws -> Int {
        try QwenLongPrefillCheckedBytes.sum(try (0..<family.layerCount).map { layer in
            let state = try family.requestState(layer: layer)
            return try QwenLongPrefillCheckedBytes.sum([state.fixedBytes,
                QwenLongPrefillCheckedBytes.product([state.bytesPerToken, maximum])])
        })
    }
}

extension ClusterPlacementArtifact {
    /// Header/configuration work only. The caller supplies the current native
    /// allocator's metadata-only upper bound, never a measured free-memory credit.
    public static func requestedBatchQuote(directory: URL, promptTokens: Int, outputTokens: Int,
                                           chunkTokens: Int, lanes: Int,
                                           allocationBound: (Int) throws -> Int) throws -> ClusterPlacementBatchQuote {
        let configuration = try Self.configuration(directory: directory)
        func quote(model: String, artifact: String, hash: String, profile: QwenLayerStageGenerationProfile,
                   charge: ClusterPlacementBatchBudget.Charge) throws -> ClusterPlacementBatchQuote {
            let request = try ClusterPlacementRequestScope(runtimeModelID: model, artifactSHA256: artifact,
                configurationSHA256: hash, promptTokens: promptTokens, outputTokens: outputTokens,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumContextTokens: profile.maximumContextTokens, requestChargeEveryRankBytes: charge.request)
            return try .init(request: request, lanes: lanes, chunkTokens: chunkTokens,
                sharedWorkspaceEveryRankBytes: charge.shared)
        }
        if GPTOSSRegisteredSpecification.handles(configuration: configuration) {
            let family = try GPTOSSPlacementFamily(configuration: configuration)
            return try quote(model: family.runtimeModelID, artifact: family.specification.artifactSHA256,
                hash: family.specification.configurationSHA256, profile: family.profile,
                charge: ClusterPlacementBatchBudget.gptoss(family, prompt: promptTokens, output: outputTokens,
                    chunk: chunkTokens, lanes: lanes, bound: allocationBound))
        }
        if MiMoPlacementFamily.handles(configuration: configuration) {
            let family = try MiMoPlacementFamily(configuration: configuration)
            return try quote(model: family.runtimeModelID, artifact: family.specification.artifactSHA256,
                hash: family.specification.configurationSHA256, profile: family.profile,
                charge: ClusterPlacementBatchBudget.mimo(family, prompt: promptTokens, output: outputTokens,
                    chunk: chunkTokens, lanes: lanes, bound: allocationBound))
        }
        throw ProbeError("This family has no separate native batch quotation")
    }
}
