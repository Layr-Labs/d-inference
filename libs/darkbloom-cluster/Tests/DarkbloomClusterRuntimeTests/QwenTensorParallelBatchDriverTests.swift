import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

extension HistoryBatchTestSession: QwenTensorParallelBatchLane {}

@Suite(.serialized)
struct QwenTensorParallelBatchDriverTests {
    struct Reservation: QwenTensorParallelBatchReservation {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64
        var laneStateBytes: Int { 100 }
        var ready: () -> Bool = { true }
        var joinable: Bool { ready() }
    }
    final class Link: @unchecked Sendable {
        let condition = NSCondition()
        var values: [Int: [Float]] = [:], result: [Float] = []
        var leaving = 0, failure: Error?
        func fail(_ error: Error) { condition.withLock { failure = error; condition.broadcast() } }
        func sum(_ words: [Float], rank: Int) throws -> [Float] {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(10)
            while leaving > 0 && failure == nil {
                guard condition.wait(until: deadline) else { throw ProbeError("TP test prior exchange timed out") }
            }
            if let failure { throw failure }
            guard values[rank] == nil else { throw ProbeError("TP test rank contributed twice") }
            values[rank] = words
            if values.count == 2 {
                guard values[0]!.count == values[1]!.count else { throw ProbeError("TP test collective shapes differ") }
                result = zip(values[0]!, values[1]!).map(+); leaving = 2; condition.broadcast()
            } else {
                while leaving == 0 && failure == nil {
                    guard condition.wait(until: deadline) else { throw ProbeError("TP test peer exchange timed out") }
                }
            }
            if let failure { throw failure }
            let output = result; leaving -= 1
            if leaving == 0 { values = [:]; result = []; condition.broadcast() }
            return output
        }
    }
    final class Pair: @unchecked Sendable {
        let capacity: Int
        let link = Link(), lock = NSLock()
        let books = [ClusterBatchLaneBook<Reservation>(), ClusterBatchLaneBook<Reservation>()]
        var native: [Executor] = [], hosts: [Host] = []
        var errors: [String] = [], flags = Set<String>()
        var clock: UInt64 = 1
        init(_ capacity: Int) {
            self.capacity = capacity
            native = (0...1).map { Executor(pair: self, rank: $0) }
            hosts = (0...1).map { Host(pair: self, rank: $0) }
        }
        func flag(_ key: String) -> Bool { lock.withLock { flags.contains(key) } }
        func set(_ key: String) { _ = lock.withLock { flags.insert(key) } }
        func now() -> UInt64 { lock.withLock { clock } }
        func request(length: Int = 3, output: Int = 24, stops: Set<Int> = []) throws -> QwenLayerStageGenerationRequest {
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-driver-test", vocabularySize: 64,
                hiddenSize: 64, activationDType: "bfloat16", maximumPromptTokens: 128, maximumChunkTokens: 16,
                maximumOutputTokens: 64, maximumContextTokens: 256)
            return try .init(profile: profile, requestID: UUID(), promptTokenIDs: (0..<length).map { $0 % 63 + 1 },
                             chunkSize: 4, outputCount: output, stopTokenIDs: stops)
        }
        func reserve(_ request: QwenLayerStageGenerationRequest, rank: Int? = nil, deadline: UInt64 = .max, ready: @escaping () -> Bool = { true }) throws {
            for i in rank.map({ [$0] }) ?? [0, 1] {
                try books[i].reserve(request.requestID, Reservation(request: request, deadline: deadline, ready: ready), lanes: capacity)
                try books[i].start(request.requestID)
            }
        }
        func run() throws {
            let group = DispatchGroup()
            for rank in 0...1 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    do {
                        let driver = try QwenTensorParallelBatchDriver(executor: self.native[rank], book: self.books[rank],
                            capacity: self.capacity, vocabulary: 64, now: self.now)
                        try driver.serve(host: self.hosts[rank], check: {})
                    } catch {
                        self.lock.withLock { self.errors.append(String(describing: error)) }; self.link.fail(error)
                    }
                }
            }
            guard group.wait(timeout: .now() + 15) == .success else { throw ProbeError("TP test driver timed out") }
            if !errors.isEmpty { throw ProbeError(errors.joined(separator: "; ")) }
        }
    }
    final class Executor: QwenTensorParallelBatchExecutor {
        typealias Reservation = QwenTensorParallelBatchDriverTests.Reservation
        unowned let pair: Pair
        let rank: Int
        var sessions: [UUID: HistoryBatchTestSession] = [:]
        var maximumWidth = 0, failCleanup = Set<UUID>()
        var afterDecode: ([UUID]) throws -> Void = { _ in }
        var preparing: (UUID) throws -> Void = { _ in }
        init(pair: Pair, rank: Int) { self.pair = pair; self.rank = rank }
        func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float] { try check(); return try pair.link.sum(words, rank: rank) }
        func discard(_ reservation: Reservation) throws {
            pair.set("closed-\(rank)-\(reservation.request.requestID)")
        }
        func open(_ reservation: Reservation, check: () throws -> Void) throws -> HistoryBatchTestSession {
            // Models an already-announced bilateral media phase. Individual
            // cancellation is deferred until this phase has completed.
            try preparing(reservation.request.requestID)
            let session = HistoryBatchTestSession(reservation.request)
            session.failCleanup = failCleanup.contains(reservation.request.requestID)
            sessions[reservation.request.requestID] = session; return session
        }
        func prefill(_ lane: HistoryBatchTestSession, frame: QwenLayerStageFrame, check: () throws -> Void) throws -> Int? {
            try lane.advance(Array(lane.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]))
            return frame.finalPromptChunk ? HistoryBatchTestSession.next(lane.history) : nil
        }
        func decode(_ lanes: [HistoryBatchTestSession], tokens: [Int], check: () throws -> Void) throws -> [Int] {
            for (lane, token) in zip(lanes, tokens) { try lane.advance([token]) }
            maximumWidth = max(maximumWidth, lanes.count)
            try afterDecode(lanes.map { $0.request.requestID })
            return lanes.map { HistoryBatchTestSession.next($0.history) }
        }
        func retire(_ lane: HistoryBatchTestSession, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws {
            if let reason, let last { try lane.finishGeneration(reason, selectedTokenCount: selected, lastTokenID: last) }
            else { try lane.cancel() }
            pair.set("closed-\(rank)-\(lane.request.requestID)")
        }
        func confirmedRetirement(_ lane: HistoryBatchTestSession, clean: Bool) throws {
            let id = lane.request.requestID
            guard pair.flag("closed-0-\(id)"), pair.flag("closed-1-\(id)"),
                  pair.books[rank].reservation(id) != nil else {
                throw ProbeError("Prefix transfer preceded bilateral drain or followed charge release")
            }
            pair.set("prefix-\(clean)-\(rank)-\(id)")
        }
        func takeLogprobs(_ lane: HistoryBatchTestSession) throws -> ClusterWorkerTokenLogprobs? { nil }
    }
    final class Host: QwenBatchServingHost {
        unowned let pair: Pair
        let rank: Int
        var tokens: [UUID: [Int]] = [:], finished: [UUID: ClusterWorkerFinishReason] = [:], left = Set<UUID>()
        var onControl: () throws -> Void = {}, onToken: (UUID, Int) throws -> Void = { _, _ in }
        var answer: (UUID) -> Bool? = { _ in true }
        init(pair: Pair, rank: Int) { self.pair = pair; self.rank = rank }
        func serviceControl() throws { try onControl() }
        func pollDecision(_ id: UUID) throws -> Bool? { answer(id) }
        func awaitDecisions(_ ids: [UUID]) throws -> [UUID: Bool] { throw ProbeError("TP driver blocked on all credits") }
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
            guard ordinal == tokens[requestID, default: []].count,
                  pair.native[rank].sessions[requestID]?.committedTokens == committedTokens else {
                throw ProbeError("TP publication differs from native frontier")
            }
            tokens[requestID, default: []].append(tokenID); try onToken(requestID, ordinal)
        }
        private func retired(_ id: UUID) throws {
            guard pair.books[rank].reservation(id) == nil,
                  pair.flag("closed-0-\(id)"), pair.flag("closed-1-\(id)") else {
                throw ProbeError("TP retirement ACK preceded bilateral native drain")
            }
        }
        func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {
            try retired(requestID); finished[requestID] = reason; pair.set("finished-\(requestID)")
        }
        func publishLeft(requestID: UUID) throws { try retired(requestID); left.insert(requestID) }
        func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {
            throw ProbeError("TP fixture unexpectedly restored a prefix")
        }
    }

    @Test func bothRanksBatchIndependentHistoriesAndDrainBeforeAcknowledging() throws {
        for width in [2, 4, 8] {
            let pair = Pair(width)
            let requests = try (0..<width).map { try pair.request(length: $0 + 2, output: 32) }
            for request in requests { try pair.reserve(request) }
            try pair.run()
            for request in requests {
                #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
                for rank in 0...1 {
                    #expect(pair.hosts[rank].finished[request.requestID] == .length)
                    #expect(pair.native[rank].maximumWidth == width)
                    #expect(pair.flag("prefix-true-\(rank)-\(request.requestID)"))
                }
            }
            #expect(pair.books.allSatisfy { $0.isEmpty })
        }
    }

    @Test func aDelayedPeerStartAndPendingCreditDoNotBlockLaterLanes() throws {
        let pair = Pair(4), held = try pair.request(output: 8), later = try pair.request(length: 7, output: 8)
        try pair.reserve(held)
        pair.hosts[0].answer = { id in id == held.requestID && !pair.flag("finished-\(later.requestID)") ? nil : true }
        pair.hosts[0].onControl = { pair.lock.withLock { pair.clock += 250_000 } }
        pair.hosts[0].onToken = { id, _ in
            if id == held.requestID && !pair.flag("joined") {
                pair.set("joined"); try pair.reserve(later, rank: 0)
            }
        }
        pair.hosts[1].onControl = {
            if pair.flag("joined") && !pair.flag("peer-started") { pair.set("peer-started"); try pair.reserve(later, rank: 1) }
        }
        try pair.run()
        #expect(pair.hosts[0].tokens[held.requestID] == HistoryBatchTestSession.oracle(held))
        #expect(pair.hosts[0].tokens[later.requestID] == HistoryBatchTestSession.oracle(later))
    }

    @Test func staggeredOwnerCreditsFormOneDecodeRectangleOnBothRanks() throws {
        let pair = Pair(2), first = try pair.request(), second = try pair.request()
        try pair.reserve(first); try pair.reserve(second)
        var tick = 0, readyAt: [UUID: Int] = [:]
        pair.hosts[0].onControl = {
            tick += 1
            pair.lock.withLock { pair.clock += 250_000 }
        }
        // Each real publication gets a later owner answer. The two initial
        // prefills stagger these answers; immediate scheduling alternates
        // singleton decodes forever instead of forming a rectangle.
        pair.hosts[0].onToken = { id, _ in readyAt[id] = tick + 2 }
        pair.hosts[0].answer = { id in tick >= readyAt[id, default: .max] ? true : nil }
        try pair.run()
        for rank in 0...1 {
            #expect(pair.native[rank].maximumWidth == 2)
            #expect(pair.books[rank].isEmpty)
        }
        for request in [first, second] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
        }
    }

    @Test func silentOwnerCreditCannotHoldAReadyLaneBeyondTheWindow() throws {
        let pair = Pair(2), held = try pair.request(output: 4), live = try pair.request(output: 4)
        try pair.reserve(held); try pair.reserve(live)
        let tick: UInt64 = 250_000
        var partialReadyAt: UInt64?, firstSoloDecodeAt: UInt64?
        pair.hosts[0].onControl = { pair.lock.withLock { pair.clock += tick } }
        pair.hosts[0].answer = { id in
            if id == held.requestID && !pair.flag("finished-\(live.requestID)") { return nil }
            if id == live.requestID && partialReadyAt == nil { partialReadyAt = pair.now() }
            return true
        }
        pair.native[0].afterDecode = { ids in
            if ids == [live.requestID] && firstSoloDecodeAt == nil {
                firstSoloDecodeAt = pair.now()
                #expect(pair.hosts[0].tokens[held.requestID]?.count == 1)
            }
        }
        try pair.run()
        let began = try #require(partialReadyAt), decoded = try #require(firstSoloDecodeAt)
        #expect(decoded - began >= QwenBatchDecodeCoalescing.windowNanoseconds)
        #expect(decoded - began <= QwenBatchDecodeCoalescing.windowNanoseconds + tick)
        for request in [held, live] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
        }
        #expect(pair.books.allSatisfy { $0.isEmpty })
    }

    @Test func cancellationAndDeadlineInterruptCreditCoalescing() throws {
        for expires in [false, true] {
            let pair = Pair(2), held = try pair.request(), live = try pair.request(output: 4)
            let tick: UInt64 = 250_000
            let deadline: UInt64 = expires ? 1_250_000 : .max
            try pair.reserve(held, deadline: deadline); try pair.reserve(live)
            var partialReadyAt: UInt64?, firstDecodeAt: UInt64?
            pair.hosts[0].answer = { id in
                if id == held.requestID { return nil }
                if partialReadyAt == nil { partialReadyAt = pair.now() }
                return true
            }
            pair.hosts[0].onControl = {
                pair.lock.withLock { pair.clock += tick }
                if !expires, let began = partialReadyAt, pair.now() > began {
                    pair.books[0].cancel(held.requestID)
                }
            }
            pair.native[0].afterDecode = { ids in
                if ids.contains(live.requestID) && firstDecodeAt == nil { firstDecodeAt = pair.now() }
            }
            try pair.run()
            let began = try #require(partialReadyAt), decoded = try #require(firstDecodeAt)
            #expect(decoded - began < QwenBatchDecodeCoalescing.windowNanoseconds)
            for rank in 0...1 {
                #expect(pair.hosts[rank].left.contains(held.requestID))
                #expect(pair.hosts[rank].finished[live.requestID] == .length)
                #expect(pair.books[rank].isEmpty)
            }
            #expect(pair.hosts[0].tokens[live.requestID] == HistoryBatchTestSession.oracle(live))
        }
    }

    @Test func followerCancellationAndDeadlineRetireOnlyTheirLanes() throws {
        let pair = Pair(4), cancelled = try pair.request(), expired = try pair.request(), live = try pair.request()
        try pair.reserve(cancelled); try pair.reserve(expired, deadline: 10); try pair.reserve(live)
        pair.native[1].afterDecode = { ids in
            if ids.contains(cancelled.requestID), !pair.flag("cancelled") {
                pair.set("cancelled"); pair.books[1].cancel(cancelled.requestID)
                pair.lock.withLock { pair.clock = 11 }
            }
        }
        try pair.run()
        for rank in 0...1 {
            #expect(pair.hosts[rank].left.contains(cancelled.requestID))
            #expect(pair.flag("prefix-false-\(rank)-\(cancelled.requestID)"))
            #expect(!pair.flag("prefix-true-\(rank)-\(cancelled.requestID)"))
            #expect(pair.hosts[rank].left.contains(expired.requestID))
            #expect(pair.hosts[rank].finished[live.requestID] == .length)
        }
        #expect(pair.hosts[0].tokens[live.requestID] == HistoryBatchTestSession.oracle(live))
    }

    @Test func cancelledAndExpiredUnjoinedPreparationDrainsWithoutOpeningNativeHistory() throws {
        let pair = Pair(4), cancelled = try pair.request(), expired = try pair.request(), live = try pair.request()
        try pair.reserve(cancelled, ready: { pair.flag("prepared") })
        try pair.reserve(expired, deadline: 10, ready: { pair.flag("prepared") })
        try pair.reserve(live)
        pair.hosts[0].onToken = { id, ordinal in
            if id == live.requestID && ordinal == 1 {
                pair.books[0].cancel(cancelled.requestID)
                pair.lock.withLock { pair.clock = 11 }
                // A cancelled asynchronous producer becomes joinable only
                // after it stopped retaining its admitted host buffers.
                pair.set("prepared")
            }
        }
        try pair.run()
        for rank in 0...1 {
            #expect(pair.native[rank].sessions[cancelled.requestID] == nil)
            #expect(pair.native[rank].sessions[expired.requestID] == nil)
            #expect(pair.hosts[rank].left.contains(cancelled.requestID))
            #expect(!pair.flag("prefix-false-\(rank)-\(cancelled.requestID)"))
            #expect(!pair.flag("prefix-true-\(rank)-\(cancelled.requestID)"))
            #expect(pair.hosts[rank].left.contains(expired.requestID))
            #expect(pair.books[rank].isEmpty)
        }
        #expect(pair.hosts[0].tokens[cancelled.requestID] == nil && pair.hosts[0].tokens[expired.requestID] == nil)
        #expect(pair.hosts[0].tokens[live.requestID] == HistoryBatchTestSession.oracle(live))
    }

    @Test func cancellationAfterOpenVoteFinishesPreparationAndPreservesSurvivors() throws {
        let pair = Pair(4), cancelled = try pair.request(), expired = try pair.request(), live = try pair.request()
        try pair.reserve(cancelled); try pair.reserve(expired, deadline: 10); try pair.reserve(live)
        for rank in 0...1 {
            pair.native[rank].preparing = { id in
                if id == cancelled.requestID {
                    // The cancellation arrives after the driver's shared
                    // vote, while both ranks already owe this preparation.
                    if rank == 1 { pair.books[1].cancel(id) }
                    _ = try pair.link.sum([1], rank: rank)
                    pair.set("prepared-\(rank)-\(id)")
                }
                if id == expired.requestID {
                    if rank == 1 { pair.lock.withLock { pair.clock = 11 } }
                    _ = try pair.link.sum([1], rank: rank)
                }
            }
        }
        try pair.run()
        for rank in 0...1 {
            #expect(pair.flag("prepared-\(rank)-\(cancelled.requestID)"))
            #expect(pair.native[rank].sessions[cancelled.requestID]?.isClosed == true)
            #expect(pair.hosts[rank].left.contains(cancelled.requestID))
            #expect(pair.flag("prefix-false-\(rank)-\(cancelled.requestID)"))
            #expect(!pair.flag("prefix-true-\(rank)-\(cancelled.requestID)"))
            #expect(pair.hosts[rank].left.contains(expired.requestID))
            #expect(pair.hosts[rank].finished[live.requestID] == .length)
            #expect(pair.books[rank].isEmpty)
        }
        #expect(pair.hosts[0].tokens[cancelled.requestID] == nil)
        #expect(pair.hosts[0].tokens[expired.requestID] == nil)
        #expect(pair.hosts[0].tokens[live.requestID] == HistoryBatchTestSession.oracle(live))
    }

    @Test func failedNativeRetirementNeverPublishesSuccessOrReleasesThatCharge() throws {
        let pair = Pair(2), request = try pair.request(output: 2)
        pair.native[1].failCleanup.insert(request.requestID)
        try pair.reserve(request)
        #expect(throws: ProbeError.self) { try pair.run() }
        #expect(pair.books[1].reservation(request.requestID) != nil)
        #expect(pair.hosts.allSatisfy { $0.finished.isEmpty && $0.left.isEmpty })
    }

    @Test func controlWordsPreserveEveryInt32BitAndRejectMalformedAndStaleFrames() throws {
        var slot = QwenBatchWire.Slot(state: .active, requestID: UUID())
        slot.fingerprintWords = [Int32.min, Int32.max, -1, 0]
        let plan = QwenBatchWire.Header(step: 17, stop: false, slots: [slot, .init()])
        let report = QwenBatchWire.Reply(step: 17, tokens: [3, -1], cancelledMask: 1)
        let a = try QwenTensorParallelBatchWire.contribution(rank: 0, plan: plan, report: nil)
        let b = try QwenTensorParallelBatchWire.contribution(rank: 1, plan: nil, report: report)
        let sum = zip(a, b).map(+)
        let result = try QwenTensorParallelBatchWire.read(sum, step: 17, lanes: 2)
        #expect(result.0 == plan && result.1 == report)
        #expect(throws: ProbeError.self) { try QwenTensorParallelBatchWire.read(sum, step: 18, lanes: 2) }
        for bad: Float in [.nan, .infinity, -1, 65536, 1.5] {
            var corrupt = sum; corrupt[4] = bad
            #expect(throws: ProbeError.self) { try QwenTensorParallelBatchWire.read(corrupt, step: 17, lanes: 2) }
        }
    }
}
