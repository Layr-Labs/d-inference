import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// Actual coordinator/protocol with the production Qwen cancellation and
/// token-credit policies. Native state and the paired data plane remain fake.
final class WorkerQwenCancellationTests: XCTestCase {
    private func expect(_ h: LanePipeHarness, _ event: ClusterWorkerEvent, id: UUID?,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try h.event()
        XCTAssertEqual(frame.requestID, id, file: file, line: line)
        XCTAssertEqual(frame.event, event, file: file, line: line)
    }

    func testNativeIsolationGateRequiresPlainPipelineAndMultipleValidLanes() {
        for mode in ClusterGenerationMode.allCases {
            for lanes in [0, 1, 2, 4, 8, 9] {
                XCTAssertEqual(NativeWorkerRuntime.qwenLanesRetireAlone(mode: mode, lanes: lanes),
                    mode == .pipeline && (2...8).contains(lanes))
            }
        }
    }

    func testAcceptedStartCancelledBeforeRuntimeJoinRetiresWithoutWithdrawingOrBlockingAnotherLane() throws {
        let h = try LanePipeHarness(retiresCancelledLanes: true, pollsBatchDecisions: true)
        let a = UUID(), b = UUID(), c = UUID()
        let continueRuntime = DispatchSemaphore(value: 0), observedCancel = DispatchSemaphore(value: 0)
        h.runtime.afterPollingToken = { _ = continueRuntime.wait(timeout: .now() + 5) }
        h.runtime.observedCancel = { if $0 == b { observedCancel.signal() } }
        defer { continueRuntime.signal() }
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
        }
        try h.send(.start, id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)
        // A holds the executor; the reader accepts B's start and cancel first.
        try h.send([(.start, b), (.cancel(.callerCancelled), b)])
        XCTAssertEqual(observedCancel.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(h.runtime.heldRequests, [a, b])
        XCTAssertEqual(h.runtime.withdrawalAttempts, [])
        continueRuntime.signal()
        try expect(h, .retired(.cancelled), id: b)
        XCTAssertEqual(h.runtime.heldRequests, [a])
        // B's retirement must be available before answering A's token credit.
        try h.send(.reserve(h.reservation), id: c)
        try expect(h, .admitted(reservedBytes: 1024), id: c)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: a)
        try expect(h, .finished(.length), id: a)
        try expect(h, .retired(.clean), id: a)
        try h.send(.start, id: c)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: c)
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: c)
        try expect(h, .finished(.length), id: c)
        try expect(h, .retired(.clean), id: c)
        try finish(h)
    }

    func testCancelWithPendingDecisionsDropsOnlyItsOwnCreditAndDoesNotInventCleanFinish() throws {
        let h = try LanePipeHarness(retiresCancelledLanes: true, pollsBatchDecisions: true)
        let a = UUID(), b = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        for id in [a, b] {
            try h.send(.reserve(h.reservation), id: id)
            try expect(h, .admitted(reservedBytes: 1024), id: id)
            try h.send(.start, id: id)
            try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: id)
        }
        try h.send([(.cancel(.callerCancelled), a), (.cancel(.callerCancelled), a)])
        try expect(h, .retired(.cancelled), id: a)
        XCTAssertEqual(h.runtime.heldRequests, [b])
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: b)
        try expect(h, .finished(.length), id: b)
        try expect(h, .retired(.clean), id: b)
        try h.send(.cancel(.callerCancelled), id: b)
        try finish(h)
    }

    private func finish(_ h: LanePipeHarness) throws {
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertEqual(h.result.exitReasons, [])
        XCTAssertEqual(h.runtime.withdrawalAttempts, [])
        XCTAssertTrue(h.runtime.heldRequests.isEmpty)
    }
}
