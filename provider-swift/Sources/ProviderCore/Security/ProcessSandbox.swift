import Foundation

/// Whether this process runs inside a macOS sandbox. Darkbloom never sandboxes
/// its own process (no App Sandbox entitlement, no `sandbox_init`), so a
/// sandbox here was set up by whatever started it, and the boot-security
/// reads made from inside it can't be trusted.
public enum ProcessSandbox: Sendable, Equatable {
    case notSandboxed
    /// Inside a sandbox Darkbloom didn't set up: Darkbloom serving stays off.
    case sandboxed
    /// The check is missing or failed: a warning.
    case unknown

    /// `sandbox_check(pid, NULL, SANDBOX_FILTER_NONE)` answers 1 for a
    /// sandboxed process, 0 for one that isn't, and -1 on error.
    public init(sandboxCheckResult: Int32) {
        switch sandboxCheckResult {
        case 0: self = .notSandboxed
        case 1: self = .sandboxed
        default: self = .unknown
        }
    }

    private typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

    /// This process. libSystem exports `sandbox_check` to every process; like
    /// `csr_get_active_config` (`SIPConfigurationReader`) it is looked up at
    /// run time. No filter argument follows the fixed ones, so the variadic
    /// call is safe through this signature.
    public static func current() -> ProcessSandbox {
        // UnsafeMutableRawPointer(bitPattern: -2) is RTLD_DEFAULT.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return .unknown }
        let sandboxCheck = unsafeBitCast(symbol, to: SandboxCheck.self)
        return ProcessSandbox(sandboxCheckResult: sandboxCheck(getpid(), nil, 0))
    }
}
