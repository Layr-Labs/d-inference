import DarkbloomClusterProtocol
import Foundation
import MLX

struct QwenTensorParallelOwnedBatchReservation: QwenTensorParallelBatchReservation {
    let request: QwenLayerStageGenerationRequest
    let deadline: UInt64
    let laneStateBytes: Int
    let media: QwenMediaRequestWork?
    // Preparation starts bilaterally in open; no unsynchronized model/tower
    // work is scheduled by admission or by the control thread.
    var joinable: Bool { true }
}

extension QwenTensorParallelResidentRuntime {
    private func withBatchOperation<T>(_ body: () throws -> T) throws -> T {
        // serviceControl applies new reservations on this same serial native
        // executor while its outer serveBatch owns the operation lock.
        if batchServing { return try body() }
        guard operation.try() else { throw ProbeError("A tensor-parallel native operation is already active") }
        defer { operation.unlock() }
        return try body()
    }

    private func batchPlan() throws -> QwenTensorParallelPlan {
        guard let model, batchLanes > 1, !model.plan.routedExperts,
              admission.specification.model == .qwen38TwentySevenB,
              codec != nil, group.sealed != nil, group.requiresSealing else {
            throw ProbeError("Qwen27 TP batch owner is not admitted or sealed")
        }
        return model.plan
    }

    public func reserveLane(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try withBatchOperation {
            let plan = try batchPlan()
            guard value.route == nil, let batchBudget, let batchHost, batchBook.count < batchLanes else {
                throw ProbeError("Tensor-parallel batch lanes are unavailable or routed")
            }
            let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds,
                allowsQwenMedia: baseReady.media == ClusterQwenMedia.contract)
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let local = try QwenTensorParallelBatchBudget.derive(geometry: profile.geometry, plan: plan,
                tensors: profile.canonicalTensors, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount), lanes: batchLanes,
                paged: batchHost.kind == .paged, allocationBound: QwenResidentResourceEnvironment.allocationBound)
            guard local.perLaneStateBytes <= batchBudget.perLaneStateBytes else {
                throw ProbeError("Tensor-parallel lane state exceeds its LOAD budget")
            }
            let mediaBudget: QwenMediaBudget?
            if let envelope = value.qwenMedia {
                guard baseReady.media == ClusterQwenMedia.contract, let visionInventory,
                      (collective.rank == 0 && envelope.items.allSatisfy({ $0.encoded != nil }))
                        || (collective.rank == 1 && !envelope.carriesEncodedBytes) else {
                    throw ProbeError("Qwen TP batch media differs from sealed readiness")
                }
                mediaBudget = try QwenMediaBudget(media: envelope, rank: collective.rank,
                    hiddenSize: visionInventory.configuration.textConfiguration.hiddenSize,
                    featureElementBytes: visionInventory.featureDType.size,
                    maximumVideoPatches: visionInventory.processor.maximumVideoPatchCount(),
                    tensorParallel: true, chunkTokens: request.chunkSize, minimumActivationBytes: 11 * 1_073_741_824 / 2,
                    maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
                    sealedFrameOverhead: QwenTensorParallelSealCodec.frameOverhead,
                    allocationBound: QwenResidentResourceEnvironment.allocationBound)
            } else { mediaBudget = nil }
            let shared = try QwenLongPrefillCheckedBytes.sum([batchBudget.sharedBytesExcludingCollectives,
                batchBudget.allowance.collectiveScratchBytes])
            let total = try QwenLongPrefillCheckedBytes.sum([local.perLaneStateBytes, shared,
                mediaBudget?.nativeBytes ?? 0, mediaBudget?.hostBytes ?? 0])
            guard total <= value.capacityLimitBytes, total <= baseReady.requestCapacityBytes else {
                throw ProbeError("Qwen TP batch reservation exceeds its owner ceiling")
            }
            // Gate the entire future state before constructing positions,
            // pixels, features, cache rows or request samplers' native graphs.
            try requireBatchMemory(extraState: local.perLaneStateBytes,
                extraNative: mediaBudget?.nativeBytes ?? 0, extraHost: mediaBudget?.hostBytes ?? 0, entering: true)
            let media: QwenMediaRequestWork?
            if let envelope = value.qwenMedia, let budget = mediaBudget, let visionInventory {
                media = try .init(state: .init(media: envelope, prompt: request.promptTokenIDs,
                    identity: visionInventory.mediaIdentity, maximumPrompt: admission.profile.maximumPromptTokens,
                    maximumContext: request.maximumTokens), budget: budget)
            } else { media = nil }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            try batchBook.reserve(requestID, .init(request: request, deadline: value.deadlineUptimeNanoseconds,
                laneStateBytes: local.perLaneStateBytes, media: media), lanes: batchLanes)
            return total
        }
    }

    public func startLane(requestID: UUID) throws { try batchBook.start(requestID) }
    public func cancelLane(requestID: UUID) { batchBook.cancel(requestID) }
    public func withdrawLane(requestID: UUID) -> Bool {
        guard let held = batchBook.reservation(requestID) else { return false }
        // An unstarted reservation has no asynchronous preparation or native
        // roots. Do not clear a started lane's buffers from a control thread.
        return held.media == nil ? batchBook.withdraw(requestID) : withdrawUnstartedMedia(requestID, held)
    }
    private func withdrawUnstartedMedia(_ id: UUID, _ held: QwenTensorParallelOwnedBatchReservation) -> Bool {
        guard !batchBook.isStarted(id), held.media?.preparation.finished == true else { return false }
        // No native work exists before start. The book's atomic withdraw still
        // refuses a joined request, even when it is no longer in started.
        guard batchBook.withdraw(id) else { return false }
        return true
    }
    public var hasStartedLanes: Bool { batchBook.hasStarted }

    /// Full named future charge minus allocations already made by this sole
    /// native owner; retained casts/fusion and materialized pages are not charged
    /// twice in the allocator ceiling. Host media keeps its separate full bound.
    private func requireBatchMemory(extraState: Int = 0, extraNative: Int = 0, extraHost: Int = 0,
                                    entering: Bool = false) throws {
        guard let budget = batchBudget else { throw ProbeError("Qwen TP batch LOAD quote is missing") }
        let sum = QwenLongPrefillCheckedBytes.sum
        let held = batchBook.reservations()
        let native = try sum([budget.sharedBytesExcludingCollectives, budget.allowance.collectiveScratchBytes,
            sum(held.map(\.laneStateBytes)), sum(held.map { $0.media?.budget.nativeBytes ?? 0 }), extraState, extraNative])
        let host = try sum([sum(held.map { $0.media?.budget.hostBytes ?? 0 }), extraHost])
        let remaining = try QwenResidentRequestAllowance.continuingRequirement(reservedBytes: native,
            additionalBytes: 0, grownBytes: max(0, Memory.activeMemory - batchAllocationBaseline))
        try QwenResidentResourceEnvironment.requirePower()
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = try sum([remaining, host, entering ? QwenDenseStageLoadPolicy.loadingHeadroomBytes : 0])
        let allocator = try sum([Memory.activeMemory, Memory.cacheMemory, remaining, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard try batchResourceWatch.admits(os, bytes: free,
            floor: entering ? QwenDenseStageLoadPolicy.loadingHeadroomBytes : QwenDenseStageLoadPolicy.minimumTrulyFreeBytes),
            Memory.memoryLimit >= allocator else { throw ProbeError("Qwen TP batch exceeds its live memory allowance") }
    }

    public func serveBatch(host: QwenBatchServingHost) throws {
        guard operation.try() else { throw ProbeError("A tensor-parallel native operation is already active") }
        defer { operation.unlock() }
        _ = try batchPlan()
        guard let model, let batchHost else { throw ProbeError("Qwen TP batch has no model or KV host") }
        batchServing = true; defer { batchServing = false }
        batchOrdinal = try QwenBatchRecordBinding.nextOrdinal(after: batchOrdinal)
        let records = try QwenBatchRecordBinding(epoch: admission.configuration.identity.membershipEpoch,
            planFingerprint: admission.plan.fingerprint, ordinal: batchOrdinal, lanes: batchLanes)
        let observed = StageBatchObservation(rank: collective.rank, scope: records.requestID, capacity: batchLanes)
        observed.started(memory: batchHost.batchMemory).forEach { log($0) }
        let executor = try QwenTensorParallelNativeBatchExecutor<QwenTensorParallelOwnedBatchReservation>(
            model: model, configuration: admission.configBytes, host: batchHost, group: group,
            prepare: { [self] reserved, check in try prepareBatch(reserved, model: model, check: check) },
            completedDecode: { width in observed.completedDecode(width: width, memory: batchHost.batchMemory).forEach { log($0) } },
            completedPrefill: { observed.completedPrefill(memory: batchHost.batchMemory).forEach { log($0) } },
            releaseResources: { reserved in
                reserved.media?.finishHostPreparation()
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    try reserved.media?.releaseAfterCheckedDrain()
                }
            }, prefix: batchPrefix, prefixBudget: batchBudget?.prefix,
            prefixScope: { [self] reserved in
                loadAgreement + "|chunk=\(reserved.request.chunkSize)|kv=\(batchHost.kind.rawValue)"
                    + (reserved.media.map { "|media=" + $0.state.prefixIdentity } ?? "|text")
            }, allocationBound: QwenResidentResourceEnvironment.allocationBound,
            prefixObserved: { [self] event, tokens, bytes in
                log("darkbloom-tp-batch-prefix-v1 rank=\(collective.rank) scope=\(records.requestID) event=\(event) tokens=\(tokens) resident_bytes=\(bytes)")
            })
        let driver = try QwenTensorParallelBatchDriver(executor: executor, book: batchBook,
            capacity: batchLanes, vocabulary: admission.profile.vocabularySize)
        do {
            try lifecycle.withRequest(identity: .init(requestID: records.requestID, epoch: records.requestID,
                recordedRequestFingerprint: sha256(Data("qwen-tp-batch|\(loadAgreement)|\(batchOrdinal)".utf8)))) {
                try MLX.withError { error in
                    var lastResourceCheck: UInt64 = 0
                    try driver.serve(host: host, check: {
                        try error.check(); try self.control.check()
                        let now = DispatchTime.now().uptimeNanoseconds
                        if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                            try self.requireBatchMemory(); lastResourceCheck = now
                        }
                        try error.check()
                    })
                }
            }
            guard batchHost.isDrained else { throw ProbeError("Qwen TP successful batch retained native history") }
            observed.finished(success: true, memory: batchHost.batchMemory).forEach { log($0) }
            collective.logDataPlaneStatus()
        } catch {
            batchPrefix?.sweep()
            failedBatchDriver = driver; control.fail()
            observed.finished(success: false, memory: batchHost.batchMemory).forEach { log($0) }
            throw error
        }
    }

    private func prepareBatch(_ reserved: QwenTensorParallelOwnedBatchReservation, model: QwenTensorParallelModel,
                              check: () throws -> Void) throws -> QwenTensorParallelBatchInputs? {
        let fingerprint = sha256(try canonicalJSONData([reserved.request.fingerprint, loadAgreement]))
        for lower in stride(from: 0, to: fingerprint.count, by: 16) {
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: lower)
            let end = fingerprint.index(start, offsetBy: 16)
            guard let word = UInt64(fingerprint[start..<end], radix: 16), try group.digestsEqual(word) else {
                throw ProbeError("Qwen TP batch ranks differ in full request/load identity")
            }
        }
        try check()
        guard let media = reserved.media else { return nil }
        guard let visionInventory else { throw ProbeError("Qwen TP batch media source is unavailable") }
        // Cancellation is applied at the next shared driver boundary. Once a
        // preparation phase is announced, both ranks complete/drain it; an
        // individual stop cannot strand its peer or invalidate other lanes.
        try QwenTensorParallelMedia.prepare(media, vision: vision, inventory: visionInventory,
            modelConfiguration: admission.configBytes, rank: collective.rank, group: group,
            chunkTokens: reserved.request.chunkSize, shouldStop: { false }, check: check)
        return .init(positions: { try media.state.positions(in: $0) },
            promptEmbedding: { input, range in try media.state.merging(model.embeddingsForMedia(input), range: range) })
    }
}
