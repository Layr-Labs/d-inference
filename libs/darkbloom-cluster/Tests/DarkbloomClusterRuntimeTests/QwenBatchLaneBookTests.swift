import Foundation
import XCTest
@_spi(Benchmark) @testable import DarkbloomClusterRuntime

/// The actual lane ledger with inert request metadata; no resident owner,
/// tensor, model load or live-memory observation is needed.
final class QwenBatchLaneBookTests: XCTestCase {
    private func reservation(_ id: UUID, stateBytes: Int) throws -> QwenResidentReservation {
        let profile = try QwenLayerStageGenerationProfile(identifier: "lane-book-test", vocabularySize: 100,
            hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 8,
            maximumChunkTokens: 4, maximumOutputTokens: 4, maximumContextTokens: 12)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
            promptTokenIDs: [1, 2, 3], chunkSize: 2, outputCount: 1, stopTokenIDs: [])
        return .init(request: request,
            allowance: .init(stateBytes: stateBytes, fusionBytes: 0, reservedBytes: stateBytes + 32),
            deadline: UInt64.max, mode: .serving, recordingCharge: nil, prefillPolicy: .serial, prefillAllowance: nil)
    }

    func testWithdrawalPreservesJoinedLaneAndReusesOnlyFreedCapacity() throws {
        let book = QwenBatchLaneBook(), a = UUID(), b = UUID(), c = UUID()
        try book.reserve(a, reservation(a, stateBytes: 64), lanes: 2)
        try book.reserve(b, reservation(b, stateBytes: 128), lanes: 2)
        XCTAssertEqual(try book.stateBytes(), 192)
        try book.start(a)
        XCTAssertEqual(try XCTUnwrap(book.takeStarted()).0, a)
        XCTAssertThrowsError(try book.reserve(c, reservation(c, stateBytes: 32), lanes: 2))

        XCTAssertTrue(book.withdraw(b))
        XCTAssertEqual(book.count, 1)
        XCTAssertEqual(try book.stateBytes(), 64)
        XCTAssertEqual(try book.stateBytes(excluding: a), 0)
        XCTAssertEqual(book.allowances().map(\.stateBytes), [64])
        XCTAssertFalse(book.anyCancelled)
        XCTAssertFalse(book.hasStarted)
        XCTAssertNil(book.takeStarted(b))
        try book.reserve(c, reservation(c, stateBytes: 32), lanes: 2)
        XCTAssertEqual(book.count, 2)
        XCTAssertEqual(try book.stateBytes(), 96)
        book.finish(a)
        XCTAssertEqual(try book.stateBytes(), 32)
        book.finish(c)
        XCTAssertTrue(book.isEmpty)
    }

    func testStartedAndJoinedLanesCannotBeWithdrawn() throws {
        let book = QwenBatchLaneBook(), a = UUID()
        try book.reserve(a, reservation(a, stateBytes: 64), lanes: 2)
        try book.start(a)
        XCTAssertFalse(book.withdraw(a))
        XCTAssertTrue(book.isStarted(a))
        XCTAssertEqual(try book.stateBytes(), 64)
        XCTAssertNotNil(book.takeStarted(a))
        XCTAssertFalse(book.withdraw(a))
        XCTAssertEqual(book.count, 1)
        XCTAssertEqual(try book.stateBytes(), 64)
        book.cancel(a)
        XCTAssertTrue(book.anyCancelled)
    }

    func testWithdrawalClearsOnlyItsOwnCancellation() throws {
        let book = QwenBatchLaneBook(), a = UUID(), b = UUID(), c = UUID()
        try book.reserve(a, reservation(a, stateBytes: 64), lanes: 2)
        try book.reserve(b, reservation(b, stateBytes: 128), lanes: 2)
        book.cancel(b)
        XCTAssertTrue(book.anyCancelled)
        XCTAssertTrue(book.withdraw(b))
        XCTAssertFalse(book.anyCancelled)
        try book.reserve(c, reservation(c, stateBytes: 32), lanes: 2)
        book.cancel(a); book.cancel(c)
        XCTAssertTrue(book.withdraw(c))
        XCTAssertTrue(book.anyCancelled, "Withdrawing C must not clear A's cancellation")
        XCTAssertEqual(try book.stateBytes(), 64)
    }

    func testUnknownRepeatedAndReplayedWithdrawalsLeaveOtherLaneIntact() throws {
        let book = QwenBatchLaneBook(), a = UUID(), b = UUID()
        try book.reserve(a, reservation(a, stateBytes: 64), lanes: 2)
        try book.reserve(b, reservation(b, stateBytes: 128), lanes: 2)
        XCTAssertFalse(book.withdraw(UUID()))
        XCTAssertTrue(book.withdraw(b))
        XCTAssertFalse(book.withdraw(b))
        XCTAssertThrowsError(try book.start(b))
        XCTAssertThrowsError(try book.reserve(b, reservation(b, stateBytes: 128), lanes: 2))
        XCTAssertEqual(book.count, 1)
        XCTAssertEqual(try book.stateBytes(), 64)
        XCTAssertFalse(book.anyCancelled)
        try book.start(a)
        XCTAssertEqual(try XCTUnwrap(book.takeStarted()).0, a)
    }
}
