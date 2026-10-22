import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// Synchronous, process-local native owner for the worker's private executor.
/// Only cancel/readiness may run on its separate control thread. Concurrent
/// reserve/start/shutdown calls refuse instead of overlapping MLX work.
///
/// A hard enclosing worker/process deadline is REQUIRED: cooperative checks
/// cannot interrupt a blocked native collective. On any throw, withdraw this
/// worker and fence/cancel its peer out of band; do not publish a retired event
/// merely because the call threw or a timer elapsed. shutdown releases only this
/// process's weights. Provider lease retirement remains the two-worker owner's job.
public final class QwenResidentRuntime {
    let admission: any LayerStageResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let baseReady: ClusterWorkerReady
    /// Declared at load and bound into the load agreement with the peer.
    public let generationMode: QwenResidentGenerationMode
    private let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    let lifecycle: QwenLayerStageResidentLifecycle
    private var stage: (any LayerStageResidentStage)?
    private weak var model: Module?
    /// Phase split, rank 1 only: the producer stage this rank also holds, so
    /// that it owns every layer once rank 0 has handed its request state over.
    private var producerStage: (any LayerStageResidentStage)?
    private weak var producerModel: Module?
    /// `phase_split_mtp_v1`, rank 1 only: the model's speculative head, bound
    /// to both stages this rank holds. The terms are declared on both ranks.
    private var speculativeHead: QwenMTPHead?
    public let speculativeTerms: QwenMTPTerms?
    private var reservation: QwenResidentReservation?
    private var phaseSplitAllowance: QwenPhaseSplitAllowance?
    /// Qualification only: admitted at load from a permitted switch, nil otherwise.
    private let qualificationFault: QwenPhaseSplitFault?
    private var processLeaseOwned = true
    /// This rank's resident prompt-prefix cache; lives as long as the model.
    public let prefixCache: QwenStagePrefixCache
    /// The longest context this rank's host memory gate admits with its
    /// weights resident: found at load, re-derived while idle
    /// (`refreshServingContext`). Reported in the readiness and on every
    /// keep-warm answer, so the pair's owner refuses a longer request up front.
    public private(set) var servingContextTokens: Int?
    /// Allocator active bytes once the model was loaded: what this process
    /// holds while idle and empty. Anything above it while idle (the prefix
    /// cache) gives way to a request, so the serving context counts it.
    private let activeLoadedBytes: Int
    /// Continuous batching terms, agreed with the peer at load.
    public let batch: QwenBatchSettings
    /// Batch lanes this rank holds (empty with one lane).
    let laneBook = QwenBatchLaneBook()
    /// True while the batch loop runs on the executor: lane reservations and
    /// starts it applies between steps then run inside its exclusive hold.
    var batchServing = false
    /// The KV storage the stage's requests use, for whoever launched the worker.
    public var kvBackend: String { stage?.loaded.kvHost.host?.kind.rawValue ?? "contiguous" }

    init(admission: any LayerStageResidentAdmission, control: QwenResidentControl, collective: Collective,
         stage: any LayerStageResidentStage, capacity: Int, lifecycle: QwenLayerStageResidentLifecycle,
         generationMode: QwenResidentGenerationMode = .pipeline, producerStage: (any LayerStageResidentStage)? = nil,
         speculativeHead: QwenMTPHead? = nil, speculativeTerms: QwenMTPTerms? = nil,
         qualificationFault: QwenPhaseSplitFault? = nil,
         prefixCache: QwenStagePrefixCache = .fromEnvironment(),
         servingContextTokens: Int? = nil, activeLoadedBytes: Int = 0, prefixBudgetBytes: Int? = nil,
         batch: QwenBatchSettings = .single, linkProbe: ClusterWorkerLinkProbe? = nil) {
        self.prefixCache = prefixCache; self.batch = batch
        if let prefixBudgetBytes { prefixCache.setBudget(prefixBudgetBytes) }
        self.servingContextTokens = servingContextTokens; self.activeLoadedBytes = activeLoadedBytes
        self.admission = admission; self.control = control; self.collective = collective
        self.speculativeHead = speculativeHead; self.speculativeTerms = speculativeTerms
        self.stage = stage; model = stage.loaded.model; self.lifecycle = lifecycle
        self.generationMode = generationMode; self.qualificationFault = qualificationFault
        self.producerStage = producerStage; producerModel = producerStage?.loaded.model
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane,
            servingContextTokens: servingContextTokens.map { min($0, admission.wireProfile.maximumContextTokens) },
            linkProbe: linkProbe)
    }

    /// Re-derives the serving context from this Mac's live admissible memory
    /// while idle: the same search as at load (`admittedContext`), counting
    /// what the prefix cache holds as memory a request gets back (the cache
    /// gives way before a reservation is refused). Not even the smallest
    /// useful request fitting reports that smallest one, so a longer request
    /// is refused up front and a shorter one is still gated at reservation.
    /// Nil (and nothing changes) while a request is reserved or running, or
    /// when the host cannot be judged now. Allocates nothing.
    public func refreshServingContext() -> Int? {
        guard operation.try() else { return nil }
        defer { operation.unlock() }
        guard control.available, let stage else { return nil }
        let reclaimable = max(0, Memory.activeMemory - activeLoadedBytes)
        let found: Int
        var room = 0
        do {
            let admitted = try Self.admittedContext(admission: admission, stage: stage, rank: collective.rank,
                mode: generationMode, speculativeTerms: speculativeTerms, reclaimableBytes: reclaimable)
            found = admitted.contextTokens; room = admitted.roomBytes
        } catch {
            guard String(describing: error).hasPrefix("Resident load refused: not even") else { return nil }
            found = min(admission.profile.maximumContextTokens, admission.profile.maximumChunkTokens + 1)
        }
        // The cache's budget follows the room beside the serving context now, in
        // both directions (models stay loaded until unloaded, so a dip at load
        // must not keep it small), so the context and the full budget fit
        // together; entries beyond a smaller budget are evicted now.
        if prefixCache.refreshBudget(roomBytes: room) {
            log("darkbloom-prefix-v1 rank=\(collective.rank) budget_bytes=\(prefixCache.budgetBytes) room_bytes=\(room)"
                + " held_bytes=\(prefixCache.bytesInUse)")
        }
        let value = min(found, admission.wireProfile.maximumContextTokens)
        if value != servingContextTokens {
            log("darkbloom-serving-context-v1 rank=\(collective.rank) tokens=\(value) previous=\(servingContextTokens ?? 0)"
                + " reclaimable=\(reclaimable)")
        }
        servingContextTokens = value
        return value
    }

    /// Keep-warm tier 1: one asynchronous pulse on a dedicated stream of this
    /// executor while idle (`ClusterKeepWarm.pulse`); returns its submission
    /// time in nanoseconds. Refuses while a native operation or request runs.
    public func keepWarmPulse() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return keepWarm.pulse()
    }

    /// Keep-warm tier 2: one 1x16 exchange with the peer on the data plane
    /// while idle (`ClusterKeepWarm.dataPlanePing`); returns its duration in
    /// nanoseconds. Both ranks must be told by their owner; never during a
    /// request.
    public func dataPlanePing() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    /// The executor's exclusive hold. Inside the batch loop, control it applies
    /// between steps runs in the loop's own hold.
    func withExclusiveOperation<T>(_ body: () throws -> T) throws -> T {
        if batchServing { return try body() }
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        return try body()
    }

    var stageForBatch: (any LayerStageResidentStage)? { stage }

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    /// Named local recording ceiling, available only after the existing bilateral
    /// load and while idle. This query allocates no request state and does not
    /// replace live admission at reserve/start or the enclosing process fence.
    @_spi(Benchmark) public func recordingReadiness(prefillPolicy: QwenResidentPrefillPolicy = .serial) throws -> ClusterWorkerReady? {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available, (try? control.check()) != nil else { return nil }
        let capacity = try recordingCapacity(prefillPolicy)
        try control.check()
        return .init(identity: baseReady.identity, rank: baseReady.rank, profile: baseReady.profile,
            executionPlanSHA256: baseReady.executionPlanSHA256, requestCapacityBytes: capacity,
            dataPlane: baseReady.dataPlane, servingContextTokens: baseReady.servingContextTokens)
    }

    private func prefillAllowance(_ policy: QwenResidentPrefillPolicy, promptCount: Int,
                                  chunkSize: Int) throws -> QwenGenerationPrefillAllowance? {
        try QwenResidentPrefillSelection.allowance(policy, rank: collective.rank,
            promptCount: promptCount, chunkSize: chunkSize,
            hiddenSize: admission.profile.hiddenSize,
            elementBytes: qwenStageWireElementBytes(admission.profile.activationDType),
            bound: QwenResidentResourceEnvironment.allocationBound)
    }
    private func recordingCapacity(_ policy: QwenResidentPrefillPolicy) throws -> Int {
        let base = try maximumRecordingCharge().reservedBytes
        let extra = try prefillAllowance(policy, promptCount: admission.profile.maximumPromptTokens,
            chunkSize: admission.profile.maximumChunkTokens)
        let split = try Self.phaseSplitAllowance(generationMode, admission: admission, stage: stage,
            rank: collective.rank, promptCount: admission.profile.maximumPromptTokens, speculativeTerms: speculativeTerms)
        return try QwenLongPrefillCheckedBytes.sum([base, extra?.reservedBytes ?? 0, split?.reservedBytes ?? 0])
    }

    /// The hand-off's own named storage for a prompt of `promptCount` tokens;
    /// nil for the pipeline. Shared by load, readiness, reserve and start.
    ///
    /// `pipeline_mtp_v1` has no hand-off; its named storage is the verify
    /// window's (both ranks run every window through their stage, each
    /// recurrent layer keeping its state at every window position) and, on the
    /// last rank, the head's request state: `QwenMTPAllowance`, charged in
    /// full on both ranks (conservative on rank 0, which holds no head).
    static func phaseSplitAllowance(_ mode: QwenResidentGenerationMode, admission: any LayerStageResidentAdmission,
                                    stage: (any LayerStageResidentStage)?, rank: Int,
                                    promptCount: Int, speculativeTerms: QwenMTPTerms? = nil) throws -> QwenPhaseSplitAllowance? {
        if mode == .pipelineMTP {
            guard let speculativeTerms else { throw ProbeError("Speculative terms differ from the declared generation mode") }
            guard let stage else { throw ProbeError("Resident model already released") }
            guard let geometry = stage.handoffGeometry else {
                throw ProbeError("This registered model has no speculative window geometry")
            }
            let speculative = try QwenMTPAllowance.derive(geometry: geometry, depth: speculativeTerms.depth,
                maximumTokens: admission.profile.maximumContextTokens, promptTokens: promptCount,
                chunkSize: admission.profile.maximumChunkTokens, vocabularySize: admission.profile.vocabularySize,
                bound: QwenResidentResourceEnvironment.allocationBound)
            return .init(rank: rank, extraNativeBytes: speculative.extraNativeBytes,
                extraHostBytes: speculative.extraHostBytes)
        }
        guard mode.isPhaseSplit else { return nil }
        guard mode.usesSpeculativeHead == (speculativeTerms != nil) else {
            throw ProbeError("Speculative terms differ from the declared generation mode")
        }
        guard let stage else { throw ProbeError("Resident model already released") }
        guard let geometry = stage.handoffGeometry else {
            throw ProbeError("This registered model's request state does not change owner")
        }
        let shapes = try QwenPhaseSplitPlan.expectedShapes(stage: admission.plan.stages[0], geometry: geometry,
            committedTokens: promptCount, activationDType: admission.profile.activationDType)
        // The state that changes owner is part of the admitted model's own
        // named state, so it is held to that model's ceiling and no other's.
        guard try QwenLongPrefillCheckedBytes.sum(shapes.map(\.byteCount)) <= stage.namedStateByteCeiling() else {
            throw ProbeError("Phase-split hand-off exceeds the model's named-state byte ceiling")
        }
        // The adopting rank also runs the producer stage, with that stage's fusion.
        var producerFusion = 0
        if rank == 1 {
            producerFusion = try stage.requestAllowance(plan: admission.plan,
                rank: 0, maximumTokens: admission.profile.maximumContextTokens,
                chunkSize: admission.profile.maximumChunkTokens,
                bound: QwenResidentResourceEnvironment.allocationBound).fusionBytes
        }
        // The decoding rank of a speculative phase split also holds the head's
        // per-request state; its weights are resident and charged at load.
        var speculative: QwenMTPAllowance?
        if rank == 1, let speculativeTerms {
            speculative = try .derive(geometry: geometry, depth: speculativeTerms.depth,
                maximumTokens: admission.profile.maximumContextTokens, promptTokens: promptCount,
                chunkSize: admission.profile.maximumChunkTokens, vocabularySize: admission.profile.vocabularySize,
                bound: QwenResidentResourceEnvironment.allocationBound)
        }
        return try .derive(rank: rank, shapes: shapes, producerFusionBytes: producerFusion, speculative: speculative,
            bound: QwenResidentResourceEnvironment.allocationBound)
    }

    /// The largest context this rank admits now and its charge: state,
    /// fusion and attention transient (`QwenResidentRequestAllowance`), plus
    /// the schedule's and the mode's named storage at that context's prompt.
    /// One sample of the host is judged for every candidate, so the search
    /// is consistent; the caller then takes one live decision at the result.
    /// `reclaimableBytes` is memory this process holds now that a request
    /// would get back first (the idle prefix cache); it is taken off each
    /// candidate's ask. Zero at load.
    static func admittedContext(admission: any LayerStageResidentAdmission, stage: any LayerStageResidentStage,
                                rank: Int, mode: QwenResidentGenerationMode,
                                speculativeTerms: QwenMTPTerms? = nil,
                                reclaimableBytes: Int = 0) throws -> QwenResidentAdmittedContext {
        // The admitted profile carries the model's limits (`QwenResidentContextLimits`
        // for a registered Qwen row; the earlier reservation for a family without one).
        let maximumContext = admission.profile.maximumContextTokens
        let policy = QwenResidentPrefillSelection.policy(admission.configuration.prefillSchedule)
        let sum = QwenLongPrefillCheckedBytes.sum
        // A charge is the same for a context on this loaded stage every time; it is derived from the plan and costs
        // tens of milliseconds (Bonsai's Prism configuration more), and the idle refresh searches it often: kept.
        let memoKey = "\(admission.plan.fingerprint)|\(rank)|\(mode)|\(speculativeTerms.map { "mtp\($0.depth)" } ?? "none")"
            + "|\(admission.profile.maximumContextTokens)|\(admission.profile.maximumPromptTokens)"
            + "|\(admission.profile.maximumChunkTokens)|\(admission.configuration.prefillSchedule)"
        func charge(_ context: Int) throws -> QwenResidentAdmittedContext {
            try QwenResidentChargeMemo.shared.value(key: memoKey, context: context) { try uncachedCharge(context) }
        }
        func uncachedCharge(_ context: Int) throws -> QwenResidentAdmittedContext {
            let prompt = min(admission.profile.maximumPromptTokens, context - 1)
            let chunk = min(admission.profile.maximumChunkTokens, prompt)
            let allowance = try stage.requestAllowance(plan: admission.plan, rank: rank,
                maximumTokens: context, chunkSize: chunk, bound: QwenResidentResourceEnvironment.allocationBound)
            let prefill = try QwenResidentPrefillSelection.allowance(policy, rank: rank, promptCount: prompt,
                chunkSize: chunk, hiddenSize: admission.profile.hiddenSize,
                elementBytes: qwenStageWireElementBytes(admission.profile.activationDType),
                bound: QwenResidentResourceEnvironment.allocationBound)
            let split = try phaseSplitAllowance(mode, admission: admission, stage: stage, rank: rank, promptCount: prompt,
                speculativeTerms: speculativeTerms)
            return .init(contextTokens: context, allowance: allowance,
                extraNativeBytes: try sum([prefill?.extraNativeBytes ?? 0, split?.extraNativeBytes ?? 0]),
                extraHostBytes: try sum([prefill?.extraHostBytes ?? 0, split?.extraHostBytes ?? 0]))
        }
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        let now = DispatchTime.now().uptimeNanoseconds
        func judge(_ context: Int) throws -> (admitted: Bool, roomBytes: Int) {
            let value = try charge(context)
            let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes, try sum([value.allowance.reservedBytes,
                value.extraNativeBytes, value.extraHostBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes])
                - max(0, reclaimableBytes))
            let allocator = try sum([native.activeBytes, native.cacheBytes, value.allowance.reservedBytes,
                value.extraNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes]) - max(0, reclaimableBytes)
            let decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: free,
                purpose: "Resident context of \(context) tokens", now: now)
            return (decision.admitted && native.allocatorLimitBytes >= allocator,
                    max(0, min(decision.admissibleBytes - decision.requiredBytes, native.allocatorLimitBytes - allocator)))
        }
        func admits(_ context: Int) throws -> Bool { try judge(context).admitted }
        // One prefill frame and one output token: the least a loaded stage serves.
        let minimum = min(maximumContext, admission.profile.maximumChunkTokens + 1)
        let plain = try QwenResidentContextAdmission.largest(minimum: minimum, maximum: maximumContext, admits: admits)
        // A Mac whose memory bounds the context keeps room for the prompt-prefix cache when that costs at most a
        // quarter of the context: the largest context left the cache no budget at all (0.4 MB beside 29,072 tokens
        // on a 36 GB M4 Max, 2026-10-16), and one rank without a cache turns reuse off for both.
        let keepingCache = try plain.flatMap { found -> Int? in
            guard try judge(found).roomBytes < QwenStagePrefixCache.contextReserveBytes else { return nil }
            return try QwenResidentContextAdmission.largest(minimum: minimum, maximum: found, admits: { context in
                let value = try judge(context); return value.admitted && value.roomBytes >= QwenStagePrefixCache.contextReserveBytes
            }).flatMap { $0 * 4 >= found * 3 ? $0 : nil }
        }
        guard let largest = keepingCache ?? plain else {
            // The live gate's own sentence for the smallest useful request.
            let smallest = try charge(minimum)
            try smallest.allowance.requireLive(additionalNativeBytes: smallest.extraNativeBytes,
                additionalHostBytes: smallest.extraHostBytes)
            throw ProbeError("Resident load refused: not even a request of \(minimum) context tokens fits on rank \(rank)")
        }
        var admitted = try charge(largest)
        admitted.roomBytes = try judge(largest).roomBytes
        return admitted
    }

    private func maximumRecordingCharge() throws -> QwenResidentRecordingCharge {
        guard let stage else { throw ProbeError("Resident model already released") }
        let base = try stage.requestAllowance(plan: admission.plan,
            rank: collective.rank, maximumTokens: admission.profile.maximumContextTokens,
            chunkSize: admission.profile.maximumChunkTokens, bound: QwenResidentResourceEnvironment.allocationBound)
        guard base.reservedBytes <= baseReady.requestCapacityBytes else {
            throw ProbeError("Recording maximum differs from the admitted resident base ceiling")
        }
        return try .derive(base: base, rank: collective.rank, vocabularySize: admission.profile.vocabularySize,
            activationDType: admission.profile.selectedRowDType, bound: QwenResidentResourceEnvironment.allocationBound)
    }

    /// Metadata/native resource reservation only; no request state or forward.
    /// Returned bytes are this rank's named allowance, not combined peer RAM.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try reserve(requestID: requestID, request: value, mode: .serving,
            prefillPolicy: QwenResidentPrefillSelection.policy(admission.configuration.prefillSchedule))
    }

    /// Charges the original state/fusion allowance plus both named host/native
    /// capture terms. Both workers must use recording reservations; a serving
    /// reservation cannot be upgraded at start or by a live resource check.
    @_spi(Benchmark) public func reserveRecording(requestID: UUID, request value: ClusterWorkerReservation,
        prefillPolicy: QwenResidentPrefillPolicy = .serial) throws -> Int {
        try reserve(requestID: requestID, request: value, mode: .recording, prefillPolicy: prefillPolicy)
    }

    private func reserve(requestID: UUID, request value: ClusterWorkerReservation,
                         mode: QwenResidentRequestMode, prefillPolicy: QwenResidentPrefillPolicy = .serial) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        try control.check(); try control.reserve(requestID)
        // Nothing below allocates: a throw gives the reservation back and is
        // a refusal of this request alone (`ClusterResidentRequestRefusal`).
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard let stage else { throw ProbeError("Resident model already released") }
            let allowance = try stage.requestAllowance(
                plan: admission.plan, rank: collective.rank, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount), bound: QwenResidentResourceEnvironment.allocationBound)
            let prefill = try prefillAllowance(prefillPolicy, promptCount: request.promptCount, chunkSize: request.chunkSize)
            let split = try Self.phaseSplitAllowance(generationMode, admission: admission, stage: stage,
                rank: collective.rank, promptCount: request.promptCount, speculativeTerms: speculativeTerms)
            let charge: QwenResidentRecordingCharge?
            if mode == .recording {
                let recording = try QwenResidentRecordingCharge.derive(base: allowance, rank: collective.rank,
                    vocabularySize: request.profile.vocabularySize, activationDType: request.profile.selectedRowDType,
                    bound: QwenResidentResourceEnvironment.allocationBound)
                if let prefill {
                    try prefill.requireCapacity(baseBytes: recording.reservedBytes, ownerLimit: value.capacityLimitBytes,
                        readinessLimit: recordingCapacity(prefillPolicy))
                } else {
                    try recording.requireCapacity(ownerLimit: value.capacityLimitBytes,
                        readinessLimit: maximumRecordingCharge().reservedBytes)
                }
                // Reuse the actual diagnostic source/request/allocator binding
                // and live policy; no caller-supplied budget grants permission.
                let resources = try stage.diagnosticResources(
                    plan: admission.plan, request: request, rank: collective.rank, requestAllowance: allowance)
                try recording.requireCapture(resources.budget)
                charge = recording
            } else {
                if let prefill {
                    try prefill.requireCapacity(baseBytes: allowance.reservedBytes,
                        ownerLimit: value.capacityLimitBytes, readinessLimit: baseReady.requestCapacityBytes)
                } else {
                    guard allowance.reservedBytes <= value.capacityLimitBytes,
                          allowance.reservedBytes <= baseReady.requestCapacityBytes else {
                        throw ProbeError("Resident reservation exceeds its additional owner capacity ceiling")
                    }
                }
                charge = nil
            }
            var reserved = QwenResidentReservation(request: request, allowance: allowance,
                deadline: value.deadlineUptimeNanoseconds, mode: mode, recordingCharge: charge,
                prefillPolicy: prefillPolicy, prefillAllowance: prefill)
            // Only what this request's capture adds after the prefix this rank
            // holds for it (nothing on a repeat of the whole prompt), so kept
            // entries never give way for a capture that will not happen. The
            // scope is the one its agreement will key the cache by; without
            // it the whole plan is charged, as for a cold request.
            var scope: String?
            if prefixCache.enabled {
                scope = try? QwenResidentRequestExecution.prefixScope(stage: stage, admission: admission, request: request)
            }
            reserved.prefixCaptureBytes = scope.map {
                prefixCache.captureLimit(scope: $0, tokens: request.promptTokenIDs, chunkSize: request.chunkSize)
            } ?? prefixCache.captureLimit(promptCount: request.promptCount, chunkSize: request.chunkSize)
            let total = try QwenLongPrefillCheckedBytes.sum([charge?.reservedBytes ?? allowance.reservedBytes,
                prefill?.reservedBytes ?? 0, split?.reservedBytes ?? 0])
            if split != nil {
                // The hand-off allowance is charged on top of everything above
                // and must fit the same owner and readiness ceilings.
                var readiness = baseReady.requestCapacityBytes
                if mode == .recording { readiness = try recordingCapacity(prefillPolicy) }
                guard total <= value.capacityLimitBytes, total <= readiness else {
                    throw ProbeError("Phase-split reservation exceeds its owner or readiness capacity ceiling")
                }
            }
            // Kept prefixes give way before a reservation is refused for memory,
            // and this request's own capture is optional: when even an empty
            // cache leaves no room for it, the request runs without capturing.
            do {
                try prefixCache.yieldingMemory { try QwenResidentRequestExecution.requireLive(reserved, phaseSplit: split) }
            } catch where reserved.prefixCaptureBytes > 0 {
                log("darkbloom-prefix-v1 rank=\(collective.rank) capture-dropped bytes=\(reserved.prefixCaptureBytes): \(error)")
                reserved.prefixCaptureBytes = 0
                try prefixCache.yieldingMemory { try QwenResidentRequestExecution.requireLive(reserved, phaseSplit: split) }
            }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            if prefixCache.enabled {
                log("darkbloom-prefix-v1 rank=\(collective.rank) capture_charge=\(reserved.prefixCaptureBytes)"
                    + " held_bytes=\(prefixCache.bytesInUse) budget_bytes=\(prefixCache.budgetBytes)")
            }
            prefixCache.admitCapture(reserved.prefixCaptureBytes)
            reservation = reserved; phaseSplitAllowance = split
            return total
        }
    }

    /// Gives back a reservation that never started, when the pair's owner
    /// cancels it because the other rank refused the request: nothing was
    /// allocated for it, and this rank is idle and available again.
    public func releaseReservation(requestID: UUID) throws {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("Resident release has no matching unstarted reservation")
        }
        reservation = nil; phaseSplitAllowance = nil; prefixCache.admitCapture(nil)
    }

    /// Only rank0 invokes the callback, after both ranks commit/accept the token.
    /// False requests agreed clean stop; a thrown callback is abnormal failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        try execute(requestID: requestID, mode: .serving, onCommittedToken: onCommittedToken) { completion, _ in completion }
    }

    /// Returns bounded CPU evidence only after bilateral retirement, local
    /// lifecycle exit and encoding. No tensors or model handle cross this SPI.
    @_spi(Benchmark) public func startRecording(requestID: UUID,
        onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> QwenResidentRecordingCompletion {
        try execute(requestID: requestID, mode: .recording, onCommittedToken: onCommittedToken) { completion, evidence in
            guard let evidence else { throw ProbeError("Recording request returned no diagnostic evidence") }
            return .init(completion: completion, encodedEvidence: try evidence.encoded())
        }
    }

    private func execute<Output>(requestID: UUID, mode: QwenResidentRequestMode,
        onCommittedToken: (Int, Int, Int) throws -> Bool,
        prepare: (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) throws -> Output
    ) throws -> Output {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        try reserved.mode.require(mode)
        do {
            guard reserved.prefillAllowance == (try prefillAllowance(reserved.prefillPolicy,
                promptCount: reserved.request.promptCount, chunkSize: reserved.request.chunkSize)) else {
                throw ProbeError("Lookahead allowance changed since reservation")
            }
            let split = phaseSplitAllowance
            guard split == (try Self.phaseSplitAllowance(generationMode, admission: admission, stage: stage,
                rank: collective.rank, promptCount: reserved.request.promptCount, speculativeTerms: speculativeTerms)) else {
                throw ProbeError("Phase-split allowance changed since reservation")
            }
            // This request's allocator peak, for whoever launched the worker.
            let before = Memory.snapshot()
            Memory.peakMemory = 0   // resets the allocator peak (the value is ignored)
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID,
                    recordedRequestFingerprint: reserved.request.fingerprint), deadline: reserved.deadline, body: {
                try autoreleasepool {
                    guard let stage else { throw ProbeError("Resident model already released") }
                    return try QwenResidentRequestExecution.run(stage: stage, producerStage: producerStage,
                        speculativeHead: speculativeHead, speculativeTerms: speculativeTerms,
                        generationMode: generationMode, phaseSplitAllowance: split,
                        qualificationFault: qualificationFault, admission: admission,
                        collective: collective, control: control, reserved: reserved, prefixCache: prefixCache,
                        activeAtStart: before.activeMemory, onCommittedToken: onCommittedToken)
                }
            }, prepare: { try prepare($0.0, $0.1) })
            let after = Memory.snapshot()
            log("darkbloom-resident-request-v1 rank=\(collective.rank) prompt=\(reserved.request.promptCount)"
                + " output=\(reserved.request.outputCount) reserved=\(reserved.allowance.reservedBytes)"
                + " transient=\(reserved.allowance.transientBytes) active_before=\(before.activeMemory)"
                + " peak=\(after.peakMemory) active_after=\(after.activeMemory) cache_after=\(after.cacheMemory)"
                + " prefix_capture_charge=\(reserved.prefixCaptureBytes) prefix_held=\(prefixCache.bytesInUse)"
                + " prefix_budget=\(prefixCache.budgetBytes)")
            // S16: the session's record counters and key generations so far.
            collective.logDataPlaneStatus()
            // Output is fully prepared and control completed before this slot
            // is cleared. A thrown encode keeps the failed owner unavailable.
            reservation = nil; phaseSplitAllowance = nil
            return value
        } catch {
            // The peer may have stored or dropped differently; a failed owner
            // keeps nothing it cannot prove both ranks hold.
            prefixCache.sweep()
            control.fail(); throw error
        }
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    /// Local release only. On failure the external owner must retain/fence its
    /// peer and must not manufacture a successful request-retirement event.
    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        collective.logDataPlaneStatus()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    // Every rank sweeps its cache before its model goes. Records
                    // already queued for the SSD are finished first (bounded):
                    // they are what a restarted pair restores.
                    prefixCache.disk?.close()
                    prefixCache.sweep(); laneBook.clear()
                    // The stages' KV pools go with them; one still holding a
                    // request's pages is a failed release.
                    let drained = CBv2StageKVHost.uninstall(from: stage?.loaded)
                        && CBv2StageKVHost.uninstall(from: producerStage?.loaded)
                    reservation = nil; phaseSplitAllowance = nil; speculativeHead = nil; stage = nil; producerStage = nil
                    guard drained else { throw ProbeError("A stage KV pool still held request pages at release") }
                    guard model == nil, producerModel == nil else { throw ProbeError("Resident model remains retained") }
                    Memory.clearCache(); try error.check()
                    if generationMode.isPhaseSplit {
                        // Sizes only: what this process still holds after release.
                        Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                        let after = Memory.snapshot()
                        log("darkbloom-resident-release-v1 rank=\(collective.rank) active=\(after.activeMemory) cache=\(after.cacheMemory)")
                    }
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit {
        // Explicit shutdown is required. Do not reopen the process-wide native
        // admission if a caller dropped an owner without acknowledged cleanup.
        if processLeaseOwned { control.fail() }
    }
}

/// What `QwenResidentRuntime.admittedContext` found for one rank at load.
struct QwenResidentAdmittedContext {
    let contextTokens: Int
    let allowance: QwenResidentRequestAllowance
    let extraNativeBytes: Int
    let extraHostBytes: Int
    /// Admissible memory (and allocator room) left beside this context's
    /// whole ask, on the same sample; the prefix cache's budget comes from it.
    var roomBytes = 0
}

/// `admittedContext`'s charges, per loaded stage (plan, rank, mode) and context: the idle refresh searched them again
/// and again (each one derives the stage plan), and on a 36 GB M4 Max with Bonsai 2 27B a refresh outlasted the 10 s
/// a request waits for its reservation, so every request failed (2026-10-16). Bounded; a worker serves one stage.
final class QwenResidentChargeMemo: @unchecked Sendable {
    static let shared = QwenResidentChargeMemo()
    private let lock = NSLock()
    private var key = ""
    private var values: [Int: QwenResidentAdmittedContext] = [:]

    func value(key: String, context: Int, _ make: () throws -> QwenResidentAdmittedContext) rethrows -> QwenResidentAdmittedContext {
        if let found = lock.withLock({ () -> QwenResidentAdmittedContext? in
            if self.key != key { self.key = key; values.removeAll() }
            return values[context]
        }) { return found }
        let made = try make()
        lock.withLock {
            if self.key == key, values.count < 4_096 { values[context] = made }
        }
        return made
    }
}
