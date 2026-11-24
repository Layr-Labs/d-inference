import Foundation

/// A command on the leading Mac before its cluster service confirmed that it leads: after its service restarted, it
/// confirms once the other Mac answers or once the claim's window (the lease's time-to-live, awake) passed with none.
/// The command waited a fixed `leaseTTLSeconds + 10` and then refused, even when the service said the window ended a
/// few seconds later, and `cluster stop --service` then left this Mac's service running while the other Mac was gone
/// (seen on a DevNet pair whose Studio's service had restarted while its disk was full, the other Mac's service off).
///
/// - `windowWaitKey`: the wait also covers the window the service publishes (`confirmsInSeconds`), at most twice the
///   fixed wait (`OnboardingLive.awaitConfirmedLeadership`).
/// - `stopAloneKey`: when the claim is still unconfirmed and the service says the other Mac doesn't answer,
///   `cluster stop --service` stops this Mac's service alone, as `--local-only` does, and says so
///   (`Cluster.Stop.finishStop`). The pair isn't stopped from here.
///
/// Both are read by the `darkbloom` command, from the shell that runs it. An off word (`off`, `false`, `0`, `none`, `no`
/// or `disabled`, in any case, surrounding space ignored) restores the earlier behaviour.
public enum ClusterUnconfirmedLeadership {
    public static let windowWaitKey = "DARKBLOOM_CLUSTER_LEADERSHIP_WINDOW_WAIT"
    public static let stopAloneKey = "DARKBLOOM_CLUSTER_STOP_ALONE_UNCONFIRMED"

    public static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    public static func waitsWindow(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[windowWaitKey])
    }

    public static func stopsAlone(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[stopAloneKey])
    }

    /// What `cluster stop --service` says before this Mac's service stops alone.
    public static let stopAloneLines = [
        "This Mac's leadership isn't confirmed yet and the other Mac doesn't answer over the cable, so the pair wasn't stopped from here.",
        "Only this Mac's cluster service stops, as `\(BuildEnvironment.current.cliName) cluster stop --local-only` would.",
    ]
    /// What the other Mac was told: nothing, because it didn't answer.
    public static let otherMacUnanswered = "The other Mac didn't answer over the cable"
}
