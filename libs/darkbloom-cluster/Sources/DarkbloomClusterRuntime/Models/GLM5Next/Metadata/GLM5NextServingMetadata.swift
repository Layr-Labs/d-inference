import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM

/// Capability metadata of the registered GLM row: the same specification,
/// descriptor and stage-contract arithmetic the resident load uses, so each
/// partition's Plan hash is the one a loaded rank reports at READY. No
/// checkpoint payload, shard header or GPU is read.
public enum GLM5NextResidentCapabilityMetadata {
    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String, imageCandidate: Bool = false) throws -> ClusterRuntimeCapability {
        guard qwenStageWireIsSHA256(runtimeBinarySHA256) else {
            throw ProbeError("Capability metadata requires a runtime binary digest")
        }
        let spec = try GLM5NextRegisteredSpecification.specification(configuration: configuration)
        let profile = try spec.profile(imageCandidate: imageCandidate)
        let parsed = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configuration)
        // One identity and one parse for all cuts: the 10 MiB configuration is
        // decoded once, not once per partition.
        let identity = GLM5NextArtifactIdentity(repository: spec.repository, revision: spec.revision,
            files: try spec.runtimeFiles(manifest: manifest))
        let partitions = try spec.supportedCuts.map { cut -> ClusterRuntimePartition in
            let contract = try GLM5NextServingResources.contract(specification: spec, configuration: parsed,
                artifactIdentity: identity, cut: cut)
            return ClusterRuntimePartition(planSHA256: contract.source.planFingerprint, stages: [
                ClusterRuntimeStage(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut,
                    stagePlanSHA256: contract.stageFingerprints[0],
                    constructionConfigurationSHA256: contract.constructionConfigurationSHA256),
                ClusterRuntimeStage(rank: 1, sourceLayerStart: cut, sourceLayerEnd: spec.layers,
                    stagePlanSHA256: contract.stageFingerprints[1],
                    constructionConfigurationSHA256: contract.constructionConfigurationSHA256),
            ])
        }
        let adapter = ClusterRuntimeAdapter.glm5NextLayerStage
        return try ClusterRuntimeCapability(runtimeBinarySHA256: runtimeBinarySHA256,
            adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: spec.model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            manifestSHA256: spec.manifestSHA256,
            profile: .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
            profileFingerprint: profile.fingerprint, partitions: partitions,
            arithmeticPolicyID: adapter.arithmeticPolicyID,
            arithmeticPolicySHA256: try GLM5NextStageContract.policySHA256(spec.executionPolicy),
            supportedPrefillSchedules: spec.supportedPrefillSchedules,
            // The private PNG image candidate is pipeline-only; tensor parallel serves
            // images and video under the text profile (`ClusterGLMMedia`, READY's `media`).
            supportedGenerationModes: imageCandidate ? [.pipeline] : spec.supportedGenerationModes,
            glmImages: imageCandidate ? .init() : nil)
    }
}

/// Serving resources of a registered GLM rank. The request workspace is the
/// product's conservative activation floor (`UnifiedMemoryCap`'s default
/// reserve, sized for the worst measured model) until a measured GLM floor
/// replaces it; it covers every layer and the row's whole request scope.
enum GLM5NextServingResources {
    /// 5.5 GiB: the provider's default activation reserve for an unmeasured model.
    static let workspaceNativeBytes = 11 * 1024 * 1024 * 1024 / 2
    /// Host allocator, Foundation and CryptoKit scratch beside the named wire buffers.
    static let workspaceHostBytes = 1024 * 1024 * 1024
    static let workspaceBasis = "glm5-next-conservative-workspace-v1:unified-memory-default-activation-reserve"

    static func contract(specification spec: GLM5NextRegisteredSpecification, configuration: GLM5NextConfiguration,
                         artifactIdentity: GLM5NextArtifactIdentity, cut: Int) throws -> GLM5NextStageContractMetadata {
        guard spec.supportedCuts.contains(cut) else { throw ProbeError("Not a cut of the registered GLM row: \(cut)") }
        return try GLM5NextStageContractMetadata(configuration: configuration,
            artifactIdentity: artifactIdentity, storage: spec.storage,
            executionPolicy: spec.executionPolicy, artifactAggregateSHA256: spec.artifactSHA256,
            storageCommitmentSHA256: try GLM5NextStageContractMetadata.storageCommitment(
                inventorySHA256: spec.inventorySHA256, cut: cut, includeMTP: false),
            cut: cut)
    }

    /// The device and binary this rank executes on. Recomputed before every
    /// load and request quotation; a change refuses rather than requoting.
    static func environmentSHA256(buildSHA256: String) throws -> String {
        let info = GPU.deviceInfo()
        return sha256(try canonicalJSONData([
            "glm5-next-serving-environment-v1", buildSHA256,
            ProcessInfo.processInfo.operatingSystemVersionString, info.architecture,
            String(info.maxBufferSize), String(info.maxRecommendedWorkingSetSize), String(info.memorySize),
        ]))
    }

    static func hostBound(_ bytes: Int) throws -> Int {
        let page = Int(getpagesize())
        let padded = bytes.addingReportingOverflow(page - 1)
        guard bytes >= 0, !padded.overflow else { throw ProbeError("GLM host rounding overflow") }
        let rounded = (padded.partialValue / page).multipliedReportingOverflow(by: page)
        let total = rounded.partialValue.addingReportingOverflow(page)
        guard !rounded.overflow, !total.overflow else { throw ProbeError("GLM host bound overflow") }
        return total.partialValue
    }

    /// The envelope of one rank: load capacity is the GPU's resident capacity
    /// (hardware, never transient free or file-cache memory); the request
    /// capacity is the quotation of the row's memory scope on this rank's
    /// layers (`GLM5NextResidentDescriptor.memoryProfile`). The workspace
    /// evidence covers the profile's whole scope, so a runtime that charges a
    /// longer request at its own context (tensor parallel) quotes it here too.
    static func envelope(descriptor: GLM5NextResidentDescriptor, inventory: GLM5NextWeightInventory,
                         rank: Int, buildSHA256: String) throws -> GLM5NextResidentResourceEnvelope {
        let environment = try environmentSHA256(buildSHA256: buildSHA256)
        let c = inventory.configuration.textConfig
        let p = descriptor.profile
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: p.maximumContextTokens,
            maximumPromptTokens: p.maximumPromptTokens, maximumOutputTokens: p.maximumOutputTokens,
            maximumChunkTokens: p.maximumChunkTokens, includesVision: descriptor.includesVision)
        let evidence = GLM5NextRequestStateBudget.WorkspaceEvidence(kind: .conservative,
            evidenceSHA256: sha256(Data(workspaceBasis.utf8)),
            configurationSHA256: sha256(try canonicalJSONData(c)),
            inventorySHA256: GLM5NextArtifactMetadata.fingerprint(inventory),
            numericalPolicySHA256: try GLM5NextStageContract.policySHA256(descriptor.executionPolicy),
            executionEnvironmentSHA256: environment, layers: 0..<c.hiddenLayers, scope: scope,
            nativeBytes: workspaceNativeBytes, hostBytes: workspaceHostBytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let document = try encoder.encode(evidence)
        let load = Int(GPU.deviceInfo().maxRecommendedWorkingSetSize)
        func make(requestCapacity: Int) throws -> GLM5NextResidentResourceEnvelope {
            try GLM5NextResidentResourceEnvelope(descriptor: descriptor, inventory: inventory, rank: rank,
                loadCapacityBytes: load, requestCapacityBytes: requestCapacity,
                executionEnvironmentSHA256: environment, workspaceEvidence: document,
                authenticateWorkspace: { guard $0 == document else { throw ProbeError("GLM workspace evidence changed") } },
                requireExecutionEnvironment: {
                    guard try $0 == environment && environmentSHA256(buildSHA256: buildSHA256) == environment else {
                        throw ProbeError("GLM serving device or binary changed")
                    }
                }, hostAllocationBound: hostBound)
        }
        // First bound by the hardware, then held to this rank's whole-scope quotation.
        let request = try make(requestCapacity: load).budget(descriptor: descriptor).reservedBytes
        return try make(requestCapacity: request)
    }
}

/// GLM's answers to the planner's questions. Every layer boundary is a
/// structural cut; the registered row admits them all and the pair records
/// decide what is served. The NextN (MTP) layer and the vision tower belong
/// to no text stage. Request state is the verified driver's own quotation
/// (`GLM5NextRequestStateBudget`): DSA histories grow with the context, linear
/// attention layers hold fixed recurrent and convolution state. The
/// conservative workspace is charged once on every rank. Text requests may
/// also run tensor parallel on two ranks (`GLM5NextTensorShard`); images are
/// served by the pipeline only.
struct GLM5NextPlacementFamily: ClusterPlacementFamily {
    let specification: GLM5NextRegisteredSpecification
    let configuration: GLM5NextTextConfiguration
    let fullConfiguration: GLM5NextConfiguration
    let profile: QwenLayerStageGenerationProfile
    let imageCandidate: Bool
    let allocationExtraBytes: Int
    let transferAndInputAllowanceBytes: Int
    let tensorParallelPlan: ClusterTensorParallelFamilyPlan?

    static func handles(configuration: Data) -> Bool { GLM5NextRegisteredSpecification.handles(configuration: configuration) }

    init(configuration: Data, imageCandidate: Bool = false) throws {
        self.imageCandidate = imageCandidate
        specification = try GLM5NextRegisteredSpecification.specification(configuration: configuration)
        fullConfiguration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configuration)
        self.configuration = fullConfiguration.textConfig
        // The planner sizes the pair for the memory plan's request (the
        // standard 32,768 + 32,768 tokens), as every LOAD gate charges it; the
        // capability advertises the native limits, and a longer request is
        // charged at its own context when a rank reserves it.
        profile = try specification.memoryProfile(imageCandidate: imageCandidate)
        guard let allocation = Memory.allocationFootprintPolicy(), let extra = allocation.maximumExtraBytes else {
            throw ProbeError("GLM placement needs the allocator's buffer bounds")
        }
        allocationExtraBytes = extra
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: profile.maximumContextTokens,
            maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
            maximumChunkTokens: profile.maximumChunkTokens)
        let buffers = try GLM5NextRequestStateBudget.transferAndInputBytes(configuration: self.configuration,
            rank: 1, scope: scope, transport: GLM5NextResidentResourceEnvelope.transportTerms,
            nativeBound: { bytes, copies in
                guard let bound = allocation.upperBound(byteCount: bytes) else { throw ProbeError("GLM buffer bound overflow") }
                return try GLM5NextRequestStateBudget.product([bound, copies])
            }, hostBound: { bytes, copies in
                try GLM5NextRequestStateBudget.product([GLM5NextServingResources.hostBound(bytes), copies])
            })
        transferAndInputAllowanceBytes = try GLM5NextStageLoadResources.sum([
            buffers.boundary, buffers.logits, buffers.wireNative, buffers.input, buffers.tokenHost, buffers.wireHost])

        guard self.configuration.hiddenLayers == specification.layers, self.configuration.hcMult == 4,
              self.configuration.layerTypes.count == specification.layers else {
            throw ProbeError("GLM configuration geometry differs from the registered row")
        }
        tensorParallelPlan = imageCandidate ? nil : Self.tensorParallelPlan(specification: specification,
            configuration: self.configuration, modes: specification.supportedGenerationModes)
    }

    var runtimeModelID: String { specification.model.rawValue }
    var layerCount: Int { specification.layers }
    var admittedCuts: [Int] { specification.supportedCuts }
    var structuralCuts: [Int] { Array(1..<specification.layers) }
    /// The capability's modes (`GLM5NextResidentCapabilityMetadata`): the image profile is pipeline-only.
    var generationModes: [ClusterGenerationMode] { imageCandidate ? [.pipeline] : specification.supportedGenerationModes }
    var prefillSchedules: [ClusterPrefillSchedule] { specification.supportedPrefillSchedules }
    var reservesFullRequestScope: Bool { true }
    var maximumPromptTokens: Int { profile.maximumPromptTokens }
    var maximumOutputTokens: Int { profile.maximumOutputTokens }
    var maximumChunkTokens: Int { profile.maximumChunkTokens }
    /// The whole [hc_mult, hidden] stream matrix in bfloat16.
    var boundaryBytesPerToken: Int { specification.hidden * 4 * 2 }
    /// The rank's quotation sums its own state with the workspace, what LOAD
    /// holds beside the weights (`GLM5NextStageLoadResources`: the metadata
    /// ledgers, the host read allowance, the largest expert bank's construction
    /// copy) and the chunk buffers (`GLM5NextRequestStateBudget`: logits and
    /// the residual crossing the cut, two copies each). Charged as a state
    /// stand-in, the plan chose cuts the rank's load gate then refused.
    var allowanceEveryRankBytes: Int? {
        return GLM5NextServingResources.workspaceNativeBytes + GLM5NextServingResources.workspaceHostBytes
            + GLM5NextResidentResourceEnvelope.metadataAllowanceBytes
            + 2 * Self.largestTensorBytes + GLM5NextArtifactLoader.verificationHostBytes
            + GLM5NextArtifactLoader.payloadReadScratchAllowanceBytes + Self.largestExpertBankBytes + allocationExtraBytes
            + transferAndInputAllowanceBytes
            + mediaAllowanceBytes
    }

    private var mediaAllowanceBytes: Int {
        // Computed from the pinned full vision configuration, retained below.
        guard imageCandidate else { return 0 }
        return (try? GLM5NextImageBudget.bytes(configuration: fullConfiguration, rank: 0,
            chunk: maximumChunkTokens, native: { $0 + allocationExtraBytes }, host: GLM5NextServingResources.hostBound)).map { $0.native + $0.host } ?? Int.max / 4
    }

    /// Of the registered inventory (`specification.inventorySHA256`): the
    /// embedding, and one projection's routed experts of one layer.
    static let largestTensorBytes = 317_194_240
    static let largestExpertBankBytes = 1_207_959_552

    /// Native LOAD bounds every source allocation, including cache reuse;
    /// stored checkpoint bytes alone omit that allocator overhead.
    func loadedBytes(ofStoredTensor name: String, storedBytes: Int) -> Int {
        storedBytes + allocationExtraBytes
    }

    /// The fused-projection construction allowance: every non-expert array of
    /// a layer is bounded as a source alias plus its fused copy.
    func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int {
        if name.hasPrefix("model.visual.") { return imageCandidate ? 3 * (storedBytes + allocationExtraBytes) : 0 }
        return layer(ofStoredTensor: name) != nil && !name.contains(".mlp.experts.") ? 2 * (storedBytes + allocationExtraBytes) : 0
    }

    static let layerPrefix = "model.language_model.layers."

    func layer(ofStoredTensor name: String) -> Int? {
        guard name.hasPrefix(Self.layerPrefix), let first = name.dropFirst(Self.layerPrefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first), layer < specification.layers else { return nil }
        return layer
    }

    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        guard (1..<specification.layers).contains(cut) else { throw ProbeError("Not a cut of the GLM stage plan: \(cut)") }
        if let layer = layer(ofStoredTensor: name) { return layer < cut ? 0 : 1 }
        if name.hasPrefix("model.visual.") { return imageCandidate ? 0 : nil }
        if name.hasPrefix("model.language_model.embed_tokens.") { return 0 }
        if name.hasPrefix("model.language_model.norm.") || name.hasPrefix("lm_head.") { return 1 }
        return nil  // NextN layer and vision tower.
    }

    /// `GLM5NextTensorParallelResidentRuntime`'s plan, offered only where the
    /// runtime lists the mode and the geometry halves (`localConfiguration`).
    /// Each layer sums its attention and its feed-forward partials, the
    /// projections' bfloat16 outputs at the residual width
    /// (`GLM5NextTensorParallelResidentRuntime.partialsTransport`); each
    /// step sums the ranks' token and stop flags once. The DSA latent cache
    /// is replicated, so request state is held whole on every rank.
    ///
    /// Not in this plan yet: the runtime's speculative decode
    /// (`GLM5NextTensorParallelResidentRuntime.mtpDepth`). It loads the NextN
    /// layer whole on every rank (about 4.2 GB, which this layout leaves to
    /// no rank) and charges it, its history and the captured verification
    /// windows to its own load gate and request reserve; a greedy step then
    /// verifies up to `mtpDepth + 1` rows per round of sums. The planner
    /// still prices one token per step and no NextN bytes, so it can admit a
    /// pair the load gate then refuses, and it underestimates greedy decode.
    static func tensorParallelPlan(specification: GLM5NextRegisteredSpecification,
                                   configuration: GLM5NextTextConfiguration,
                                   modes: [ClusterGenerationMode]) -> ClusterTensorParallelFamilyPlan? {
        guard modes.contains(.tensorParallel),
              (try? GLM5NextTensorShard(rank: 0, size: 2).localConfiguration(configuration)) != nil else { return nil }
        return ClusterTensorParallelFamilyPlan(plan: GLM5NextTensorParallelResidentRuntime.planName, ranks: [2],
            reductionsPerLayer: 2, reductionsPerStep: 1,
            partialBytesPerToken: specification.hidden * 2, stateDividesByHeads: false)
    }

    /// The SDK's split rule for a text layer's tensor (`GLM5NextTensorShard.splitAxis`);
    /// the embedding, final norm and head are replicated. Nil for what no
    /// text stage loads (the NextN layer, the vision tower; the tensor-parallel
    /// runtime loads NextN beside the stage, whole, and charges it itself).
    func tensorParallelCut(ofStoredTensor name: String) -> ClusterTensorParallelTensorCut? {
        guard tensorParallelPlan != nil, (try? stage(ofStoredTensor: name, cut: 1)) ?? nil != nil else { return nil }
        guard layer(ofStoredTensor: name) != nil else { return .replicated }
        return GLM5NextTensorShard.splitAxis(name) == nil ? .replicated : .divided
    }

    /// Each token is routed to `num_experts_per_tok` of `n_routed_experts` per sparse layer.
    var expertRouting: ClusterExpertRouting? {
        ClusterExpertRouting(selected: configuration.numExpertsPerTok, experts: configuration.nRoutedExperts)
    }

    func isRoutedExpert(storedTensor name: String) -> Bool {
        layer(ofStoredTensor: name) != nil && name.contains(".mlp.experts.")
    }

    func isSpeculativeHead(storedTensor name: String) -> Bool {
        name.hasPrefix(Self.layerPrefix + "\(specification.layers).")
    }

    func layerKind(_ layer: Int) -> String {
        configuration.layerTypes[layer].rawValue + "_" + configuration.mlpLayerTypes[layer].rawValue
    }

    /// `GLM5NextRequestStateBudget`: a DSA layer keeps three float32 histories
    /// (latent KV, two index widths) plus validity over a capacity of twice
    /// the context; a linear attention layer six recurrent and convolution states.
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        let c = configuration
        if c.layerTypes[layer] == .deepseekSparseAttention {
            let width = c.kvLoraRank * 4 + c.indexHeadDim * 4 * 2 + 1
            return .init(fixedBytes: maximumChunkTokens * width + 16 * allocationExtraBytes,
                bytesPerToken: width * 3 * 2)
        }
        let state = try GLM5NextRequestStateBudget.linearTransactionBytes(configuration: c.linearAttention,
            chunk: profile.maximumChunkTokens, native: { bytes, copies in
                try GLM5NextRequestStateBudget.product([bytes + allocationExtraBytes, copies])
            })
        return .init(fixedBytes: state, bytesPerToken: 0)
    }

    func requireRegisteredInventory(_ tensors: [ClusterPlacementStoredTensor]) throws {
        guard ClusterPlacementInventory.fingerprint(tensors) == specification.inventorySHA256 else {
            throw ProbeError("The artifact's tensor headers are not the registered GLM inventory")
        }
    }
}
