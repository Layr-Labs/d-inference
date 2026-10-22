import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Continuous batching for GLM tensor parallel (`lanes > 1`): requests join
/// and leave a loop both ranks run in lockstep (`GLM5NextTensorParallelLaneLoop`).
///
/// Every lane keeps the arithmetic of its request served alone. It opens with
/// the same digest agreement and prefix vote (`openRequest`), prefills frame
/// by frame on its own grid (`prefillFrameEnd`, `runPrefillFrame`) and decodes
/// in its own MTP rounds or one-token steps, with its own stage cache, NextN
/// state and sampler; only the order in which lanes' frames and units run is
/// the loop's. The decode units of one step run one lane after another
/// (`decode`, the decode seam): each is bitwise its request's solo unit. A
/// batched executor that verifies several lanes' windows in one forward
/// replaces that seam and nothing else.
///
/// Memory: a request's whole charge at its own context
/// (`GLM5NextTensorParallelRequestCharge`: both stages' request state, the sum
/// and bulk prefill workspaces, NextN work and windows) is its named state
/// (`laneStateBytes`) and the transients of its forward. Lanes run one
/// forward at a time, so the host holds every held lane's state and the
/// largest of their transients. A lane the host cannot hold now is refused,
/// alone; the running lanes go on.
///
/// Media: a lane carrying images or video runs the solo request's media path
/// (`GLM5NextTensorParallelMedia`): rank 0 prepares its patches from the
/// reservation on, off the executor, and joins it only once that ended, so
/// the running lanes never wait for a decode; when it joins, its features are
/// made and agreed in its open, its prefill frames splice them and prime the
/// NextN history, and it decodes in MTP rounds as any lane. Its media charge
/// (`GLM5NextTensorParallelMedia.requestBytes`) is held with its state for
/// its whole life.
///
/// Isolation: a lane that ends (its stop token, its output limit, its owner's
/// stop answer), is cancelled, or passes its deadline leaves both ranks at a
/// step boundary and its worker retires it; the other lanes go on. A native,
/// collective, agreement or protocol failure ends every lane and the pair, as
/// it ends one request.
extension GLM5NextTensorParallelResidentRuntime {
    /// One lane count keeps the agreement bytes it always had.
    static func laneAgreementFields(_ lanes: QwenBatchSettings) -> [String] {
        lanes.batching ? ["glm5-next-tp-lanes-v1", "lanes=\(lanes.lanes)"] : []
    }

    /// One lane's named state on a rank while it is held beside others, at
    /// its own context (prompt plus output tokens): every DSA layer's latent
    /// and index histories (replicated under TP) at the cache's growth bound
    /// (`historyTokens`, the request's capped length, or the doubling's
    /// `max(256, 2 * context)`), every KDA layer's settled convolution and
    /// recurrent state (whole heads, as the request budget charges them), and
    /// the NextN history when it decodes speculatively. One copy each at the
    /// doubling's bound. At a capped length, the histories also carry the
    /// fresh buffer an append writes before the one it replaces is released
    /// (twice, the NextN history a round's checkpoint and two drafts: three
    /// times): every speculating lane's round appends in the one batched
    /// verification forward (`decode`), so those copies coexist. Prefill
    /// frames still run one lane at a time, inside its request's whole charge.
    static func laneStateBytes(configuration c: GLM5NextTextConfiguration, contextTokens: Int, speculative: Bool,
                               historyTokens: Int? = nil,
                               allocationBound: (Int) throws -> Int = QwenResidentResourceEnvironment.allocationBound)
        throws -> Int {
        typealias Bytes = QwenLongPrefillCheckedBytes
        guard contextTokens > 0 else { throw ProbeError("GLM lane state needs a positive context") }
        let capacity = try (historyTokens.map { GLM5NextRequestStateBudget.HistoryBound.reserved(tokens: $0) } ?? .geometric)
            .columns(contextTokens: contextTokens).capacity
        let (copies, nextNCopies) = historyTokens == nil ? (1, 1) : (2, 3)
        let history = try Bytes.sum([c.kvLoraRank * 4, c.indexHeadDim * 4, c.indexHeadDim * 4, 1].map {
            try allocationBound(Bytes.product([capacity, $0]))
        })
        let dsaLayers = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        let kdaLayers = c.layerTypes.filter { $0 == .linearAttention }.count
        let linear = c.linearAttention
        let recurrent = try allocationBound(Bytes.product([linear.numHeads, linear.headDim, linear.headDim, 4]))
        let convolution = try allocationBound(Bytes.product([3, linear.numHeads, linear.headDim,
            linear.shortConvKernelSize, 4]))
        // A speculating lane's round runs beside the others' in one forward
        // (`decode`): its captured verification windows and the state adopted
        // last round (`speculationRequestBytes`' windows) are its own too.
        let depth = Self.mtpDepth + 1
        let windows = speculative ? try Bytes.product([Bytes.sum([
            allocationBound(Bytes.product([depth, linear.numHeads, linear.headDim, linear.headDim, 4])),
            allocationBound(Bytes.product([depth, 3, linear.numHeads, linear.headDim, linear.shortConvKernelSize, 4]))]),
            2, kdaLayers]) : 0
        return try Bytes.sum([Bytes.product([history, dsaLayers, copies]),
            Bytes.product([Bytes.sum([recurrent, convolution]), kdaLayers]),
            speculative ? Bytes.product([history, nextNCopies]) : 0, windows])
    }

    func withExclusiveOperation<T>(_ body: () throws -> T) throws -> T {
        if batchServing { return try body() }
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        return try body()
    }

    /// Lane reservation: admitted when a lane is free and the host holds the
    /// whole request allowance beside every other held lane's state. A full
    /// set of lanes or a host that cannot hold one more is this request's
    /// refusal, not a failure.
    public func reserveLane(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try withExclusiveOperation {
            let now = DispatchTime.now().uptimeNanoseconds
            guard lanes.batching, stage != nil else { throw ProbeError("Batch lanes are not configured for this resident owner") }
            guard value.route == nil, value.stillImages == nil, value.mimoImages == nil,
                  value.profileID == descriptor.profile.identifier,
                  value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(), value.capacityLimitBytes > 0,
                  configuration.admitsRequestDeadline(value.deadlineUptimeNanoseconds, now: now) else {
                throw ProbeError("GLM tensor-parallel reservation differs from its profile, route, media or deadline")
            }
            let request = try QwenLayerStageGenerationRequest(profile: descriptor.profile, requestID: requestID,
                promptTokenIDs: value.promptTokenIDs, chunkSize: value.chunkSize, outputCount: value.outputCount,
                stopTokenIDs: Set(value.stopTokenIDs), sampling: value.sampling, stillImages: nil)
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let media = try reservedMedia(value)
            let mediaBytes = media?.requestBytes ?? 0
            let context = request.maximumTokens
            let charge = try QwenLongPrefillCheckedBytes.sum([try requestCharge.bytes(contextTokens: context), mediaBytes])
            guard charge <= value.capacityLimitBytes, laneBook.count < lanes.lanes else {
                throw ProbeError("GLM lane reservation exceeds its owner ceiling or every lane is taken")
            }
            // A media lane holds its media charge for its whole life, beside its state.
            let state = try QwenLongPrefillCheckedBytes.sum([try Self.laneStateBytes(
                configuration: descriptor.configuration.textConfig,
                contextTokens: context, speculative: mtp != nil,
                historyTokens: requestCharge.historyTokens(contextTokens: context)), mediaBytes])
            let transient = max(0, charge - state)
            // Every held lane's state, and the largest forward's transients.
            let held = laneBook.reservations()
            let states = try QwenLongPrefillCheckedBytes.sum([state] + held.map(\.laneStateBytes))
            let largest = max(transient, held.map(\.transientBytes).max() ?? 0)
            try prefix.yieldingMemory {
                try Self.requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([states, largest]))
            }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            try laneBook.reserve(requestID, .init(request: request, deadline: value.deadlineUptimeNanoseconds,
                laneStateBytes: state, transientBytes: transient, media: media?.media), lanes: lanes.lanes)
            // Rank 0 prepares the patches off the executor; the lane joins once
            // that ended (`GLM5NextTensorParallelLaneReservation.joinable`).
            if collective.rank == 0 { media?.media.startPreparation() }
            return charge
        }
    }

    public func startLane(requestID: UUID) throws { try laneBook.start(requestID) }
    /// Thread-safe: the lane leaves the loop at its next step boundary (a
    /// media lane still preparing stops preparing and joins only to leave).
    public func cancelLane(requestID: UUID) {
        laneBook.cancel(requestID)
        laneBook.reservation(requestID)?.media?.cancelPreparation()
    }
    /// Gives back a lane that was reserved but never started.
    public func withdrawLane(requestID: UUID) -> Bool {
        let media = laneBook.reservation(requestID)?.media
        guard laneBook.withdraw(requestID) else { return false }
        media?.cancelPreparation()
        return true
    }
    /// Started lanes wait for the loop; the worker re-enters it while any do.
    public var hasStartedLanes: Bool { laneBook.hasStarted }

    /// Runs the lane loop until rank 0 has no lane left. Every lane that left
    /// published its finish or its retirement first. Throws on any failure
    /// that is not one lane's, after dropping every lane: the owner is then
    /// failed, as for a failed request.
    public func serveBatch(host: QwenBatchServingHost) throws {
        try withExclusiveOperation {
            guard lanes.batching, let stage else { throw ProbeError("Batch lanes are not configured for this resident owner") }
            batchServing = true
            defer { batchServing = false }
            let scope = UUID()
            do {
                try lifecycle.withRequest(identity: .init(requestID: scope, epoch: scope,
                        recordedRequestFingerprint: sha256(Data("glm5-next-tp-lanes-v1|\(scope.uuidString)".utf8)))) {
                    try autoreleasepool {
                        try MLX.withError { nativeError in
                            var lastResourceCheck: UInt64 = 0
                            func checked() throws {
                                try nativeError.check(); try control.check()
                                let now = DispatchTime.now().uptimeNanoseconds
                                if now - lastResourceCheck >= 250_000_000 {
                                    // As one request: the running lanes need the
                                    // memory they were admitted with.
                                    try prefix.yieldingMemory { try Self.requireLiveMemory(bytes: 0) }
                                    lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                                }
                                try nativeError.check()
                            }
                            let loop = GLM5NextTensorParallelLaneLoop(native: GLM5NextTensorParallelLaneRank(runtime: self,
                                stage: stage), lanes: lanes.lanes, book: laneBook, host: host)
                            try loop.run(check: checked)
                        }
                    }
                }
                collective.logDataPlaneStatus()
            } catch {
                for lane in laneBook.reservations() { lane.media?.cancelPreparation() }
                laneBook.clear(); prefix.sweep(); control.fail()
                throw error
            }
        }
    }
}

/// The lane loop's native half on one GLM tensor-parallel rank.
final class GLM5NextTensorParallelLaneRank: GLM5NextTensorParallelLaneNative {
    typealias Runtime = GLM5NextTensorParallelResidentRuntime

    /// One lane's own request state: what `generate` holds for one request.
    final class Lane {
        let request: QwenLayerStageGenerationRequest
        let sampler: QwenStageTokenSampler?
        let opened: Runtime.OpenedRequest
        let speculates: Bool
        let draw: ((MLXArray) -> MLXArray)?
        let propose: GLM5NextMTP.ProposalSelection?
        var offset: Int
        var stored: [Int] = []

        init(request: QwenLayerStageGenerationRequest, sampler: QwenStageTokenSampler?, opened: Runtime.OpenedRequest,
             speculates: Bool, draw: ((MLXArray) -> MLXArray)?, propose: GLM5NextMTP.ProposalSelection?) {
            self.request = request; self.sampler = sampler; self.opened = opened
            self.speculates = speculates; self.draw = draw; self.propose = propose; offset = opened.start
        }
    }

    private unowned let runtime: Runtime
    private let stage: GLM5NextTextStage

    init(runtime: Runtime, stage: GLM5NextTextStage) { self.runtime = runtime; self.stage = stage }

    var rank: Int { runtime.collective.rank }
    var depth: Int { runtime.mtp == nil ? 0 : Runtime.mtpDepth }
    var prefixEnabled: Bool { runtime.prefix.enabled }

    func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float] {
        let summed = runtime.group.allSum(MLXArray(words))
        try MLX.withError { error in eval(summed); try error.check() }
        try check()
        return summed.asArray(Float.self)
    }

    func open(_ request: QwenLayerStageGenerationRequest, check: () throws -> Void) throws -> Lane {
        let id = request.requestID, book = runtime.laneBook
        let reservation = book.reservation(id)
        // A media lane's features are made and agreed here, as one request's;
        // a rank's cancel or deadline before then stops it on both ranks.
        let opened = try runtime.openRequest(request, stage: stage, media: reservation?.media, stop: {
            book.isCancelled(id) || DispatchTime.now().uptimeNanoseconds >= (reservation?.deadline ?? 0)
        })
        // Rank 0 then retires it at the next step, before any frame of it is planned.
        if opened.stopped, rank == 0 { book.cancel(id) }
        try check()
        let sampler = request.sampler
        // As one request: every request speculates (bias and penalties too).
        let speculates = opened.speculation != nil
        if let speculation = opened.speculation { runtime.installDraftProbe(speculation, sampler: sampler) }
        return Lane(request: request, sampler: sampler, opened: opened, speculates: speculates,
            draw: speculates ? runtime.verificationDraw(sampler) : nil,
            propose: speculates ? runtime.proposalSelection(sampler) : nil)
    }

    func nextFrame(_ lane: Lane, merging: Bool) -> GLM5NextTensorParallelLaneWire.Frame? {
        let count = lane.request.promptTokenIDs.count
        guard lane.offset < count else { return nil }
        let end = Runtime.prefillFrameEnd(offset: lane.offset, promptCount: count, chunk: lane.opened.chunk,
            keepAt: lane.opened.keepAt, merging: merging)
        return .init(offset: lane.offset, end: end, final: end == count)
    }

    func prefill(_ lane: Lane, _ frame: GLM5NextTensorParallelLaneWire.Frame, check: () throws -> Void) throws -> Int? {
        guard frame == nextFrame(lane, merging: false) || frame == nextFrame(lane, merging: true) else {
            throw ProbeError("GLM lane prefill frame is not the lane's next")
        }
        // Equal merging and single-chunk frames run the same micro-batches.
        let result = try runtime.runPrefillFrame(lane.request.promptTokenIDs, offset: frame.offset, end: frame.end,
            opened: lane.opened, stage: stage, merging: frame == nextFrame(lane, merging: true))
        if let at = result.stored { lane.stored.append(at) }
        lane.offset = frame.end
        try check()
        guard frame.final else { return nil }
        guard let final = result.final else { throw ProbeError("GLM tensor-parallel prefill produced no logits") }
        // The first token is agreed as one request's is.
        let first = try Runtime.agreedToken(runtime.choose(final.logits, sampler: lane.sampler, stop: 0)
            .asArray(Float.self), sampled: lane.sampler != nil)
        lane.sampler?.commit(first)
        if lane.speculates { try lane.opened.speculation!.begin(carry: first, lastHidden: final.lastHidden) }
        return first
    }

    func speculates(_ lane: Lane) -> Bool { lane.speculates }

    /// The decode seam, batched: every speculating unit's round in ONE stage
    /// forward and ONE agreement sum (`GLM5NextTensorParallelSpeculation
    /// .rounds`: each lane's window, cache, NextN history and tokens are
    /// bitwise its own round's), then each one-token unit's own step, in unit
    /// order. Both ranks run the same units, so the same collectives in the
    /// same order.
    func decode(_ units: [GLM5NextTensorParallelDecodeUnit<Lane>], whileRunning: (Int) throws -> Void,
                check: () throws -> Void) throws -> [[Int]] {
        try GPU.withCommandBufferLimits(GLM5NextTensorParallelResidentRuntime.decodeCommandBuffers) {
            try decodeUnits(units, whileRunning: whileRunning, check: check)
        }
    }

    private func decodeUnits(_ units: [GLM5NextTensorParallelDecodeUnit<Lane>], whileRunning: (Int) throws -> Void,
                             check: () throws -> Void) throws -> [[Int]] {
        var results = [[Int]?](repeating: nil, count: units.count)
        let speculating = units.indices.filter { units[$0].window != nil }
        if !speculating.isEmpty {
            let lanes = try speculating.map { index -> GLM5NextTensorParallelSpeculation.Lane in
                let unit = units[index]
                guard unit.lane.speculates, let speculation = unit.lane.opened.speculation, let window = unit.window else {
                    throw ProbeError("GLM lane round for a lane that does not speculate")
                }
                return .init(speculation: speculation, cache: unit.lane.opened.cache, last: unit.last, window: window,
                    stop: 0, draw: unit.lane.draw, propose: unit.lane.propose)
            }
            let rounds = try GLM5NextTensorParallelSpeculation.rounds(stage: stage, lanes: lanes, whileRunning: {
                for index in speculating { try whileRunning(index) }
            })
            for (index, round) in zip(speculating, rounds) {
                units[index].lane.sampler?.commitRound(round.tokens)
                results[index] = round.tokens
            }
            try check()
        }
        for (index, unit) in units.enumerated() where unit.window == nil {
            let lane = unit.lane
            guard !lane.speculates else { throw ProbeError("GLM lane step for a lane that speculates") }
            let next = MLXArray([Int32(unit.last)], [1, 1])
            let candidate = try stage.prepareForward(tokens: next, cache: lane.opened.cache, readout: .lastToken)
            try candidate.commit { roots in asyncEval(roots) }
            guard case .final(let output) = candidate.output else {
                throw ProbeError("GLM tensor-parallel decode produced no logits")
            }
            let chosen = runtime.choose(output.logits[0..., -1, 0...], sampler: lane.sampler, stop: 0)
            asyncEval(chosen)
            try whileRunning(index)
            let token = try Runtime.agreedToken(chosen.asArray(Float.self), sampled: lane.sampler != nil)
            lane.sampler?.commit(token)
            results[index] = [token]
            try check()
        }
        return results.map { $0! }
    }

    func close(_ lane: Lane, kept: Int, leave: GLM5NextTensorParallelLaneWire.Leave) -> (reused: Int, stored: [Int]) {
        let speculation = lane.opened.speculation
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) request=\(lane.request.requestID.uuidString.lowercased())"
            + " lane=1 prompt=\(lane.request.promptTokenIDs.count) reused=\(lane.opened.start)"
            + " stored=\(lane.stored.map(String.init).joined(separator: "_")) prefix_entries=\(runtime.prefix.count) prefix_bytes=\(runtime.prefix.bytesInUse)"
            + " output=\(kept) finish=\(leave.finish?.rawValue ?? "cancelled") sampled=\(lane.sampler == nil ? 0 : 1)"
            + " mtp_rounds=\(speculation?.rounds ?? 0) mtp_accepted=\(speculation?.acceptedTokens ?? 0)"
            + " mtp_proposed=\(speculation?.proposedTokens ?? 0)" + Runtime.proposalFields(speculation, sampler: lane.sampler)
            + " media_frames=\(lane.opened.media?.media.frames.count ?? 0) media_tokens=\(lane.opened.media?.featureCount ?? 0)")
        return (lane.opened.start, lane.stored)
    }
}
