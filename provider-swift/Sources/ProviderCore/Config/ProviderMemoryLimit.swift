import Foundation

public enum ProviderMemoryLimit {
    private static let bytesPerGiB: UInt64 = 1024 * 1024 * 1024
    private static let maxWholeGiBBeforeOverflow = UInt64.max / bytesPerGiB

    public struct EffectiveBytes: Sendable, Equatable {
        public let totalBytes: UInt64
        public let limitBytes: UInt64?
    }

    public static func effectiveHardware(
        _ hardware: HardwareInfo,
        limitGB: UInt64?,
        reserveGB: UInt64
    ) -> HardwareInfo {
        let effectiveMemory = applyLimit(hardware.memoryGb, limit: limitGB)
        let effectiveAvailable = effectiveMemory > reserveGB
            ? effectiveMemory - reserveGB
            : 0

        return HardwareInfo(
            machineModel: hardware.machineModel,
            chipName: hardware.chipName,
            chipFamily: hardware.chipFamily,
            chipTier: hardware.chipTier,
            memoryGb: effectiveMemory,
            memoryAvailableGb: min(hardware.memoryAvailableGb, effectiveAvailable),
            cpuCores: hardware.cpuCores,
            gpuCores: hardware.gpuCores,
            memoryBandwidthGbs: hardware.memoryBandwidthGbs
        )
    }

    public static func effectiveBytes(
        physicalBytes: UInt64,
        limitGB: UInt64?
    ) -> EffectiveBytes {
        let bytes = limitBytes(limitGB: limitGB)
        return EffectiveBytes(
            totalBytes: applyLimit(physicalBytes, limit: bytes),
            limitBytes: bytes
        )
    }

    public static func limitBytes(limitGB: UInt64?) -> UInt64? {
        guard let limitGB, limitGB > 0 else { return nil }
        return saturatingGiBToBytes(limitGB)
    }

    private static func applyLimit(_ value: UInt64, limit: UInt64?) -> UInt64 {
        guard let limit, limit > 0 else { return value }
        return min(value, limit)
    }

    private static func saturatingGiBToBytes(_ gb: UInt64) -> UInt64 {
        guard gb <= maxWholeGiBBeforeOverflow else {
            return UInt64.max
        }
        return gb * bytesPerGiB
    }
}
