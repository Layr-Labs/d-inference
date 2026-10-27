import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX
import XCTest
@testable import DarkbloomClusterRuntime

/// Real AEAD records over small Data values. No native array, model, transport
/// endpoint or GPU is created by these binding and replay checks.
final class QwenBatchRecordBindingTests: XCTestCase {
    private let epoch = UUID(uuidString: "01234567-89AB-CDEF-8123-456789ABCDEF")!
    private let payload = Data(repeating: 0x42, count: 8)

    private func binding(ordinal: UInt64 = 1, lanes: Int = 2, plan: String = String(repeating: "a", count: 64)) throws
        -> QwenBatchRecordBinding {
        try .init(epoch: epoch, planFingerprint: plan, ordinal: ordinal, lanes: lanes)
    }

    private func lane(slot: Int = 0, committed: Int = 16, selected: Int = 2,
                      fingerprint: String = String(repeating: "b", count: 64)) -> QwenBatchRecordBinding.Lane {
        .init(slot: slot, requestID: UUID(uuidString: slot == 0
                ? "12345678-1234-4234-8234-123456789ABC" : "22345678-1234-4234-8234-123456789ABC")!,
            requestFingerprint: fingerprint, committedTokens: committed, selectedTokens: selected)
    }

    private func context(_ scope: CollectiveRecordScope, dtype: DType = .uint8, shape: [Int] = [8]) throws
        -> ClusterRecordContext {
        try scope.expectation(shape: shape, dtype: dtype, chunk: 0, of: 1, length: payload.count).context
    }

    private func channels() throws -> (ClusterAuthenticatedRecordChannel, ClusterAuthenticatedRecordChannel) {
        let key = SymmetricKey(data: Data(repeating: 0x37, count: 32))
        let pinned = try ClusterRecordBinding(epoch: epoch, planSHA256: Data(repeating: 1, count: 32),
            membershipTranscriptSHA256: Data(repeating: 2, count: 32))
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 64, maximumRecordsPerDirection: 128,
            maximumCumulativePlaintextBytesPerDirection: 4096)
        let rekey = try ClusterRecordRekeyPolicy(records: 2, bytes: 1024, seconds: 0)
        return try (.init(sessionKey: key, binding: pinned, localRank: 0, limits: limits, rekey: rekey),
                    .init(sessionKey: key, binding: pinned, localRank: 1, limits: limits, rekey: rekey))
    }

    func testBatchIdentityIsLocalDeterministicAndSeparated() throws {
        let a = try binding(), b = try binding()
        XCTAssertEqual(a.requestID, b.requestID)
        XCTAssertEqual(try context(a.header(step: 0)).expectationSHA256,
                       try context(b.header(step: 0)).expectationSHA256)
        let anotherEpoch = try QwenBatchRecordBinding(epoch: UUID(), planFingerprint: String(repeating: "a", count: 64),
            ordinal: 1, lanes: 2)
        for other in [try binding(ordinal: 2), try binding(lanes: 3),
                      try binding(plan: String(repeating: "c", count: 64)), anotherEpoch] {
            XCTAssertNotEqual(a.requestID, other.requestID)
        }
        XCTAssertNotEqual(try context(a.opening(fromRank: 0)).expectationSHA256,
                          try context(a.opening(fromRank: 1)).expectationSHA256)
    }

    func testWrongBatchPhaseStepLaneFrontierAndGeometryFailClosed() throws {
        let batch = try binding()
        let residual = try batch.residual(step: 2, kind: .decode, lanes: [lane()])
        let expected = try context(residual.payload)
        let wrong = try [context(binding(ordinal: 2).residual(step: 2, kind: .decode, lanes: [lane()]).payload),
            context(batch.header(step: 2)), context(batch.reply(step: 2)), context(residual.digest),
            context(batch.residual(step: 3, kind: .decode, lanes: [lane()]).payload),
            context(batch.residual(step: 2, kind: .prefill(offset: 16, count: 1, final: true), lanes: [lane()]).payload),
            context(batch.residual(step: 2, kind: .decode, lanes: [lane(slot: 1)]).payload),
            context(batch.residual(step: 2, kind: .decode, lanes: [lane(committed: 17)]).payload),
            context(batch.residual(step: 2, kind: .decode, lanes: [lane(selected: 3)]).payload),
            context(batch.residual(step: 2, kind: .decode, lanes: [lane(fingerprint: String(repeating: "c", count: 64))]).payload),
            context(residual.payload, dtype: .int32, shape: [2]), context(residual.payload, shape: [1, 8])]
        for mismatch in wrong {
            let (sender, receiver) = try channels()
            let sealed = try sender.seal(payload, context: expected)
            XCTAssertThrowsError(try receiver.open(sealed, expecting: mismatch))
            XCTAssertFalse(receiver.status.active)
        }
    }

    func testCompletedBatchesContinueDirectionalSequencesAcrossRekeys() throws {
        let (rank0, rank1) = try channels()
        for ordinal in UInt64(1)...2 {
            let batch = try binding(ordinal: ordinal)
            for step in 0..<3 {
                let header = try context(batch.header(step: step))
                XCTAssertEqual(try rank1.open(rank0.seal(payload, context: header), expecting: header), payload)
                let reply = try context(batch.reply(step: step))
                XCTAssertEqual(try rank0.open(rank1.seal(payload, context: reply), expecting: reply), payload)
            }
        }
        XCTAssertEqual(rank0.status.sealedRecords, 6)
        XCTAssertEqual(rank1.status.openedRecords, 6)
        XCTAssertEqual(rank1.status.sealedRecords, 6)
        XCTAssertEqual(rank0.status.openedRecords, 6)
        XCTAssertGreaterThan(rank0.status.sendGeneration, 0)
        XCTAssertGreaterThan(rank1.status.receiveGeneration, 0)
        XCTAssertTrue(rank0.status.active && rank1.status.active)
    }

    func testReplayReorderingAndWrongDirectionPoisonTheReceiver() throws {
        let batch = try binding(), first = try context(batch.header(step: 0)), second = try context(batch.header(step: 1))
        do {
            let (sender, receiver) = try channels()
            let record = try sender.seal(payload, context: first)
            XCTAssertEqual(try receiver.open(record, expecting: first), payload)
            XCTAssertThrowsError(try receiver.open(record, expecting: first))
            XCTAssertFalse(receiver.status.active)
        }
        do {
            let (sender, receiver) = try channels()
            _ = try sender.seal(payload, context: first)
            let later = try sender.seal(payload, context: second)
            XCTAssertThrowsError(try receiver.open(later, expecting: second))
            XCTAssertFalse(receiver.status.active)
        }
        do {
            let (sender, _) = try channels()
            let (wrongDirection, _) = try channels()
            XCTAssertThrowsError(try wrongDirection.open(sender.seal(payload, context: first), expecting: first))
            XCTAssertFalse(wrongDirection.status.active)
        }
    }

    func testInvalidBatchAndRowMetadataRefuseBeforeRecords() throws {
        XCTAssertEqual(try QwenBatchRecordBinding.nextOrdinal(after: 0), 1)
        XCTAssertEqual(try QwenBatchRecordBinding.nextOrdinal(after: UInt64.max - 1), UInt64.max)
        XCTAssertThrowsError(try QwenBatchRecordBinding.nextOrdinal(after: UInt64.max))
        XCTAssertThrowsError(try binding(ordinal: 0))
        XCTAssertThrowsError(try binding(lanes: 0))
        XCTAssertThrowsError(try binding(lanes: 9))
        XCTAssertThrowsError(try binding(plan: "not-a-digest"))
        let batch = try binding()
        XCTAssertThrowsError(try batch.opening(fromRank: 2))
        XCTAssertThrowsError(try batch.header(step: -1))
        XCTAssertThrowsError(try batch.reply(step: Int(Int32.max) + 1))
        XCTAssertThrowsError(try batch.residual(step: 0, kind: .decode, lanes: []))
        XCTAssertThrowsError(try batch.residual(step: 0, kind: .decode, lanes: [lane(slot: 1), lane()]))
        XCTAssertThrowsError(try batch.residual(step: 0, kind: .decode, lanes: [lane(), lane()]))
        XCTAssertThrowsError(try batch.residual(step: 0, kind: .decode, lanes: [lane(committed: -1)]))
        XCTAssertThrowsError(try batch.residual(step: 0, kind: .prefill(offset: 16, count: 1, final: false),
            lanes: [lane(), lane(slot: 1)]))
        XCTAssertThrowsError(try batch.residual(step: 0, kind: .prefill(offset: Int(Int32.max), count: 1, final: true),
            lanes: [lane()]))
    }
}
