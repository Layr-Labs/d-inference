import DarkbloomClusterProtocol
import Foundation

/// Request state owned by a Independent-history batch lane. Native and CPU test executors
/// share the same lifecycle; the driver never owns arrays or sampling state.
protocol IndependentHistoryBatchSession: AnyObject {
    var nextFrame: QwenLayerStageFrame? { get }
    var committedTokens: Int { get }
    var isClosed: Bool { get }
    var isFailed: Bool { get }
    func finishGeneration(_ reason: QwenLayerStageGenerationFinishReason,
                          selectedTokenCount: Int, lastTokenID: Int) throws
    func cancel() throws
}

protocol IndependentHistoryBatchReservation: ClusterBatchLaneReservation {
    var request: QwenLayerStageGenerationRequest { get }
    var deadline: UInt64 { get }
}

/// Native execution and authenticated transport are separate from the lane
/// schedule. A deterministic CPU executor exercises this exact driver without
/// constructing a model or using a device. Only rank1 methods select tokens.
protocol IndependentHistoryBatchExecutor: AnyObject {
    associatedtype Session: IndependentHistoryBatchSession
    func open(lanes: Int) throws
    func session(_ request: QwenLayerStageGenerationRequest) throws -> Session
    func sendHeader(_ value: QwenBatchWire.Header) throws
    func receiveHeader(step: Int) throws -> QwenBatchWire.Header
    func sendReply(_ value: QwenBatchWire.Reply) throws
    func receiveReply(step: Int) throws -> QwenBatchWire.Reply
    func produceDecode(_ sessions: [Session], tokens: [Int], lanes: [QwenBatchRecordBinding.Lane], step: Int) throws
    func consumeDecode(_ sessions: [Session], requests: [QwenLayerStageGenerationRequest], tokens: [Int],
                       lanes: [QwenBatchRecordBinding.Lane], step: Int) throws -> [Int]
    func producePrefill(_ session: Session, request: QwenLayerStageGenerationRequest,
                        frame: QwenLayerStageFrame, lane: QwenBatchRecordBinding.Lane, step: Int) throws
    func consumePrefill(_ session: Session, request: QwenLayerStageGenerationRequest,
                        frame: QwenLayerStageFrame, lane: QwenBatchRecordBinding.Lane, step: Int) throws -> Int?
}

/// Plain pipeline batching: one prefill chunk and every ready decode lane per
/// step. Each announced transfer completes before either rank observes leave.
/// Token credits never block admission/control progress on the other rank.
final class IndependentHistoryBatchDriver<Executor: IndependentHistoryBatchExecutor, Reservation: IndependentHistoryBatchReservation> {
    private final class Lane {
        let id: UUID, slot: Int, order: Int
        let reserved: Reservation
        let session: Executor.Session
        var selected: [Int] = []
        init(slot: Int, order: Int, reserved: Reservation, session: Executor.Session) {
            id = reserved.request.requestID; self.slot = slot; self.order = order
            self.reserved = reserved; self.session = session
        }
        var record: QwenBatchRecordBinding.Lane {
            .init(slot: slot, requestID: id, requestFingerprint: reserved.request.fingerprint,
                  committedTokens: session.committedTokens, selectedTokens: selected.count)
        }
        var fingerprint: [Int32] { QwenBatchWire.fingerprintWords(reserved.request.fingerprint) }
        func finish(_ proceed: Bool) -> QwenLayerStageGenerationFinishReason? {
            guard let last = selected.last else { return nil }
            if reserved.request.stopTokenIDs.contains(last) { return .eos }
            if selected.count == reserved.request.outputCount { return .length }
            return proceed ? nil : .clientStop
        }
    }
    private let rank: Int, capacity: Int, vocabulary: Int
    private let book: ClusterBatchLaneBook<Reservation>
    private let executor: Executor
    private let now: () -> UInt64
    private var lanes: [Int: Lane] = [:]

    init(rank: Int, capacity: Int, vocabulary: Int, book: ClusterBatchLaneBook<Reservation>,
         executor: Executor, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        guard (0...1).contains(rank), (2...8).contains(capacity), vocabulary > 0 else {
            throw ProbeError("Independent-history batch driver has invalid rank, width or vocabulary")
        }
        self.rank = rank; self.capacity = capacity; self.vocabulary = vocabulary
        self.book = book; self.executor = executor; self.now = now
    }

    func serve(host: QwenBatchServingHost, check: () throws -> Void) throws {
        do {
            try executor.open(lanes: capacity)
            if rank == 0 { try lead(host: host, check: check) }
            else { try follow(host: host, check: check) }
        } catch {
            let primary = error
            do { try retireAll() }
            catch { throw ProbeError("\(primary); Independent-history batch cleanup failed (\(error))") }
            throw primary
        }
    }

    /// On a failed loop no successful lifecycle event is published. A failed
    /// session stays retained and charged for the enclosing worker's fence.
    func retireAll() throws {
        var failure: Error?
        for slot in lanes.keys.sorted() {
            guard let lane = lanes[slot] else { continue }
            do {
                try lane.session.cancel()
                guard lane.session.isClosed else { throw ProbeError("Independent-history batch cleanup retained native state") }
                book.finish(lane.id); lanes[slot] = nil
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    private func cancelled(_ lane: Lane) -> Bool {
        QwenBatchCancellation.requested(ownerCancelled: book.isCancelled(lane.id), deadline: lane.reserved.deadline, now: now())
    }
    private func leave(_ lane: Lane, reason: QwenLayerStageGenerationFinishReason?, host: QwenBatchServingHost) throws {
        if let reason {
            guard let last = lane.selected.last else { throw ProbeError("Independent-history clean finish has no token") }
            try lane.session.finishGeneration(reason, selectedTokenCount: lane.selected.count, lastTokenID: last)
            guard lane.session.isClosed, !lane.session.isFailed else {
                throw ProbeError("Independent-history batch clean retirement failed")
            }
        } else {
            try lane.session.cancel()
            guard lane.session.isClosed else { throw ProbeError("Independent-history batch cancellation retained native state") }
        }
        // Retirement must succeed before releasing the charge or publishing ACK.
        book.finish(lane.id)
        if let reason { try host.publishFinished(requestID: lane.id, reason: ClusterWorkerFinishReason(rawValue: reason.rawValue)!) }
        else { try host.publishLeft(requestID: lane.id) }
    }
    private func join(slot: Int, order: Int, reserved: Reservation) throws -> Lane {
        let session = try executor.session(reserved.request)
        let lane = Lane(slot: slot, order: order, reserved: reserved, session: session)
        lanes[slot] = lane
        return lane
    }

    private func lead(host: QwenBatchServingHost, check: () throws -> Void) throws {
        var step = 0, order = 0, decisions = QwenBatchDecisionProgress()
        var peerCancelled = Set<UUID>()
        while true {
            let stop = try autoreleasepool { () throws -> Bool in
                let answered = try decisions.serviceAndPoll(host)
                try check()
                var leaving: [Int: QwenBatchWire.Slot] = [:]
                for slot in lanes.keys.sorted() {
                    let lane = lanes[slot]!
                    let cancellation = cancelled(lane) || peerCancelled.contains(lane.id)
                    let reason = answered[lane.id].flatMap { lane.finish($0) }
                    if cancellation || reason != nil {
                        try leave(lane, reason: cancellation ? nil : reason, host: host)
                        decisions.retired(lane.id); peerCancelled.remove(lane.id)
                        leaving[slot] = .init(state: .leaving, requestID: lane.id, selectedTokens: lane.selected.count,
                            leaveReason: cancellation ? nil : reason, leaveCancelled: cancellation)
                        lanes[slot] = nil
                    }
                }
                var joining = Set<Int>()
                while lanes.count + leaving.count < capacity, let (_, reserved) = book.takeStarted() {
                    guard let slot = (0..<capacity).first(where: { lanes[$0] == nil && leaving[$0] == nil }) else {
                        throw ProbeError("Independent-history batch has no slot for its accepted start")
                    }
                    _ = try join(slot: slot, order: order, reserved: reserved)
                    order += 1; joining.insert(slot)
                }
                let decode = lanes.keys.sorted().filter {
                    let lane = lanes[$0]!
                    return lane.session.nextFrame?.phase == .decode && decisions.canForward(lane.id) && !cancelled(lane)
                }
                let prefill = lanes.values.filter {
                    $0.session.nextFrame?.phase == .prefill && decisions.canForward($0.id) && !cancelled($0)
                }.min { $0.order < $1.order }?.slot
                var slots = [QwenBatchWire.Slot](repeating: .init(), count: capacity)
                for (slot, value) in leaving { slots[slot] = value }
                for (slot, lane) in lanes {
                    var value = QwenBatchWire.Slot(state: joining.contains(slot) ? .joining : .active, requestID: lane.id)
                    value.committedTokens = lane.session.committedTokens; value.selectedTokens = lane.selected.count
                    value.fingerprintWords = lane.fingerprint
                    if decode.contains(slot) { value.role = .decode; value.inputToken = lane.selected.last ?? -1 }
                    else if slot == prefill, let frame = lane.session.nextFrame {
                        value.role = .prefill; value.frameOffset = frame.tokenOffset
                        value.frameCount = frame.tokenCount; value.finalChunk = frame.finalPromptChunk
                    }
                    slots[slot] = value
                }
                try executor.sendHeader(.init(step: step, stop: lanes.isEmpty, slots: slots))
                if lanes.isEmpty { return true }
                if !decode.isEmpty {
                    try executor.produceDecode(decode.map { lanes[$0]!.session },
                        tokens: decode.map { lanes[$0]!.selected.last! }, lanes: decode.map { lanes[$0]!.record }, step: step)
                }
                var finalPrefill = false
                if let slot = prefill, let lane = lanes[slot], let frame = lane.session.nextFrame {
                    try executor.producePrefill(lane.session, request: lane.reserved.request, frame: frame, lane: lane.record, step: step)
                    finalPrefill = frame.finalPromptChunk
                }
                let reply = try executor.receiveReply(step: step)
                peerCancelled.formUnion(try QwenBatchCancellation.peerRequests(mask: reply.cancelledMask, slots: slots))
                guard reply.restored.allSatisfy({ $0 == 0 }) else { throw ProbeError("Independent-history batch has no prefix restoration") }
                for slot in 0..<capacity {
                    let expected = decode.contains(slot) || (slot == prefill && finalPrefill)
                    guard (reply.tokens[slot] >= 0) == expected else { throw ProbeError("Independent-history batch reply differs from the announced frames") }
                    guard expected, let lane = lanes[slot] else { continue }
                    let token = reply.tokens[slot]
                    guard (0..<vocabulary).contains(token) else { throw ProbeError("Independent-history batch selected token is outside vocabulary") }
                    lane.selected.append(token); try check()
                    if cancelled(lane) || peerCancelled.contains(lane.id) { continue }
                    try decisions.published(lane.id)
                    try host.publishToken(requestID: lane.id, ordinal: lane.selected.count - 1, tokenID: token,
                        committedTokens: lane.reserved.request.promptCount + lane.selected.count - 1)
                }
                if decode.isEmpty && prefill == nil && joining.isEmpty { Thread.sleep(forTimeInterval: 0.0005) }
                return false
            }
            if stop { return }
            step += 1
        }
    }

    private func follow(host: QwenBatchServingHost, check: () throws -> Void) throws {
        var step = 0, order = 0
        while true {
            let stop = try autoreleasepool { () throws -> Bool in
                let header = try executor.receiveHeader(step: step)
                for (slot, value) in header.slots.enumerated() where value.state == .leaving {
                    guard let lane = lanes[slot], lane.id == value.requestID,
                          lane.selected.count == value.selectedTokens else {
                        throw ProbeError("Independent-history batch leave differs from this rank's lane")
                    }
                    if value.leaveCancelled || cancelled(lane) {
                        try leave(lane, reason: nil, host: host)
                    } else {
                        guard let reason = value.leaveReason, lane.finish(reason != .clientStop) == reason else {
                            throw ProbeError("Independent-history batch leave reason differs from its committed tokens")
                        }
                        try leave(lane, reason: reason, host: host)
                    }
                    lanes[slot] = nil
                }
                for value in header.slots {
                    guard !value.confirming, value.reusedPrefix == 0, value.offers.isEmpty else {
                        throw ProbeError("Independent-history batch does not negotiate prefix restoration")
                    }
                }
                for (slot, value) in header.slots.enumerated() where value.state == .joining {
                    guard lanes[slot] == nil, let id = value.requestID else {
                        throw ProbeError("Independent-history batch join names an occupied slot")
                    }
                    // An accepted cancellation still joins its exact identity;
                    // only the following common leave step may acknowledge it.
                    while !book.isStarted(id) {
                        try host.serviceControl(); try check()
                        if !book.isStarted(id) { Thread.sleep(forTimeInterval: 0.0005) }
                    }
                    guard let reserved = book.takeStarted(id) else { throw ProbeError("Independent-history accepted batch start vanished") }
                    let lane = try join(slot: slot, order: order, reserved: reserved)
                    order += 1
                    guard lane.fingerprint == value.fingerprintWords else {
                        throw ProbeError("Independent-history batch request differs between the owners")
                    }
                }
                for (slot, value) in header.slots.enumerated() {
                    switch value.state {
                    case .empty, .leaving:
                        guard lanes[slot] == nil else { throw ProbeError("Independent-history batch header omits a held lane") }
                    case .joining, .active:
                        guard let lane = lanes[slot], lane.id == value.requestID,
                              lane.fingerprint == value.fingerprintWords,
                              lane.session.committedTokens == value.committedTokens,
                              lane.selected.count == value.selectedTokens else {
                            throw ProbeError("Independent-history batch header differs in identity or frontier")
                        }
                    }
                }
                if header.stop {
                    guard lanes.isEmpty else { throw ProbeError("Independent-history batch stop retains native lanes") }
                    return true
                }
                try host.serviceControl(); try check()
                var tokens = [Int](repeating: -1, count: capacity)
                let decode = header.slots.indices.filter { header.slots[$0].role == .decode }
                if !decode.isEmpty {
                    for slot in decode {
                        guard let lane = lanes[slot], lane.session.nextFrame?.phase == .decode,
                              header.slots[slot].inputToken == lane.selected.last else {
                            throw ProbeError("Independent-history batch decode differs from its own committed history")
                        }
                    }
                    let selected = try executor.consumeDecode(decode.map { lanes[$0]!.session },
                        requests: decode.map { lanes[$0]!.reserved.request }, tokens: decode.map { lanes[$0]!.selected.last! },
                        lanes: decode.map { lanes[$0]!.record }, step: step)
                    guard selected.count == decode.count, selected.allSatisfy({ (0..<vocabulary).contains($0) }) else {
                        throw ProbeError("Independent-history batch decode selection differs from its rows")
                    }
                    for (row, slot) in decode.enumerated() {
                        tokens[slot] = selected[row]; lanes[slot]!.selected.append(selected[row])
                    }
                }
                if let slot = header.slots.firstIndex(where: { $0.role == .prefill }) {
                    let value = header.slots[slot]
                    guard let lane = lanes[slot], let frame = lane.session.nextFrame,
                          frame.phase == .prefill, frame.tokenOffset == value.frameOffset,
                          frame.tokenCount == value.frameCount, frame.finalPromptChunk == value.finalChunk else {
                        throw ProbeError("Independent-history batch prefill differs from its own chunk grid")
                    }
                    let token = try executor.consumePrefill(lane.session, request: lane.reserved.request,
                        frame: frame, lane: lane.record, step: step)
                    guard (token != nil) == frame.finalPromptChunk else {
                        throw ProbeError("Independent-history batch prefill selection differs from its final-chunk contract")
                    }
                    if let token {
                        guard (0..<vocabulary).contains(token) else { throw ProbeError("Independent-history prefill token is outside vocabulary") }
                        tokens[slot] = token; lane.selected.append(token)
                    }
                }
                try host.serviceControl()
                let mask = lanes.values.reduce(0) { $0 | (cancelled($1) ? 1 << $1.slot : 0) }
                try executor.sendReply(.init(step: step, tokens: tokens,
                    restored: [Int](repeating: 0, count: capacity), cancelledMask: mask))
                return false
            }
            if stop { return }
            step += 1
        }
    }
}
