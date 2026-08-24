import Foundation

/// Side-effect-free disk admission result for a model download.
///
/// `remainingBytes` is derived from the same manifest, staged-file validation,
/// and `.part` accounting used by ``ModelDownloader`` when it resumes. The
/// capacity sample is taken from the destination volume rather than `/`.
public struct ModelDownloadStoragePlan: Codable, Equatable, Sendable {
    /// Keep this much free after an app-initiated download. The downloader's
    /// normal capacity gate accepts an explicit reserve so non-app callers can
    /// continue to pass zero.
    public static let appReserveBytes: Int64 = 2 * 1_073_741_824

    public let remainingBytes: Int64
    public let reserveBytes: Int64
    public let requiredAvailableBytes: Int64
    public let availableBytes: Int64?
    public let hasSufficientCapacity: Bool

    enum CodingKeys: String, CodingKey {
        case remainingBytes = "remaining_bytes"
        case reserveBytes = "reserve_bytes"
        case requiredAvailableBytes = "required_available_bytes"
        case availableBytes = "available_bytes"
        case hasSufficientCapacity = "has_sufficient_capacity"
    }

    init(remainingBytes: Int64, reserveBytes: Int64, availableBytes: Int64?) {
        let remaining = max(0, remainingBytes)
        let reserve = max(0, reserveBytes)
        let required = remaining > Int64.max - reserve
            ? Int64.max
            : remaining + reserve
        let available = availableBytes.flatMap { $0 > 0 ? $0 : nil }

        self.remainingBytes = remaining
        self.reserveBytes = reserve
        requiredAvailableBytes = required
        self.availableBytes = available
        // Preserve the downloader's existing fail-open behavior when the
        // filesystem does not report usable capacity.
        hasSufficientCapacity = available.map { $0 >= required } ?? true
    }
}

extension ModelDownloader {
    /// Plan a foreground manifest download without creating, deleting, moving,
    /// or modifying any cache content.
    ///
    /// A fresh download can use the catalog total directly. A resumable build
    /// resolves its manifest and validates completed staged files exactly as the
    /// downloader does; only valid files and bounded `.part` prefixes receive
    /// credit.
    public func storagePlan(
        for model: CatalogModel,
        reserveBytes: Int64 = ModelDownloadStoragePlan.appReserveBytes
    ) async throws -> ModelDownloadStoragePlan {
        let remaining = try await remainingForegroundDownloadBytes(for: model)
        let snapshotsDirectory = Self.cacheSnapshotDirectory(for: model.id)
            .deletingLastPathComponent()
        let available = try Self.availableCapacity(at: snapshotsDirectory)
        return ModelDownloadStoragePlan(
            remainingBytes: remaining,
            reserveBytes: reserveBytes,
            availableBytes: available
        )
    }

    private func remainingForegroundDownloadBytes(for model: CatalogModel) async throws -> Int64 {
        let fullSize = Self.catalogSizeBytes(model)
        guard let prefix = model.r2Prefix,
              model.aggregateSHA256 != nil,
              Self.hasResumableStaging(modelID: model.id, r2Prefix: prefix)
        else {
            return fullSize
        }

        let manifest = try await resolveManifest(model: model)
        try Self.validatePlanningManifest(manifest, for: model)

        let stagingDirectory = Self.cacheSnapshotDirectory(for: model.id)
            .deletingLastPathComponent()
            .appendingPathComponent(
                Self.localStagingDirName(r2Prefix: manifest.r2Prefix),
                isDirectory: true
            )
        let destinations = try manifest.files.map { file in
            stagingDirectory.appendingPathComponent(
                try Self.validatedManifestRelativePath(file.path),
                isDirectory: false
            )
        }
        let valid = zip(manifest.files, destinations).map { file, destination in
            Self.fileMatches(destination, size: file.sizeBytes, sha256: file.sha256)
        }
        let partBytes = destinations.map {
            fileSize($0.appendingPathExtension("part"))
        }
        return Self.remainingBytesToFetch(
            sizes: manifest.files.map(\.sizeBytes),
            alreadyValid: valid,
            partBytes: partBytes
        )
    }

    private static func validatePlanningManifest(
        _ manifest: ModelManifest,
        for model: CatalogModel
    ) throws {
        guard manifest.modelID == model.id else {
            throw ModelCatalogError.downloadFailed(
                "manifest model_id \(manifest.modelID) does not match catalog id \(model.id)"
            )
        }
        guard manifest.files.count == manifest.fileCount, !manifest.files.isEmpty else {
            throw ModelCatalogError.downloadFailed("manifest files do not match file_count")
        }
        if let aggregate = model.aggregateSHA256,
           aggregate != manifest.aggregateSHA256 {
            throw ModelCatalogError.downloadFailed(
                "catalog aggregate hash does not match manifest"
            )
        }
        if let prefix = model.r2Prefix, prefix != manifest.r2Prefix {
            throw ModelCatalogError.downloadFailed(
                "catalog r2_prefix does not match manifest"
            )
        }
    }

    private static func catalogSizeBytes(_ model: CatalogModel) -> Int64 {
        if let exact = model.totalSizeBytes {
            return max(0, exact)
        }
        let estimate = (model.sizeGb * 1_000_000_000).rounded()
        guard estimate.isFinite, estimate > 0 else { return 0 }
        return estimate >= Double(Int64.max) ? Int64.max : Int64(estimate)
    }

    /// Capacity reported for the volume that will hold `directory`. When the
    /// destination has not been created yet, walk to its nearest existing
    /// ancestor without mutating the filesystem.
    static func availableCapacity(at directory: URL) throws -> Int64? {
        let fileManager = FileManager.default
        var probe = directory.standardizedFileURL
        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { break }
            probe = parent
        }

        let values = try probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return available > 0 ? available : nil
    }
}
