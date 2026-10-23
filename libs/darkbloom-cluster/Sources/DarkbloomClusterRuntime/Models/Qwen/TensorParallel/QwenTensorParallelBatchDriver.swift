import DarkbloomClusterProtocol
import Foundation

protocol QwenTensorParallelBatchReservation: ClusterBatchLaneReservation {
    var request: QwenLayerStageGenerationRequest { get }
    var deadline: UInt64 { get }
    var joinable: Bool { get }
}

protocol QwenTensorParallelBatchLane: AnyObject {
    var nextFrame: QwenLayerStageFrame? { get }
    var committedTokens: Int { get }
    var isClosed: Bool { get }
    var reusedPrefixTokens: Int { get }
    var storedPrefixFrontiers: [Int] { get }
}

extension QwenTensorParallelBatchLane {
    var reusedPrefixTokens: Int { 0 }
    var storedPrefixFrontiers: [Int] { [] }
}

/// Both ranks run every forward. Selection returns the same token to both;
/// only rank0 advances request samplers and publishes their raw logprobs.
protocol QwenTensorParallelBatchExecutor: AnyObject {
    associatedtype Reservation: QwenTensorParallelBatchReservation
    associatedtype Lane: QwenTensorParallelBatchLane
    var rank: Int { get }
    func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float]
    func discard(_ reservation: Reservation) throws
    func open(_ reservation: Reservation, check: () throws -> Void) throws -> Lane
    func prefill(_ lane: Lane, frame: QwenLayerStageFrame, check: () throws -> Void) throws -> Int?
    func decode(_ lanes: [Lane], tokens: [Int], check: () throws -> Void) throws -> [Int]
    func retire(_ lane: Lane, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws
    func takeLogprobs(_ lane: Lane) throws -> ClusterWorkerTokenLogprobs?
    func confirmedRetirement(_ lane: Lane, clean: Bool) throws
}

extension QwenTensorParallelBatchExecutor {
    func confirmedRetirement(_ lane: Lane, clean: Bool) throws {}
}

/// One prefill frame on its original grid and one real decode rectangle per
/// step. Every active request owns its native history. A slow client holds
/// only its own token credit. Successful retirement is published only after
/// both ranks have drained, including cancellation and deadline departures.
final class QwenTensorParallelBatchDriver<Executor: QwenTensorParallelBatchExecutor> {
    typealias Reservation = Executor.Reservation
    private final class Record {
        let reservation: Reservation
        let slot: Int, order: Int
        var native: Executor.Lane?
        var tokens: [Int] = []
        var id: UUID { reservation.request.requestID }
        var fingerprint: [Int32] { QwenBatchWire.fingerprintWords(reservation.request.fingerprint) }
        init(_ reservation: Reservation, slot: Int, order: Int) {
            self.reservation = reservation; self.slot = slot; self.order = order
        }
        func finish(_ proceed: Bool) -> QwenLayerStageGenerationFinishReason? {
            guard let last = tokens.last else { return nil }
            if reservation.request.stopTokenIDs.contains(last) { return .eos }
            if tokens.count == reservation.request.outputCount { return .length }
            return proceed ? nil : .clientStop
        }
    }
    private let executor: Executor
    private let book: ClusterBatchLaneBook<Reservation>
    private let capacity: Int, vocabulary: Int
    private let now: () -> UInt64
    private let joinWaitNanoseconds: UInt64
    private var records: [Int: Record] = [:]
    private var order = 0

    init(executor: Executor, book: ClusterBatchLaneBook<Reservation>, capacity: Int, vocabulary: Int,
         joinWaitNanoseconds: UInt64 = 30_000_000_000,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        guard (0...1).contains(executor.rank), (1...8).contains(capacity), vocabulary > 0,
              joinWaitNanoseconds > 0 else { throw ProbeError("Qwen TP batch driver has invalid geometry") }
        self.executor = executor; self.book = book; self.capacity = capacity; self.vocabulary = vocabulary
        self.joinWaitNanoseconds = joinWaitNanoseconds; self.now = now
    }

    private func cancelled(_ record: Record) -> Bool {
        book.isCancelled(record.id) || now() >= record.reservation.deadline
    }

    func serve(host: QwenBatchServingHost, check: () throws -> Void) throws {
        var step = 0
        var decisions = QwenBatchDecisionProgress()
        var coalescing = QwenBatchDecodeCoalescing()
        var peerCancelled = Set<Int>()
        do {
            while true {
                let stop = try autoreleasepool { () throws -> Bool in
                    let answers = executor.rank == 0 ? try decisions.serviceAndPoll(host) : [:]
                    if executor.rank == 1 { try host.serviceControl() }
                    try check()
                    let localPlan = executor.rank == 0
                        ? makePlan(step: step, answers: answers, decisions: decisions, peerCancelled: peerCancelled,
                                   coalescing: &coalescing) : nil
                    let localReport = executor.rank == 1 ? report(step: step) : nil
                    let sum = try executor.exchange(QwenTensorParallelBatchWire.contribution(
                        rank: executor.rank, plan: localPlan, report: localReport), check: check)
                    let (plan, peer) = try QwenTensorParallelBatchWire.read(sum, step: step, lanes: capacity)
                    if let localPlan, plan != localPlan { throw ProbeError("Qwen TP leader plan changed in transit") }
                    if let localReport, peer != localReport { throw ProbeError("Qwen TP follower report changed in transit") }
                    try validate(plan, peer: peer)
                    peerCancelled = Set((0..<capacity).filter { peer.cancelledMask & (1 << $0) != 0 })
                    if plan.stop { return true }
                    try leave(plan, host: host, decisions: &decisions, check: check)
                    try join(plan, host: host, check: check)
                    let decode = plan.slots.indices.filter { plan.slots[$0].role == .decode }
                    if !decode.isEmpty {
                        let lanes = try decode.map { slot -> Record in
                            guard let record = records[slot], let native = record.native,
                                  native.nextFrame?.phase == .decode, record.tokens.last == plan.slots[slot].inputToken else {
                                throw ProbeError("Qwen TP decode differs from its request history")
                            }
                            return record
                        }
                        let tokens = try executor.decode(lanes.map { $0.native! }, tokens: lanes.map { $0.tokens.last! },
                            check: { try check(); try host.serviceControl() })
                        guard tokens.count == lanes.count else { throw ProbeError("Qwen TP decode omitted a lane") }
                        for (lane, token) in zip(lanes, tokens) { try selected(token, lane: lane, decisions: &decisions, host: host, publish: !peerCancelled.contains(lane.slot)) }
                    }
                    let prompts = plan.slots.indices.filter { plan.slots[$0].role == .prefill }
                    guard prompts.count <= 1 else { throw ProbeError("Qwen TP plan has multiple prefill frames") }
                    if let slot = prompts.first {
                        let value = plan.slots[slot]
                        guard let lane = records[slot], let native = lane.native, let frame = native.nextFrame,
                              frame.phase == .prefill, frame.tokenOffset == value.frameOffset,
                              frame.tokenCount == value.frameCount, frame.finalPromptChunk == value.finalChunk else {
                            throw ProbeError("Qwen TP prefill differs from its original chunk grid")
                        }
                        let token = try executor.prefill(native, frame: frame, check: { try check(); try host.serviceControl() })
                        guard (token != nil) == frame.finalPromptChunk else { throw ProbeError("Qwen TP prefill returned the wrong final-row kind") }
                        if let token { try selected(token, lane: lane, decisions: &decisions, host: host, publish: !peerCancelled.contains(lane.slot)) }
                    }
                    if decode.isEmpty && prompts.isEmpty && plan.slots.allSatisfy({ $0.state == .active || $0.state == .empty }) {
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                    return false
                }
                if stop { return }
                step += 1
            }
        } catch {
            let primary = error
            do { try retireAll() }
            catch { throw ProbeError("\(primary); Qwen TP batch cleanup failed (\(error))") }
            throw primary
        }
    }

    private func makePlan(step: Int, answers: [UUID: Bool], decisions: QwenBatchDecisionProgress,
                          peerCancelled: Set<Int>, coalescing: inout QwenBatchDecodeCoalescing) -> QwenBatchWire.Header {
        var slots = [QwenBatchWire.Slot](repeating: .init(), count: capacity)
        for (slot, record) in records {
            var value = QwenBatchWire.Slot(state: .active, requestID: record.id)
            value.committedTokens = record.native?.committedTokens ?? 0
            value.selectedTokens = record.tokens.count; value.fingerprintWords = record.fingerprint
            let reason = answers[record.id].flatMap { record.finish($0) }
            if cancelled(record) || peerCancelled.contains(slot) || reason != nil {
                value.state = .leaving; value.leaveCancelled = cancelled(record) || peerCancelled.contains(slot)
                value.leaveReason = value.leaveCancelled ? nil : reason
            } else if record.native?.nextFrame?.phase == .decode, decisions.canForward(record.id) {
                value.role = .decode; value.inputToken = record.tokens.last ?? -1
            }
            slots[slot] = value
        }
        while let slot = slots.firstIndex(where: { $0.state == .empty }),
              let (_, reserved) = book.takeStarted(where: \.joinable) {
            let record = Record(reserved, slot: slot, order: order); order += 1; records[slot] = record
            var value = QwenBatchWire.Slot(state: .joining, requestID: record.id)
            value.fingerprintWords = record.fingerprint; slots[slot] = value
        }
        if let prompt = records.values.filter({
            slots[$0.slot].state == .active && $0.native?.nextFrame?.phase == .prefill
        }).min(by: { $0.order < $1.order }), let frame = prompt.native?.nextFrame {
            slots[prompt.slot].role = .prefill; slots[prompt.slot].frameOffset = frame.tokenOffset
            slots[prompt.slot].frameCount = frame.tokenCount; slots[prompt.slot].finalChunk = frame.finalPromptChunk
        }
        let decoding = slots.indices.filter {
            slots[$0].state == .active && records[$0]?.native?.nextFrame?.phase == .decode
        }
        let ready = decoding.filter { slots[$0].role == .decode }
        // Let nearby credits form one decode rectangle without waiting on a
        // silent lane. Joining, prefill and retirement keep their next step.
        if coalescing.shouldDefer(ready: ready.count, pending: decoding.count - ready.count,
            hasOtherWork: slots.contains { $0.state == .joining || $0.state == .leaving || $0.role == .prefill },
            now: now) {
            for slot in ready { slots[slot].role = .none; slots[slot].inputToken = -1 }
        }
        return .init(step: step, stop: slots.allSatisfy({ $0.state == .empty }) && !book.hasStarted, slots: slots)
    }

    private func report(step: Int) -> QwenBatchWire.Reply {
        let mask = records.values.reduce(0) { $0 | (cancelled($1) ? 1 << $1.slot : 0) }
        return .init(step: step, tokens: (0..<capacity).map { records[$0]?.tokens.count ?? -1 }, cancelledMask: mask)
    }

    private func validate(_ plan: QwenBatchWire.Header, peer: QwenBatchWire.Reply) throws {
        for (slot, value) in plan.slots.enumerated() {
            guard !value.confirming, value.offers.isEmpty, value.reusedPrefix == 0,
                  value.committedTokens >= 0, value.selectedTokens >= 0,
                  value.role == .none || value.state == .active else { throw ProbeError("Qwen TP plan has invalid lane fields") }
            let record = records[slot]
            if executor.rank == 0 {
                let expected = value.state == .joining ? -1 : record?.tokens.count ?? -1
                guard peer.tokens[slot] == expected else { throw ProbeError("Qwen TP ranks disagree on selected token counts") }
            }
            switch value.state {
            case .empty:
                guard record == nil else { throw ProbeError("Qwen TP plan omits a held lane") }
            case .joining:
                guard executor.rank == 0 || record == nil else { throw ProbeError("Qwen TP join replaces a held lane") }
            case .active, .leaving:
                guard let record, record.id == value.requestID, record.fingerprint == value.fingerprintWords,
                      record.tokens.count == value.selectedTokens, record.native?.committedTokens == value.committedTokens else {
                    throw ProbeError("Qwen TP plan differs in request identity or committed frontier")
                }
            }
        }
    }

    private func join(_ plan: QwenBatchWire.Header, host: QwenBatchServingHost, check: () throws -> Void) throws {
        for (slot, value) in plan.slots.enumerated() where value.state == .joining {
            guard let id = value.requestID else { throw ProbeError("Qwen TP join omits its request ID") }
            if executor.rank == 1 {
                let start = now()
                while !book.isStarted(id) {
                    try host.serviceControl(); try check()
                    guard now() >= start, now() - start < joinWaitNanoseconds else { throw ProbeError("Qwen TP peer start never arrived") }
                    Thread.sleep(forTimeInterval: 0.0005)
                }
                guard let reserved = book.takeStarted(id), QwenBatchWire.fingerprintWords(reserved.request.fingerprint) == value.fingerprintWords else {
                    throw ProbeError("Qwen TP joining request differs between ranks")
                }
                records[slot] = Record(reserved, slot: slot, order: order); order += 1
            }
            guard let record = records[slot], record.id == id, record.native == nil else { throw ProbeError("Qwen TP native lane was already opened") }
            // Cancellation before native admission is request-local. Both
            // ranks vote before either starts media preparation/forward. Host
            // work that already began must finish and release before the ACK.
            let local = cancelled(record) ? Float(1) : 0
            let flags = try executor.exchange(executor.rank == 0 ? [local, 0] : [0, local], check: check)
            guard flags.count == 2, flags.allSatisfy({ $0 == 0 || $0 == 1 }) else {
                throw ProbeError("Qwen TP join cancellation vote is invalid")
            }
            if flags.contains(1) {
                try executor.discard(record.reservation)
                let closed = try executor.exchange(executor.rank == 0 ? [1, 0] : [0, 1], check: check)
                guard closed == [1, 1] else { throw ProbeError("Qwen TP peer retained an unjoined reservation") }
                book.finish(id); records[slot] = nil
                try host.publishLeft(requestID: id)
            } else {
                record.native = try executor.open(record.reservation, check: check)
            }
        }
    }

    private func selected(_ token: Int, lane: Record, decisions: inout QwenBatchDecisionProgress,
                          host: QwenBatchServingHost, publish: Bool) throws {
        guard (0..<vocabulary).contains(token) else { throw ProbeError("Qwen TP selected token lies outside the vocabulary") }
        lane.tokens.append(token)
        if executor.rank == 0, publish, !cancelled(lane) {
            let logprobs = try executor.takeLogprobs(lane.native!)
            try decisions.published(lane.id)
            try host.publishToken(requestID: lane.id, ordinal: lane.tokens.count - 1, tokenID: token,
                committedTokens: lane.reservation.request.promptCount + lane.tokens.count - 1, logprobs: logprobs)
        }
    }

    private func leave(_ plan: QwenBatchWire.Header, host: QwenBatchServingHost,
                       decisions: inout QwenBatchDecisionProgress, check: () throws -> Void) throws {
        let leaving = plan.slots.indices.filter { plan.slots[$0].state == .leaving }
        guard !leaving.isEmpty else { return }
        for slot in leaving {
            let value = plan.slots[slot], record = records[slot]!
            guard let native = record.native,
                  value.leaveCancelled || (value.leaveReason != nil && record.finish(value.leaveReason != .clientStop) == value.leaveReason) else {
                throw ProbeError("Qwen TP leave reason differs from selected tokens")
            }
            try executor.retire(native, reason: value.leaveCancelled ? nil : value.leaveReason,
                                selected: record.tokens.count, last: record.tokens.last)
            guard native.isClosed else { throw ProbeError("Qwen TP retirement retained native history") }
        }
        // A successful local close alone is insufficient to release the host's
        // admission. The next sealed collective proves its peer also drained.
        var vote = [Float](repeating: 0, count: 2 * capacity)
        for slot in leaving { vote[executor.rank * capacity + slot] = 1 }
        let both = try executor.exchange(vote, check: check)
        var expected = [Float](repeating: 0, count: vote.count)
        for slot in leaving { expected[slot] = 1; expected[capacity + slot] = 1 }
        guard both == expected else { throw ProbeError("Qwen TP peer did not prove native retirement") }
        for slot in leaving {
            let value = plan.slots[slot], record = records[slot]!
            let native = record.native!
            try executor.confirmedRetirement(native, clean: !value.leaveCancelled)
            if !value.leaveCancelled, native.reusedPrefixTokens > 0 || !native.storedPrefixFrontiers.isEmpty {
                try host.publishPromptCache(requestID: record.id, reusedTokens: native.reusedPrefixTokens,
                    storedFrontiers: native.storedPrefixFrontiers)
            }
            record.native = nil; book.finish(record.id); decisions.retired(record.id); records[slot] = nil
            if value.leaveCancelled { try host.publishLeft(requestID: record.id) }
            else if let reason = value.leaveReason { try host.publishFinished(requestID: record.id, reason: .init(rawValue: reason.rawValue)!) }
            else { throw ProbeError("Qwen TP clean leave omitted its reason") }
        }
    }

    /// Failure has no success ACK. Failed native closes remain retained and
    /// charged for the enclosing worker's quarantine/process fence.
    func retireAll() throws {
        var failure: Error?
        for slot in records.keys.sorted() {
            guard let record = records[slot] else { continue }
            do {
                if let native = record.native {
                    try executor.retire(native, reason: nil, selected: record.tokens.count, last: record.tokens.last)
                    guard native.isClosed else { throw ProbeError("Qwen TP failed cleanup retained native history") }
                } else {
                    try executor.discard(record.reservation)
                }
                record.native = nil; book.finish(record.id); records[slot] = nil
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
