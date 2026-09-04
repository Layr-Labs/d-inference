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
        XCTAssertTrue(WeightHasher.isStreamingBufferSizeAllowed(1024 * 1024))
        XCTAssertFalse(WeightHasher.isStreamingBufferSizeAllowed(2 * 1024 * 1024))
    }

    /// The concurrent per-file path holds at most one 1 MiB buffer per
    /// worker; eight 64 MiB files hashed together must stay far under the
    /// same bound the single-file test pins.
    func testEightFileFixtureHashedConcurrentlyStaysWithinTheRSSBound() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-hasher-memory-8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var files: [(file: URL, sortKey: String)] = []
        for index in 0..<8 {
            let name = "model-0000\(index)-of-00008.safetensors"
            let file = tmp.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 64 * 1024 * 1024)
            try handle.close()
            files.append((file: file, sortKey: name))
        }

        let beforePeak = try Self.maxRSSBytes()
        XCTAssertNotNil(WeightHasher.hashFilesWithRelativeKey(files))
        let afterPeak = try Self.maxRSSBytes()

        let growth = afterPeak > beforePeak ? afterPeak - beforePeak : 0
        XCTAssertLessThan(
            growth,
            Self.maxAllowedRSSGrowthBytes,
            "concurrent per-file hashing must keep N × 1 MiB buffers, not N × file; grew by \(growth) bytes")
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
