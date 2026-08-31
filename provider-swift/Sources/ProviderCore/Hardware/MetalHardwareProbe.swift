import Foundation
#if canImport(Metal)
import Metal
#endif

/// Metal availability facts for supervisor diagnostics. This type deliberately
/// has no MLX dependency and never creates or mutates inference runtime state.
public enum MetalHardwareProbe {
    public struct Status: Sendable, Equatable {
        public let isAvailable: Bool
        public let deviceName: String?
        public let recommendedMaxWorkingSetSizeBytes: UInt64

        public static let unavailable = Status(
            isAvailable: false,
            deviceName: nil,
            recommendedMaxWorkingSetSizeBytes: 0)
    }

    public static func probe() -> Status {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unavailable
        }
        return Status(
            isAvailable: true,
            deviceName: device.name,
            recommendedMaxWorkingSetSizeBytes:
                device.recommendedMaxWorkingSetSize)
        #else
        return .unavailable
        #endif
    }
}
