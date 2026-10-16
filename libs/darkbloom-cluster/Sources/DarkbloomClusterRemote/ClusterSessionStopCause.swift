import Foundation

/// What a leader tells the other Mac when it ends a session (the cause its
/// fence carries, S24), and how that Mac reads it. A stop the leader was
/// asked for (a drain, `darkbloom stop`, an interrupt) is a planned end: the
/// workers' exit that follows it invalidates readiness as a lost rank would,
/// and it must not be journaled as one, on either Mac. Only a stop nobody
/// asked for is an incident.
public enum ClusterSessionStopCause {
    /// The cause of a stop the leader was asked for.
    public static let requested = "the session is stopping"

    /// The fence cause for a stop: `unrequested` when readiness was lost (a
    /// rank ended, a request had to be cancelled); `requestedFirst` when a
    /// requested stop had already begun before that, so the loss is its own
    /// workers leaving.
    public static func fenceCause(unrequested: Bool, requestedFirst: Bool, lastFailure: String?) -> String {
        guard unrequested, !requestedFirst else { return requested }
        return "the session stopped: " + (lastFailure ?? "a rank was lost")
    }

    /// True for the fence a follower's link endpoint reports for a requested
    /// stop (`leader fenced: <cause>`): exactly the requested cause, nothing
    /// else, so every other fence is still an incident.
    public static func isRequestedStop(fenceReason: String) -> Bool {
        fenceReason == "leader fenced: " + requested
    }
}
