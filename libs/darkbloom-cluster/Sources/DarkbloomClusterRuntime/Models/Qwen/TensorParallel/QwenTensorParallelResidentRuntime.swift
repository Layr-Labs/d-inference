import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

/// The worker's resident owner for `tensor_parallel_v1` on the dense Qwen
/// rows (9B, 27B) and equal shares of the Qwen3.5 and Qwen3.6 35B A3B
/// routed-expert rows: both ranks hold a
/// share of every layer (heads, key/value heads, MLP channels and vocabulary
/// rows, `QwenTensorParallelPlan`), run
/// every prefill chunk and decode step together, and sum each row-parallel
/// projection's partials with the sealed all-sum inside the lazy graph: every
/// partial crosses the cable as an AES-256-GCM frame under direction keys the
/// pinned data-plane exchange (S16) derived for this session and load
/// agreement, rekeyed by count and bytes; a frame that does not authenticate
/// ends the evaluation on both ranks.
///
/// Every row serves request-owned CBv2 lanes (main's paged KV host,
/// `QwenTensorParallelResidentRuntime+Batch.swift`) at every capacity over an
/// authenticated sealed pair; capacity one is the same path one lane wide, and
/// its singleton wire adapts to the shared batch driver. An enclosing process
/// deadline is required (a blocked collective cannot be interrupted
/// cooperatively).
///
/// Generation (`QwenTensorParallelNativeBatchExecutor`): a greedy row's token
/// is the distributed argmax (one small sealed reduction for the cohort, both
/// ranks learn every token); a sampled row's whole-vocabulary logits are
/// gathered to every rank (exact: each rank adds zeros outside its rows) and
/// rank 0 draws with the product's sampler (`QwenStageTokenSampler`), then
/// makes the tokens known to rank 1 in one small sealed reduction. Joins,
/// stops, cancellations, deadlines and retirements cross in the shared
/// driver's own bounded exchange (`QwenTensorParallelBatchDriver`), so a stop
/// on either rank ends that request on both after the same step. Stop tokens
/// and the output count are known to both ranks and end both at once.
///
/// Prompt prefixes: each rank keeps its own heads' state at chunk boundaries,
/// resident and on its SSD tier (`QwenTensorParallelBatchPrefixCache`); a
/// request restores the longest boundary BOTH ranks hold (one sealed vote), or
/// neither restores.
///
/// Limits: the profile is the row's (`QwenResidentAdmission.profile`, the
/// native context for Qwen3.8 27B); LOAD quotes every lane at the memory
/// plan's request (`memoryProfile`), and a longer request is charged at its
/// own context when it is reserved (`QwenTensorParallelRequestCharge`).
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
    private var processLeaseOwned = true
    public let shares: [Int]
    public let receipt: String
    /// What this rank measured of the link at load (`QwenTensorParallelLinkProbe`).
    public let linkProbe: ClusterWorkerLinkProbe?
    public let batchLanes: Int
    var batchHost: CBv2StageKVHost?
    let batchBudget: QwenTensorParallelBatchBudget?
    let batchMTPBudget: QwenTensorParallelBatchMTPBudget?
    /// What a request costs this rank at its own context: `reserveLane`
    /// admits by it, READY's capacity covers the profile's longest.
    let requestCharge: QwenTensorParallelRequestCharge
    /// The longest context this rank's gate admits now, for a row whose
    /// profile is longer than its memory plan (READY, then each keep-warm
    /// answer: `refreshServingContext`); nil for every other row.
    private(set) var servingContextTokens: Int?
    let batchPrefix: QwenTensorParallelBatchPrefixCache?
    /// The batch prefix cache's SSD tier on this rank, when the owner configured one.
    let prefixDisk: QwenTensorParallelPrefixDisk?
    let batchBook = ClusterBatchLaneBook<QwenTensorParallelOwnedBatchReservation>()
    var batchServing = false
    var batchOrdinal: UInt64 = 0
    let batchAllocationBaseline: Int
    let batchResourceWatch = QwenDenseStageLoadWatch("Tensor-parallel batch")
    let mtpTerms: QwenMTPTerms?
    let mtpPrefix: QwenTensorParallelMTPPrefixCache?
    var mtpHead: QwenTensorParallelMTPHead?
    // Failed native/resource cleanup must remain reachable until shutdown's
    // checked drain or the enclosing worker's process fence.
    var failedBatchDriver: QwenTensorParallelBatchDriver<QwenTensorParallelNativeBatchExecutor<QwenTensorParallelOwnedBatchReservation>>?

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
        // Live precision (main's policy, as the owner resolved it): every
        // request-owned row sits on the product's paged pool.
        let kvQuantization = try PagedKVQuantizationSelection.clusterLive(environment)
        // How the SSD tier's records store attention rows (main's checkpoint
        // precision, as the owner resolved it; balanced unless it says native).
        let prefixRecords = try QwenStagePrefixDiskEncoding.fromEnvironment(environment, family: .qwenAttention)
        // The assistant's request-owned history needs the CBv2 paged backend;
        // refuse before LOAD rather than at the first request.
        try QwenTensorParallelMTPPolicy.require(model: admission.specification.model, lanes: batch.lanes,
            keyed: credential != nil, paged: batch.backend == .paged, terms: speculativeTerms, environment: environment)
        if let tensorAssistantPolicy {
            try tensorAssistantPolicy.validate()
            guard ClusterQwenTensorAssistantPolicy.runtimeModelIDs.contains(admission.specification.model.rawValue),
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
        var requestCharge: QwenTensorParallelRequestCharge?
        var loadedMTPHead: QwenTensorParallelMTPHead?
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
            // Packed rows have no exact snapshot to keep (main keeps no snapshot prefixes for them).
            let prefixEnabled = QwenStagePrefixCache.fromEnvironment(environment).enabled && kvQuantization == .native
            let fields = try QwenTensorParallelMTPPolicy.fields(terms: speculativeTerms, inventory: mtpInventory)
                + (tensorAssistantPolicy.map { [$0.schema, String($0.depth), $0.inventorySHA256] + $0.verificationArguments }
                    ?? [])
                + batch.agreementFields + kvQuantization.loadAgreementFields + mode.loadAgreementFields
                + loadAgreementFields(shares: shares)
                + QwenTensorParallelTargetWindow.agreementFields
                + QwenTensorParallelPlan.arithmeticAgreementFields(routedExperts: admission.specification.routedExperts != nil)
                + QwenTensorParallelBatchSession.decodeAgreementFields
                + ["qwen-tensor-parallel-prefix-v2", prefixEnabled ? "on" : "off"]
                + (prefixEnabled ? prefixRecords.loadAgreementFields : [])
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
            // The shard reduces through the group, except while the share probe times it alone.
            let reduction = QwenTensorParallelSwitchableReduction(group)
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
                // LOAD quotes every lane at the memory plan's request; a longer
                // one is charged at its own context when it is reserved.
                let memory = admission.memoryProfile
                let value = try autoreleasepool {
                    try QwenTensorParallelVerifiedLoad.load(admission, rank: collective.rank, shares: shares,
                        reduction: reduction, includeVision: mediaEnabled,
                        requestAllowance: { profile, plan in
                            if let terms = speculativeTerms {
                                let quote = try QwenTensorParallelBatchMTPBudget.derive(geometry: profile.geometry, plan: plan,
                                    tensors: profile.canonicalTensors, maximumTokens: memory.maximumContextTokens,
                                    promptTokens: memory.maximumPromptTokens,
                                    chunkSize: memory.maximumChunkTokens, lanes: batch.lanes, depth: terms.depth,
                                    maximumSpeculativeWidth: maximumSpeculativeWidth, rank: collective.rank,
                                    allocationBound: QwenResidentResourceEnvironment.allocationBound)
                                batchMTPBudget = quote; batchBudget = quote.target
                                return quote.allowance.reservedBytes
                            }
                            let quote = try QwenTensorParallelBatchBudget.derive(geometry: profile.geometry, plan: plan,
                                tensors: profile.canonicalTensors, maximumTokens: memory.maximumContextTokens,
                                chunkSize: memory.maximumChunkTokens, lanes: batch.lanes,
                                paged: batch.backend == .paged, rank: collective.rank,
                                allocationBound: QwenResidentResourceEnvironment.allocationBound)
                            batchBudget = quote
                            return quote.allowance.reservedBytes
                        }, additionalResidentBytes: futureAssistant, check: checked)
                }
                retired = value.model; loadedModel = value.model; shardReceipt = value.receipt; source = value.profile
                loadedVision = value.vision; loadedVisionInventory = value.visionInventory
                if let mtpSource, let mtpInventory {
                    guard let requestAllowance = batchMTPBudget?.allowance else {
                        throw ProbeError("Qwen TP assistant LOAD has no complete native request quote")
                    }
                    loadedMTPHead = try QwenTensorParallelMTPHead.load(source: mtpSource,
                        configuration: admission.configBytes, inventory: mtpInventory,
                        target: value.model, reduction: group,
                        remainingResidentAllowanceBytes: requestAllowance.reservedBytes, check: checked)
                }
                // Every request's keys and values live in this rank's CBv2 KV
                // host, bounded by the profile's longest request (a ceiling,
                // not an allocation: each request's pages grow with it).
                batchHost = try CBv2StageKVHost(model: value.model.model, kind: batch.backend, lanes: batch.lanes,
                    maximumTokensPerRequest: admission.profile.maximumContextTokens,
                    maximumChunkTokens: max(admission.profile.maximumChunkTokens, (speculativeTerms?.depth ?? 0) + 1),
                    quantization: kvQuantization)
                batchHost?.report("qwen_tensor_parallel")
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
                    + " lanes=\(batch.lanes) batch_policy=\(QwenTensorParallelBatchWire.agreement)"
                    + " paged_kv=\(batch.backend == .paged ? CBv2PagedDefaults.pageSize : 0)")
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
                if let terms = speculativeTerms, let mtpInventory, let quote = batchMTPBudget?.allowance {
                    log("darkbloom-tensor-parallel-mtp-load-v1 rank=\(collective.rank) depth=\(terms.depth)"
                        + " capacity=\(batch.lanes) maximum_speculative_width=\(maximumSpeculativeWidth) assistant_bytes=\(mtpInventory.allocationBytes)"
                        + " kv_backend=paged request_bytes=\(quote.reservedBytes) policy=\(QwenTensorParallelMTPPolicy.agreement)")
                }
                guard let batchBudget else { throw ProbeError("Tensor-parallel load has no request-owned batch quote") }
                let complete = batchMTPBudget?.allowance ?? batchBudget.allowance
                let allowance = QwenResidentRequestAllowance(stateBytes: complete.reservedBytes,
                    fusionBytes: 0, reservedBytes: complete.reservedBytes,
                    contextTokens: memory.maximumContextTokens)
                try allowance.requireLive()
                try checked()
                let charge = QwenTensorParallelRequestCharge(geometry: value.profile.geometry, plan: value.model.plan,
                    tensors: value.profile.canonicalTensors, lanes: batch.lanes, paged: batch.backend == .paged,
                    assistant: speculativeTerms.map { ($0.depth, maximumSpeculativeWidth) }, rank: collective.rank,
                    allocationBound: QwenResidentResourceEnvironment.allocationBound,
                    loadSharedBytes: batchMTPBudget?.sharedBytesExcludingCollectives ?? batchBudget.sharedBytesExcludingCollectives,
                    collectiveScratchBytes: complete.collectiveScratchBytes)
                requestCharge = charge
                // The most one text request is charged: LOAD's quote, or one
                // request at the profile's longest context when that is longer.
                let text = admission.profile.maximumContextTokens > memory.maximumContextTokens
                    ? max(complete.reservedBytes, try charge.bytes(contextTokens: admission.profile.maximumContextTokens,
                        profile: admission.profile))
                    : complete.reservedBytes
                // A ceiling on additional owner bytes, never a memory grant.
                // Every media reservation derives its full quote and passes
                // the live OS and allocator gates before creating any pixels.
                return !mediaEnabled ? text : max(text,
                    min(ClusterWorkerLimits.capacityBytes, Memory.memoryLimit,
                        Int(clamping: ProcessInfo.processInfo.physicalMemory)))
            }
            guard let loaded = loadedModel, let receipt = shardReceipt, let profile = source, let requestCharge else {
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
            // The batch prefix cache's SSD tier, when the owner configured one:
            // this rank's records of this plan and shares, the verified
            // artifact and storage, both builds and the assistant, which a
            // restarted pair finds again. Opening it sweeps the directories of
            // other plans under the root that hold no live record.
            let prefixDisk: QwenTensorParallelPrefixDisk? = prefixEnabled ? {
                let scope = QwenTensorParallelPrefixDisk.planScope(plan: loaded.plan, planFingerprint: admission.plan.fingerprint,
                    artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
                    storageCommitmentSHA256: receipt.storageCommitmentSHA256,
                    rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
                    assistantPolicy: speculativeTerms.map { "depth=\($0.depth)|inventory=\(mtpInventory?.fingerprint ?? "none")" })
                return QwenStagePrefixDiskTier.open(configuration: .fromEnvironment(environment, key: prefixSSDKey),
                    planScope: scope, rank: collective.rank, encoding: prefixRecords,
                    stagingEpoch: admission.configuration.identity.membershipEpoch.uuidString.lowercased())
                    .map { QwenTensorParallelPrefixDisk(tier: $0, planScope: scope) }
            }() : nil
            // This rank's own share, timed alone before its ready record (`QwenTensorParallelShareProbe`). The batch
            // owner's baseline is taken first, so what the probe's forward keeps counts as a first request's would.
            let allocationBaseline = Memory.activeMemory
            log(QwenTensorParallelBatchSession.kernelLine(rank: collective.rank, plan: loaded.plan))
            let shareProbe = try QwenTensorParallelShareProbe.atLoad(model: loaded, reduction: reduction, admission: admission,
                profile: profile, shares: shares, backend: batch.backend, depth: speculativeTerms?.depth, control: control)
            // The longest context the reservation gate admits now, beside the
            // loaded weights and what the probe kept (local: no collective).
            let grown = max(0, Memory.activeMemory - allocationBaseline)
            let serving = try servingContext(requestCharge, admission: admission, grownBytes: grown)
            if let serving {
                log("darkbloom-serving-context-v1 rank=\(collective.rank) tokens=\(serving) previous=0 grown=\(grown)"
                    + " profile=\(admission.profile.maximumContextTokens) memory_plan=\(admission.memoryProfile.maximumContextTokens)")
            }
            return QwenTensorParallelResidentRuntime(admission: admission, control: control, collective: collective,
                group: group, codec: codec, model: loaded, vision: loadedVision, visionInventory: loadedVisionInventory,
                profile: profile, shares: shares,
                allocationBaseline: allocationBaseline, shareProbe: shareProbe,
                loadAgreement: loadAgreement, capacity: capacity, receipt: receipt, linkProbe: probe,
                batchLanes: batch.lanes, batchHost: batchHost, batchBudget: batchBudget, batchMTPBudget: batchMTPBudget,
                requestCharge: requestCharge, servingContextTokens: serving, batchPrefixEnabled: prefixEnabled,
                prefixDisk: prefixDisk,
                mtpTerms: speculativeTerms, mtpHead: loadedMTPHead, assistantReady: assistantReady)
        } catch {
            let primary = error
            // The opt-in assistant borrows target weights. Retain every new
            // LOAD root until the drain, including a partially loaded assistant
            // carried by the original error. Nil MTP preserves legacy cleanup.
            var mtpFailedRoots: [AnyObject] = speculativeTerms == nil ? []
                : ([loadedModel, loadedVision, loadedMTPHead, batchHost] as [AnyObject?]).compactMap { $0 }
            control.fail(); batchHost = nil; loadedModel = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                loadedVision = nil; loadedMTPHead = nil
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
                 vision: QwenStageVision?, visionInventory: QwenStageVisionInventory?, profile: QwenRegisteredDenseModelProfile, shares: [Int],
                 allocationBaseline: Int, shareProbe: ClusterWorkerShareProbe?, loadAgreement: String, capacity: Int,
                 receipt: QwenTensorParallelShardReceipt, linkProbe: ClusterWorkerLinkProbe?,
                 batchLanes: Int, batchHost: CBv2StageKVHost?,
                 batchBudget: QwenTensorParallelBatchBudget?, batchMTPBudget: QwenTensorParallelBatchMTPBudget?,
                 requestCharge: QwenTensorParallelRequestCharge, servingContextTokens: Int?,
                 batchPrefixEnabled: Bool, prefixDisk: QwenTensorParallelPrefixDisk?, mtpTerms: QwenMTPTerms?,
                 mtpHead: QwenTensorParallelMTPHead?, assistantReady: ClusterQwenTensorAssistantReady?) {
        self.admission = admission; self.control = control; self.collective = collective; self.group = group
        self.codec = codec; self.model = model; self.profile = profile; self.shares = shares
        self.vision = vision; self.visionInventory = visionInventory
        self.loadAgreement = loadAgreement; self.linkProbe = linkProbe
        self.batchAllocationBaseline = allocationBaseline
        self.batchLanes = batchLanes; self.batchHost = batchHost; self.batchBudget = batchBudget
        self.batchMTPBudget = batchMTPBudget
        self.requestCharge = requestCharge; self.servingContextTokens = servingContextTokens
        self.mtpTerms = mtpTerms; self.mtpHead = mtpHead
        self.mtpPrefix = batchMTPBudget.map {
            .init(enabled: batchPrefixEnabled, budgetBytes: $0.prefix.residentBytes)
        }
        self.batchPrefix = batchBudget.map {
            .init(enabled: batchPrefixEnabled, budgetBytes: $0.prefix.residentBytes)
        }
        self.prefixDisk = prefixDisk
        self.receipt = receipt.storageCommitmentSHA256
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane,
            servingContextTokens: servingContextTokens, linkProbe: linkProbe,
            media: visionInventory != nil && collective.workerDataPlane?.encryptedAndVerified == true ? ClusterQwenMedia.contract : nil,
            tensorAssistant: assistantReady, shareProbe: shareProbe)
    }

    /// The longest context this rank's gate admits now when the profile is
    /// longer than the memory plan LOAD quoted (nil otherwise: every request
    /// within such a profile was charged at LOAD). Not even the smallest
    /// useful request fitting reports that smallest one, so a longer request
    /// is refused up front and a shorter one is still gated at reservation.
    static func servingContext(_ charge: QwenTensorParallelRequestCharge, admission: QwenResidentAdmission,
                               grownBytes: Int) throws -> Int? {
        let profile = admission.profile
        guard profile.maximumContextTokens > admission.memoryProfile.maximumContextTokens else { return nil }
        return try charge.servingContextTokens(profile: profile, grownBytes: grownBytes, on: .live())
            ?? min(profile.maximumContextTokens, profile.maximumChunkTokens + 1)
    }

    /// The serving context re-derived while idle, on each keep-warm answer
    /// (`ClusterWorkerEvent.keptWarm`), with the reservation gate's own
    /// arithmetic: kept prefix entries are part of the charge they were
    /// allocated under. Nil (and nothing changes) while a lane is held, or for
    /// a row whose profile is its memory plan. Allocates nothing.
    public func refreshServingContext() -> Int? {
        guard servingContextTokens != nil, operation.try() else { return nil }
        defer { operation.unlock() }
        guard control.available, batchBook.isEmpty, model != nil else { return nil }
        let grown = max(0, Memory.activeMemory - batchAllocationBaseline)
        guard let value = try? Self.servingContext(requestCharge, admission: admission, grownBytes: grown) else {
            return nil
        }
        if value != servingContextTokens {
            log("darkbloom-serving-context-v1 rank=\(collective.rank) tokens=\(value) previous=\(servingContextTokens ?? 0)"
                + " grown=\(grown)")
        }
        servingContextTokens = value
        return value
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

    /// Capacity one reserves through the lane contract; a refusal there is
    /// this request's alone, named as the lane path names it (capacity or its
    /// own deadline), never `unsupported`.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard usesRequestOwnedSingleton else { throw ProbeError("Batched TP owners reserve through the lane contract") }
        do { return try reserveLane(requestID: requestID, request: value) }
        catch let refusal as ClusterResidentRequestRefusal { throw refusal }
        catch {
            let reason: ClusterWorkerRefusal = DispatchTime.now().uptimeNanoseconds >= value.deadlineUptimeNanoseconds
                ? .deadline : .capacity
            log("darkbloom-request-refused-v1 rank=\(collective.rank) reason=\(reason.rawValue)")
            throw ClusterResidentRequestRefusal(reason: reason, message: String(describing: error))
        }
    }

    public func releaseReservation(requestID: UUID) throws {
        guard usesRequestOwnedSingleton, withdrawLane(requestID: requestID) else {
            throw ProbeError("Singleton TP release has no matching unstarted lane")
        }
    }

    /// Every row's native batch path publishes raw selection logprobs, at
    /// capacity one as wider.
    public var capturesLogprobs: Bool { true }

    public func start(requestID: UUID, tokens channel: ClusterCommittedTokenChannel) throws -> QwenResidentGenerationCompletion {
        try startSingletonLane(requestID: requestID, channel: channel)
    }

    /// Only rank 0 invokes the callback, once both ranks hold the token.
    /// False requests an agreed clean stop; a thrown callback is a failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        try ClusterCommittedTokenChannel.answering(onCommittedToken) {
            try startSingletonLane(requestID: requestID, channel: $0)
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
        for reserved in batchBook.reservations() { reserved.media?.finishHostPreparation() }
        collective.logDataPlaneStatus()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    mtpHead = nil
                    try failedBatchDriver?.retireAll()
                    guard batchHost?.isDrained ?? true else { throw ProbeError("Qwen TP batch histories remain owned") }
                    for reserved in batchBook.reservations() { try reserved.media?.releaseAfterCheckedDrain() }
                    batchBook.clear(); failedBatchDriver = nil; batchHost = nil
                    // Records already queued for the SSD are finished first
                    // (bounded): they are what a restarted pair restores.
                    prefixDisk?.tier.close()
                    batchPrefix?.sweep(); mtpPrefix?.sweep()
                    weak var releasedVision = vision
                    vision = nil
                    guard releasedVision == nil else { throw ProbeError("Tensor-parallel vision model remains retained") }
                    weak var released: QwenTensorParallelModel?
                    released = model; model = nil
                    guard released == nil else { throw ProbeError("Tensor-parallel model remains retained") }
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit { if processLeaseOwned { control.fail() } }

    /// 64 bits of SHA-256 of `text`.
    static func digest64(_ text: String) -> UInt64 {
        let hex = sha256(Data(text.utf8))
        return UInt64(hex.prefix(16), radix: 16) ?? 0
    }
}
