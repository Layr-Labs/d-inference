import Foundation

/// The boot security policy macOS reports for the running system (the
/// Startup Security Utility setting), read unprivileged from
/// `system_profiler -json SPiBridgeDataType`. On a Mac with Apple silicon any
/// SIP custom configuration also moves the policy to Permissive Security.
public enum SecureBootPolicy: String, Sendable, Equatable {
    case full
    case reduced
    case permissive
    /// The report was missing, failed, timed out or held an unexpected value.
    case unknown

    /// The JSON report carries the unlocalized value of `ibridge_secure_boot`;
    /// anything else reads as unknown rather than as a downgrade.
    public static func parse(systemProfilerJSON data: Data) -> SecureBootPolicy {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPiBridgeDataType"] as? [[String: Any]],
              let value = items.lazy.compactMap({ $0["ibridge_secure_boot"] as? String }).first
        else { return .unknown }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Full Security": return .full
        case "Reduced Security", "Medium Security": return .reduced
        case "Permissive Security", "No Security": return .permissive
        default: return .unknown
        }
    }

    public static func current(runner: SecurityCommandRunner = .bounded(timeout: 20)) -> SecureBootPolicy {
        guard let result = try? runner.run("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]),
              result.terminationStatus == 0
        else { return .unknown }
        return parse(systemProfilerJSON: Data(result.stdout.utf8))
    }

    public var summary: String {
        switch self {
        case .full: return "Full Security"
        case .reduced: return "Reduced Security"
        case .permissive: return "Permissive Security"
        case .unknown: return "could not be read"
        }
    }

    /// Only an explicit downgrade blocks serving: an unreadable report is
    /// shown as unconfirmed, and Apple's App Attest key policy still requires
    /// Full Security before the coordinator authorizes this Mac.
    public var isDowngraded: Bool { self == .reduced || self == .permissive }
}
