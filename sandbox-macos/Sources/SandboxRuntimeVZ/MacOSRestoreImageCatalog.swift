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
    case fetchFailed(String)

    public var description: String {
        switch self {
        case .unsupportedHost:
            return "this host cannot fetch a supported macOS restore image"
        case .noSupportedConfiguration:
            return "the restore image has no configuration supported by this host"
        case .fetchFailed(let message):
            return "failed to fetch the supported macOS restore image: \(message)"
        }
    }
}

public struct MacOSRestoreImageCatalog: Sendable {
    public init() {}

    public func latestSupported() async throws -> MacOSRestoreImageRecord {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image):
                    do {
                        continuation.resume(returning: try Self.makeRecord(from: image))
                    } catch {
                        continuation.resume(
                            throwing: MacOSRestoreImageError.fetchFailed(
                                String(describing: error)
                            )
                        )
                    }
                case .failure(let error):
                    continuation.resume(
                        throwing: MacOSRestoreImageError.fetchFailed(
                            String(describing: error)
                        )
                    )
                }
            }
        }
    }

    private static func makeRecord(
        from image: VZMacOSRestoreImage
    ) throws -> MacOSRestoreImageRecord {
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

    private static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
