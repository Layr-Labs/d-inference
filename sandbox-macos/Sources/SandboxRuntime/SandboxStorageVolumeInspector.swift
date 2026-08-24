import Foundation

public struct SandboxStorageVolumeReport: Equatable, Sendable {
    public let path: URL
    public let availableImportantBytes: UInt64

    public init(path: URL, availableImportantBytes: UInt64) {
        self.path = path
        self.availableImportantBytes = availableImportantBytes
    }
}

public enum SandboxStorageVolumeInspectionError: Error, Equatable, Sendable {
    case invalidPath
    case capacityUnavailable
}

public struct SandboxStorageVolumeInspector: Sendable {
    public init() {}

    public func inspect(path: URL) throws -> SandboxStorageVolumeReport {
        guard path.isFileURL,
              path.baseURL == nil,
              path.path.hasPrefix("/")
        else {
            throw SandboxStorageVolumeInspectionError.invalidPath
        }
        let normalized = path.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try normalized.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
            ])
        } catch {
            throw SandboxStorageVolumeInspectionError.capacityUnavailable
        }
        guard let available = values
            .volumeAvailableCapacityForImportantUsage,
            available >= 0
        else {
            throw SandboxStorageVolumeInspectionError.capacityUnavailable
        }
        return SandboxStorageVolumeReport(
            path: normalized,
            availableImportantBytes: UInt64(available)
        )
    }
}
