import Crypto
import Foundation
import XCTest

@testable import ProviderCoreFoundation

/// Real files in the unified buffer cache: residency is measured with `mincore`.
final class PageCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 32 MiB file, read once through the cache like a download's own write
    /// and an ordinary read leave it.
    private func cachedFile() throws -> (url: URL, contents: Data) {
        let url = directory.appendingPathComponent("weights.safetensors")
        var contents = Data(count: 32 << 20)
        contents.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4096) {
                buffer[index] = UInt8(truncatingIfNeeded: index >> 12)
            }
        }
        try contents.write(to: url)
        XCTAssertEqual(try Data(contentsOf: url), contents)
        return (url, contents)
    }

    func testDropInvalidatesCachedPagesWithoutChangingContents() throws {
        let file = try cachedFile()
        XCTAssertGreaterThan(try XCTUnwrap(PageCache.residentBytes(fileAt: file.url)), 16 << 20)
        XCTAssertTrue(PageCache.drop(fileAt: file.url))
        XCTAssertEqual(PageCache.residentBytes(fileAt: file.url), 0)
        XCTAssertEqual(try Data(contentsOf: file.url), file.contents)
    }

    func testHashingDropsPagesThatWereCachedBeforeTheRead() throws {
        let file = try cachedFile()
        XCTAssertGreaterThan(try XCTUnwrap(PageCache.residentBytes(fileAt: file.url)), 16 << 20)
        let digest = try XCTUnwrap(WeightHasher.hashSingleFile(at: file.url))
        XCTAssertEqual(Data(digest), Data(SHA256.hash(data: file.contents)))
        XCTAssertEqual(PageCache.residentBytes(fileAt: file.url), 0)
    }

    func testEmptyAndMissingFiles() throws {
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertTrue(PageCache.drop(fileAt: empty))
        XCTAssertEqual(PageCache.residentBytes(fileAt: empty), 0)
        XCTAssertFalse(PageCache.drop(fileAt: directory.appendingPathComponent("missing")))
        XCTAssertNil(PageCache.residentBytes(fileAt: directory.appendingPathComponent("missing")))
    }
}
