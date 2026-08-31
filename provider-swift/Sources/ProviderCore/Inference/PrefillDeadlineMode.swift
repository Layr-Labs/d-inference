import Foundation

/// Controls provider-side first-token deadline admission.
///
/// Explicit typed config is authoritative. Only an absent config value falls
/// back to the legacy environment control, where exact lowercase `off`
/// disables and every other value securely enforces. Effective forecast
/// admission separately requires a projection-compatible scheduler posture.
public enum PrefillDeadlineMode: String, Sendable, Equatable, Codable {
    public static let environmentKey = "DARKBLOOM_PREFILL_DEADLINE_MODE"

    case off
    case enforce

    public static func resolve(
        configured: PrefillDeadlineMode? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PrefillDeadlineMode {
        if let configured {
            return configured
        }
        return environment[environmentKey] == off.rawValue ? .off : .enforce
    }
}
