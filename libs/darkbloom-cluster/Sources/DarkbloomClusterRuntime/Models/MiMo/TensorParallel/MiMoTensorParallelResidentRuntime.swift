import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM

/// The worker's resident owner for `tensor_parallel_v1` on the registered
/// MiMo V2.6 Flash text row (`MiMoTensorParallelPlan`): both ranks hold every
/// layer, each with half of every head- and channel-parallel weight and half
/// the vocabulary rows of the untied head, run every prefill chunk and decode
/// step together, and sum each layer's attention and feed-forward partials
/// with the sealed all-sum inside the lazy graph, under the session's keyed
/// data plane. Text only: the private image candidate stays a pipeline
/// candidate, and MTP stays off (no rank holds the trained heads).
///
/// The executor contract of `GLM5NextTensorParallelResidentRuntime`, one
/// lane: one request at a time, cancel from the control thread, an enclosing
/// process deadline required (a blocked collective cannot be interrupted
/// cooperatively); on any throw the owner withdraws this worker and fences its
/// peer.
///
/// Load: the load agreement (the plan's fingerprint and arithmetic contract,
/// the serving contract below, the mode, the data plane) is bound into the
/// keyed exchange and compared before anything is read; the link is measured
/// as this mode uses it (`QwenTensorParallelLinkProbe`); every artifact file
/// is hashed against the registered manifest, and then only this rank's byte
/// runs are read (`MiMoTensorParallelVerifiedLoad`); both ranks compare what
/// they loaded before either is ready.
///
/// Requests (`MiMoTensorParallelDecoding`): paged KV histories at this rank's
/// geometry, decode under 100-operation command buffers, one agreement sum
/// per step (the vocabulary-split argmax, or rank 0's draw from the gathered
/// row with the product's sampler, and both ranks' stop flags and
/// positions), logprobs from the split top-k gather (greedy rows) or the
/// product's own gather (sampled rows). No prompt-prefix reuse yet.
public final class MiMoTensorParallelResidentRuntime {
    /// What this owner keeps of the model's serving features, as the capability declares it
    /// (`MiMoResidentCapabilityMetadata.servingFeatures`): one lane and no prompt prefix (both bound below), no
    /// speculative rounds (no rank holds the trained heads), and committed-token logprobs.
    static let servingFeatures = ClusterServingFeatures(promptPrefixReuse: false, ssdPrefixTier: false,
        speculativeRounds: false, maximumLanes: 1, logprobs: true)

    /// Everything about serving both ranks must have been told the same,
    /// beside the plan: one lane, paged KV, the chunk grid, the selection
    /// rules and the decode command buffers.
    public static func servingAgreementFields(chunkTokens: Int) -> [String] {
        ["mimo-v26-tensor-parallel-serving-v1", "lanes=\(servingFeatures.maximumLanes)",
         "kv=paged-\(MiMoTensorParallelRequestBudget.pageTokens)", "chunk=\(chunkTokens)",
         "selection=split-argmax-agreement-gathered-row-rank0-draw-split-topk-logprobs-v1",
         "decode-buffers=\(MiMoTensorParallelDecoding.decodeCommandBuffers.operations)",
         servingFeatures.promptPrefixReuse ? "prefix=on" : "prefix=off"]
    }

    /// The load agreement's fields after the admission's fingerprint.
    static func loadAgreementFields(plan: MiMoTensorParallelPlan, chunkTokens: Int) -> [String] {
        ["mimo-v26-tensor-parallel-load-v1", MiMoTensorParallelPlan.name, plan.fingerprint]
            + MiMoTensorParallelPlan.arithmeticAgreementFields + servingAgreementFields(chunkTokens: chunkTokens)
            + ClusterGenerationMode.tensorParallel.loadAgreementFields + [QwenTensorParallelLinkProbe.loadAgreementField]
            + ClusterDataPlaneAgreement.loadAgreementFields
    }

    let admission: MiMoResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let group: QwenTensorParallelGroup
    let codec: QwenTensorParallelSealCodec?
    let lifecycle = QwenLayerStageResidentLifecycle()
    let loadAgreement: String
    let plan: MiMoTensorParallelPlan
    let slidingWindow: Int
    /// What the live gate asks for beside every held request: the rank's
    /// activation floor, freed-buffer cache and sealed frames.
    let rankReserveBytes: Int
    private let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    private var model: MiMoTensorParallelModel?
    private var residency: ClusterStageResidency?
    private let baseReady: ClusterWorkerReady
    private var reservation: Reserved?
    private var processLeaseOwned = true
    public let linkProbe: ClusterWorkerLinkProbe?

    private struct Reserved {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64
    }

    // MARK: - Load

    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential) throws -> MiMoTensorParallelResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        try requireTextLaunch(configuration, environment: environment)
        let directory = configuration.modelDirectory
        func read(_ url: URL, _ limit: Int) throws -> Data { try BoundedProbeInput.data(url, maximumBytes: limit) }
        let admission = try MiMoResidentAdmission(configuration: configuration,
            configBytes: read(directory.appendingPathComponent("config.json"), 1_048_576),
            manifestBytes: read(directory.appendingPathComponent("manifest.json"), 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds, read: read)
        guard admission.specification.supportedGenerationModes.contains(.tensorParallel) else {
            throw ProbeError("Generation mode tensor_parallel_v1 is not in the MiMo row")
        }
        let plan = try MiMoTensorParallelPlan(configuration: admission.configBytes)
        let decoded = try JSONDecoder().decode(MiMoV26Configuration.self, from: admission.configBytes)
        guard let window = decoded.slidingAttention.slidingWindow else {
            throw ProbeError("MiMo tensor parallel needs the sliding layers' window")
        }
        let profile = admission.profile
        // The rank's reserve at the profile's longest request: the planner's quote beside the shard.
        let budget = try requestBudget(plan: plan, slidingWindow: window, contextTokens: profile.maximumContextTokens,
                                       chunkTokens: profile.maximumChunkTokens)
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loaded: MiMoTensorParallelModel?
        weak var retired: MiMoTensorParallelModel?
        var residency: ClusterStageResidency?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            try admission.jaccl.requireUnchanged(environment: environment, read: read)
            let collective = try Collective(transport: .jaccl)
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size,
                                                   transport: collective.transport)
            let loadAgreement = sha256(try canonicalJSONData([try admission.loadAgreementFingerprint(
                mode: .tensorParallel, transport: collective.transport, residency: true, measuredGate: false)]
                + loadAgreementFields(plan: plan, chunkTokens: profile.maximumChunkTokens)))
            try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                loadAgreement: loadAgreement, tamper: nil, tensorParallelSeal: true, check: { try control.check() })
            guard collective.workerDataPlane?.peerVerified == true else {
                throw ProbeError("MiMo tensor parallel requires an authenticated peer")
            }
            let group = try QwenTensorParallelGroup(collective: collective)
            let codec = try QwenTensorParallelSealCodec.product(collective: collective, scope: Data(loadAgreement.utf8))
            try codec.install()
            group.sealed = codec
            var probe: ClusterWorkerLinkProbe?
            let started = DispatchTime.now().uptimeNanoseconds
            let requestReserve = budget.requestBytes
            let capacity = try MLX.withError { nativeError -> Int in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                let bufferCacheBytes = configuration.allocatorPolicy == .disableFreedBufferCache
                    ? MiMoTensorParallelRequestBudget.freedBufferCacheBytes : 0
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                    disagreementMessage: "MiMo tensor-parallel load membership/source/plan/contract differ",
                    scope: .session(.loadAgreement, "mimo-tensor-parallel-load-intent"), check: checked)
                // The link as this mode uses it, before any weight is read.
                let measured = try QwenTensorParallelLinkProbe.measure(collective: collective, group: group,
                    hiddenSize: plan.hiddenSize, chunkTokens: profile.maximumChunkTokens, check: checked)
                probe = measured
                log(QwenTensorParallelLinkProbe.line(measured, rank: collective.rank))
                // Every file of the artifact against the registered manifest, before any tensor is read.
                let source = try prepareMiMoResidentSource(directory: directory, configuration: admission.configBytes,
                    manifest: admission.manifestBytes, specification: admission.specification, plan: admission.plan,
                    check: checked)
                // The shard with the profile's longest request and the rank's own reserve (activation floor,
                // freed-buffer cache, sealed frames) beside it: the planner's quote. The read's largest slice
                // (half an expert bank) lives only while loading, inside the reserve no request holds yet.
                let shardBytes = try Self.shardBytes(plan: plan, descriptors: source.descriptors)
                try requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([shardBytes, budget.allowance.reservedBytes]))
                let value = try autoreleasepool {
                    try MiMoTensorParallelVerifiedLoad.load(checkpoint: source.checkpoint,
                        configurationData: admission.configBytes, role: .shard(rank: collective.rank), reduction: group,
                        beforeRead: { _, _ in try checked() }, check: checked)
                }
                loaded = value.model; retired = value.model
                guard value.receipt.verifiedAggregateSHA256 == admission.specification.artifactSHA256 else {
                    throw ProbeError("MiMo tensor-parallel shard was not read from the registered artifact")
                }
                Memory.clearCache()
                residency = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum([
                    Memory.activeMemory, requestReserve, bufferCacheBytes]))
                try configuration.allocatorPolicy.prepareReady(
                    synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                    snapshot: {
                        let s = Memory.snapshot()
                        return .init(activeBytes: s.activeMemory, cachedBytes: s.cacheMemory, peakBytes: s.peakMemory)
                    }, clearCache: { Memory.clearCache() }, check: checked)
                if bufferCacheBytes > 0 { Memory.cacheLimit = bufferCacheBytes; try checked() }
                let loadedIdentity = sha256(try canonicalJSONData([loadAgreement, value.receipt.verifiedAggregateSHA256,
                    value.receipt.planFingerprint, String(value.receipt.shardBytes), String(value.receipt.textTensors)]))
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                    disagreementMessage: "MiMo tensor-parallel peers did not load matching shards",
                    scope: .session(.loadedReady, "mimo-tensor-parallel-loaded"), check: checked)
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(MiMoTensorParallelPlan.name)"
                    + " shares=1-1 shard_bytes=\(value.receipt.shardBytes) read_bytes=\(value.receipt.readBytes)"
                    + " text_bytes=\(value.receipt.textBytes) tensors=\(value.receipt.textTensors)"
                    + " excluded=\(value.receipt.excludedTensors) load_ns=\(DispatchTime.now().uptimeNanoseconds - started)"
                    + " sealed=1 buffer_cache=\(bufferCacheBytes) wired_limit=\(residency?.receipt.appliedBytes ?? 0)"
                    + " lanes=1 paged_kv=\(MiMoTensorParallelRequestBudget.pageTokens) mtp=off")
                return requestReserve
            }
            guard let model = loaded else { throw ProbeError("MiMo tensor-parallel load returned no shard") }
            try control.loaded()
            return try MiMoTensorParallelResidentRuntime(admission: admission, control: control, collective: collective,
                group: group, codec: codec, model: model, residency: residency, plan: plan, slidingWindow: window,
                rankReserveBytes: budget.rankBytes, capacity: capacity, loadAgreement: loadAgreement, linkProbe: probe)
        } catch {
            let primary = error; control.fail(); loaded = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    try residency?.end(); residency = nil
                    Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil else { throw ProbeError("MiMo tensor-parallel failed-load model remains retained") }
            } catch {
                throw ProbeError("MiMo tensor-parallel load failed (\(primary)); local cleanup failed (\(error))")
            }
            throw primary
        }
    }

    /// Refused before anything is read or connected: the private image
    /// candidate (rank 0's vision tower stays a pipeline candidate), more than
    /// one batch lane, and any schedule but the serial one.
    static func requireTextLaunch(_ configuration: QwenResidentLoadConfiguration,
                                  environment: [String: String]) throws {
        guard configuration.runtimeProfile != ClusterMiMoImageCandidate.profileID else {
            throw ProbeError("MiMo tensor parallel serves text only; the image candidate is a pipeline candidate")
        }
        if let lanes = environment["DARKBLOOM_CLUSTER_BATCH_LANES"], lanes != "1" {
            throw ProbeError("MiMo tensor parallel serves one lane")
        }
        guard configuration.prefillSchedule == .serial else {
            throw ProbeError("MiMo tensor parallel prefills on the serial schedule")
        }
    }

    /// Bytes one rank holds of the text model: its half of every divided
    /// tensor, all of every replicated one; excluded components none.
    static func shardBytes(plan: MiMoTensorParallelPlan, descriptors: [String: TensorDescriptor]) throws -> Int {
        try descriptors.reduce(0) { total, entry in
            switch try plan.disposition(of: entry.key) {
            case .excluded: return total
            case .replicated: return try QwenLongPrefillCheckedBytes.sum([total, entry.value.byteCount])
            case .divided: return try QwenLongPrefillCheckedBytes.sum([total, entry.value.byteCount / plan.size])
            }
        }
    }

    /// This rank's reserve for requests of `contextTokens` (`MiMoTensorParallelRequestBudget`)
    /// at the allocator's own bound.
    static func requestBudget(plan: MiMoTensorParallelPlan, slidingWindow: Int, contextTokens: Int,
                              chunkTokens: Int) throws -> MiMoTensorParallelRequestBudget {
        try MiMoTensorParallelRequestBudget.derive(plan: plan, slidingWindow: slidingWindow, contextTokens: contextTokens,
            chunkTokens: chunkTokens, allocationBound: QwenResidentResourceEnvironment.allocationBound)
    }

    /// The host memory gate's decision for `bytes` more, as the resident families take it.
    static func requireLiveMemory(bytes: Int) throws {
        try QwenResidentResourceEnvironment.require()
        let watch = QwenDenseStageLoadWatch("MiMo tensor-parallel")
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([bytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        guard try watch.admits(os, bytes: free) else {
            throw ProbeError("MiMo tensor parallel needs \(bytes) bytes the memory gate does not admit now")
        }
    }

    private init(admission: MiMoResidentAdmission, control: QwenResidentControl, collective: Collective,
                 group: QwenTensorParallelGroup, codec: QwenTensorParallelSealCodec?, model: MiMoTensorParallelModel,
                 residency: ClusterStageResidency?, plan: MiMoTensorParallelPlan, slidingWindow: Int,
                 rankReserveBytes: Int, capacity: Int, loadAgreement: String, linkProbe: ClusterWorkerLinkProbe?) throws {
        self.admission = admission; self.control = control; self.collective = collective; self.group = group
        self.codec = codec; self.model = model; self.residency = residency
        self.plan = plan; self.slidingWindow = slidingWindow; self.rankReserveBytes = rankReserveBytes
        self.loadAgreement = loadAgreement; self.linkProbe = linkProbe
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane, linkProbe: linkProbe)
    }

    // MARK: - Owner interface

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    /// Every request's tokens carry their logprobs when it asks for them.
    public var capturesLogprobs: Bool { true }

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

    /// Text only: no route, media or images. Charged at the request's own
    /// context (`MiMoTensorParallelRequestBudget.requestBytes`); the live gate
    /// is asked for it and the rank's own reserve once.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard value.route == nil, value.stillImages == nil, value.mimoImages == nil, value.glmMedia == nil,
              value.qwenMedia == nil else {
            throw ProbeError("MiMo tensor parallel serves text requests only")
        }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        let charge = try Self.requestBudget(plan: plan, slidingWindow: slidingWindow, contextTokens: request.maximumTokens,
                                            chunkTokens: request.chunkSize).requestBytes
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard model != nil else { throw ProbeError("Resident model already released") }
            guard charge <= value.capacityLimitBytes, charge <= baseReady.requestCapacityBytes else {
                throw ProbeError("MiMo tensor-parallel reservation exceeds its owner or readiness capacity")
            }
            try Self.requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([charge, rankReserveBytes]))
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
                    weak var released: MiMoTensorParallelModel?
                    released = model
                    reservation = nil; model = nil
                    guard released == nil else { throw ProbeError("MiMo tensor-parallel model remains retained") }
                    try residency?.end(); residency = nil
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
        guard let model else { throw ProbeError("Resident model already released") }
        let request = reserved.request, rank = collective.rank
        let decoding = MiMoTensorParallelDecoding(model: model)
        guard try decoding.requestAgreed(QwenTensorParallelResidentRuntime.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("MiMo tensor-parallel ranks were given different requests")
        }
        var lastCheck: UInt64 = 0
        func localStop() -> Bool {
            if (try? control.check(deadline: reserved.deadline)) == nil { return true }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastCheck >= 250_000_000 {
                lastCheck = now
                if (try? Self.requireLiveMemory(bytes: 0)) == nil { return true }
            }
            return false
        }
        let sampler = request.sampler
        let rule = MiMoTensorParallelSelectionRule.rule(request.sampling?.wire)
        let outcome = try decoding.run(.init(prompt: request.promptTokenIDs, outputCount: request.outputCount,
            chunk: request.chunkSize, stopTokenIDs: request.stopTokenIDs, rule: rule, sampler: sampler),
            localStop: localStop, publish: { ordinal, token, logprobs in
                try channel.publishToken(ordinal, token, request.promptCount + ordinal, logprobs)
                return try channel.answer()
            })
        try control.check(deadline: reserved.deadline)
        let finish: ClusterWorkerFinishReason
        switch outcome.finish {
        case .eos: finish = .eos
        case .length: finish = .length
        case .clientStop: finish = .clientStop
        }
        if finish == .clientStop, !outcome.ownerStopped, rank == 0 {
            throw ProbeError("The peer rank stopped the MiMo tensor-parallel request")
        }
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) request=\(request.requestID.uuidString.lowercased())"
            + " family=mimo prompt=\(request.promptCount) output=\(outcome.tokens.count) finish=\(finish.rawValue)"
            + " rule=\(rule.label) frames=\(codec?.sealedFrames ?? 0) key_generation=\(codec?.keyGeneration ?? 0)"
            + " kv_pages=\(outcome.caches.reduce(0) { $0 + $1.pageCount })"
            + String(format: " first_token_ms=%.1f decode_ms=%.1f", outcome.firstTokenSeconds * 1000, outcome.decodeSeconds * 1000))
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: outcome.tokens, completedFrames: outcome.tokens.count,
            committedTokens: request.promptCount + outcome.tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(outcome.tokens.map { String($0) })),
            bothRequestStatesRetired: true)
    }
}
