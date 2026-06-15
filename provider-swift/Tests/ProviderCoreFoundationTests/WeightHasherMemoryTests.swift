import XCTest

@testable import ProviderCoreFoundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class WeightHasherMemoryTests: XCTestCase {
    private static let fixtureSizeBytes: UInt64 = 192 * 1024 * 1024
    private static let maxAllowedRSSGrowthBytes: UInt64 = 64 * 1024 * 1024

    func testWholeFileFallbackRejectsLargeModelShards() {
        XCTAssertFalse(WeightHasher.isWholeFileFallbackAllowed(fileSizeBytes: Self.fixtureSizeBytes))
        XCTAssertTrue(WeightHasher.isWholeFileFallbackAllowed(fileSizeBytes: 64 * 1024 * 1024))
    }

    func testStreamingBufferSizeMustStaySmall() {
        XCTAssertFalse(WeightHasher.isStreamingBufferSizeAllowed(0))
        XCTAssertTrue(WeightHasher.isStreamingBufferSizeAllowed(64 * 1024))
        XCTAssertFalse(WeightHasher.isStreamingBufferSizeAllowed(2 * 1024 * 1024))
    }

    func testLargeFileHashingDoesNotRetainEveryChunk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-hasher-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("model.safetensors")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: Self.fixtureSizeBytes)
        try handle.close()

        let beforePeak = try Self.maxRSSBytes()
        XCTAssertNotNil(WeightHasher.hashFilesWithRelativeKey([(file: file, sortKey: "model.safetensors")]))
        let afterPeak = try Self.maxRSSBytes()

        let growth = afterPeak > beforePeak ? afterPeak - beforePeak : 0
        XCTAssertLessThan(
            growth,
            Self.maxAllowedRSSGrowthBytes,
            "hashing a large file must stream with bounded resident memory growth; grew by \(growth) bytes")
    }

    private static func maxRSSBytes() throws -> UInt64 {
        #if canImport(Darwin) || canImport(Glibc)
        var usage = rusage()
        #if canImport(Glibc)
        let selector = __rusage_who_t(RUSAGE_SELF.rawValue)
        #else
        let selector = RUSAGE_SELF
        #endif
        guard getrusage(selector, &usage) == 0 else {
            throw XCTSkip("getrusage() failed; cannot measure peak RSS")
        }

        #if os(macOS)
        return UInt64(max(0, usage.ru_maxrss))
        #else
        return UInt64(max(0, usage.ru_maxrss)) * 1024
        #endif
        #else
        throw XCTSkip("peak RSS measurement is unavailable on this platform")
        #endif
    }
}
