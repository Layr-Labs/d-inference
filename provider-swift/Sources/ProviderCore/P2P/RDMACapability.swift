import Foundation
#if canImport(os)
import os
#endif

// MARK: - RDMACapability
//
// Capability gate for --rdma-enabled. The operator can pass the flag, but the
// binary itself decides whether to honor it. Honor requires:
//
//   1. Chip family is M5 or later. Earlier Apple Silicon lacks the Thunderbolt 5
//      RDMA controllers needed for cluster pipeline inference.
//   2. /usr/bin/rdma_ctl reports "enabled". RDMA is opt-in at the OS level and
//      requires booting into Recovery OS to enable; an M5 with RDMA still off
//      cannot participate.
//
// If either check fails, callers MUST coerce the effective flag to false. The
// attestation blob carries the effective value (signed by the SE), so the
// coordinator sees the hardware-validated answer — not the operator's intent.

public enum RDMACapability: Sendable {

    /// Returns true if this Mac can honor --rdma-enabled.
    ///
    /// Pure capability check — no side effects. Reads chip family from the
    /// system and shells out to rdma_ctl.
    public static func isAvailable() -> Bool {
        guard isM5OrLater() else { return false }
        return rdmaCtlReportsEnabled()
    }

    /// Returns a short reason describing why capability is unavailable, or
    /// nil if available. Suitable for operator-facing warnings.
    public static func unavailableReason() -> String? {
        if !isM5OrLater() {
            return "this Mac is not M5 or later (Thunderbolt 5 RDMA requires M5)"
        }
        if !rdmaCtlReportsEnabled() {
            return "rdma_ctl reports RDMA disabled (enable via Recovery OS: `rdma_ctl enable`)"
        }
        return nil
    }

    // MARK: - Internals

    /// True if the current chip family is M5 or later.
    static func isM5OrLater() -> Bool {
        guard let info = try? HardwareDetector.detect() else { return false }
        return chipFamilyIsM5OrLater(info.chipFamily)
    }

    /// True if /usr/bin/rdma_ctl status returns "enabled".
    ///
    /// Mirrors the negation of checkRDMADisabled() in SecurityHardening.swift —
    /// kept as a separate function here so the capability check is testable
    /// and self-contained without pulling in the security check's "safe if
    /// missing" semantics. For capability the rule is opposite: rdma_ctl
    /// missing or reporting anything other than "enabled" means RDMA is not
    /// available.
    static func rdmaCtlReportsEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rdma_ctl")
        process.arguments = ["status"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "enabled"
    }
}

/// Helper exposed for unit tests so we can validate the family comparison
/// without spinning up real hardware.
internal func chipFamilyIsM5OrLater(_ family: ChipFamily) -> Bool {
    switch family {
    case .m5:
        return true
    case .m1, .m2, .m3, .m4, .unknown:
        return false
    }
}
