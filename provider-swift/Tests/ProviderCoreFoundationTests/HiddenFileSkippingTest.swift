import XCTest
@testable import ProviderCoreFoundation

/// Hidden files (`.DS_Store`, `.git/...`) must never appear in the manifest
/// and must not affect the aggregate hash. The `collectWeightFiles`
/// enumerator passes `.skipsHiddenFiles`, but this regression test locks the
/// behaviour in case anyone touches the options later.
final class HiddenFileSkippingTest: XCTestCase {

    func testHiddenFilesIgnored() async throws {
        let baseline = try makeBaselineFixture()
        let withHidden = try makeBaselineFixture()
        defer {
            try? FileManager.default.removeItem(at: baseline)
            try? FileManager.default.removeItem(at: withHidden)
        }

        // Add hidden detritus to the second fixture.
        try Data("ds store noise".utf8).write(to: withHidden.appendingPathComponent(".DS_Store"))
        let dotGit = withHidden.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main".utf8).write(to: dotGit.appendingPathComponent("HEAD"))

        let aManifest = try await ManifestBuilder.build(modelDirectory: baseline, modelID: "test/hidden", version: "v1")
        let bManifest = try await ManifestBuilder.build(modelDirectory: withHidden, modelID: "test/hidden", version: "v1")

        let bPaths = bManifest.files.map { $0.path }
        XCTAssertFalse(bPaths.contains(where: { $0.hasPrefix(".") }),
            "Hidden entries leaked into manifest: \(bPaths)")
        XCTAssertFalse(bPaths.contains(".DS_Store"))
        XCTAssertFalse(bPaths.contains(".git/HEAD"))

        XCTAssertEqual(aManifest.aggregateSHA256, bManifest.aggregateSHA256,
            "Hidden files changed the aggregate hash; .skipsHiddenFiles is broken")
        XCTAssertEqual(aManifest.fileCount, bManifest.fileCount)
    }

    private func makeBaselineFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "{}".write(to: url.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0xAB, count: 16).write(to: url.appendingPathComponent("model.safetensors"))
        return url
    }
}
