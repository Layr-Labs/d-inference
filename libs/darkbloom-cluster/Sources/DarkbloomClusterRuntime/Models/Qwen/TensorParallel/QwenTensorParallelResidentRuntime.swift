import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

/// The worker's resident owner for `tensor_parallel_v1` on the dense Qwen
/// rows (9B, 27B) and equal shares of Qwen3.5 35B A3B: both ranks hold a
/// share of every layer (heads, key/value heads, MLP channels and vocabulary
/// rows, `QwenTensorParallelPlan`), run
/// every prefill chunk and decode step together, and sum each row-parallel
/// projection's partials with the sealed all-sum inside the lazy graph: every
/// partial crosses the cable as an AES-256-GCM frame under direction keys the
/// pinned data-plane exchange (S16) derived for this session and load
/// agreement, rekeyed by count and bytes; a frame that does not authenticate
/// ends the evaluation on both ranks.
///
/// Keyed Qwen27 uses request-owned CBv2 execution at every capacity; the
/// singleton wire adapts to the shared batch driver. Other rows retain
/// the same contract as `QwenResidentRuntime` for the worker's executor:
/// synchronous, one request at a time, cancel from the control thread only,
/// an enclosing process deadline required (a blocked collective cannot be
/// interrupted cooperatively).
///
/// Generation: a greedy request's token is the distributed argmax (one small
/// sealed reduction per step, both ranks learn the token); a sampled
/// request's whole-vocabulary logits are gathered to every rank (exact: each
/// rank adds zeros outside its rows) and rank 0 draws with the product's
/// sampler (`QwenStageTokenSampler`), then makes the token known to rank 1 in
/// one small sealed reduction. Each step's reduction also carries every
/// rank's stop flag, so a client stop, a cancellation or a deadline on either
/// rank ends both after the same step with no extra exchange. Stop tokens and
/// the output count are known to both ranks and end both at once.
///
/// Prompt prefixes: each rank keeps its own heads' state at chunk boundaries
/// (`QwenTensorParallelPrefixCache`); a request restores the longest boundary
/// BOTH ranks hold (one sealed vote), or neither restores.
public final class QwenTensorParallelResidentRuntime {
    let admission: QwenResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let group: QwenTensorParallelGroup
    let codec: QwenTensorParallelSealCodec?
    let lifecycle = QwenLayerStageResidentLifecycle()
    let loadAgreement: String
    let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    var model: QwenTensorParallelModel?
    var vision: QwenStageVision?
    let visionInventory: QwenStageVisionInventory?
    let profile: QwenRegisteredDenseModelProfile
    let baseReady: ClusterWorkerReady
    private var reservation: Reserved?
    private var processLeaseOwned = true
    public let shares: [Int]
    public let receipt: String
    /// What this rank measured of the link at load (`QwenTensorParallelLinkProbe`).
    public let linkProbe: ClusterWorkerLinkProbe?
    let prefix: QwenTensorParallelPrefixCache
    public let batchLanes: Int
    var batchHost: CBv2StageKVHost?
    let batchBudget: QwenTensorParallelBatchBudget?
    let batchMTPBudget: QwenTensorParallelBatchMTPBudget?
    let batchPrefix: QwenTensorParallelBatchPrefixCache?
    let batchBook = ClusterBatchLaneBook<QwenTensorParallelOwnedBatchReservation>()
    var batchServing = false
    var batchOrdinal: UInt64 = 0
    let batchAllocationBaseline: Int
    let batchResourceWatch = QwenDenseStageLoadWatch("Tensor-parallel batch")
    let mtpTerms: QwenMTPTerms?
    let mtpPrefix: QwenTensorParallelMTPPrefixCache?
    var mtpHead: QwenTensorParallelMTPHead?
    var mtpHost: CBv2StageKVHost?
    var failedMTPDecoder: QwenTensorParallelMTPDecoder?
    var failedMTPTarget: QwenTensorParallelMTPSession?
    var mtpCommittedLogprobs: ClusterWorkerTokenLogprobs?
    // Failed native/resource cleanup must remain reachable until shutdown's
    // checked drain or the enclosing worker's process fence.
    var failedBatchDriver: QwenTensorParallelBatchDriver<QwenTensorParallelNativeBatchExecutor<QwenTensorParallelOwnedBatchReservation>>?

    struct Reserved {
        let request: QwenLayerStageGenerationRequest
        let allowance: QwenResidentRequestAllowance
        let extraNativeBytes: Int
        let deadline: UInt64
        let media: QwenMediaRequestWork?
    }

    /// Bound into the load agreement besides the mode's terms: the plan and
    /// each rank's share weight (ranks with other shares would sum partials of
    /// overlapping or missing heads without any mismatched shape).
    static func loadAgreementFields(shares: [Int]) -> [String] {
        ["qwen-tensor-parallel-shares-v1", shares.map(String.init).joined(separator: ":")]
    }

    public static func load(_ configuration: QwenResidentLoadConfiguration, shares: [Int] = [1, 1],
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential? = nil,
                            prefixSSDKey: Data? = nil,
                            speculativeTerms: QwenMTPTerms? = nil,
                            tensorAssistantPolicy: ClusterQwenTensorAssistantPolicy? = nil) throws -> QwenTensorParallelResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        guard shares.count == 2, shares.allSatisfy({ (1...64).contains($0) }) else {
            throw ProbeError("Tensor-parallel shares are two weights of 1...64")
        }
        let directory = configuration.modelDirectory
        let any = try LayerStageResidentFamily.admission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        guard let admission = any as? QwenResidentAdmission,
              admission.supportedGenerationModes.contains(.tensorParallel) else {
            throw ProbeError("Generation mode tensor_parallel_v1 is not in the resident row of \(any.runtimeModelID)")
        }
        try QwenTensorParallelVerifiedLoad.requireSupportedProduct(admission.definition, shares: shares)
        let batch = try QwenTensorParallelBatchSettings.resolve(model: admission.specification.model,
            keyed: credential != nil, environment: environment)
        try QwenTensorParallelMTPPolicy.require(model: admission.specification.model, lanes: batch.lanes,
            keyed: credential != nil, paged: Self.pagedKV(environment), terms: speculativeTerms, environment: environment)
        // The assistant's request-owned history needs the CBv2 paged backend;
        // refuse before LOAD rather than at the first request.
        guard speculativeTerms == nil || !(batch.requestOwned || batch.lanes > 1) || batch.backend == .paged else {
            throw ProbeError("The Qwen27 TP assistant requires the paged batch KV backend")
        }
        if let tensorAssistantPolicy {
            try tensorAssistantPolicy.validate()
            guard admission.specification.model.rawValue == ClusterQwenTensorAssistantPolicy.runtimeModelID,
                  speculativeTerms?.depth == tensorAssistantPolicy.depth, credential != nil,
                  configuration.prefillSchedule == .serial else {
                throw ProbeError("Saved tensor assistant policy differs from the native load")
            }
        }
        let maximumSpeculativeWidth = try tensorAssistantPolicy?.maximumSpeculativeWidth(capacity: batch.lanes) ?? 1
        let mediaEnabled = admission.specification.model == .qwen38TwentySevenB && credential != nil
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loadedModel: QwenTensorParallelModel?
        var loadedVision: QwenStageVision?
        var loadedVisionInventory: QwenStageVisionInventory?
        weak var retired: QwenTensorParallelModel?
        var batchHost: CBv2StageKVHost?
        var batchBudget: QwenTensorParallelBatchBudget?
        var batchMTPBudget: QwenTensorParallelBatchMTPBudget?
        var loadedMTPHead: QwenTensorParallelMTPHead?
        var mtpHost: CBv2StageKVHost?
        var mtpQuote: QwenTensorParallelMTPBudget?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            try admission.jaccl.requireUnchanged(environment: environment, read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            if configuration.allocatorPolicy == .disableFreedBufferCache {
                try MLX.withError { nativeError in
                    func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                    do {
                        try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                    } catch { try nativeError.check(); throw error }
                }
            }
            // Header-only assistant inventory precedes the peer agreement and
            // every payload read. It is absent on the unchanged default path.
            let mtpSource = speculativeTerms == nil ? nil : try prepareQwenResidentSource(admission, check: { try control.check() })
            let mtpInventory = try mtpSource.map { try QwenTensorParallelMTPInventory(source: $0,
                configuration: admission.configBytes, specification: admission.specification,
                allocationBound: QwenResidentResourceEnvironment.allocationBound) }
            if let tensorAssistantPolicy {
                guard mtpInventory?.fingerprint == tensorAssistantPolicy.inventorySHA256 else {
                    throw ProbeError("Saved tensor assistant inventory differs before payload reads")
                }
            }
            let futureAssistant = mtpInventory?.loadBytes ?? 0
            // RDMA only: the sealed all-sum runs on the JACCL group itself.
            let collective = try Collective(transport: .jaccl)
            try admission.jaccl.requireUnchanged(environment: environment, read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let mode = ClusterGenerationMode.tensorParallel
            // The prefix cache votes in a reduction of its own: both ranks must have it on, or both off.
            let prefixEnabled = QwenStagePrefixCache.fromEnvironment(environment).enabled
            // Paged attention KV (`QwenTensorParallelPagedKV.swift`), bound into the agreement.
            let pagedKV = try Self.pagedKV(environment)
            let fields = try QwenTensorParallelMTPPolicy.fields(terms: speculativeTerms, inventory: mtpInventory)
                + (tensorAssistantPolicy.map { [$0.schema, String($0.depth), $0.inventorySHA256] + $0.verificationArguments }
                    ?? [])
                + batch.agreementFields + mode.loadAgreementFields + loadAgreementFields(shares: shares)
                + QwenTensorParallelPlan.arithmeticAgreementFields(routedExperts: admission.specification.routedExperts != nil)
                + ["qwen-tensor-parallel-prefix-v1", prefixEnabled ? "on" : "off"] + pagedKVAgreementFields(pagedKV)
                + (mediaEnabled ? [ClusterQwenMedia.contract, Qwen3VLMediaProcessor.policyID] : [])
                + (credential == nil ? [] : ClusterDataPlaneAgreement.loadAgreementFields)
            let loadAgreement = sha256(try canonicalJSONData([try admission.loadAgreementFingerprint()] + fields))
            if let credential {
                try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                    loadAgreement: loadAgreement, tamper: nil, tensorParallelSeal: true, check: { try control.check() })
            }
            let group = try QwenTensorParallelGroup(collective: collective)
            var codec: QwenTensorParallelSealCodec?
            if credential != nil {
                let installed = try QwenTensorParallelSealCodec.product(collective: collective, scope: Data(loadAgreement.utf8))
                try installed.install()
                group.sealed = installed; codec = installed
            }
            var probe: ClusterWorkerLinkProbe?
            var shardReceipt: QwenTensorParallelShardReceipt?
            var source: QwenRegisteredDenseModelProfile?
            let capacity = try MLX.withError { nativeError -> Int in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                    disagreementMessage: "Tensor-parallel load membership/source/plan/shares differ",
                    scope: .session(.loadAgreement, "resident-load-intent"), check: checked)
                // The link, measured as this mode uses it, before any weight is read.
                probe = try QwenTensorParallelLinkProbe.measure(collective: collective, group: group,
                    hiddenSize: admission.profile.hiddenSize, chunkTokens: admission.profile.maximumChunkTokens, check: checked)
                if let probe { log(QwenTensorParallelLinkProbe.line(probe, rank: collective.rank)) }
                let value = try autoreleasepool {
                    try QwenTensorParallelVerifiedLoad.load(admission, rank: collective.rank, shares: shares,
                        reduction: group, includeVision: mediaEnabled,
                        requestAllowance: batch.requestOwned || batch.lanes > 1 || speculativeTerms != nil ? { profile, plan in
                            if let terms = speculativeTerms, batch.requestOwned || batch.lanes > 1 {
                                let quote = try QwenTensorParallelBatchMTPBudget.derive(geometry: profile.geometry, plan: plan,
                                    tensors: profile.canonicalTensors, maximumTokens: admission.profile.maximumContextTokens,
                                    promptTokens: admission.profile.maximumPromptTokens,
                                    chunkSize: admission.profile.maximumChunkTokens, lanes: batch.lanes, depth: terms.depth,
                                    maximumSpeculativeWidth: maximumSpeculativeWidth, rank: collective.rank,
                                    allocationBound: QwenResidentResourceEnvironment.allocationBound)
                                batchMTPBudget = quote; batchBudget = quote.target
                                return quote.allowance.reservedBytes
                            }
                            if let terms = speculativeTerms {
                                let quote = try QwenTensorParallelMTPBudget.derive(geometry: profile.geometry, plan: plan,
                                    tensors: profile.canonicalTensors, maximumTokens: admission.profile.maximumContextTokens,
                                    promptTokens: admission.profile.maximumPromptTokens,
                                    chunkSize: admission.profile.maximumChunkTokens, depth: terms.depth,
                                    rank: collective.rank, allocationBound: QwenResidentResourceEnvironment.allocationBound)
                                mtpQuote = quote
                                return quote.allowance.reservedBytes
                            }
                            let quote = try QwenTensorParallelBatchBudget.derive(geometry: profile.geometry, plan: plan,
                                tensors: profile.canonicalTensors, maximumTokens: admission.profile.maximumContextTokens,
                                chunkSize: admission.profile.maximumChunkTokens, lanes: batch.lanes,
                                paged: batch.backend == .paged, rank: collective.rank,
                                allocationBound: QwenResidentResourceEnvironment.allocationBound)
                            batchBudget = quote
                            return quote.allowance.reservedBytes
                        } : nil, additionalResidentBytes: futureAssistant, check: checked)
                }
                retired = value.model; loadedModel = value.model; shardReceipt = value.receipt; source = value.profile
                loadedVision = value.vision; loadedVisionInventory = value.visionInventory
                if let mtpSource, let mtpInventory {
                    guard let requestAllowance = batchMTPBudget?.allowance ?? mtpQuote?.allowance else {
                        throw ProbeError("Qwen TP assistant LOAD has no complete native request quote")
                    }
                    loadedMTPHead = try QwenTensorParallelMTPHead.load(source: mtpSource,
                        configuration: admission.configBytes, inventory: mtpInventory,
                        target: value.model, reduction: group,
                        remainingResidentAllowanceBytes: requestAllowance.reservedBytes, check: checked)
                    if batch.lanes == 1 && !batch.requestOwned {
                        mtpHost = try CBv2StageKVHost(model: value.model.model, kind: .paged, lanes: 1,
                            maximumTokensPerRequest: admission.profile.maximumContextTokens,
                            maximumChunkTokens: max(admission.profile.maximumChunkTokens, speculativeTerms!.depth + 1))
                    }
                }
                // Every request's attention keys and values live in this rank's page pool.
                if pagedKV && batch.lanes == 1 && !batch.requestOwned { value.model.attentionPagePool = try value.model.makeAttentionPagePool(pageSize: Self.attentionPageTokens) }
                if batch.requestOwned || batch.lanes > 1 {
                    batchHost = try CBv2StageKVHost(model: value.model.model, kind: batch.backend, lanes: batch.lanes,
                        maximumTokensPerRequest: admission.profile.maximumContextTokens,
                        maximumChunkTokens: max(admission.profile.maximumChunkTokens, (speculativeTerms?.depth ?? 0) + 1))
                    batchHost?.report("qwen_tensor_parallel")
                }
                let loadedIdentity = sha256(try canonicalJSONData([loadAgreement, value.receipt.verifiedAggregateSHA256,
                    value.receipt.storageCommitmentSHA256, value.receipt.planName]
                    + (value.visionInventory.map { [$0.fingerprint] } ?? [])
                    + (mtpInventory.map { [$0.fingerprint] } ?? [])))
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                    disagreementMessage: "Tensor-parallel peers did not load matching verified commitments",
                    scope: .session(.loadedReady, "resident-loaded"), check: checked)
                let bufferCacheBytes = configuration.allocatorPolicy == .disableFreedBufferCache
                    ? QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes)
                    : Memory.cacheLimit
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(value.receipt.planName)"
                    + " shares=\(shares.map(String.init).joined(separator: "-")) shard_bytes=\(value.receipt.shardBytes)"
                    + " source_bytes=\(value.receipt.sourceBytes) tensors=\(value.receipt.sourceTensors)"
                    + " load_ns=\(value.receipt.loadNanoseconds) sealed=\(codec == nil ? 0 : 1) buffer_cache=\(bufferCacheBytes)"
                    + " lanes=\(batch.lanes) batch_policy=\(batch.requestOwned || batch.lanes > 1 ? QwenTensorParallelBatchWire.agreement : "single")"
                    + " paged_kv=\(pagedKV ? Self.attentionPageTokens : 0) page_bytes=\(value.model.attentionPagePool?.pageBytes ?? 0)")
                try configuration.allocatorPolicy.prepareReady(
                    synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                    snapshot: {
                        let s = Memory.snapshot()
                        return .init(activeBytes: s.activeMemory, cachedBytes: s.cacheMemory, peakBytes: s.peakMemory)
                    }, clearCache: { Memory.clearCache() }, check: checked)
                if configuration.allocatorPolicy == .disableFreedBufferCache {
                    // Ready: a bounded cache inside the gate's allocator headroom (see freedBufferCacheBytes).
                    Memory.cacheLimit = bufferCacheBytes
                    try checked()
                }
                if let terms = speculativeTerms, let mtpInventory,
                   let quote = batchMTPBudget?.allowance ?? mtpQuote?.allowance {
                    log("darkbloom-tensor-parallel-mtp-load-v1 rank=\(collective.rank) depth=\(terms.depth)"
                        + " capacity=\(batch.lanes) maximum_speculative_width=\(maximumSpeculativeWidth) assistant_bytes=\(mtpInventory.allocationBytes)"
                        + " kv_backend=paged request_bytes=\(quote.reservedBytes) policy=\(QwenTensorParallelMTPPolicy.agreement)")
                }
                if let batchBudget {
                    let complete = batchMTPBudget?.allowance ?? batchBudget.allowance
                    let allowance = QwenResidentRequestAllowance(stateBytes: complete.reservedBytes,
                        fusionBytes: 0, reservedBytes: complete.reservedBytes,
                        contextTokens: admission.profile.maximumContextTokens)
                    try allowance.requireLive()
                    try checked()
                    return !mediaEnabled ? complete.reservedBytes : max(complete.reservedBytes,
                        min(ClusterWorkerLimits.capacityBytes, Memory.memoryLimit,
                            Int(clamping: ProcessInfo.processInfo.physicalMemory)))
                }
                if let mtpQuote {
                    let maximum = Self.mtpAllowance(mtpQuote)
                    try maximum.requireLive(); try checked()
                    return max(mtpQuote.allowance.reservedBytes, min(ClusterWorkerLimits.capacityBytes,
                        Memory.memoryLimit, Int(clamping: ProcessInfo.processInfo.physicalMemory)))
                }
                let maximum = try Self.allowance(profile: source!, admission: admission,
                    maximumTokens: admission.profile.maximumContextTokens, chunkSize: admission.profile.maximumChunkTokens)
                try maximum.allowance.requireLive(additionalNativeBytes: maximum.extraNativeBytes)
                try checked()
                let textCeiling = try QwenLongPrefillCheckedBytes.sum([maximum.allowance.reservedBytes, maximum.extraNativeBytes])
                // A ceiling on additional owner bytes, never a memory grant.
                // Every media reservation derives its full quote and passes
                // the live OS and allocator gates before creating any pixels.
                return !mediaEnabled ? textCeiling : max(textCeiling,
                    min(ClusterWorkerLimits.capacityBytes, Memory.memoryLimit,
                        Int(clamping: ProcessInfo.processInfo.physicalMemory)))
            }
            guard let loaded = loadedModel, let receipt = shardReceipt, let profile = source else {
                throw ProbeError("Tensor-parallel load returned no shard")
            }
            let assistantReady = try speculativeTerms.map { terms -> ClusterQwenTensorAssistantReady in
                guard let mtpInventory, loadedMTPHead != nil else {
                    throw ProbeError("Tensor assistant readiness precedes its verified resident head")
                }
                let policy = try tensorAssistantPolicy ?? .init(depth: terms.depth, inventorySHA256: mtpInventory.fingerprint)
                return try .init(policy: policy, capacity: batch.lanes,
                    maximumSpeculativeWidth: batchMTPBudget?.maximumSpeculativeWidth ?? 1)
            }
            try control.loaded()
            let budget = prefixEnabled ? max(1, QwenTensorParallelPrefixCache.defaultBudget(activeLoaded: Memory.activeMemory)) : 0
            return QwenTensorParallelResidentRuntime(admission: admission, control: control, collective: collective,
                group: group, codec: codec, model: loaded, vision: loadedVision, visionInventory: loadedVisionInventory,
                profile: profile, shares: shares,
                loadAgreement: loadAgreement, capacity: capacity, receipt: receipt, linkProbe: probe,
                prefix: QwenTensorParallelPrefixCache(budgetBytes: batch.requestOwned || batch.lanes > 1 ? 0 : budget),
                batchLanes: batch.lanes, batchHost: batchHost, batchBudget: batchBudget, batchMTPBudget: batchMTPBudget, batchPrefixEnabled: prefixEnabled,
                mtpTerms: speculativeTerms, mtpHead: loadedMTPHead, mtpHost: mtpHost, mtpBudget: mtpQuote,
                assistantReady: assistantReady)
        } catch {
            let primary = error
            // The opt-in assistant borrows target weights. Retain every new
            // LOAD root until the drain, including a partially loaded assistant
            // carried by the original error. Nil MTP preserves legacy cleanup.
            var mtpFailedRoots: [AnyObject] = speculativeTerms == nil ? []
                : ([loadedModel, loadedVision, loadedMTPHead, mtpHost, batchHost] as [AnyObject?]).compactMap { $0 }
            control.fail(); batchHost = nil; loadedModel = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                loadedVision = nil; loadedMTPHead = nil; mtpHost = nil
                (primary as? QwenStageVisionLoadFailure)?.releaseAfterCheckedDrain()
                (primary as? QwenTensorParallelMTPLoadFailure)?.releaseAfterCheckedDrain()
                mtpFailedRoots = []
                guard retired == nil else { throw ProbeError("Tensor-parallel failed-load model remains retained") }
            } catch {
                if speculativeTerms != nil {
                    QwenTensorParallelMTPAbandonedLoad.shared.retain(primary, roots: mtpFailedRoots)
                }
                throw ProbeError("Tensor-parallel load failed (\(primary)); local cleanup failed (\(error))")
            }
            throw primary
        }
    }

    private init(admission: QwenResidentAdmission, control: QwenResidentControl, collective: Collective,
                 group: QwenTensorParallelGroup, codec: QwenTensorParallelSealCodec?, model: QwenTensorParallelModel,
                 vision: QwenStageVision?, visionInventory: QwenStageVisionInventory?, profile: QwenRegisteredDenseModelProfile, shares: [Int], loadAgreement: String, capacity: Int,
                 receipt: QwenTensorParallelShardReceipt, linkProbe: ClusterWorkerLinkProbe?,
                 prefix: QwenTensorParallelPrefixCache, batchLanes: Int, batchHost: CBv2StageKVHost?,
                 batchBudget: QwenTensorParallelBatchBudget?, batchMTPBudget: QwenTensorParallelBatchMTPBudget?,
                 batchPrefixEnabled: Bool, mtpTerms: QwenMTPTerms?,
                 mtpHead: QwenTensorParallelMTPHead?, mtpHost: CBv2StageKVHost?, mtpBudget: QwenTensorParallelMTPBudget?,
                 assistantReady: ClusterQwenTensorAssistantReady?) {
        self.admission = admission; self.control = control; self.collective = collective; self.group = group
        self.codec = codec; self.model = model; self.profile = profile; self.shares = shares
        self.vision = vision; self.visionInventory = visionInventory
        self.loadAgreement = loadAgreement; self.linkProbe = linkProbe; self.prefix = prefix
        self.batchAllocationBaseline = Memory.activeMemory
        self.batchLanes = batchLanes; self.batchHost = batchHost; self.batchBudget = batchBudget
        self.batchMTPBudget = batchMTPBudget
        self.mtpTerms = mtpTerms; self.mtpHead = mtpHead; self.mtpHost = mtpHost
        self.mtpPrefix = (batchMTPBudget?.prefix ?? mtpBudget?.prefix).map {
            .init(enabled: batchPrefixEnabled, budgetBytes: $0.residentBytes)
        }
        self.batchPrefix = batchBudget.map {
            .init(enabled: batchPrefixEnabled, budgetBytes: $0.prefix.residentBytes)
        }
        self.receipt = receipt.storageCommitmentSHA256
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane, linkProbe: linkProbe,
            media: visionInventory != nil && collective.workerDataPlane?.encryptedAndVerified == true ? ClusterQwenMedia.contract : nil,
            tensorAssistant: assistantReady)
    }

    /// One request's charge on a rank: the pipeline's conservative named state
    /// of the whole model (every rank is charged as if it held every head, as
    /// the pipeline charges either rank), both stages' fused projections, and
    /// beside them the sealed reductions' frames of one prefill chunk and the
    /// gathered logits of one step.
    static func allowance(profile: QwenRegisteredDenseModelProfile, admission: QwenResidentAdmission,
                          maximumTokens: Int, chunkSize: Int) throws -> (allowance: QwenResidentRequestAllowance, extraNativeBytes: Int) {
        let bound = QwenResidentResourceEnvironment.allocationBound
        let first = try QwenResidentRequestAllowance.derive(profile: profile, plan: admission.plan, rank: 0,
            maximumTokens: maximumTokens, chunkSize: chunkSize, bound: bound)
        let second = try QwenResidentRequestAllowance.derive(profile: profile, plan: admission.plan, rank: 1,
            maximumTokens: maximumTokens, chunkSize: chunkSize, bound: bound)
        guard let root = try JSONSerialization.jsonObject(with: admission.configBytes) as? [String: Any],
              let text = root["text_config"] as? [String: Any],
              let quantization = (root["quantization"] ?? root["quantization_config"]) as? [String: Any] else {
            throw ProbeError("Tensor-parallel request configuration is incomplete")
        }
        let plan = try QwenTensorParallelPlan(textConfiguration: text, quantization: quantization, size: 2)
        let budget = try QwenTensorParallelRequestBudget.derive(geometry: profile.geometry, plan: plan,
            tensors: profile.canonicalTensors, maximumTokens: maximumTokens, chunkSize: chunkSize,
            allocationBound: bound)
        let fusion = try QwenLongPrefillCheckedBytes.sum([first.fusionBytes, second.fusionBytes])
        guard budget.stateBytes == first.stateBytes, budget.stateBytes == second.stateBytes,
              budget.fusionBytes == fusion,
              budget.transientBytes == max(first.transientBytes, second.transientBytes) else {
            throw ProbeError("Tensor-parallel request ledger differs from the admitted stage inventories")
        }
        let reserved = try QwenLongPrefillCheckedBytes.sum([budget.stateBytes, fusion, budget.transientBytes])
        return (.init(stateBytes: budget.stateBytes, fusionBytes: fusion,
                      reservedBytes: reserved, transientBytes: budget.transientBytes, contextTokens: maximumTokens),
                try QwenLongPrefillCheckedBytes.sum([budget.allowance.collectiveScratchBytes,
                    budget.logitsBytes, budget.projectionConstantBytes]))
    }

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    public func keepWarmPulse() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return keepWarm.pulse()
    }

    public func dataPlanePing() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        if usesRequestOwnedSingleton {
            // Capacity one reserves through the lane contract; a refusal there is
            // this request's alone, named as the lane path names it (capacity or
            // its own deadline), never `unsupported`.
            do { return try reserveLane(requestID: requestID, request: value) }
            catch let refusal as ClusterResidentRequestRefusal { throw refusal }
            catch {
                let reason: ClusterWorkerRefusal = DispatchTime.now().uptimeNanoseconds >= value.deadlineUptimeNanoseconds
                    ? .deadline : .capacity
                log("darkbloom-request-refused-v1 rank=\(collective.rank) reason=\(reason.rawValue)")
                throw ClusterResidentRequestRefusal(reason: reason, message: String(describing: error))
            }
        }
        guard batchLanes == 1 else { throw ProbeError("Batched TP owners reserve through the lane contract") }
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard value.route == nil else { throw ProbeError("Under tensor parallel every request uses both ranks") }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds,
            allowsQwenMedia: baseReady.media == ClusterQwenMedia.contract)
        let mediaBudget: QwenMediaBudget?
        if let envelope = value.qwenMedia {
            guard baseReady.media == ClusterQwenMedia.contract, let visionInventory,
                (collective.rank == 0 && envelope.items.allSatisfy({ $0.encoded != nil }))
                    || (collective.rank == 1 && !envelope.carriesEncodedBytes) else {
                throw ProbeError("Qwen media payload or sealed readiness differs from its rank")
            }
            mediaBudget = try QwenMediaBudget(media: envelope, rank: collective.rank,
                hiddenSize: visionInventory.configuration.textConfiguration.hiddenSize,
                featureElementBytes: visionInventory.featureDType.size,
                maximumVideoPatches: visionInventory.processor.maximumVideoPatchCount(),
                tensorParallel: true, chunkTokens: request.chunkSize,
                minimumActivationBytes: 11 * 1_073_741_824 / 2,
                maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
                sealedFrameOverhead: QwenTensorParallelSealCodec.frameOverhead,
                allocationBound: QwenResidentResourceEnvironment.allocationBound)
        } else { mediaBudget = nil }
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard model != nil else { throw ProbeError("Resident model already released") }
            let charge: (allowance: QwenResidentRequestAllowance, extraNativeBytes: Int)
            if let terms = mtpTerms, request.qwenMedia == nil {
                guard let model else { throw ProbeError("Tensor assistant lost its target") }
                let quote = try QwenTensorParallelMTPBudget.derive(geometry: profile.geometry, plan: model.plan,
                    tensors: profile.canonicalTensors, maximumTokens: request.maximumTokens,
                    promptTokens: request.promptCount, chunkSize: min(request.chunkSize, request.promptCount), depth: terms.depth,
                    rank: collective.rank, allocationBound: QwenResidentResourceEnvironment.allocationBound)
                charge = (Self.mtpAllowance(quote), 0)
            } else {
                charge = try Self.allowance(profile: profile, admission: admission, maximumTokens: request.maximumTokens,
                    chunkSize: min(request.chunkSize, request.promptCount))
            }
            let extra = try QwenLongPrefillCheckedBytes.sum([charge.extraNativeBytes, mediaBudget?.nativeBytes ?? 0])
            let host = mediaBudget?.hostBytes ?? 0
            let total = try QwenLongPrefillCheckedBytes.sum([charge.allowance.reservedBytes, extra, host])
            guard total <= value.capacityLimitBytes, total <= baseReady.requestCapacityBytes else {
                throw ProbeError("Tensor-parallel reservation exceeds its owner or readiness capacity ceiling")
            }
            // Pages no request or prefix entry holds go back first (the pool
            // regrows to this request's pages when it starts).
            _ = try? model?.attentionPagePool?.trim()
            // Kept prefixes give way before a reservation is refused for memory;
            // a paged rank also needs what its page pool grows by.
            try prefix.yieldingMemory {
                try charge.allowance.requireLive(additionalNativeBytes: try QwenLongPrefillCheckedBytes.sum([
                    extra, Self.pagedGrowthBytes(model: model, tokens: Self.initialPageTokens(
                        promptCount: request.promptCount, maximumTokens: request.maximumTokens))]), additionalHostBytes: host)
            }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let media: QwenMediaRequestWork?
            if let envelope = value.qwenMedia, let budget = mediaBudget {
                guard let visionInventory else { throw ProbeError("Qwen media lost its loaded source identity") }
                let state = try QwenMediaRequestState(media: envelope, prompt: request.promptTokenIDs,
                    identity: visionInventory.mediaIdentity, maximumPrompt: admission.profile.maximumPromptTokens,
                    maximumContext: request.maximumTokens)
                media = .init(state: state, budget: budget)
            } else { media = nil }
            reservation = .init(request: request, allowance: charge.allowance, extraNativeBytes: extra,
                deadline: value.deadlineUptimeNanoseconds, media: media)
            return total
        }
    }

    public func releaseReservation(requestID: UUID) throws {
        if usesRequestOwnedSingleton {
            guard withdrawLane(requestID: requestID) else { throw ProbeError("Singleton TP release has no matching unstarted lane") }
            return
        }
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("Resident release has no matching unstarted reservation")
        }
        try reserved.media?.releaseAfterCheckedDrain()
        reservation = nil
    }

    /// The exact Qwen27 owner publishes raw selection logprobs on both its
    /// singleton and native batch paths. Other TP rows keep prior readiness.
    public var capturesLogprobs: Bool { admission.specification.model == .qwen38TwentySevenB }

    public func start(requestID: UUID, tokens channel: ClusterCommittedTokenChannel) throws -> QwenResidentGenerationCompletion {
        if usesRequestOwnedSingleton { return try startSingletonLane(requestID: requestID, channel: channel) }
        return try start(requestID: requestID) { ordinal, token, frontier in
            // Sampling remains request-local and is disabled from the greedy
            // lookahead path; the pending raw row belongs to this token only.
            let logprobs = self.mtpCommittedLogprobs ?? self.reservation?.request.sampler?.takePendingLogprobs()
            try channel.publishToken(ordinal, token, frontier, logprobs)
            return try channel.answer()
        }
    }

    /// Only rank 0 invokes the callback, once both ranks hold the token.
    /// False requests an agreed clean stop; a thrown callback is a failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        if usesRequestOwnedSingleton {
            return try ClusterCommittedTokenChannel.answering(onCommittedToken) {
                try startSingletonLane(requestID: requestID, channel: $0)
            }
        }
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        do {
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID, recordedRequestFingerprint: reserved.request.fingerprint),
                deadline: reserved.deadline, body: {
                    if let media = reserved.media {
                        return try MLX.withError { error in
                            let result = try autoreleasepool {
                                try generate(reserved, onCommittedToken: onCommittedToken, check: { try error.check() })
                            }
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                            try media.releaseAfterCheckedDrain()
                            return result
                        }
                    }
                    return try autoreleasepool {
                        if mtpTerms != nil { return try generateMTP(reserved, onCommittedToken: onCommittedToken) }
                        return try generate(reserved, onCommittedToken: onCommittedToken, check: {})
                    }
                }, prepare: { $0 })
            collective.logDataPlaneStatus()
            reservation = nil
            return value
        } catch {
            // The peer may hold another prefix state now: keep nothing.
            prefix.sweep()
            control.fail(); throw error
        }
    }

    public func cancel(requestID: UUID) {
        if usesRequestOwnedSingleton { cancelLane(requestID: requestID) }
        else { control.cancel(requestID) }
    }

    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        reservation?.media?.finishHostPreparation()
        for reserved in batchBook.reservations() { reserved.media?.finishHostPreparation() }
        collective.logDataPlaneStatus()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    try failedMTPDecoder?.retire()
                    try failedMTPTarget?.retire()
                    guard mtpHost?.isDrained ?? true else { throw ProbeError("Qwen TP assistant target histories remain owned") }
                    failedMTPDecoder = nil; failedMTPTarget = nil; mtpHost = nil; mtpHead = nil; mtpCommittedLogprobs = nil
                    try failedBatchDriver?.retireAll()
                    guard batchHost?.isDrained ?? true else { throw ProbeError("Qwen TP batch histories remain owned") }
                    for reserved in batchBook.reservations() { try reserved.media?.releaseAfterCheckedDrain() }
                    batchBook.clear(); failedBatchDriver = nil; batchHost = nil
                    try reservation?.media?.releaseAfterCheckedDrain()
                    prefix.sweep(); batchPrefix?.sweep(); mtpPrefix?.sweep()
                    weak var releasedVision = vision
                    vision = nil
                    guard releasedVision == nil else { throw ProbeError("Tensor-parallel vision model remains retained") }
                    weak var released: QwenTensorParallelModel?
                    released = model; reservation = nil; model = nil
                    guard released == nil else { throw ProbeError("Tensor-parallel model remains retained") }
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit { if processLeaseOwned { control.fail() } }

    // MARK: - One request

    private func generate(_ reserved: Reserved, onCommittedToken: (Int, Int, Int) throws -> Bool,
                          check: () throws -> Void) throws -> QwenResidentGenerationCompletion {
        guard let model else { throw ProbeError("Resident model already released") }
        let request = reserved.request, rank = collective.rank
        // Both ranks run the same request: its fingerprint (prompt, output
        // count, chunk, stop tokens, sampling) and this load's agreement.
        guard try group.digestsEqual(Self.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("Tensor-parallel ranks were given different requests")
        }
        let sampler = request.sampler
        let prompt = request.promptTokenIDs, chunk = max(1, request.chunkSize)
        var lastCheck: UInt64 = 0
        /// Local: true when this rank must ask both to stop (cancel, deadline, memory).
        func localStop() -> Bool {
            if (try? control.check(deadline: reserved.deadline)) == nil { return true }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastCheck >= 250_000_000 {
                lastCheck = now
                if (try? prefix.yieldingMemory({ try reserved.allowance.requireLive(additionalNativeBytes: reserved.extraNativeBytes,
                        additionalHostBytes: reserved.media?.budget.hostBytes ?? 0) })) == nil {
                    return true
                }
            }
            return false
        }

        if let media = reserved.media {
            guard let visionInventory else { throw ProbeError("Qwen media lost its loaded processor identity") }
            try QwenTensorParallelMedia.prepare(media, vision: vision, inventory: visionInventory,
                modelConfiguration: admission.configBytes, rank: rank, group: group, chunkTokens: chunk,
                shouldStop: localStop, check: check)
        }
        // The request's attention pages (nil when contiguous), held until it ends.
        // Its prompt and one granule; decode grows them (`growPages`).
        let pages = try Self.reservePages(model: model, tokens: Self.initialPageTokens(
            promptCount: prompt.count, maximumTokens: request.maximumTokens))
        defer { withExtendedLifetime(pages) {} }
        // Prompt prefix: the longest chunk boundary both ranks hold.
        var cache = model.newCache(account: pages?.account)
        var start = 0
        let scope = loadAgreement + "|" + receipt
            + (reserved.media.map { "|qwen-media=" + $0.state.prefixIdentity } ?? "")
        if prefix.enabled, prompt.count > chunk {
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: chunk)
            let held = prefix.heldBoundaries(scope: scope, prompt: prompt, chunk: chunk)
            if let agreed = try QwenTensorParallelPrefixCache.agree(held: held, group: group, candidates: candidates),
               let restored = prefix.restore(scope: scope, prompt: prompt, length: agreed) {
                cache = restored; start = agreed
                // The entry's pages are shared; what the request appends is its own.
                for case let history as PagedAttentionKVCache in cache { history.account = pages?.account }
            }
        }
        // Prefill from `start` in chunks aligned to the boundaries; keep the
        // last whole boundary before the final token.
        var logits: MLXArray?
        var offset = start
        let keepAt = prefix.enabled ? ((prompt.count - 1) / chunk) * chunk : 0
        while offset < prompt.count {
            let end = min(prompt.count, (offset / chunk + 1) * chunk)
            let input = MLXArray(prompt[offset ..< end].map { Int32($0) }).reshaped(1, end - offset)
            let out: MLXArray
            if let media = reserved.media {
                let embeddings = try media.state.merging(model.embeddingsForMedia(input), range: offset..<end)
                out = try model.forwardMediaForRuntime(input, cache: cache, embeddings: embeddings,
                    positions: media.state.positions(in: offset..<end))
            } else { out = model.forwardForRuntime(input, cache: cache) }
            if end < prompt.count {
                eval(cache.flatMap { $0.innerState() }); try check()
                if end == keepAt, keepAt > start { prefix.store(scope: scope, prompt: prompt, length: end, cache: cache) }
            } else {
                logits = out[0..., -1, 0...]
            }
            offset = end
        }
        guard let firstLogits = logits else { throw ProbeError("Tensor-parallel prefill produced no logits") }

        func nextLogits(_ token: MLXArray, outputIndex: Int) throws -> MLXArray {
            guard let media = reserved.media else { return model.step(token, cache: cache) }
            let offset = prompt.count + outputIndex
            let input = token.reshaped(1, 1)
            return try model.forwardMediaForRuntime(input, cache: cache, embeddings: nil,
                positions: media.state.positions(in: offset..<(offset + 1)))[0..., -1, 0...]
        }
        func choose(_ stepLogits: MLXArray, stop: Float) -> (MLXArray, MLXArray) {
            guard let sampler else { return model.selectWithFlags(stepLogits, stop: stop) }
            // Every rank evaluates the logits gather before the choice is broadcast:
            // rank 0's draw reads it, and a rank that left it unevaluated would meet
            // rank 0's gather with the broadcast's reduction (the first sampled run on
            // the pair hung so: both ranks ended at the 60 s progress guard, status 75).
            let full = model.gatheredLogits(stepLogits)
            eval(full)
            let drawn = rank == 0 ? sampler.sample(full) : nil
            return model.broadcastChoice(drawn, stop: stop)
        }
        // Greedy steps are built one ahead (the next step's graph is submitted
        // before this token is read). A sampled step is built after the token
        // before it is committed: the product's sampler draws at the output
        // index with the history (penalties) up to it.
        let pipelined = sampler == nil
        var (current, currentFlags) = choose(firstLogits, stop: 0)
        asyncEval(current, currentFlags)
        var tokens: [Int] = []
        var finish: ClusterWorkerFinishReason = .length
        var clientStopped = false
        // 0, or the number of tokens to keep: what this rank puts in its stop
        // slot of every step built from now on.
        var stopKeep: Float = 0
        // The pages could not grow: the request ends at its length after the
        // next step built (the margin covers the steps built before that).
        var pagesRefused = false
        /// Before a step that appends output `index` is built: its pages.
        func growPages(forOutput index: Int) {
            guard !pagesRefused else { return }
            pagesRefused = !Self.growPages(pages, needed: prompt.count + index + 1, limit: request.maximumTokens,
                caches: cache, admit: { bytes in try prefix.yieldingMemory { try Self.requireLiveMemory(bytes: bytes) } })
        }
        var pending: (MLXArray, MLXArray)?
        steps: for step in 0 ..< request.outputCount {
            pending = nil
            if pipelined, step + 1 < request.outputCount {
                growPages(forOutput: step)
                let next = choose(try nextLogits(current, outputIndex: step), stop: stopKeep)
                asyncEval(next.0, next.1)
                pending = next
            }
            let token = Int(current.item(Int32.self)); try check()
            let flags = currentFlags.asArray(Float.self).filter { $0 > 0 }
            if let slot = flags.min() {
                // A rank asked both to stop when this step was built: both keep
                // the tokens it named and end here (at the request's length
                // when its pages could not grow).
                let stop = QwenTensorParallelStopRule.stop(slot: slot)
                tokens = Array(tokens.prefix(stop.keep))
                finish = stop.finish == .length ? .length : .clientStop; break
            }
            if stopKeep == 0 {
                sampler?.commit(token)
                tokens.append(token)
                let wanted = rank == 0 ? try onCommittedToken(tokens.count - 1, token, prompt.count + tokens.count - 1) : true
                // A stop token, then the output limit, end the request at this
                // token whatever the answer (the engine answers "not wanted"
                // for the token that ends it); only an earlier "not wanted" is
                // a client stop (`QwenTensorParallelStopRule`).
                switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(token),
                                                          committed: tokens.count, outputCount: request.outputCount, wanted: wanted) {
                case .eos: finish = .eos; break steps
                case .length: finish = .length; break steps   // the last step: nothing further was built
                case .clientStop: clientStopped = true
                case .proceed: break
                }
                if clientStopped || localStop() {
                    stopKeep = Float(tokens.count)
                } else if pagesRefused {
                    stopKeep = QwenTensorParallelStopRule.lengthStop(keep: tokens.count)
                }
            }
            if !pipelined, step + 1 < request.outputCount {
                growPages(forOutput: step)
                if pagesRefused, stopKeep == 0 { stopKeep = QwenTensorParallelStopRule.lengthStop(keep: tokens.count) }
                let next = choose(try nextLogits(current, outputIndex: step), stop: stopKeep)
                asyncEval(next.0, next.1)
                pending = next
            }
            guard let (nextToken, nextFlags) = pending else { break }
            current = nextToken; currentFlags = nextFlags
            pending = nil
        }
        // A step both ranks built and submitted is evaluated by both, so its
        // reductions meet; nothing of it is emitted.
        if let pending { eval(pending.0, pending.1); try check() }
        if clientStopped || (stopKeep > 0 && stopKeep < QwenTensorParallelStopRule.lengthStopBase) { finish = .clientStop }
        // Both ranks end on rank 0's outcome (one small sealed agreement, made
        // by both before either may throw below): a client stop rank 0 made
        // when no later step could carry its flag leaves rank 1 at the limit.
        let localFinish: QwenTensorParallelStopRule.Finish = finish == .eos ? .eos : finish == .length ? .length : .clientStop
        let agreed = try group.exchangeIntegers(rank == 0 ? [Int32(tokens.count), localFinish.code] : [0, 0])
        guard agreed.count == 2, let rank0Finish = QwenTensorParallelStopRule.Finish(code: agreed[1]) else {
            throw ProbeError("Tensor-parallel ranks did not agree how the request ended")
        }
        let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: localFinish, localCount: tokens.count,
            localStopped: stopKeep > 0 && !clientStopped, rank0Finish: rank0Finish, rank0Count: Int(agreed[0]))
        tokens = Array(tokens.prefix(ended.count))
        switch ended.finish {
        case .eos: finish = .eos
        case .length: finish = .length
        case .clientStop: finish = .clientStop
        }
        try control.check(deadline: reserved.deadline)
        if finish == .clientStop && !clientStopped && rank == 0 {
            // The other rank asked to stop (cancelled or out of memory there).
            throw ProbeError("The peer rank stopped the tensor-parallel request")
        }
        let reused = start
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) request=\(request.requestID.uuidString.lowercased())"
            + " prompt=\(prompt.count) reused=\(reused) output=\(tokens.count) finish=\(finish.rawValue)"
            + " sampled=\(sampler == nil ? 0 : 1) frames=\(codec?.sealedFrames ?? 0) key_generation=\(codec?.keyGeneration ?? 0)"
            + " kv_tokens=\(pages?.tokens ?? 0) kv_grown=\(max(0, (pages?.accounts.count ?? 1) - 1)) kv_refused=\(pagesRefused ? 1 : 0)")
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true,
            reusedPromptTokens: reused, storedPromptFrontiers: keepAt > 0 ? [keepAt] : [])
    }

    /// 64 bits of SHA-256 of `text`.
    static func digest64(_ text: String) -> UInt64 {
        let hex = sha256(Data(text.utf8))
        return UInt64(hex.prefix(16), radix: 16) ?? 0
    }
}
