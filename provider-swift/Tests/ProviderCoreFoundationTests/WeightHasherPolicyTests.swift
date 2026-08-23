import XCTest

@testable import ProviderCoreFoundation

final class WeightHasherPolicyTests: XCTestCase {
    private static let largeModelShardSizeBytes: UInt64 = 192 * 1024 * 1024

    func testWholeFileFallbackRejectsLargeModelShards() {
        XCTAssertFalse(
            WeightHasher.isWholeFileFallbackAllowed(
                fileSizeBytes: Self.largeModelShardSizeBytes))
        XCTAssertTrue(
            WeightHasher.isWholeFileFallbackAllowed(
                fileSizeBytes: 64 * 1024 * 1024))
    }

    func testStreamingBufferSizeMustStaySmall() {
        XCTAssertFalse(WeightHasher.isStreamingBufferSizeAllowed(0))
        XCTAssertTrue(WeightHasher.isStreamingBufferSizeAllowed(64 * 1024))
        XCTAssertFalse(WeightHasher.isStreamingBufferSizeAllowed(2 * 1024 * 1024))
    }
}
