/// ModelPrefetcher -- abstraction over make-available-and-verified-on-disk
/// so the Layer-3 prefetch coordinator is unit-testable with a fake.

import Foundation

// MARK: - ModelPrefetcher abstraction

/// Abstraction over "make a model build available + verified on disk" so the
/// prefetch coordinator (Layer 3) can be unit-tested with an injected fake that
/// simulates success, resume, hash failure, and cancellation WITHOUT hitting
/// the network or downloading real multi-GB weights.
///
/// The real conformer (`ModelDownloader`) fetches the manifest from the
/// coordinator/CDN, downloads + resumes + verifies, and publishes the snapshot.
public protocol ModelPrefetcher: Sendable {
    /// Download (resuming if interrupted) and verify the model on disk without
    /// loading it into GPU. Reports cumulative verified bytes vs. total via
    /// `onByteProgress`. Throws on hash mismatch, fetch failure, or
    /// cancellation; returns normally only when the build is on disk and
    /// aggregate-hash-verified.
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (_ done: Int64, _ total: Int64) -> Void
    ) async throws
}

/// Production `ModelPrefetcher` backed by the coordinator catalog + R2 CDN.
///
/// Resolves the catalog entry (for `r2Prefix`/`aggregateSHA256`), then the
/// manifest, then runs the resume-aware verified download. A short-circuit for
/// "already on disk and valid" is handled one layer up (the prefetch
/// coordinator) so this type stays a thin IO conformer.
public struct CatalogModelPrefetcher: ModelPrefetcher {
    private let catalogClient: ModelCatalogClient
    private let downloader: ModelDownloader

    public init(coordinatorURL: String, urlSession: URLSession = .shared) {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL, urlSession: urlSession)
        self.catalogClient = client
        self.downloader = ModelDownloader(urlSession: urlSession, catalogClient: client)
    }

    public init(catalogClient: ModelCatalogClient, downloader: ModelDownloader) {
        self.catalogClient = catalogClient
        self.downloader = downloader
    }

    public func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (_ done: Int64, _ total: Int64) -> Void
    ) async throws {
        let catalog = try await catalogClient.fetchCatalog()
        guard let model = catalog.first(where: { $0.id == modelID }) else {
            throw ModelCatalogError.modelNotInCatalog(modelID)
        }
        guard model.r2Prefix != nil, model.aggregateSHA256 != nil else {
            throw ModelCatalogError.downloadFailed(
                "model '\(modelID)' has no manifest (r2_prefix/aggregate_sha256); cannot prefetch"
            )
        }
        let manifest = try await downloader.resolveManifest(model: model)
        try await downloader.prefetch(model: model, manifest: manifest, onByteProgress: onByteProgress)
    }
}
