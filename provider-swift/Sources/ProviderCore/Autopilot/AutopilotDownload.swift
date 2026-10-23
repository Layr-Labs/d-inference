import Foundation

/// Closed vocabulary of the `prefetch_model_status` `error` for a download
/// Autopilot makes on the operator's behalf. A provider without saved consent
/// keeps answering `model_not_selected`, and lifecycle refusals keep their
/// existing replies.
public enum AutopilotDownloadRefusal: String, Error, LocalizedError, CaseIterable, Sendable {
    /// Saved consent is present but Autopilot is paused.
    case autopilotPaused = "autopilot_paused"
    /// Not an active catalog build this machine can run: unknown or inactive
    /// in the catalog, below its RAM floor, missing a runtime capability, an
    /// unsupported engine family, larger than the load budget, or not
    /// reportable as an Autopilot model ID.
    case modelNotSupported = "model_not_supported"
    /// The download would leave less free disk than the configured reserve.
    case insufficientDisk = "insufficient_disk"
    /// The catalog or the build's manifest could not be fetched; retryable.
    case catalogUnavailable = "catalog_unavailable"
    /// The transfer or its verification failed; retryable. The detail stays
    /// in the provider log.
    case downloadFailed = "download_failed"

    public var errorDescription: String? { rawValue }
}

/// Keeps a configurable amount of disk free after an Autopilot download
/// (`backend.autopilot_download_reserve_gb`, `defaultReserveGiB` when
/// absent). The downloader's own capacity check still applies on top.
public enum AutopilotDiskGuard {
    public static let defaultReserveGiB: UInt64 = 50

    public static func reserveBytes(configuredGiB: UInt64?) -> Int64 {
        let (bytes, overflow) = (configuredGiB ?? defaultReserveGiB).multipliedReportingOverflow(by: 1 << 30)
        return overflow ? .max : Int64(clamping: bytes)
    }

    /// An unknown free figure refuses: the guard fails closed.
    public static func allows(neededBytes: Int64, freeBytes: Int64?, reserveBytes: Int64) -> Bool {
        guard let freeBytes, freeBytes > 0 else { return false }
        let (required, overflow) = max(0, neededBytes).addingReportingOverflow(max(0, reserveBytes))
        return !overflow && freeBytes >= required
    }

    /// Free bytes for important usage on the volume holding `url` (or its
    /// nearest existing ancestor).
    public static func volumeFreeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? probe.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Downloads a catalog build for Autopilot through the ordinary resumable,
/// verified prefetch, after the catalog gates and the disk guard. Every
/// failure leaves as an `AutopilotDownloadRefusal`, so the status `error`
/// stays a closed code. It never loads, advertises or deletes anything.
struct AutopilotDownloadPrefetcher: ModelPrefetcher {
    struct Dependencies: Sendable {
        var catalog: @Sendable () async throws -> [CatalogModel]
        var manifest: @Sendable (CatalogModel) async throws -> ModelManifest
        /// Bytes the download still needs on disk; 0 when the revision is
        /// already present.
        var neededBytes: @Sendable (CatalogModel, ModelManifest) -> Int64
        var freeBytes: @Sendable (CatalogModel) -> Int64?
        var download: @Sendable (CatalogModel, ModelManifest, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void
        var log: @Sendable (String) -> Void
    }

    let memoryGb: Double
    let runtimeCapabilities: Set<ProviderRuntimeCapability>
    let reserveBytes: Int64
    let dependencies: Dependencies

    func prefetchToDisk(modelID: String,
                        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        let catalog: [CatalogModel]
        do { catalog = try await dependencies.catalog() } catch {
            try Task.checkCancellation()
            dependencies.log("Autopilot download \(modelID): catalog unavailable: \(error.localizedDescription)")
            throw AutopilotDownloadRefusal.catalogUnavailable
        }
        guard let entry = catalog.first(where: { $0.id == modelID }),
              AutopilotModelSet.isReportableID(modelID),
              AutopilotBuildEligibility.catalogAllows(entry, memoryGb: memoryGb,
                  runtimeCapabilities: runtimeCapabilities),
              entry.r2Prefix != nil, entry.aggregateSHA256 != nil
        else { throw AutopilotDownloadRefusal.modelNotSupported }
        let manifest: ModelManifest
        do { manifest = try await dependencies.manifest(entry) } catch {
            try Task.checkCancellation()
            dependencies.log("Autopilot download \(modelID): manifest unavailable: \(error.localizedDescription)")
            throw AutopilotDownloadRefusal.catalogUnavailable
        }
        guard AutopilotDiskGuard.allows(neededBytes: dependencies.neededBytes(entry, manifest),
            freeBytes: dependencies.freeBytes(entry), reserveBytes: reserveBytes)
        else { throw AutopilotDownloadRefusal.insufficientDisk }
        do {
            try await dependencies.download(entry, manifest, onByteProgress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            dependencies.log("Autopilot download \(modelID) failed: \(error.localizedDescription)")
            throw AutopilotDownloadRefusal.downloadFailed
        }
    }
}

extension AutopilotDownloadPrefetcher.Dependencies {
    /// The catalog client and resumable verified downloader of ordinary
    /// prefetch, with the disk measured where the build will be written.
    static func live(coordinatorURL: String, runtimeCapabilities: Set<ProviderRuntimeCapability>,
                     log: @escaping @Sendable (String) -> Void) -> Self {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)
        let downloader = ModelDownloader(catalogClient: client, runtimeCapabilities: runtimeCapabilities)
        return Self(
            catalog: { try await client.fetchCatalog(typeFilter: "text") },
            manifest: { try await downloader.resolveManifest(model: $0) },
            neededBytes: { _, manifest in
                // A present revision with this manifest's receipt needs no
                // download; anything else is charged its full size, which is
                // conservative for a resumed transfer.
                guard let directory = try? ModelDownloader.revisionSnapshotDirectory(manifest: manifest),
                      let receipt = ModelDownloader.revisionReceipt(at: directory),
                      ModelRevisionIdentity(receipt) == ModelRevisionIdentity(manifest)
                else { return max(0, manifest.totalSizeBytes) }
                return 0
            },
            freeBytes: { entry in
                AutopilotDiskGuard.volumeFreeBytes(at: ModelDownloader.cacheSnapshotDirectory(for: entry.id))
            },
            download: { entry, manifest, progress in
                try await downloader.prefetch(model: entry, manifest: manifest, onByteProgress: progress)
            },
            log: log)
    }
}
