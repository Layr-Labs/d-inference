import Foundation

/// The Macs on which `darkbloom cluster gpu-limit` raises the GPU
/// wired-memory limit for a GLM-5.3-Flash pair rank: M5 Macs with 128 or
/// 256 GiB, read from the chip's own name (`machdep.cpu.brand_string`, which a
/// cluster device profile carries too) and physical memory. The command
/// (`GLM5NextWiredLimit.pairRankRecommendation`) and the plan's advice
/// (`ClusterPlacementFlow.gpuLimitLines`) both ask this, so the plan names the
/// command only where it runs.
public enum GLM5NextGPULimitEligibility {
    static let memoryGiB: [UInt64] = [128, 256]

    public static func applies(chipName: String, physicalMemoryBytes: UInt64) -> Bool {
        guard let chip = ClusterChipClass(chipName: chipName)?.rawValue,
              chip == "apple_m5" || chip.hasPrefix("apple_m5_") else { return false }
        return memoryGiB.contains(physicalMemoryBytes >> 30)
    }

    /// The same, in words: "M5 Macs with 128 or 256 GB".
    public static var macs: String {
        "M5 Macs with " + memoryGiB.map(String.init).joined(separator: " or ") + " GB"
    }
}
