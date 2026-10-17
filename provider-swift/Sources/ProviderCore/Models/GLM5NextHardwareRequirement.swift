import Foundation

/// GLM-5.3-Flash serves only on Apple M5 Max or M5 Ultra with at least 256 GiB
/// of unified memory. The provider reports `glm5_next_v1` only when this gate
/// passes, so older providers and other Macs fail closed in catalog eligibility.
public enum GLM5NextHardwareRequirement {
    /// Physical unified memory in GiB as `HardwareDetector` reports it; Apple's
    /// "256 GB" configuration is exactly 256 GiB.
    public static let minimumMemoryGiB: UInt64 = 256
    public static let qualifyingTiers: Set<ChipTier> = [.max, .ultra]

    public static func refusal(chipFamily: ChipFamily, chipTier: ChipTier, memoryGiB: UInt64) -> String? {
        guard chipFamily != .m5 || !qualifyingTiers.contains(chipTier) || memoryGiB < minimumMemoryGiB
        else { return nil }
        let chip = chipTier == .base ? chipFamily.rawValue : "\(chipFamily.rawValue) \(chipTier.rawValue)"
        return "GLM-5.3-Flash requires Apple M5 Max or M5 Ultra with at least \(minimumMemoryGiB) GB "
            + "unified memory; this Mac is \(chip) with \(memoryGiB) GB"
    }

    public static func refusal(hardware: HardwareInfo) -> String? {
        refusal(chipFamily: hardware.chipFamily, chipTier: hardware.chipTier, memoryGiB: hardware.memoryGb)
    }
}
