import Foundation

/// A cluster leader whose coordinator cannot take its member role serves on its own local API only.
///
/// The distributed leader registers with the configured coordinator as a control-only cluster member before it opens
/// its local API. When that coordinator is unreachable, or answers the registration as an ordinary provider's because
/// it predates the role, the pair serves LOCALLY ONLY: the leader's local API with the same local token as single-Mac
/// `--local`, no public traffic and no coordinator advertisement (the member connection is closed), while this Mac's
/// device stays held (media-serving lock, native device lease) exactly as when it serves publicly. The next start asks
/// the coordinator again, so a coordinator that gains the role is registered with normally. A coordinator that refuses
/// THIS member or pairing (it closes the connection, or sends an acknowledgement that does not verify) is never read
/// as "unsupported": that start fails as before. Nothing here relaxes pairing, the data plane, signed plans, the rank
/// lease or the memory gate, which the distributed session enforces whatever the coordinator answers.
///
/// Local-only serving (`darkbloom cluster local`, `ClusterServingScope.localOnly`) is the person's choice instead of a
/// fallback: the leader part starts with `--no-coordinator`, never builds a coordinator connection (so nothing can
/// refuse it), and serves on the chosen address with the same local token.
public enum ClusterLocalServing {
    /// The one plain line the part, the onboarding and the status show.
    public static let notice = "Serving locally on this Mac's API; public serving needs a coordinator with cluster support"

    /// How the part writes the notice to its log (its stderr), where the cluster service reads it.
    public static let logPrefix = "Notice: "
    public static var logLine: String { logPrefix + notice }

    /// What a start that registered with the coordinator writes instead. Every serving start writes one of the three
    /// lines (to its unbuffered stderr) once its API listens, so the latest one in the part's log, which keeps earlier
    /// runs, tells how the CURRENT run serves.
    public static let registeredLogLine = logPrefix + "Registered with the coordinator as a cluster member"

    /// `darkbloom cluster local`: the person chose local-only serving, so the leader never contacts a coordinator.
    public static let localOnlyNotice = "Serving locally only on this Mac's API: no coordinator, no public traffic"
    public static var localOnlyLogLine: String { logPrefix + localOnlyNotice }

    /// The leader part's start option that skips the coordinator entirely (`darkbloom start --distributed`).
    public static let noCoordinatorFlag = "--no-coordinator"

    /// True when the registration wait ended because the coordinator cannot take the member role (unreachable, or
    /// without the role); false for a refusal of this member, a dropped control connection, a stop or anything else.
    public static func servesLocally(after error: Error) -> Bool {
        guard let error = error as? ClusterMemberControlError else { return false }
        return error == .roleUnsupported || error == .coordinatorUnreachable
    }

    /// The notice when the latest serving start in `log` (the part's log tail) serves locally only (by choice, or
    /// because the coordinator cannot take the member role), nil when it registered or there is none.
    public static func notice(inLog log: String) -> String? {
        guard let last = log.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(logPrefix) }) else { return nil }
        switch last.trimmingCharacters(in: .whitespaces) {
        case logLine: return notice
        case localOnlyLogLine: return localOnlyNotice
        default: return nil
        }
    }

    /// The leader part's start for the saved scope: `base` (`start --local --distributed` and the configuration), and
    /// for local-only serving the coordinator skipped and the API on the chosen address.
    public static func leaderArguments(_ base: [String], scope: ClusterServingScope) -> [String] {
        guard let bind = scope.bind else { return base }
        return base + [noCoordinatorFlag, "--bind", bind]
    }

    /// The solo server (this Mac alone after the absence grace) is coordinator-less already; local-only serving gives
    /// it the same address as the cluster's API.
    public static func soloArguments(_ base: [String], scope: ClusterServingScope) -> [String] {
        guard let bind = scope.bind else { return base }
        return base + ["--bind", bind]
    }

    /// What the cluster service keys this Mac's running part by: the saved setup, and the scope when it is local only,
    /// so a change of scope stops the running part and starts it again that way (public keeps the earlier key).
    public static func partKey(setupSHA256: String, scope: ClusterServingScope) -> String {
        "cluster:" + setupSHA256 + (scope.bind.map { localOnlyKeyMarker + $0 } ?? "")
    }

    private static let localOnlyKeyMarker = ":local-only@"

    /// Two part keys of the same saved setup that differ only by scope (the restart is the scope's, not a new setup).
    public static func scopeChangedOnly(from old: String?, to new: String?) -> Bool {
        guard let old, let new, old != new, old.hasPrefix("cluster:"), new.hasPrefix("cluster:") else { return false }
        func setup(_ key: String) -> Substring { key.split(separator: localOnlyKeyMarker, maxSplits: 1).first ?? Substring(key) }
        return setup(old) == setup(new)
    }
}
