/// ModelDownloader -- on-disk model download/removal core.
///
/// Struct declaration, init, the `download` entry point, `remove`, and
/// the cache-path / staging-name / R2-path helpers. The bigger flows live
/// in companion extensions:
///   - ModelDownloader+Download.swift  manifest/legacy download orchestration
///   - ModelDownloader+Prefetch.swift  resume-aware background prefetch
///   - ModelDownloader+HTTP.swift       low-level file fetch/stream/hash/publish

import Foundation

// MARK: - Downloader

public struct ModelDownloader: Sendable {

    public struct ProgressEvent: Sendable {
        public let file: String
        public let bytesDownloaded: Int64
        public let bytesTotal: Int64?
    }

    /// Structured, machine-facing download event — the feed behind
    /// `darkbloom models download --json`'s NDJSON stream. Unlike
    /// `ProgressEvent` (per-file completion notifications for human output),
    /// this fires per streamed byte chunk (cumulative bytes on disk, so a
    /// resumed `.part` prefix is included) plus a `verifying` phase marker
    /// before the manifest aggregate-hash check.
    ///
    /// Purely additive: when no `onEvent` sink is attached to `download`,
    /// nothing is emitted and the human terminal renderer behaves exactly
    /// as before.
    public struct DownloadEvent: Sendable, Equatable {
        public enum Phase: String, Sendable {
            /// Cumulative `bytesDownloaded` on disk for `file`
            /// (`bytesTotal` when the manifest knows the file's size).
            case progress
            /// All bytes are staged; the aggregate hash is being verified
            /// before the snapshot is published. `file` carries the model id
            /// and the byte fields are zero.
            case verifying
        }

        public let phase: Phase
        public let file: String
        public let bytesDownloaded: Int64
        public let bytesTotal: Int64?

        public init(
            phase: Phase,
            file: String,
            bytesDownloaded: Int64 = 0,
            bytesTotal: Int64? = nil
        ) {
            self.phase = phase
            self.file = file
            self.bytesDownloaded = bytesDownloaded
            self.bytesTotal = bytesTotal
        }
    }

    /// CDN root for model artifacts. Override with `DARKBLOOM_R2_CDN_URL` for
    /// transition/testing against alternate buckets.
    public static let defaultR2CDNURL = "https://models.darkbloom.ai"

    internal let r2CDNURL: String
    internal let urlSession: URLSession
    internal let catalogClient: ModelCatalogClient?
    internal let concurrency: Int

    public init(
        r2CDNURL: String? = nil,
        urlSession: URLSession = .shared,
        catalogClient: ModelCatalogClient? = nil,
        concurrency: Int = 4
    ) {
        if let r2CDNURL { self.r2CDNURL = r2CDNURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        else if let env = ProcessInfo.processInfo.environment["DARKBLOOM_R2_CDN_URL"], !env.isEmpty {
            self.r2CDNURL = env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            self.r2CDNURL = ModelDownloader.defaultR2CDNURL
        }
        self.urlSession = urlSession
        self.catalogClient = catalogClient
        self.concurrency = max(1, concurrency)
    }

    /// Download a catalog model into the local HuggingFace cache.
    ///
    /// Tries (in order):
    ///   1. `${R2_CDN}/${s3_name}/config.json` -- the existence smoke test
    ///   2. tokenizer files (best-effort, missing files are fine)
    ///   3. `model.safetensors` if present, else
    ///   4. `model.safetensors.index.json` + each shard listed inside
    ///
    /// On success, the model is laid out under
    /// `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/local/`
    /// with a `refs/main` pointer so `ModelScanner` discovers it the next
    /// time `darkbloom status` runs.
    public func download(
        model: CatalogModel,
        onProgress: (@Sendable (ProgressEvent) -> Void)? = nil,
        onEvent: (@Sendable (DownloadEvent) -> Void)? = nil
    ) async throws {
        if model.r2Prefix != nil, model.aggregateSHA256 != nil {
            let manifest: ModelManifest
            if let catalogClient {
                manifest = try await catalogClient.fetchManifest(modelID: model.id)
            } else {
                manifest = try await fetchManifestFromCDN(model: model)
            }
            try await downloadManifestModel(
                model: model, manifest: manifest, onProgress: onProgress, onEvent: onEvent)
            return
        }

        try await downloadLegacyModelFromCDN(model: model, onProgress: onProgress, onEvent: onEvent)
    }

    /// Remove a downloaded model from the cache. Returns true if anything was
    /// removed, false if the model was not present.
    @discardableResult
    public static func remove(modelID: String) throws -> Bool {
        let modelDir = cacheModelDirectory(for: modelID)
        guard FileManager.default.fileExists(atPath: modelDir.path) else { return false }
        try FileManager.default.removeItem(at: modelDir)
        return true
    }

    // MARK: - Internals

    public static func cacheModelDirectory(for modelID: String) -> URL {
        let safe = modelID.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .appendingPathComponent("models--\(safe)", isDirectory: true)
    }

    static func cacheSnapshotDirectory(for modelID: String) -> URL {
        cacheModelDirectory(for: modelID)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
    }

    /// Stable foreground-download staging dir name, keyed by the manifest's
    /// `r2Prefix` so an interrupted download resumes into the SAME dir instead of
    /// a throwaway UUID. `r2Prefix` is path-like (e.g. "v2/org__name/version");
    /// flatten it to a single safe component.
    static func localStagingDirName(r2Prefix: String) -> String {
        ".local-staging-" + r2Prefix
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "\\", with: "__")
    }

    static func validatedManifestRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty else {
            throw ModelCatalogError.downloadFailed("manifest contains empty file path")
        }
        guard !path.hasPrefix("/"), !path.contains("\\") else {
            throw ModelCatalogError.downloadFailed("unsafe manifest path: \(path)")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelCatalogError.downloadFailed("unsafe manifest path: \(path)")
        }
        return path
    }

    static func escapeR2Path(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

}
