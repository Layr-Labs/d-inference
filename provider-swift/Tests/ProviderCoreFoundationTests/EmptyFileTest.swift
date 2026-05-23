import XCTest
@testable import ProviderCoreFoundation

final class EmptyFileTest: XCTestCase {

    /// A 0-byte allow-listed file should appear in the manifest with size 0
    /// and the canonical SHA-256 of the empty string.
    func testEmptyAddedTokensFileIsIncluded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "{}".write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x55, count: 8).write(to: tmp.appendingPathComponent("model.safetensors"))
        // 0-byte added_tokens.json
        try Data().write(to: tmp.appendingPathComponent("added_tokens.json"))

        let manifest = try await ManifestBuilder.build(
            modelDirectory: tmp,
            modelID: "test/empty",
            version: "v1"
        )

        let entry = manifest.files.first { $0.path == "added_tokens.json" }
        XCTAssertNotNil(entry, "0-byte file dropped from manifest")
        XCTAssertEqual(entry?.sizeBytes, 0)
        // SHA-256 of the empty bytestring.
        XCTAssertEqual(entry?.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(entry?.role, "tokenizer")
    }
}
