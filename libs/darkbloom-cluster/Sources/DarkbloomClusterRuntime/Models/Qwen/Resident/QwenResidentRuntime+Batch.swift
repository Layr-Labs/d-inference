import DarkbloomClusterProtocol
import Foundation
import MLX

/// One request in the batch loop on this rank.
final class QwenBatchLane {
    let id: UUID
    let slot: Int
    let order: Int
    let reserved: QwenResidentReservation
    /// The planned request both ranks run (the last prompt token split off
    /// exactly when both prefix caches are on, as the one-request path does).
    let request: QwenLayerStageGenerationRequest
    let session: QwenLayerStageSession
    var selected: [Int] = []

    init(id: UUID, slot: Int, order: Int, reserved: QwenResidentReservation,
         request: QwenLayerStageGenerationRequest, session: QwenLayerStageSession) {
        self.id = id; self.slot = slot; self.order = order; self.reserved = reserved
        self.request = request; self.session = session
    }

    var fingerprintWords: [Int32] { QwenBatchWire.fingerprintWords(reserved.request.fingerprint) }

    /// How the request finishes after its latest token, or nil to go on.
    func finish(continueRequested: Bool) -> QwenLayerStageGenerationFinishReason? {
        guard let last = selected.last else { return nil }
        if request.stopTokenIDs.contains(last) { return .eos }
        if selected.count == request.outputCount { return .length }
        return continueRequested ? nil : .clientStop
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
/// Every frame keeps the arithmetic of the request run alone: prefill frames
/// end on the request's own chunk grid (one frame per step, earliest joined
/// lane first), the last prompt token is split off exactly when the
/// one-request path splits it, and decode rows attend only their own KV.
/// Greedy selection on rank 1, as for one request.
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
            try prefixCache.yieldingMemory { try allowance.requireLive(additionalNativeBytes: others) }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            try laneBook.reserve(requestID, .init(request: request, allowance: allowance,
                deadline: value.deadlineUptimeNanoseconds, mode: .serving, recordingCharge: nil,
                prefillPolicy: .serial, prefillAllowance: nil), lanes: batch.lanes)
            return allowance.reservedBytes
        }
    }

    public func startLane(requestID: UUID) throws { try laneBook.start(requestID) }
    public func cancelLane(requestID: UUID) { laneBook.cancel(requestID) }
    /// Started lanes wait for the loop; the worker re-enters it while any do.
    public var hasStartedLanes: Bool { laneBook.hasStarted }
    public var hasLanes: Bool { !laneBook.isEmpty }

    /// Runs the batch loop until no lane is left on rank 0's side. Returns only
    /// after every lane that finished published its finish; throws on any
    /// failure, after retiring every lane's native state.
    public func serveBatch(host: QwenBatchServingHost) throws {
        try withExclusiveOperation {
            guard batch.batching, generationMode == .pipeline, let stage = stageForBatch,
                  stage.loaded.kvHost.host != nil else {
                throw ProbeError("Batch lanes are not configured for this resident owner")
            }
            batchServing = true
            defer { batchServing = false }
            let lanes = QwenBatchLaneTable()
            let scope = UUID()
            do {
                try lifecycle.withRequest(identity: .init(requestID: scope, epoch: scope,
                        recordedRequestFingerprint: sha256(Data("qwen-batch-scope-v1|\(scope.uuidString)".utf8)))) {
                    try autoreleasepool {
                        try MLX.withError { nativeError in
                            var lastResourceCheck: UInt64 = 0
                            func checked() throws {
                                try nativeError.check(); try control.check()
                                let now = DispatchTime.now().uptimeNanoseconds
                                guard !laneBook.anyCancelled, lanes.values.allSatisfy({ now < $0.reserved.deadline }) else {
                                    throw ProbeError("A batch lane was cancelled or passed its deadline")
                                }
                                if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                                    // Kept prefixes give way to the lanes' own admission.
                                    let allowances = laneBook.allowances()
                                    if let first = allowances.first {
                                        let others = try QwenLongPrefillCheckedBytes.sum(allowances.dropFirst().map(\.stateBytes))
                                        try prefixCache.yieldingMemory { try first.requireLive(additionalNativeBytes: others) }
                                    }
                                    lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                                }
                                try nativeError.check()
                            }
                            let opening = try openBatch(stage: stage, check: checked)
                            let split = opening
                            if collective.rank == 0 {
                                try leadBatch(stage: stage, split: split, lanes: lanes, host: host, check: checked)
                            } else {
                                try followBatch(stage: stage, split: split, lanes: lanes, host: host, check: checked)
                            }
                        }
                    }
                }
            } catch {
                var primary: Error = error
                for lane in lanes.values {
                    do { try lane.session.cancel() } catch { primary = ProbeError("\(primary); lane retirement also failed (\(error))") }
                }
                lanes.slots.removeAll(); laneBook.clear()
                prefixCache.sweep(); control.fail()
                throw primary
            }
        }
    }

    /// The loop's first exchange. Returns whether the last prompt token is
    /// split off (both prefix caches on).
    private func openBatch(stage: any LayerStageResidentStage, check: () throws -> Void) throws -> Bool {
        let local = QwenBatchWire.Opening(lanes: batch.lanes, pagedKV: stage.loaded.kvHost.host?.kind == .paged,
            prefixCacheEnabled: prefixCache.enabled, vocabularySize: admission.profile.vocabularySize,
            hiddenSize: admission.profile.hiddenSize)
        let peer = try QwenBatchWire.Opening(words: exchangeBatchWords(local.words, check: check))
        guard peer.lanes == local.lanes, peer.pagedKV == local.pagedKV,
              peer.vocabularySize == local.vocabularySize, peer.hiddenSize == local.hiddenSize else {
            throw ProbeError("Batch peers differ in lanes, KV storage or model geometry")
        }
        return local.prefixCacheEnabled && peer.prefixCacheEnabled
    }

    private func makeLane(stage: any LayerStageResidentStage, id: UUID, reserved: QwenResidentReservation,
                          slot: Int, order: Int, split: Bool) throws -> QwenBatchLane {
        let request = try reserved.request.planned(reusedPrefix: 0, splitFinalToken: split)
        let session = try QwenLayerStageSession(stage: stage.loaded, plan: admission.plan, generationRequest: request)
        return QwenBatchLane(id: id, slot: slot, order: order, reserved: reserved, request: request, session: session)
    }

    // MARK: Rank 0

    private func leadBatch(stage: any LayerStageResidentStage, split: Bool, lanes: QwenBatchLaneTable,
                           host: QwenBatchServingHost, check: () throws -> Void) throws {
        var step = 0, order = 0
        var leaving: [Int: (id: UUID, reason: QwenLayerStageGenerationFinishReason, selected: Int)] = [:]
        // One autorelease scope per step, as the one-request loop has per frame.
        while try !autoreleasepool(invoking: { () throws -> Bool in
            try host.serviceControl()
            try check()
            var joining = Set<Int>()
            while lanes.count + leaving.count < batch.lanes, let (id, reserved) = laneBook.takeStarted() {
                guard let slot = (0..<batch.lanes).first(where: { lanes[$0] == nil && leaving[$0] == nil }) else { break }
                lanes[slot] = try makeLane(stage: stage, id: id, reserved: reserved, slot: slot, order: order, split: split)
                order += 1; joining.insert(slot)
            }
            let stop = lanes.isEmpty
            // The step's plan: every decoding lane together, one prefill frame.
            let decodeSlots = lanes.keys.sorted().filter { lanes[$0]!.session.nextFrame?.phase == .decode }
            let prefillSlot = lanes.values.filter { $0.session.nextFrame?.phase == .prefill }
                .min(by: { $0.order < $1.order })?.slot
            var slots = [QwenBatchWire.Slot](repeating: .init(), count: batch.lanes)
            for (slot, left) in leaving {
                slots[slot] = .init(state: .leaving, requestID: left.id, selectedTokens: left.selected, leaveReason: left.reason)
            }
            for (slot, lane) in lanes.slots {
                var value = QwenBatchWire.Slot(state: joining.contains(slot) ? .joining : .active, requestID: lane.id)
                value.committedTokens = lane.session.committedTokens; value.selectedTokens = lane.selected.count
                value.fingerprintWords = lane.fingerprintWords
                if decodeSlots.contains(slot) {
                    value.role = .decode; value.inputToken = lane.selected.last ?? -1
                } else if slot == prefillSlot, let frame = lane.session.nextFrame {
                    value.role = .prefill; value.frameOffset = frame.tokenOffset
                    value.frameCount = frame.tokenCount; value.finalChunk = frame.finalPromptChunk
                }
                slots[slot] = value
            }
            try sendBatchWords(QwenBatchWire.Header(step: step, stop: stop, slots: slots).words, check: check)
            leaving.removeAll()
            if stop { return true }

            if !decodeSlots.isEmpty {
                let residual = try QwenLayerStageSession.decodeBatch(decodeSlots.map { lanes[$0]!.session },
                    tokens: decodeSlots.map { lanes[$0]!.selected.last! }, residual: nil, check: check)
                try sendBatchResidual(residual, digest: sha256(residual.asData().data), check: check)
            }
            var finalPrefill = false
            if let slot = prefillSlot, let lane = lanes[slot], let frame = lane.session.nextFrame {
                let tokens = Array(lane.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                guard case .hidden(let boundary) = try lane.session.prefillChunk(tokens, offset: frame.tokenOffset,
                        final: frame.finalPromptChunk, check: check) else {
                    throw ProbeError("Batch producer prefill did not return a residual")
                }
                try sendBatchResidual(boundary.array, digest: boundary.payloadSHA256, check: check)
                finalPrefill = frame.finalPromptChunk
            }
            let reply = try QwenBatchWire.Reply(words: receiveBatchWords(QwenBatchWire.replyWords, check: check),
                expectedStep: step, lanes: batch.lanes)
            var published: [Int] = []
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
                try host.publishToken(requestID: lane.id, ordinal: lane.selected.count - 1, tokenID: reply.tokens[slot],
                    committedTokens: lane.request.promptCount + lane.selected.count - 1)
                published.append(slot)
            }
            if !published.isEmpty {
                let decisions = try host.awaitDecisions(published.map { lanes[$0]!.id })
                try check()
                for slot in published {
                    let lane = lanes[slot]!
                    guard let proceed = decisions[lane.id] else { throw ProbeError("Batch lane decision missing") }
                    guard let reason = lane.finish(continueRequested: proceed) else { continue }
                    try lane.session.finishGeneration(reason, selectedTokenCount: lane.selected.count,
                        lastTokenID: lane.selected.last!)
                    guard lane.session.isClosed, !lane.session.isFailed else {
                        throw ProbeError("Batch lane native state failed retirement")
                    }
                    try host.publishFinished(requestID: lane.id, reason: ClusterWorkerFinishReason(rawValue: reason.rawValue)!)
                    laneBook.finish(lane.id)
                    leaving[slot] = (lane.id, reason, lane.selected.count)
                    lanes[slot] = nil
                }
            }
            step += 1
            return false
        }) {}
    }

    // MARK: Rank 1

    private func followBatch(stage: any LayerStageResidentStage, split: Bool, lanes: QwenBatchLaneTable,
                             host: QwenBatchServingHost, check: () throws -> Void) throws {
        var step = 0, order = 0
        while try !autoreleasepool(invoking: { () throws -> Bool in
            let header = try QwenBatchWire.Header(words: receiveBatchWords(QwenBatchWire.headerWords, check: check),
                expectedStep: step, lanes: batch.lanes)
            for (slot, value) in header.slots.enumerated() where value.state == .leaving {
                guard let lane = lanes[slot], lane.id == value.requestID, let reason = value.leaveReason,
                      value.selectedTokens == lane.selected.count,
                      lane.finish(continueRequested: reason != .clientStop) == reason else {
                    throw ProbeError("Batch header ends a lane this rank does not hold, or for another reason")
                }
                try lane.session.finishGeneration(reason, selectedTokenCount: lane.selected.count,
                    lastTokenID: lane.selected.last!)
                guard lane.session.isClosed, !lane.session.isFailed else {
                    throw ProbeError("Batch lane native state failed retirement")
                }
                try host.publishFinished(requestID: lane.id, reason: ClusterWorkerFinishReason(rawValue: reason.rawValue)!)
                laneBook.finish(lane.id)
                lanes[slot] = nil
            }
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
                let lane = try makeLane(stage: stage, id: id, reserved: reserved, slot: slot, order: order, split: split)
                order += 1
                lanes[slot] = lane
                guard lane.fingerprintWords == value.fingerprintWords else {
                    throw ProbeError("Batch lane request differs between the ranks' owners")
                }
            }
            for (slot, value) in header.slots.enumerated() {
                switch value.state {
                case .empty, .leaving:
                    guard lanes[slot] == nil else { throw ProbeError("Batch header leaves out a lane this rank holds") }
                case .joining, .active:
                    guard let lane = lanes[slot], lane.id == value.requestID,
                          lane.session.committedTokens == value.committedTokens,
                          lane.selected.count == value.selectedTokens else {
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
                    guard let lane = lanes[slot], lane.session.nextFrame?.phase == .decode,
                          header.slots[slot].inputToken == lane.selected.last else {
                        throw ProbeError("Batch decode row differs from this rank's lane")
                    }
                }
                let residual = try receiveBatchResidual(shape: [decodeSlots.count, 1, admission.profile.hiddenSize],
                    dtype: stage.loaded.activationDType, check: check)
                let logits = try QwenLayerStageSession.decodeBatch(decodeSlots.map { lanes[$0]!.session },
                    tokens: decodeSlots.map { lanes[$0]!.selected.last! }, residual: residual.array, check: check)
                let selected = try Self.selectBatchTokens(logits, rows: decodeSlots.count,
                    request: lanes[decodeSlots[0]]!.request, check: check)
                for (row, slot) in decodeSlots.enumerated() {
                    tokens[slot] = selected[row]; lanes[slot]!.selected.append(selected[row])
                }
            }
            if let slot = header.slots.indices.first(where: { header.slots[$0].role == .prefill }) {
                let value = header.slots[slot]
                guard let lane = lanes[slot], let frame = lane.session.nextFrame, frame.phase == .prefill,
                      frame.tokenOffset == value.frameOffset, frame.tokenCount == value.frameCount,
                      frame.finalPromptChunk == value.finalChunk else {
                    throw ProbeError("Batch prefill frame differs from this rank's lane")
                }
                let received = try receiveBatchResidual(shape: [1, frame.tokenCount, admission.profile.hiddenSize],
                    dtype: stage.loaded.activationDType, check: check)
                let ids = Array(lane.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                let identity = lane.session.identity
                let boundary = QwenLayerStageBoundary(requestFingerprint: identity.requestFingerprint,
                    sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                    artifactAggregateSHA256: identity.artifactAggregateSHA256,
                    storageCommitmentSHA256: identity.storageCommitmentSHA256,
                    planFingerprint: identity.planFingerprint, producerStageFingerprint: admission.plan.stages[0].fingerprint,
                    frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(ids),
                    payloadSHA256: received.digest, array: received.array)
                let output = try lane.session.prefillChunk(ids, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                    incoming: boundary, check: check)
                switch output {
                case .evaluationHandle where !frame.finalPromptChunk: break
                case .logits(let row) where frame.finalPromptChunk:
                    let token = try QwenLayerStageGenerationSelection.token(row, request: lane.request, check: check)
                    tokens[slot] = token; lane.selected.append(token)
                default: throw ProbeError("Batch consumer prefill output does not match its frame")
                }
            }
            try sendBatchWords(QwenBatchWire.Reply(step: step, tokens: tokens).words, check: check)
            step += 1
            return false
        }) {}
    }

    /// Greedy selection of every row at once: the same finite argmax as one
    /// request's selection, per row.
    static func selectBatchTokens(_ logits: MLXArray, rows: Int, request: QwenLayerStageGenerationRequest,
                                  check: () throws -> Void) throws -> [Int] {
        guard logits.shape == [rows, request.profile.vocabularySize],
              String(describing: logits.dtype) == request.profile.selectedRowDType else {
            throw ProbeError("Batch selected rows differ from the admitted native shape/dtype")
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

    private func exchangeBatchWords(_ words: [Int32], check: () throws -> Void) throws -> [Int32] {
        if collective.rank == 0 {
            try sendBatchWords(words, check: check)
            return try receiveBatchWords(words.count, check: check)
        }
        let peer = try receiveBatchWords(words.count, check: check)
        try sendBatchWords(words, check: check)
        return peer
    }

    private func sendBatchWords(_ words: [Int32], check: () throws -> Void) throws {
        let array = MLXArray(words)
        _ = try collective.sendCompleted(array, to: 1 - collective.rank, maximumBytes: words.count * 4, check: check)
    }

    private func receiveBatchWords(_ count: Int, check: () throws -> Void) throws -> [Int32] {
        let words = try collective.receiveCompleted(shape: [count], dtype: .int32, from: 1 - collective.rank,
            maximumBytes: count * 4, check: check).asArray(Int32.self)
        try check()
        return words
    }

    /// A residual, then its SHA-256 as eight words: the receiver verifies the
    /// bytes it got against the digest, as the one-request boundary does.
    private func sendBatchResidual(_ array: MLXArray, digest: String, check: () throws -> Void) throws {
        _ = try collective.sendCompleted(array, to: 1, maximumBytes: array.nbytes, check: check)
        try sendBatchWords(Self.digestWords(digest), check: check)
    }

    private func receiveBatchResidual(shape: [Int], dtype: DType, check: () throws -> Void) throws
        -> (array: MLXArray, digest: String) {
        let bytes = shape.reduce(1, *) * dtype.size
        let array = try collective.receiveCompleted(shape: shape, dtype: dtype, from: 0, maximumBytes: bytes, check: check)
        let digest = Self.digestHex(try receiveBatchWords(8, check: check))
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
