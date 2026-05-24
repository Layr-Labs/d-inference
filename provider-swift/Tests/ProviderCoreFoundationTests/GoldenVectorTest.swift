import XCTest
@testable import ProviderCoreFoundation

/// Pinned golden vector — any future change to the aggregate-hash algorithm
/// (sort key, digest combination, etc.) fails this test.
///
/// Fixture: three files containing deterministic bytes.
///   config.json        -> "a"
///   model.safetensors  -> "ccc"
///   tokenizer.json     -> "bb"
///
/// Sorted by relative POSIX path:
///   config.json, model.safetensors, tokenizer.json
///
/// Per-file SHA-256 digests:
///   config.json        ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb
///   model.safetensors  64daa44ad493ff28a96effab6e77f1732a3d97d83241581b37dbd70a7a4900fe
///   tokenizer.json     3b64db95cb55c763391c707108489ae18b4112d783300de38e033b4c98c3deaf
///
/// Aggregate SHA-256 over the three concatenated 32-byte digests in sorted order:
///   5b658afdbc19cde3b9ede40aabd9364369a75c79f6baca3f08ff5e443e058900
final class GoldenVectorTest: XCTestCase {

    private static let expectedAggregate = "5b658afdbc19cde3b9ede40aabd9364369a75c79f6baca3f08ff5e443e058900"
    private static let expectedPerFile: [String: String] = [
        "config.json":       "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
        "model.safetensors": "64daa44ad493ff28a96effab6e77f1732a3d97d83241581b37dbd70a7a4900fe",
        "tokenizer.json":    "3b64db95cb55c763391c707108489ae18b4112d783300de38e033b4c98c3deaf",
    ]

    func testGoldenVector() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "a".write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "bb".write(to: tmp.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try "ccc".write(to: tmp.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)

        let manifest = try await ManifestBuilder.build(
            modelDirectory: tmp,
            modelID: "golden/vec",
            version: "v1"
        )

        XCTAssertEqual(manifest.aggregateSHA256, Self.expectedAggregate,
            "Aggregate hash drift — somebody changed the hashing algorithm or sort key.")

        XCTAssertEqual(manifest.fileCount, 3)
        XCTAssertEqual(manifest.totalSizeBytes, Int64(1 + 2 + 3))
        XCTAssertEqual(manifest.r2Prefix, "v2/golden-vec--8b3ee36178a0/v1")

        let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        for (path, expected) in Self.expectedPerFile {
            XCTAssertEqual(byPath[path]?.sha256, expected, "Per-file hash mismatch for \(path)")
        }
    }
}
