import Foundation
import DarkbloomClusterProtocol

/// Which cluster approval a pair's setup keeps, and for how long. Every approval expires (its `not_after`, which the
/// operator sets); one within a day of its end is replaced when the coordinator has a later one. An expired approval
/// is removed, never kept: the Macs then serve as a pair without one does, on the leader's local API.
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

    /// The entry for this setup: its model and its prefill schedule, still current, the latest `not_after` first, and
    /// either a model approval for the saved setup's own `artifact` (`capability.artifactSHA256`), or a build-pinned
    /// entry whose eight digests are this Mac's own cluster runtime facts (`ClusterApprovalAttachment.mismatches`). An
    /// entry for another build or another copy of the model is simply not this setup's. `facts` runs at most once,
    /// and only for a build-pinned entry of this model and schedule: a model approval needs no facts (nil: they could
    /// not be computed, so no build-pinned entry is this setup's).
    static func select(_ approvals: [ClusterRuntimeApproval], model: String, schedule: ClusterPrefillSchedule,
                       artifact: String, facts: () -> ClusterRuntimeApprovalFacts?, now: Double) -> ClusterRuntimeApproval? {
        let eligible = approvals.filter {
            $0.model == model && $0.schedule == Self.schedule(schedule) && current($0, now: now)
        }
        let installed: ClusterRuntimeApprovalFacts? = eligible.allSatisfy(\.isModelApproval) ? nil : facts()
        return eligible.filter { approval in
            if approval.isModelApproval { return approval.artifactSHA256 == artifact }
            guard let installed else { return false }
            return ClusterApprovalAttachment.mismatches(approval, facts: installed).isEmpty
        }.max { (expiry($0) ?? 0) < (expiry($1) ?? 0) }
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to write: the saved setup stays byte for byte as it is.
        case keep
        /// Save this approval on both Macs: none was saved; the saved one is near its end and this one is later; or the
        /// coordinator no longer lists the saved one as saved and serves this matching one.
        case save(ClusterRuntimeApproval)
        /// The saved approval expired and the coordinator has no later one: both Macs save the setup without it.
        case remove
        /// The coordinator answered (404, or a list without the saved approval as saved) and serves no other matching
        /// entry: the saved approval is withdrawn although it has not ended.
        case withdrawn
    }

    /// What to do with the setup's saved approval (`saved`, nil for none) after asking the coordinator (`fetched`).
    /// Only a list (200) or 404 says anything about the saved approval; any other outcome keeps it. `artifact` is the
    /// saved setup's artifact; `facts` are this Mac's own cluster runtime facts for the setup's model, computed only
    /// when a build-pinned entry must be checked (`select`).
    static func decide(saved: ClusterRuntimeApproval?, fetched: ClusterApprovalFetch.Outcome, model: String,
                       schedule: ClusterPrefillSchedule, artifact: String, facts: () -> ClusterRuntimeApprovalFacts?,
                       now: Double) -> Decision {
        let listed: [ClusterRuntimeApproval]?
        switch fetched {
        case .approvals(let approvals): listed = approvals
        case .notOffered: listed = []
        case .unavailable, .unreachable: listed = nil
        }
        func candidate() -> ClusterRuntimeApproval? {
            guard let listed, !listed.isEmpty else { return nil }
            return select(listed, model: model, schedule: schedule, artifact: artifact, facts: facts, now: now)
        }
        guard let saved else { return candidate().map(Decision.save) ?? .keep }
        let savedEnd = expiry(saved) ?? 0
        if savedEnd <= now { return candidate().map(Decision.save) ?? .remove }
        // An entry the operator replaced under the same `id` (a new `not_after`, other terms) is not the saved one: the
        // coordinator no longer approves the saved bytes.
        if let listed, !listed.contains(saved) { return candidate().map(Decision.save) ?? .withdrawn }
        if savedEnd - now > renewWithinSeconds { return .keep }
        if let candidate = candidate(), candidate != saved, (expiry(candidate) ?? 0) > savedEnd { return .save(candidate) }
        return .keep
    }

    /// The one status line of a pair registered with the coordinator as a cluster member.
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
