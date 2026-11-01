import DarkbloomClusterProtocol
import Foundation
@testable import DarkbloomClusterRuntime

/// Same real two-rank driver/wire fixture for both typed reservation families.
/// Only native model forwards and the blocking data link are substituted.
protocol HistoryBatchTestReservation: IndependentHistoryBatchReservation, SendableMetatype {
    static func fixture(_ request: QwenLayerStageGenerationRequest, deadline: UInt64) throws -> Self
}

extension GPTOSSBatchReservation: HistoryBatchTestReservation {
    static func fixture(_ request: QwenLayerStageGenerationRequest, deadline: UInt64) throws -> Self {
        let budget = GPTOSSRequestStateBudget(fullAttentionLayers: 1, slidingLayers: 1,
            fullAttentionStateBytes: 40, slidingStateBytes: 20, boundaryBytes: 10, rowBytes: 10,
            workspaceBytes: 20, reservedBytes: 100)
        return try .init(request: request, allowance: .init(budget: budget), deadline: deadline)
    }
}

extension MiMoBatchReservation: HistoryBatchTestReservation {
    static func fixture(_ request: QwenLayerStageGenerationRequest, deadline: UInt64) throws -> Self {
        let budget = MiMoRequestStateBudget(fullAttentionLayers: 1, slidingLayers: 1,
            fullAttentionStateBytes: 40, slidingStateBytes: 20, boundaryBytes: 10, rowBytes: 10,
            workspaceBytes: 20, reservedBytes: 100)
        return try .init(request: request, allowance: .init(budget: budget, pagedBytes: 1),
            deadline: deadline, pageBytes: 1)
    }
}

fileprivate final class HistoryBatchTestPipe: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [[Int32]] = []
    private var failure: Error?
    func send(_ value: [Int32]) { condition.withLock { values.append(value); condition.broadcast() } }
    func fail(_ error: Error) { condition.withLock { failure = error; condition.broadcast() } }
    func receive() throws -> [Int32] {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while values.isEmpty && failure == nil {
            guard condition.wait(until: deadline) else { throw ProbeError("Test data link timed out") }
        }
        if let failure { throw failure }
        return values.removeFirst()
    }
}

final class HistoryBatchTestPair<Reservation: HistoryBatchTestReservation>: @unchecked Sendable {
    let width: Int
    let books = [ClusterBatchLaneBook<Reservation>(), ClusterBatchLaneBook<Reservation>()]
    fileprivate let headers = HistoryBatchTestPipe(), replies = HistoryBatchTestPipe(), payloads = HistoryBatchTestPipe()
    var executors: [HistoryBatchTestExecutor<Reservation>] = [], hosts: [HistoryBatchTestHost<Reservation>] = []
    private let lock = NSLock()
    private var flags = Set<String>(), clock: UInt64 = 1
    private var errors: [String] = []
    private(set) var maxDecodeWidth = 0
    init(width: Int) throws {
        self.width = width
        executors = (0...1).map { HistoryBatchTestExecutor<Reservation>(pair: self, rank: $0) }
        hosts = (0...1).map { HistoryBatchTestHost<Reservation>(pair: self, rank: $0) }
    }
    func flag(_ key: String) -> Bool { lock.withLock { flags.contains(key) } }
    func set(_ key: String) { _ = lock.withLock { flags.insert(key) } }
    func setTime(_ value: UInt64) { lock.withLock { clock = value } }
    func now() -> UInt64 { lock.withLock { clock } }
    func decoded(_ width: Int) { lock.withLock { maxDecodeWidth = max(maxDecodeWidth, width) } }
    func request(length: Int, chunk: Int, output: Int, stops: Set<Int> = []) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "gptoss-schedule-cpu", vocabularySize: 64,
            hiddenSize: 64, activationDType: "bfloat16", maximumPromptTokens: 512, maximumChunkTokens: 32,
            maximumOutputTokens: 32, maximumContextTokens: 1024)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: (0..<length).map { $0 % 63 + 1 },
            chunkSize: chunk, outputCount: output, stopTokenIDs: stops)
    }
    func reserve(_ request: QwenLayerStageGenerationRequest, rank: Int? = nil, deadline: UInt64 = UInt64.max) throws {
        for index in rank.map({ [$0] }) ?? [0, 1] {
            try books[index].reserve(request.requestID, Reservation.fixture(request, deadline: deadline), lanes: width)
            try books[index].start(request.requestID)
        }
    }
    func run() throws {
        let group = DispatchGroup()
        for rank in 0...1 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let driver = try IndependentHistoryBatchDriver(rank: rank, capacity: self.width, vocabulary: 64,
                        book: self.books[rank], executor: self.executors[rank], now: self.now)
                    try driver.serve(host: self.hosts[rank], check: {})
                } catch {
                    self.lock.withLock { self.errors.append(String(describing: error)) }
                    self.headers.fail(error); self.replies.fail(error); self.payloads.fail(error)
                }
            }
        }
        guard group.wait(timeout: .now() + 15) == .success else { throw ProbeError("Test driver pair timed out") }
        if !errors.isEmpty { throw ProbeError(errors.joined(separator: "; ")) }
    }
}

final class HistoryBatchTestSession: IndependentHistoryBatchSession {
    let request: QwenLayerStageGenerationRequest
    var frames: [QwenLayerStageFrame] = [], history: [Int] = []
    var committedTokens: Int { history.count }
    var isClosed = false, isFailed = false, failCleanup = false
    var nextFrame: QwenLayerStageFrame? { try? request.frame(sequence: frames.count) }
    init(_ request: QwenLayerStageGenerationRequest) { self.request = request }
    static func next(_ history: [Int]) -> Int { (history.reduce(0, +) + history.count * 7) % 64 }
    static func oracle(_ request: QwenLayerStageGenerationRequest) -> [Int] {
        var history = request.promptTokenIDs, selected: [Int] = []
        for _ in 0..<request.outputCount {
            let token = next(history); selected.append(token)
            if request.stopTokenIDs.contains(token) { break }
            history.append(token)
        }
        return selected
    }
    func advance(_ tokens: [Int]) throws {
        guard !isClosed, let frame = nextFrame, frame.tokenCount == tokens.count,
              frame.tokenOffset == history.count else { throw ProbeError("Test session frame mismatch") }
        if frame.phase == .prefill {
            guard tokens == Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]) else {
                throw ProbeError("Test session prompt mismatch")
            }
        } else if tokens != [Self.next(history)] { throw ProbeError("Test session decode history mismatch") }
        history += tokens; frames.append(frame)
    }
    func finishGeneration(_ reason: QwenLayerStageGenerationFinishReason, selectedTokenCount: Int, lastTokenID: Int) throws {
        guard lastTokenID == Self.next(history), selectedTokenCount == frames.count - request.prefillFrameCount + 1 else {
            throw ProbeError("Test finish differs from committed history")
        }
        guard !failCleanup else { throw ProbeError("Injected native retirement failure") }
        isClosed = true
    }
    func cancel() throws {
        isFailed = true
        guard !failCleanup else { throw ProbeError("Injected native retirement failure") }
        isClosed = true
    }
}

final class HistoryBatchTestExecutor<Reservation: HistoryBatchTestReservation>: IndependentHistoryBatchExecutor {
    unowned let pair: HistoryBatchTestPair<Reservation>
    let rank: Int
    var sessions: [UUID: HistoryBatchTestSession] = [:], failCleanup = Set<UUID>()
    var afterDecode: ([UUID]) throws -> Void = { _ in }
    init(pair: HistoryBatchTestPair<Reservation>, rank: Int) { self.pair = pair; self.rank = rank }
    func open(lanes: Int) throws { guard lanes == pair.width else { throw ProbeError("Test opening width mismatch") } }
    func session(_ request: QwenLayerStageGenerationRequest) throws -> HistoryBatchTestSession {
        let session = HistoryBatchTestSession(request); session.failCleanup = failCleanup.contains(request.requestID)
        sessions[request.requestID] = session; return session
    }
    func sendHeader(_ value: QwenBatchWire.Header) throws { pair.headers.send(value.words) }
    func receiveHeader(step: Int) throws -> QwenBatchWire.Header {
        try .init(words: pair.headers.receive(), expectedStep: step, lanes: pair.width)
    }
    func sendReply(_ value: QwenBatchWire.Reply) throws { pair.replies.send(value.words) }
    func receiveReply(step: Int) throws -> QwenBatchWire.Reply {
        try .init(words: pair.replies.receive(), expectedStep: step, lanes: pair.width)
    }
    private func payload(_ sessions: [HistoryBatchTestSession], tokens: [Int], lanes: [QwenBatchRecordBinding.Lane], step: Int) -> [Int32] {
        [Int32(step)] + zip(sessions, lanes).flatMap { session, lane in
            QwenBatchWire.fingerprintWords(session.request.fingerprint)
                + [Int32(lane.slot), Int32(lane.committedTokens), Int32(lane.selectedTokens)]
        } + tokens.map(Int32.init)
    }
    func produceDecode(_ sessions: [HistoryBatchTestSession], tokens: [Int], lanes: [QwenBatchRecordBinding.Lane], step: Int) throws {
        let value = payload(sessions, tokens: tokens, lanes: lanes, step: step)
        for (session, token) in zip(sessions, tokens) { try session.advance([token]) }
        pair.decoded(sessions.count); pair.payloads.send(value)
    }
    func consumeDecode(_ sessions: [HistoryBatchTestSession], requests: [QwenLayerStageGenerationRequest], tokens: [Int],
                       lanes: [QwenBatchRecordBinding.Lane], step: Int) throws -> [Int] {
        guard try pair.payloads.receive() == payload(sessions, tokens: tokens, lanes: lanes, step: step) else {
            throw ProbeError("Test decode record binding mismatch")
        }
        for (session, token) in zip(sessions, tokens) { try session.advance([token]) }
        try afterDecode(requests.map(\.requestID))
        return sessions.map { HistoryBatchTestSession.next($0.history) }
    }
    func producePrefill(_ session: HistoryBatchTestSession, request: QwenLayerStageGenerationRequest, frame: QwenLayerStageFrame,
                        lane: QwenBatchRecordBinding.Lane, step: Int) throws {
        let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
        let value = payload([session], tokens: tokens, lanes: [lane], step: step)
        try session.advance(tokens); pair.payloads.send(value)
    }
    func consumePrefill(_ session: HistoryBatchTestSession, request: QwenLayerStageGenerationRequest, frame: QwenLayerStageFrame,
                        lane: QwenBatchRecordBinding.Lane, step: Int) throws -> Int? {
        let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
        guard try pair.payloads.receive() == payload([session], tokens: tokens, lanes: [lane], step: step) else {
            throw ProbeError("Test prefill record binding mismatch")
        }
        try session.advance(tokens)
        return frame.finalPromptChunk ? HistoryBatchTestSession.next(session.history) : nil
    }
}

final class HistoryBatchTestHost<Reservation: HistoryBatchTestReservation>: QwenBatchServingHost {
    unowned let pair: HistoryBatchTestPair<Reservation>
    let rank: Int
    var tokens: [UUID: [Int]] = [:], finished: [UUID: ClusterWorkerFinishReason] = [:], left = Set<UUID>()
    var onControl: () throws -> Void = {}, onToken: (UUID, Int) throws -> Void = { _, _ in }
    var answer: (UUID) -> Bool? = { _ in true }
    init(pair: HistoryBatchTestPair<Reservation>, rank: Int) { self.pair = pair; self.rank = rank }
    func serviceControl() throws { try onControl() }
    func pollDecision(_ id: UUID) throws -> Bool? { answer(id) }
    func awaitDecisions(_ ids: [UUID]) throws -> [UUID: Bool] { throw ProbeError("Driver blocked on token credits") }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
        guard ordinal == tokens[requestID, default: []].count,
              let session = pair.executors[rank].sessions[requestID], committedTokens == session.committedTokens else {
            throw ProbeError("Published token frontier differs from its native session")
        }
        tokens[requestID, default: []].append(tokenID); try onToken(requestID, ordinal)
    }
    private func checkRetired(_ id: UUID) throws {
        guard pair.books[rank].reservation(id) == nil, pair.executors[rank].sessions[id]?.isClosed == true else {
            throw ProbeError("Retirement ACK preceded native cleanup or charge release")
        }
    }
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {
        try checkRetired(requestID); finished[requestID] = reason
    }
    func publishLeft(requestID: UUID) throws { try checkRetired(requestID); left.insert(requestID) }
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {
        throw ProbeError("GPT-OSS batch unexpectedly published prefix state")
    }
}
