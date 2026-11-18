import Darwin
import Foundation

/// The kernel's active System Integrity Protection configuration, the value
/// `csr_get_active_config` returns (`<sys/csr.h>`). Zero is Apple's default:
/// every protection on. Each set `CSR_ALLOW_*` bit relaxes one protection.
/// `csrutil enable --without …` sets one or more bits while `csrutil status`
/// still lists most protections as enabled; `csrutil disable` sets most bits;
/// `csrutil authenticated-root disable` sets `CSR_ALLOW_UNAUTHENTICATED_ROOT`.
public struct SIPConfiguration: Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Apple's default configuration: no `CSR_ALLOW_*` bit set.
    public var isDefault: Bool { rawValue == 0 }

    public var hexString: String { "0x" + String(rawValue, radix: 16) }

    /// `CSR_ALLOW_UNAUTHENTICATED_ROOT`, which `csrutil enable` alone leaves set.
    public static let unauthenticatedRootBit: UInt32 = 1 << 11

    public var relaxesAuthenticatedRoot: Bool { rawValue & Self.unauthenticatedRootBit != 0 }

    /// One `CSR_ALLOW_*` flag and the protection it turns off.
    public struct Relaxation: Sendable, Equatable {
        public let bit: UInt32
        public let flag: String
        public let protection: String
    }

    /// Every flag `<sys/csr.h>` documents (`CSR_VALID_FLAGS`), in bit order.
    /// Protection names follow `csrutil status` where it lists the flag.
    public static let documentedRelaxations: [Relaxation] = [
        Relaxation(bit: 1 << 0, flag: "CSR_ALLOW_UNTRUSTED_KEXTS", protection: "Kext Signing"),
        Relaxation(bit: 1 << 1, flag: "CSR_ALLOW_UNRESTRICTED_FS", protection: "Filesystem Protections"),
        Relaxation(bit: 1 << 2, flag: "CSR_ALLOW_TASK_FOR_PID", protection: "Debugging Restrictions"),
        Relaxation(bit: 1 << 3, flag: "CSR_ALLOW_KERNEL_DEBUGGER", protection: "Kernel Debugger Restrictions"),
        Relaxation(bit: 1 << 4, flag: "CSR_ALLOW_APPLE_INTERNAL", protection: "Apple Internal"),
        Relaxation(bit: 1 << 5, flag: "CSR_ALLOW_UNRESTRICTED_DTRACE", protection: "DTrace Restrictions"),
        Relaxation(bit: 1 << 6, flag: "CSR_ALLOW_UNRESTRICTED_NVRAM", protection: "NVRAM Protections"),
        Relaxation(bit: 1 << 7, flag: "CSR_ALLOW_DEVICE_CONFIGURATION", protection: "Device Configuration"),
        Relaxation(bit: 1 << 8, flag: "CSR_ALLOW_ANY_RECOVERY_OS", protection: "BaseSystem Verification"),
        Relaxation(bit: 1 << 9, flag: "CSR_ALLOW_UNAPPROVED_KEXTS", protection: "Kext Approval"),
        Relaxation(bit: 1 << 10, flag: "CSR_ALLOW_EXECUTABLE_POLICY_OVERRIDE", protection: "Executable Policy"),
        Relaxation(bit: SIPConfiguration.unauthenticatedRootBit, flag: "CSR_ALLOW_UNAUTHENTICATED_ROOT",
                   protection: "Authenticated Root Requirement"),
        Relaxation(bit: 1 << 12, flag: "CSR_ALLOW_RESEARCH_GUESTS", protection: "Research Guests"),
    ]

    /// The protections this configuration turns off: documented flags in bit
    /// order, then every other set bit, so no relaxation goes unnamed.
    public var relaxedProtections: [String] {
        var names = Self.documentedRelaxations.filter { rawValue & $0.bit != 0 }.map(\.protection)
        let documented = Self.documentedRelaxations.reduce(UInt32(0)) { $0 | $1.bit }
        var undocumented = rawValue & ~documented
        while undocumented != 0 {
            let lowest = undocumented & (~undocumented &+ 1)
            names.append("undocumented bit 0x" + String(lowest, radix: 16))
            undocumented &= ~lowest
        }
        return names
    }
}

/// Reads the live configuration. libSystem exports `csr_get_active_config` to
/// every process (it is what `csrutil status` reads); it is looked up at run
/// time so the binary carries no link-time import of the private call.
public enum SIPConfigurationReader {
    private typealias GetActiveConfig = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32

    /// nil when the call is missing or fails.
    public static func current() -> SIPConfiguration? {
        // UnsafeMutableRawPointer(bitPattern: -2) is RTLD_DEFAULT.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csr_get_active_config") else {
            return nil
        }
        let getActiveConfig = unsafeBitCast(symbol, to: GetActiveConfig.self)
        var value: UInt32 = 0
        guard getActiveConfig(&value) == 0 else { return nil }
        return SIPConfiguration(rawValue: value)
    }
}
