import XCTest
@testable import ProviderCoreFoundation

/// Regression tests pinning the Phase 1 allow-list expansion. Each test
/// asserts that tampering with the named file actually changes the manifest's
/// aggregate hash — i.e. the file IS being hashed.
final class HashAllowlistTests: XCTestCase {

    private static let newlyAllowlistedFiles: [String] = [
        "special_tokens_map.json",
        "added_tokens.json",
        "model.safetensors.index.json",
        "vocab.json",
        "merges.txt",
        "preprocessor_config.json",
        "processor_config.json",
    ]

    func testEachNewlyAllowlistedFileIsHashed() async throws {
        for target in Self.newlyAllowlistedFiles {
            try await assertFileTamperingChangesAggregate(target: target)
        }
    }

    private func assertFileTamperingChangesAggregate(target: String) async throws {
        let original = try makeFixture(targetFile: target, contents: "original")
        let tampered = try makeFixture(targetFile: target, contents: "tampered")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: tampered)
        }

        let aManifest = try await ManifestBuilder.build(
            modelDirectory: original,
            modelID: "test/allowlist",
            version: "v1"
        )
        let bManifest = try await ManifestBuilder.build(
            modelDirectory: tampered,
            modelID: "test/allowlist",
            version: "v1"
        )

        XCTAssertNotEqual(
            aManifest.aggregateSHA256,
            bManifest.aggregateSHA256,
            "Tampering with \(target) did not change the aggregate hash; file is not in the allow-list"
        )

        // Sanity: the per-file digest for the target file must differ.
        let aFile = aManifest.files.first { $0.path == target }
        let bFile = bManifest.files.first { $0.path == target }
        XCTAssertNotNil(aFile, "\(target) missing from manifest A")
        XCTAssertNotNil(bFile, "\(target) missing from manifest B")
        XCTAssertNotEqual(aFile?.sha256, bFile?.sha256)
    }

    /// Builds a fixture directory with:
    /// - a deterministic weight file (so the manifest never has zero weight files),
    /// - a fixed config.json,
    /// - and the `target` file with the supplied contents.
    private func makeFixture(targetFile: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-allow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x42, count: 16).write(to: dir.appendingPathComponent("model.safetensors"))
        try contents.write(to: dir.appendingPathComponent(targetFile), atomically: true, encoding: .utf8)
        return dir
    }
}
