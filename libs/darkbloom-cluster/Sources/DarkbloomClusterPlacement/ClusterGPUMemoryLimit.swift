import Foundation

/// The GPU's wired-memory limit (`iogpu.wired_limit_mb`): how much of a Mac's memory the GPU may keep resident
/// at once. While it is 0, macOS's default, the limit is Metal's recommended working set: 107.52 GiB of a
/// 128 GiB M5 Max and 222.72 GiB of a 256 GiB M3 Ultra, as their recorded profiles report it. A command buffer
/// past it fails with "Insufficient Memory".
///
/// Darkbloom raises it at most to `ceilingBytes`: physical memory less `reserveBytes`, which stays for macOS and
/// its applications. The reserve is 16 GiB, what the production 256 GB GLM hosts leave
/// (`iogpu.wired_limit_mb=245760`, `GLM5NextWiredLimit`) and the least a stage's residency leaves unwired on any
/// Mac (`ClusterStageResidency.ceiling`); on a Mac whose macOS wires more than that at rest (a sixteenth of
/// memory, `ClusterDeviceProfile.systemWiredBytes`: 32 GiB of 512 GiB) the reserve is that share instead.
public enum ClusterGPUMemoryLimit {
    public static let minimumReserveBytes = 16 << 30

    public static func reserveBytes(physicalMemoryBytes: Int) -> Int {
        max(minimumReserveBytes, ClusterDeviceProfile.systemWiredBytes(physical: physicalMemoryBytes))
    }

    /// The highest limit Darkbloom sets, in whole MiB (the sysctl's unit); 0 when the Mac has no more than the reserve.
    public static func ceilingMegabytes(physicalMemoryBytes: Int) -> Int {
        max(0, physicalMemoryBytes - reserveBytes(physicalMemoryBytes: physicalMemoryBytes)) >> 20
    }

    public static func ceilingBytes(physicalMemoryBytes: Int) -> Int {
        ceilingMegabytes(physicalMemoryBytes: physicalMemoryBytes) << 20
    }
}

extension ClusterDeviceProfile {
    /// The most this Mac's GPU may be given (`ClusterGPUMemoryLimit.ceilingBytes`).
    public var gpuMemoryLimitCeilingBytes: Int { ClusterGPUMemoryLimit.ceilingBytes(physicalMemoryBytes: physicalMemoryBytes) }

    /// This profile as it reads once its GPU limit is raised to the ceiling; nil when the limit is already there or
    /// above, so raising it would change nothing.
    public func withGPUMemoryLimitRaised() throws -> ClusterDeviceProfile? {
        let ceiling = gpuMemoryLimitCeilingBytes
        guard ceiling > residentCapacityBytes else { return nil }
        var raised = try ClusterDeviceProfile(chip: chip, performanceCores: performanceCores, efficiencyCores: efficiencyCores,
            gpuCores: gpuCores, osVersion: osVersion, osBuild: osBuild, physicalMemoryBytes: physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: gpuMaximumBufferBytes,
            allocatorLimitBytes: allocatorLimitBytes, memory: memory, power: power, wiredLimitBytes: ceiling)
        raised.speedIndex = speedIndex
        return raised
    }
}
