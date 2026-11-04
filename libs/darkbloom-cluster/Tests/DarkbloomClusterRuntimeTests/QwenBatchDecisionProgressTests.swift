import Foundation
import XCTest
@testable import DarkbloomClusterRuntime
import DarkbloomClusterProtocol

/// CPU-only token-credit/control checks. Native forward/transport are absent.
final class QwenBatchDecisionProgressTests: XCTestCase {
    func testMissingAnswerKeepsControlResponsiveWithoutGrantingAnotherForward() throws {
        var progress = QwenBatchDecisionProgress()
        let host = DecisionHost(), a = UUID(), joining = UUID()
        try progress.published(a)
        host.onService = { host.reserved.insert(joining) }
        for _ in 0..<8 {
            XCTAssertTrue(try progress.serviceAndPoll(host).isEmpty)
            XCTAssertFalse(progress.canForward(a))
            XCTAssertTrue(progress.canForward(joining))
        }
        XCTAssertEqual(host.services, 8)
        XCTAssertEqual(host.reserved, [joining])
        XCTAssertEqual(host.polled, Array(repeating: a, count: 8))
        XCTAssertThrowsError(try progress.published(a))
    }

    func testAnswersReleaseOnlyTheirOwnCreditAndAreConsumedOnce() throws {
        var progress = QwenBatchDecisionProgress()
        let host = DecisionHost(), a = UUID(), b = UUID()
        try progress.published(a); try progress.published(b)
        host.onService = { host.answers[a] = true }
        XCTAssertEqual(try progress.serviceAndPoll(host), [a: true])
        XCTAssertTrue(progress.canForward(a)); XCTAssertFalse(progress.canForward(b))
        host.onService = {}
        XCTAssertTrue(try progress.serviceAndPoll(host).isEmpty)
        try progress.published(a)
        host.answers[b] = false
        XCTAssertEqual(try progress.serviceAndPoll(host), [b: false])
        XCTAssertFalse(progress.canForward(a)); XCTAssertTrue(progress.canForward(b))
        host.answers[a] = true
        XCTAssertEqual(try progress.serviceAndPoll(host), [a: true])
        XCTAssertTrue(try progress.serviceAndPoll(host).isEmpty)
    }

    func testNoWorkHeaderPreservesUnansweredLaneFrontiers() throws {
        let ids = [UUID(), UUID()]
        let slots = ids.enumerated().map { index, id in
            QwenBatchWire.Slot(state: .active, requestID: id, role: .none,
                committedTokens: 7 + index, selectedTokens: 2 + index)
        }
        let header = QwenBatchWire.Header(step: 3, stop: false, slots: slots)
        let decoded = try QwenBatchWire.Header(words: header.words, expectedStep: 3, lanes: 2)
        XCTAssertEqual(decoded, header)
        XCTAssertTrue(decoded.slots.allSatisfy { $0.role == .none })
        XCTAssertEqual(decoded.slots.map(\.requestID), ids)
        XCTAssertEqual(decoded.slots.map(\.committedTokens), [7, 8])
        XCTAssertEqual(decoded.slots.map(\.selectedTokens), [2, 3])
        let reply = QwenBatchWire.Reply(step: 3, tokens: [-1, -1])
        XCTAssertEqual(try QwenBatchWire.Reply(words: reply.words, expectedStep: 3, lanes: 2), reply)
    }

    func testControlFailureDoesNotConsumeTokenCredits() throws {
        var progress = QwenBatchDecisionProgress()
        let host = DecisionHost(), id = UUID()
        try progress.published(id)
        host.failControl = true; host.answers[id] = true
        XCTAssertThrowsError(try progress.serviceAndPoll(host))
        XCTAssertTrue(host.polled.isEmpty)
        XCTAssertFalse(progress.canForward(id))
        host.failControl = false
        XCTAssertEqual(try progress.serviceAndPoll(host), [id: true])
    }
}

private final class DecisionHost: QwenBatchServingHost {
    enum Failure: Error { case control, unexpectedBlockingCall }
    var answers: [UUID: Bool] = [:]
    var reserved = Set<UUID>()
    var polled: [UUID] = []
    var services = 0, failControl = false
    var onService: () -> Void = {}
    func serviceControl() throws {
        services += 1
        if failControl { throw Failure.control }
        onService()
    }
    func pollDecision(_ id: UUID) throws -> Bool? {
        polled.append(id)
        return answers.removeValue(forKey: id)
    }
    func awaitDecisions(_ ids: [UUID]) throws -> [UUID: Bool] { throw Failure.unexpectedBlockingCall }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {}
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {}
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
}
