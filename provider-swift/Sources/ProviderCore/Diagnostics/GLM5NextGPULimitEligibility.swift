import DarkbloomClusterPlacement
import Foundation

/// The Macs on which `darkbloom cluster gpu-limit` raises the GPU
/// wired-memory limit for a GLM-5.3-Flash pair rank: any Apple silicon Mac
/// with 128 GB of memory or more, read from the chip's own name
/// (`machdep.cpu.brand_string`, which a cluster device profile carries too)
/// and physical memory. The command (`GLM5NextWiredLimit.pairRankRecommendation`),
/// the plan's advice (`ClusterPlacementFlow.gpuLimitLines`) and the planner's
/// memory verdict (`ClusterDeviceProfile.withGPUMemoryLimitRaised`) share the
/// one rule, `ClusterGPUMemoryLimit.raisedByDarkbloom`, so nothing offers a
/// raise the command would refuse.
public enum GLM5NextGPULimitEligibility {
    public static func applies(chipName: String, physicalMemoryBytes: UInt64) -> Bool {
        ClusterGPUMemoryLimit.raisedByDarkbloom(chipName: chipName, physicalMemoryBytes: Int(clamping: physicalMemoryBytes))
    }

    /// Why the command does not run on this Mac, in plain words; nil where it does.
    public static func refusal(chipName: String, physicalMemoryBytes: UInt64) -> String? {
        guard ClusterGPUMemoryLimit.isAppleSilicon(chipName: chipName) else { return "it is not an Apple silicon Mac" }
        let gib = physicalMemoryBytes >> 30
        guard gib >= UInt64(ClusterGPUMemoryLimit.minimumRaisableMemoryGiB) else {
            return "it has \(gib) GB of memory; the command needs \(ClusterGPUMemoryLimit.minimumRaisableMemoryGiB) GB or more"
        }
        return nil
    }

    /// The same, in words: "Apple silicon Macs with 128 GB or more".
    public static var macs: String {
        "Apple silicon Macs with \(ClusterGPUMemoryLimit.minimumRaisableMemoryGiB) GB or more"
    }
}
