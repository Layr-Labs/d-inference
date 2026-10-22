// Copyright © 2026 Eigen Labs.
import Foundation
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Opt-in delivery check: install Flint from its published R2 manifest through
/// the production downloader into a fresh, explicitly owned cache root. No
/// coordinator or catalog registration is involved. Run FlintLiveTests with
/// DARKBLOOM_FLINT_CACHE set to the same root to load and serve that copy.
@Suite("Flint R2 manifest fresh install", .serialized)
struct FlintR2InstallTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_FLINT_R2_INSTALL"] == "1"))
    func freshInstallMatchesPublishedManifest() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = try #require(env["DARKBLOOM_FLINT_R2_INSTALL_CACHE"])
        try #require(root.hasPrefix("/") && !FileManager.default.fileExists(atPath: root),
            "Use a fresh, nonexistent absolute cache root")
        let prefix = try #require(env["DARKBLOOM_FLINT_R2_PREFIX"])
        let aggregate = try #require(env["DARKBLOOM_FLINT_R2_AGGREGATE"])
        let version = try #require(env["DARKBLOOM_FLINT_R2_VERSION"])
        let modelID = "RecursiveSI/flint-int4"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(root)
        defer { ModelScanner.configureCacheDirectory(previous) }

        // Optional pinned public HF source: the production downloader tries it
        // first per file and falls back to R2, verifying registry checksums.
        let huggingFace = env["DARKBLOOM_FLINT_HF_REPO"].map {
            HuggingFaceArtifact(repoID: $0, revision: env["DARKBLOOM_FLINT_HF_REVISION"] ?? "")
        }
        let model = CatalogModel(id: modelID, s3Name: prefix, displayName: modelID, sizeGb: 0,
            version: version, r2Prefix: prefix, huggingFaceArtifact: huggingFace,
            aggregateSHA256: aggregate)
        try await ModelDownloader(r2CDNURL: env["DARKBLOOM_R2_CDN_URL"]).download(model: model)

        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        #expect(directory.resolvingSymlinksInPath().path.hasPrefix(
            URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"))
        #expect(WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) == aggregate)
        let info = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        #expect(info.modelType == "flint" && info.templateRenderOK == true)
    }
}
