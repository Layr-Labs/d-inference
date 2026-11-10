import Foundation

/// Why a pair that was registered with the coordinator serves on the leader's local API instead.
public enum ClusterApprovalFallback: String, Codable, Equatable, Sendable {
    /// No HTTP answer for the absence grace (`ClusterService.soloGraceSeconds`, the grace before a Mac serves alone).
    case unreachable
    /// The coordinator answers (404, or a list without the saved approval) and serves no other matching entry.
    case withdrawn
    /// The coordinator-paired parts ended `ClusterControlSoloAdmission.maximumQuickEnds` times in a row right after
    /// starting with the approval (the rule for a solo server that keeps ending; `ClusterApprovalCheck.memberQuickEnds`).
    /// The approval itself is taken again `failingSeconds` after it was set aside; a later matching one at once.
    case failing

    /// How long the same build does not take an approval set aside as `failing` again. Meanwhile each Mac's part that
    /// serves locally starts its count of quick ends again (`ClusterService`), so the approval comes back with none.
    public static let failingSeconds: Double = 3_600

    /// The one line for the screen, the log and the status.
    func line(_ approval: ClusterRuntimeApproval, grace: Double) -> String {
        switch self {
        case .unreachable:
            return "The coordinator has not answered for " + (grace >= 60 ? "\(Int(grace / 60)) minutes" : "\(Int(grace)) s")
                + ": the pair serves on the leader's local API until it answers again, then it is offered again with approval \(approval.id)"
        case .withdrawn:
            return "The coordinator no longer lists cluster approval \(approval.id): the pair serves on the leader's local API "
                + "until it lists a matching one again"
        case .failing:
            return "The coordinator-paired parts ended \(ClusterControlSoloAdmission.maximumQuickEnds) times in a row right after "
                + "starting with cluster approval \(approval.id): the pair serves on the leader's local API for "
                + "\(Int(Self.failingSeconds / 60)) minutes, then it is offered again with it, or sooner with a later one the coordinator lists"
        }
    }
}
