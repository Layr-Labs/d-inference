import Foundation
import DarkbloomClusterPlacement

/// TEST ONLY, never offered to a user: the developer bench override that makes
/// this Mac check and plan its cluster ranks as another Apple silicon chip
/// (for example two bench Macs standing in for two M4 Max Macs), so the
/// chip-agnostic grant rule can be shown on hardware the bench does not have.
///
/// Set `DARKBLOOM_DEV_BENCH_CHIP` to a chip name as the system spells it
/// ("Apple M4 Max"). Only a debug build reads it: `ClusterChipClass.local()`
/// then returns that chip's class, and the onboarding plans and offers with
/// that chip name in both profiles of this Mac's planning. A release build
/// ignores it for rank checks and refuses to plan while it is set, so a signed
/// install is never planned from it by accident. Memory, speed and every load
/// gate stay on the Mac's real hardware (cap memory with
/// `ClusterPlannerBenchCap`).
public enum ClusterBenchChip {
    public static let environmentName = "DARKBLOOM_DEV_BENCH_CHIP"

    /// Whether this binary was built for development (SwiftPM's debug configuration).
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The chip name to use, nil when unset or in a release build. A value
    /// that names no chip class is ignored (the real chip is used).
    public static func chipName(environment: [String: String], debugBuild: Bool = isDebugBuild) -> String? {
        guard debugBuild, let value = environment[environmentName], value.utf8.count <= 64,
              ClusterChipClass(chipName: value) != nil else { return nil }
        return value
    }

    /// The planner's half: the chip name both profiles carry while planning,
    /// nil when unset. A release build refuses to plan while it is set.
    public static func planningChipName(environment: [String: String], debugBuild: Bool = isDebugBuild) throws -> String? {
        guard environment[environmentName] != nil else { return nil }
        guard debugBuild else {
            throw ClusterConfigurationError.invalid("\(environmentName) is a developer bench override and is not available in a release build; "
                + "unset it to plan this pair on its real chips")
        }
        guard let name = chipName(environment: environment, debugBuild: true) else {
            throw ClusterConfigurationError.invalid("\(environmentName) must name an Apple silicon chip as the system spells it, e.g. \"Apple M4 Max\"")
        }
        return name
    }

    /// The words a plan made under the override starts with.
    static func lines(chipName: String) -> [String] {
        ["Developer bench chip (\(environmentName)=\(chipName))",
         "  This plan is test only: both Macs are planned and checked as \(chipName). Memory and speed are as detected; "
            + "each Mac's load gate is unchanged."]
    }
}

extension ClusterDeviceProfile {
    /// TEST ONLY (`ClusterBenchChip`): this profile with another chip name, for
    /// planning. Memory, cores, speed index and power stay as detected. A
    /// profile only carries a device index measured on its own chip and build,
    /// so the measured index moves to the bench name with its figures unchanged
    /// (else every Mac that has probed its speed fails validation).
    func renamedForBench(chip name: String) throws -> ClusterDeviceProfile {
        guard name != chip else { return self }
        var value = try ClusterDeviceProfile(chip: name, performanceCores: performanceCores, efficiencyCores: efficiencyCores,
            gpuCores: gpuCores, osVersion: osVersion, osBuild: osBuild, physicalMemoryBytes: physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: gpuMaximumBufferBytes,
            allocatorLimitBytes: allocatorLimitBytes, memory: memory, power: power, wiredLimitBytes: wiredLimitBytes)
        value.speedIndex = speedIndex.map { ClusterDeviceIndex(chip: name, osBuild: $0.osBuild, benchmark: $0.benchmark,
            prefillIndex: $0.prefillIndex, decodeIndex: $0.decodeIndex) }
        try value.validate()
        return value
    }
}
