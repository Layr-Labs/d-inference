import Foundation

/// The leading Mac's re-plan after a Darkbloom update (`ClusterService.checkForUpdate`) beside the pair's coordinated
/// update (`ClusterPairUpdateCycle`), which installs the release on disk and only then restarts the cluster service. The
/// old service's update check compares the workers on disk, so it could start a re-plan between both Macs' installs and
/// the restart: the re-plan's stop cleared the pair's saved start, the restart ended it before it served again, and the
/// pair stayed stopped on both Macs (seen on a DevNet pair during an update). Now the old service doesn't re-plan
/// while this Mac's update has drained or is restarting into a release it doesn't run yet (`holdsReplan`): the new
/// service sets the pair up again after the restart. And every re-plan marks the record while it runs
/// (`ClusterSetupRecord.updateReplan`), so a service ended in the middle of one puts the pair's start back when it runs
/// again, as a local-only pair's already did (`ClusterLocalPairUpdate`).
///
/// The switch is read by the cluster service, from the environment its login agent carries
/// (`LaunchAgent.passthroughEnvKeys`: export it before `darkbloom start` or `darkbloom cluster`). An off word (`off`,
/// `false`, `0`, `none`, `no` or `disabled`, in any case, surrounding space ignored) restores the earlier behaviour.
public enum ClusterUpdateReplanGuard {
    public static let environmentKey = "DARKBLOOM_CLUSTER_UPDATE_REPLAN_GUARD"

    public static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    public static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[environmentKey])
    }

    /// Whether this Mac's coordinated update holds the re-plan now: its supervisor still writes its progress
    /// (`ClusterPairUpdate.progressStaleSeconds`), the cycle drained or installed, and its release is not the one this
    /// process runs (`running`), so the restart into it comes.
    public static func holdsReplan(_ progress: ClusterPairUpdateProgress?, running: String, now: Double) -> Bool {
        guard let progress, [.draining, .drained, .restarting].contains(progress.phase),
              now - progress.writtenAt <= ClusterPairUpdate.progressStaleSeconds else { return false }
        return progress.target != running
    }

    /// The cluster service's line while its update check waits for this Mac's update (`holdsReplan`), said once per
    /// wait, so the service log shows the wait.
    public static func holdLine(_ progress: ClusterPairUpdateProgress) -> String {
        "this Mac's update" + (progress.target.map { " to \($0)" } ?? "")
            + " restarts the cluster service next: setting the cluster up again waits for that restart"
    }
}
