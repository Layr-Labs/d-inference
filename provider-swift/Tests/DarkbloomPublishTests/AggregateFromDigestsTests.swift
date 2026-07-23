import XCTest
import Foundation
import ProviderCoreFoundation

/// Parity and pinning for `WeightHasher.aggregateFromDigests` — the
/// digests-only aggregate used by the republish flow. It must be
/// byte-identical to `WeightHasher.hashFilesWithRelativeKey` (which reads
/// file bytes) and to the Go coordinator's `aggregateManifestFileHashes`
/// (which validates every registered manifest).
final class AggregateFromDigestsTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agg-digests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Build the aggregate two ways over the same real files — streaming the
    /// bytes (hashFilesWithRelativeKey) vs combining known digests
    /// (aggregateFromDigests) — and require identical output.
    func testParityWithHashFilesWithRelativeKey() throws {
        let dir = try makeTempDir()
        let contents: [String: Data] = [
            "config.json": Data("{\"a\":1}".utf8),
            "tokenizer.json": Data(repeating: 0x7F, count: 4096),
            "adapters/lora.safetensors": Data(repeating: 0xC3, count: 999),
            "model-00001-of-00002.safetensors": Data(repeating: 0xAA, count: 65536 * 2 + 17),
            "model-00002-of-00002.safetensors": Data(),
        ]
        var keyed: [(file: URL, sortKey: String)] = []
        var digests: [(path: String, sha256Hex: String)] = []
        for (relPath, data) in contents {
            let url = dir.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            keyed.append((file: url, sortKey: relPath))
            let digest = try XCTUnwrap(WeightHasher.hashSingleFile(at: url))
            digests.append((path: relPath, sha256Hex: digest.map { String(format: "%02x", $0) }.joined()))
        }

        let fromBytes = try XCTUnwrap(WeightHasher.hashFilesWithRelativeKey(keyed))
        let fromDigests = try XCTUnwrap(WeightHasher.aggregateFromDigests(digests))
        XCTAssertEqual(fromBytes, fromDigests,
                       "digests-only aggregate must be byte-identical to the streaming aggregate")
        // Input order must not matter.
        XCTAssertEqual(WeightHasher.aggregateFromDigests(digests.reversed()), fromDigests)
    }

    /// Fixed cross-language test vector. Same fixture as
    /// ProviderCoreFoundationTests/GoldenVectorTest (files "a", "bb", "ccc")
    /// so the digests-only helper, ManifestBuilder, and the Go coordinator's
    /// aggregateManifestFileHashes are all pinned to one expected aggregate:
    ///
    ///   sorted by path, concat raw 32-byte digests, SHA-256:
    ///   5b658afdbc19cde3b9ede40aabd9364369a75c79f6baca3f08ff5e443e058900
    func testPinnedCrossLanguageVector() {
        // Deliberately unsorted input — sorting is part of the contract.
        let digests: [(path: String, sha256Hex: String)] = [
            (path: "tokenizer.json",
             sha256Hex: "3b64db95cb55c763391c707108489ae18b4112d783300de38e033b4c98c3deaf"),
            (path: "config.json",
             sha256Hex: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"),
            (path: "model.safetensors",
             sha256Hex: "64daa44ad493ff28a96effab6e77f1732a3d97d83241581b37dbd70a7a4900fe"),
        ]
        XCTAssertEqual(
            WeightHasher.aggregateFromDigests(digests),
            "5b658afdbc19cde3b9ede40aabd9364369a75c79f6baca3f08ff5e443e058900",
            "Aggregate drift — the digests-only helper no longer matches the pinned Go/Swift vector.")
    }

    func testInvalidDigestsReturnNil() {
        XCTAssertNil(WeightHasher.aggregateFromDigests([(path: "a", sha256Hex: "abc")]),
                     "short digest must be rejected")
        XCTAssertNil(WeightHasher.aggregateFromDigests([
            (path: "a", sha256Hex: String(repeating: "zz", count: 32))
        ]), "non-hex digest must be rejected")
    }

    func testEmptyInputMatchesEmptySHA256() {
        // SHA-256 of zero bytes — same as Go's h.Sum(nil) over no writes.
        XCTAssertEqual(
            WeightHasher.aggregateFromDigests([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
