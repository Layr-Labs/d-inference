/// SpecDecResolver -- resolves the local drafter directory for a catalog
/// model that carries a `spec_dec` distribution pointer (plan D2).
///
/// The target build's registry entry attaches
/// `metadata.spec_dec = {"r2_prefix": "v2-specdec/<artifact>/<version>"}`.
/// This resolver fetches that artifact's `manifest.json` from the model CDN
/// (same source/env as `ModelDownloader`: `DARKBLOOM_R2_CDN_URL`, default
/// `https://models.darkbloom.ai`), downloads each listed file with per-file
/// SHA-256 verification into a staging dir, and atomically publishes it under
/// `~/.darkbloom/spec-dec/<key>/`.
///
/// FAIL-OPEN CONTRACT: every failure -- no metadata pointer, HTTP error, SHA
/// mismatch after retries, disk full -- returns nil after one WARN log, never
/// throws. A drafter problem must never become a slot/load failure; the
/// caller falls back to plain decode (availability beats speculation).
///
/// Deliberately absent (plan D3): aggregate-hash enforcement and registry
/// pinning. Per-file SHA-256 from the artifact's own manifest is the only
/// integrity gate, because greedy-accept-walk drafter bytes cannot alter
/// output content.

import Foundation
import Logging
import ProviderCoreFoundation

public struct SpecDecResolver: Sendable {

    private let storeRoot: URL
    private let downloader: ModelDownloader

    private static let logger = Logger(label: "darkbloom.SpecDecResolver")

    /// - Parameters:
    ///   - storeRoot: drafter store root; defaults to `~/.darkbloom/spec-dec/`
    ///     (override for tests).
    ///   - cdnBaseURL: CDN base; defaults to `DARKBLOOM_R2_CDN_URL` /
    ///     `https://models.darkbloom.ai`, the same resolution `ModelDownloader`
    ///     uses (override for tests).
    ///   - urlSession: transport (override for tests).
    public init(storeRoot: URL? = nil, cdnBaseURL: String? = nil, urlSession: URLSession = .shared) {
        self.storeRoot = storeRoot ?? SpecDecStore.defaultRoot()
        self.downloader = ModelDownloader(r2CDNURL: cdnBaseURL, urlSession: urlSession)
    }

    /// The `metadata.spec_dec.r2_prefix` pointer, when the catalog entry
    /// carries one. Callers can use this to check for a pointer cheaply
    /// (without the resolver's fail-open WARN) before resolving.
    public static func specDecR2Prefix(for model: CatalogModel) -> String? {
        guard case .string(let prefix)? = model.metadata?["spec_dec"]?["r2_prefix"],
              !prefix.isEmpty
        else { return nil }
        return prefix
    }

    /// Resolve the local drafter directory for `model`. Returns a directory
    /// containing the artifact's files + its `manifest.json`, or nil (with one
    /// WARN log) on any failure. When a complete verified copy is already on
    /// disk no network traffic happens; otherwise the artifact is downloaded
    /// iff `allowDownload` is true.
    public func drafterDirectory(for model: CatalogModel, allowDownload: Bool) async -> URL? {
        guard let prefix = Self.specDecR2Prefix(for: model) else {
            Self.logger.warning(
                "spec-dec: model \(model.id) carries no spec_dec.r2_prefix metadata; no drafter")
            return nil
        }

        let artifactDir = SpecDecStore.artifactDirectory(root: storeRoot, r2Prefix: prefix)
        if SpecDecStore.verifiedManifest(at: artifactDir) != nil {
            return artifactDir
        }

        guard allowDownload else {
            Self.logger.warning(
                "spec-dec: no verified local copy of \(prefix) for \(model.id) and downloads are disabled; no drafter")
            return nil
        }

        do {
            try await downloadArtifact(r2Prefix: prefix, into: artifactDir)
        } catch {
            Self.logger.warning(
                "spec-dec: fetch of \(prefix) for \(model.id) failed (\(errorDetail(error))); falling back to plain decode")
            return nil
        }

        // Re-verify the published copy so a nil here always means "not usable".
        guard SpecDecStore.verifiedManifest(at: artifactDir) != nil else {
            Self.logger.warning(
                "spec-dec: downloaded copy of \(prefix) for \(model.id) failed verification; falling back to plain decode")
            return nil
        }
        return artifactDir
    }

    // MARK: - Download

    /// Fetch `<cdn>/<r2_prefix>/manifest.json`, download every listed file
    /// with per-file SHA-256 verification into a stable staging dir (resuming
    /// already-valid files / `.part` prefixes), stage the manifest bytes as
    /// the completeness marker, then atomically publish to `artifactDir`.
    private func downloadArtifact(r2Prefix: String, into artifactDir: URL) async throws {
        let (manifest, manifestData) = try await fetchManifest(r2Prefix: r2Prefix)

        guard !manifest.files.isEmpty else {
            throw ModelCatalogError.downloadFailed("manifest contains no files")
        }
        guard manifest.files.count == manifest.fileCount else {
            throw ModelCatalogError.downloadFailed(
                "manifest file_count \(manifest.fileCount) does not match files array")
        }

        let fm = FileManager.default
        let stagingDir = SpecDecStore.stagingDirectory(root: storeRoot, r2Prefix: r2Prefix)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // NOTE: URLs are built from the artifact's own manifest prefix
        // deliberately -- there is no catalog pinning to cross-check (D3).
        let jobs = try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try ModelDownloader.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(downloader.r2CDNURL)/\(ModelDownloader.escapeR2Path(r2Prefix))/\(ModelDownloader.escapeR2Path(relativePath))"
            )
        }

        // Disk pre-check sized to what is actually left to fetch (valid staged
        // files and `.part` prefixes are credited), same as the model paths.
        let alreadyValid = jobs.map {
            ModelDownloader.fileMatches($0.destination, size: $0.file.sizeBytes, sha256: $0.file.sha256)
        }
        let partBytes = jobs.map { downloader.fileSize($0.destination.appendingPathExtension("part")) }
        try ModelDownloader.ensureAvailableCapacity(
            at: storeRoot,
            requiredBytes: ModelDownloader.remainingBytesToFetch(
                sizes: jobs.map(\.file.sizeBytes), alreadyValid: alreadyValid, partBytes: partBytes
            )
        )

        // Sequential fetch (drafter artifacts are small -- ~2 files, ~226 MiB);
        // each file byte-resumes and is size + SHA-256 verified before promotion.
        for (job, valid) in zip(jobs, alreadyValid) where !valid {
            try await downloader.downloadManifestFileWithResume(job)
        }

        // The staged manifest doubles as the store's completeness marker: it is
        // written only after every file verified, and the publish below is atomic.
        try manifestData.write(
            to: stagingDir.appendingPathComponent(SpecDecStore.manifestFileName, isDirectory: false))

        try ModelDownloader.publishStagedSnapshot(stagingDir, to: artifactDir)
        // Staging was consumed by the publish; best-effort husk cleanup.
        try? fm.removeItem(at: stagingDir)
    }

    private func fetchManifest(r2Prefix: String) async throws -> (ModelManifest, Data) {
        let urlString = "\(downloader.r2CDNURL)/\(ModelDownloader.escapeR2Path(r2Prefix))/manifest.json"
        guard let url = URL(string: urlString) else {
            throw ModelCatalogError.downloadFailed("invalid manifest URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await downloader.urlSession.data(for: request)
        } catch {
            throw ModelCatalogError.downloadFailed("manifest.json: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.downloadFailed("manifest.json: HTTP \(http.statusCode)")
        }

        do {
            let manifest = try ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: data)
            return (manifest, data)
        } catch {
            throw ModelCatalogError.downloadFailed("manifest.json decode failed: \(error.localizedDescription)")
        }
    }

    private func errorDetail(_ error: Error) -> String {
        if let catalogError = error as? ModelCatalogError { return catalogError.description }
        return error.localizedDescription
    }
}
