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
public enum ClusterLocalServing {
    /// The one plain line the part, the onboarding and the status show.
    public static let notice = "Serving locally on this Mac's API; public serving needs a coordinator with cluster support"

    /// How the part writes the notice to its log (its stderr), where the cluster service reads it.
    public static let logPrefix = "Notice: "
    public static var logLine: String { logPrefix + notice }

    /// What a start that registered with the coordinator writes instead. Every serving start writes one of the two
    /// lines (to its unbuffered stderr) once its API listens, so the latest one in the part's log, which keeps earlier
    /// runs, tells how the CURRENT run serves.
    public static let registeredLogLine = logPrefix + "Registered with the coordinator as a cluster member"

    /// True when the registration wait ended because the coordinator cannot take the member role (unreachable, or
    /// without the role); false for a refusal of this member, a dropped control connection, a stop or anything else.
    public static func servesLocally(after error: Error) -> Bool {
        guard let error = error as? ClusterMemberControlError else { return false }
        return error == .roleUnsupported || error == .coordinatorUnreachable
    }

    /// The notice when the latest serving start in `log` (the part's log tail) serves locally only, nil otherwise.
    public static func notice(inLog log: String) -> String? {
        guard let last = log.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(logPrefix) }) else { return nil }
        return last.trimmingCharacters(in: .whitespaces) == logLine ? notice : nil
    }
}
