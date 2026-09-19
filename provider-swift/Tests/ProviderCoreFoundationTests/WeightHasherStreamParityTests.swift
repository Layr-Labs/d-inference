import Crypto
import Foundation
import XCTest
@testable import ProviderCoreFoundation

/// Process-isolated OFF/ON qualification for the streaming-I/O experiment.
/// No model weights or gate expectations are rewritten by these fixtures.
final class WeightHasherStreamParityTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "weight-stream-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    func testEmptyAndStreamingChunkBoundariesMatchIndependentDigest() throws {
        try withDirectory { root in
            for size in [0, 1, 63, 64, 65535, 65536, 65537, 131071, 131072, 1048579] {
                let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
                let file = root.appendingPathComponent("payload")
                try data.write(to: file)
                let result = try XCTUnwrap(WeightHasher.hashSingleFile(at: file))
                XCTAssertEqual(hex(result), hex(SHA256.hash(data: data)), "size \(size)")
            }
        }
    }

    func testSortedAggregationRetainsRawDigestContract() throws {
        try withDirectory { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            let first = Data("first\n\u{00e9}".utf8), second = Data([0, 255, 1, 9])
            try first.write(to: a); try second.write(to: b)
            var expected = SHA256()
            SHA256.hash(data: first).withUnsafeBytes { expected.update(bufferPointer: $0) }
            SHA256.hash(data: second).withUnsafeBytes { expected.update(bufferPointer: $0) }
            XCTAssertEqual(WeightHasher.hashFilesSorted([b, a]), hex(expected.finalize()))
            XCTAssertEqual(WeightHasher.hashFilesWithRelativeKey([
                (file: b, sortKey: "z"), (file: a, sortKey: "a")]),
                WeightHasher.hashFilesSorted([a, b]))
        }
    }

    func testMissingDirectoryAndBrokenSymlinkFailClosed() throws {
        try withDirectory { root in
            let missing = root.appendingPathComponent("missing")
            XCTAssertNil(WeightHasher.hashSingleFile(at: missing))
            XCTAssertNil(WeightHasher.hashSingleFile(at: root))
            let broken = root.appendingPathComponent("broken")
            try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
            XCTAssertNil(WeightHasher.hashSingleFile(at: broken))
            XCTAssertNil(WeightHasher.hashFilesSorted([missing]))
        }
    }

    func testSymlinkAndSameSizeTimestampMutationReadActualBytes() throws {
        try withDirectory { root in
            let file = root.appendingPathComponent("payload"), link = root.appendingPathComponent("link")
            let before = Data(repeating: 0x41, count: 65537)
            let after = Data(repeating: 0x42, count: 65537)
            let date = Date(timeIntervalSince1970: 1700000000)
            try before.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let first = try XCTUnwrap(WeightHasher.hashSingleFile(at: link))
            try after.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let second = try XCTUnwrap(WeightHasher.hashSingleFile(at: link))
            XCTAssertEqual(hex(first), hex(SHA256.hash(data: before)))
            XCTAssertEqual(hex(second), hex(SHA256.hash(data: after)))
            XCTAssertNotEqual(hex(first), hex(second))
        }
    }

    func testUnreadablePayloadDoesNotReturnSuccess() throws {
        try withDirectory { root in
            let file = root.appendingPathComponent("unreadable")
            try Data([1, 2, 3]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            XCTAssertNil(WeightHasher.hashSingleFile(at: file))
        }
    }
}
