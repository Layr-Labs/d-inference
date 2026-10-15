import XCTest
import MLXVLM

final class NemotronSuperRecurrentAdmissionTests: XCTestCase {
    func testSerialCausalLayoutAccepted() throws {
        try NemotronSuperRecurrentAdapter.validateLayout(batchSize: 1, sequenceLength: 32,
            hasExplicitPositions: false, recurrentOwnerCount: 1,
            attentionCacheCount: 8, expectedAttentionCacheCount: 8)
    }
    func testExplicitPositionsRejected() {
        XCTAssertThrowsError(try NemotronSuperRecurrentAdapter.validateLayout(batchSize: 1,
            sequenceLength: 32, hasExplicitPositions: true, recurrentOwnerCount: 1,
            attentionCacheCount: 8, expectedAttentionCacheCount: 8))
    }
    func testWrongBatchOrOwnerRejected() {
        for (batch, owners) in [(0, 1), (2, 2), (1, 0), (1, 2)] {
            XCTAssertThrowsError(try NemotronSuperRecurrentAdapter.validateLayout(batchSize: batch,
                sequenceLength: 32, hasExplicitPositions: false, recurrentOwnerCount: owners,
                attentionCacheCount: 8, expectedAttentionCacheCount: 8))
        }
    }
    func testEmptySequenceOrCacheMismatchRejected() {
        for (length, caches) in [(0, 8), (32, 7), (32, 9)] {
            XCTAssertThrowsError(try NemotronSuperRecurrentAdapter.validateLayout(batchSize: 1,
                sequenceLength: length, hasExplicitPositions: false, recurrentOwnerCount: 1,
                attentionCacheCount: caches, expectedAttentionCacheCount: 8))
        }
    }
}
