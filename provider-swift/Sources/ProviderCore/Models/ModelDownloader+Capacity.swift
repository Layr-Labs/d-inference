import Foundation

extension ModelDownloader {
    /// Legacy/non-app capacity gate. A zero-reserve caller preserves the
    /// historical fail-open behavior when the filesystem reports no capacity.
    internal static func ensureAvailableCapacity(
        at directory: URL,
        requiredBytes: Int64
    ) throws {
        try validateAvailableCapacity(
            remainingBytes: requiredBytes,
            reserveBytes: 0,
            availableBytes: try availableCapacity(at: directory),
            unknownCapacityAllowed: true
        )
    }

    /// Authoritative foreground gate. App callers pass a nonzero reserve, so
    /// unknown filesystem capacity is a refusal rather than an optimistic start.
    func ensureAvailableCapacity(
        at directory: URL,
        remainingBytes: Int64,
        reserveBytes: Int64
    ) throws {
        try Self.validateAvailableCapacity(
            remainingBytes: remainingBytes,
            reserveBytes: reserveBytes,
            availableBytes: try availableCapacityProvider(directory),
            unknownCapacityAllowed: reserveBytes == 0
        )
    }

    static func validateAvailableCapacity(
        remainingBytes: Int64,
        reserveBytes: Int64,
        availableBytes: Int64?,
        unknownCapacityAllowed: Bool
    ) throws {
        guard remainingBytes >= 0, reserveBytes >= 0 else {
            throw ModelCatalogError.downloadFailed(
                "invalid negative disk-capacity requirement"
            )
        }
        let (required, overflow) = remainingBytes.addingReportingOverflow(
            reserveBytes
        )
        guard !overflow else {
            throw ModelCatalogError.downloadFailed(
                "disk-capacity requirement overflow"
            )
        }
        guard let availableBytes else {
            if unknownCapacityAllowed { return }
            throw ModelCatalogError.downloadFailed(
                "could not determine available disk space for the required "
                    + "\(required)-byte download capacity"
            )
        }
        let available = max(0, availableBytes)
        guard available >= required else {
            throw ModelCatalogError.downloadFailed(
                "insufficient disk space: need \(required) bytes including "
                    + "\(reserveBytes) bytes reserved, available \(available) bytes"
            )
        }
    }
}
