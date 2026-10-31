import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
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

    /// A runtime that retires cancelled lanes alone (GLM tensor parallel):
    /// cancelling a started lane retires it as cancelled, the other lane
    /// finishes, and the worker stays up. (The Qwen loop's case below fails.)
    func testRunningLaneCancellationRetiresAloneWhenTheRuntimeRetiresLanes() throws {
        let h = try LanePipeHarness(retiresCancelledLanes: true), a = UUID(), b = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
        }
        try h.send([(.start, a), (.start, b)])
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)
        try h.send(.cancel(.callerCancelled), id: a)
        try expect(h, .retired(.cancelled), id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: b)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: b)
        try expect(h, .finished(.length), id: b)
        try expect(h, .retired(.clean), id: b)
        // A cancel that crosses a lane's clean retirement changes nothing.
        try h.send(.cancel(.callerCancelled), id: b)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
        XCTAssertEqual(h.runtime.withdrawalAttempts, [])
    }

    /// Rank 1 drops a lane rank 0 dropped before this rank's own cancel came:
    /// its retirement waits for that cancel, then answers it.
    func testALaneThatLeftBeforeItsCancelRetiresWhenTheCancelArrives() throws {
        let h = try LanePipeHarness(rank: 1, retiresCancelledLanes: true), a = UUID(), b = UUID()
        h.runtime.leaveOnStart = [a]
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
        }
        try h.send(.start, id: a)
        try h.send(.start, id: b)
        try expect(h, .finished(.length), id: b)
        try expect(h, .retired(.clean), id: b)
        try h.send(.cancel(.deadline), id: a)
        try expect(h, .retired(.cancelled), id: a)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
    }

    /// A lane the runtime's live memory gate refuses (a request longer than
    /// fits now, as Qwen tensor parallel's `reserveLane` refuses one past its
    /// serving context) is refused alone, `capacity`, while the held lane
    /// runs to its end; the worker stays up, and a keep-warm answer with no
    /// lane held carries the serving context the runtime re-derived between
    /// batches (`refreshLaneServingContext`).
    func testALaneTheGateRefusesIsRefusedAloneAndKeepWarmCarriesTheServingContext() throws {
        let h = try LanePipeHarness(), short = UUID(), long = UUID(), next = UUID()
        h.runtime.refusesContextAbove = 20
        h.runtime.laneServingContext = 20
        try expect(h, .ready(h.runtime.ready), id: nil)
        try h.send(.reserve(h.reservation), id: short)
        try expect(h, .admitted(reservedBytes: 1024), id: short)
        try h.send(.reserve(h.reservation(prompt: 30, output: 4)), id: long)
        try expect(h, .refused(.capacity), id: long)
        try h.send(.start, id: short)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: short)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: short)
        try expect(h, .finished(.length), id: short)
        try expect(h, .retired(.clean), id: short)
        try h.send(.keepWarm(ordinal: 1))
        try expect(h, .keptWarm(ordinal: 1, microseconds: 0, servingContextTokens: 20), id: nil)
        // A lane runtime that keeps readiness's serving context answers none.
        h.runtime.laneServingContext = nil
        try h.send(.keepWarm(ordinal: 2))
        try expect(h, .keptWarm(ordinal: 2, microseconds: 0, servingContextTokens: nil), id: nil)
        // The next request within it is served.
        try h.send(.reserve(h.reservation(prompt: 16, output: 1)), id: next)
        try expect(h, .admitted(reservedBytes: 1024), id: next)
        try h.send(.start, id: next)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 16), id: next)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: next)
        try expect(h, .finished(.length), id: next)
        try expect(h, .retired(.clean), id: next)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
    }

    /// A lane the runtime refuses for a reason of its own (rank 0's Qwen media
    /// preparation that cannot reproduce the leader's patches) is refused
    /// alone with that reason, not `capacity`; the worker stays up and the
    /// next request is admitted and served.
    func testALaneRefusedWithItsOwnReasonKeepsTheWorkerServing() throws {
        let h = try LanePipeHarness(), refused = UUID(), next = UUID()
        h.runtime.refusesNextReservation = ClusterResidentRequestRefusal(reason: .unsupported,
            message: "Qwen media preparation refused this request: fixture")
        try expect(h, .ready(h.runtime.ready), id: nil)
        try h.send(.reserve(h.reservation), id: refused)
        try expect(h, .refused(.unsupported), id: refused)
        try h.send(.reserve(h.reservation), id: next)
        try expect(h, .admitted(reservedBytes: 1024), id: next)
        try h.send(.start, id: next)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: next)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: next)
        try expect(h, .finished(.length), id: next)
        try expect(h, .retired(.clean), id: next)
        XCTAssertEqual(h.runtime.heldRequests, [])
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
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
