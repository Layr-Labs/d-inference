import Crypto
import XCTest
@testable import ProviderCoreFoundation

/// Regression test for the HuggingFace cache layout: every file under a
/// snapshot directory is a relative symlink into a sibling `blobs/` directory.
/// The manifest builder must preserve subdirectory paths (no flattening) AND
/// hash the BLOB bytes (it must follow the symlink to read).
final class SymlinkedSnapshotTest: XCTestCase {

    func testHuggingFaceLikeSnapshotLayout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Real blobs.
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let configBytes = Data("real config".utf8)
        let weightsBytes = Data("real weights".utf8)
        let configBlob = blobs.appendingPathComponent("config_blob")
        let weightsBlob = blobs.appendingPathComponent("weights_blob")
        try configBytes.write(to: configBlob)
        try weightsBytes.write(to: weightsBlob)

        // Snapshot tree with relative symlinks back to blobs/.
        let snap = root.appendingPathComponent("snap", isDirectory: true)
        let snapAdapters = snap.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: snapAdapters, withIntermediateDirectories: true)

        // snap/config.json -> ../blobs/config_blob (relative symlink, mirrors HF cache layout).
        // We deliberately use the `atPath:withDestinationPath:` variant: the
        // URL-based variant resolves the destination URL against the current
        // working directory at creation time, breaking the relative link.
        try FileManager.default.createSymbolicLink(
            atPath: snap.appendingPathComponent("config.json").path,
            withDestinationPath: "../blobs/config_blob"
        )
        try FileManager.default.createSymbolicLink(
            atPath: snapAdapters.appendingPathComponent("lora.safetensors").path,
            withDestinationPath: "../../blobs/weights_blob"
        )

        let manifest = try await ManifestBuilder.build(
            modelDirectory: snap,
            modelID: "test/hf",
            version: "v1"
        )

        let paths = Set(manifest.files.map { $0.path })
        XCTAssertEqual(paths, ["config.json", "adapters/lora.safetensors"],
            "subdirectory information must be preserved through symlinks; manifest paths were \(paths)")

        XCTAssertEqual(manifest.fileCount, 2)

        // Per-file digests must match SHA-256 of the BLOB contents (i.e. the
        // builder followed the symlink to read bytes).
        let expectedConfig = SHA256.hash(data: configBytes).map { String(format: "%02x", $0) }.joined()
        let expectedWeights = SHA256.hash(data: weightsBytes).map { String(format: "%02x", $0) }.joined()
        let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["config.json"]?.sha256, expectedConfig)
        XCTAssertEqual(byPath["adapters/lora.safetensors"]?.sha256, expectedWeights)
        XCTAssertEqual(byPath["config.json"]?.sizeBytes, Int64(configBytes.count))
        XCTAssertEqual(byPath["adapters/lora.safetensors"]?.sizeBytes, Int64(weightsBytes.count))
    }
}
