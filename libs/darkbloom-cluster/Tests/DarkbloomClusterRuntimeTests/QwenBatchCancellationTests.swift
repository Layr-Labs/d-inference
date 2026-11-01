import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

/// Real cancellation/wire/credit/ledger policies with inert native sessions.
/// No model, MLX tensor or transport is constructed.
final class QwenBatchCancellationTests: XCTestCase {
    func testCancelledLeaveIsDistinctFromCleanStopAndRejectsAnotherForward() throws {
        let id = UUID()
        let cancelled = QwenBatchWire.Slot(state: .leaving, requestID: id,
            selectedTokens: 3, leaveCancelled: true)
        let clean = QwenBatchWire.Slot(state: .leaving, requestID: UUID(),
            selectedTokens: 2, leaveReason: .clientStop)
        let header = QwenBatchWire.Header(step: 5, stop: true, slots: [cancelled, clean])
        let decoded = try QwenBatchWire.Header(words: header.words, expectedStep: 5, lanes: 2)
        XCTAssertEqual(decoded, header)
        XCTAssertNil(decoded.slots[0].leaveReason)
        XCTAssertFalse(decoded.slots[1].leaveCancelled)
        var invalid = cancelled; invalid.role = .decode
        XCTAssertThrowsError(try QwenBatchWire.Header(words:
            QwenBatchWire.Header(step: 5, stop: false, slots: [invalid, clean]).words,
            expectedStep: 5, lanes: 2))
        var unknown = header.words; unknown[16 + 11] = 5
        repairChecksum(&unknown)
        XCTAssertThrowsError(try QwenBatchWire.Header(words: unknown, expectedStep: 5, lanes: 2))
    }

    func testReplyCancellationIsBoundToCurrentOccupiedSlots() throws {
        for count in [2, 4, 8] {
            let slots = (0..<count).map { _ in QwenBatchWire.Slot(state: .active, requestID: UUID()) }
            let mask = (1 << (count - 1)) | 1
            let reply = QwenBatchWire.Reply(step: 8, tokens: Array(repeating: -1, count: count), cancelledMask: mask)
            let decoded = try QwenBatchWire.Reply(words: reply.words, expectedStep: 8, lanes: count)
            XCTAssertEqual(decoded, reply)
            XCTAssertEqual(try QwenBatchCancellation.peerRequests(mask: mask, slots: slots),
                Set([slots[0].requestID!, slots[count - 1].requestID!]))
            var invalid = reply.words; invalid[4] = Int32(1 << count); repairChecksum(&invalid)
            XCTAssertThrowsError(try QwenBatchWire.Reply(words: invalid, expectedStep: 8, lanes: count))
            XCTAssertThrowsError(try QwenBatchWire.Reply(words: reply.words, expectedStep: 9, lanes: count))
        }
        let joined = QwenBatchWire.Slot(state: .joining, requestID: UUID())
        XCTAssertEqual(try QwenBatchCancellation.peerRequests(mask: 1, slots: [joined, .init()]), [joined.requestID!])
        XCTAssertThrowsError(try QwenBatchCancellation.peerRequests(mask: 2, slots: [joined, .init()]))
        var left = joined; left.state = .leaving; left.leaveCancelled = true
        XCTAssertThrowsError(try QwenBatchCancellation.peerRequests(mask: 1, slots: [left, .init()]))
        XCTAssertThrowsError(try QwenBatchCancellation.peerRequests(mask: 3, slots: [joined, joined]))
    }

    func testMixedWireVersionsRefuseBeforeNativeWork() throws {
        let opening = QwenBatchWire.Opening(lanes: 2, pagedKV: true,
            prefixCacheEnabled: true, vocabularySize: 100, hiddenSize: 32)
        var oldOpening = opening.words; oldOpening[1] = 1; repairChecksum(&oldOpening)
        XCTAssertThrowsError(try QwenBatchWire.Opening(words: oldOpening))
        var oldHeader = QwenBatchWire.Header(step: 0, stop: false, slots: [.init(), .init()]).words
        oldHeader[5] = 0; repairChecksum(&oldHeader)
        XCTAssertThrowsError(try QwenBatchWire.Header(words: oldHeader, expectedStep: 0, lanes: 2))
        var oldReply = QwenBatchWire.Reply(step: 0, tokens: [-1, -1]).words
        oldReply[5] = 0; repairChecksum(&oldReply)
        XCTAssertThrowsError(try QwenBatchWire.Reply(words: oldReply, expectedStep: 0, lanes: 2))
    }

    func testNativeAndPrefixStateRetireBeforeChargeReleaseAndPublication() throws {
        let trace = Trace(), active = Session("active", trace), restored = Session("restored", trace)
        var charged = true, published = false
        try QwenBatchCancellation.retire(sessions: [active, restored], release: {
            XCTAssertTrue(active.isClosed && restored.isClosed)
            XCTAssertFalse(active.keepsPrefix || restored.keepsPrefix)
            trace.events.append("release"); charged = false
        }, publish: {
            XCTAssertFalse(charged); trace.events.append("publish"); published = true
        })
        XCTAssertTrue(published)
        XCTAssertEqual(trace.events, ["active.cancel", "active.discard", "restored.cancel", "restored.discard", "release", "publish"])
    }

    func testNativeFailureStillAttemptsEverySessionWithoutAcknowledgingOrReleasing() {
        for mode in [Session.Mode.throwsOnCancel, .retainsNative] {
            let trace = Trace(), failing = Session("failing", trace, mode: mode), other = Session("other", trace)
            var charged = true, published = false
            XCTAssertThrowsError(try QwenBatchCancellation.retire(sessions: [failing, other],
                release: { charged = false }, publish: { published = true }))
            XCTAssertTrue(charged); XCTAssertFalse(published)
            XCTAssertTrue(other.isClosed)
            XCTAssertFalse(failing.keepsPrefix || other.keepsPrefix)
            XCTAssertEqual(trace.events, ["failing.cancel", "failing.discard", "other.cancel", "other.discard"])
        }
    }

    func testAcceptedStartStaysChargedUntilMatchedJoinAndCancellationRetirement() throws {
        struct Reservation: ClusterBatchLaneReservation { let laneStateBytes: Int }
        let book = ClusterBatchLaneBook<Reservation>(), survivor = UUID(), cancelled = UUID(), replacement = UUID()
        try book.reserve(survivor, .init(laneStateBytes: 64), lanes: 2)
        try book.reserve(cancelled, .init(laneStateBytes: 128), lanes: 2)
        try book.start(survivor); _ = book.takeStarted(survivor)
        try book.start(cancelled); book.cancel(cancelled)
        XCTAssertFalse(book.withdraw(cancelled), "Accepted starts must not masquerade as unstarted withdrawals")
        XCTAssertEqual(try book.stateBytes(), 192)
        XCTAssertNotNil(book.takeStarted(cancelled))
        var progress = QwenBatchDecisionProgress()
        try progress.published(survivor); try progress.published(cancelled)
        var published = false
        try QwenBatchCancellation.retire(sessions: [], release: {
            book.finish(cancelled); progress.retired(cancelled)
        }, publish: { published = true; XCTAssertEqual(try book.stateBytes(), 64) })
        XCTAssertTrue(published); XCTAssertFalse(progress.canForward(survivor)); XCTAssertTrue(progress.canForward(cancelled))
        XCTAssertFalse(book.anyCancelled)
        try book.reserve(replacement, .init(laneStateBytes: 32), lanes: 2)
        XCTAssertEqual(try book.stateBytes(), 96)
    }

    func testDeadlineAndOwnerCancellationAreIndependentAtTheBoundary() {
        XCTAssertFalse(QwenBatchCancellation.requested(ownerCancelled: false, deadline: 10, now: 9))
        XCTAssertTrue(QwenBatchCancellation.requested(ownerCancelled: false, deadline: 10, now: 10))
        XCTAssertTrue(QwenBatchCancellation.requested(ownerCancelled: false, deadline: 10, now: 11))
        XCTAssertTrue(QwenBatchCancellation.requested(ownerCancelled: true, deadline: 10, now: 9))
    }

    private func repairChecksum(_ words: inout [Int32]) {
        words[words.count - 1] = QwenBatchWire.checksum(words.dropLast())
    }

    private final class Trace { var events: [String] = [] }
    private final class Session: QwenBatchCancellableSession {
        enum Mode { case normal, throwsOnCancel, retainsNative }
        enum Failure: Error { case native }
        let name: String, trace: Trace, mode: Mode
        var isClosed = false, keepsPrefix = true
        init(_ name: String, _ trace: Trace, mode: Mode = .normal) { self.name = name; self.trace = trace; self.mode = mode }
        func cancel() throws {
            trace.events.append(name + ".cancel")
            if mode == .throwsOnCancel { throw Failure.native }
            if mode != .retainsNative { isClosed = true }
        }
        func discardCapturedPrefix() { trace.events.append(name + ".discard"); keepsPrefix = false }
    }
}
