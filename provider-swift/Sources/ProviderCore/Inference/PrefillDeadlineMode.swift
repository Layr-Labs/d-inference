import Foundation

/// Controls provider-side first-token deadline admission.
///
/// The release-candidate default is deliberately fail-open. Only the exact
/// `enforce` value enables atomic engine admission; missing or unknown values
/// preserve ordinary submission.
public enum PrefillDeadlineMode: String, Sendable, Equatable {
    public static let environmentKey = "DARKBLOOM_PREFILL_DEADLINE_MODE"

    case off
    case enforce

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PrefillDeadlineMode {
        guard let rawValue = environment[environmentKey] else { return .off }
        return PrefillDeadlineMode(rawValue: rawValue) ?? .off
    }
}
