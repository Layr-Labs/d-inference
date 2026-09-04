import XCTest

@testable import ProviderCoreFoundation

/// The scanner honors the standard HuggingFace cache environment
/// (`HF_HUB_CACHE`, then `HF_HOME/hub`, then the legacy default) — the same
/// precedence `huggingface-cli` uses, so a model downloaded with HF tooling
/// is found where the operator put it. Pure over an injected environment;
/// the one test that installs the process override restores it.
final class ModelScannerCacheDirectoryTests: XCTestCase {

    func testHubCacheWinsOverHFHome() {
        let url = ModelScanner.resolveCacheDirectory(environment: [
            "HF_HUB_CACHE": "/Volumes/models/hub-cache",
            "HF_HOME": "/Volumes/models/hf-home",
        ])
        XCTAssertEqual(url.path, "/Volumes/models/hub-cache")
    }

    func testHFHomeResolvesToItsHubSubdirectory() {
        let url = ModelScanner.resolveCacheDirectory(environment: [
            "HF_HOME": "/Volumes/models/hf-home"
        ])
        XCTAssertEqual(url.path, "/Volumes/models/hf-home/hub")
    }

    func testEmptyAndBlankValuesAreIgnored() {
        let legacy = ModelScanner.resolveCacheDirectory(environment: [:])
        XCTAssertTrue(legacy.path.hasSuffix("/.cache/huggingface/hub"), legacy.path)
        XCTAssertEqual(
            ModelScanner.resolveCacheDirectory(environment: ["HF_HUB_CACHE": "", "HF_HOME": "  "]),
            legacy)
        XCTAssertEqual(
            ModelScanner.resolveCacheDirectory(environment: ["HF_HUB_CACHE": "", "HF_HOME": "/h"]).path,
            "/h/hub")
    }

    func testDefaultCacheDirectoryReadsTheInjectedEnvironment() {
        XCTAssertEqual(
            ModelScanner.defaultCacheDirectory(environment: ["HF_HUB_CACHE": "/x/y"])?.path,
            "/x/y")
        XCTAssertEqual(
            ModelScanner.defaultCacheDirectory(environment: [:]),
            ModelScanner.resolveCacheDirectory(environment: [:]))
    }

    func testResolveLocalPathFollowsTheOverriddenCacheRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("scanner-cache-root-\(UUID().uuidString)", isDirectory: true)
        let snapshot = root
            .appendingPathComponent("models--darkbloom-tests--env-cache", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        defer { try? fm.removeItem(at: root) }

        XCTAssertNil(ModelScanner.resolveLocalPath(modelID: "darkbloom-tests/env-cache"))

        ModelScanner.setCacheDirectoryOverrideForTesting(root)
        defer { ModelScanner.setCacheDirectoryOverrideForTesting(nil) }
        XCTAssertEqual(ModelScanner.defaultCacheDirectory(environment: ["HF_HUB_CACHE": "/elsewhere"]), root)
        XCTAssertEqual(
            ModelScanner.resolveLocalPath(modelID: "darkbloom-tests/env-cache")?.standardizedFileURL,
            snapshot.standardizedFileURL)
    }
}
