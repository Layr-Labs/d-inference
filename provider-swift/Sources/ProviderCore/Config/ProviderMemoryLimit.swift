import Foundation

public enum ProviderMemoryLimit {
    private static let bytesPerGiB: UInt64 = 1024 * 1024 * 1024

    public static func effectiveHardware(
        _ hardware: HardwareInfo,
        settings: ProviderSettings
    ) -> HardwareInfo {
        effectiveHardware(
            hardware,
            limitGB: settings.memoryLimitGB,
            reserveGB: settings.memoryReserveGB
        )
    }

    public static func effectiveHardware(
        _ hardware: HardwareInfo,
        limitGB: UInt64?,
        reserveGB: UInt64
    ) -> HardwareInfo {
        let effectiveMemory = effectiveMemoryGB(
            physicalGB: hardware.memoryGb,
            limitGB: limitGB
        )
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

    public static func effectiveTotalBytes(
        physicalBytes: UInt64,
        limitGB: UInt64?
    ) -> UInt64 {
        guard let limitGB, limitGB > 0 else {
            return physicalBytes
        }
        let limitBytes = saturatingGiBToBytes(limitGB)
        return min(physicalBytes, limitBytes)
    }

    public static func limitBytes(limitGB: UInt64?) -> UInt64? {
        guard let limitGB, limitGB > 0 else { return nil }
        return saturatingGiBToBytes(limitGB)
    }

    private static func effectiveMemoryGB(
        physicalGB: UInt64,
        limitGB: UInt64?
    ) -> UInt64 {
        guard let limitGB, limitGB > 0 else {
            return physicalGB
        }
        return min(physicalGB, limitGB)
    }

    private static func saturatingGiBToBytes(_ gb: UInt64) -> UInt64 {
        let (bytes, overflow) = gb.multipliedReportingOverflow(by: bytesPerGiB)
        return overflow ? UInt64.max : bytes
    }
}
