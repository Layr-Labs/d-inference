import DarkbloomClusterProtocol
import Foundation
import MLX

struct Gemma4TensorParallelLaneReservation: QwenTensorParallelBatchReservation {
    let request: QwenLayerStageGenerationRequest
    let deadline: UInt64
    /// The lane's own charge at its context, with its own prompt's prefix
    /// capture (`Gemma4TensorParallelResidentRuntime.prefixCharge`).
    let laneStateBytes: Int
    /// What its prefix capture may hold (0: none).
    var prefixCaptureLimit = 0
    var joinable: Bool { true }
}

/// One batch lane: a request's paged session and the frames it has run,
/// on the request's own chunk grid (the solo path's), from a restored
/// prefix's boundary when both ranks restored one.
final class Gemma4TensorParallelLane: QwenTensorParallelBatchLane {
    let session: Gemma4TensorParallelPagedSession
    let request: QwenLayerStageGenerationRequest
    private var schedule: QwenLayerStageGenerationSchedule
    var pendingLogprobs: ClusterWorkerTokenLogprobs?
    var reusedPrefixTokens: Int { session.reusedPrefixTokens }
    /// The boundaries its capture kept, once both ranks retired it cleanly.
    var storedPrefixFrontiers: [Int] = []

    init(session: Gemma4TensorParallelPagedSession, request: QwenLayerStageGenerationRequest) throws {
        self.session = session
        self.request = session.reusedPrefixTokens > 0
            ? try request.planned(reusedPrefix: session.reusedPrefixTokens, splitFinalToken: false) : request
        schedule = QwenLayerStageGenerationSchedule(request: self.request)
    }

    var nextFrame: QwenLayerStageFrame? {
        guard !session.retired else { return nil }
        return try? request.frame(sequence: schedule.nextSequence)
    }
    var committedTokens: Int { session.committedTokens }
    var isClosed: Bool { session.retired }

    /// One prompt frame; the frame that ends the prompt returns its logits.
    func prefill(_ frame: QwenLayerStageFrame, check: () throws -> Void) throws -> MLXArray? {
        let admitted = try schedule.admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset,
            final: frame.finalPromptChunk)
        let result = try session.prefill(request.promptTokenIDs,
            range: admitted.tokenOffset ..< admitted.tokenOffset + admitted.tokenCount, check: check) { $0 }
        try schedule.commit(admitted)
        return result?.logits
    }

    func admitDecode() throws -> QwenLayerStageFrame { try schedule.admitDecode(offset: session.committedTokens) }
    func commit(_ frame: QwenLayerStageFrame) throws { try schedule.commit(frame) }

    /// Checks a clean end against the frames run (the schedule is not reused).
    func finish(_ reason: QwenLayerStageGenerationFinishReason, selected: Int, last: Int) throws {
        var copy = schedule
        try copy.finish(reason, selectedTokenCount: selected, lastTokenID: last)
    }
}

/// The batch driver's native adapter for Gemma 4 tensor parallel
/// (`QwenTensorParallelBatchDriver`: joins, stops, cancellations, deadlines
/// and retirements cross in its own bounded exchange). Every request owns
/// its paged history on the rank's host; a decode step runs every decoding
/// lane in one forward (`Gemma4TensorParallelPagedSession.decode`), each row
/// bit for bit its request's own step, and its tokens as the solo path
/// chooses them: the split argmax for greedy rows; with a row that samples,
/// every row gathered whole and rank 0's draws (the product's sampler);
/// greedy logprobs from the split top-k gather, sampled ones from the draw.
final class Gemma4TensorParallelBatchExecutor<Reservation: QwenTensorParallelBatchReservation>: QwenTensorParallelBatchExecutor {
    typealias Lane = Gemma4TensorParallelLane
    let rank: Int
    private let model: Gemma4TensorParallelModel
    private let host: CBv2StageKVHost
    private let reduction: any QwenTensorParallelReduction
    /// Both ranks agree they were given this request (and this load) before
    /// its history is opened.
    private let agree: (QwenLayerStageGenerationRequest, () throws -> Void) throws -> Void
    private let completedDecode: (Int) -> Void
    /// This rank's prompt prefixes; nil keeps none (oracles).
    private let prefix: Gemma4TensorParallelPrefix?

    init(model: Gemma4TensorParallelModel, host: CBv2StageKVHost, reduction: any QwenTensorParallelReduction,
         prefix: Gemma4TensorParallelPrefix? = nil,
         agree: @escaping (QwenLayerStageGenerationRequest, () throws -> Void) throws -> Void,
         completedDecode: @escaping (Int) -> Void = { _ in }) throws {
        guard case .shard(let rank) = model.role, rank == reduction.rank, reduction.size == model.plan.size,
              model.plan.vocabularySize < (1 << 24) else {
            throw ProbeError("Gemma tensor-parallel batch executor has a mismatched shard or group")
        }
        self.rank = rank; self.model = model; self.host = host; self.reduction = reduction
        self.prefix = prefix; self.agree = agree; self.completedDecode = completedDecode
    }

    func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float] {
        try check()
        let result = reduction.allSum(MLXArray(words)); eval(result); try check()
        guard result.shape == [words.count], result.dtype == .float32 else {
            throw ProbeError("Gemma tensor-parallel batch control reduction changed shape or dtype")
        }
        let output = result.asArray(Float.self); try check()
        guard output.allSatisfy(\.isFinite) else { throw ProbeError("Gemma tensor-parallel batch control reduction is not finite") }
        return output
    }

    /// An unopened reservation holds no native state.
    func discard(_ reservation: Reservation) throws {}

    /// Both ranks agree on the request, then (with prompt prefixes kept) vote
    /// its prefix and restore it or neither does (`Gemma4TensorParallelPrefix.open`).
    func open(_ reservation: Reservation, check: () throws -> Void) throws -> Lane {
        let request = reservation.request
        try agree(request, check)
        try check()
        guard let prefix else {
            return try Lane(session: try .init(model: model, host: host, promptCount: request.promptCount,
                outputCount: request.outputCount), request: request)
        }
        let limit = (reservation as? Gemma4TensorParallelLaneReservation)?.prefixCaptureLimit ?? 0
        let session = try prefix.open(request, model: model, host: host, group: reduction, captureLimit: limit)
        do { return try Lane(session: session, request: request) } catch {
            try? session.retire(failed: true)
            throw error
        }
    }

    /// Both ranks retired the lane: a clean one's capture becomes reusable.
    func confirmedRetirement(_ lane: Lane, clean: Bool) throws {
        guard let capture = lane.session.prefixCapture else { return }
        lane.session.prefixCapture = nil
        guard clean, let prefix, let scopes = prefix.scopes(lane.request) else { capture.discard(); return }
        lane.storedPrefixFrontiers = prefix.store(capture, request: lane.request, scopes: scopes, rank: rank)
    }

    func prefill(_ lane: Lane, frame: QwenLayerStageFrame, check: () throws -> Void) throws -> Int? {
        guard lane.nextFrame == frame, frame.phase == .prefill else {
            throw ProbeError("Gemma tensor-parallel lane prefill frame changed")
        }
        guard let logits = try lane.prefill(frame, check: check) else { return nil }
        return try select(logits, lanes: [lane], check: check)[0]
    }

    func decode(_ lanes: [Lane], tokens: [Int], check: () throws -> Void) throws -> [Int] {
        guard !lanes.isEmpty, lanes.count == tokens.count, lanes.count <= host.lanes else {
            throw ProbeError("Gemma tensor-parallel decode lanes exceed the host")
        }
        return try GPU.withCommandBufferLimits(Gemma4TensorParallelModel.decodeCommandBuffers) {
            let frames = try lanes.map { try $0.admitDecode() }
            let logits = try Gemma4TensorParallelPagedSession.decode(lanes.map(\.session), tokens: tokens, check: check)
            for (lane, frame) in zip(lanes, frames) { try lane.commit(frame) }
            completedDecode(lanes.count)
            return try select(logits, lanes: lanes, check: check)
        }
    }

    private func select(_ logits: MLXArray, lanes: [Lane], check: () throws -> Void) throws -> [Int] {
        let width = lanes.count, selection = model.selection
        guard logits.shape == [width, model.vocabularyRange.count] else {
            throw ProbeError("Gemma tensor-parallel selection rows do not match the lanes")
        }
        let choices = lanes.map { Gemma4TensorParallelChoice(selection: selection, sampler: $0.request.sampler, rank: rank) }
        // Greedy rows take the split argmax; only sampled rows cross whole.
        // Both ranks derive the same rows from the agreed requests.
        let sampled = choices.indices.filter { choices[$0].gathersRow }
        let greedy = choices.indices.filter { !choices[$0].gathersRow }
        var tokens = [Int](repeating: 0, count: width)
        var maxima = [Float?](repeating: nil, count: width)
        if !greedy.isEmpty {
            let rows = greedy.count == width ? logits : logits[MLXArray(greedy.map(Int32.init))]
            let agreed = selection.greedyRows(rows)
            eval(agreed.tokens, agreed.maxima); try check()
            for (row, (token, maximum)) in zip(greedy, zip(agreed.tokens.asArray(Int32.self), agreed.maxima.asArray(Float.self))) {
                tokens[row] = Int(token); maxima[row] = maximum
            }
        }
        if !sampled.isEmpty {
            let rows = selection.gather(sampled.count == width ? logits : logits[MLXArray(sampled.map(Int32.init))])
            eval(rows); try check()
            var drawn = MLXArray.zeros([sampled.count], dtype: .float32)
            if rank == 0 {
                drawn = concatenated(sampled.enumerated().map { index, lane in
                    lanes[lane].request.sampler!.sample(rows[index ..< index + 1]).asType(.float32).reshaped([1])
                }, axis: 0)
            }
            let agreed = selection.exchange(drawn)[0 ..< sampled.count]
            eval(agreed); try check()
            for (row, token) in zip(sampled, agreed.asArray(Float.self)) { tokens[row] = Int(token) }
        }
        guard tokens.count == width, tokens.allSatisfy({ (0 ..< model.plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Gemma tensor-parallel selection produced an invalid token")
        }
        // Every rank takes every greedy row's top-k collective, in lane order.
        for (index, lane) in lanes.enumerated() {
            guard let sampler = lane.request.sampler else { continue }
            if let count = sampler.wire.capturedLogprobs {
                if choices[index].gathersRow {
                    lane.pendingLogprobs = rank == 0 ? sampler.takePendingLogprobs() : nil
                } else {
                    let captured = try choices[index].logprobs(logits[index ..< index + 1], token: tokens[index],
                                                               maximum: maxima[index], count: count)
                    lane.pendingLogprobs = rank == 0 ? captured : nil
                }
            }
            sampler.commit(tokens[index])
        }
        return tokens
    }

    func takeLogprobs(_ lane: Lane) throws -> ClusterWorkerTokenLogprobs? {
        guard rank == 0 else { throw ProbeError("Only Gemma tensor-parallel rank 0 publishes token logprobs") }
        defer { lane.pendingLogprobs = nil }
        return lane.pendingLogprobs
    }

    func retire(_ lane: Lane, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws {
        if let reason {
            guard let last else { throw ProbeError("Gemma tensor-parallel clean retirement has no selected token") }
            try lane.finish(reason, selected: selected, last: last)
        }
        try lane.session.retire(failed: reason == nil)
        lane.pendingLogprobs = nil
    }
}

extension Gemma4TensorParallelModel {
    /// Greedy requests served together through the batch driver on this
    /// shard's own paged host, as a batching rank serves them: each request's
    /// tokens. Oracles and tools; both ranks call it with the same prompts.
    public func generateLanes(prompts: [[Int]], outputCount: Int, chunk: Int) throws -> [[Int]] {
        guard case .shard = role, let reduction, (1 ... 8).contains(prompts.count), outputCount >= 1, chunk >= 1,
              let longest = prompts.map(\.count).max(), chunk <= longest, prompts.allSatisfy({ !$0.isEmpty }),
              prompts.joined().allSatisfy({ (0 ..< plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Gemma tensor-parallel lanes: a shard, 1 to 8 prompts, a chunk within the longest")
        }
        let activation = String(describing: activationDType)
        let profile = try QwenLayerStageGenerationProfile(identifier: "gemma4-tensor-parallel-lanes",
            vocabularySize: plan.vocabularySize, hiddenSize: plan.hiddenSize, activationDType: activation,
            maximumPromptTokens: longest, maximumChunkTokens: chunk, maximumOutputTokens: outputCount,
            maximumContextTokens: longest + outputCount, logitsDType: activation == "float32" ? nil : "float32")
        // The same request IDs on both ranks: the driver's exchange binds them.
        let requests = try prompts.enumerated().map { index, prompt in
            try QwenLayerStageGenerationRequest(profile: profile,
                requestID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                promptTokenIDs: prompt, chunkSize: chunk, outputCount: outputCount, stopTokenIDs: [])
        }
        let host = try pagedHost(lanes: prompts.count, maximumTokens: longest + outputCount, chunkTokens: chunk)
        let book = ClusterBatchLaneBook<Gemma4TensorParallelLaneReservation>()
        for request in requests {
            try book.reserve(request.requestID, .init(request: request, deadline: .max, laneStateBytes: 1), lanes: prompts.count)
            try book.start(request.requestID)
        }
        let executor = try Gemma4TensorParallelBatchExecutor<Gemma4TensorParallelLaneReservation>(model: self, host: host,
            reduction: reduction, agree: { _, check in try check() })
        let driver = try QwenTensorParallelBatchDriver(executor: executor, book: book, capacity: prompts.count,
            vocabulary: plan.vocabularySize)
        var tokens: [UUID: [Int]] = [:]
        try MLX.withError { error in
            try driver.serve(host: Gemma4TensorParallelOracleLaneHost(),
                retiredSelection: { id, selected, _ in tokens[id] = selected }, check: { try error.check() })
        }
        guard host.isDrained, book.isEmpty, requests.allSatisfy({ tokens[$0.requestID]?.count == outputCount }) else {
            throw ProbeError("Gemma tensor-parallel lanes did not all finish and return their pages")
        }
        return requests.map { tokens[$0.requestID]! }
    }
}

/// An owner that wants every token and publishes nowhere (oracles).
final class Gemma4TensorParallelOracleLaneHost: QwenBatchServingHost {
    func serviceControl() throws {}
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {}
    func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: requestIDs.map { ($0, true) })
    }
    func pollDecision(_ requestID: UUID) throws -> Bool? { true }
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {}
    func publishLeft(requestID: UUID) throws {}
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
}

extension Gemma4TensorParallelResidentRuntime {
    private func withLaneOperation<T>(_ body: () throws -> T) throws -> T {
        // The driver applies new reservations on this executor while
        // `serveBatch` holds the operation lock.
        if batchServing { return try body() }
        guard operation.try() else { throw ProbeError("A Gemma tensor-parallel native operation is already active") }
        defer { operation.unlock() }
        return try body()
    }

    public func reserveLane(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try withLaneOperation {
            guard lanes > 1, model != nil, host != nil, laneBook.count < lanes else {
                throw ProbeError("Gemma tensor-parallel batch lanes are unavailable")
            }
            guard value.stillImages == nil, value.mimoImages == nil, value.glmMedia == nil else {
                throw ProbeError("Gemma tensor parallel serves text requests only")
            }
            let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let priced = try prefixCharge(request)
            let charge = priced.charge
            guard charge <= value.capacityLimitBytes else {
                throw ProbeError("Gemma tensor-parallel lane exceeds its owner or readiness capacity")
            }
            // Every held lane at its whole charge, this one, and the rank's own reserve once
            // (kept prefixes give way first; a capture beyond its charged part may be cut).
            _ = ClusterIdleMemory.releaseFreedBuffers()
            let captureLimit = try admitCapture(priced, held: [try laneBook.stateBytes(), charge, rankReserveBytes])
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            try laneBook.reserve(requestID, .init(request: request, deadline: value.deadlineUptimeNanoseconds,
                laneStateBytes: charge, prefixCaptureLimit: captureLimit), lanes: lanes)
            return charge
        }
    }

    public func startLane(requestID: UUID) throws { try laneBook.start(requestID) }
    public func cancelLane(requestID: UUID) { laneBook.cancel(requestID) }
    public func withdrawLane(requestID: UUID) -> Bool { laneBook.withdraw(requestID) }
    public var hasStartedLanes: Bool { laneBook.hasStarted }

    public func serveBatch(host servingHost: QwenBatchServingHost) throws {
        guard operation.try() else { throw ProbeError("A Gemma tensor-parallel native operation is already active") }
        defer { operation.unlock() }
        guard lanes > 1, let model, let host else { throw ProbeError("Gemma tensor-parallel batch has no lanes, shard or KV host") }
        batchServing = true; defer { batchServing = false }
        batchOrdinal = try QwenBatchRecordBinding.nextOrdinal(after: batchOrdinal)
        let records = try QwenBatchRecordBinding(epoch: admission.configuration.identity.membershipEpoch,
            planFingerprint: admission.plan.fingerprint, ordinal: batchOrdinal, lanes: lanes)
        let executor = try Gemma4TensorParallelBatchExecutor<Gemma4TensorParallelLaneReservation>(model: model, host: host,
            reduction: group, prefix: prefix, agree: { [self] request, check in try agreeRequest(request, check: check) })
        let driver = try QwenTensorParallelBatchDriver(executor: executor, book: laneBook, capacity: lanes,
            vocabulary: admission.profile.vocabularySize)
        do {
            try lifecycle.withRequest(identity: .init(requestID: records.requestID, epoch: records.requestID,
                recordedRequestFingerprint: sha256(Data("gemma4-tp-batch|\(loadAgreement)|\(batchOrdinal)".utf8)))) {
                try MLX.withError { error in
                    var lastResourceCheck: UInt64 = 0
                    try driver.serve(host: servingHost, memoryRefused: {
                        // Kept prefixes give way first; a memory refusal then stops
                        // one lane alone (D6), any other refusal fails the batch.
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 else { return false }
                        lastResourceCheck = now
                        do { try self.prefix.cache.yieldingMemory { try Self.requireLiveMemory(bytes: 0) }; return false }
                        catch let refusal as QwenResidentMemoryRefusal {
                            log("darkbloom-tp-batch-v1 rank=\(self.collective.rank) family=gemma4 memory-refused: \(refusal.message)")
                            return true
                        }
                    }, check: {
                        try error.check(); try self.control.check(); try error.check()
                    })
                }
            }
            guard host.isDrained else { throw ProbeError("Gemma tensor-parallel batch retained native history") }
            collective.logDataPlaneStatus()
        } catch {
            // Its native state stays reachable until shutdown's checked drain;
            // the peer may hold other prefixes now.
            prefix.cache.sweep()
            failedLaneDriver = driver; control.fail()
            throw error
        }
    }

    /// Both ranks hold the same request under the same load: every 64 bits
    /// of the SHA-256 of its fingerprint and the load agreement compared.
    func agreeRequest(_ request: QwenLayerStageGenerationRequest, check: () throws -> Void) throws {
        let digest = sha256(try canonicalJSONData([request.fingerprint, loadAgreement]))
        for lower in stride(from: 0, to: digest.count, by: 16) {
            let start = digest.index(digest.startIndex, offsetBy: lower)
            guard let word = UInt64(digest[start ..< digest.index(start, offsetBy: 16)], radix: 16),
                  try group.digestsEqual(word) else {
                throw ProbeError("Gemma tensor-parallel ranks were given different requests")
            }
        }
        try check()
    }
}
