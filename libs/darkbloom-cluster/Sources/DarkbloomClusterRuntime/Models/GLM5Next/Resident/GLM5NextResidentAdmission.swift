import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM
import MLXVLM

/// Explicit private qualification selection, not a catalog entry or a memory
/// calibration. The trusted manifest supplier owns the aggregate's authority;
/// the resident reader independently verifies the selected artifact's files.
public struct GLM5NextResidentDescriptor {
    public let modelID: String
    public let artifactIdentity: GLM5NextArtifactIdentity
    public let artifactAggregateSHA256: String
    public let cut: Int
    public let storage: GLM5NextWeightInventory.Storage
    public let executionPolicy: GLM5NextExecutionPolicy
    public let fingerprint: String
    let includesVision: Bool
    let configuration: GLM5NextConfiguration
    /// What the pair advertises and a reservation is held to.
    let profile: QwenLayerStageGenerationProfile
    /// The request every LOAD gate and the memory plan charge: the profile
    /// itself, or a smaller standard request when the profile is the model's
    /// native context (`GLM5NextRegisteredSpecification.memoryLimits`). A
    /// runtime that charges each request at its own context admits beyond it
    /// (tensor parallel); one that does not serves up to it (the pipeline).
    let memoryProfile: QwenLayerStageGenerationProfile

    /// A memory scope within the profile's limits.
    struct MemoryScope: Equatable {
        let promptTokens: Int, outputTokens: Int, contextTokens: Int
    }

    public init(modelID: String, artifactIdentity: GLM5NextArtifactIdentity,
                artifactAggregateSHA256: String, configurationBytes: Data, cut: Int,
                storage: GLM5NextWeightInventory.Storage, executionPolicy: GLM5NextExecutionPolicy,
                profileID: String, maximumPromptTokens: Int, maximumChunkTokens: Int,
                maximumOutputTokens: Int, maximumContextTokens: Int,
                generationMode: QwenResidentGenerationMode = .pipeline,
                prefixReuse: Bool = false, batchSize: Int = 1, includesVision: Bool = false) throws {
        try self.init(modelID: modelID, artifactIdentity: artifactIdentity, artifactAggregateSHA256: artifactAggregateSHA256,
            configurationBytes: configurationBytes, cut: cut, storage: storage, executionPolicy: executionPolicy,
            profileID: profileID, maximumPromptTokens: maximumPromptTokens, maximumChunkTokens: maximumChunkTokens,
            maximumOutputTokens: maximumOutputTokens, maximumContextTokens: maximumContextTokens,
            generationMode: generationMode, prefixReuse: prefixReuse, batchSize: batchSize,
            includesVision: includesVision, memoryScope: nil)
    }

    init(modelID: String, artifactIdentity: GLM5NextArtifactIdentity,
         artifactAggregateSHA256: String, configurationBytes: Data, cut: Int,
         storage: GLM5NextWeightInventory.Storage, executionPolicy: GLM5NextExecutionPolicy,
         profileID: String, maximumPromptTokens: Int, maximumChunkTokens: Int,
         maximumOutputTokens: Int, maximumContextTokens: Int,
         generationMode: QwenResidentGenerationMode = .pipeline,
         prefixReuse: Bool = false, batchSize: Int = 1, includesVision: Bool = false,
         memoryScope: MemoryScope?) throws {
        guard generationMode == .pipeline, !prefixReuse, batchSize == 1 else {
            throw ProbeError("GLM resident currently requires regular pipeline, cold prefix and batch size one")
        }
        let limits = GLM5NextArtifactLimits()
        guard !modelID.isEmpty, modelID.utf8.count <= 128,
              modelID.utf8.allSatisfy({ (33...126).contains($0) }),
              !artifactIdentity.repository.isEmpty, artifactIdentity.repository.utf8.count <= 256,
              artifactIdentity.revision.utf8.count == 40,
              artifactIdentity.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              qwenStageWireIsSHA256(artifactAggregateSHA256),
              !configurationBytes.isEmpty, configurationBytes.count <= limits.maximumConfigBytes,
              artifactIdentity.files.count >= 3, artifactIdentity.files.count <= limits.maximumShards + 2,
              artifactIdentity.files["model.safetensors.index.json"] != nil,
              let config = artifactIdentity.files["config.json"],
              config.bytes == configurationBytes.count, config.sha256 == sha256(configurationBytes),
              artifactIdentity.files.allSatisfy({ name, file in
                  !name.isEmpty && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\")
                      && name != "." && name != ".." && !name.utf8.contains(0)
                      && file.bytes > 0 && qwenStageWireIsSHA256(file.sha256)
              }) else { throw ProbeError("GLM resident requires a bounded explicit pinned artifact descriptor") }
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configurationBytes)
        if modelID == ClusterGLMImageCandidate.runtimeModelID {
            guard includesVision == (profileID == ClusterGLMImageCandidate.profileID) else {
                throw ProbeError("GLM image LOAD and profile disagree")
            }
            if includesVision {
                try ClusterGLMImageCandidate.validateSource(profileID: profileID, modelID: modelID,
                    artifact: artifactAggregateSHA256, configuration: config.sha256)
            }
        }
        self.includesVision = includesVision
        let c = configuration.textConfig
        guard cut > 0, cut < c.hiddenLayers, c.hcMult == 4,
              maximumContextTokens <= c.maxPositionEmbeddings else {
            throw ProbeError("GLM resident cut, four-stream geometry or context differs from configuration")
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: profileID,
            vocabularySize: c.vocabularySize, hiddenSize: c.hiddenSize, activationDType: c.dtype,
            maximumPromptTokens: maximumPromptTokens, maximumChunkTokens: maximumChunkTokens,
            maximumOutputTokens: maximumOutputTokens, maximumContextTokens: maximumContextTokens,
            residualStreams: 4)
        let memoryProfile: QwenLayerStageGenerationProfile
        if let memoryScope, memoryScope.contextTokens < maximumContextTokens {
            guard (1...maximumPromptTokens).contains(memoryScope.promptTokens),
                  (1...maximumOutputTokens).contains(memoryScope.outputTokens),
                  (memoryScope.promptTokens...maximumContextTokens).contains(memoryScope.contextTokens) else {
                throw ProbeError("GLM memory scope exceeds the resident profile")
            }
            memoryProfile = try QwenLayerStageGenerationProfile(identifier: profileID,
                vocabularySize: c.vocabularySize, hiddenSize: c.hiddenSize, activationDType: c.dtype,
                maximumPromptTokens: memoryScope.promptTokens,
                maximumChunkTokens: min(maximumChunkTokens, memoryScope.promptTokens),
                maximumOutputTokens: memoryScope.outputTokens, maximumContextTokens: memoryScope.contextTokens,
                residualStreams: 4)
        } else {
            memoryProfile = profile
        }
        // Exercise the actual driver's compact-byte bound at the advertised cap.
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: Array(repeating: 0, count: maximumChunkTokens),
            chunkSize: maximumChunkTokens, outputCount: 1, stopTokenIDs: [])
        let dtype: DType
        switch c.dtype {
        case "bfloat16": dtype = .bfloat16
        case "float16": dtype = .float16
        case "float32": dtype = .float32
        default: throw ProbeError("Unsupported GLM boundary dtype")
        }
        _ = try qwenGenerationBoundaryGeometry(request: request, dtype: dtype, authenticatedChunking: true)
        let storageName: String
        switch storage {
        case .float32: storageName = "float32"
        case .vontraQ4: storageName = "vontraQ4"
        case .affineMixed: storageName = "affineMixed"
        case .nvfp4Hybrid: storageName = "nvfp4Hybrid"
        }
        var fields = ["glm5-next-resident-descriptor-v1", modelID, artifactIdentity.repository,
            artifactIdentity.revision, artifactAggregateSHA256, config.sha256, String(cut), storageName,
            try GLM5NextStageContract.policySHA256(executionPolicy), profile.fingerprint,
            "pipeline", "prefix=false", "batch=1", "mtp=false"]
        if includesVision { fields.append("still-images=v1") }
        // Only a memory scope below the profile changes the bytes it always had.
        if memoryProfile.fingerprint != profile.fingerprint { fields.append("memory=" + memoryProfile.fingerprint) }
        for name in artifactIdentity.files.keys.sorted() {
            let file = artifactIdentity.files[name]!
            fields += [name, String(file.bytes), file.sha256]
        }
        fingerprint = sha256(try canonicalJSONData(fields))
        self.modelID = modelID; self.artifactIdentity = artifactIdentity
        self.artifactAggregateSHA256 = artifactAggregateSHA256; self.cut = cut
        self.storage = storage; self.executionPolicy = executionPolicy
        self.configuration = configuration; self.profile = profile; self.memoryProfile = memoryProfile
    }

    var wireProfile: ClusterWorkerProfile {
        let p = profile
        return .init(id: p.identifier, vocabularySize: p.vocabularySize, maximumPromptTokens: p.maximumPromptTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumChunkTokens: p.maximumChunkTokens,
            maximumContextTokens: p.maximumContextTokens)
    }

    /// Bounded config/index/header inspection only: no GPU queries, tensor
    /// reads or full payload hashing. The later resident load independently
    /// verifies every expected file before constructing its selected stage.
    public func inspectInventory(directory: URL) throws -> GLM5NextWeightInventory {
        let inventory = try GLM5NextResidentStage.inspect(directory: directory,
            identity: artifactIdentity, storage: storage)
        guard inventory.configuration == configuration, inventory.storage == storage else {
            throw ProbeError("GLM inspected inventory differs from the explicit descriptor")
        }
        return inventory
    }
}

/// Authenticated workspace evidence plus the exact selected request envelope.
/// The owner authenticates the bounded evidence document and checks its current
/// binary/backend/device environment; an unverified digest alone grants nothing.
public struct GLM5NextResidentResourceEnvelope {
    /// Header admission, SDK verification, and bounded selection/read ledgers
    /// coexist during LOAD. Placement and workers must quote this same allowance.
    public static var metadataAllowanceBytes: Int {
        GLM5NextArtifactLimits().maximumMetadataBytes * 3
    }

    public let loadCapacityBytes: Int
    public let requestCapacityBytes: Int
    public let executionEnvironmentSHA256: String
    let calibrationOnly: Bool
    let descriptorFingerprint: String
    let inventory: GLM5NextWeightInventory
    let rank: Int
    let workspace: GLM5NextRequestStateBudget.WorkspaceEvidence
    let scope: GLM5NextRequestStateBudget.Scope
    let hostAllocationBound: (Int) throws -> Int
    let requireExecutionEnvironment: (String) throws -> Void

    /// Workspace JSON is GLM5NextRequestStateBudget.WorkspaceEvidence's
    /// qualification document. Authentication must cover the exact supplied bytes.
    /// Host rounding is supplied by the evidence owner, never inferred from MLX.
    public init(descriptor: GLM5NextResidentDescriptor, inventory: GLM5NextWeightInventory, rank: Int,
                loadCapacityBytes: Int, requestCapacityBytes: Int, executionEnvironmentSHA256: String,
                workspaceEvidence: Data, authenticateWorkspace: (Data) throws -> Void,
                requireExecutionEnvironment: @escaping (String) throws -> Void,
                hostAllocationBound: @escaping (Int) throws -> Int) throws {
        try self.init(descriptor: descriptor, inventory: inventory, rank: rank,
            loadCapacityBytes: loadCapacityBytes, requestCapacityBytes: requestCapacityBytes,
            executionEnvironmentSHA256: executionEnvironmentSHA256, workspaceEvidence: workspaceEvidence,
            authenticateWorkspace: authenticateWorkspace, requireExecutionEnvironment: requireExecutionEnvironment,
            hostAllocationBound: hostAllocationBound, calibrationOnly: false)
    }

    init(descriptor: GLM5NextResidentDescriptor, inventory: GLM5NextWeightInventory, rank: Int,
                loadCapacityBytes: Int, requestCapacityBytes: Int, executionEnvironmentSHA256: String,
                workspaceEvidence: Data, authenticateWorkspace: (Data) throws -> Void,
                requireExecutionEnvironment: @escaping (String) throws -> Void,
                hostAllocationBound: @escaping (Int) throws -> Int, calibrationOnly: Bool) throws {
        guard (0...1).contains(rank), loadCapacityBytes > 0, requestCapacityBytes > 0,
              requestCapacityBytes <= loadCapacityBytes,
              inventory.configuration == descriptor.configuration, inventory.storage == descriptor.storage,
              !workspaceEvidence.isEmpty, workspaceEvidence.count <= 65_536 else {
            throw ProbeError("GLM resource evidence differs from the descriptor or exceeds its bounds")
        }
        try authenticateWorkspace(workspaceEvidence)
        try requireExecutionEnvironment(executionEnvironmentSHA256)
        let workspace = try JSONDecoder().decode(GLM5NextRequestStateBudget.WorkspaceEvidence.self, from: workspaceEvidence)
        guard (workspace.kind == .experimentalAllowance) == calibrationOnly else {
            throw ProbeError("Experimental calibration allowance is not serving workspace evidence")
        }
        self.calibrationOnly = calibrationOnly
        let p = descriptor.memoryProfile
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: p.maximumContextTokens,
            maximumPromptTokens: p.maximumPromptTokens, maximumOutputTokens: p.maximumOutputTokens,
            maximumChunkTokens: p.maximumChunkTokens, includesVision: descriptor.includesVision)
        let layers = rank == 0 ? 0..<descriptor.cut : descriptor.cut..<inventory.configuration.textConfig.hiddenLayers
        // CPU-only structural/evidence validation. Live allocator bounds are
        // applied again under the process lease before the load agreement.
        let minimum = try GLM5NextRequestStateBudget.estimate(inventory: inventory, layers: layers,
            rank: rank, scope: scope, executionPolicy: descriptor.executionPolicy,
            executionEnvironmentSHA256: executionEnvironmentSHA256, workspace: workspace,
            transport: Self.transportTerms, maximumBufferBytes: Int.max,
            allocationBound: { $0 }, hostAllocationBound: hostAllocationBound)
        guard minimum.reservedBytes <= requestCapacityBytes else {
            throw ProbeError("GLM request envelope exceeds its owner capacity")
        }
        self.loadCapacityBytes = loadCapacityBytes; self.requestCapacityBytes = requestCapacityBytes
        self.executionEnvironmentSHA256 = executionEnvironmentSHA256
        descriptorFingerprint = descriptor.fingerprint; self.inventory = inventory; self.rank = rank
        self.workspace = workspace; self.scope = scope; self.hostAllocationBound = hostAllocationBound
        self.requireExecutionEnvironment = requireExecutionEnvironment
    }

    // Exact defaults used by Collective.establishDataPlane and the regular
    // generation codec, not caller-selected smaller record limits.
    static var transportTerms: GLM5NextRequestStateBudget.TransportTerms {
        .init(maximumRecordPlaintextBytes: CollectiveAuthenticatedRecords.chunkBytes,
            maximumTransportFrameBytes: CollectiveAuthenticatedRecords.chunkBytes + ClusterRecordTransferAccounting.framingBytes,
            maximumControlBytes: max(4096, QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes))
    }

    /// The same bound quote used by placement, without querying a native device.
    func quote(descriptor: GLM5NextResidentDescriptor, maximumBufferBytes: Int,
               allocationBound: (Int) throws -> Int) throws
        -> (load: GLM5NextStageLoadResources, request: GLM5NextRequestStateBudget, peak: GLM5NextResidentPeak) {
        try requireExecutionEnvironment(executionEnvironmentSHA256)
        guard descriptor.fingerprint == descriptorFingerprint else {
            throw ProbeError("GLM quotation descriptor differs from resource envelope")
        }
        let layers = rank == 0 ? 0..<descriptor.cut : descriptor.cut..<inventory.configuration.textConfig.hiddenLayers
        let request = try GLM5NextRequestStateBudget.estimate(inventory: inventory, layers: layers, rank: rank,
            scope: scope, executionPolicy: descriptor.executionPolicy,
            executionEnvironmentSHA256: executionEnvironmentSHA256, workspace: workspace,
            transport: Self.transportTerms, maximumBufferBytes: maximumBufferBytes,
            allocationBound: allocationBound, hostAllocationBound: hostAllocationBound)
        let load = try GLM5NextStageLoadResources(inventory: inventory, stageIndex: rank,
            cut: descriptor.cut, includeMTP: false, executionPolicy: descriptor.executionPolicy,
            metadataAllowanceBytes: Self.metadataAllowanceBytes, maximumBufferBytes: maximumBufferBytes,
            allocationBound: allocationBound, includeVision: descriptor.includesVision)
        let peak = try GLM5NextResidentPeak(load: load.summary, request: request)
        guard request.reservedBytes <= requestCapacityBytes, peak.reservedBytes <= loadCapacityBytes else {
            throw ProbeError("GLM quotation exceeds the bound load/request capacities")
        }
        return (load, request, peak)
    }

    func budget(descriptor: GLM5NextResidentDescriptor) throws -> GLM5NextRequestStateBudget {
        try requireExecutionEnvironment(executionEnvironmentSHA256)
        let layers = rank == 0 ? 0..<descriptor.cut : descriptor.cut..<inventory.configuration.textConfig.hiddenLayers
        let budget = try GLM5NextRequestStateBudget.estimate(inventory: inventory, layers: layers, rank: rank,
            scope: scope, executionPolicy: descriptor.executionPolicy,
            executionEnvironmentSHA256: executionEnvironmentSHA256, workspace: workspace,
            transport: Self.transportTerms, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
            allocationBound: QwenResidentResourceEnvironment.allocationBound, hostAllocationBound: hostAllocationBound)
        guard descriptor.fingerprint == descriptorFingerprint, budget.reservedBytes <= requestCapacityBytes else {
            throw ProbeError("GLM live request quotation exceeds the bound resource envelope")
        }
        return budget
    }
}

struct GLM5NextResidentAdmission {
    let configuration: QwenResidentLoadConfiguration
    let descriptor: GLM5NextResidentDescriptor
    let resources: GLM5NextResidentResourceEnvelope

    init(configuration: QwenResidentLoadConfiguration, descriptor: GLM5NextResidentDescriptor,
         resources: GLM5NextResidentResourceEnvelope, now: UInt64) throws {
        let identity = configuration.identity
        guard (0...1).contains(configuration.rank), configuration.stageCut == descriptor.cut,
              configuration.modelDirectory.isFileURL, configuration.prefillSchedule == .serial,
              configuration.admitsLoadDeadline(now: now),
              resources.rank == configuration.rank, resources.descriptorFingerprint == descriptor.fingerprint,
              identity.modelID == descriptor.modelID,
              identity.configurationSHA256 == descriptor.artifactIdentity.files["config.json"]?.sha256,
              identity.artifactSHA256 == descriptor.artifactAggregateSHA256,
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128
                  && $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }) else {
            throw ProbeError("GLM resident launch differs from its explicit descriptor, peers or bounded lifetime")
        }
        if descriptor.modelID == ClusterGLMImageCandidate.runtimeModelID {
            let vision = try ClusterGLMImageCandidate.includesVision(runtimeProfile: configuration.runtimeProfile,
                modelID: identity.modelID, artifact: identity.artifactSHA256, configuration: identity.configurationSHA256)
            guard vision == descriptor.includesVision else { throw ProbeError("GLM worker LOAD profile differs from descriptor") }
        }
        self.configuration = configuration; self.descriptor = descriptor; self.resources = resources
    }

    func loadAgreement(jacclFingerprint: String, transport: ClusterTransport) throws -> String {
        guard qwenStageWireIsSHA256(jacclFingerprint) else { throw ProbeError("Missing GLM topology binding") }
        let identity = configuration.identity
        return sha256(try canonicalJSONData(["glm5-next-resident-load-v1", descriptor.fingerprint,
            identity.membershipEpoch.uuidString.lowercased(), jacclFingerprint, transport.rawValue,
            configuration.allocatorPolicy.rawValue]
            + ClusterDataPlaneAgreement.loadAgreementFields + identity.peers.flatMap { [$0.id, $0.buildSHA256] }))
    }

    func request(_ value: ClusterWorkerReservation, id: UUID, now: UInt64) throws -> QwenLayerStageGenerationRequest {
        guard value.mimoImages == nil, value.stillImages == nil || descriptor.includesVision,
              value.profileID == descriptor.profile.identifier, value.route == nil,
              value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(),
              value.capacityLimitBytes > 0,
              configuration.admitsRequestDeadline(value.deadlineUptimeNanoseconds, now: now) else {
            throw ProbeError("GLM reservation differs from its profile, capacity, route or deadline")
        }
        // The pipeline's LOAD charged its memory scope, never more: a longer
        // request is not charged here, so it is not served here (its READY
        // says so too: `servingContextTokens`).
        let memory = descriptor.memoryProfile
        guard value.promptTokenIDs.count <= memory.maximumPromptTokens, value.outputCount <= memory.maximumOutputTokens,
              value.promptTokenIDs.count + value.outputCount <= memory.maximumContextTokens else {
            throw ProbeError("GLM pipeline request exceeds the context its LOAD charged")
        }
        if let media = value.stillImages {
            let c = descriptor.configuration
            guard media.configurationSHA256 == configuration.identity.configurationSHA256 else {
                throw ProbeError("GLM image source differs from loaded config")
            }
            try media.validate(prompt: value.promptTokenIDs, imageToken: c.imageTokenId,
                startToken: c.imageStartTokenId, endToken: c.imageEndTokenId, videoToken: c.videoTokenId)
            for image in media.images {
                let i = try MLXVLM.GLM5NextClusterImagePlan.inspectPNG(image.png, configuration: c)
                guard i.width == image.width, i.height == image.height,
                      try i.resize.grid.featureCount() == image.tokenCount else {
                    throw ProbeError("GLM actual PNG geometry differs from admitted span")
                }
            }
        }
        return try .init(profile: descriptor.profile, requestID: id, promptTokenIDs: value.promptTokenIDs,
            chunkSize: value.chunkSize, outputCount: value.outputCount, stopTokenIDs: Set(value.stopTokenIDs),
            sampling: value.sampling, stillImages: value.stillImages)
    }

    var wireProfile: ClusterWorkerProfile { descriptor.wireProfile }
}

/// One accounting authority for placement and the live resident LOAD gate.
struct GLM5NextResidentPeak {
    let nativeBytes: Int
    let hostBytes: Int
    let reservedBytes: Int

    init(load: GLM5NextStageLoadResources.Summary, request: GLM5NextRequestStateBudget) throws {
        guard load.metadataAllowanceBytes == GLM5NextResidentResourceEnvelope.metadataAllowanceBytes else {
            throw ProbeError("GLM LOAD metadata allowance differs from resident policy")
        }
        nativeBytes = try GLM5NextStageLoadResources.sum([
            load.sourceAllocationBoundBytes, load.nativeConstructionAllowanceBytes, request.nativeBytes])
        hostBytes = try GLM5NextStageLoadResources.sum([
            load.hostReadAllowanceBytes, load.metadataAllowanceBytes, request.hostBytes])
        reservedBytes = try GLM5NextStageLoadResources.sum([nativeBytes, hostBytes])
    }
}
