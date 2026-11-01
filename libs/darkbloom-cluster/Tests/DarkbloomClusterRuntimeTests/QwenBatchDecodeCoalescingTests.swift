import XCTest
import Foundation
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRuntime

final class QwenBatchDecodeCoalescingTests: XCTestCase {
    func testSingletonCompleteAndBlockedSetsDoNotReadClockOrWait() {
        var policy = QwenBatchDecodeCoalescing()
        for (ready, pending) in [(1, 0), (8, 0), (0, 8), (0, 0)] {
            XCTAssertFalse(policy.shouldDefer(ready: ready, pending: pending, hasOtherWork: false,
                now: { XCTFail("Ineligible work read the clock"); return 0 }))
        }
    }

    func testNearbyAnswersJoinWithoutExtendingTheAbsoluteWindow() {
        var policy = QwenBatchDecodeCoalescing()
        let limit = QwenBatchDecodeCoalescing.windowNanoseconds
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 7, hasOtherWork: false, now: { 0 }))
        XCTAssertTrue(policy.shouldDefer(ready: 3, pending: 5, hasOtherWork: false, now: { limit - 1 }))
        XCTAssertFalse(policy.shouldDefer(ready: 7, pending: 1, hasOtherWork: false, now: { limit }))
        // A new token round gets its own bounded window after the old one ran.
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 7, hasOtherWork: false, now: { limit + 1 }))
    }

    func testAllAnswersArrivingEarlyReleaseImmediately() {
        var policy = QwenBatchDecodeCoalescing()
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { 10 }))
        XCTAssertFalse(policy.shouldDefer(ready: 2, pending: 0, hasOtherWork: false,
            now: { XCTFail("A complete batch read the clock"); return 11 }))
    }

    func testMissingCreditCannotHoldReadyLaneForever() {
        var policy = QwenBatchDecodeCoalescing()
        let limit = QwenBatchDecodeCoalescing.windowNanoseconds
        for round in UInt64(0)..<4 {
            let start = round * (limit + 1)
            XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { start }))
            XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { start + limit }))
        }
    }

    func testJoinPrefillAndRetirementWorkBypassAndResetTheWindow() {
        var policy = QwenBatchDecodeCoalescing()
        for _ in 0..<3 {
            XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { 1 }))
            XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: true,
                now: { XCTFail("Control/native work was delayed"); return 2 }))
        }
        // Once a cancelled or expired pending lane leaves, its survivor runs.
        XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 0, hasOtherWork: false, now: { 3 }))
    }

    func testDeferredStepsKeepControlAndPerLaneCancellationProgressing() throws {
        let ready = UUID(), slow = UUID(), joining = UUID(), host = CoalescingHost()
        var credits = QwenBatchDecisionProgress(), policy = QwenBatchDecodeCoalescing()
        try credits.published(ready); try credits.published(slow)
        host.answers[ready] = true
        XCTAssertEqual(try credits.serviceAndPoll(host), [ready: true])
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { 0 }))
        // The next no-work exchange reaches the ordinary service/poll boundary.
        host.onService = { host.joined.insert(joining) }
        XCTAssertTrue(try credits.serviceAndPoll(host).isEmpty)
        XCTAssertEqual(host.joined, [joining])
        XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: true, now: { 1 }))
        // Cancellation/deadline retirement removes only the silent lane's credit.
        credits.retired(slow)
        XCTAssertTrue(credits.canForward(ready)); XCTAssertTrue(credits.canForward(joining))
        XCTAssertEqual(credits.pendingCount, 0)
        XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 0, hasOtherWork: true, now: { 2 }))
        XCTAssertEqual(host.services, 2)
        XCTAssertEqual(host.blockingCalls, 0)
    }

    func testCleanStopCreditDoesNotHoldItsSurvivor() throws {
        let ready = UUID(), stopped = UUID(), host = CoalescingHost()
        var credits = QwenBatchDecisionProgress(), policy = QwenBatchDecodeCoalescing()
        try credits.published(ready); try credits.published(stopped)
        host.answers[ready] = true
        _ = try credits.serviceAndPoll(host)
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { 0 }))
        host.answers[stopped] = false
        XCTAssertEqual(try credits.serviceAndPoll(host), [stopped: false])
        // The production loop retires false/eos/length answers before planning.
        XCTAssertEqual(credits.pendingCount, 0)
        XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 0, hasOtherWork: true, now: { 1 }))
        try credits.published(ready)
        XCTAssertFalse(credits.canForward(ready))
        XCTAssertEqual(host.blockingCalls, 0)
    }

    func testClockBoundaryNeverWrapsIntoAnUnboundedWait() {
        var policy = QwenBatchDecodeCoalescing()
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { .max - 1 }))
        XCTAssertTrue(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { .max }))
        XCTAssertFalse(policy.shouldDefer(ready: 1, pending: 1, hasOtherWork: false, now: { 0 }))
    }
}

private final class CoalescingHost: QwenBatchServingHost {
    enum Failure: Error { case unexpectedBlockingWait }
    var answers: [UUID: Bool] = [:]
    var joined = Set<UUID>()
    var services = 0, blockingCalls = 0
    var onService: () -> Void = {}
    func serviceControl() throws { services += 1; onService() }
    func pollDecision(_ id: UUID) throws -> Bool? { answers.removeValue(forKey: id) }
    func awaitDecisions(_ ids: [UUID]) throws -> [UUID: Bool] {
        blockingCalls += 1; throw Failure.unexpectedBlockingWait
    }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {}
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {}
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
}
