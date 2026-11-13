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
        /// Every completed collective's word count, in order.
        var lengths: [Int] = []
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
                result = zip(values[0]!, values[1]!).map(+); leaving = 2; lengths.append(result.count); condition.broadcast()
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
        /// Each rank's driver builds steps ahead (`QwenTensorParallelBatchDriver.serveAhead`).
        let ahead: [Bool]
        /// Each rank's live memory check at a step boundary (D6): true when it refuses.
        var memoryRefused: [() throws -> Bool] = [{ false }, { false }]
        init(_ capacity: Int, ahead: Bool = false, aheadByRank: [Bool]? = nil) {
            self.capacity = capacity
            self.ahead = aheadByRank ?? [ahead, ahead]
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
                            capacity: self.capacity, vocabulary: 64, buildsAhead: self.ahead[rank], now: self.now)
                        try driver.serve(host: self.hosts[rank], memoryRefused: self.memoryRefused[rank], check: {})
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
        /// Requests opened as assisted rows, and each rectangle whose selection sum carried control words.
        var assisted = Set<UUID>(), folded: [[UUID]] = []
        var afterDecode: ([UUID]) throws -> Void = { _ in }
        var preparing: (UUID) throws -> Void = { _ in }
        var carriesSelectionControl = true
        /// Build-ahead: what each rank submitted and read, in order (`submit N` / `read N`, N the rectangle's ordinal).
        var events: [String] = []
        private var submissions = 0
        var buildsAhead: Bool { pair.ahead[rank] }
        final class Submitted {
            let ordinal: Int, width: Int, selected: [Int], summed: [Float]
            init(ordinal: Int, width: Int, selected: [Int], summed: [Float]) {
                self.ordinal = ordinal; self.width = width; self.selected = selected; self.summed = summed
            }
        }
        init(pair: Pair, rank: Int) { self.pair = pair; self.rank = rank }
        /// Submits a rectangle at once (the fake selects eagerly) and keeps its sum for `readDecode`; both ranks
        /// submit in the same order, so the selection sum pairs up as the lazy one does.
        func submitDecode(_ lanes: [HistoryBatchTestSession], inputs: QwenBatchDecodeInputs<Submitted>, control: () throws -> [Float],
                          check: () throws -> Void) throws -> Submitted {
            let tokens: [Int]
            switch inputs {
            case .tokens(let values): tokens = values
            case .after(let previous, let rows): tokens = rows.map { previous.selected[$0] }
            }
            for (lane, token) in zip(lanes, tokens) { try lane.advance([token]) }
            maximumWidth = max(maximumWidth, lanes.count)
            try afterDecode(lanes.map { $0.request.requestID })
            let selected = lanes.map { HistoryBatchTestSession.next($0.history) }
            folded.append(lanes.map { $0.request.requestID })
            submissions += 1; events.append("submit \(submissions)")
            if submissions == failSubmissionAt { throw ProbeError("Injected failure while a step is submitted") }
            let sum = try pair.link.sum(selected.map { rank == 0 ? Float($0) : 0 } + (try control()), rank: rank)
            return Submitted(ordinal: submissions, width: lanes.count, selected: selected, summed: sum)
        }
        /// Test hooks: corrupt the last control word this rank reads of submission N; fail submission N,
        /// or the read of submission N.
        var corruptDecisionAt: Int?, failSubmissionAt: Int?, failReadAt: Int?
        /// The largest gap between the native frontier and a publication (`Host.publishToken`).
        var widestPublicationGap = 0
        func readDecode(_ submitted: Submitted, check: () throws -> Void) throws -> (tokens: [Int], control: [Float]) {
            events.append("read \(submitted.ordinal)")
            if submitted.ordinal == failReadAt { throw ProbeError("Injected failure reading a submitted step") }
            var control = Array(submitted.summed.dropFirst(submitted.width))
            if submitted.ordinal == corruptDecisionAt, !control.isEmpty { control[control.count - 1] = 2 }
            return (submitted.summed.prefix(submitted.width).map { Int($0) }, control)
        }
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
            session.plainSelection = !assisted.contains(reservation.request.requestID)
            session.aheadDiscardLimit = pair.ahead[rank] ? QwenTensorParallelBatchDriver<Executor>.aheadHeldLimit : 1
            sessions[reservation.request.requestID] = session; return session
        }
        func prefill(_ lane: HistoryBatchTestSession, frame: QwenLayerStageFrame, check: () throws -> Void) throws -> Int? {
            try lane.advance(Array(lane.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]))
            return frame.finalPromptChunk ? HistoryBatchTestSession.next(lane.history) : nil
        }
        func decode(_ lanes: [HistoryBatchTestSession], tokens: [Int], check: () throws -> Void) throws -> [Int] {
            try decode(lanes, tokens: tokens, control: { nil }, check: check).tokens
        }
        func decode(_ lanes: [HistoryBatchTestSession], tokens: [Int], control: () throws -> [Float]?,
                    check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?) {
            for (lane, token) in zip(lanes, tokens) { try lane.advance([token]) }
            maximumWidth = max(maximumWidth, lanes.count)
            try afterDecode(lanes.map { $0.request.requestID })
            let selected = lanes.map { HistoryBatchTestSession.next($0.history) }
            guard let words = try control() else { return (selected, nil) }
            guard carriesSelectionControl else { throw ProbeError("Control words reached an executor that cannot carry them") }
            folded.append(lanes.map { $0.request.requestID })
            // The selection's own sum: rank 0's tokens, rank 1's zeros, then both ranks' control words.
            let sum = try pair.link.sum(selected.map { rank == 0 ? Float($0) : 0 } + words, rank: rank)
            return (sum.prefix(lanes.count).map { Int($0) }, Array(sum.dropFirst(lanes.count)))
        }
        func retire(_ lane: HistoryBatchTestSession, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws {
            if let reason, let last {
                let decoded = lane.frames.count - lane.request.prefillFrameCount
                try lane.finishGeneration(reason, selectedTokenCount: selected, lastTokenID: last, discarded: decoded + 1 - selected)
            } else { try lane.cancel() }
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
        var aborted: [UUID: ClusterWorkerAbort] = [:]
        var onControl: () throws -> Void = {}, onToken: (UUID, Int) throws -> Void = { _, _ in }
        var answer: (UUID) -> Bool? = { _ in true }
        init(pair: Pair, rank: Int) { self.pair = pair; self.rank = rank }
        func serviceControl() throws { try onControl() }
        func pollDecision(_ id: UUID) throws -> Bool? { answer(id) }
        func awaitDecisions(_ ids: [UUID]) throws -> [UUID: Bool] { throw ProbeError("TP driver blocked on all credits") }
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
            // Read-then-build publishes at the native frontier. Build-ahead may run ahead of it by the held
            // tokens after the one published (at most `aheadHeldLimit` - 1) and two unread steps.
            let native = pair.native[rank].sessions[requestID]?.committedTokens ?? -1
            let ahead = pair.ahead[rank] ? QwenTensorParallelBatchDriver<Executor>.aheadHeldLimit + 1 : 0
            pair.native[rank].widestPublicationGap = max(pair.native[rank].widestPublicationGap, native - committedTokens)
            guard ordinal == tokens[requestID, default: []].count,
                  (committedTokens...(committedTokens + ahead)).contains(native) else {
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
        func publishAborted(requestID: UUID, abort: ClusterWorkerAbort) throws {
            try retired(requestID); aborted[requestID] = abort
        }
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

    /// D6, tensor parallel: a rank's live memory check refuses at a step
    /// boundary. The newest running lane alone leaves, on both ranks, with
    /// the refusing rank (rank 1's lane rides its report's memory mask); its
    /// state is retired as a cancelled lane's and it is published as
    /// aborted, not left or finished. The older lane runs to its length and
    /// the driver serves on; read-then-build and build-ahead alike.
    @Test func aMemoryRefusalOnEitherRankEndsTheNewestLaneAloneOnBothRanks() throws {
        for (refusing, ahead) in [(0, false), (1, false), (0, true), (1, true)] {
            let pair = Pair(4, ahead: ahead)
            let older = try pair.request(output: 24), newer = try pair.request(length: 5, output: 24)
            try pair.reserve(older); try pair.reserve(newer)
            // Once both lanes hold tokens, the refusing rank's check refuses once: Gemma's own
            // tensor-parallel gate on a Mac whose memory is taken (a real refusal, no fault).
            pair.memoryRefused[refusing] = {
                let both = pair.native[refusing].sessions.count == 2
                    && pair.native[refusing].sessions.values.allSatisfy { $0.committedTokens > $0.request.promptCount + 2 }
                guard both, !pair.flag("refused"),
                      try TakenMemory.refusesLane({ try Gemma4TensorParallelResidentRuntime.requireLiveMemory(bytes: 0) })
                else { return false }
                pair.set("refused"); return true
            }
            try pair.run()
            let label = "rank \(refusing) refusing, ahead \(ahead)"
            for rank in 0...1 {
                #expect(pair.hosts[rank].aborted[newer.requestID] == .init(reason: .memory, rank: refusing), "\(label)")
                #expect(pair.hosts[rank].finished[newer.requestID] == nil && !pair.hosts[rank].left.contains(newer.requestID))
                #expect(pair.hosts[rank].finished[older.requestID] == .length, "\(label)")
                #expect(pair.flag("prefix-false-\(rank)-\(newer.requestID)"), "\(label)")
            }
            #expect(pair.hosts[0].tokens[older.requestID] == HistoryBatchTestSession.oracle(older))
            #expect((pair.hosts[0].tokens[newer.requestID]?.count ?? 0) < 24)
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

    final class Retired: @unchecked Sendable {
        let lock = NSLock()
        var byRank: [[UUID: ([Int], QwenLayerStageGenerationFinishReason)]] = [[:], [:]]
    }
    /// Each rank's retired selections (`retiredSelection`), per request.
    private func runRetiring(_ pair: Pair) throws -> [[UUID: ([Int], QwenLayerStageGenerationFinishReason)]] {
        let group = DispatchGroup(), retired = Retired()
        for rank in 0...1 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let driver = try QwenTensorParallelBatchDriver(executor: pair.native[rank], book: pair.books[rank],
                        capacity: pair.capacity, vocabulary: 64, buildsAhead: pair.ahead[rank], now: pair.now)
                    try driver.serve(host: pair.hosts[rank], retiredSelection: { id, tokens, reason in
                        retired.lock.withLock { retired.byRank[rank][id] = (tokens, reason) }
                    }, check: {})
                } catch {
                    pair.lock.withLock { pair.errors.append(String(describing: error)) }; pair.link.fail(error)
                }
            }
        }
        guard group.wait(timeout: .now() + 15) == .success else { throw ProbeError("TP test driver timed out") }
        if !pair.errors.isEmpty { throw ProbeError(pair.errors.joined(separator: "; ")) }
        return retired.lock.withLock { retired.byRank }
    }

    /// A steady decode step's plan and report ride its own selection sum:
    /// between the first and the last decode, one collective a step, of the
    /// rectangle's words and the control words, and no separate exchange.
    @Test func controlWordsRideTheSelectionSumOfEverySteadyDecodeStep() throws {
        let pair = Pair(1), request = try pair.request(output: 24)
        try pair.reserve(request)
        try pair.run()
        #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
        for rank in 0...1 { #expect(pair.hosts[rank].finished[request.requestID] == .length) }
        let folded = 1 + QwenTensorParallelBatchWire.words, lengths = pair.link.lengths
        let first = try #require(lengths.firstIndex(of: folded)), last = try #require(lengths.lastIndex(of: folded))
        // The prompt's step selects the first token; every other token is one folded step.
        #expect(lengths.filter { $0 == folded }.count == request.outputCount - 1)
        #expect(lengths[first...last].allSatisfy { $0 == folded })
        #expect(!lengths[first...last].contains(QwenTensorParallelBatchWire.words))
    }

    /// An executor whose selection sum cannot carry control words keeps the
    /// exchange every step, with today's tokens.
    @Test func anExecutorWithoutSelectionControlKeepsTheExchange() throws {
        let pair = Pair(1), request = try pair.request(output: 24)
        for rank in 0...1 { pair.native[rank].carriesSelectionControl = false }
        try pair.reserve(request)
        try pair.run()
        #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
        for rank in 0...1 {
            #expect(pair.hosts[rank].finished[request.requestID] == .length)
            #expect(pair.native[rank].folded.isEmpty)
        }
        #expect(!pair.link.lengths.contains(1 + QwenTensorParallelBatchWire.words))
    }

    /// Both ranks end a row at its stop token or output count from the tokens
    /// in the sum: the same kept tokens and reason, and no forward after it.
    @Test func eosAndLengthAreDerivedIdenticallyOnBothRanks() throws {
        // The stop token comes after every prompt step, so the step selecting it
        // carries the next plan: alone, and beside rows that end at their length.
        for width in [1, 4] {
            let pair = Pair(width)
            let oracle = HistoryBatchTestSession.oracle(try pair.request(length: 3, output: 24))
            let at = try #require(oracle.indices.last { !oracle.prefix($0).contains(oracle[$0]) })
            let stopping = try pair.request(length: 3, output: 24, stops: [oracle[at]])
            var expected: [(QwenLayerStageGenerationRequest, QwenLayerStageGenerationFinishReason)] = [(stopping, .eos)]
            if width > 1 {
                expected += [(try pair.request(length: 2, output: 9), .length), (try pair.request(length: 4, output: 16), .length)]
            }
            for (request, _) in expected { try pair.reserve(request) }
            let retired = try runRetiring(pair)
            for (request, reason) in expected {
                let tokens = HistoryBatchTestSession.oracle(request)
                #expect(pair.hosts[0].tokens[request.requestID] == tokens)
                for rank in 0...1 {
                    #expect(retired[rank][request.requestID]?.0 == tokens)
                    #expect(retired[rank][request.requestID]?.1 == reason)
                    #expect(pair.hosts[rank].finished[request.requestID] == .init(rawValue: reason.rawValue))
                    // Prompt frames, then one decode forward per token after the first: none after the end.
                    let session = try #require(pair.native[rank].sessions[request.requestID])
                    #expect(session.frames.count == request.prefillFrameCount + tokens.count - 1)
                }
            }
            #expect(at >= 4 && HistoryBatchTestSession.oracle(stopping).count == at + 1)
            #expect(pair.link.lengths.contains { $0 > QwenTensorParallelBatchWire.words })
        }
    }

    /// The owner's stop answer reaches the plan one step late: the row has
    /// already selected one more token, which is never published, and both
    /// ranks retire the tokens the owner saw as a clean client stop.
    @Test func aHostStopAppliesOneStepLateAndItsExtraTokenIsNeverPublished() throws {
        // Every decode after the first is a folded step; a stop answer to
        // a later token reaches the plan one step after the forward on it.
        for stopAfter in [2, 6] {
            let pair = Pair(1), stopped = try pair.request(output: 24)
            try pair.reserve(stopped)
            pair.hosts[0].answer = { id in pair.hosts[0].tokens[id]?.count == stopAfter ? false : true }
            let retired = try runRetiring(pair)
            let seen = Array(HistoryBatchTestSession.oracle(stopped).prefix(stopAfter))
            #expect(pair.hosts[0].tokens[stopped.requestID] == seen)
            for rank in 0...1 {
                #expect(retired[rank][stopped.requestID]?.0 == seen)
                #expect(retired[rank][stopped.requestID]?.1 == .clientStop)
                #expect(pair.hosts[rank].finished[stopped.requestID] == .clientStop)
                #expect(pair.flag("prefix-true-\(rank)-\(stopped.requestID)"))
                // The extra step ran (a decode forward on the last seen token) and was dropped.
                let session = try #require(pair.native[rank].sessions[stopped.requestID])
                #expect(session.frames.count == stopped.prefillFrameCount + stopAfter)
            }
        }
    }

    /// A token selected before the owner answered the one before it is held
    /// on rank 0. A stop answer drops it: it is never published, and both
    /// ranks retire the tokens the owner saw.
    @Test func aStopAnswerDropsAHeldTokenThatWasNeverPublished() throws {
        // The owner answers each token at the second poll after it, so the row
        // selects its 3rd, 5th, ... token before the answer to the one before.
        for stopAfter in [2, 4] {
            let pair = Pair(1), stopped = try pair.request(output: 24)
            try pair.reserve(stopped)
            var polls = 0
            pair.hosts[0].onToken = { _, _ in polls = 0 }
            pair.hosts[0].answer = { id in
                polls += 1
                return polls < 2 ? nil : pair.hosts[0].tokens[id]?.count != stopAfter
            }
            let retired = try runRetiring(pair)
            let seen = Array(HistoryBatchTestSession.oracle(stopped).prefix(stopAfter))
            #expect(pair.hosts[0].tokens[stopped.requestID] == seen)
            for rank in 0...1 {
                #expect(retired[rank][stopped.requestID]?.0 == seen)
                #expect(retired[rank][stopped.requestID]?.1 == .clientStop)
                #expect(pair.hosts[rank].finished[stopped.requestID] == .clientStop)
                #expect(pair.flag("prefix-true-\(rank)-\(stopped.requestID)"))
                // The held token's forward ran on both ranks; only the seen tokens retire.
                let session = try #require(pair.native[rank].sessions[stopped.requestID])
                #expect(session.frames.count == stopped.prefillFrameCount + stopAfter)
            }
        }
    }

    /// Joins, a prompt beside decoding rows and a cancellation interleave
    /// folded steps with exchanged ones; every row keeps its own tokens, and
    /// a cancelled row publishes nothing after the cancellation was seen.
    @Test func joinsPromptsAndCancellationInterleaveWithFoldedSteps() throws {
        let pair = Pair(4), first = try pair.request(output: 20), cancelled = try pair.request(length: 4, output: 20)
        let late = try pair.request(length: 40, output: 8)
        try pair.reserve(first); try pair.reserve(cancelled)
        pair.hosts[0].onToken = { id, ordinal in
            if id == first.requestID && ordinal == 3 && !pair.flag("late") {
                pair.set("late"); try pair.reserve(late, rank: 0)
            }
            if id == cancelled.requestID && ordinal == 5 { pair.books[0].cancel(cancelled.requestID) }
        }
        pair.hosts[1].onControl = {
            if pair.flag("late") && !pair.flag("late-1") { pair.set("late-1"); try pair.reserve(late, rank: 1) }
        }
        try pair.run()
        for request in [first, late] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
            for rank in 0...1 { #expect(pair.hosts[rank].finished[request.requestID] == .length) }
        }
        #expect(pair.hosts[0].tokens[cancelled.requestID] == Array(HistoryBatchTestSession.oracle(cancelled).prefix(6)))
        for rank in 0...1 {
            #expect(pair.hosts[rank].left.contains(cancelled.requestID))
            #expect(pair.books[rank].isEmpty)
        }
        let lengths = pair.link.lengths
        #expect(lengths.contains { $0 > QwenTensorParallelBatchWire.words })
        #expect(lengths.contains(QwenTensorParallelBatchWire.words))
    }

    /// An assisted row keeps today's exchange and gate beside plain rows: no
    /// rectangle that holds it carries control words, and it decodes only once
    /// the owner answered its last published token. Plain rows fold again
    /// once it has left.
    @Test func assistedRowsKeepTheirExchangeAndGate() throws {
        let pair = Pair(2), plain = try pair.request(output: 20), assisted = try pair.request(length: 5, output: 6)
        for rank in 0...1 { pair.native[rank].assisted = [assisted.requestID] }
        try pair.reserve(plain); try pair.reserve(assisted)
        var answered: [UUID: Int] = [:], aheadOfAnswer = 0, besidePlain = 0
        pair.hosts[0].answer = { id in answered[id] = pair.hosts[0].tokens[id]?.count; return true }
        pair.native[0].afterDecode = { ids in
            guard ids.contains(assisted.requestID) else { return }
            if ids.count > 1 { besidePlain += 1 }
            if answered[assisted.requestID] != pair.hosts[0].tokens[assisted.requestID]?.count { aheadOfAnswer += 1 }
        }
        try pair.run()
        for request in [plain, assisted] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
            for rank in 0...1 { #expect(pair.hosts[rank].finished[request.requestID] == .length) }
        }
        #expect(besidePlain > 0 && aheadOfAnswer == 0)
        for rank in 0...1 {
            #expect(!pair.native[rank].folded.isEmpty)
            #expect(pair.native[rank].folded.allSatisfy { !$0.contains(assisted.requestID) })
        }
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

    // MARK: - Build-ahead (`QwenTensorParallelBatchDriver.serveAhead`)

    /// Submitted rectangles built before the one before them was read.
    private static func builtAhead(_ events: [String]) -> Int {
        var read = Set<Int>(), count = 0
        for event in events {
            let parts = event.split(separator: " "), ordinal = Int(parts[1])!
            if parts[0] == "submit" { if ordinal > 1 && !read.contains(ordinal - 1) { count += 1 } } else { read.insert(ordinal) }
        }
        return count
    }

    /// Steady decode builds each step before reading the one before it, on
    /// both ranks in the same order, and every request takes the
    /// read-then-build tokens, finish and forwards (none past its length).
    @Test func steadyDecodeBuildsAheadAndTakesTheReadThenBuildTokens() throws {
        for width in [1, 2, 4] {
            let pair = Pair(width, ahead: true)
            let requests = try (0..<width).map { try pair.request(length: $0 + 2, output: 24) }
            for request in requests { try pair.reserve(request) }
            try pair.run()
            for request in requests {
                let tokens = HistoryBatchTestSession.oracle(request)
                #expect(pair.hosts[0].tokens[request.requestID] == tokens)
                for rank in 0...1 {
                    #expect(pair.hosts[rank].finished[request.requestID] == .length)
                    let session = try #require(pair.native[rank].sessions[request.requestID])
                    #expect(session.frames.count == request.prefillFrameCount + tokens.count - 1)
                }
            }
            #expect(pair.native[0].events == pair.native[1].events)
            #expect(Self.builtAhead(pair.native[0].events) >= 10, "width \(width): \(pair.native[0].events)")
            #expect(pair.books.allSatisfy { $0.isEmpty })
        }
    }

    /// The read-then-build driver never builds ahead (the order the check above requires).
    @Test func readThenBuildNeverBuildsAhead() throws {
        let pair = Pair(2)
        for executor in pair.native { executor.events = [] }
        let request = try pair.request(output: 12)
        try pair.reserve(request)
        try pair.run()
        #expect(pair.native[0].events.isEmpty, "the read-then-build path submits nothing ahead")
        #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
    }

    /// An EOS read after the next step was built: that step's forward is
    /// discarded on both ranks (at most one), its token never published, and
    /// the request retires as EOS with the oracle's tokens.
    @Test func anEOSReadAfterTheNextStepWasBuiltDiscardsThatForwardOnly() throws {
        for width in [1, 3] {
            let pair = Pair(width, ahead: true)
            let oracle = HistoryBatchTestSession.oracle(try pair.request(length: 3, output: 24))
            let at = try #require(oracle.indices.last { !oracle.prefix($0).contains(oracle[$0]) })
            let stopping = try pair.request(length: 3, output: 24, stops: [oracle[at]])
            var expected: [(QwenLayerStageGenerationRequest, QwenLayerStageGenerationFinishReason)] = [(stopping, .eos)]
            if width > 1 {
                expected += [(try pair.request(length: 2, output: 9), .length), (try pair.request(length: 4, output: 16), .length)]
            }
            for (request, _) in expected { try pair.reserve(request) }
            let retired = try runRetiring(pair)
            for (request, reason) in expected {
                let tokens = HistoryBatchTestSession.oracle(request)
                #expect(pair.hosts[0].tokens[request.requestID] == tokens)
                for rank in 0...1 {
                    #expect(retired[rank][request.requestID]?.0 == tokens)
                    #expect(retired[rank][request.requestID]?.1 == reason)
                    let session = try #require(pair.native[rank].sessions[request.requestID])
                    let extra = session.frames.count - (request.prefillFrameCount + tokens.count - 1)
                    // The EOS is read after the next step was built: exactly one discarded forward.
                    #expect(extra == (reason == .eos ? 1 : 0), "\(reason): \(extra) forwards past the end")
                }
            }
            #expect(Self.builtAhead(pair.native[0].events) > 0, "width \(width): the build-ahead path ran")
        }
    }

    /// The owner's stop under build-ahead: nothing past the tokens the owner
    /// saw is published, whether each answer comes at once or a poll late
    /// (tokens held unpublished meanwhile), and both ranks retire them as a
    /// clean client stop.
    @Test func aHostStopUnderBuildAheadPublishesOnlyWhatTheOwnerSaw() throws {
        for (stopAfter, late) in [(2, false), (6, false), (2, true), (5, true)] {
            let pair = Pair(1, ahead: true), stopped = try pair.request(output: 24)
            try pair.reserve(stopped)
            var polls = 0
            pair.hosts[0].onToken = { _, _ in polls = 0 }
            pair.hosts[0].answer = { id in
                polls += 1
                if late && polls < 2 { return nil }
                return pair.hosts[0].tokens[id]?.count != stopAfter
            }
            let retired = try runRetiring(pair)
            let seen = Array(HistoryBatchTestSession.oracle(stopped).prefix(stopAfter))
            #expect(pair.hosts[0].tokens[stopped.requestID] == seen, "stop after \(stopAfter) late \(late): published \(pair.hosts[0].tokens[stopped.requestID] ?? []), retired \(retired[0][stopped.requestID].map { "\($0)" } ?? "-")")
            for rank in 0...1 {
                #expect(retired[rank][stopped.requestID]?.0 == seen)
                #expect(retired[rank][stopped.requestID]?.1 == .clientStop)
                #expect(pair.hosts[rank].finished[stopped.requestID] == .clientStop)
            }
            #expect(Self.builtAhead(pair.native[0].events) > 0, "stop after \(stopAfter): the build-ahead path ran")
        }
    }

    /// A slow owner (each answer a poll late) under build-ahead: tokens are
    /// held and published in order, one per answer, and the request ends with
    /// the oracle's tokens.
    @Test func lateCreditsUnderBuildAheadPublishInOrder() throws {
        let pair = Pair(2, ahead: true), first = try pair.request(output: 16), second = try pair.request(length: 5, output: 16)
        try pair.reserve(first); try pair.reserve(second)
        var polls: [UUID: Int] = [:]
        pair.hosts[0].onToken = { id, _ in polls[id] = 0 }
        pair.hosts[0].answer = { id in polls[id, default: 0] += 1; return polls[id]! < 2 ? nil : true }
        try pair.run()
        for request in [first, second] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
            for rank in 0...1 { #expect(pair.hosts[rank].finished[request.requestID] == .length) }
        }
        #expect(Self.builtAhead(pair.native[0].events) > 0, "the build-ahead path ran")
    }

    /// Joins, prompts and a cancellation while steps are built ahead: barriers
    /// drain every submitted step before the plan that changes the lanes.
    @Test func joinsPromptsAndCancellationInterleaveWithBuildAhead() throws {
        let pair = Pair(4, ahead: true), first = try pair.request(output: 20), cancelled = try pair.request(length: 4, output: 20)
        let late = try pair.request(length: 40, output: 8)
        try pair.reserve(first); try pair.reserve(cancelled)
        pair.hosts[0].onToken = { id, ordinal in
            if id == first.requestID && ordinal == 3 && !pair.flag("late") {
                pair.set("late"); try pair.reserve(late, rank: 0)
            }
            if id == cancelled.requestID && ordinal == 5 { pair.books[0].cancel(cancelled.requestID) }
        }
        pair.hosts[1].onControl = {
            if pair.flag("late") && !pair.flag("late-1") { pair.set("late-1"); try pair.reserve(late, rank: 1) }
        }
        try pair.run()
        for request in [first, late] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
            for rank in 0...1 { #expect(pair.hosts[rank].finished[request.requestID] == .length) }
        }
        let shown = pair.hosts[0].tokens[cancelled.requestID] ?? []
        #expect(shown.count >= 6 && shown == Array(HistoryBatchTestSession.oracle(cancelled).prefix(shown.count)))
        for rank in 0...1 {
            #expect(pair.hosts[rank].left.contains(cancelled.requestID))
            #expect(pair.books[rank].isEmpty)
        }
        #expect(pair.native[0].events == pair.native[1].events)
        #expect(Self.builtAhead(pair.native[0].events) > 0)
    }

    /// A pair whose ranks disagree on build-ahead fails on both ranks at the
    /// first folded step (its selection sums differ in shape) instead of
    /// running out of step. The product never starts such a pair: build-ahead
    /// is in the load agreement (`QwenTensorParallelBatchSettings.agreementFields`).
    @Test func ranksThatDisagreeOnBuildAheadFailClosed() throws {
        for ahead in [[true, false], [false, true]] {
            let pair = Pair(1, aheadByRank: ahead)
            let request = try pair.request(output: 12)
            try pair.reserve(request)
            #expect(throws: ProbeError.self) { try pair.run() }
            // Both ranks fail, at the first folded step: nothing past the prompt's token is published.
            #expect(pair.errors.count == 2, "\(ahead): \(pair.errors)")
            #expect((pair.hosts[0].tokens[request.requestID] ?? []).count <= 1, "\(ahead)")
        }
    }

    /// A decision word that changed in transit fails both ranks.
    @Test func aCorruptedDecisionWordFailsBothRanks() throws {
        let pair = Pair(1, ahead: true)
        pair.native[1].corruptDecisionAt = 3
        try pair.reserve(try pair.request(output: 16))
        #expect(throws: ProbeError.self) { try pair.run() }
        #expect(pair.errors.count == 2 && pair.errors.contains { $0.contains("decision changed in transit") }, "\(pair.errors)")
    }

    /// A slow owner lets tokens pile up held: build-ahead stops at the bound
    /// (a barrier once more than `aheadHeldLimit` would be held) and resumes
    /// as answers arrive; every token is the oracle's, published in order.
    @Test func heldTokensStopBuildingAheadAtTheBound() throws {
        let pair = Pair(1, ahead: true), request = try pair.request(output: 24)
        try pair.reserve(request)
        var polls = 0
        pair.hosts[0].onToken = { _, _ in polls = 0 }
        pair.hosts[0].answer = { _ in polls += 1; return polls < 12 ? nil : true }
        try pair.run()
        #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
        let gap = pair.native[0].widestPublicationGap
        #expect(gap >= 3 && gap <= QwenTensorParallelBatchDriver<Executor>.aheadHeldLimit + 1, "frontier ran \(gap) ahead")
        #expect(Self.builtAhead(pair.native[0].events) > 0)
    }

    /// An assisted row beside plain rows: no step is built ahead while it is
    /// held (it never folds), and every request takes the oracle's tokens.
    @Test func anAssistedRowBesidePlainRowsKeepsReadThenBuild() throws {
        let pair = Pair(2, ahead: true), assisted = try pair.request(output: 10), plain = try pair.request(length: 5, output: 20)
        for executor in pair.native { executor.assisted.insert(assisted.requestID) }
        try pair.reserve(assisted); try pair.reserve(plain)
        try pair.run()
        for request in [assisted, plain] {
            #expect(pair.hosts[0].tokens[request.requestID] == HistoryBatchTestSession.oracle(request))
            for rank in 0...1 { #expect(pair.hosts[rank].finished[request.requestID] == .length) }
        }
        #expect(pair.native[0].folded.allSatisfy { !$0.contains(assisted.requestID) })
    }

    /// A failure while a step is submitted and unread: both ranks fail, the
    /// pending step is drained, and every lane retires on both ranks.
    @Test func aFailureWhileAStepIsPendingRetiresEveryLane() throws {
        let pair = Pair(2, ahead: true), first = try pair.request(output: 20), second = try pair.request(length: 4, output: 20)
        pair.native[0].failSubmissionAt = 6
        try pair.reserve(first); try pair.reserve(second)
        #expect(throws: ProbeError.self) { try pair.run() }
        #expect(pair.errors.count == 2 && pair.errors.contains { $0.contains("Injected failure") }, "\(pair.errors)")
        for rank in 0...1 {
            for request in [first, second] { #expect(pair.flag("closed-\(rank)-\(request.requestID)")) }
        }
        // Every step submitted before the failure is read exactly once (the pending one by the drain); the failed one never.
        for rank in 0...1 {
            let events = pair.native[rank].events
            let submitted = events.filter { $0.hasPrefix("submit ") }.map { Int($0.dropFirst(7))! }
            #expect(submitted.last == 6, "rank \(rank): \(events)")
            for ordinal in submitted.dropLast() { #expect(events.filter { $0 == "read \(ordinal)" }.count == 1, "rank \(rank): \(events)") }
            #expect(!events.contains("read 6"), "rank \(rank): \(events)")
        }
    }

    /// A read that fails while the next step is already built ahead: the
    /// newer step is drained exactly once, the failed step is not read again,
    /// both ranks fail, and every lane retires.
    @Test func aReadFailureWhileTheNextStepIsBuiltDrainsTheNewerStepOnce() throws {
        let pair = Pair(1, ahead: true), request = try pair.request(output: 24)
        try pair.reserve(request)
        pair.native[0].failReadAt = 6
        #expect(throws: ProbeError.self) { try pair.run() }
        #expect(pair.errors.contains { $0.contains("Injected failure reading") }, "\(pair.errors)")
        let events = pair.native[0].events
        // The failed read happened while step 7 was built ahead.
        let failedAt = try #require(events.firstIndex(of: "read 6"))
        #expect(events[..<failedAt].contains("submit 7"), "\(events)")
        for ordinal in events.filter({ $0.hasPrefix("submit ") }).map({ Int($0.dropFirst(7))! }) {
            #expect(events.filter { $0 == "read \(ordinal)" }.count == 1, "submit \(ordinal) read once: \(events)")
        }
        for rank in 0...1 { #expect(pair.flag("closed-\(rank)-\(request.requestID)")) }
    }

    /// Build-ahead needs an executor that submits steps and folds control.
    @Test func buildAheadNeedsAnExecutorThatSubmitsAndFolds() throws {
        let pair = Pair(1)
        #expect(throws: ProbeError.self) {
            _ = try QwenTensorParallelBatchDriver(executor: pair.native[0], book: pair.books[0], capacity: 1, vocabulary: 64,
                                                  buildsAhead: true)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenTensorParallelBatchDriver(executor: pair.native[0], book: pair.books[0], capacity: 1, vocabulary: 64,
                                                  foldsControl: false, buildsAhead: true)
        }
    }

    /// The schedule takes an EOS with the forward built ahead past it declared;
    /// a length finish still declares none, and an undeclared extra forward is refused.
    @Test func theScheduleAcceptsAnEOSWithTheForwardBuiltPastIt() throws {
        let pair = Pair(1)
        let request = try pair.request(length: 3, output: 8, stops: [5])
        var schedule = try QwenLayerStageGenerationSchedule(request: request, adoptedCommittedTokens: request.promptCount)
        for _ in 0..<3 { try schedule.commit(try request.frame(sequence: schedule.nextSequence)) }
        // Three decode forwards: three tokens selected, the third an EOS, then one forward on it built ahead.
        var undeclared = schedule
        #expect(throws: ProbeError.self) { try undeclared.finish(.eos, selectedTokenCount: 3, lastTokenID: 5) }
        var length = schedule
        #expect(throws: ProbeError.self) { try length.finish(.length, selectedTokenCount: 3, lastTokenID: 6, discardedDecodeForwards: 1) }
        var notStop = schedule
        #expect(throws: ProbeError.self) { try notStop.finish(.eos, selectedTokenCount: 3, lastTokenID: 6, discardedDecodeForwards: 1) }
        try schedule.finish(.eos, selectedTokenCount: 3, lastTokenID: 5, discardedDecodeForwards: 1)
        #expect(schedule.complete)
    }
}
