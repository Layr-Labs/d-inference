import Foundation

/// A part of the pair whose start this Mac's device journal refuses ("Unresolved native ownership journal"): an earlier
/// session's owner ended before its worker was seen to exit, so the journal still names that session. That happens when
/// a stop lands seconds after the pair came up, as the guided setup's approval step and the service's own approval check
/// do. Every later start then ended the same way until someone ran `darkbloom cluster recover`. Now the cluster service
/// runs that same recovery by itself, once per such run of refused starts: the journal is cleared only when no process
/// holds this Mac's device scope and none carries the recorded session's membership epoch
/// (`ClusterDeviceRecovery.recover`), and stale bootstrap directories (no process has their socket bound) are removed.
/// Nothing is signalled.
///
/// The switch is read by the cluster service, from the environment its login agent carries
/// (`LaunchAgent.passthroughEnvKeys`: export it before `darkbloom start` or `darkbloom cluster`). An off word (`off`,
/// `false`, `0`, `none`, `no` or `disabled`, in any case, surrounding space ignored) restores the earlier behaviour.
public enum ClusterJournalAutoRecover {
    public static let environmentKey = "DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER"

    public static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    public static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[environmentKey])
    }

    /// The part's last error says this Mac's device journal refused its start.
    public static func refusedByJournal(_ lastError: String?) -> Bool {
        lastError?.contains("Unresolved native ownership journal") == true
    }
}
