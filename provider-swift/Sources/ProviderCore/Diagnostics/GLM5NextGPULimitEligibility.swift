import DarkbloomClusterPlacement
import Foundation

/// The Macs on which `darkbloom cluster gpu-limit` raises the GPU
/// wired-memory limit for a GLM-5.3-Flash pair rank: M5 Macs with 128 or
/// 256 GiB, read from the chip's own name (`machdep.cpu.brand_string`, which a
/// cluster device profile carries too) and physical memory. The command
/// (`GLM5NextWiredLimit.pairRankRecommendation`), the plan's advice
/// (`ClusterPlacementFlow.gpuLimitLines`) and the planner's memory verdict
/// (`ClusterDeviceProfile.withGPUMemoryLimitRaised`) share the one rule,
/// `ClusterGPUMemoryLimit.raisedByDarkbloom`, so nothing offers a raise the
/// command would refuse.
public enum GLM5NextGPULimitEligibility {
    static var memoryGiB: [UInt64] { ClusterGPUMemoryLimit.raisableMemoryGiB.map(UInt64.init) }

    public static func applies(chipName: String, physicalMemoryBytes: UInt64) -> Bool {
        ClusterGPUMemoryLimit.raisedByDarkbloom(chipName: chipName, physicalMemoryBytes: Int(clamping: physicalMemoryBytes))
    }

    /// The same, in words: "M5 Macs with 128 or 256 GB".
    public static var macs: String {
        "M5 Macs with " + memoryGiB.map(String.init).joined(separator: " or ") + " GB"
    }
}
