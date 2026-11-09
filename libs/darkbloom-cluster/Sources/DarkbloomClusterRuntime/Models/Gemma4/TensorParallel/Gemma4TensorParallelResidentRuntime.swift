import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLMCommon

/// The worker's resident owner for `tensor_parallel_v1` on the registered
/// Gemma 4 26B rows: both ranks hold every layer, each with its half of every
/// head- and channel-parallel weight (`Gemma4TensorParallelPlan`), run every
/// prompt chunk and decode step together, and sum each layer's attention
/// partial and its one packed feed-forward collective (FP32 partials,
/// `ClusterTensorParallelTerms.current`) with the sealed all-sum inside the
/// lazy graph, under the session's keyed data plane.
///
/// The same executor contract as `GLM5NextTensorParallelResidentRuntime`:
/// one request at a time, cancel from the control thread, an enclosing
/// process deadline required; or, loaded with batch lanes (`lanes`, from
/// `DARKBLOOM_CLUSTER_BATCH_LANES`), several requests at once through the
/// shared batch driver (`Gemma4TensorParallelLanes.swift`). Each request's
/// keys and values live in this rank's paged KV host, its own heads of every
/// layer (`Gemma4TensorParallelPagedSession`); pages grow with the request.
///
/// Every step's token is agreed inside the step's own evaluation
/// (`Gemma4TensorParallelChoice`): the vocabulary-split argmax for greedy
/// requests, carrying both ranks' stop flags; for sampled ones the whole row
/// gathered to every rank and rank 0's draw with the product's sampler. A
/// stop on either rank (cancel, deadline, memory, the owner's stop, pages
/// that could not grow) ends both after the same step. Logprobs: a greedy
/// request's from the vocabulary-split top-k gather, a sampled one's from the
/// product's sampler on rank 0.
///
/// Prompt prefixes are kept as the Gemma pipeline keeps them, resident and on
/// the owner's encrypted SSD tier, each rank its own heads; a request
/// restores the deepest boundary both ranks hold after a sealed vote and
/// confirmation, or neither does (`Gemma4TensorParallelPrefix`).
///
/// Limits: the profile is the model's native context (262,144 tokens,
/// `Gemma4ResidentAdmission.profile`); LOAD quotes the memory plan's request
/// (`memoryProfile`), and a longer request is charged at its own context when
/// it is reserved (`Gemma4TensorParallelRequestCharge`). READY and every
/// keep-warm answer carry the longest context the gate admits now.
///
/// Not yet: speculative decoding and media.
public final class Gemma4TensorParallelResidentRuntime {
    static let planName = Gemma4TensorParallelPlan.name
    /// Bytes the worker keeps for MLX's freed-buffer cache once ready under
    /// the product's `disableFreedBufferCache` policy (as Qwen tensor parallel).
    static var freedBufferCacheBytes: Int {
        QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes)
    }

    let admission: Gemma4ResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let group: QwenTensorParallelGroup
    let codec: QwenTensorParallelSealCodec
    let lifecycle = QwenLayerStageResidentLifecycle()
    let loadAgreement: String
    let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    var model: Gemma4TensorParallelModel?
    var host: CBv2StageKVHost?
    private let baseReady: ClusterWorkerReady
    private var reservation: Reserved?
    private var processLeaseOwned = true
    public let linkProbe: ClusterWorkerLinkProbe?
    public let shareProbe: ClusterWorkerShareProbe?
    /// Requests served at once (bound into the load agreement); one serves
    /// one request at a time through `reserve` and `start`.
    public let lanes: Int
    /// Batch lanes: every reserved, started and running lane on this rank.
    let laneBook = ClusterBatchLaneBook<Gemma4TensorParallelLaneReservation>()
    /// True while the batch driver runs on the executor.
    var batchServing = false
    var batchOrdinal: UInt64 = 0
    /// A failed batch's driver, kept until shutdown's checked drain.
    var failedLaneDriver: QwenTensorParallelBatchDriver<Gemma4TensorParallelBatchExecutor<Gemma4TensorParallelLaneReservation>>?
    /// Raw-token logprobs are published for every request that asks for them.
    public var capturesLogprobs: Bool { true }
    /// This rank's prompt prefixes, in memory and on its SSD tier.
    let prefix: Gemma4TensorParallelPrefix
    /// What a request costs this rank at its own context: READY's capacity
    /// covers the profile's longest, and the serving context is its gate's.
    let requestCharge: Gemma4TensorParallelRequestCharge
    /// The longest context this rank's gate admits now (READY, then each
    /// keep-warm answer: `refreshServingContext`); nil while the profile is
    /// the memory plan.
    private(set) var servingContextTokens: Int?

    struct Reserved {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64
        /// What this request's prefix capture may hold (0: none).
        var prefixCaptureLimit = 0
    }

    // MARK: - Load

    /// Whether a registered row is a Gemma 4 artifact, whose tensor-parallel
    /// loads this runtime owns (its catalog family is the layer-stage one).
    public static func serves(runtimeModelID: String) -> Bool {
        (try? Gemma4RegisteredSpecification.registered(runtimeModelID: runtimeModelID)) != nil
    }

    /// `prefixSSDKey`: the 32-byte key of this rank's prompt-prefix SSD tier,
    /// as the owner sent it on the worker's input; nil keeps the tier off.
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential,
                            prefixSSDKey: Data? = nil) throws -> Gemma4TensorParallelResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        let kvQuantization = try PagedKVQuantizationSelection.clusterLive(environment)
        try kvQuantization.requireNative("Gemma tensor parallel, whose paged KV stays native until it is qualified")
        let kv = try ClusterStageKVBackendKind.fromEnvironment(environment)
        let lanes = try QwenBatchSettings.fromEnvironment(environment).lanes
        // Prompt prefixes, unless the diagnosis switch turns them off on this
        // rank (`DARKBLOOM_CLUSTER_PREFIX_CACHE=off`): bound into the agreement,
        // so both ranks keep them or neither does. Gemma records stay native.
        let prefixCache = QwenStagePrefixCache.fromEnvironment(environment)
        let keepsPrefixes = Gemma4ResidentAdapterDefinition.tensorParallelKeepsPromptPrefixes && prefixCache.enabled
        let prefixRecords = try QwenStagePrefixDiskEncoding.fromEnvironment(environment, family: .native)
        let directory = configuration.modelDirectory
        let any = try LayerStageResidentFamily.admission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        guard let admission = any as? Gemma4ResidentAdmission,
              admission.supportedGenerationModes.contains(.tensorParallel) else {
            throw ProbeError("Generation mode tensor_parallel_v1 is not in the resident row of \(any.runtimeModelID)")
        }
        guard configuration.prefillSchedule == .serial else {
            throw ProbeError("Gemma tensor parallel prefills every chunk together: the serial schedule only")
        }
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loadedModel: Gemma4TensorParallelModel?
        var loadedHost: CBv2StageKVHost?
        weak var retired: Gemma4TensorParallelModel?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            let read: (URL, Int) throws -> Data = { try BoundedProbeInput.data($0, maximumBytes: $1) }
            try admission.jaccl.requireUnchanged(environment: environment, read: read)
            let collective = try Collective(transport: .jaccl)
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size,
                transport: collective.transport)
            let terms = Gemma4TensorParallelLoadAgreement(lanes: lanes, kv: kv, kvQuantization: kvQuantization,
                prefixCache: keepsPrefixes)
            let loadAgreement = try terms.fingerprint(admission: try admission.loadAgreementFingerprint())
            try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                loadAgreement: loadAgreement, tamper: nil, tensorParallelSeal: true, check: { try control.check() })
            guard collective.workerDataPlane?.peerVerified == true else {
                throw ProbeError("Gemma tensor parallel requires an authenticated peer")
            }
            let group = try QwenTensorParallelGroup(collective: collective)
            let codec = try QwenTensorParallelSealCodec.product(collective: collective, scope: Data(loadAgreement.utf8))
            try codec.install()
            group.sealed = codec
            // The shard reduces through the group, except while the share probe times it alone.
            let reduction = QwenTensorParallelSwitchableReduction(group)
            let profile = admission.profile
            let charge = try Gemma4TensorParallelRequestCharge(profile: profile, memory: admission.memoryProfile,
                keepsPrefixes: keepsPrefixes, allocationBound: QwenResidentResourceEnvironment.allocationBound)
            var probe: ClusterWorkerLinkProbe?
            var receipt: Gemma4TensorParallelShardReceipt?
            var prefixCharges = (capture: 0, room: 0)
            let capacity = try MLX.withError { nativeError -> Int in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                    disagreementMessage: "Gemma tensor-parallel load membership/source/plan/terms differ",
                    scope: .session(.loadAgreement, "gemma4-tensor-parallel-load-intent"), check: checked)
                // The link as this mode uses it, before any weight is read.
                let measured = try QwenTensorParallelLinkProbe.measure(collective: collective, group: group,
                    hiddenSize: profile.hiddenSize, chunkTokens: profile.maximumChunkTokens, check: checked)
                probe = measured
                log(QwenTensorParallelLinkProbe.line(measured, rank: collective.rank))
                // The load gate admits the shard with the memory plan's longest request (its prompt-prefix
                // capture included) for every lane and the rank's own reserve (activation floor, freed-buffer
                // cache, sealed frames) once beside it: the planner's quote of this width. A longer request is
                // charged at its own context when it is reserved.
                let budget = try charge.memoryPlan
                let reserved = try budget.reservedBytes(lanes: lanes)
                let value = try autoreleasepool {
                    try Gemma4TensorParallelVerifiedLoad.load(admission, rank: collective.rank, reduction: reduction,
                        additionalResidentBytes: reserved, check: checked)
                }
                loadedModel = value.model; retired = value.model; receipt = value.receipt
                value.model.model.freeze()
                // Every request's keys and values live in this rank's paged
                // host, bounded by the profile's longest request (a ceiling,
                // not an allocation: each request's pages grow with it).
                loadedHost = try value.model.pagedHost(lanes: lanes, maximumTokens: profile.maximumContextTokens,
                    chunkTokens: profile.maximumChunkTokens, quantization: kvQuantization)
                loadedHost?.report("gemma4_tensor_parallel")
                let loadedIdentity = sha256(try canonicalJSONData([loadAgreement, value.receipt.verifiedAggregateSHA256,
                    value.receipt.storageCommitmentSHA256, planName]))
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                    disagreementMessage: "Gemma tensor-parallel peers did not load matching verified commitments",
                    scope: .session(.loadedReady, "gemma4-tensor-parallel-loaded"), check: checked)
                try configuration.allocatorPolicy.prepareReady(
                    synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                    snapshot: {
                        let s = Memory.snapshot()
                        return .init(activeBytes: s.activeMemory, cachedBytes: s.cacheMemory, peakBytes: s.peakMemory)
                    }, clearCache: { Memory.clearCache() }, check: checked)
                let bufferCacheBytes = configuration.allocatorPolicy == .disableFreedBufferCache
                    ? freedBufferCacheBytes : Memory.cacheLimit
                if configuration.allocatorPolicy == .disableFreedBufferCache {
                    Memory.cacheLimit = bufferCacheBytes
                    try checked()
                }
                // The prefix memory tier, charged nowhere: the pipeline's budget,
                // half the admissible room measured beside what LOAD reserved,
                // the longest request of every lane and this rank's reserve (at
                // most `maximumBudgetBytes`).
                if keepsPrefixes {
                    let room = try ClusterStagePrefixBudget.roomBytes(chargeBytes: reserved)
                    prefixCache.setBudget(QwenStagePrefixCache.budget(roomBytes: room))
                    prefixCharges = (budget.prefixCaptureBytes, room)
                }
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(planName) shares=1-1"
                    + " shard_bytes=\(value.receipt.shardBytes) source_bytes=\(value.receipt.sourceBytes)"
                    + " tensors=\(value.receipt.sourceTensors) load_ns=\(value.receipt.loadNanoseconds) sealed=1"
                    + " buffer_cache=\(bufferCacheBytes) lanes=\(lanes) reserved=\(reserved) paged_kv=\(CBv2PagedDefaults.pageSize)"
                    + " kv_heads=\(value.model.plan.kvHeadsPerRank.map(String.init).joined(separator: "-"))")
                // A ceiling on additional owner bytes, never a memory grant: LOAD's quote, or one
                // request at the profile's longest context when that is more.
                return try charge.capacityBytes
            }
            guard let model = loadedModel, let host = loadedHost, let receipt else {
                throw ProbeError("Gemma tensor-parallel load returned no shard")
            }
            // This rank's own share, timed alone before its ready record.
            let shareProbe = try Gemma4TensorParallelShareProbe.measure(model: model, reduction: reduction, profile: profile,
                deadline: control.deadline, admit: { tokens, chunk in
                    try QwenTensorParallelShareProbe.memoryAdmits(bytes: charge.budget(contextTokens: tokens,
                        chunkTokens: chunk, keepsPrefixes: false).requestBytes)
                }, check: { try control.check() })
            if let shareProbe { log(QwenTensorParallelShareProbe.line(shareProbe, rank: collective.rank)) }
            try control.loaded()
            // The prefix cache's SSD tier, when the owner configured one: this
            // rank's records of this artifact, plan and both builds, which a
            // restarted pair finds again. Opening it sweeps the directories of
            // other plans under the root that hold no live record.
            let identity = admission.configuration.identity
            let diskPlanScope = Gemma4TensorParallelPrefix.planScope(admission: admission,
                aggregateSHA256: receipt.verifiedAggregateSHA256, storageCommitmentSHA256: receipt.storageCommitmentSHA256)
            if keepsPrefixes {
                prefixCache.disk = QwenStagePrefixDiskTier.open(configuration: .fromEnvironment(environment, key: prefixSSDKey),
                    planScope: diskPlanScope, rank: collective.rank, encoding: prefixRecords,
                    stagingEpoch: identity.membershipEpoch.uuidString.lowercased())
            }
            log("darkbloom-prefix-v1 rank=\(collective.rank) family=gemma4 mode=tensor_parallel enabled=\(keepsPrefixes)"
                + " budget_bytes=\(keepsPrefixes ? prefixCache.budgetBytes : 0) capture_charge=\(prefixCharges.capture)"
                + " room_bytes=\(prefixCharges.room) ssd=\(prefixCache.disk != nil)")
            let prefix = Gemma4TensorParallelPrefix(cache: keepsPrefixes ? prefixCache : QwenStagePrefixCache(enabled: false),
                load: loadAgreement, diskPlanScope: diskPlanScope)
            // The longest context the reservation gate admits now, beside the
            // loaded shard (local: no collective).
            let serving = try charge.servingContextTokens(reclaimableBytes: 0,
                on: QwenDenseStageLoadResources.observeOS(), now: DispatchTime.now().uptimeNanoseconds)
            if let serving {
                log("darkbloom-serving-context-v1 rank=\(collective.rank) family=gemma4 tokens=\(serving) previous=0"
                    + " profile=\(profile.maximumContextTokens) memory_plan=\(admission.memoryProfile.maximumContextTokens)")
            }
            return Gemma4TensorParallelResidentRuntime(admission: admission, control: control, collective: collective,
                group: group, codec: codec, model: model, host: host, loadAgreement: loadAgreement, capacity: capacity,
                linkProbe: probe, shareProbe: shareProbe, lanes: lanes, prefix: prefix, requestCharge: charge,
                servingContextTokens: serving)
        } catch {
            let primary = error
            control.fail(); loadedHost = nil; loadedModel = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil else { throw ProbeError("Gemma tensor-parallel failed-load shard remains retained") }
            } catch {
                throw ProbeError("Gemma tensor-parallel load failed (\(primary)); local cleanup failed (\(error))")
            }
            throw primary
        }
    }

    /// What the live gate asks for beside every held request: the rank's
    /// activation floor, freed-buffer cache and sealed frames, as LOAD quoted them.
    var rankReserveBytes: Int {
        get throws { try requestCharge.memoryPlan.rankBytes }
    }

    /// A request's charge on this rank, at its own context with its own
    /// prompt's prefix capture (none when its cache is off: it neither
    /// restores nor captures), what that capture may hold
    /// (`Gemma4TensorParallelPrefix.captureLimit`, at least the charged part)
    /// and the part beyond the charge: kept entries give way before the live
    /// gate refuses that part, and a capture the gate still refuses is cut to
    /// its charged part.
    func prefixCharge(_ request: QwenLayerStageGenerationRequest) throws -> (charge: Int, captureLimit: Int, beyond: Int) {
        let budget = try requestCharge.budget(contextTokens: request.maximumTokens, chunkTokens: request.chunkSize,
            promptTokens: request.promptCount, keepsPrefixes: prefix.scopes(request) != nil)
        let limit = prefix.captureLimit(request, chargedBytes: budget.prefixCaptureBytes)
        return (budget.requestBytes, limit, max(0, limit - budget.prefixCaptureBytes))
    }

    /// The host memory gate's decision for `bytes` more, as the resident
    /// families take it; a memory refusal is typed (`ClusterLiveMemory`).
    static func requireLiveMemory(bytes: Int) throws {
        try ClusterLiveMemory.requireTensorParallel(bytes: bytes, family: "Gemma")
    }

    private init(admission: Gemma4ResidentAdmission, control: QwenResidentControl, collective: Collective,
                 group: QwenTensorParallelGroup, codec: QwenTensorParallelSealCodec, model: Gemma4TensorParallelModel,
                 host: CBv2StageKVHost, loadAgreement: String, capacity: Int, linkProbe: ClusterWorkerLinkProbe?,
                 shareProbe: ClusterWorkerShareProbe?, lanes: Int, prefix: Gemma4TensorParallelPrefix,
                 requestCharge: Gemma4TensorParallelRequestCharge, servingContextTokens: Int?) {
        self.admission = admission; self.control = control; self.collective = collective; self.group = group
        self.codec = codec; self.model = model; self.host = host; self.loadAgreement = loadAgreement
        self.linkProbe = linkProbe; self.shareProbe = shareProbe; self.lanes = lanes; self.prefix = prefix
        self.requestCharge = requestCharge; self.servingContextTokens = servingContextTokens
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane,
            servingContextTokens: servingContextTokens, linkProbe: linkProbe, shareProbe: shareProbe)
    }

    /// The serving context re-derived while idle, on each keep-warm answer
    /// (`ClusterWorkerEvent.keptWarm`), with the reservation gate's own
    /// arithmetic: kept prefix entries count as room, since they give way to
    /// a reservation. Nil (and nothing changes) while a request or lane is
    /// held, when the host cannot be judged now, or while the profile is the
    /// memory plan. Allocates nothing.
    public func refreshServingContext() -> Int? {
        guard servingContextTokens != nil, operation.try() else { return nil }
        defer { operation.unlock() }
        guard control.available, reservation == nil, laneBook.isEmpty, model != nil else { return nil }
        let held = prefix.cache.bytesInUse
        guard let os = try? QwenDenseStageLoadResources.observeOS(),
              let value = try? requestCharge.servingContextTokens(reclaimableBytes: held, on: os,
                  now: DispatchTime.now().uptimeNanoseconds) else { return nil }
        if value != servingContextTokens {
            log("darkbloom-serving-context-v1 rank=\(collective.rank) family=gemma4 tokens=\(value)"
                + " previous=\(servingContextTokens ?? 0) reclaimable=\(held)")
        }
        servingContextTokens = value
        return value
    }

    // MARK: - Owner interface

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
        guard control.available else { throw ProbeError("A data-plane ping needs an idle resident owner") }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard lanes == 1 else { throw ProbeError("Batched Gemma tensor-parallel owners reserve through the lane contract") }
        let now = DispatchTime.now().uptimeNanoseconds
        guard value.stillImages == nil, value.mimoImages == nil, value.glmMedia == nil else {
            throw ProbeError("Gemma tensor parallel serves text requests only")
        }
        let request = try admission.request(value, id: requestID, now: now)
        // Charged at its own context: the live gate alone decides whether it fits.
        let priced = try prefixCharge(request)
        let charge = priced.charge
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard model != nil, host != nil else { throw ProbeError("Resident model already released") }
            guard charge <= value.capacityLimitBytes else {
                throw ProbeError("Gemma tensor-parallel reservation exceeds its owner or readiness capacity")
            }
            ClusterIdleMemory.releaseFreedBuffers()
            let captureLimit = try admitCapture(priced, held: [charge, rankReserveBytes])
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, deadline: value.deadlineUptimeNanoseconds, prefixCaptureLimit: captureLimit)
            return charge
        }
    }

    /// The live gate for a request priced as `prefixCharge` beside `held`
    /// bytes: kept prefix entries give way first; a capture beyond its
    /// charged part that still does not fit is cut to that part. Returns the
    /// capture limit admitted.
    func admitCapture(_ priced: (charge: Int, captureLimit: Int, beyond: Int), held: [Int]) throws -> Int {
        let base = try QwenLongPrefillCheckedBytes.sum(held)
        if priced.beyond > 0 {
            do {
                try prefix.cache.yieldingMemory {
                    try Self.requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([base, priced.beyond]))
                }
                return priced.captureLimit
            } catch {
                log("darkbloom-prefix-v1 rank=\(collective.rank) family=gemma4 capture-cut bytes=\(priced.beyond): \(error)")
            }
        }
        try prefix.cache.yieldingMemory { try Self.requireLiveMemory(bytes: base) }
        return priced.captureLimit - priced.beyond
    }

    public func releaseReservation(requestID: UUID) throws {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("Resident release has no matching unstarted reservation")
        }
        reservation = nil
    }

    /// Only rank 0 invokes the callback, once both ranks hold the token.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        try ClusterCommittedTokenChannel.answering(onCommittedToken) { try start(requestID: requestID, tokens: $0) }
    }

    /// As `start(requestID:onCommittedToken:)`, with the owner's answer to each
    /// token read after the next step ran: the answer's round trip through the
    /// owner overlaps the step.
    public func start(requestID: UUID, tokens channel: ClusterCommittedTokenChannel) throws
        -> QwenResidentGenerationCompletion {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        do {
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID, recordedRequestFingerprint: reserved.request.fingerprint),
                deadline: reserved.deadline, body: {
                    try autoreleasepool { try generate(reserved, channel: channel) }
                }, prepare: { $0 })
            collective.logDataPlaneStatus()
            reservation = nil
            return value
        } catch {
            // The peer may hold something else now.
            prefix.cache.sweep()
            control.fail(); throw error
        }
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    /// Gives back what this idle rank holds beyond its weights
    /// (`ClusterIdleMemory`): MLX's freed-buffer cache, and the prompt-prefix
    /// entries too while the host is `underPressure` (the vote then restores
    /// nothing until both ranks hold a boundary again). Nothing while a
    /// request or any batch lane is reserved, started or running.
    public func releaseIdleMemory(underPressure: Bool) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available, reservation == nil, laneBook.isEmpty, model != nil else { return 0 }
        let held = prefix.cache.bytesInUse, entries = prefix.cache.count
        if underPressure { prefix.cache.sweep() }
        let released = ClusterIdleMemory.releaseFreedBuffers()
        if underPressure, entries > 0 {
            log("darkbloom-idle-release-v1 rank=\(collective.rank) family=gemma4 prefix_entries_dropped=\(entries)"
                + " prefix_bytes_dropped=\(held) freed_buffer_bytes=\(released)")
        }
        return released
    }

    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        collective.logDataPlaneStatus()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    try failedLaneDriver?.retireAll()
                    guard host?.isDrained ?? true else { throw ProbeError("Gemma tensor-parallel request state remains owned") }
                    // Records already queued for the SSD are finished first
                    // (bounded): they are what a restarted pair restores.
                    prefix.disk?.close()
                    prefix.cache.sweep()
                    reservation = nil; laneBook.clear(); failedLaneDriver = nil; host = nil
                    weak var released: Gemma4TensorParallelModel?
                    released = model; model = nil
                    guard released == nil else { throw ProbeError("Gemma tensor-parallel shard remains retained") }
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit { if processLeaseOwned { control.fail() } }

    // MARK: - One request

    private func generate(_ reserved: Reserved, channel: ClusterCommittedTokenChannel) throws
        -> QwenResidentGenerationCompletion {
        guard let model, let host else { throw ProbeError("Resident model already released") }
        let request = reserved.request
        guard try group.digestsEqual(QwenTensorParallelResidentRuntime.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("Gemma tensor-parallel ranks were given different requests")
        }
        // Prompt prefix: the deepest boundary both ranks hold, voted and confirmed (or none).
        let session = try MLX.withError { error -> Gemma4TensorParallelPagedSession in
            let value = try prefix.open(request, model: model, host: host, group: group,
                captureLimit: reserved.prefixCaptureLimit, stop: { [control] in
                    (try? control.check(deadline: reserved.deadline)) == nil
                })
            try error.check()
            return value
        }
        do {
            // A step checks native errors only: a cancel or deadline must not
            // end one rank between two collectives (its peer would wait in the
            // next one), so it rides in the next step's flags (`localStop`).
            var completion = try MLX.withError { error in
                try serve(request, session: session, deadline: reserved.deadline, channel: channel,
                    checked: { try error.check() })
            }
            if completion.abort != nil {
                // Both ranks ended it alone for a rank's memory (D6): nothing
                // of it is kept, its pages go back, and the pair serves on.
                session.prefixCapture?.withdraw()
                try session.retire()
                Memory.clearCache()
                return completion
            }
            try session.retire()
            // Both ranks ended after the same step and agreed how: the prompt's
            // capture becomes reusable now, in memory and behind serving on SSD.
            if let capture = session.prefixCapture, let scopes = prefix.scopes(request) {
                completion.storedPromptFrontiers = prefix.store(capture, request: request, scopes: scopes, rank: collective.rank)
            }
            completion.reusedPromptTokens = session.reusedPrefixTokens
            return completion
        } catch {
            session.prefixCapture?.withdraw()
            try? session.retire(failed: true)
            throw error
        }
    }

    /// The request's prompt and decode through `Gemma4TensorParallelRequestLoop`
    /// on this rank: the pair's agreed tokens and finish.
    private func serve(_ request: QwenLayerStageGenerationRequest, session: Gemma4TensorParallelPagedSession,
                       deadline: UInt64, channel: ClusterCommittedTokenChannel,
                       checked: () throws -> Void) throws -> QwenResidentGenerationCompletion {
        let rank = collective.rank, prompt = request.promptTokenIDs
        let choice = Gemma4TensorParallelChoice(selection: session.model.selection, sampler: request.sampler, rank: rank)
        var lastCheck: UInt64 = 0
        // This rank's stop was its live memory check's refusal (D6).
        var stoppedForMemory = false
        var loop = Gemma4TensorParallelRequestLoop(session: session, request: request, choice: choice,
            exchange: { [group] in try group.exchangeIntegers($0) }, localStop: { [control, prefix] in
                if (try? control.check(deadline: deadline)) == nil { return true }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastCheck >= 250_000_000 {
                    lastCheck = now
                    // Kept prefixes give way first, then the request's own capture.
                    do { try prefix.cache.yieldingMemory({ try Self.requireLiveMemory(bytes: 0) }) } catch {
                        guard let capture = session.prefixCapture, !capture.withdrawn else {
                            stoppedForMemory = error is QwenResidentMemoryRefusal
                            return true
                        }
                        capture.withdraw(); Memory.clearCache()
                        do { try Self.requireLiveMemory(bytes: 0) } catch {
                            stoppedForMemory = error is QwenResidentMemoryRefusal
                            return true
                        }
                    }
                }
                return false
            })
        loop.stoppedForMemory = { stoppedForMemory }
        let ended = try loop.run(channel: channel, check: checked)
        if let abort = ended.abort {
            return .aborted(requestID: request.requestID, abort: abort,
                message: "Gemma tensor parallel: rank \(abort.rank)'s memory refused the request while it ran", rank: rank)
        }
        let tokens = ended.tokens, finish = ended.finish
        try control.check(deadline: deadline)
        if finish == .clientStop && !ended.clientStopped && rank == 0 {
            throw ProbeError("The peer rank stopped the Gemma tensor-parallel request")
        }
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) family=gemma4 request=\(request.requestID.uuidString.lowercased())"
            + " prompt=\(prompt.count) output=\(tokens.count) finish=\(finish.rawValue) sampled=\(choice.gathersRow ? 1 : 0)"
            + " logprobs=\(request.sampler?.wire.capturedLogprobs ?? 0) frames=\(codec.sealedFrames)"
            + " key_generation=\(codec.keyGeneration) kv_tokens=\(session.state.reservedTokens)"
            + " kv_refused=\(ended.pagesRefused ? 1 : 0) reused=\(session.reusedPrefixTokens)")
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true)
    }
}
