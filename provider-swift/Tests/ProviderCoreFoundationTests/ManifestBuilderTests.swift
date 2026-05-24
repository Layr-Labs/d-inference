import XCTest
@testable import ProviderCoreFoundation

final class ManifestBuilderTests: XCTestCase {

    /// Happy-path test: every file type listed in the spec is present, the
    /// manifest has the expected count, roles, sort order, and r2_prefix.
    func testHappyPath() async throws {
        let tmp = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 15 files: 13 top-level + 2 weight shards + 1 subdir adapter weight.
        // Build deterministic contents for each so the aggregate is stable.
        let textFiles: [String] = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "merges.txt",
            "preprocessor_config.json",
            "processor_config.json",
            "generation_config.json",
            "chat_template.jinja",
            "model.safetensors.index.json",
        ]
        for file in textFiles {
            try "content-of-\(file)".write(to: tmp.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        try Data(repeating: 0xAA, count: 32).write(to: tmp.appendingPathComponent("model-00001-of-00002.safetensors"))
        try Data(repeating: 0xBB, count: 32).write(to: tmp.appendingPathComponent("model-00002-of-00002.safetensors"))

        let adaptersDir = tmp.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: adaptersDir, withIntermediateDirectories: true)
        try Data(repeating: 0xCC, count: 32).write(to: adaptersDir.appendingPathComponent("lora.safetensors"))

        let manifest = try await ManifestBuilder.build(
            modelDirectory: tmp,
            modelID: "test/model",
            version: "v1"
        )

        XCTAssertEqual(manifest.fileCount, 15)
        XCTAssertEqual(manifest.files.count, 15)
        XCTAssertEqual(manifest.r2Prefix, "v2/test-model--bbae3530039b/v1")
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.modelID, "test/model")
        XCTAssertEqual(manifest.version, "v1")

        // Sort order — relative POSIX path, lexicographic.
        let actualOrder = manifest.files.map { $0.path }
        let sortedOrder = actualOrder.sorted()
        XCTAssertEqual(actualOrder, sortedOrder, "manifest.files must be sorted by relative path")

        // Every file in the fixture must appear by name.
        let expectedPaths = Set(
            textFiles
            + ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
            + ["adapters/lora.safetensors"]
        )
        XCTAssertEqual(Set(actualOrder), expectedPaths)

        // Role classification spot-checks.
        let roles = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.role) })
        XCTAssertEqual(roles["config.json"], "config")
        XCTAssertEqual(roles["tokenizer.json"], "tokenizer")
        XCTAssertEqual(roles["tokenizer_config.json"], "tokenizer")
        XCTAssertEqual(roles["special_tokens_map.json"], "tokenizer")
        XCTAssertEqual(roles["added_tokens.json"], "tokenizer")
        XCTAssertEqual(roles["vocab.json"], "tokenizer")
        XCTAssertEqual(roles["merges.txt"], "tokenizer")
        XCTAssertEqual(roles["preprocessor_config.json"], "preprocessor")
        XCTAssertEqual(roles["processor_config.json"], "preprocessor")
        XCTAssertEqual(roles["generation_config.json"], "config")
        XCTAssertEqual(roles["chat_template.jinja"], "template")
        XCTAssertEqual(roles["model.safetensors.index.json"], "index")
        XCTAssertEqual(roles["model-00001-of-00002.safetensors"], "weight")
        XCTAssertEqual(roles["model-00002-of-00002.safetensors"], "weight")
        XCTAssertEqual(roles["adapters/lora.safetensors"], "weight")

        // Aggregate is 64 hex chars and total size is consistent.
        XCTAssertEqual(manifest.aggregateSHA256.count, 64)
        XCTAssertTrue(manifest.aggregateSHA256.allSatisfy { $0.isHexDigit })

        var expectedTotal: Int64 = 0
        for file in manifest.files {
            XCTAssertGreaterThan(file.sizeBytes, 0)
            XCTAssertEqual(file.sha256.count, 64)
            expectedTotal += file.sizeBytes
        }
        XCTAssertEqual(manifest.totalSizeBytes, expectedTotal)
    }

    func testEmptyDirectoryThrows() async {
        let tmp = try? makeFixtureDir()
        defer { tmp.map { try? FileManager.default.removeItem(at: $0) } }
        guard let tmp else { return XCTFail("could not make fixture") }
        do {
            _ = try await ManifestBuilder.build(modelDirectory: tmp, modelID: "x", version: "v1")
            XCTFail("expected throw for empty directory")
        } catch ManifestBuilder.Error.noFilesFound {
            // ok
        } catch {
            XCTFail("expected noFilesFound, got \(error)")
        }
    }

    func testMissingDirectoryThrows() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await ManifestBuilder.build(modelDirectory: missing, modelID: "x", version: "v1")
            XCTFail("expected throw for missing directory")
        } catch ManifestBuilder.Error.directoryNotFound {
            // ok
        } catch {
            XCTFail("expected directoryNotFound, got \(error)")
        }
    }

    func testR2PrefixSlashEscaping() async throws {
        let tmp = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "{}".write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 4).write(to: tmp.appendingPathComponent("model.safetensors"))

        let manifest = try await ManifestBuilder.build(
            modelDirectory: tmp,
            modelID: "mlx-community/openai-gpt-oss-20b",
            version: "2026-05-23-r1"
        )
        XCTAssertEqual(manifest.r2Prefix, "v2/mlx-community-openai-gpt-oss-20b--8f458c9d97d4/2026-05-23-r1")

        let slashID = ManifestBuilder.safeModelID("foo/bar")
        let underscoreID = ManifestBuilder.safeModelID("foo__bar")
        XCTAssertNotEqual(slashID, underscoreID, "R2-safe model IDs must be collision-free")
        XCTAssertEqual(slashID, "foo-bar--cc5d46bdb499")
        XCTAssertEqual(underscoreID, "foo__bar--a3a759156e88")
    }

    private func makeFixtureDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-happy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
