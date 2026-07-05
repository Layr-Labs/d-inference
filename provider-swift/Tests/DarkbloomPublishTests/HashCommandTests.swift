import XCTest
import Foundation
import ProviderCoreFoundation
@testable import darkbloom_publish

/// End-to-end coverage for the `darkbloom-publish hash` CLI entrypoint. The
/// manifest-hashing library (`ManifestBuilder`) is unit-tested in
/// ProviderCoreFoundationTests; these tests pin the CLI surface that wraps it:
/// argument validation and manifest.json emission to `--output`.
final class HashCommandTests: XCTestCase {

    /// Build a minimal HuggingFace-style snapshot dir (one config + one weight
    /// shard) with deterministic bytes so the manifest is stable.
    private func makeSnapshotDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "{}".write(to: url.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0xAB, count: 64).write(to: url.appendingPathComponent("model.safetensors"))
        return url
    }

    /// `hash` hashes the snapshot dir and writes a manifest.json that decodes
    /// back into a `ModelManifest` with the expected id/version/files/aggregate.
    func testHashCommandWritesManifestToOutput() async throws {
        let dir = try makeSnapshotDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }

        var cmd = try HashCommand.parse([
            dir.path,
            "--id", "mlx-community/test-model",
            "--version", "2026-06-21-r1",
            "--output", out.path,
        ])
        try await cmd.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "manifest.json must be written")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ModelManifest.self, from: Data(contentsOf: out))

        XCTAssertEqual(manifest.modelID, "mlx-community/test-model")
        XCTAssertEqual(manifest.version, "2026-06-21-r1")
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.files.count, 2)
        XCTAssertEqual(Set(manifest.files.map(\.path)), ["config.json", "model.safetensors"])
        XCTAssertEqual(manifest.aggregateSHA256.count, 64)
        XCTAssertTrue(manifest.aggregateSHA256.allSatisfy { $0.isHexDigit })
        for file in manifest.files {
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertGreaterThan(file.sizeBytes, 0)
        }
    }

    /// Hashing is deterministic: the same bytes produce the same aggregate.
    func testHashCommandIsDeterministic() async throws {
        func aggregate() async throws -> String {
            let dir = try makeSnapshotDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("dbpub-det-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: out) }
            var cmd = try HashCommand.parse([
                dir.path, "--id", "test/model", "--version", "v1", "--output", out.path,
            ])
            try await cmd.run()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let m = try decoder.decode(ModelManifest.self, from: Data(contentsOf: out))
            return m.aggregateSHA256
        }
        let first = try await aggregate()
        let second = try await aggregate()
        XCTAssertEqual(first, second, "identical snapshot bytes must hash to the same aggregate")
    }

    /// The CLI rejects an unsafe model id before any hashing happens.
    func testHashCommandRejectsInvalidModelID() {
        XCTAssertThrowsError(try validateParsed(id: "has space", version: "v1"))
        XCTAssertThrowsError(try validateParsed(id: "../escape", version: "v1"))
        XCTAssertThrowsError(try validateParsed(id: "", version: "v1"))
    }

    /// The CLI rejects an unsafe version tag before any hashing happens.
    func testHashCommandRejectsInvalidVersion() {
        XCTAssertThrowsError(try validateParsed(id: "test/model", version: "bad version"))
        XCTAssertThrowsError(try validateParsed(id: "test/model", version: "a/b"))
        XCTAssertThrowsError(try validateParsed(id: "test/model", version: ""))
    }

    /// Parse + validate without running (robust whether ArgumentParser runs
    /// validation during `parse` or not).
    private func validateParsed(id: String, version: String) throws {
        var cmd = try HashCommand.parse(["/tmp/whatever", "--id", id, "--version", version])
        try cmd.validate()
    }
}
