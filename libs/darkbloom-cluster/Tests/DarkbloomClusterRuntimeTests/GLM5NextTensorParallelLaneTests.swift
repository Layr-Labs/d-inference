import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// The GLM tensor-parallel lane loop without a model: its step message, the
/// prefill grid every lane shares with one request, the lane charge, and the
/// whole two-rank loop over a fake native (an in-process all-sum, requests
/// whose tokens are a fixed function of the request and position). A lane's
/// tokens are its request's alone, joins, leaves and cancels are per lane,
/// and both ranks run the same collectives in the same order.
struct GLM5NextTensorParallelLaneTests {
    typealias Wire = GLM5NextTensorParallelLaneWire
    typealias Runtime = GLM5NextTensorParallelResidentRuntime

    // MARK: Wire

    @Test func aStepMessageCrossesTheSumExactly() throws {
        let a = UUID(), b = UUID()
        var plan = Wire.Plan(step: 41, stop: false, lanes: 3, depth: 2, prefixEnabled: true,
            slots: Array(repeating: .init(), count: 3))
        plan.slots[0] = .init(state: .active, requestID: a, role: .decode, tokens: 17, last: 151_000, window: 2)
        plan.slots[1] = .init(state: .active, requestID: b, role: .prefill, tokens: 0,
            frame: .init(offset: 8192, end: 12_288, final: true))
        plan.slots[2] = .init(state: .leaving, requestID: UUID(), tokens: 9, leave: .clientStop, kept: 6)
        let report = Wire.Report(step: 41, lanes: 3, prefixEnabled: true, leaveWanted: [false, true, false],
            tokens: [17, 0, 9])
        let summed = zip(try Wire.words(plan), try Wire.words(report)).map { $0 + $1 }
        let read = try Wire.read(summed, lanes: 3, step: 41)
        #expect(read.plan == plan)
        #expect(read.report == report)
        // A one-token step has no window.
        plan.slots[0].window = nil
        #expect(try Wire.read(zip(try Wire.words(plan), try Wire.words(report)).map { $0 + $1 }, lanes: 3, step: 41)
            .plan.slots[0].window == nil)
    }

    @Test func anotherStepOrADamagedWordStopsBothRanks() throws {
        let plan = Wire.Plan(step: 7, stop: false, lanes: 2, depth: 2, prefixEnabled: false,
            slots: [.init(state: .joining, requestID: UUID()), .init()])
        let report = Wire.Report(step: 7, lanes: 2, prefixEnabled: false, leaveWanted: [false, false], tokens: [nil, nil])
        let summed = zip(try Wire.words(plan), try Wire.words(report)).map { $0 + $1 }
        #expect(throws: ProbeError.self) { try Wire.read(summed, lanes: 2, step: 8) }
        #expect(throws: ProbeError.self) { try Wire.read(summed, lanes: 3, step: 7) }
        for index in [3, 10, summed.count - 2] {
            var damaged = summed; damaged[index] += 1
            #expect(throws: ProbeError.self) { try Wire.read(damaged, lanes: 2, step: 7) }
        }
        var fractional = summed; fractional[12] += 0.5
        #expect(throws: ProbeError.self) { try Wire.read(fractional, lanes: 2, step: 7) }
        // A rank that contributed nothing (both regions must be present).
        #expect(throws: ProbeError.self) { try Wire.read(try Wire.words(plan), lanes: 2, step: 7) }
        // A stop may not leave a lane running.
        var running = plan; running.stop = true
        #expect(throws: ProbeError.self) {
            try Wire.read(zip(try Wire.words(running), try Wire.words(report)).map { $0 + $1 }, lanes: 2, step: 7)
        }
    }

    // MARK: The grid one request and every lane prefill on

    @Test func framesFollowTheSoloGrid() {
        func frames(_ count: Int, start: Int = 0, requestChunk: Int = 2048, prefix: Bool) -> [Int] {
            let chunk = Runtime.prefillChunk(requestChunk: requestChunk)
            let keepAt = Runtime.prefixKeepAt(promptCount: count, chunk: chunk, prefixEnabled: prefix)
            var ends: [Int] = [], offset = start
            while offset < count {
                offset = Runtime.prefillFrameEnd(offset: offset, promptCount: count, chunk: chunk, keepAt: keepAt)
                ends.append(offset)
            }
            return ends
        }
        #expect(Runtime.prefillChunk(requestChunk: 2048) == 4096)
        #expect(Runtime.prefillChunk(requestChunk: 3000) == 3000)
        #expect(Runtime.prefillChunk(requestChunk: 0) == 4096)
        // Bulk chunks up to the kept boundary, then chunk-aligned ones.
        #expect(frames(20_000, prefix: true) == [8192, 16_384, 20_000])
        #expect(frames(20_000, prefix: false) == [8192, 16_384, 20_000])
        #expect(frames(13_000, prefix: true) == [8192, 12_288, 13_000])
        #expect(frames(12_289, prefix: true) == [8192, 12_288, 12_289])
        #expect(frames(12_288, prefix: true) == [8192, 12_288])
        #expect(frames(3931, prefix: true) == [3931])
        // From a restored prefix.
        #expect(frames(20_000, start: 4096, prefix: true) == [12_288, 16_384, 20_000])
    }

    @Test func aLaneIsChargedItsOwnContext() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration.textConfig
        let identity: (Int) throws -> Int = { $0 }
        let short = try Runtime.laneStateBytes(configuration: c, contextTokens: 100, speculative: true, allocationBound: identity)
        let long = try Runtime.laneStateBytes(configuration: c, contextTokens: 10_000, speculative: true, allocationBound: identity)
        let plain = try Runtime.laneStateBytes(configuration: c, contextTokens: 10_000, speculative: false, allocationBound: identity)
        let dsa = c.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        let kda = c.layerTypes.filter { $0 == .linearAttention }.count
        let row = c.kvLoraRank * 4 + 2 * c.indexHeadDim * 4 + 1
        let linear = c.linearAttention
        let settled = linear.numHeads * linear.headDim * linear.headDim * 4
            + 3 * linear.numHeads * linear.headDim * linear.shortConvKernelSize * 4
        // A speculating lane's captured verification windows (and last round's adopted state).
        let windows = 2 * kda * (Runtime.mtpDepth + 1) * settled
        #expect(plain == 20_000 * row * dsa + settled * kda)
        #expect(long == plain + 20_000 * row + windows)
        // Below 128 tokens the cache's first growth (256 rows) is charged.
        #expect(short == 256 * row * (dsa + 1) + settled * kda + windows)
        #expect(throws: ProbeError.self) {
            try Runtime.laneStateBytes(configuration: c, contextTokens: 0, speculative: false, allocationBound: identity)
        }
    }

    @Test func lanesAreBoundIntoTheLoadAgreementOnlyWhenBatching() {
        #expect(Runtime.laneAgreementFields(.single) == [])
        #expect(Runtime.laneAgreementFields(.init(lanes: 8)) == ["glm5-next-tp-lanes-v1", "lanes=8"])
    }

    // MARK: The two-rank loop

    @Test func staggeredLanesKeepTheirSoloTokensAndLeaveAlone() throws {
        let run = try FakePair(lanes: 3)
        // Ten requests arriving while others run: plain and speculating,
        // with stop tokens, output limits, a stop answer, two cancels (one
        // seen by rank 0, one only by rank 1), a deadline and a request that
        // arrives while every lane is taken.
        let specs: [FakePair.Spec] = [
            .init(tick: 0, prompt: 9, output: 12),
            .init(tick: 0, prompt: 6, output: 30, eosAt: 13),
            .init(tick: 2, prompt: 4, output: 9),
            .init(tick: 3, prompt: 11, output: 20, stopAnswerAt: 4),
            .init(tick: 5, prompt: 8, output: 25, cancelAt: 12, cancelRanks: [0, 1]),
            .init(tick: 6, prompt: 5, output: 40, cancelAt: 20, cancelRanks: [1]),
            .init(tick: 8, prompt: 14, output: 6),
            .init(tick: 9, prompt: 7, output: 50, deadlineTicks: 18),
            .init(tick: 10, prompt: 2, output: 1),
            .init(tick: 11, prompt: 12, output: 17, eosAt: 0),
        ]
        try run.serve(specs)
        for (index, spec) in specs.enumerated() {
            let id = run.ids[index]
            let solo = FakeLaneNative.solo(prompt: run.prompts[index], count: spec.output + 1)
            let zero = run.hosts[0].record(id), one = run.hosts[1].record(id)
            if spec.cancelAt != nil || spec.deadlineTicks != nil {
                #expect(zero.left && one.left, "lane \(index) retires as cancelled on both ranks")
                #expect(zero.finish == nil && one.finish == nil)
                #expect(zero.tokens == Array(solo.prefix(zero.tokens.count)), "lane \(index) tokens")
                continue
            }
            var expected = Array(solo.prefix(spec.output))
            if let eos = spec.eosAt { expected = Array(expected.prefix(eos + 1)) }
            var finish: ClusterWorkerFinishReason = spec.eosAt.map { $0 < spec.output ? .eos : .length } ?? .length
            if let stop = spec.stopAnswerAt, stop + 1 < expected.count {
                expected = Array(expected.prefix(stop + 1)); finish = .clientStop
            }
            #expect(zero.tokens == expected, "lane \(index) publishes its solo tokens")
            #expect(zero.finish == finish && one.finish == finish, "lane \(index) finish")
            #expect(!zero.left && !one.left)
            #expect(one.tokens.isEmpty, "rank 1 publishes no tokens")
        }
        #expect(run.link.mismatch == nil)
        #expect(run.books.allSatisfy { $0.isEmpty })
        // Several lanes ran at once.
        #expect(run.natives[0].mostDecodeUnitsInOneStep >= 2)
    }

    @Test func aMediaLaneJoinsOnceRankZeroPreparedItWhileTheOthersRun() throws {
        let run = try FakePair(lanes: 3)
        // Lane 1 carries media whose preparation on rank 0 ends at tick 30;
        // lane 2 arrives after it and runs meanwhile.
        let specs: [FakePair.Spec] = [
            .init(tick: 0, prompt: 6, output: 30),
            .init(tick: 1, prompt: 5, output: 12, mediaReadyTick: 30),
            .init(tick: 2, prompt: 4, output: 8),
        ]
        try run.serve(specs)
        for (index, spec) in specs.enumerated() {
            let id = run.ids[index]
            #expect(run.hosts[0].record(id).tokens == FakeLaneNative.solo(prompt: run.prompts[index], count: spec.output),
                "lane \(index) publishes its solo tokens")
            #expect(run.hosts[0].record(id).finish == .length && run.hosts[1].record(id).finish == .length)
        }
        let opened = run.natives[0].opened
        #expect(opened.firstIndex(of: run.ids[2])! < opened.firstIndex(of: run.ids[1])!,
            "the later text lane joins before the media lane is prepared")
        #expect(run.natives[0].openedAtTick[run.ids[1]]! >= 30)
        #expect(run.natives[1].opened == opened, "rank 1 joins what rank 0 names")
        #expect(run.books.allSatisfy { $0.isEmpty })
    }

    @Test func aLoneMediaLaneKeepsTheLoopUntilItIsPrepared() throws {
        let run = try FakePair(lanes: 2)
        try run.serve([.init(tick: 0, prompt: 7, output: 9, mediaReadyTick: 20)])
        let id = run.ids[0]
        #expect(run.hosts[0].record(id).tokens == FakeLaneNative.solo(prompt: run.prompts[0], count: 9))
        #expect(run.hosts[0].record(id).finish == .length && run.hosts[1].record(id).finish == .length)
        #expect(run.natives[0].openedAtTick[id]! >= 20)
    }

    /// Logprob lanes beside each other (a stop answer, an EOS, an output
    /// limit): rank 0 publishes every token with that token's own logprobs,
    /// taken once each, then the lane's telemetry once, before its finish;
    /// rank 1 publishes neither.
    @Test func logprobLanesPublishEachTokensLogprobsAndTheirTelemetry() throws {
        let run = try FakePair(lanes: 3)
        for native in run.natives { native.reportsLogprobs = true }
        let specs: [FakePair.Spec] = [
            .init(tick: 0, prompt: 9, output: 12),
            .init(tick: 1, prompt: 6, output: 10, eosAt: 7),
            .init(tick: 2, prompt: 5, output: 9, stopAnswerAt: 3),
        ]
        try run.serve(specs)
        for index in specs.indices {
            let id = run.ids[index]
            let zero = run.hosts[0].record(id), one = run.hosts[1].record(id)
            #expect(!zero.tokens.isEmpty && zero.finish != nil, "lane \(index) finishes")
            #expect(zero.logprobs == zero.tokens.enumerated().map {
                FakeLaneNative.logprobs(token: $0.element, ordinal: $0.offset)
            }, "lane \(index) publishes each token's own logprobs")
            #expect(zero.telemetry == [FakeLaneNative.telemetry], "lane \(index) reports its telemetry once")
            #expect(one.tokens.isEmpty && one.telemetry.isEmpty)
        }
        #expect(run.natives[0].takenTwice.isEmpty)
        #expect(run.link.mismatch == nil)
    }

    @Test func aSingleLaneRunsAsOneRequest() throws {
        let run = try FakePair(lanes: 8)
        try run.serve([.init(tick: 0, prompt: 10, output: 20)])
        let id = run.ids[0]
        #expect(run.hosts[0].record(id).tokens == Array(FakeLaneNative.solo(prompt: run.prompts[0], count: 20)))
        #expect(run.hosts[0].record(id).finish == .length && run.hosts[1].record(id).finish == .length)
        // Open (digest and prefix vote), three frames, then one unit a step.
        #expect(run.link.kinds.prefix(4) == ["step", "open", "step", "prefill"])
    }
}

// MARK: - Fakes

/// An in-process all-sum between two threads: each call pairs with the peer's
/// call of the same ordinal, which must be the same kind and size.
final class FakeLink: @unchecked Sendable {
    private let condition = NSCondition()
    private var deposits: [Int: [Int: (kind: String, values: [Float])]] = [:]
    private var reads: [Int: Int] = [:]
    private var calls = [0, 0]
    private(set) var kinds: [String] = []
    private(set) var mismatch: String?

    func exchange(rank: Int, kind: String, _ values: [Float]) throws -> [Float] {
        condition.lock(); defer { condition.unlock() }
        let round = calls[rank]; calls[rank] += 1
        deposits[round, default: [:]][rank] = (kind, values)
        if rank == 0 { kinds.append(kind) }
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 20)
        while deposits[round]!.count < 2 {
            guard mismatch == nil else { throw ProbeError("fake link failed: \(mismatch!)") }
            guard condition.wait(until: deadline) else { mismatch = "timeout at \(round) \(kind)"; throw ProbeError("fake link timeout") }
        }
        let a = deposits[round]![0]!, b = deposits[round]![1]!
        guard a.kind == b.kind, a.values.count == b.values.count else {
            mismatch = "\(round): \(a.kind) vs \(b.kind)"; condition.broadcast()
            throw ProbeError("fake link: ranks ran different collectives")
        }
        reads[round, default: 0] += 1
        if reads[round] == 2 { deposits[round] = nil; reads[round] = nil }
        return zip(a.values, b.values).map { $0 + $1 }
    }

    func fail(_ reason: String) { condition.lock(); mismatch = mismatch ?? reason; condition.broadcast(); condition.unlock() }
}

/// The lane loop's native half without a model: a request's tokens are a
/// fixed function of its prompt and position, so a lane's tokens can be
/// compared with the request alone however the loop interleaves it.
final class FakeLaneNative: GLM5NextTensorParallelLaneNative {
    final class Lane {
        let request: QwenLayerStageGenerationRequest
        var offset = 0
        var agreed = 0
        init(request: QwenLayerStageGenerationRequest) { self.request = request }
        var solo: [Int] { FakeLaneNative.solo(prompt: request.promptTokenIDs, count: request.outputCount + 1) }
    }
    static let chunk = 4
    static let stopToken = 1
    let rank: Int
    let depth = 2
    let prefixEnabled = true
    let link: FakeLink
    private(set) var mostDecodeUnitsInOneStep = 0
    /// Requests in the order this rank opened them, and rank 0's script tick then.
    private(set) var opened: [UUID] = []
    private(set) var openedAtTick: [UUID: Int] = [:]
    var tick: () -> Int = { 0 }
    /// Every request asks for logprobs; rank 0 gives each agreed token's.
    var reportsLogprobs = false
    private var taken: Set<String> = []
    private(set) var takenTwice: [String] = []
    static let telemetry = ClusterWorkerRequestTelemetry(mtpDrafted: 4, mtpAccepted: 3, mtpRounds: 2)
    static func logprobs(token: Int, ordinal: Int) -> ClusterWorkerTokenLogprobs {
        .init(logprob: -Float(ordinal) / 8, top: [.init(tokenID: token, logprob: -Float(ordinal) / 8)])
    }

    init(rank: Int, link: FakeLink) { self.rank = rank; self.link = link }

    /// The request's tokens alone: never the stop token unless its prompt
    /// asks for one at a position (`prompt[0] - 1000`).
    static func solo(prompt: [Int], count: Int) -> [Int] {
        let seed = prompt.reduce(7) { ($0 &* 31 &+ $1) % 10_007 }
        let eos = prompt[0] >= 1000 ? prompt[0] - 1000 : -1
        return (0..<count).map { $0 == eos ? stopToken : 2 + (seed &* 13 &+ $0 &* 17) % 90 }
    }

    func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float] {
        try check()
        return try link.exchange(rank: rank, kind: "step", words)
    }

    func open(_ request: QwenLayerStageGenerationRequest, check: () throws -> Void) throws -> Lane {
        // The digest agreement, as `openRequest`: both ranks name the same request.
        let digest = Float(QwenTensorParallelResidentRuntime.digest64(request.fingerprint) & 0xFFFF)
        let summed = try link.exchange(rank: rank, kind: "open", rank == 0 ? [digest, 0] : [0, digest])
        guard summed[0] == summed[1] else { throw ProbeError("fake ranks opened different requests") }
        opened.append(request.requestID); openedAtTick[request.requestID] = tick()
        return Lane(request: request)
    }

    func nextFrame(_ lane: Lane, merging: Bool) -> GLM5NextTensorParallelLaneWire.Frame? {
        let count = lane.request.promptTokenIDs.count
        guard lane.offset < count else { return nil }
        let end = min(count, lane.offset + Self.chunk)
        return .init(offset: lane.offset, end: end, final: end == count)
    }

    func prefill(_ lane: Lane, _ frame: GLM5NextTensorParallelLaneWire.Frame, check: () throws -> Void) throws -> Int? {
        guard frame == nextFrame(lane, merging: false) else { throw ProbeError("fake frame is not the lane's next") }
        _ = try link.exchange(rank: rank, kind: "prefill", [Float(frame.end - frame.offset)])
        lane.offset = frame.end
        guard frame.final else { return nil }
        lane.agreed = 1
        return lane.solo[0]
    }

    func speculates(_ lane: Lane) -> Bool { lane.request.promptTokenIDs.count % 2 == 0 }

    func decode(_ units: [GLM5NextTensorParallelDecodeUnit<Lane>], whileRunning: (Int) throws -> Void,
                check: () throws -> Void) throws -> [[Int]] {
        mostDecodeUnitsInOneStep = max(mostDecodeUnitsInOneStep, units.count)
        return try units.enumerated().map { index, unit in
            let lane = unit.lane, solo = lane.solo, n = lane.agreed
            guard unit.last == solo[n - 1], (unit.window != nil) == speculates(lane) else {
                throw ProbeError("fake unit decodes after a token the request did not agree")
            }
            // One sum per unit, as a round's or a step's agreement.
            _ = try link.exchange(rank: rank, kind: "unit", [Float(unit.window ?? -1)])
            try whileRunning(index)
            let kept = unit.window.map { ($0 + n) % ($0 + 1) + 1 } ?? 1
            lane.agreed += kept
            try check()
            return Array(solo[n ..< n + kept])
        }
    }

    func close(_ lane: Lane, kept: Int, leave: GLM5NextTensorParallelLaneWire.Leave) -> (reused: Int, stored: [Int]) {
        (0, [])
    }

    func takeLogprobs(_ lane: Lane, ordinal: Int) throws -> ClusterWorkerTokenLogprobs? {
        guard reportsLogprobs else { return nil }
        guard rank == 0, ordinal < lane.agreed else { throw ProbeError("fake logprobs of a token not agreed on rank 0") }
        let key = "\(lane.request.requestID)/\(ordinal)"
        if !taken.insert(key).inserted { takenTwice.append(key) }
        return Self.logprobs(token: lane.solo[ordinal], ordinal: ordinal)
    }

    func telemetry(_ lane: Lane) -> ClusterWorkerRequestTelemetry? {
        reportsLogprobs && rank == 0 ? Self.telemetry : nil
    }
}

/// One rank's worker as the loop sees it: control applied between steps,
/// publication, the owner's late answers.
final class FakeLaneHost: QwenBatchServingHost, @unchecked Sendable {
    struct Record {
        var tokens: [Int] = []; var finish: ClusterWorkerFinishReason?; var left = false
        var logprobs: [ClusterWorkerTokenLogprobs] = []; var telemetry: [ClusterWorkerRequestTelemetry] = []
    }
    let rank: Int
    let pair: FakePair
    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    private var outstanding: [UUID: (ordinal: Int, polls: Int)] = [:]

    init(rank: Int, pair: FakePair) { self.rank = rank; self.pair = pair }
    func record(_ id: UUID) -> Record { lock.withLock { records[id] ?? Record() } }

    func serviceControl() throws { try pair.service(rank: rank) }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int,
                      logprobs: ClusterWorkerTokenLogprobs?) throws {
        try publishToken(requestID: requestID, ordinal: ordinal, tokenID: tokenID, committedTokens: committedTokens)
        if let logprobs { lock.withLock { records[requestID, default: .init()].logprobs.append(logprobs) } }
    }
    func publishTelemetry(requestID: UUID, telemetry: ClusterWorkerRequestTelemetry) throws {
        try lock.withLock {
            guard records[requestID]?.finish == nil else { throw ProbeError("fake host: telemetry after finish") }
            records[requestID, default: .init()].telemetry.append(telemetry)
        }
    }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
        try lock.withLock {
            guard rank == 0, outstanding[requestID] == nil, records[requestID, default: .init()].tokens.count == ordinal,
                  records[requestID]?.finish == nil else {
                throw ProbeError("fake host: token out of credit or order")
            }
            records[requestID, default: .init()].tokens.append(tokenID)
            outstanding[requestID] = (ordinal, 0)
        }
    }
    func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] { throw ProbeError("fake host: lanes answer one by one") }
    func pollDecision(_ requestID: UUID) throws -> Bool? {
        try lock.withLock {
            guard var value = outstanding[requestID] else { throw ProbeError("fake host: no token awaits an answer") }
            if pair.cancelled(requestID, rank: 0) { outstanding[requestID] = nil; return false }
            // The answer crosses the pipes: it is there at the second look.
            value.polls += 1
            guard value.polls >= 2 else { outstanding[requestID] = value; return nil }
            outstanding[requestID] = nil
            return pair.answer(requestID, ordinal: value.ordinal)
        }
    }
    func awaitDecision(_ requestID: UUID) throws -> Bool {
        try lock.withLock {
            guard let value = outstanding[requestID] else { throw ProbeError("fake host: no token awaits an answer") }
            outstanding[requestID] = nil
            return pair.cancelled(requestID, rank: 0) ? false : pair.answer(requestID, ordinal: value.ordinal)
        }
    }
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {
        try lock.withLock {
            guard outstanding[requestID] == nil, records[requestID]?.finish == nil else {
                throw ProbeError("fake host: finish before its last answer")
            }
            records[requestID, default: .init()].finish = reason
        }
    }
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
    func publishLeft(requestID: UUID) throws {
        lock.withLock { outstanding[requestID] = nil; records[requestID, default: .init()].left = true }
    }
}

/// Two ranks' loops on two threads, fed by one script of arrivals, cancels
/// and answers, on one fake clock that rank 0's steps advance.
final class FakePair: @unchecked Sendable {
    struct Spec {
        var tick: Int
        var prompt: Int
        var output: Int
        var eosAt: Int?
        var stopAnswerAt: Int?
        var cancelAt: Int?
        var cancelRanks: Set<Int> = []
        var deadlineTicks: Int?
        /// The request carries media; rank 0's preparation ends at this tick.
        var mediaReadyTick: Int?
    }
    let lanes: Int
    let link = FakeLink()
    let books = [ClusterBatchLaneBook<GLM5NextTensorParallelLaneReservation>(),
                 ClusterBatchLaneBook<GLM5NextTensorParallelLaneReservation>()]
    private(set) var natives: [FakeLaneNative] = []
    private(set) var hosts: [FakeLaneHost] = []
    private let lock = NSLock()
    private var specs: [Spec] = []
    private(set) var ids: [UUID] = []
    private(set) var prompts: [[Int]] = []
    private var tick = 0
    private var clock: UInt64 = 1_000_000
    private var startedOnZero: [UUID: Int] = [:]
    private var cancelledOn: [Int: Set<UUID>] = [0: [], 1: []]
    private var prepared = Set<UUID>()
    private let profile: QwenLayerStageGenerationProfile

    init(lanes: Int) throws {
        self.lanes = lanes
        profile = try QwenLayerStageGenerationProfile(identifier: "glm-lane-loop-test", vocabularySize: 2000,
            hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 64,
            maximumChunkTokens: 4, maximumOutputTokens: 64, maximumContextTokens: 160)
        natives = [FakeLaneNative(rank: 0, link: link), FakeLaneNative(rank: 1, link: link)]
        hosts = [FakeLaneHost(rank: 0, pair: self), FakeLaneHost(rank: 1, pair: self)]
        for native in natives { native.tick = { [unowned self] in self.lock.withLock { self.tick } } }
    }

    func isPrepared(_ id: UUID) -> Bool { lock.withLock { prepared.contains(id) } }

    var now: UInt64 { lock.withLock { clock } }

    func cancelled(_ id: UUID, rank: Int) -> Bool { lock.withLock { cancelledOn[rank]!.contains(id) } }

    /// The owner's answer to a token: go on, unless the script stops there.
    func answer(_ id: UUID, ordinal: Int) -> Bool {
        lock.withLock {
            guard let index = ids.firstIndex(of: id), let stop = specs[index].stopAnswerAt else { return true }
            return ordinal < stop
        }
    }

    /// Control between steps, as the worker applies it. Rank 0's calls are
    /// the script's ticks; rank 1 starts a lane only after rank 0 did, one
    /// call later, so its loop waits for its own start at the join.
    func service(rank: Int) throws {
        try lock.withLock {
            if rank == 0 {
                for (index, spec) in specs.enumerated() {
                    let id = ids[index]
                    if spec.tick == tick {
                        let deadline = spec.deadlineTicks.map { clock + UInt64($0) * 1_000 } ?? UInt64.max
                        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
                            promptTokenIDs: prompts[index], chunkSize: 4, outputCount: spec.output,
                            stopTokenIDs: [FakeLaneNative.stopToken])
                        for (rank, book) in books.enumerated() {
                            // Rank 0's media lane prepares until its tick; rank 1 prepares nothing.
                            var media: GLM5NextTensorParallelMedia?
                            if spec.mediaReadyTick != nil {
                                let value = try GLM5NextTensorParallelMediaTests.request(rank: rank)
                                if rank == 0 {
                                    value.startPreparation { [self] in
                                        while !isPrepared(id) { try await Task.sleep(nanoseconds: 200_000) }
                                        return []
                                    }
                                }
                                media = value
                            }
                            try book.reserve(id, .init(request: request, deadline: deadline, laneStateBytes: 1,
                                media: media), lanes: specs.count)
                        }
                        try books[0].start(id); startedOnZero[id] = 0
                    }
                    if spec.mediaReadyTick == tick { prepared.insert(id) }
                    if spec.cancelAt == tick {
                        for rank in spec.cancelRanks { books[rank].cancel(id); cancelledOn[rank]!.insert(id) }
                    }
                }
                tick += 1; clock += 1_000
            } else {
                for (id, calls) in startedOnZero {
                    if calls >= 1 { try books[1].start(id); startedOnZero[id] = nil } else { startedOnZero[id] = calls + 1 }
                }
            }
        }
    }

    func serve(_ specs: [Spec]) throws {
        lock.withLock {
            self.specs = specs
            ids = specs.map { _ in UUID() }
            prompts = specs.enumerated().map { index, spec in
                // The first word names the stop token's position (1000 + i).
                [spec.eosAt.map { 1000 + $0 } ?? 10 + index] + (1..<spec.prompt).map { (index * 7 + $0) % 90 + 2 }
            }
        }
        final class Failures: @unchecked Sendable {
            let lock = NSLock(); var errors: [Error?] = [nil, nil]
        }
        let failures = Failures()
        let done = DispatchGroup()
        for rank in 0..<2 {
            done.enter()
            Thread.detachNewThread { [self] in
                defer { done.leave() }
                let loop = GLM5NextTensorParallelLaneLoop(native: natives[rank], lanes: lanes, book: books[rank],
                    host: hosts[rank], joinWaitNanoseconds: 10_000_000_000, deadlineMarginNanoseconds: 0,
                    now: { [self] in now })
                do { try loop.run(check: {}) } catch {
                    failures.lock.withLock { failures.errors[rank] = error }; link.fail("rank \(rank): \(error)")
                }
            }
        }
        guard done.wait(timeout: .now() + 60) == .success else { throw ProbeError("fake pair did not finish") }
        if let failure = failures.lock.withLock({ failures.errors[0] ?? failures.errors[1] }) { throw failure }
    }
}
