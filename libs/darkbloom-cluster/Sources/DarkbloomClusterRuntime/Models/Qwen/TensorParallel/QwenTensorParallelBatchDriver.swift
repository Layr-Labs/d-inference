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
    var canSelectNext: Bool { get }
    /// The lane's decode selects through the plain selection sum (no
    /// assistant round or accepted queue), which can carry control words.
    var plainSelection: Bool { get }
    func promptStep(frames: Int) -> QwenLayerStageFrame?
    func promptStep(tokens: Int) -> QwenLayerStageFrame?
}

extension QwenTensorParallelBatchLane {
    var reusedPrefixTokens: Int { 0 }
    var storedPrefixFrontiers: [Int] { [] }
    var canSelectNext: Bool { nextFrame?.phase == .decode }
    var plainSelection: Bool { true }
    /// The prompt step of up to `frames` consecutive frames (`QwenTensorParallelPromptWavefront`).
    func promptStep(frames: Int) -> QwenLayerStageFrame? { nextFrame }
    /// The planned prompt step of `tokens`, if it is one this lane may run.
    func promptStep(tokens: Int) -> QwenLayerStageFrame? { nextFrame.flatMap { $0.tokenCount == tokens ? $0 : nil } }
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
    /// Whether this executor's selection sum can carry control words; the
    /// driver folds only for one that can.
    var carriesSelectionControl: Bool { get }
    /// One decode rectangle whose selection sum carries no control words.
    func decode(_ lanes: [Lane], tokens: [Int], check: () throws -> Void) throws -> [Int]
    /// One decode rectangle. `control` runs once the forward committed and
    /// before selection; words it returns (plain lanes only) ride the
    /// selection's sealed sum, and both ranks' summed words come back.
    func decode(_ lanes: [Lane], tokens: [Int], control: () throws -> [Float]?,
                check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?)
    func retire(_ lane: Lane, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws
    func takeLogprobs(_ lane: Lane) throws -> ClusterWorkerTokenLogprobs?
    func confirmedRetirement(_ lane: Lane, clean: Bool) throws
    /// A submitted, unread plain decode rectangle (build-ahead).
    associatedtype Submitted = Void
    /// Whether this executor can submit a plain decode rectangle without
    /// reading it (`submitDecode`, `readDecode`), so the driver may build the
    /// next step before it reads this one (`QwenTensorParallelBatchDriver`'s
    /// build-ahead, load-agreed).
    var buildsAhead: Bool { get }
    /// Submits one plain decode rectangle (its forward, its selection and the
    /// selection sum carrying the words `control` returns, called once the
    /// forward committed, as `decode`'s) and returns without reading it.
    /// `inputs`: the host's tokens, or rows of the previous submitted
    /// rectangle's selection, which may still be unread.
    func submitDecode(_ lanes: [Lane], inputs: QwenBatchDecodeInputs<Submitted>, control: () throws -> [Float],
                      check: () throws -> Void) throws -> Submitted
    /// Reads a submitted rectangle: one token a lane and both ranks' summed control words.
    func readDecode(_ submitted: Submitted, check: () throws -> Void) throws -> (tokens: [Int], control: [Float])
}

/// A submitted decode rectangle's input tokens: held on the host, or rows of
/// the previous submitted rectangle's selection (not yet read).
enum QwenBatchDecodeInputs<Submitted> {
    case tokens([Int])
    case after(Submitted, rows: [Int])
}

extension QwenTensorParallelBatchExecutor {
    var carriesSelectionControl: Bool { false }
    func confirmedRetirement(_ lane: Lane, clean: Bool) throws {}
    var buildsAhead: Bool { false }
    func submitDecode(_ lanes: [Lane], inputs: QwenBatchDecodeInputs<Submitted>, control: () throws -> [Float],
                      check: () throws -> Void) throws -> Submitted {
        throw ProbeError("This TP executor does not build decode steps ahead")
    }
    func readDecode(_ submitted: Submitted, check: () throws -> Void) throws -> (tokens: [Int], control: [Float]) {
        throw ProbeError("This TP executor does not build decode steps ahead")
    }

    /// An executor whose selection sum carries no control words: the driver
    /// never folds for it, so `control` is always empty.
    func decode(_ lanes: [Lane], tokens: [Int], control: () throws -> [Float]?,
                check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?) {
        let selected = try decode(lanes, tokens: tokens, check: check)
        guard try control() == nil else { throw ProbeError("This TP executor's selection sum carries no control words") }
        return (selected, nil)
    }
}

/// One prompt step (consecutive frames on the original grid) and one real decode rectangle per
/// step. Every active request owns its native history. A slow client holds
/// only its own token credit. Successful retirement is published only after
/// both ranks have drained, including cancellation and deadline departures.
///
/// A step whose decode rectangle is plain and runs no prompt folds the next
/// step's plan and report into its selection sum: one sealed sum and one host
/// read a step. That plan is made before the step's tokens are known, so
/// host events (answers, credits, cancellations, joins) apply one step later,
/// and both ranks drop a carried decode whose token ended its request (EOS or
/// length). Rank 0 publishes a token only once the owner answered the one
/// before it; a token selected before a stop answer is never published.
final class QwenTensorParallelBatchDriver<Executor: QwenTensorParallelBatchExecutor> {
    typealias Reservation = Executor.Reservation
    private final class Record {
        let reservation: Reservation
        let slot: Int, order: Int
        var native: Executor.Lane?
        var tokens: [Int] = []
        /// Rank 0: tokens published, the logprobs of each selected token not yet
        /// published (in order; one at most unless steps are built ahead), and
        /// whether a leave was planned (nothing more is published).
        var published = 0
        var heldLogprobs: [ClusterWorkerTokenLogprobs?] = []
        var leaving = false
        var id: UUID { reservation.request.requestID }
        var fingerprint: [Int32] { QwenBatchWire.fingerprintWords(reservation.request.fingerprint) }
        init(_ reservation: Reservation, slot: Int, order: Int) {
            self.reservation = reservation; self.slot = slot; self.order = order
        }
        /// How the request ends at its first `count` tokens, given the owner's answer to the last.
        func finish(_ proceed: Bool, count: Int) -> QwenLayerStageGenerationFinishReason? {
            guard count >= 1, count <= tokens.count else { return nil }
            if reservation.request.stopTokenIDs.contains(tokens[count - 1]) { return .eos }
            if count == reservation.request.outputCount { return .length }
            return proceed ? nil : .clientStop
        }
        /// Its last token ends the request: no further forward.
        var ended: Bool { finish(true, count: tokens.count) != nil }
    }
    private let executor: Executor
    private let book: ClusterBatchLaneBook<Reservation>
    private let capacity: Int, vocabulary: Int
    private let now: () -> UInt64
    private let joinWaitNanoseconds: UInt64
    private var records: [Int: Record] = [:]
    private var order = 0
    /// Folds the next step's control into plain selection sums. Off only to
    /// measure the exchange a step (`QwenTensorParallelDecodeBench`); both ranks must agree.
    private let foldsControl: Bool
    /// Builds a plain decode step before reading the one before it when both
    /// ranks agreed a continuation (`serveAhead`). Load-agreed
    /// (`QwenTensorParallelBatchSettings.buildsAhead`): both ranks must agree.
    private let buildsAhead: Bool
    /// Rank 0 under build-ahead: owner answers read while deciding a
    /// continuation whose effect needs a plan (a stop, or the answer to an
    /// ending token), kept for the next plan.
    private var deferredAnswers: [UUID: Bool] = [:]
    /// Selected tokens a lane may hold unpublished under build-ahead (one without it).
    static var aheadHeldLimit: Int { 4 }
    /// D6: this rank's live memory check at a step boundary (true: it
    /// refused), set for one `serve`. A refusal stops the newest running lane
    /// alone; no new check runs while a stopped lane has yet to leave.
    private var memoryRefused: () throws -> Bool = { false }
    /// Rank 0: lanes a rank's memory stopped, each leaving with its abort once it owes no answer.
    private var memoryStopped: [Int: ClusterWorkerAbort] = [:]
    /// Rank 1: the lane its refusal names in its next report, and lanes named until they leave.
    private var pendingMemorySlot: Int?
    private var reportedMemory = Set<Int>()

    init(executor: Executor, book: ClusterBatchLaneBook<Reservation>, capacity: Int, vocabulary: Int,
         joinWaitNanoseconds: UInt64 = 30_000_000_000, foldsControl: Bool = true, buildsAhead: Bool = false,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        guard (0...1).contains(executor.rank), (1...8).contains(capacity), vocabulary > 0,
              joinWaitNanoseconds > 0 else { throw ProbeError("Qwen TP batch driver has invalid geometry") }
        guard !buildsAhead || (executor.buildsAhead && executor.carriesSelectionControl && foldsControl) else {
            throw ProbeError("Qwen TP build-ahead needs an executor that submits decode steps and folds control")
        }
        self.executor = executor; self.book = book; self.capacity = capacity; self.vocabulary = vocabulary
        self.joinWaitNanoseconds = joinWaitNanoseconds; self.foldsControl = foldsControl
        self.buildsAhead = buildsAhead; self.now = now
    }

    private func cancelled(_ record: Record) -> Bool {
        book.isCancelled(record.id) || now() >= record.reservation.deadline
    }

    /// `retiredSelection` receives each clean, bilaterally retired selection
    /// for this call only; a retained failed driver keeps no host callback.
    func serve(host: QwenBatchServingHost,
               retiredSelection: (UUID, [Int], QwenLayerStageGenerationFinishReason) throws -> Void = { _, _, _ in },
               memoryRefused: @escaping () throws -> Bool = { false },
               check: () throws -> Void) throws {
        self.memoryRefused = memoryRefused
        defer { self.memoryRefused = { false } }
        if buildsAhead { return try serveAhead(host: host, retiredSelection: retiredSelection, check: check) }
        var step = 0
        var decisions = QwenBatchDecisionProgress()
        var coalescing = QwenBatchDecodeCoalescing()
        var peerCancelled = Set<Int>()
        /// This step's plan and report, when they rode the last step's selection sum.
        var carried: (plan: QwenBatchWire.Header, peer: QwenBatchWire.Reply)?
        do {
            while true {
                let stop = try autoreleasepool { () throws -> Bool in
                    let plan: QwenBatchWire.Header, peer: QwenBatchWire.Reply
                    let wasCarried = carried != nil
                    if let folded = carried {
                        (plan, peer) = folded; carried = nil
                        if executor.rank == 1 { try host.serviceControl() }
                        try check()
                    } else {
                        let answers = executor.rank == 0 ? try decisions.serviceAndPoll(host) : [:]
                        if executor.rank == 1 { try host.serviceControl() }
                        try check()
                        let localPlan = executor.rank == 0
                            ? try makePlan(step: step, answers: answers, decisions: &decisions, host: host,
                                           peerCancelled: peerCancelled, coalescing: &coalescing) : nil
                        let localReport = executor.rank == 1 ? try report(step: step) : nil
                        let sum = try executor.exchange(QwenTensorParallelBatchWire.contribution(
                            rank: executor.rank, plan: localPlan, report: localReport), check: check)
                        (plan, peer) = try Self.read(sum, step: step, lanes: capacity, plan: localPlan, report: localReport)
                    }
                    try validate(plan, peer: peer)
                    peerCancelled = Set((0..<capacity).filter { peer.cancelledMask & (1 << $0) != 0 })
                    noteMemoryMask(peer.memoryMask)
                    if plan.stop { return true }
                    try leave(plan, host: host, decisions: &decisions, retiredSelection: retiredSelection, check: check)
                    try join(plan, host: host, check: check)
                    let decode = plan.slots.indices.filter { plan.slots[$0].role == .decode }
                    let prompts = plan.slots.indices.filter { plan.slots[$0].role == .prefill }
                    guard prompts.count <= 1 else { throw ProbeError("Qwen TP plan has multiple prefill frames") }
                    if !decode.isEmpty {
                        let lanes = try decode.map { slot -> Record in
                            guard let record = records[slot], let native = record.native,
                                  native.canSelectNext, record.tokens.last == plan.slots[slot].inputToken else {
                                throw ProbeError("Qwen TP decode differs from its request history")
                            }
                            return record
                        }
                        // A plain rectangle with no prompt after it carries the next step's
                        // plan and report, made once its forward committed (agreed state only).
                        let folds = foldsControl && executor.carriesSelectionControl && prompts.isEmpty
                            && lanes.allSatisfy { $0.native!.plainSelection }
                        let carrying = Set(decode)
                        var nextPlan: QwenBatchWire.Header?, nextReport: QwenBatchWire.Reply?
                        let result = try executor.decode(lanes.map { $0.native! }, tokens: lanes.map { $0.tokens.last! },
                            control: { [self] () throws -> [Float]? in
                                guard folds else { return nil }
                                if executor.rank == 0 {
                                    let answers = try decisions.serviceAndPoll(host)
                                    try check()
                                    nextPlan = try makePlan(step: step + 1, answers: answers, decisions: &decisions, host: host,
                                        peerCancelled: peerCancelled, coalescing: &coalescing, carrying: carrying)
                                } else {
                                    try host.serviceControl(); try check()
                                    nextReport = try report(step: step + 1, carrying: carrying)
                                }
                                return try QwenTensorParallelBatchWire.contribution(rank: executor.rank, plan: nextPlan, report: nextReport)
                            }, check: { try check(); try host.serviceControl() })
                        guard result.tokens.count == lanes.count, (result.control != nil) == folds else {
                            throw ProbeError("Qwen TP decode omitted a lane or its control words")
                        }
                        for (lane, token) in zip(lanes, result.tokens) {
                            try selected(token, lane: lane, decisions: &decisions, host: host, peerCancelled: peerCancelled)
                        }
                        if let words = result.control {
                            let (next, nextPeer) = try Self.read(words, step: step + 1, lanes: capacity, plan: nextPlan, report: nextReport)
                            carried = (try resolve(next, carrying: carrying), nextPeer)
                        }
                    }
                    if let slot = prompts.first {
                        let value = plan.slots[slot]
                        guard let lane = records[slot], let native = lane.native, let frame = native.promptStep(tokens: value.frameCount),
                              frame.phase == .prefill, frame.tokenOffset == value.frameOffset,
                              frame.tokenCount == value.frameCount, frame.finalPromptChunk == value.finalChunk else {
                            throw ProbeError("Qwen TP prefill differs from its original chunk grid")
                        }
                        let token = try executor.prefill(native, frame: frame, check: { try check(); try host.serviceControl() })
                        guard (token != nil) == frame.finalPromptChunk else { throw ProbeError("Qwen TP prefill returned the wrong final-row kind") }
                        if let token { try selected(token, lane: lane, decisions: &decisions, host: host, peerCancelled: peerCancelled) }
                    }
                    // A carried plan whose decodes ended is idle only by the tokens just read;
                    // the next step exchanges at once.
                    if !wasCarried, decode.isEmpty, prompts.isEmpty,
                       plan.slots.allSatisfy({ $0.state == .active || $0.state == .empty }) {
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

    // MARK: - Build-ahead

    /// A plain decode rectangle submitted and not yet read (build-ahead).
    private struct Pending {
        let step: Int
        /// Its decode slots, in row order.
        let slots: [Int]
        let handle: Executor.Submitted
        /// Its control words lead with plan(step + 1) and rank 1's report
        /// (`QwenTensorParallelBatchWire.contribution`), then the decision words.
        let planWords: Int
        let localPlan: QwenBatchWire.Header?, localReport: QwenBatchWire.Reply?
        let localDecision: [Float]
    }

    /// Words a build-ahead step's selection sum carries after any plan: each
    /// rank's barrier flag (0 or 1) in its own slot.
    static var decisionWordCount: Int { 2 }

    /// This rank's decision words for the step two after the one being built:
    /// may that step be built before the step before it is read, as a
    /// continuation of the same lanes? A rank asks for a barrier (1) whenever
    /// anything needs a plan: an owner's stop or the answer to an ending token
    /// (rank 0; kept for that plan), a request waiting to join, an idle lane,
    /// a cancellation or deadline, an ended lane, a lane that would pass its
    /// output count, or (rank 0) more unpublished tokens than
    /// `aheadHeldLimit`. `inFlight`: each submitted, unread step's slots,
    /// counting the step being built.
    private func decision(inFlight: [Int: Int], host: QwenBatchServingHost, decisions: inout QwenBatchDecisionProgress,
                          peerCancelled: Set<Int>, check: () throws -> Void) throws -> [Float] {
        var barrier = false
        if executor.rank == 0 {
            let answers = try decisions.serviceAndPoll(host)
            try check()
            for (id, proceed) in answers.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let record = records.values.first(where: { $0.id == id }) else { continue }
                if proceed, record.finish(true, count: record.published) == nil {
                    try publishHeld(record, decisions: &decisions, host: host, peerCancelled: peerCancelled)
                } else {
                    // The next plan leaves this lane (a stop, or its last token answered):
                    // nothing more is published meanwhile.
                    deferredAnswers[id] = proceed; record.leaving = true; barrier = true
                }
            }
            if !deferredAnswers.isEmpty || book.hasStarted { barrier = true }
        } else {
            try host.serviceControl(); try check()
        }
        for (slot, record) in records {
            guard let native = record.native, let flight = inFlight[slot] else { barrier = true; continue }
            // Selected once every submitted step is read, the next step and the decided one too.
            let selected = record.tokens.count + flight + 2
            if cancelled(record) || peerCancelled.contains(slot) || memoryStopped[slot] != nil || pendingMemorySlot != nil
                || record.ended || !native.canSelectNext || !native.plainSelection
                || selected > record.reservation.request.outputCount
                || (executor.rank == 0 && selected - record.published > Self.aheadHeldLimit) {
                barrier = true
            }
        }
        // This rank's memory: a stopped lane needs a plan (rank 0) or a report (rank 1).
        if try pollMemory(peerCancelled: peerCancelled) { barrier = true }
        var words = [Float](repeating: 0, count: Self.decisionWordCount)
        words[executor.rank] = barrier ? 1 : 0
        return words
    }

    /// Owner answers for the next plan: those a build-ahead decision kept, then the ones polled now.
    private func answers(_ decisions: inout QwenBatchDecisionProgress, host: QwenBatchServingHost) throws -> [UUID: Bool] {
        let polled = try decisions.serviceAndPoll(host)
        defer { deferredAnswers = [:] }
        return deferredAnswers.merging(polled) { kept, _ in kept }
    }

    /// `serve` with build-ahead. Each plain folded decode step's selection
    /// sum also carries both ranks' decision words for the step two later:
    /// with neither rank asking for a barrier, and that step's predecessor
    /// decoding the same lanes, both ranks build it on the predecessor's
    /// unread selection before reading the predecessor, so the GPU runs it
    /// while the host reads, publishes and answers. Anything else (an owner's
    /// stop, a join, a prompt, a leave, a cancellation, an ended lane, a width
    /// change) is a barrier: both ranks read every submitted step and the next
    /// plan is made and exchanged with nothing in flight, as in `serve`.
    /// Every input to these choices is agreed (read sums, read tokens, plan
    /// contents), so both ranks submit the same collectives in the same order.
    /// A lane that ends on a token read after its next step was built keeps
    /// that step's forward discarded; its token is never selected or published.
    private func serveAhead(host: QwenBatchServingHost,
                            retiredSelection: (UUID, [Int], QwenLayerStageGenerationFinishReason) throws -> Void,
                            check: () throws -> Void) throws {
        var step = 0
        var decisions = QwenBatchDecisionProgress()
        var coalescing = QwenBatchDecodeCoalescing()
        var peerCancelled = Set<Int>()
        var carried: (plan: QwenBatchWire.Header, peer: QwenBatchWire.Reply)?
        /// Steps whose decision words were read, and the slots a "build ahead" decision covers.
        var decided: [Int: Set<Int>?] = [:]
        var pending: Pending?
        func laneCheck() throws { try check(); try host.serviceControl() }
        func read(_ submitted: Pending) throws {
            let result = try executor.readDecode(submitted.handle, check: laneCheck)
            guard result.tokens.count == submitted.slots.count,
                  result.control.count == submitted.planWords + Self.decisionWordCount else {
                throw ProbeError("Qwen TP build-ahead step omitted a lane or its control words")
            }
            for (slot, token) in zip(submitted.slots, result.tokens) {
                guard let record = records[slot] else { throw ProbeError("Qwen TP build-ahead row has no lane") }
                // Built ahead past its end: the forward is discarded, the token never selected.
                if record.ended { continue }
                try selected(token, lane: record, decisions: &decisions, host: host, peerCancelled: peerCancelled)
            }
            let words = Array(result.control.suffix(Self.decisionWordCount))
            guard words.allSatisfy({ $0 == 0 || $0 == 1 }), words[executor.rank] == submitted.localDecision[executor.rank] else {
                throw ProbeError("Qwen TP build-ahead decision changed in transit")
            }
            decided[submitted.step + 2] = words.contains(1) ? .some(nil) : Set(submitted.slots)
            if submitted.planWords > 0 {
                let (next, nextPeer) = try Self.read(Array(result.control.prefix(submitted.planWords)), step: submitted.step + 1,
                    lanes: capacity, plan: submitted.localPlan, report: submitted.localReport)
                carried = (try resolve(next, carrying: Set(submitted.slots)), nextPeer)
            }
        }
        do {
            while true {
                let stop = try autoreleasepool { () throws -> Bool in
                    // A decided continuation: build this step on the unread one's selection, then read that one.
                    if let previous = pending, case .some(.some(let covered)) = decided[step], covered == Set(previous.slots),
                       previous.slots.allSatisfy({ records[$0]?.native != nil && records[$0]?.ended == false }) {
                        decided[step] = nil
                        let lanes = previous.slots.map { records[$0]! }
                        var words: [Float] = []
                        let handle = try executor.submitDecode(lanes.map { $0.native! },
                            inputs: .after(previous.handle, rows: Array(previous.slots.indices)), control: {
                                words = try decision(inFlight: Dictionary(uniqueKeysWithValues: previous.slots.map { ($0, 2) }),
                                                     host: host, decisions: &decisions, peerCancelled: peerCancelled, check: check)
                                return words
                            }, check: laneCheck)
                        let next = Pending(step: step, slots: previous.slots, handle: handle, planWords: 0,
                                           localPlan: nil, localReport: nil, localDecision: words)
                        // `next` is the step a failure must drain: it depends on `previous`, so draining it
                        // completes both, and `previous` is never read twice.
                        pending = next
                        try read(previous)
                        return false
                    }
                    if let previous = pending { pending = nil; try read(previous) }
                    decided[step] = nil
                    decided = decided.filter { $0.key > step }
                    let plan: QwenBatchWire.Header, peer: QwenBatchWire.Reply
                    let wasCarried = carried != nil
                    if let folded = carried {
                        (plan, peer) = folded; carried = nil
                        if executor.rank == 1 { try host.serviceControl() }
                        try check()
                    } else {
                        let polled = executor.rank == 0 ? try answers(&decisions, host: host) : [:]
                        if executor.rank == 1 { try host.serviceControl() }
                        try check()
                        let localPlan = executor.rank == 0
                            ? try makePlan(step: step, answers: polled, decisions: &decisions, host: host,
                                           peerCancelled: peerCancelled, coalescing: &coalescing) : nil
                        let localReport = executor.rank == 1 ? try report(step: step) : nil
                        let sum = try executor.exchange(QwenTensorParallelBatchWire.contribution(
                            rank: executor.rank, plan: localPlan, report: localReport), check: check)
                        (plan, peer) = try Self.read(sum, step: step, lanes: capacity, plan: localPlan, report: localReport)
                    }
                    try validate(plan, peer: peer)
                    peerCancelled = Set((0..<capacity).filter { peer.cancelledMask & (1 << $0) != 0 })
                    noteMemoryMask(peer.memoryMask)
                    if plan.stop { return true }
                    try leave(plan, host: host, decisions: &decisions, retiredSelection: retiredSelection, check: check)
                    try join(plan, host: host, check: check)
                    let decode = plan.slots.indices.filter { plan.slots[$0].role == .decode }
                    let prompts = plan.slots.indices.filter { plan.slots[$0].role == .prefill }
                    guard prompts.count <= 1 else { throw ProbeError("Qwen TP plan has multiple prefill frames") }
                    if !decode.isEmpty {
                        let lanes = try decode.map { slot -> Record in
                            guard let record = records[slot], let native = record.native,
                                  native.canSelectNext, record.tokens.last == plan.slots[slot].inputToken else {
                                throw ProbeError("Qwen TP decode differs from its request history")
                            }
                            return record
                        }
                        let folds = executor.carriesSelectionControl && prompts.isEmpty
                            && lanes.allSatisfy { $0.native!.plainSelection }
                        if folds {
                            // The successor's plan rides this sum unless a continuation was already
                            // decided for it (after a barrier the plan rides, so no exchange follows).
                            let carriesPlan: Bool
                            if case .some(.some) = decided[step + 1] { carriesPlan = false } else { carriesPlan = true }
                            let carrying = Set(decode)
                            var nextPlan: QwenBatchWire.Header?, nextReport: QwenBatchWire.Reply?
                            var planWords = 0, decisionWords: [Float] = []
                            let handle = try executor.submitDecode(lanes.map { $0.native! },
                                inputs: .tokens(lanes.map { $0.tokens.last! }), control: { [self] () throws -> [Float] in
                                    var words: [Float] = []
                                    if carriesPlan {
                                        if executor.rank == 0 {
                                            let polled = try answers(&decisions, host: host)
                                            try check()
                                            nextPlan = try makePlan(step: step + 1, answers: polled, decisions: &decisions, host: host,
                                                peerCancelled: peerCancelled, coalescing: &coalescing, carrying: carrying)
                                        } else {
                                            try host.serviceControl(); try check()
                                            nextReport = try report(step: step + 1, carrying: carrying)
                                        }
                                        words = try QwenTensorParallelBatchWire.contribution(rank: executor.rank, plan: nextPlan, report: nextReport)
                                    }
                                    planWords = words.count
                                    decisionWords = try decision(inFlight: Dictionary(uniqueKeysWithValues: decode.map { ($0, 1) }),
                                                                 host: host, decisions: &decisions, peerCancelled: peerCancelled, check: check)
                                    return words + decisionWords
                                }, check: laneCheck)
                            pending = Pending(step: step, slots: decode, handle: handle, planWords: planWords,
                                              localPlan: nextPlan, localReport: nextReport, localDecision: decisionWords)
                        } else {
                            let result = try executor.decode(lanes.map { $0.native! }, tokens: lanes.map { $0.tokens.last! },
                                control: { nil }, check: laneCheck)
                            guard result.tokens.count == lanes.count, result.control == nil else {
                                throw ProbeError("Qwen TP decode omitted a lane or carried control words")
                            }
                            for (lane, token) in zip(lanes, result.tokens) {
                                try selected(token, lane: lane, decisions: &decisions, host: host, peerCancelled: peerCancelled)
                            }
                        }
                    }
                    if let slot = prompts.first {
                        let value = plan.slots[slot]
                        guard let lane = records[slot], let native = lane.native, let frame = native.promptStep(tokens: value.frameCount),
                              frame.phase == .prefill, frame.tokenOffset == value.frameOffset,
                              frame.tokenCount == value.frameCount, frame.finalPromptChunk == value.finalChunk else {
                            throw ProbeError("Qwen TP prefill differs from its original chunk grid")
                        }
                        let token = try executor.prefill(native, frame: frame, check: laneCheck)
                        guard (token != nil) == frame.finalPromptChunk else { throw ProbeError("Qwen TP prefill returned the wrong final-row kind") }
                        if let token { try selected(token, lane: lane, decisions: &decisions, host: host, peerCancelled: peerCancelled) }
                    }
                    if !wasCarried, decode.isEmpty, prompts.isEmpty,
                       plan.slots.allSatisfy({ $0.state == .active || $0.state == .empty }) {
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                    return false
                }
                if stop { return }
                step += 1
            }
        } catch {
            let primary = error
            // A submitted step is drained before its lanes retire: its read may fail as well (the
            // primary error stands), and no token of it is selected.
            if let submitted = pending { pending = nil; _ = try? executor.readDecode(submitted.handle, check: {}) }
            do { try retireAll() }
            catch { throw ProbeError("\(primary); Qwen TP batch cleanup failed (\(error))") }
            throw primary
        }
    }

    /// Rank 0's plan for `step`. `carrying`: rows decoding in the step whose
    /// selection sum carries this plan. Each counts the token it is selecting
    /// and decodes on it (`carriedToken`) only if the owner already answered
    /// the token before it; a stop keeps the tokens the owner saw.
    private func makePlan(step: Int, answers: [UUID: Bool], decisions: inout QwenBatchDecisionProgress,
                          host: QwenBatchServingHost, peerCancelled: Set<Int>,
                          coalescing: inout QwenBatchDecodeCoalescing, carrying: Set<Int> = []) throws -> QwenBatchWire.Header {
        _ = try pollMemory(peerCancelled: peerCancelled)
        var slots = [QwenBatchWire.Slot](repeating: .init(), count: capacity)
        for (slot, record) in records {
            let selecting = carrying.contains(slot)
            var value = QwenBatchWire.Slot(state: .active, requestID: record.id)
            value.committedTokens = record.native?.committedTokens ?? 0
            value.selectedTokens = record.tokens.count + (selecting ? 1 : 0); value.fingerprintWords = record.fingerprint
            // An answer is to the last published token.
            let reason = answers[record.id].flatMap { record.finish($0, count: record.published) }
            if cancelled(record) || peerCancelled.contains(slot) || reason != nil {
                value.state = .leaving; value.leaveCancelled = cancelled(record) || peerCancelled.contains(slot)
                value.leaveReason = value.leaveCancelled ? nil : reason
                if !value.leaveCancelled { value.selectedTokens = record.published }
                record.leaving = true
            } else if let abort = memoryStopped[slot], decisions.canForward(record.id) {
                // It owes the owner no answer: both ranks end it alone (D6).
                value.state = .leaving; value.leaveAborted = abort
                record.leaving = true
            } else {
                if answers[record.id] == true {
                    try publishHeld(record, decisions: &decisions, host: host, peerCancelled: peerCancelled)
                }
                if record.native?.canSelectNext == true, record.published == record.tokens.count,
                   decisions.canForward(record.id) {
                    value.role = .decode
                    value.inputToken = selecting ? QwenTensorParallelBatchWire.carriedToken : record.tokens.last ?? -1
                }
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
        }).min(by: { $0.order < $1.order }), let frame = prompt.native?.promptStep(frames:
            records.values.contains { $0 !== prompt && $0.native?.canSelectNext == true }
                ? QwenTensorParallelPromptWavefront.framesBesideDecoding : QwenTensorParallelPromptWavefront.maximumFrames) {
            slots[prompt.slot].role = .prefill; slots[prompt.slot].frameOffset = frame.tokenOffset
            slots[prompt.slot].frameCount = frame.tokenCount; slots[prompt.slot].finalChunk = frame.finalPromptChunk
        }
        let decoding = slots.indices.filter {
            slots[$0].state == .active && records[$0]?.native?.canSelectNext == true
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

    private func report(step: Int, carrying: Set<Int> = []) throws -> QwenBatchWire.Reply {
        let mask = records.values.reduce(0) { $0 | (cancelled($1) ? 1 << $1.slot : 0) }
        // This rank's memory: the newest running lane is named, and rank 0 ends it alone.
        _ = try pollMemory(peerCancelled: [])
        var memoryMask = 0
        if let slot = pendingMemorySlot {
            pendingMemorySlot = nil
            if records[slot] != nil { memoryMask = 1 << slot; reportedMemory.insert(slot) }
        }
        return .init(step: step, tokens: (0..<capacity).map { slot in
            records[slot].map { $0.tokens.count + (carrying.contains(slot) ? 1 : 0) } ?? -1
        }, cancelledMask: mask, memoryMask: memoryMask)
    }

    /// D6: this rank's live memory check at a step boundary. A refusal stops
    /// the newest running lane alone: rank 0 marks it to leave with its abort
    /// once it owes no answer; rank 1 names it in its next report. No new
    /// check runs while a stopped lane has yet to leave. True on a refusal.
    private func pollMemory(peerCancelled: Set<Int>) throws -> Bool {
        if executor.rank == 0 {
            guard memoryStopped.isEmpty, try memoryRefused() else { return false }
            let running = records.values.filter { !$0.leaving && !cancelled($0) && !peerCancelled.contains($0.slot) }
            guard let newest = running.max(by: { $0.order < $1.order }) else { return false }
            memoryStopped[newest.slot] = .init(reason: .memory, rank: 0)
            return true
        }
        guard reportedMemory.isEmpty, pendingMemorySlot == nil, try memoryRefused() else { return false }
        guard let newest = records.values.filter({ !cancelled($0) }).max(by: { $0.order < $1.order }) else { return false }
        pendingMemorySlot = newest.slot
        return true
    }

    /// Rank 0: the lanes rank 1's memory stopped (its report's memory mask).
    private func noteMemoryMask(_ mask: Int) {
        guard executor.rank == 0, mask != 0 else { return }
        for slot in 0..<capacity where mask & (1 << slot) != 0 {
            if let record = records[slot], !record.leaving, memoryStopped[slot] == nil {
                memoryStopped[slot] = .init(reason: .memory, rank: 1)
            }
        }
    }

    /// Both ranks' control words for `step`; this rank's own part must have crossed unchanged.
    private static func read(_ sum: [Float], step: Int, lanes: Int, plan: QwenBatchWire.Header?,
                             report: QwenBatchWire.Reply?) throws -> (QwenBatchWire.Header, QwenBatchWire.Reply) {
        let (received, peer) = try QwenTensorParallelBatchWire.read(sum, step: step, lanes: lanes)
        if let plan, received != plan { throw ProbeError("Qwen TP leader plan changed in transit") }
        if let report, peer != report { throw ProbeError("Qwen TP follower report changed in transit") }
        return (received, peer)
    }

    /// A carried plan was made before the tokens of the step that carried it.
    /// A row that decodes on its new token takes it, unless that token ended
    /// its request (a stop token or its output count): both ranks read it in
    /// the same sum and drop that decode alike.
    private func resolve(_ plan: QwenBatchWire.Header, carrying: Set<Int>) throws -> QwenBatchWire.Header {
        var plan = plan
        for slot in plan.slots.indices where plan.slots[slot].inputToken == QwenTensorParallelBatchWire.carriedToken {
            guard plan.slots[slot].role == .decode, carrying.contains(slot), let record = records[slot],
                  let token = record.tokens.last else {
                throw ProbeError("Qwen TP carried decode has no carrying row")
            }
            if record.ended { plan.slots[slot].role = .none; plan.slots[slot].inputToken = -1 }
            else { plan.slots[slot].inputToken = token }
        }
        return plan
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
                // A client stop keeps what the owner saw: it may drop the one token selected after it.
                let dropsHeld = value.state == .leaving && !value.leaveCancelled && value.leaveReason == .clientStop
                let held = record.map { $0.tokens.count - value.selectedTokens } ?? 0
                guard let record, record.id == value.requestID, record.fingerprint == value.fingerprintWords,
                      record.tokens.count == value.selectedTokens
                        || (dropsHeld && (1...(buildsAhead ? Self.aheadHeldLimit : 1)).contains(held)),
                      record.native?.committedTokens == value.committedTokens else {
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
                          host: QwenBatchServingHost, peerCancelled: Set<Int>) throws {
        guard (0..<vocabulary).contains(token) else { throw ProbeError("Qwen TP selected token lies outside the vocabulary") }
        lane.tokens.append(token)
        guard executor.rank == 0 else { return }
        lane.heldLogprobs.append(try executor.takeLogprobs(lane.native!))
        try publishHeld(lane, decisions: &decisions, host: host, peerCancelled: peerCancelled)
    }

    /// Rank 0 publishes a selected token once the owner answered "go on" to
    /// the token before it (at once when it already had); never after a stop
    /// answer, a planned leave or a cancellation.
    private func publishHeld(_ lane: Record, decisions: inout QwenBatchDecisionProgress,
                             host: QwenBatchServingHost, peerCancelled: Set<Int>) throws {
        guard lane.published < lane.tokens.count, lane.heldLogprobs.count == lane.tokens.count - lane.published,
              !lane.leaving, decisions.canForward(lane.id), memoryStopped[lane.slot] == nil,
              !peerCancelled.contains(lane.slot), !cancelled(lane) else { return }
        try decisions.published(lane.id)
        try host.publishToken(requestID: lane.id, ordinal: lane.published, tokenID: lane.tokens[lane.published],
            committedTokens: lane.reservation.request.promptCount + lane.published, logprobs: lane.heldLogprobs[0])
        lane.published += 1; lane.heldLogprobs.removeFirst()
    }

    private func leave(_ plan: QwenBatchWire.Header, host: QwenBatchServingHost,
                       decisions: inout QwenBatchDecisionProgress,
                       retiredSelection: (UUID, [Int], QwenLayerStageGenerationFinishReason) throws -> Void,
                       check: () throws -> Void) throws {
        let leaving = plan.slots.indices.filter { plan.slots[$0].state == .leaving }
        guard !leaving.isEmpty else { return }
        for slot in leaving {
            let value = plan.slots[slot], record = records[slot]!
            // A lane ended alone for memory (D6) retires as a cancelled one does.
            let unfinished = value.leaveCancelled || value.leaveAborted != nil
            // Validated: only a client stop drops a token, the one selected after the owner's answer.
            if !unfinished { record.tokens = Array(record.tokens.prefix(value.selectedTokens)) }
            guard let native = record.native, unfinished || (value.leaveReason != nil
                    && record.finish(value.leaveReason != .clientStop, count: record.tokens.count) == value.leaveReason) else {
                throw ProbeError("Qwen TP leave reason differs from selected tokens")
            }
            try executor.retire(native, reason: unfinished ? nil : value.leaveReason,
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
            let unfinished = value.leaveCancelled || value.leaveAborted != nil
            memoryStopped[slot] = nil; reportedMemory.remove(slot)
            try executor.confirmedRetirement(native, clean: !unfinished)
            if !unfinished, native.reusedPrefixTokens > 0 || !native.storedPrefixFrontiers.isEmpty {
                try host.publishPromptCache(requestID: record.id, reusedTokens: native.reusedPrefixTokens,
                    storedFrontiers: native.storedPrefixFrontiers)
            }
            record.native = nil; book.finish(record.id); decisions.retired(record.id); records[slot] = nil
            if let abort = value.leaveAborted { try host.publishAborted(requestID: record.id, abort: abort) }
            else if value.leaveCancelled { try host.publishLeft(requestID: record.id) }
            else if let reason = value.leaveReason {
                // Only a bilaterally retired clean selection is handed over.
                try retiredSelection(record.id, record.tokens, reason)
                try host.publishFinished(requestID: record.id, reason: .init(rawValue: reason.rawValue)!)
            } else { throw ProbeError("Qwen TP clean leave omitted its reason") }
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
