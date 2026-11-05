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

    /// The least memory, in GiB, of a Mac Darkbloom raises the limit on.
    public static let minimumRaisableMemoryGiB = 128

    /// Whether the chip's own name ("Apple M<generation>", then at most one of Pro, Max or Ultra) is Apple silicon, of
    /// any M generation. An Intel name, a virtual machine ("Apple M5 (Virtual)") or anything else is not.
    public static func isAppleSilicon(chipName: String) -> Bool {
        let words = chipName.lowercased().split(separator: " ").map(String.init)
        guard (2...3).contains(words.count), words[0] == "apple", words[1].count >= 2, words[1].first == "m",
              words[1].dropFirst().allSatisfy(\.isASCII), words[1].dropFirst().allSatisfy(\.isNumber),
              words[1].dropFirst().first != "0" else { return false }
        return words.count == 2 || ["pro", "max", "ultra"].contains(words[2])
    }

    /// Whether Darkbloom raises this Mac's limit (`darkbloom cluster gpu-limit`, with its owner's consent): any Apple
    /// silicon Mac with 128 GB of memory or more (owner, 2026-11-05: "yes widen, why wouldn't we"), whatever its
    /// generation. On any other Mac the limit is what macOS keeps, and a plan is held to it.
    public static func raisedByDarkbloom(chipName: String, physicalMemoryBytes: Int) -> Bool {
        isAppleSilicon(chipName: chipName) && physicalMemoryBytes >> 30 >= minimumRaisableMemoryGiB
    }
}

extension ClusterDeviceProfile {
    /// The most this Mac's GPU may be given (`ClusterGPUMemoryLimit.ceilingBytes`).
    public var gpuMemoryLimitCeilingBytes: Int { ClusterGPUMemoryLimit.ceilingBytes(physicalMemoryBytes: physicalMemoryBytes) }

    /// This profile as it reads once its GPU limit is raised to the ceiling; nil when the limit is already there or
    /// above, so raising it would change nothing, or when Darkbloom does not raise this Mac's limit
    /// (`ClusterGPUMemoryLimit.raisedByDarkbloom`), so no raise is offered that nothing would make.
    public func withGPUMemoryLimitRaised() throws -> ClusterDeviceProfile? {
        let ceiling = gpuMemoryLimitCeilingBytes
        guard ClusterGPUMemoryLimit.raisedByDarkbloom(chipName: chip, physicalMemoryBytes: physicalMemoryBytes),
              ceiling > residentCapacityBytes else { return nil }
        var raised = try ClusterDeviceProfile(chip: chip, performanceCores: performanceCores, efficiencyCores: efficiencyCores,
            gpuCores: gpuCores, osVersion: osVersion, osBuild: osBuild, physicalMemoryBytes: physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: gpuMaximumBufferBytes,
            allocatorLimitBytes: allocatorLimitBytes, memory: memory, power: power, wiredLimitBytes: ceiling)
        raised.speedIndex = speedIndex
        return raised
    }
}
