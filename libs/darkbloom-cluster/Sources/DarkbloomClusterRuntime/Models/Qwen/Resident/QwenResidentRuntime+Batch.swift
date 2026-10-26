import DarkbloomClusterProtocol
import Foundation
import MLX

/// One request in the batch loop on this rank.
final class QwenBatchLane {
    let id: UUID
    let slot: Int
    let order: Int
    let reserved: QwenResidentReservation
    /// The prefix cache's key scope, the one the one-request path uses.
    let scope: String
    /// The planned request both ranks run: from the agreed reused prefix, the
    /// last prompt token split off exactly when both prefix caches are on.
    var request: QwenLayerStageGenerationRequest
    /// Nil while the lane's prefix agreement is open (the step it joined).
    var session: QwenLayerStageSession?
    var selected: [Int] = []
    var reusedPrefix = 0
    /// Rank 0: the frontiers it offered at join. Rank 1: the frontier it
    /// restored at join and the session that holds it, until confirmed.
    var offers: [Int] = []
    var restored: (frontier: Int, session: QwenLayerStageSession)?
    /// Rank 0: the agreement settled after this lane's join; the next header
    /// confirms it.
    var confirmPending = false

    init(id: UUID, slot: Int, order: Int, reserved: QwenResidentReservation, scope: String) {
        self.id = id; self.slot = slot; self.order = order; self.reserved = reserved; self.scope = scope
        self.request = reserved.request
    }

    var fingerprintWords: [Int32] { QwenBatchWire.fingerprintWords(reserved.request.fingerprint) }
    var committedTokens: Int { session?.committedTokens ?? 0 }
    var recordLane: QwenBatchRecordBinding.Lane {
        .init(slot: slot, requestID: id, requestFingerprint: reserved.request.fingerprint,
            committedTokens: committedTokens, selectedTokens: selected.count)
    }
    var nextPhase: QwenLayerStageFrame.Phase? { session?.nextFrame?.phase }

    /// How the request finishes after its latest token, or nil to go on.
    func finish(continueRequested: Bool) -> QwenLayerStageGenerationFinishReason? {
        guard let last = selected.last else { return nil }
        if request.stopTokenIDs.contains(last) { return .eos }
        if selected.count == request.outputCount { return .length }
        return continueRequested ? nil : .clientStop
    }

    func cancel() {
        try? session?.cancel(); try? restored?.session.cancel()
        session = nil; restored = nil
    }
}

/// The lanes in the loop on this rank, by slot. A reference, so the loop's
/// checks can read it while a step changes it.
final class QwenBatchLaneTable {
    var slots: [Int: QwenBatchLane] = [:]
    var count: Int { slots.count }
    var isEmpty: Bool { slots.isEmpty }
    var values: Dictionary<Int, QwenBatchLane>.Values { slots.values }
    var keys: Dictionary<Int, QwenBatchLane>.Keys { slots.keys }
    subscript(slot: Int) -> QwenBatchLane? {
        get { slots[slot] }
        set { slots[slot] = newValue }
    }
}

/// Continuous batching on the pair (pipeline mode). Both ranks run the same
/// loop in lockstep: rank 0 decides each step (which lanes join, which decode
/// together, which one runs its next prefill frame, which leave) and sends
/// that as a fixed header; rank 1 follows it and answers with the tokens it
/// selected. Requests reach both ranks through their owners (reserve and
/// start, as for one request); the header only names them, with the first
/// bytes of the request fingerprint, so both ranks provably run the same one.
///
/// Prefill frames keep the arithmetic of the request run alone: they end on
/// the request's own chunk grid (one frame per step, earliest joined lane
/// first) and the last prompt token is split off exactly when the one-request
/// path splits it. Decode rows attend only their own KV. Each model adapter
/// owns its arithmetic-preserving batch forward; unscoped multi-row matmul
/// can select a different reduction kernel from singleton decode. Exact output
/// agreement therefore requires separate artifact/pair qualification. Request-local selection
/// runs on rank 1, as for one request; each sampled lane keeps its own state.
extension QwenResidentRuntime {
    /// Lane reservation: the same request allowance a single request gets,
    /// gated live together with every lane already charged. A full set of
    /// lanes or a host that cannot hold one more is a refusal, not a failure.
    public func reserveLane(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try withExclusiveOperation {
            guard batch.batching, generationMode == .pipeline, let stage = stageForBatch else {
                throw ProbeError("Batch lanes are not configured for this resident owner")
            }
            let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
            try admission.requireWithinMemoryProfile(value)
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let allowance = try stage.requestAllowance(plan: admission.plan, rank: collective.rank,
                maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
                bound: QwenResidentResourceEnvironment.allocationBound)
            guard allowance.reservedBytes <= value.capacityLimitBytes,
                  allowance.reservedBytes <= baseReady.requestCapacityBytes,
                  laneBook.count < batch.lanes else {
                throw ProbeError("Batch lane reservation exceeds its owner ceiling or every lane is taken")
            }
            let others = try laneBook.stateBytes()
            try prefixCache.yieldingMemory { try allowance.requireLive(additionalNativeBytes: others, onLoadedStage: true) }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            try laneBook.reserve(requestID, .init(request: request, allowance: allowance,
                deadline: value.deadlineUptimeNanoseconds, mode: .serving, recordingCharge: nil,
                prefillPolicy: .serial, prefillAllowance: nil), lanes: batch.lanes)
            return allowance.reservedBytes
        }
    }

    public func startLane(requestID: UUID) throws { try laneBook.start(requestID) }
    public func cancelLane(requestID: UUID) { laneBook.cancel(requestID) }
    /// Gives back a lane that was reserved but never started (`QwenBatchLaneBook.withdraw`).
    public func withdrawLane(requestID: UUID) -> Bool { laneBook.withdraw(requestID) }
    /// Started lanes wait for the loop; the worker re-enters it while any do.
    public var hasStartedLanes: Bool { laneBook.hasStarted }
    public var hasLanes: Bool { !laneBook.isEmpty }

    /// Runs the batch loop until no lane is left on rank 0's side. Returns only
    /// after every lane that finished published its finish; throws on any
    /// failure, after retiring every lane's native state.
    public func serveBatch(host: QwenBatchServingHost) throws {
        try withExclusiveOperation {
            guard batch.batching, generationMode == .pipeline, let stage = stageForBatch,
                  let kvHost = stage.loaded.kvHost.host else {
                throw ProbeError("Batch lanes are not configured for this resident owner")
            }
            batchServing = true
            defer { batchServing = false }
            let lanes = QwenBatchLaneTable()
            let scope = UUID()
            var observation: StageBatchObservation?
            do {
                batchRecordOrdinal = try QwenBatchRecordBinding.nextOrdinal(after: batchRecordOrdinal)
                let records = try QwenBatchRecordBinding(epoch: admission.configuration.identity.membershipEpoch,
                    planFingerprint: admission.plan.fingerprint, ordinal: batchRecordOrdinal, lanes: batch.lanes)
                let observed = StageBatchObservation(rank: collective.rank, scope: records.requestID, capacity: batch.lanes)
                observation = observed
                observed.started(memory: kvHost.batchMemory).forEach { log($0) }
                try lifecycle.withRequest(identity: .init(requestID: scope, epoch: scope,
                        recordedRequestFingerprint: sha256(Data("qwen-batch-scope-v1|\(scope.uuidString)".utf8)))) {
                    try autoreleasepool {
                        try MLX.withError { nativeError in
                            var lastResourceCheck: UInt64 = 0
                            func checked() throws {
                                try nativeError.check(); try control.check()
                                let now = DispatchTime.now().uptimeNanoseconds
                                // Request cancellation waits for a shared step boundary.
                                // An announced collective must complete on both ranks.
                                if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                                    // Kept prefixes give way to the lanes' own admission.
                                    let allowances = laneBook.allowances()
                                    if let first = allowances.first {
                                        let others = try QwenLongPrefillCheckedBytes.sum(allowances.dropFirst().map(\.stateBytes))
                                        try prefixCache.yieldingMemory { try first.requireLive(additionalNativeBytes: others, onLoadedStage: true) }
                                    }
                                    lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                                }
                                try nativeError.check()
                            }
                            let opening = try openBatch(stage: stage, records: records, check: checked)
                            let split = opening
                            if collective.rank == 0 {
                                try leadBatch(stage: stage, split: split, lanes: lanes, host: host, records: records, observation: observed, check: checked)
                            } else {
                                try followBatch(stage: stage, split: split, lanes: lanes, host: host, records: records, observation: observed, check: checked)
                            }
                        }
                    }
                }
                observed.finished(success: true, memory: kvHost.batchMemory).forEach { log($0) }
            } catch {
                var primary: Error = error
                for lane in lanes.values {
                    do { try lane.session?.cancel(); try lane.restored?.session.cancel() }
                    catch { primary = ProbeError("\(primary); lane retirement also failed (\(error))") }
                }
                lanes.slots.removeAll(); laneBook.clear()
                prefixCache.sweep(); control.fail()
                observation?.finished(success: false, memory: kvHost.batchMemory).forEach { log($0) }
                throw primary
            }
        }
    }

    /// The loop's first exchange. Returns whether the last prompt token is
    /// split off (both prefix caches on).
    private func openBatch(stage: any LayerStageResidentStage, records: QwenBatchRecordBinding,
                           check: () throws -> Void) throws -> Bool {
        let local = QwenBatchWire.Opening(lanes: batch.lanes, pagedKV: stage.loaded.kvHost.host?.kind == .paged,
            prefixCacheEnabled: prefixCache.enabled, vocabularySize: admission.profile.vocabularySize,
            hiddenSize: admission.profile.hiddenSize)
        let peer = try QwenBatchWire.Opening(words: exchangeBatchWords(local.words, records: records, check: check))
        guard peer.lanes == local.lanes, peer.pagedKV == local.pagedKV,
              peer.vocabularySize == local.vocabularySize, peer.hiddenSize == local.hiddenSize else {
            throw ProbeError("Batch peers differ in lanes, KV storage or model geometry")
        }
        return local.prefixCacheEnabled && peer.prefixCacheEnabled
    }

    // MARK: Lanes

    /// The prefix scope of a lane: the one-request path's agreement for this
    /// request (pipeline, serial prefill), so both paths share cache entries.
    private func laneScope(stage: any LayerStageResidentStage, reserved: QwenResidentReservation) throws -> String {
        let receipt = stage.loaded.receipt
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint, producerStageFingerprint: admission.plan.stages[0].fingerprint)
        let agreement = try QwenLayerStageGenerationAgreement(request: reserved.request,
            membershipEpoch: admission.configuration.identity.membershipEpoch, source: source,
            consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256, prefillPolicy: .serial)
        return qwenStagePrefixScope(agreement)
    }

    private func newLane(stage: any LayerStageResidentStage, id: UUID, reserved: QwenResidentReservation,
                         slot: Int, order: Int) throws -> QwenBatchLane {
        QwenBatchLane(id: id, slot: slot, order: order, reserved: reserved,
            scope: try laneScope(stage: stage, reserved: reserved))
    }

    /// A session for the lane from `reusedPrefix` (0: cold), restoring this
    /// rank's cached state there. Nil when the restore fails.
    private func laneSession(stage: any LayerStageResidentStage, lane: QwenBatchLane, reusedPrefix: Int,
                             split: Bool) -> (QwenLayerStageGenerationRequest, QwenLayerStageSession)? {
        do {
            let planned = try lane.reserved.request.planned(reusedPrefix: reusedPrefix, splitFinalToken: split)
            let session: QwenLayerStageSession
            if reusedPrefix > 0 {
                guard let state = prefixCache.state(scope: lane.scope, tokens: planned.promptTokenIDs,
                                                    frontier: reusedPrefix) else { return nil }
                session = try QwenLayerStageSession(stage: stage.loaded, plan: admission.plan,
                    generationRequest: planned, adopting: state.adopted)
            } else {
                session = try QwenLayerStageSession(stage: stage.loaded, plan: admission.plan, generationRequest: planned)
            }
            if split, prefixCache.enabled {
                session.prefixCaptureFrontiers = planned.prefixCaptureFrontiers(
                    stride: prefixCache.stride(chunkSize: planned.chunkSize))
            }
            return (planned, session)
        } catch {
            log("darkbloom-batch-v1 rank=\(collective.rank) lane-session-failed reused=\(reusedPrefix): \(error)")
            return nil
        }
    }

    private func installSession(_ lane: QwenBatchLane, _ value: (QwenLayerStageGenerationRequest, QwenLayerStageSession),
                                reusedPrefix: Int) {
        lane.request = value.0; lane.session = value.1; lane.reusedPrefix = reusedPrefix
    }

    private func coldSession(stage: any LayerStageResidentStage, lane: QwenBatchLane, split: Bool) throws {
        guard let value = laneSession(stage: stage, lane: lane, reusedPrefix: 0, split: split) else {
            throw ProbeError("Batch lane could not open its request state")
        }
        installSession(lane, value, reusedPrefix: 0)
    }

    /// Finishes a lane on this rank: retires its state, keeps its captured
    /// prompt frontiers, and publishes the prefix report and the finish.
    private func finishLane(_ lane: QwenBatchLane, reason: QwenLayerStageGenerationFinishReason,
                            host: QwenBatchServingHost) throws {
        guard let session = lane.session else { throw ProbeError("Batch lane finished without request state") }
        try session.finishGeneration(reason, selectedTokenCount: lane.selected.count, lastTokenID: lane.selected.last!)
        guard session.isClosed, !session.isFailed else { throw ProbeError("Batch lane native state failed retirement") }
        var stored: [Int] = []
        if prefixCache.enabled {
            let states = session.capturedPrefixStates()
            prefixCache.insert(scope: lane.scope, tokens: lane.request.promptTokenIDs, states: states)
            stored = states.map(\.committedTokens)
        }
        session.discardCapturedPrefix()
        if lane.reusedPrefix > 0 || !stored.isEmpty {
            try host.publishPromptCache(requestID: lane.id, reusedTokens: lane.reusedPrefix,
                storedFrontiers: Array(stored.sorted().suffix(32)))
        }
        try host.publishFinished(requestID: lane.id, reason: ClusterWorkerFinishReason(rawValue: reason.rawValue)!)
        laneBook.finish(lane.id)
    }

    private func cancellationRequested(_ lane: QwenBatchLane) -> Bool {
        QwenBatchCancellation.requested(ownerCancelled: laneBook.isCancelled(lane.id),
            deadline: lane.reserved.deadline, now: DispatchTime.now().uptimeNanoseconds)
    }

    /// A cancelled lane keeps its charge until all native sessions retired.
    /// Captured prefixes are discarded, never inserted into the prompt cache.
    private func cancelLane(_ lane: QwenBatchLane, host: QwenBatchServingHost) throws {
        var sessions: [any QwenBatchCancellableSession] = []
        if let session = lane.session { sessions.append(session) }
        if let restored = lane.restored { sessions.append(restored.session) }
        try QwenBatchCancellation.retire(sessions: sessions, release: {
            lane.session = nil; lane.restored = nil
            laneBook.finish(lane.id)
        }, publish: { try host.publishLeft(requestID: lane.id) })
    }

    // MARK: Rank 0

    private func leadBatch(stage: any LayerStageResidentStage, split: Bool, lanes: QwenBatchLaneTable,
                           host: QwenBatchServingHost, records: QwenBatchRecordBinding,
                           observation: StageBatchObservation, check: () throws -> Void) throws {
        var step = 0, order = 0
        let trace = try QwenBatchRowCapture.traceRequested()
        var summary = QwenBatchStepSummary()
        defer { if trace { log(summary.line) } }
        var decisions = QwenBatchDecisionProgress()
        var coalescing = QwenBatchDecodeCoalescing()
        var peerCancelled = Set<UUID>()
        var leaving: [Int: (id: UUID, reason: QwenLayerStageGenerationFinishReason?, cancelled: Bool, selected: Int)] = [:]
        // One autorelease scope per step, as the one-request loop has per frame.
        while try !autoreleasepool(invoking: { () throws -> Bool in
            let pendingCredits = decisions.pendingCount
            let answered = try decisions.serviceAndPoll(host)
            try check()
            for slot in lanes.keys.sorted() {
                let lane = lanes[slot]!
                if cancellationRequested(lane) || peerCancelled.contains(lane.id) {
                    try cancelLane(lane, host: host)
                    decisions.retired(lane.id)
                    peerCancelled.remove(lane.id)
                    leaving[slot] = (lane.id, nil, true, lane.selected.count)
                    lanes[slot] = nil
                } else if let proceed = answered[lane.id], let reason = lane.finish(continueRequested: proceed) {
                    try finishLane(lane, reason: reason, host: host)
                    leaving[slot] = (lane.id, reason, false, lane.selected.count)
                    lanes[slot] = nil
                }
            }
            var joining = Set<Int>()
            while lanes.count + leaving.count < batch.lanes, let (id, reserved) = laneBook.takeStarted() {
                guard let slot = (0..<batch.lanes).first(where: { lanes[$0] == nil && leaving[$0] == nil }) else { break }
                let lane = try newLane(stage: stage, id: id, reserved: reserved, slot: slot, order: order)
                if split {
                    // The agreement runs in this step; frames start in the next.
                    lane.offers = Array(reserved.request.admittedPrefixFrontiers(prefixCache.frontiers(scope: lane.scope,
                        tokens: reserved.request.promptTokenIDs, maximumFrontier: reserved.request.promptCount - 1))
                        .prefix(QwenBatchWire.maximumOffers))
                } else {
                    try coldSession(stage: stage, lane: lane, split: false)
                }
                lanes[slot] = lane
                order += 1; joining.insert(slot)
            }
            let stop = lanes.isEmpty
            // The step's plan: every decoding lane together, one prefill frame.
            let decodeLanes = lanes.keys.sorted().filter {
                lanes[$0]!.nextPhase == .decode && !cancellationRequested(lanes[$0]!)
            }
            var decodeSlots = decodeLanes.filter { decisions.canForward(lanes[$0]!.id) }
            let prefillSlot = lanes.values.filter {
                $0.nextPhase == .prefill && decisions.canForward($0.id) && !cancellationRequested($0)
            }.min(by: { $0.order < $1.order })?.slot
            // Keep control exchanges moving while nearby token credits arrive.
            // The absolute window cannot be extended by additional answers.
            if coalescing.shouldDefer(ready: decodeSlots.count, pending: decodeLanes.count - decodeSlots.count,
                hasOtherWork: prefillSlot != nil || !joining.isEmpty || !leaving.isEmpty,
                now: { DispatchTime.now().uptimeNanoseconds }) {
                decodeSlots.removeAll(keepingCapacity: true)
            }
            var slots = [QwenBatchWire.Slot](repeating: .init(), count: batch.lanes)
            for (slot, left) in leaving {
                slots[slot] = .init(state: .leaving, requestID: left.id, selectedTokens: left.selected,
                    leaveReason: left.reason, leaveCancelled: left.cancelled)
            }
            for (slot, lane) in lanes.slots {
                var value = QwenBatchWire.Slot(state: joining.contains(slot) ? .joining : .active, requestID: lane.id)
                value.committedTokens = lane.committedTokens; value.selectedTokens = lane.selected.count
                value.fingerprintWords = lane.fingerprintWords
                if joining.contains(slot) { value.offers = lane.offers }
                if lane.confirmPending { value.confirming = true; value.reusedPrefix = lane.reusedPrefix }
                if decodeSlots.contains(slot) {
                    value.role = .decode; value.inputToken = lane.selected.last ?? -1
                } else if slot == prefillSlot, let frame = lane.session?.nextFrame {
                    value.role = .prefill; value.frameOffset = frame.tokenOffset
                    value.frameCount = frame.tokenCount; value.finalChunk = frame.finalPromptChunk
                }
                slots[slot] = value
            }
            if trace {
                summary.record(width: decodeSlots.count, pending: pendingCredits, answered: answered.count,
                    prefill: prefillSlot != nil, joining: joining.count, leaving: leaving.count)
            }
            try sendBatchWords(QwenBatchWire.Header(step: step, stop: stop, slots: slots).words,
                scope: records.header(step: step), check: check)
            leaving.removeAll()
            for lane in lanes.values { lane.confirmPending = false }
            if stop { return true }

            if !decodeSlots.isEmpty {
                let record = try records.residual(step: step, kind: .decode,
                    lanes: decodeSlots.map { lanes[$0]!.recordLane })
                let residual = try QwenLayerStageSession.decodeBatch(decodeSlots.map { lanes[$0]!.session! },
                    tokens: decodeSlots.map { lanes[$0]!.selected.last! }, residual: nil, check: check)
                observation.completedDecode(width: decodeSlots.count, memory: stage.loaded.kvHost.host!.batchMemory).forEach { log($0) }
                try sendBatchResidual(residual, digest: sha256(residual.asData().data), records: record, check: check)
            }
            var finalPrefill = false
            if let slot = prefillSlot, let lane = lanes[slot], let session = lane.session, let frame = session.nextFrame {
                let record = try records.residual(step: step,
                    kind: .prefill(offset: frame.tokenOffset, count: frame.tokenCount, final: frame.finalPromptChunk),
                    lanes: [lane.recordLane])
                let tokens = Array(lane.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                guard case .hidden(let boundary) = try session.prefillChunk(tokens, offset: frame.tokenOffset,
                        final: frame.finalPromptChunk, check: check) else {
                    throw ProbeError("Batch producer prefill did not return a residual")
                }
                observation.completedPrefill(memory: stage.loaded.kvHost.host!.batchMemory).forEach { log($0) }
                try sendBatchResidual(boundary.array, digest: boundary.payloadSHA256, records: record, check: check)
                finalPrefill = frame.finalPromptChunk
            }
            let reply = try QwenBatchWire.Reply(words: receiveBatchWords(QwenBatchWire.replyWords, scope: records.reply(step: step), check: check),
                expectedStep: step, lanes: batch.lanes)
            peerCancelled.formUnion(try QwenBatchCancellation.peerRequests(mask: reply.cancelledMask, slots: slots))
            // Prefix agreements of this step's joins: rank 1 restored what it
            // could of what was offered; rank 0 restores the same frontier or
            // both start cold (the next header says which).
            for slot in joining {
                guard let lane = lanes[slot], lane.session == nil else { continue }
                let peer = reply.restored[slot]
                guard peer == 0 || lane.offers.contains(peer) else {
                    throw ProbeError("Batch peer restored a frontier that was not offered")
                }
                // A cancelled accepted start still joins on both ranks. Its
                // next header retires that matched identity without a forward.
                if cancellationRequested(lane) || peerCancelled.contains(lane.id) { continue }
                if peer > 0, let value = laneSession(stage: stage, lane: lane, reusedPrefix: peer, split: split) {
                    installSession(lane, value, reusedPrefix: peer)
                } else {
                    try coldSession(stage: stage, lane: lane, split: split)
                }
                lane.confirmPending = true
                if peer > 0 || lane.reusedPrefix > 0 {
                    log("darkbloom-prefix-v1 rank=0 batch-lane agreed=\(peer) reused=\(lane.reusedPrefix) prompt=\(lane.request.promptCount)")
                }
            }
            for slot in joining where reply.restored[slot] != 0 && !split {
                throw ProbeError("Batch peer restored a prefix with the caches off")
            }
            for slot in 0..<batch.lanes {
                let expected = decodeSlots.contains(slot) || (slot == prefillSlot && finalPrefill)
                guard (reply.tokens[slot] >= 0) == expected else {
                    throw ProbeError("Batch reply tokens differ from the step's plan")
                }
                guard expected, let lane = lanes[slot] else { continue }
                guard (0..<admission.profile.vocabularySize).contains(reply.tokens[slot]) else {
                    throw ProbeError("Batch reply token is outside the vocabulary")
                }
                lane.selected.append(reply.tokens[slot])
                try check()
                // Both ranks keep the selected frontier for the next leave,
                // but a known cancelled lane publishes no additional output.
                if cancellationRequested(lane) || peerCancelled.contains(lane.id) { continue }
                try decisions.published(lane.id)
                try host.publishToken(requestID: lane.id, ordinal: lane.selected.count - 1, tokenID: reply.tokens[slot],
                    committedTokens: lane.request.promptCount + lane.selected.count - 1)
            }
            // An unanswered token must not stop control on either rank. A
            // role.none step carries no model forward, but lets the follower
            // admit reservations before the provider can answer older tokens.
            if decodeSlots.isEmpty && prefillSlot == nil && joining.isEmpty {
                Thread.sleep(forTimeInterval: 0.0005)
            }
            step += 1
            return false
        }) {}
    }

    // MARK: Rank 1

    private func followBatch(stage: any LayerStageResidentStage, split: Bool, lanes: QwenBatchLaneTable,
                             host: QwenBatchServingHost, records: QwenBatchRecordBinding,
                             observation: StageBatchObservation, check: () throws -> Void) throws {
        var step = 0, order = 0
        let capture = try QwenBatchRowCapture.fromEnvironment()
        while try !autoreleasepool(invoking: { () throws -> Bool in
            let header = try QwenBatchWire.Header(words: receiveBatchWords(QwenBatchWire.headerWords, scope: records.header(step: step), check: check),
                expectedStep: step, lanes: batch.lanes)
            for (slot, value) in header.slots.enumerated() where value.state == .leaving {
                guard let lane = lanes[slot], lane.id == value.requestID,
                      value.selectedTokens == lane.selected.count else {
                    throw ProbeError("Batch header ends a lane this rank does not hold, or at another frontier")
                }
                if value.leaveCancelled {
                    try cancelLane(lane, host: host)
                } else {
                    guard let reason = value.leaveReason,
                          lane.finish(continueRequested: reason != .clientStop) == reason else {
                        throw ProbeError("Batch header ends a lane for another reason")
                    }
                    if cancellationRequested(lane) { try cancelLane(lane, host: host) }
                    else { try finishLane(lane, reason: reason, host: host) }
                }
                lanes[slot] = nil
            }
            // The previous step's joins: rank 0's decision on the prefix.
            for (slot, value) in header.slots.enumerated() where value.confirming {
                guard value.state == .active, let lane = lanes[slot], lane.id == value.requestID, lane.session == nil else {
                    throw ProbeError("Batch header confirms a lane that is not waiting for its agreement")
                }
                if value.reusedPrefix > 0 {
                    guard let restored = lane.restored, restored.frontier == value.reusedPrefix else {
                        throw ProbeError("Batch header confirms a prefix this rank did not restore")
                    }
                    lane.restored = nil
                    installSession(lane, (restored.session.request, restored.session), reusedPrefix: value.reusedPrefix)
                } else {
                    try lane.restored?.session.cancel(); lane.restored = nil
                    try coldSession(stage: stage, lane: lane, split: split)
                }
            }
            var restoredNow = [Int](repeating: 0, count: batch.lanes)
            for (slot, value) in header.slots.enumerated() where value.state == .joining {
                guard lanes[slot] == nil, let id = value.requestID else {
                    throw ProbeError("Batch header joins a lane into an occupied slot")
                }
                // The owner starts both ranks; this rank's start may still be on its way.
                while !laneBook.isStarted(id) {
                    try host.serviceControl(); try check()
                    if !laneBook.isStarted(id) { Thread.sleep(forTimeInterval: 0.0005) }
                }
                guard let reserved = laneBook.takeStarted(id) else { throw ProbeError("Batch lane vanished before joining") }
                let lane = try newLane(stage: stage, id: id, reserved: reserved, slot: slot, order: order)
                order += 1
                lanes[slot] = lane
                guard lane.fingerprintWords == value.fingerprintWords else {
                    throw ProbeError("Batch lane request differs between the ranks' owners")
                }
                if split {
                    // The deepest frontier both hold; restored now, kept only if rank 0 confirms it.
                    let local = Set(reserved.request.admittedPrefixFrontiers(prefixCache.frontiers(scope: lane.scope,
                        tokens: reserved.request.promptTokenIDs, maximumFrontier: reserved.request.promptCount - 1)))
                    if let frontier = value.offers.filter({ local.contains($0) }).max(),
                       let restored = laneSession(stage: stage, lane: lane, reusedPrefix: frontier, split: split) {
                        lane.restored = (frontier, restored.1); restoredNow[slot] = frontier
                    }
                } else {
                    guard value.offers.isEmpty else { throw ProbeError("Batch header offers prefixes with the caches off") }
                    try coldSession(stage: stage, lane: lane, split: false)
                }
            }
            for (slot, value) in header.slots.enumerated() {
                switch value.state {
                case .empty, .leaving:
                    guard lanes[slot] == nil else { throw ProbeError("Batch header leaves out a lane this rank holds") }
                case .joining, .active:
                    guard let lane = lanes[slot], lane.id == value.requestID,
                          lane.committedTokens == value.committedTokens,
                          lane.selected.count == value.selectedTokens,
                          value.state == .joining || lane.session != nil else {
                        throw ProbeError("Batch lane frontier or selection differs between the ranks")
                    }
                }
            }
            if header.stop {
                guard lanes.isEmpty else { throw ProbeError("Batch stop names lanes still running") }
                return true
            }
            try host.serviceControl()
            try check()
            var tokens = [Int](repeating: -1, count: batch.lanes)
            let decodeSlots = header.slots.indices.filter { header.slots[$0].role == .decode }
            if !decodeSlots.isEmpty {
                for slot in decodeSlots {
                    guard let lane = lanes[slot], lane.nextPhase == .decode,
                          header.slots[slot].inputToken == lane.selected.last else {
                        throw ProbeError("Batch decode row differs from this rank's lane")
                    }
                }
                let record = try records.residual(step: step, kind: .decode,
                    lanes: decodeSlots.map { lanes[$0]!.recordLane })
                let residual = try receiveBatchResidual(shape: [decodeSlots.count, 1, admission.profile.hiddenSize],
                    dtype: stage.loaded.activationDType, records: record, check: check)
                let logits = try QwenLayerStageSession.decodeBatch(decodeSlots.map { lanes[$0]!.session! },
                    tokens: decodeSlots.map { lanes[$0]!.selected.last! }, residual: residual.array, check: check)
                observation.completedDecode(width: decodeSlots.count, memory: stage.loaded.kvHost.host!.batchMemory).forEach { log($0) }
                let selected = try Self.selectBatchTokens(logits,
                    requests: decodeSlots.map { lanes[$0]!.request }, check: check)
                for (row, slot) in decodeSlots.enumerated() {
                    if let capture, QwenBatchRowCapture.ordinals.contains(lanes[slot]!.selected.count) {
                        try captureBatchRow(capture, lane: lanes[slot]!, step: step, row: row,
                            width: decodeSlots.count, phase: "decode", token: selected[row],
                            logits: logits[row..<(row + 1)], check: check)
                    }
                    tokens[slot] = selected[row]; lanes[slot]!.selected.append(selected[row])
                }
            }
            if let slot = header.slots.indices.first(where: { header.slots[$0].role == .prefill }) {
                let value = header.slots[slot]
                guard let lane = lanes[slot], let session = lane.session, let frame = session.nextFrame,
                      frame.phase == .prefill, frame.tokenOffset == value.frameOffset,
                      frame.tokenCount == value.frameCount, frame.finalPromptChunk == value.finalChunk else {
                    throw ProbeError("Batch prefill frame differs from this rank's lane")
                }
                let record = try records.residual(step: step,
                    kind: .prefill(offset: frame.tokenOffset, count: frame.tokenCount, final: frame.finalPromptChunk),
                    lanes: [lane.recordLane])
                let received = try receiveBatchResidual(shape: [1, frame.tokenCount, admission.profile.hiddenSize],
                    dtype: stage.loaded.activationDType, records: record, check: check)
                let ids = Array(lane.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                let identity = session.identity
                let boundary = QwenLayerStageBoundary(requestFingerprint: identity.requestFingerprint,
                    sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                    artifactAggregateSHA256: identity.artifactAggregateSHA256,
                    storageCommitmentSHA256: identity.storageCommitmentSHA256,
                    planFingerprint: identity.planFingerprint, producerStageFingerprint: admission.plan.stages[0].fingerprint,
                    frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(ids),
                    payloadSHA256: received.digest, array: received.array)
                let output = try session.prefillChunk(ids, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                    incoming: boundary, check: check)
                observation.completedPrefill(memory: stage.loaded.kvHost.host!.batchMemory).forEach { log($0) }
                switch output {
                case .evaluationHandle where !frame.finalPromptChunk: break
                case .logits(let row) where frame.finalPromptChunk:
                    let token = try QwenLayerStageGenerationSelection.token(row, request: lane.request, check: check)
                    if let capture {
                        try captureBatchRow(capture, lane: lane, step: step, row: 0, width: 1,
                            phase: "prefill", token: token, logits: row, check: check)
                    }
                    tokens[slot] = token; lane.selected.append(token)
                default: throw ProbeError("Batch consumer prefill output does not match its frame")
                }
            }
            // An owner cancel may have arrived during this announced forward.
            // Finish the collective, then ask rank 0 for a common leave step.
            try host.serviceControl()
            let cancelledMask = lanes.values.reduce(0) {
                $0 | (cancellationRequested($1) ? (1 << $1.slot) : 0)
            }
            try sendBatchWords(QwenBatchWire.Reply(step: step, tokens: tokens, restored: restoredNow,
                cancelledMask: cancelledMask).words,
                scope: records.reply(step: step), check: check)
            step += 1
            return false
        }) {}
    }

    private func captureBatchRow(_ capture: QwenBatchRowCapture, lane: QwenBatchLane, step: Int,
                                 row: Int, width: Int, phase: String, token: Int,
                                 logits: MLXArray, check: () throws -> Void) throws {
        try capture.capture(.init(batchOrdinal: batchRecordOrdinal, step: step, slot: lane.slot, row: row,
            decodeWidth: width, phase: phase, requestID: lane.id,
            requestFingerprint: lane.reserved.request.fingerprint, promptTokens: lane.request.promptTokenIDs,
            priorSelectedTokens: lane.selected, selectedToken: token),
            shape: logits.shape, dtype: String(describing: logits.dtype)) {
                let bytes = logits.asData(access: .copy).data
                try check()
                return bytes
            }
    }

    /// Each row uses its own request's sampler and committed history. Plain
    /// greedy batches keep the existing vectorized finite argmax path.
    static func selectBatchTokens(_ logits: MLXArray, requests: [QwenLayerStageGenerationRequest],
                                  check: () throws -> Void) throws -> [Int] {
        let rows = requests.count
        guard let request = requests.first,
              requests.allSatisfy({ $0.profile.vocabularySize == request.profile.vocabularySize
                  && $0.profile.selectedRowDType == request.profile.selectedRowDType }),
              logits.shape == [rows, request.profile.vocabularySize],
              String(describing: logits.dtype) == request.profile.selectedRowDType else {
            throw ProbeError("Batch selected rows differ from the admitted native shape/dtype")
        }
        if requests.contains(where: { $0.sampler != nil }) {
            // Reject the whole matrix before any sampler advances its output
            // index or penalties; an invalid later row must not commit earlier ones.
            let finite = all(isFinite(logits), axes: [-1])
            eval(logits, finite); try check()
            guard finite.shape == [rows], finite.asArray(Bool.self).allSatisfy({ $0 }) else {
                throw ProbeError("Batch target logits are not finite")
            }
            return try requests.enumerated().map { row, request in
                try QwenLayerStageGenerationSelection.token(logits[row..<(row + 1)], request: request, check: check)
            }
        }
        let selected = argMax(logits, axis: -1), finite = all(isFinite(logits), axes: [-1])
        eval(logits, selected, finite); try check()
        guard selected.shape == [rows], selected.dtype == .uint32, finite.shape == [rows] else {
            throw ProbeError("Batch finite argmax contract differs")
        }
        guard finite.asArray(Bool.self).allSatisfy({ $0 }) else { throw ProbeError("Batch target logits are not finite") }
        let tokens = selected.asArray(UInt32.self).map { Int($0) }
        guard tokens.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
            throw ProbeError("Batch selected token outside vocabulary")
        }
        try check()
        return tokens
    }

    // MARK: Transfers

    private func exchangeBatchWords(_ words: [Int32], records: QwenBatchRecordBinding,
                                    check: () throws -> Void) throws -> [Int32] {
        let sending = try records.opening(fromRank: collective.rank)
        let receiving = try records.opening(fromRank: 1 - collective.rank)
        if collective.rank == 0 {
            try sendBatchWords(words, scope: sending, check: check)
            return try receiveBatchWords(words.count, scope: receiving, check: check)
        }
        let peer = try receiveBatchWords(words.count, scope: receiving, check: check)
        try sendBatchWords(words, scope: sending, check: check)
        return peer
    }

    private func sendBatchWords(_ words: [Int32], scope: CollectiveRecordScope, check: () throws -> Void) throws {
        let array = MLXArray(words)
        _ = try collective.sendCompleted(array, to: 1 - collective.rank, maximumBytes: words.count * 4,
            scope: scope, check: check)
    }

    private func receiveBatchWords(_ count: Int, scope: CollectiveRecordScope, check: () throws -> Void) throws -> [Int32] {
        let words = try collective.receiveCompleted(shape: [count], dtype: .int32, from: 1 - collective.rank,
            maximumBytes: count * 4, scope: scope, check: check).asArray(Int32.self)
        try check()
        return words
    }

    /// A residual, then its SHA-256 as eight words: the receiver verifies the
    /// bytes it got against the digest, as the one-request boundary does.
    private func sendBatchResidual(_ array: MLXArray, digest: String,
                                   records: QwenBatchRecordBinding.ResidualRecords, check: () throws -> Void) throws {
        _ = try collective.sendCompleted(array, to: 1, maximumBytes: array.nbytes, scope: records.payload, check: check)
        try sendBatchWords(Self.digestWords(digest), scope: records.digest, check: check)
    }

    private func receiveBatchResidual(shape: [Int], dtype: DType,
                                      records: QwenBatchRecordBinding.ResidualRecords, check: () throws -> Void) throws
        -> (array: MLXArray, digest: String) {
        let bytes = shape.reduce(1, *) * dtype.size
        let array = try collective.receiveCompleted(shape: shape, dtype: dtype, from: 0, maximumBytes: bytes,
            scope: records.payload, check: check)
        let digest = Self.digestHex(try receiveBatchWords(8, scope: records.digest, check: check))
        guard sha256(array.asData().data) == digest else {
            throw ProbeError("Batch residual bytes differ from the producer's digest")
        }
        return (array, digest)
    }

    static func digestWords(_ hex: String) -> [Int32] {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return [Int32](repeating: 0, count: 8) }
        func nibble(_ c: UInt8) -> UInt32 { c >= 97 ? UInt32(c - 87) : c >= 65 ? UInt32(c - 55) : UInt32(c - 48) }
        return (0..<8).map { i in
            var v: UInt32 = 0
            for j in 0..<8 { v = v << 4 | nibble(digits[8 * i + j]) }
            return Int32(bitPattern: v)
        }
    }

    static func digestHex(_ words: [Int32]) -> String {
        words.map { String(format: "%08x", UInt32(bitPattern: $0)) }.joined()
    }
}
