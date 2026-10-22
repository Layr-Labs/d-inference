import DarkbloomClusterProtocol
import Foundation

/// One lane's request as its rank's lane book holds it, from reservation
/// until it retires.
struct GLM5NextTensorParallelLaneReservation: ClusterBatchLaneReservation {
    let request: QwenLayerStageGenerationRequest
    let deadline: UInt64
    /// The lane's named state while it is held beside the other lanes
    /// (`GLM5NextTensorParallelResidentRuntime.laneStateBytes`).
    let laneStateBytes: Int
}

/// One decode unit the decode seam runs: a lane, the agreed token it decodes
/// after, and its MTP window (the proposals its round verifies, 0...depth), or
/// nil for a one-token step.
struct GLM5NextTensorParallelDecodeUnit<Lane> {
    let lane: Lane
    let last: Int
    let window: Int?
}

/// The native half of the lane loop on one rank: every tensor, sum and cache.
/// The loop (`GLM5NextTensorParallelLaneLoop`) decides and orders; this runs.
/// Both ranks call their native in the same order with the same arguments
/// (rank 0's plan, which rank 1 follows), so every collective inside meets
/// its peer's. `check` is the loop's cancellation and native-error check.
protocol GLM5NextTensorParallelLaneNative: AnyObject {
    associatedtype Lane: AnyObject
    var rank: Int { get }
    /// NextN proposals an MTP round verifies at most (0: no NextN layer).
    var depth: Int { get }
    var prefixEnabled: Bool { get }
    /// The step's one sealed all-sum (`GLM5NextTensorParallelLaneWire`), evaluated.
    func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float]
    /// A joining request: both ranks check they hold the same request, vote
    /// for its prompt prefix and restore it or start cold (collective).
    func open(_ request: QwenLayerStageGenerationRequest, check: () throws -> Void) throws -> Lane
    /// The lane's next prefill frame on its own (solo) grid; nil once its
    /// prompt is in.
    func nextFrame(_ lane: Lane) -> GLM5NextTensorParallelLaneWire.Frame?
    /// Runs that frame (collective); the final one returns the agreed first token.
    func prefill(_ lane: Lane, _ frame: GLM5NextTensorParallelLaneWire.Frame, check: () throws -> Void) throws -> Int?
    /// True when the lane decodes in MTP rounds, false for one token a step.
    func speculates(_ lane: Lane) -> Bool
    /// The decode seam: one decode unit for each of `units`, in order, and
    /// each unit's agreed new tokens (a round's accepted proposals and the
    /// target's next token, or a step's one token), before any end of request
    /// is applied. Each unit's tokens must be exactly the ones the request
    /// alone would agree at that point. `whileRunning(i)` is called once per
    /// unit `i` after its work was submitted and before its result is read
    /// (rank 0 talks to its owner then); it never changes a result.
    func decode(_ units: [GLM5NextTensorParallelDecodeUnit<Lane>], whileRunning: (Int) throws -> Void,
                check: () throws -> Void) throws -> [[Int]]
    /// Drops the lane's native state: prompt tokens it restored and the
    /// prompt frontiers it kept.
    func close(_ lane: Lane, kept: Int, leave: GLM5NextTensorParallelLaneWire.Leave) -> (reused: Int, stored: [Int])
}

/// Continuous batching for GLM tensor parallel. Both ranks run this loop in
/// lockstep; rank 0 decides every step and both run what it decided:
///
/// 1. Leaves: a lane whose request ended (rank 0 heard every answer), was
///    stopped by its owner's answer, was cancelled, or passed its deadline
///    (on either rank) retires its native state on both ranks; the others go on.
/// 2. Joins, first come first served, into free slots: both ranks check the
///    request and vote its prompt prefix, as one request does.
/// 3. At most one prefill frame, of the earliest joined lane still prefilling,
///    on that request's own chunk grid (`prefillFrameEnd`), so every frame is
///    the frame the request alone runs.
/// 4. One decode unit for every decoding lane (`GLM5NextTensorParallelLaneNative.decode`).
///
/// The plan crosses inside the step's one sealed sum
/// (`GLM5NextTensorParallelLaneWire`), with rank 1's report beside it. Rank 0
/// alone talks to its owner: it publishes each lane's agreed tokens and reads
/// the answers late, as one request does (each token is answered before the
/// next is published; the newest one's answer is read while the lane's next
/// unit runs). A stop answer ends the lane at the token it answers; the work
/// done past it is never published. A lane whose owner answers slowly waits
/// alone: its answers are waited for only a bounded time a step, and a lane
/// more than two rounds of tokens behind runs no unit until they catch up.
/// Control (reservations, starts, cancels) is applied at every step and
/// between decode units, so a lane's admission waits at most one prefill
/// frame or decode unit on each rank.
final class GLM5NextTensorParallelLaneLoop<Native: GLM5NextTensorParallelLaneNative> {
    typealias Wire = GLM5NextTensorParallelLaneWire

    /// One lane as the loop holds it on this rank.
    final class Record {
        let id: UUID
        let slot: Int
        let order: Int
        let reservation: GLM5NextTensorParallelLaneReservation
        var native: Native.Lane?
        /// Agreed tokens, cut at the request's own end (a stop token or its
        /// output limit), identical on both ranks.
        var tokens: [Int] = []
        var ended = false
        // Rank 0 only: publication to the owner and its answers.
        var published = 0
        var answered = 0
        var awaiting = false
        var lastAnswer = true
        /// The owner's stop answer: the tokens the request keeps.
        var stoppedAt: Int?

        init(id: UUID, slot: Int, order: Int, reservation: GLM5NextTensorParallelLaneReservation) {
            self.id = id; self.slot = slot; self.order = order; self.reservation = reservation
        }
        var request: QwenLayerStageGenerationRequest { reservation.request }
        var prefilled: Bool { !tokens.isEmpty }

        /// Appends a unit's tokens up to the request's own end.
        func agree(_ fresh: [Int]) {
            for token in fresh where !ended {
                tokens.append(token)
                if request.stopTokenIDs.contains(token) || tokens.count >= request.outputCount { ended = true }
            }
        }
    }

    let native: Native
    let lanes: Int
    let book: ClusterBatchLaneBook<GLM5NextTensorParallelLaneReservation>
    let host: QwenBatchServingHost
    let now: () -> UInt64
    /// The longest rank 1 waits for its own start of a lane rank 0 joined.
    let joinWaitNanoseconds: UInt64
    /// A lane leaves this long before its deadline (its owner cancels it
    /// earlier still), so it retires before any rank's owner holds it overdue.
    let deadlineMarginNanoseconds: UInt64
    /// Rank 0: the longest one answer is waited for in a step.
    let answerWaitNanoseconds: UInt64
    private(set) var step = 0
    private var order = 0
    private var slots: [Int: Record] = [:]

    init(native: Native, lanes: Int, book: ClusterBatchLaneBook<GLM5NextTensorParallelLaneReservation>,
         host: QwenBatchServingHost, joinWaitNanoseconds: UInt64 = 30_000_000_000,
         deadlineMarginNanoseconds: UInt64 = 10_000_000_000, answerWaitNanoseconds: UInt64 = 100_000_000,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.native = native; self.lanes = lanes; self.book = book; self.host = host
        self.joinWaitNanoseconds = joinWaitNanoseconds; self.deadlineMarginNanoseconds = deadlineMarginNanoseconds
        self.answerWaitNanoseconds = answerWaitNanoseconds; self.now = now
    }

    /// True once the lane is within its deadline margin.
    private func overdue(_ lane: Record, at time: UInt64) -> Bool {
        time >= lane.reservation.deadline - min(deadlineMarginNanoseconds, lane.reservation.deadline)
    }

    /// Runs until rank 0 has no lane left. Throws on any failure that is not
    /// one lane's (collective, agreement, native, protocol): the caller then
    /// ends every lane and the pair.
    func run(check: () throws -> Void) throws {
        guard (1...Wire.maximumLanes).contains(lanes) else { throw ProbeError("GLM lane loop lane count") }
        if native.rank == 0 {
            var peerWanted = Set<Int>()
            while try !autoreleasepool(invoking: { try lead(peerWanted: &peerWanted, check: check) }) {}
        } else {
            while try !autoreleasepool(invoking: { try follow(check: check) }) {}
        }
    }

    // MARK: Rank 0

    /// How a lane leaves now, or nil while it goes on.
    private func leave(_ lane: Record, peerWants: Bool) -> (Wire.Leave, Int)? {
        if book.isCancelled(lane.id) || overdue(lane, at: now()) || peerWants {
            return (.cancelled, lane.answered)
        }
        let kept: Int, wanted: Bool
        if let stopped = lane.stoppedAt {
            kept = stopped; wanted = false
        } else if lane.ended && !lane.awaiting && lane.answered == lane.tokens.count {
            kept = lane.tokens.count; wanted = lane.lastAnswer
        } else {
            return nil
        }
        guard kept > 0 else { return (.cancelled, 0) }
        switch QwenTensorParallelStopRule.outcome(isStopToken: lane.request.stopTokenIDs.contains(lane.tokens[kept - 1]),
                                                  committed: kept, outputCount: lane.request.outputCount, wanted: wanted) {
        case .eos: return (.eos, kept)
        case .length: return (.length, kept)
        case .clientStop: return (.clientStop, kept)
        case .proceed: return nil
        }
    }

    /// One step on rank 0; true when the loop ends.
    private func lead(peerWanted: inout Set<Int>, check: () throws -> Void) throws -> Bool {
        try host.serviceControl()
        try check()
        // Leaves are decided, announced and run in the same step.
        var leaving: [Int: (Record, Wire.Leave, Int)] = [:]
        for (slot, lane) in slots {
            guard let (reason, kept) = leave(lane, peerWants: peerWanted.contains(slot)) else { continue }
            leaving[slot] = (lane, reason, kept); slots[slot] = nil
        }
        var joining: [Int] = []
        while let free = (0..<lanes).first(where: { slots[$0] == nil && leaving[$0] == nil }),
              let (id, reservation) = book.takeStarted() {
            slots[free] = Record(id: id, slot: free, order: order, reservation: reservation)
            order += 1; joining.append(free)
        }
        // A lane whose owner has not answered two rounds of its tokens waits.
        let backlog = 2 * (native.depth + 1)
        let decoding = slots.keys.sorted().filter {
            let lane = slots[$0]!
            return lane.native != nil && lane.prefilled && !lane.ended && lane.stoppedAt == nil
                && lane.tokens.count - lane.answered <= backlog
        }
        let prefilling = slots.values.filter { $0.native != nil && !$0.prefilled }.min { $0.order < $1.order }
        let frame = prefilling.flatMap { native.nextFrame($0.native!) }
        var plan = Wire.Plan(step: step, stop: slots.isEmpty && leaving.isEmpty, lanes: lanes, depth: native.depth,
            prefixEnabled: native.prefixEnabled, slots: Array(repeating: .init(), count: lanes))
        for (slot, value) in leaving {
            plan.slots[slot] = .init(state: .leaving, requestID: value.0.id, tokens: value.0.tokens.count,
                leave: value.1, kept: value.2)
        }
        var windows: [Int: Int?] = [:]
        for (slot, lane) in slots {
            var value = Wire.Slot(state: joining.contains(slot) ? .joining : .active, requestID: lane.id,
                tokens: lane.tokens.count)
            if decoding.contains(slot) {
                let window = native.speculates(lane.native!)
                    ? min(native.depth, lane.request.outputCount - lane.tokens.count - 1) : nil
                value.role = .decode; value.last = lane.tokens.last!; value.window = window; windows[slot] = window
            } else if let prefilling, prefilling === lane, let frame {
                value.role = .prefill; value.frame = frame
            }
            plan.slots[slot] = value
        }
        if !plan.stop, leaving.isEmpty, joining.isEmpty, frame == nil, decoding.isEmpty {
            // Every lane waits for its owner's answers: do not spin the link.
            Thread.sleep(forTimeInterval: 0.001)
        }
        let report = try Wire.read(native.exchange(Wire.words(plan), check: check), lanes: lanes, step: step).report
        guard report.prefixEnabled == native.prefixEnabled else {
            throw ProbeError("GLM lane ranks differ in their prompt-prefix cache")
        }
        // Rank 1 holds what rank 0 held before this step, at the same agreed count.
        for slot in 0..<lanes {
            let held = leaving[slot]?.0 ?? (joining.contains(slot) ? nil : slots[slot])
            guard report.tokens[slot] == held?.tokens.count else {
                throw ProbeError("GLM lane ranks hold different lanes or agreed tokens")
            }
        }
        peerWanted = Set((0..<lanes).filter { report.leaveWanted[$0] })
        if plan.stop { return true }

        for slot in leaving.keys.sorted() {
            let (lane, reason, kept) = leaving[slot]!
            try retire(lane, reason: reason, kept: kept)
        }
        for slot in joining.sorted() {
            let lane = slots[slot]!
            lane.native = try native.open(lane.request, check: check)
        }
        if let prefilling, let frame, let lane = prefilling.native {
            if let first = try native.prefill(lane, frame, check: check) {
                prefilling.agree([first])
                try pump(prefilling, .poll)
            }
        }
        if !decoding.isEmpty {
            let lanes = decoding.map { slots[$0]! }
            let units = lanes.map { GLM5NextTensorParallelDecodeUnit(lane: $0.native!, last: $0.tokens.last!,
                window: windows[$0.slot]!) }
            let rounds = try native.decode(units, whileRunning: { index in
                // This lane's earlier tokens are answered while its unit runs;
                // the others publish what they can without waiting.
                try pump(lanes[index], .allButLast)
                for (other, lane) in lanes.enumerated() where other != index { try pump(lane, .poll) }
            }, check: { try check(); try host.serviceControl() })
            guard rounds.count == lanes.count, rounds.allSatisfy({ !$0.isEmpty }) else {
                throw ProbeError("GLM lane decode returned no tokens for a unit")
            }
            for (lane, round) in zip(lanes, rounds) {
                guard round.count <= (windows[lane.slot]!.map { $0 + 1 } ?? 1) else {
                    throw ProbeError("GLM lane decode returned more tokens than its window")
                }
                lane.agree(round)
            }
        }
        // A request that ended has every token answered before it leaves.
        for lane in slots.values where lane.ended && lane.stoppedAt == nil { try pump(lane, .all) }
        for lane in slots.values { try pump(lane, .poll) }
        step += 1
        return false
    }

    private enum Flush { case poll, allButLast, all }

    /// Rank 0: publishes the lane's agreed tokens in order, each only after
    /// the answer to the one before it. `.poll` never waits; `.allButLast`
    /// waits until every token is published (the newest may stay unanswered);
    /// `.all` until every token is answered. A wait for one answer lasts at
    /// most `answerWaitNanoseconds`; the pump then stops until a later call.
    private func pump(_ lane: Record, _ mode: Flush) throws {
        while true {
            if lane.awaiting {
                if mode == .allButLast && lane.published == lane.tokens.count { return }
                var answer = try host.pollDecision(lane.id)
                if mode != .poll {
                    let limit = DispatchTime.now().uptimeNanoseconds + answerWaitNanoseconds
                    while answer == nil && DispatchTime.now().uptimeNanoseconds < limit {
                        Thread.sleep(forTimeInterval: 0.0002)
                        answer = try host.pollDecision(lane.id)
                    }
                }
                guard let answer else { return }
                lane.awaiting = false; lane.answered += 1; lane.lastAnswer = answer
                if !answer { lane.stoppedAt = lane.answered; return }
            }
            guard lane.stoppedAt == nil, lane.published < lane.tokens.count else { return }
            try host.publishToken(requestID: lane.id, ordinal: lane.published, tokenID: lane.tokens[lane.published],
                committedTokens: lane.request.promptTokenIDs.count + lane.published)
            lane.published += 1; lane.awaiting = true
        }
    }

    // MARK: Rank 1

    /// One step on rank 1; true when the loop ends.
    private func follow(check: () throws -> Void) throws -> Bool {
        try host.serviceControl()
        try check()
        let time = now()
        let report = Wire.Report(step: step, lanes: lanes, prefixEnabled: native.prefixEnabled,
            leaveWanted: (0..<lanes).map { slot in
                slots[slot].map { book.isCancelled($0.id) || overdue($0, at: time) } ?? false
            },
            tokens: (0..<lanes).map { slots[$0]?.tokens.count })
        let plan = try Wire.read(native.exchange(Wire.words(report), check: check), lanes: lanes, step: step).plan
        guard plan.prefixEnabled == native.prefixEnabled, plan.depth == native.depth else {
            throw ProbeError("GLM lane ranks differ in their prompt-prefix cache or speculative depth")
        }
        for (slot, value) in plan.slots.enumerated() {
            switch value.state {
            case .empty, .joining:
                guard slots[slot] == nil else { throw ProbeError("GLM lane plan leaves out a lane this rank holds") }
            case .active, .leaving:
                guard let lane = slots[slot], lane.id == value.requestID, lane.tokens.count == value.tokens else {
                    throw ProbeError("GLM lane plan names a lane or agreed count this rank does not hold")
                }
            }
        }
        if plan.stop { return true }

        for (slot, value) in plan.slots.enumerated() where value.state == .leaving {
            let lane = slots[slot]!, reason = value.leave!, kept = value.kept
            if let finish = reason.finish {
                // Rank 0's finish must be one this rank's agreed tokens allow.
                guard kept > 0, kept <= lane.tokens.count else {
                    throw ProbeError("GLM lane plan keeps tokens this rank did not agree")
                }
                let last = lane.tokens[kept - 1], stop = lane.request.stopTokenIDs.contains(last)
                let valid: Bool
                switch finish {
                case .eos: valid = stop
                case .length: valid = !stop && kept == lane.request.outputCount
                case .clientStop: valid = !stop && kept < lane.request.outputCount
                }
                guard valid else { throw ProbeError("GLM lane plan finishes a lane for a reason its tokens refute") }
            }
            try retire(lane, reason: reason, kept: kept)
            slots[slot] = nil
        }
        for (slot, value) in plan.slots.enumerated() where value.state == .joining {
            let id = value.requestID!
            // The owner starts both ranks; this rank's start may still be on its way.
            let limit = min(book.reservations().first { $0.request.requestID == id }?.deadline ?? UInt64.max,
                now() + joinWaitNanoseconds)
            while !book.isStarted(id) {
                try host.serviceControl(); try check()
                guard now() < limit else { throw ProbeError("GLM lane joined on rank 0 was never started here") }
                if !book.isStarted(id) { Thread.sleep(forTimeInterval: 0.0005) }
            }
            guard let reservation = book.takeStarted(id) else { throw ProbeError("GLM lane vanished before joining") }
            let lane = Record(id: id, slot: slot, order: order, reservation: reservation)
            order += 1
            slots[slot] = lane
            lane.native = try native.open(lane.request, check: check)
        }
        if let slot = plan.slots.indices.first(where: { plan.slots[$0].role == .prefill }) {
            let value = plan.slots[slot]
            guard let lane = slots[slot], let state = lane.native, !lane.prefilled,
                  let frame = native.nextFrame(state), frame == value.frame else {
                throw ProbeError("GLM lane prefill frame differs from this rank's lane")
            }
            let first = try native.prefill(state, frame, check: check)
            guard (first != nil) == frame.final else { throw ProbeError("GLM lane prefill frame did not end as planned") }
            if let first { lane.agree([first]) }
        }
        let decoding = plan.slots.indices.filter { plan.slots[$0].role == .decode }
        if !decoding.isEmpty {
            let lanes = try decoding.map { slot -> Record in
                let value = plan.slots[slot]
                guard let lane = slots[slot], let state = lane.native, lane.prefilled, !lane.ended,
                      value.last == lane.tokens.last,
                      value.window == (native.speculates(state)
                        ? min(native.depth, lane.request.outputCount - lane.tokens.count - 1) : nil) else {
                    throw ProbeError("GLM lane decode unit differs from this rank's lane")
                }
                return lane
            }
            let units = zip(lanes, decoding).map {
                GLM5NextTensorParallelDecodeUnit(lane: $0.native!, last: $0.tokens.last!, window: plan.slots[$1].window)
            }
            let rounds = try native.decode(units, whileRunning: { _ in }, check: { try check(); try host.serviceControl() })
            guard rounds.count == lanes.count, rounds.allSatisfy({ !$0.isEmpty }) else {
                throw ProbeError("GLM lane decode returned no tokens for a unit")
            }
            for (lane, round) in zip(lanes, rounds) { lane.agree(round) }
        }
        step += 1
        return false
    }

    // MARK: Both ranks

    /// Retires one lane on this rank: its native state, its prompt-cache
    /// report and its finish, or, cancelled, its retirement without one.
    private func retire(_ lane: Record, reason: Wire.Leave, kept: Int) throws {
        let cache = lane.native.map { native.close($0, kept: kept, leave: reason) } ?? (reused: 0, stored: [])
        lane.native = nil
        if let finish = reason.finish {
            if cache.reused > 0 || !cache.stored.isEmpty {
                try host.publishPromptCache(requestID: lane.id, reusedTokens: cache.reused,
                    storedFrontiers: Array(cache.stored.sorted().suffix(32)))
            }
            try host.publishFinished(requestID: lane.id, reason: finish)
        } else {
            try host.publishLeft(requestID: lane.id)
        }
        book.finish(lane.id)
    }
}
