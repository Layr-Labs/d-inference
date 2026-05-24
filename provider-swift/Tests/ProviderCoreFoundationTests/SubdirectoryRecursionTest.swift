import XCTest
@testable import ProviderCoreFoundation

final class SubdirectoryRecursionTest: XCTestCase {

    /// Ensures `ModelScanner.collectWeightFiles` recurses into subdirectories
    /// like `adapters/` and surfaces the file via a relative manifest path.
    func testAdapterSubdirectoryIncluded() async throws {
        let tmp = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Top-level files
        try "{\"hello\":1}".write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x11, count: 8).write(to: tmp.appendingPathComponent("model.safetensors"))

        // Subdirectory
        let adaptersDir = tmp.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: adaptersDir, withIntermediateDirectories: true)
        try Data(repeating: 0x22, count: 16).write(to: adaptersDir.appendingPathComponent("extra.safetensors"))

        let manifest = try await ManifestBuilder.build(
            modelDirectory: tmp,
            modelID: "test/recurse",
            version: "v1"
        )

        let paths = manifest.files.map { $0.path }.sorted()
        XCTAssertEqual(paths, ["adapters/extra.safetensors", "config.json", "model.safetensors"].sorted())

        // The subdir entry must be referenced with a forward-slash relative path.
        let subdirEntry = manifest.files.first { $0.path == "adapters/extra.safetensors" }
        XCTAssertNotNil(subdirEntry)
        XCTAssertEqual(subdirEntry?.role, "weight")
        XCTAssertEqual(subdirEntry?.sizeBytes, 16)
    }

    /// Depth-2 nesting: `vision/adapters/lora.safetensors`. Locks that the
    /// enumerator recurses arbitrarily deep, not just one level.
    func testDepthTwoSubdirectory() async throws {
        let tmp = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "{}".write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x33, count: 8).write(to: tmp.appendingPathComponent("model.safetensors"))

        let visionAdapters = tmp.appendingPathComponent("vision/adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: visionAdapters, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 32).write(to: visionAdapters.appendingPathComponent("lora.safetensors"))

        let manifest = try await ManifestBuilder.build(
            modelDirectory: tmp,
            modelID: "test/deep",
            version: "v1"
        )

        let paths = Set(manifest.files.map { $0.path })
        XCTAssertEqual(paths, ["config.json", "model.safetensors", "vision/adapters/lora.safetensors"])

        let deep = manifest.files.first { $0.path == "vision/adapters/lora.safetensors" }
        XCTAssertNotNil(deep)
        XCTAssertEqual(deep?.role, "weight")
        XCTAssertEqual(deep?.sizeBytes, 32)
    }

    private func makeFixtureDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-recurse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
