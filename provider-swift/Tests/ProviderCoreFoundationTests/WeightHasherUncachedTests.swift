import Crypto
import Foundation
import XCTest
@testable import ProviderCoreFoundation

/// The weight hash reads with the file cache off; the digest is the one every
/// other reader computes, at every chunk boundary, and the cache-off reader
/// fails closed where a raw open() cannot read (the fallbacks still run).
final class WeightHasherUncachedTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "weight-uncached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func hex(_ digest: SHA256Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    func testCacheOffReaderMatchesAnIndependentDigestAtEveryChunkBoundary() throws {
        let chunk = WeightHasher.maxStreamingBufferSize
        try withDirectory { root in
            for size in [0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk + 5] {
                let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) })
                let file = root.appendingPathComponent("shard-\(size)")
                try data.write(to: file)
                let uncached = try XCTUnwrap(WeightHasher.hashSingleFileUncached(at: file), "size \(size)")
                XCTAssertEqual(hex(uncached), hex(SHA256.hash(data: data)), "size \(size)")
                // `hashSingleFile` takes the cache-off reader first and returns the same digest.
                XCTAssertEqual(hex(try XCTUnwrap(WeightHasher.hashSingleFile(at: file))), hex(uncached))
            }
        }
    }

    func testCacheOffReaderFailsClosedAndFollowsSymlinks() throws {
        try withDirectory { root in
            XCTAssertNil(WeightHasher.hashSingleFileUncached(at: root.appendingPathComponent("missing")))
            XCTAssertNil(WeightHasher.hashSingleFileUncached(at: root), "a directory is not a weight file")
            let file = root.appendingPathComponent("payload"), link = root.appendingPathComponent("link")
            let data = Data(repeating: 0x5a, count: 70_000)
            try data.write(to: file)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertEqual(hex(try XCTUnwrap(WeightHasher.hashSingleFileUncached(at: link))), hex(SHA256.hash(data: data)))
        }
    }
}
