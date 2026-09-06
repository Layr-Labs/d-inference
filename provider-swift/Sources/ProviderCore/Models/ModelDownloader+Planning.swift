import Foundation
import ProviderCoreFoundation

/// Side-effect-free disk admission result for a model download.
///
/// `remainingBytes` is derived from the same manifest, staged-file validation,
/// and `.part` accounting used by ``ModelDownloader`` when it resumes. The
/// capacity sample is taken from the destination volume rather than `/`.
public struct ModelDownloadStoragePlan: Codable, Equatable, Sendable {
    /// Keep this much free after an app-initiated download. The downloader's
    /// normal capacity gate accepts an explicit reserve so non-app callers can
    /// continue to pass zero.
    public static let appReserveBytes = ModelDownloadStorageContract.appReserveBytes

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
        let (requiredSum, requiredOverflow) = remaining.addingReportingOverflow(reserve)
        let required = requiredOverflow ? Int64.max : requiredSum
        let available = availableBytes.map { max(0, $0) }

        self.remainingBytes = remaining
        self.reserveBytes = reserve
        requiredAvailableBytes = required
        self.availableBytes = available
        hasSufficientCapacity = !requiredOverflow
            && (available.map { $0 >= required } ?? false)
    }
}

extension ModelDownloader {
    struct ManifestDownloadDiskState {
        let alreadyValid: [Bool]
        let partBytes: [Int64]
        let remainingBytes: Int64
    }

    /// One read-only classification shared by foreground download, background
    /// prefetch, and app planning. Keeping this in one place prevents any of
    /// those callers from drifting on staged-file or `.part` accounting.
    func inspectManifestDownloadState(
        files: [ManifestFile],
        destinations: [URL]
    ) -> ManifestDownloadDiskState {
        let valid = zip(files, destinations).map { pair in
            Self.fileMatches(
                pair.1,
                size: pair.0.sizeBytes,
                sha256: pair.0.sha256
            )
        }
        let partBytes = destinations.map {
            fileSize($0.appendingPathExtension("part"))
        }
        return ManifestDownloadDiskState(
            alreadyValid: valid,
            partBytes: partBytes,
            remainingBytes: Self.remainingBytesToFetch(
                sizes: files.map(\.sizeBytes),
                alreadyValid: valid,
                partBytes: partBytes
            )
        )
    }

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
        let available = try availableCapacityProvider(snapshotsDirectory)
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
        return inspectManifestDownloadState(
            files: manifest.files,
            destinations: destinations
        ).remainingBytes
    }

    private static func validatePlanningManifest(
        _ manifest: ModelManifest,
        for model: CatalogModel
    ) throws {
        try validateManifestForDownload(manifest, model: model)
    }

    static func catalogSizeBytes(_ model: CatalogModel) -> Int64 {
        ModelCatalogSize.bytes(
            totalSizeBytes: model.totalSizeBytes,
            sizeGB: model.sizeGb
        )
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
        return normalizedAvailableCapacity(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            ordinary: values.volumeAvailableCapacity
        )
    }

    static func normalizedAvailableCapacity(
        importantUsage: Int64?,
        ordinary: Int?
    ) -> Int64? {
        if let importantUsage {
            return max(0, importantUsage)
        }
        if let ordinary {
            return Int64(max(0, ordinary))
        }
        return nil
    }
}
