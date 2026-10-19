import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

final class WorkerLaneTests: XCTestCase {
    private func expect(_ harness: LanePipeHarness, _ event: ClusterWorkerEvent, id: UUID?,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try harness.event()
        XCTAssertEqual(frame.requestID, id, file: file, line: line)
        XCTAssertEqual(frame.event, event, file: file, line: line)
    }

    func testWithdrawnLaneRetiresWhileOtherLaneAwaitsDecision() throws {
        let h = try LanePipeHarness(), a = UUID(), b = UUID(), c = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
        }
        try h.send(.start, id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)
        // A's token credit is deliberately held until B's retirement arrives.
        try h.send(.cancel(.callerCancelled), id: b)
        try expect(h, .retired(.cancelled), id: b)
        XCTAssertEqual(h.runtime.heldRequests, [a])
        // An ordinary action queued during the wait must survive withdrawal
        // servicing and run at the next executor service point.
        try h.send(.reserve(h.reservation), id: c)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: a)
        try expect(h, .finished(.length), id: a)
        try expect(h, .retired(.clean), id: a)
        // Reuse the freed capacity and service queue; no stale cancellation remains.
        try expect(h, .admitted(reservedBytes: 1024), id: c)
        try h.send(.start, id: c)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: c)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: c)
        try expect(h, .finished(.length), id: c)
        try expect(h, .retired(.clean), id: c)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
        XCTAssertEqual(h.runtime.withdrawalAttempts, [b])
    }

    func testAcceptedStartIsNeverWithdrawnWhileQueuedBehindAnotherLane() throws {
        let h = try LanePipeHarness(), a = UUID(), b = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
        }
        try h.send(.start, id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)
        // The executor is waiting on A, so B's accepted start cannot yet have
        // reached the runtime. Cancel must not mistake B for an unstarted lane.
        try h.send([(.start, b), (.cancel(.callerCancelled), b)])
        var failed = Set<UUID>()
        for _ in 0..<2 {
            let event = try h.event()
            XCTAssertEqual(event.event, .failed(.runtimeError))
            failed.insert(try XCTUnwrap(event.requestID))
        }
        XCTAssertEqual(failed, [a, b])
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNotNil(h.result.error)
        XCTAssertFalse(h.result.exitReasons.isEmpty)
        XCTAssertEqual(h.runtime.withdrawalAttempts, [])
        XCTAssertThrowsError(try h.event(), "Started cancellation must never invent a clean retirement")
    }

    func testDuplicateWithdrawalIsServicedOnceWhenTokenDecisionArrivesWithCancel() throws {
        let h = try LanePipeHarness(), a = UUID(), b = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
        }
        try h.send(.start, id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)
        try h.send([(.cancel(.callerCancelled), b), (.cancel(.callerCancelled), b),
                    (.tokenDecision(ordinal: 0, decision: .proceed), a)])
        try expect(h, .retired(.cancelled), id: b)
        try expect(h, .finished(.length), id: a)
        try expect(h, .retired(.clean), id: a)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
        XCTAssertEqual(h.runtime.withdrawalAttempts, [b])
    }

    func testUnstartedWithdrawalWorksOnBothIdleRanks() throws {
        for rank in [0, 1] {
            let h = try LanePipeHarness(rank: rank), id = UUID()
            try expect(h, .ready(h.runtime.ready), id: nil)
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
            try h.send(.cancel(.callerCancelled), id: id)
            try expect(h, .retired(.cancelled), id: id)
            XCTAssertTrue(h.runtime.heldRequests.isEmpty)
            try h.send(.shutdown)
            try expect(h, .shutdownComplete, id: nil)
            XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
            XCTAssertNil(h.result.error)
            XCTAssertEqual(h.result.exitReasons, [])
        }
    }

    func testRunningLaneCancellationStillFailsWithoutRetirement() throws {
        let h = try LanePipeHarness(), id = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        try h.send(.reserve(h.reservation), id: id)
        try expect(h, .admitted(reservedBytes: 1024), id: id)
        try h.send(.start, id: id)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: id)
        try h.send(.cancel(.callerCancelled), id: id)
        try expect(h, .failed(.runtimeError), id: id)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNotNil(h.result.error)
        XCTAssertFalse(h.result.exitReasons.isEmpty)
        XCTAssertEqual(h.runtime.withdrawalAttempts, [])
        XCTAssertThrowsError(try h.event())
    }
}
