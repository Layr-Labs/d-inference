import Foundation
import Testing
@testable import DarkbloomClusterRuntime

private typealias BatchPair = HistoryBatchTestPair<MiMoBatchReservation>
private typealias BatchSession = HistoryBatchTestSession

@Suite("MiMo typed batch owner schedule (CPU, no arrays)", .serialized)
struct MiMoBatchDriverTests {
    @Test func mixedHistoriesRunConcurrentDecodeAndKeepEveryChunkGrid() throws {
        for width in [2, 4, 8] {
            let pair = try BatchPair(width: width)
            let requests = try (0..<width).map { try pair.request(length: 3 + $0 * 4, chunk: 2 + $0 % 3, output: 12) }
            for request in requests { try pair.reserve(request) }
            try pair.run()
            #expect(pair.maxDecodeWidth > 1)
            for request in requests {
                #expect(pair.hosts[0].tokens[request.requestID] == BatchSession.oracle(request))
                #expect(pair.executors[0].sessions[request.requestID]?.frames == pair.executors[1].sessions[request.requestID]?.frames)
                #expect(pair.hosts.allSatisfy { $0.finished[request.requestID] == .length })
            }
            #expect(pair.books.allSatisfy { $0.isEmpty })
        }
    }

    @Test func followerCancellationCompletesAnnouncedFrameAndLeavesSurvivorRunning() throws {
        let pair = try BatchPair(width: 2)
        let cancelled = try pair.request(length: 1, chunk: 1, output: 8)
        let survivor = try pair.request(length: 1, chunk: 1, output: 8)
        try pair.reserve(cancelled); try pair.reserve(survivor)
        pair.executors[1].afterDecode = { ids in
            if ids.contains(cancelled.requestID) { pair.books[1].cancel(cancelled.requestID) }
        }
        try pair.run()
        for rank in 0...1 {
            #expect(pair.hosts[rank].left.contains(cancelled.requestID))
            #expect(pair.executors[rank].sessions[cancelled.requestID]?.frames.count == 2)
        }
        #expect(pair.hosts[0].tokens[cancelled.requestID]?.count == 1)
        #expect(pair.hosts[0].tokens[survivor.requestID] == BatchSession.oracle(survivor))
        #expect(pair.books.allSatisfy { $0.isEmpty })
    }

    /// D6: a rank's live memory check refuses while lanes run (MiMo's pipeline
    /// batch). The newest running lane alone leaves, on both ranks, published
    /// as aborted with the refusing rank (rank 1's lane rides its reply's
    /// memory mask); its session is cancelled and nothing more of it is
    /// published. The older lane runs to its length.
    @Test func aMemoryRefusalOnEitherRankEndsTheNewestLaneAloneOnBothRanks() throws {
        for refusing in 0...1 {
            let pair = try BatchPair(width: 3)
            let older = try pair.request(length: 6, chunk: 3, output: 24), newer = try pair.request(length: 5, chunk: 3, output: 24)
            try pair.reserve(older); try pair.reserve(newer)
            // Once both lanes hold tokens, MiMo's own gate on a Mac whose memory is taken (a real refusal, no fault).
            pair.memoryRefused[refusing] = {
                let sessions = pair.executors[refusing].sessions
                let both = sessions.count == 2 && sessions.values.allSatisfy { $0.committedTokens > $0.request.promptCount + 2 }
                guard both, !pair.flag("refused"), try TakenMemory.refusesLane({ try TakenMemory.mimo().requireLive() })
                else { return false }
                pair.set("refused"); return true
            }
            try pair.run()
            for rank in 0...1 {
                #expect(pair.hosts[rank].aborted[newer.requestID] == .init(reason: .memory, rank: refusing),
                        "rank \(refusing) refusing")
                #expect(pair.hosts[rank].finished[newer.requestID] == nil && !pair.hosts[rank].left.contains(newer.requestID))
                #expect(pair.executors[rank].sessions[newer.requestID]?.isClosed == true)
                #expect(pair.hosts[rank].finished[older.requestID] == .length)
            }
            #expect(pair.hosts[0].tokens[older.requestID] == BatchSession.oracle(older))
            let stopped = pair.hosts[0].tokens[newer.requestID] ?? []
            #expect(stopped.count < 24 && stopped == Array(BatchSession.oracle(newer).prefix(stopped.count)))
            #expect(pair.books.allSatisfy { $0.isEmpty })
        }
    }

    /// D6: rank 0's memory refuses while the newer lane's last token awaits
    /// the owner's answer. The lane runs no more forwards and publishes
    /// nothing more, but leaves only once that answer came (the host refuses
    /// an abort with an answer owed); then both ranks publish its abort.
    @Test func aMemoryStopWaitsForTheAnswerItsLaneOwes() throws {
        final class Held: @unchecked Sendable { var polls = 0, refusedAt: Int? }
        let pair = try BatchPair(width: 3), held = Held()
        let older = try pair.request(length: 6, chunk: 3, output: 24), newer = try pair.request(length: 5, chunk: 3, output: 24)
        try pair.reserve(older); try pair.reserve(newer)
        // Once both lanes hold tokens, the newer lane's answer is held back for five polls.
        pair.hosts[0].answer = { id in
            guard id == newer.requestID, pair.flag("both"), held.polls < 5 else { return true }
            held.polls += 1; return nil
        }
        // The memory check refuses while that answer is owed.
        pair.memoryRefused[0] = {
            let sessions = pair.executors[0].sessions
            if sessions.count == 2 && sessions.values.allSatisfy({ $0.committedTokens > $0.request.promptCount + 2 }) {
                pair.set("both")
            }
            guard held.polls >= 1, held.refusedAt == nil else { return false }
            held.refusedAt = held.polls; return true
        }
        try pair.run()
        #expect(held.polls == 5 && (held.refusedAt ?? 5) < 5, "the stop waited for the owed answer (\(held.polls), \(String(describing: held.refusedAt)))")
        for rank in 0...1 {
            #expect(pair.hosts[rank].aborted[newer.requestID] == .init(reason: .memory, rank: 0))
            #expect(pair.hosts[rank].finished[older.requestID] == .length)
        }
        #expect(pair.hosts[0].tokens[older.requestID] == BatchSession.oracle(older))
        #expect(pair.books.allSatisfy { $0.isEmpty })
    }

    /// D6, the case `f7af17941b` fixed in the Qwen pipeline batch: rank 0
    /// plans the newer lane's leave for memory in the step where that lane's
    /// deadline passes on rank 1 alone (before rank 1's reply could name it).
    /// Rank 1 ends it as rank 0's header says, aborted, not as a cancelled lane.
    @Test func rankOneFollowsAMemoryLeaveItsOwnDeadlineCrossed() throws {
        let pair = try BatchPair(width: 3)
        let older = try pair.request(length: 6, chunk: 3, output: 24), newer = try pair.request(length: 5, chunk: 3, output: 24)
        try pair.reserve(older)
        try pair.reserve(newer, rank: 0)
        try pair.reserve(newer, rank: 1, deadline: 1_000)
        pair.memoryRefused[0] = {
            let sessions = pair.executors[0].sessions
            let both = sessions.count == 2 && sessions.values.allSatisfy { $0.committedTokens > $0.request.promptCount + 2 }
            guard both, !pair.flag("refused") else { return false }
            pair.set("refused"); pair.setTime(1_000); return true
        }
        try pair.run()
        for rank in 0...1 {
            #expect(pair.hosts[rank].aborted[newer.requestID] == .init(reason: .memory, rank: 0), "rank \(rank)")
            #expect(!pair.hosts[rank].left.contains(newer.requestID), "rank \(rank) ended it as cancelled")
            #expect(pair.hosts[rank].finished[older.requestID] == .length)
        }
        #expect(pair.books.allSatisfy { $0.isEmpty })
    }

    @Test func deadlineRetiresOnlyExpiredLaneEvenWithoutTokenCredit() throws {
        let pair = try BatchPair(width: 2)
        let expired = try pair.request(length: 1, chunk: 1, output: 5)
        let survivor = try pair.request(length: 1, chunk: 1, output: 5)
        try pair.reserve(expired, deadline: 2); try pair.reserve(survivor)
        pair.hosts[0].onToken = { id, _ in if id == expired.requestID { pair.setTime(2) } }
        pair.hosts[0].answer = { id in id == expired.requestID ? nil : true }
        try pair.run()
        #expect(pair.hosts.allSatisfy { $0.left.contains(expired.requestID) })
        #expect(pair.hosts[0].tokens[survivor.requestID] == BatchSession.oracle(survivor))
        #expect(pair.books.allSatisfy { $0.isEmpty })
    }

    @Test func failedNativeCleanupKeepsChargeAndNeverAcknowledgesRetirement() throws {
        let pair = try BatchPair(width: 2)
        let request = try pair.request(length: 1, chunk: 1, output: 5)
        try pair.reserve(request)
        let expectedCharge = try pair.books[0].stateBytes()
        #expect(expectedCharge > 100) // Whole native allowance plus retained host token history.
        for executor in pair.executors { executor.failCleanup = [request.requestID] }
        pair.hosts[0].onToken = { id, _ in pair.books[0].cancel(id) }
        #expect(throws: (any Error).self) { try pair.run() }
        #expect(pair.books.allSatisfy { $0.count == 1 && (try? $0.stateBytes()) == expectedCharge })
        #expect(pair.hosts.allSatisfy { $0.left.isEmpty && $0.finished.isEmpty })
        #expect(pair.executors.allSatisfy { $0.sessions[request.requestID]?.isClosed == false })
    }

}
