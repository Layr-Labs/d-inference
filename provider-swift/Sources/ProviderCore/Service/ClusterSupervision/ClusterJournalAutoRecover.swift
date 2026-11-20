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
/// A save of the pair's cluster approval needs the journal empty too, and the guided setup's approval step saves right
/// after its own stop, so the stop that stranded the journal also refused that save ("Not offered for pairing: this Mac
/// could not save its setup: Unresolved native ownership journal"). Such a save runs the same recovery once and saves
/// again (`ClusterApprovalJournalRecovery`); when that recovery refused and the part's recovery cleared the journal
/// later, the next approval check saves the approval again, and the status says so in place of `cluster recover`
/// (`clearedSaveNote`).
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

    /// The part's last error, or a save's refusal, says this Mac's device journal refused it.
    public static func refusedByJournal(_ lastError: String?) -> Bool {
        lastError?.contains("Unresolved native ownership journal") == true
    }

    /// What a recovery that left the journal empty says: whether it cleared a journal (`cleared`) or found it empty, and
    /// how many stale bootstrap directories it removed.
    public static func clearedLine(cleared: Bool, removedBootstrapDirectories removed: Int, cli: String) -> String {
        "this Mac's device journal named an earlier session whose owner is gone: "
            + (cleared ? "cleared it, as `\(cli) cluster recover` does" : "it is empty now")
            + (removed > 0 ? ", and removed \(removed) stale bootstrap director\(removed == 1 ? "y" : "ies")" : "")
    }

    /// The leading Mac's approval note once the part's recovery cleared the journal that refused a save of the cluster
    /// approval: the next approval check saves it again, so the status no longer says to run `cluster recover`.
    public static let clearedSaveNote = "Not offered for pairing: this Mac could not save its setup while its device journal "
        + "named an earlier session; that journal is cleared now, and the next approval check saves the cluster approval again"
}
