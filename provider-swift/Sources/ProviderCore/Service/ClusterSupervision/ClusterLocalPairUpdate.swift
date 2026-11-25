import Foundation

/// A pair that serves only on the leading Mac's local API (`darkbloom cluster local`), updated by hand. Its parts never
/// answer the pair's drain, so the coordinated update (`ClusterPairUpdateCycle`) gave up on it, and both Macs' cluster
/// services kept running the earlier release: the pair stayed down until `darkbloom cluster stop --local-only --service`
/// and `darkbloom start` on each Mac (on a DevNet pair, 0.10.13 `.181` → `.187` and `.187` → `.188`). Now
/// `darkbloom update` on such a Mac restarts that Mac's cluster service into the release it installed at once, and a
/// cluster service ended in the middle of setting the pair up again after an update puts the pair's start back when it
/// runs again (`ClusterSetupRecord.updateReplan`), so the pair sets itself up again once both Macs run the release.
///
/// The switch is read by the cluster service and its supervisor, from the environment their login agent carries
/// (`LaunchAgent.passthroughEnvKeys`: export it before `darkbloom start` or `darkbloom cluster`). An off word (`off`,
/// `false`, `0`, `none`, `no` or `disabled`, in any case, surrounding space ignored) restores 0.10.13's behaviour.
public enum ClusterLocalPairUpdate {
    public static let environmentKey = "DARKBLOOM_CLUSTER_LOCAL_UPDATE_RESTART"

    public static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    public static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[environmentKey])
    }
}
