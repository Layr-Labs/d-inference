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

    func testMigrationNoticeNamesLegacyModelsWhenTheEnvRootDiffers() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("scanner-migration-\(UUID().uuidString)", isDirectory: true)
        let legacy = base.appendingPathComponent("legacy", isDirectory: true)
        let env = base.appendingPathComponent("env-root", isDirectory: true)
        try fm.createDirectory(
            at: legacy.appendingPathComponent("models--org--kept"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: legacy.appendingPathComponent("models--org--other"), withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy.appendingPathComponent(".locks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: env, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let notice = try XCTUnwrap(ModelScanner.cacheRootMigrationNotice(resolved: env, legacy: legacy))
        XCTAssertTrue(notice.contains("models--org--kept, models--org--other"), notice)
        XCTAssertTrue(notice.contains(legacy.path), notice)
        XCTAssertTrue(notice.contains(env.path), notice)
        // The same root, a legacy root without models, or no legacy root at
        // all is not a migration.
        XCTAssertNil(ModelScanner.cacheRootMigrationNotice(resolved: legacy, legacy: legacy))
        XCTAssertNil(ModelScanner.cacheRootMigrationNotice(resolved: env, legacy: env))
        XCTAssertNil(ModelScanner.cacheRootMigrationNotice(
            resolved: env, legacy: base.appendingPathComponent("missing")))
        XCTAssertTrue(ModelScanner.legacyCacheDirectory.path.hasSuffix("/.cache/huggingface/hub"))
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
