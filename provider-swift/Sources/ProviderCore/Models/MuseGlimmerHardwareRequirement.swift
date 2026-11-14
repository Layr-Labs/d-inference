// Copyright © 2026 Eigen Labs.

import Foundation
import Metal

/// Muse Glimmer 30B serves only on an Apple M5 Ultra: the Mac its row-exact
/// kernels, numerics profile and admission floors were qualified on. The
/// provider reports `muse_glimmer_v1` only when this gate passes, so older
/// builds and other Macs fail closed in catalog eligibility: the model is
/// neither advertised nor loaded (`ModelRuntimeRequirements`).
///
/// Both the hardware report (`machdep.cpu.brand_string`) and the Metal device
/// the runtime would use must name the chip.
public enum MuseGlimmerHardwareRequirement {
    public static let metalDeviceName = "Apple M5 Ultra"

    /// Why this Mac may not serve the model, nil when it may. The Metal
    /// device is read only once the hardware report names an M5 Ultra.
    public static func refusal(
        chipFamily: ChipFamily, chipTier: ChipTier, metalDeviceName: () -> String?
    ) -> String? {
        let chip = chipTier == .base ? chipFamily.rawValue : "\(chipFamily.rawValue) \(chipTier.rawValue)"
        guard chipFamily == .m5, chipTier == .ultra else {
            return "Muse Glimmer 30B requires an \(Self.metalDeviceName); this Mac is \(chip)"
        }
        let device = metalDeviceName()
        guard device == Self.metalDeviceName else {
            return "Muse Glimmer 30B requires an \(Self.metalDeviceName); this Mac's Metal device is "
                + (device.map { "\"\($0)\"" } ?? "unavailable")
        }
        return nil
    }

    public static func refusal(hardware: HardwareInfo, metalDeviceName: () -> String? = liveMetalDeviceName) -> String? {
        refusal(chipFamily: hardware.chipFamily, chipTier: hardware.chipTier, metalDeviceName: metalDeviceName)
    }

    /// The system default Metal device's name, the device MLX runs on.
    public static func liveMetalDeviceName() -> String? {
        MTLCreateSystemDefaultDevice()?.name
    }
}
