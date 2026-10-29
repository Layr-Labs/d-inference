import Foundation
import DarkbloomClusterProtocol

/// Which cluster approval a pair's setup keeps, and for how long. Every approval expires (14 days after its release);
/// one within a day of its end is replaced when the coordinator has a later one. An expired approval is removed, never
/// kept: the Macs then serve as a pair without one does, on the leader's local API.
public enum ClusterApprovalLifetime {
    /// A saved approval this close to its `not_after` is replaced when the coordinator offers a later one.
    public static let renewWithinSeconds: Double = 86_400

    /// `not_after` in seconds since 1970; nil when it is not a strict RFC 3339 instant (such an entry never saves).
    static func expiry(_ approval: ClusterRuntimeApproval) -> Double? { expiry(notAfter: approval.notAfter) }

    private static func expiry(notAfter: String) -> Double? {
        ClusterPairApproval.unixNanoseconds(rfc3339: notAfter).map { Double($0) / 1_000_000_000 }
    }

    /// Whether `approval` may still be registered at `now`.
    public static func current(_ approval: ClusterRuntimeApproval, now: Double) -> Bool {
        expiry(approval).map { now < $0 } ?? false
    }

    /// Whether a setup saved with `member` is offered to the coordinator now: its approval (a cluster approval, or a
    /// pair approval saved by hand) is current and the cluster serves publicly. Otherwise each Mac saves its setup
    /// without it and the pair serves as one without an approval does.
    static func offers(_ member: ClusterNativeMemberAttachment, scope: ClusterServingScope, now: Double) -> Bool {
        guard !scope.isLocalOnly, let notAfter = member.clusterApproval?.notAfter ?? member.approval?.notAfter,
              let end = expiry(notAfter: notAfter) else { return false }
        return now < end
    }

    /// The schedule number an approval names for a setup's prefill schedule (1 serial, 2 one-chunk lookahead).
    static func schedule(_ value: ClusterPrefillSchedule) -> UInt8 { value == .serial ? 1 : 2 }

    /// The entry for this setup: its model and its prefill schedule, still current, the latest `not_after` first.
    static func select(_ approvals: [ClusterRuntimeApproval], model: String, schedule: ClusterPrefillSchedule,
                       now: Double) -> ClusterRuntimeApproval? {
        approvals.filter { $0.model == model && $0.schedule == Self.schedule(schedule) && current($0, now: now) }
            .max { (expiry($0) ?? 0) < (expiry($1) ?? 0) }
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to write: the saved setup stays byte for byte as it is.
        case keep
        /// Save this approval on both Macs (none was saved, or the saved one is near its end and this one is later).
        case save(ClusterRuntimeApproval)
        /// The saved approval expired and the coordinator has no later one: both Macs save the setup without it.
        case remove
    }

    /// What to do with the setup's saved approval (`saved`, nil for none) after asking the coordinator (`fetched`).
    static func decide(saved: ClusterRuntimeApproval?, fetched: ClusterApprovalFetch.Outcome, model: String,
                       schedule: ClusterPrefillSchedule, now: Double) -> Decision {
        let candidate: ClusterRuntimeApproval?
        if case .approvals(let approvals) = fetched {
            candidate = select(approvals, model: model, schedule: schedule, now: now)
        } else { candidate = nil }
        guard let saved else { return candidate.map(Decision.save) ?? .keep }
        let savedEnd = expiry(saved) ?? 0
        if savedEnd - now > renewWithinSeconds { return .keep }
        if let candidate, candidate != saved, (expiry(candidate) ?? 0) > savedEnd { return .save(candidate) }
        return savedEnd > now ? .keep : .remove
    }

    /// The one status line of a pair offered to the coordinator for pairing.
    public static func offeredLine(_ approval: ClusterRuntimeApproval) -> String { offeredLine(id: approval.id, notAfter: approval.notAfter) }

    /// The same for a saved setup's attachment (a cluster approval, or a pair approval saved by hand).
    static func offeredLine(_ member: ClusterNativeMemberAttachment) -> String? {
        if let approval = member.clusterApproval { return offeredLine(approval) }
        return member.approval.map { offeredLine(id: $0.id, notAfter: $0.notAfter) }
    }

    private static func offeredLine(id: String, notAfter: String) -> String {
        "\(ClusterLocalServing.offeredNotice): approval \(id), until \(notAfter)"
    }
}
