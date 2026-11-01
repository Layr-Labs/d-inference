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
/// Not yet: prompt prefixes, speculative decoding and media.
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

    struct Reserved {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64
    }

    // MARK: - Load

    /// Whether a registered row is a Gemma 4 artifact, whose tensor-parallel
    /// loads this runtime owns (its catalog family is the layer-stage one).
    public static func serves(runtimeModelID: String) -> Bool {
        (try? Gemma4RegisteredSpecification.registered(runtimeModelID: runtimeModelID)) != nil
    }

    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential) throws -> Gemma4TensorParallelResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        let kvQuantization = try PagedKVQuantizationSelection.clusterLive(environment)
        try kvQuantization.requireNative("Gemma tensor parallel, whose paged KV stays native until it is qualified")
        let kv = try ClusterStageKVBackendKind.fromEnvironment(environment)
        let lanes = try QwenBatchSettings.fromEnvironment(environment).lanes
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
            let terms = Gemma4TensorParallelLoadAgreement(lanes: lanes, kv: kv, kvQuantization: kvQuantization, prefixCache: false)
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
            var probe: ClusterWorkerLinkProbe?
            var receipt: Gemma4TensorParallelShardReceipt?
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
                // The load gate admits the shard with the profile's longest request beside it.
                let request = try requestChargeBytes(contextTokens: profile.maximumContextTokens, admission: admission)
                let value = try autoreleasepool {
                    try Gemma4TensorParallelVerifiedLoad.load(admission, rank: collective.rank, reduction: reduction,
                        additionalResidentBytes: request, check: checked)
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
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(planName) shares=1-1"
                    + " shard_bytes=\(value.receipt.shardBytes) source_bytes=\(value.receipt.sourceBytes)"
                    + " tensors=\(value.receipt.sourceTensors) load_ns=\(value.receipt.loadNanoseconds) sealed=1"
                    + " buffer_cache=\(bufferCacheBytes) lanes=\(lanes) paged_kv=\(CBv2PagedDefaults.pageSize)"
                    + " kv_heads=\(value.model.plan.kvHeadsPerRank.map(String.init).joined(separator: "-"))")
                return request
            }
            guard let model = loadedModel, let host = loadedHost, receipt != nil else {
                throw ProbeError("Gemma tensor-parallel load returned no shard")
            }
            // This rank's own share, timed alone before its ready record.
            let shareProbe = try Gemma4TensorParallelShareProbe.measure(model: model, reduction: reduction, profile: profile,
                deadline: control.deadline, admit: { tokens, chunk in
                    try QwenTensorParallelShareProbe.memoryAdmits(bytes: requestChargeBytes(contextTokens: tokens,
                        admission: admission, chunkTokens: chunk))
                }, check: { try control.check() })
            if let shareProbe { log(QwenTensorParallelShareProbe.line(shareProbe, rank: collective.rank)) }
            try control.loaded()
            return Gemma4TensorParallelResidentRuntime(admission: admission, control: control, collective: collective,
                group: group, codec: codec, model: model, host: host, loadAgreement: loadAgreement, capacity: capacity,
                linkProbe: probe, shareProbe: shareProbe, lanes: lanes)
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

    /// What one request of `contextTokens` costs a rank, conservatively: the
    /// whole model's request state (`Gemma4StateBudget`, every head of every
    /// layer, though a rank keeps half the heads) at the allocator's bound,
    /// one prompt chunk's attention transient over every layer, and the
    /// chunk's FP32 partials and packed feed-forward rows as sealed frames.
    static func requestChargeBytes(contextTokens: Int, admission: Gemma4ResidentAdmission,
                                   chunkTokens: Int? = nil) throws -> Int {
        let chunk = min(contextTokens, chunkTokens ?? admission.profile.maximumChunkTokens)
        let bound = QwenResidentResourceEnvironment.allocationBound
        let state = try Gemma4StateBudget.estimate(maximumTokens: contextTokens, chunkSize: chunk).allowance(bound: bound)
        let transient = try Gemma4PrefillTransient.bytes(layers: admission.plan.stages.flatMap(\.layers),
            chunkTokens: chunk, contextTokens: contextTokens)
        // Attention partial and the packed rows (top-8 experts and the dense
        // branch) per token, FP32; the sum's output and two sealed frames each.
        let partials = try QwenLongPrefillCheckedBytes.product([chunk, Gemma4StageGeometry.hiddenSize * 4, 1 + 8 + 1, 4])
        return try QwenLongPrefillCheckedBytes.sum([state.reservedBytes, transient == 0 ? 0 : bound(transient), partials])
    }

    /// The host memory gate's decision for `bytes` more, as the resident families take it.
    static func requireLiveMemory(bytes: Int) throws {
        try QwenResidentResourceEnvironment.require()
        let watch = QwenDenseStageLoadWatch("Gemma tensor-parallel")
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([bytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        guard try watch.admits(os, bytes: free) else {
            throw ProbeError("Gemma tensor parallel needs \(bytes) bytes the memory gate does not admit now")
        }
    }

    private init(admission: Gemma4ResidentAdmission, control: QwenResidentControl, collective: Collective,
                 group: QwenTensorParallelGroup, codec: QwenTensorParallelSealCodec, model: Gemma4TensorParallelModel,
                 host: CBv2StageKVHost, loadAgreement: String, capacity: Int, linkProbe: ClusterWorkerLinkProbe?,
                 shareProbe: ClusterWorkerShareProbe?, lanes: Int) {
        self.admission = admission; self.control = control; self.collective = collective; self.group = group
        self.codec = codec; self.model = model; self.host = host; self.loadAgreement = loadAgreement
        self.linkProbe = linkProbe; self.shareProbe = shareProbe; self.lanes = lanes
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane, linkProbe: linkProbe,
            shareProbe: shareProbe)
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
        let charge = try Self.requestChargeBytes(contextTokens: request.maximumTokens, admission: admission,
            chunkTokens: request.chunkSize)
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard model != nil, host != nil else { throw ProbeError("Resident model already released") }
            guard charge <= value.capacityLimitBytes else {
                throw ProbeError("Gemma tensor-parallel reservation exceeds its owner or readiness capacity")
            }
            ClusterIdleMemory.releaseFreedBuffers()
            try Self.requireLiveMemory(bytes: charge)
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, deadline: value.deadlineUptimeNanoseconds)
            return charge
        }
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
            control.fail(); throw error
        }
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

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
        let request = reserved.request, rank = collective.rank
        guard try group.digestsEqual(QwenTensorParallelResidentRuntime.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("Gemma tensor-parallel ranks were given different requests")
        }
        let session = try Gemma4TensorParallelPagedSession(model: model, host: host,
            promptCount: request.promptTokenIDs.count, outputCount: request.outputCount)
        do {
            // A step checks native errors only: a cancel or deadline must not
            // end one rank between two collectives (its peer would wait in the
            // next one), so it rides in the next step's flags (`localStop`).
            let completion = try MLX.withError { error in
                try decode(request, session: session, deadline: reserved.deadline, channel: channel,
                    checked: { try error.check() })
            }
            try session.retire()
            return completion
        } catch {
            try? session.retire(failed: true)
            throw error
        }
    }

    /// The request through `Gemma4TensorParallelRequestLoop` on this rank:
    /// the pair's agreed tokens and finish.
    private func decode(_ request: QwenLayerStageGenerationRequest, session: Gemma4TensorParallelPagedSession,
                        deadline: UInt64, channel: ClusterCommittedTokenChannel,
                        checked: () throws -> Void) throws -> QwenResidentGenerationCompletion {
        let rank = collective.rank, prompt = request.promptTokenIDs
        let choice = Gemma4TensorParallelChoice(selection: session.model.selection, sampler: request.sampler, rank: rank)
        var lastCheck: UInt64 = 0
        let loop = Gemma4TensorParallelRequestLoop(session: session, request: request, choice: choice,
            exchange: { [group] in try group.exchangeIntegers($0) }, localStop: { [control] in
                if (try? control.check(deadline: deadline)) == nil { return true }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastCheck >= 250_000_000 {
                    lastCheck = now
                    if (try? Self.requireLiveMemory(bytes: 0)) == nil { return true }
                }
                return false
            })
        let ended = try loop.run(channel: channel, check: checked)
        let tokens = ended.tokens, finish = ended.finish
        try control.check(deadline: deadline)
        if finish == .clientStop && !ended.clientStopped && rank == 0 {
            throw ProbeError("The peer rank stopped the Gemma tensor-parallel request")
        }
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) family=gemma4 request=\(request.requestID.uuidString.lowercased())"
            + " prompt=\(prompt.count) output=\(tokens.count) finish=\(finish.rawValue) sampled=\(choice.gathersRow ? 1 : 0)"
            + " logprobs=\(request.sampler?.wire.capturedLogprobs ?? 0) frames=\(codec.sealedFrames)"
            + " key_generation=\(codec.keyGeneration) kv_tokens=\(session.state.reservedTokens)"
            + " kv_refused=\(ended.pagesRefused ? 1 : 0)")
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true)
    }
}
