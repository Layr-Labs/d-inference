import Foundation
import ProviderSandboxCheck

/// Whether this process runs inside a macOS sandbox. Darkbloom never sandboxes
/// its own process (no App Sandbox entitlement, no `sandbox_init`), so a
/// sandbox here was set up by whatever started it, and Darkbloom can't verify
/// the Mac's boot security from inside it. Process-local: it answers for the
/// process that asks.
public enum ProcessSandbox: Sendable, Equatable {
    case notSandboxed
    /// Inside a sandbox Darkbloom didn't set up: Darkbloom serving stays off.
    case sandboxed
    /// The check is missing or failed: a warning.
    case unknown

    /// `provider_sandbox_check_self()`: 1 for a sandboxed process, 0 for one
    /// that isn't, anything else (an error, a missing call) unknown.
    public init(sandboxCheckResult: Int32) {
        switch sandboxCheckResult {
        case 0: self = .notSandboxed
        case 1: self = .sandboxed
        default: self = .unknown
        }
    }

    /// This process (`sandbox_check` through its C prototype).
    public static func current() -> ProcessSandbox {
        ProcessSandbox(sandboxCheckResult: provider_sandbox_check_self())
    }

    public var telemetryValue: String {
        switch self {
        case .notSandboxed: return "not_sandboxed"
        case .sandboxed: return "sandboxed"
        case .unknown: return "unknown"
        }
    }
}
