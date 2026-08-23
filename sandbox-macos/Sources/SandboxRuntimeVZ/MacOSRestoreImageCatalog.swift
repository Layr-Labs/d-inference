import Foundation
import SandboxRuntime
import Virtualization

public struct MacOSRestoreImageRecord: Codable, Equatable, Sendable {
    public let url: URL
    public let buildVersion: String
    public let operatingSystemVersion: String
    public let minimumCPUCount: Int
    public let minimumMemoryBytes: UInt64
    public let hardwareModelData: Data

    public init(
        url: URL,
        buildVersion: String,
        operatingSystemVersion: String,
        minimumCPUCount: Int,
        minimumMemoryBytes: UInt64,
        hardwareModelData: Data
    ) {
        self.url = url
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.minimumCPUCount = minimumCPUCount
        self.minimumMemoryBytes = minimumMemoryBytes
        self.hardwareModelData = hardwareModelData
    }
}

public enum MacOSRestoreImageError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedHost
    case noSupportedConfiguration

    public var description: String {
        switch self {
        case .unsupportedHost:
            return "this host cannot fetch a supported macOS restore image"
        case .noSupportedConfiguration:
            return "the restore image has no configuration supported by this host"
        }
    }
}

public struct MacOSRestoreImageCatalog: Sendable {
    public init() {}

    public func latestSupported() async throws -> MacOSRestoreImageRecord {
        let image = try await fetchLatestSupported()
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw MacOSRestoreImageError.noSupportedConfiguration
        }
        return MacOSRestoreImageRecord(
            url: image.url,
            buildVersion: image.buildVersion,
            operatingSystemVersion: Self.versionString(image.operatingSystemVersion),
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemoryBytes: requirements.minimumSupportedMemorySize,
            hardwareModelData: requirements.hardwareModel.dataRepresentation
        )
    }

    private func fetchLatestSupported() async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
