import Foundation
import DarkbloomClusterPlacement

/// DEVELOPER ONLY, never offered on a user's path: forces the deployment mode
/// family the planner places (`ClusterForcedMode`), for pilots of a mode the
/// planner cannot choose yet on a new pair (tensor parallel needs a link that a
/// load measured and measured shard speeds, which only a tensor-parallel load
/// produces).
///
/// Set `DARKBLOOM_CLUSTER_FORCE_MODE=tensor_parallel_v1` (or `pipeline_v1`) in
/// the environment of `darkbloom cluster` on the Mac that plans (set it on
/// both Macs: either may lead). Only a debug build reads it; a release build
/// refuses to plan while it is set, so a signed install is never planned from
/// it by accident. Memory fit, the model's own stage adapter and the
/// qualification records still decide (a forced family that cannot be placed
/// is refused with the reason); public traffic keeps its own coordinator
/// qualification. The setup screen and the plan say it in one loud line.
public enum ClusterForcedModeSetting {
    public static let environmentName = "DARKBLOOM_CLUSTER_FORCE_MODE"

    /// The forced family, nil when unset or empty. Refused in a release build
    /// and for a value that names no family, so a typo never plans silently.
    public static func mode(environment: [String: String], debugBuild: Bool = ClusterBenchChip.isDebugBuild) throws -> ClusterForcedMode? {
        guard let value = environment[environmentName], !value.isEmpty else { return nil }
        guard debugBuild else {
            throw ClusterConfigurationError.invalid("\(environmentName) is a developer setting and is not available in a release build; "
                + "unset it to let the planner choose")
        }
        switch value {
        case "tensor_parallel_v1", "tensor_parallel": return .tensorParallel
        case "pipeline_v1", "pipeline": return .pipeline
        default:
            throw ClusterConfigurationError.invalid("\(environmentName) is tensor_parallel_v1 or pipeline_v1 (developer setting; unset, the planner chooses)")
        }
    }

    /// The setup screen's one line: what is forced, or that the setting is
    /// refused; nil when unset (every user's case).
    public static func notice(environment: [String: String], debugBuild: Bool = ClusterBenchChip.isDebugBuild) -> String? {
        do {
            guard let forced = try mode(environment: environment, debugBuild: debugBuild) else { return nil }
            return "Developer setting: \(forced.words) forced (\(environmentName)=\(forced.rawValue); debug build only)."
        } catch {
            let reason = (error as? ClusterConfigurationError).map { "\($0)" } ?? "\(error)"
            return "Developer setting \(environmentName) is set but refused: \(reason)"
        }
    }

    /// The words a plan made under the setting starts with.
    static func lines(_ forced: ClusterForcedMode) -> [String] {
        ["Developer setting: \(forced.words) forced (\(environmentName)=\(forced.rawValue))",
         "  The planner places only \(forced.words) placements (developer only, never offered in the onboarding). Memory, the model's "
            + "stage adapter and its qualification records still decide; public traffic keeps the coordinator's own qualification."]
    }
}
