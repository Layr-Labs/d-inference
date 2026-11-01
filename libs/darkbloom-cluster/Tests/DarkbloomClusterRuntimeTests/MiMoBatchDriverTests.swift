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
