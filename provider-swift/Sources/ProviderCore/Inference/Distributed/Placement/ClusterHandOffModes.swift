import Foundation

/// The one explicit opt-in for the hand-off modes, off by default (owner,
/// 2026-10-13: "Keep the phase split engineering but keep it off"). A cluster
/// deployment shards the model across its members, tensor parallel or
/// pipeline, chosen by the planner from the detected hardware. Phase split,
/// phase split + MTP, the pipeline-prefill/tensor-decode hybrid and the
/// per-request "alone" route stay in the code with their tests and records,
/// and are reachable only when `DARKBLOOM_CLUSTER_HANDOFF_MODES=1` is in the
/// environment of the process that plans (`darkbloom cluster`, `darkbloom
/// cluster plan`) and, for the alone route, of the serving leader. The
/// onboarding never offers it.
public enum ClusterHandOffModes {
    public static let environmentName = "DARKBLOOM_CLUSTER_HANDOFF_MODES"

    /// False when unset, "0" or "off"; true for "1" or "on". Anything else is
    /// refused, so a typo never silently changes what is planned.
    public static func enabled(environment: [String: String]) throws -> Bool {
        guard let text = environment[environmentName] else { return false }
        switch text {
        case "1", "on": return true
        case "", "0", "off": return false
        default:
            throw ClusterConfigurationError.invalid("\(environmentName) is 1 (consider the hand-off modes: phase split, phase split + MTP, "
                + "the pipeline-prefill/tensor-decode hybrid and the alone route) or 0 (the default: sharded deployments only)")
        }
    }

    /// The words a plan carries about the setting.
    static func lines(enabled: Bool) -> [String] {
        enabled
            ? ["Hand-off modes (\(environmentName)=1)",
               "  Opted in: phase split, phase split + MTP, the pipeline-prefill/tensor-decode hybrid and the per-request alone route "
                   + "are considered beside the sharded modes. They are off by default and never offered in the onboarding."]
            : ["  \(environmentName)=1 is the explicit opt-in for them (developer setting, never offered in the onboarding)."]
    }
}
