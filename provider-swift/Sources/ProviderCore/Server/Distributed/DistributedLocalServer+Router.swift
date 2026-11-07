import Foundation

extension LocalRouterConfig {
    /// The router of a pair's leader API run by `darkbloom start --local --distributed`: `cluster local`, and the
    /// leader's own API while the pair isn't offered to Darkbloom. Its `[local]` and coordinator are any host's, but it
    /// takes no Darkbloom work, however that start decides to serve:
    /// - local only, by choice or because the coordinator can't take the member role, it has no coordinator connection;
    /// - registered, the leader is a control-only member that hosts no pair slot and refuses every dispatch
    ///   (`ProviderLoop.consumeClusterMemberEvent`), and the coordinator lists a member to its owner only through a pair
    ///   it formed.
    ///
    /// So a `self` request can't come back here, and the router never asks the `self` view, which doesn't count this
    /// leader: one other Mac serving the model would read as this Mac alone (`this_mac_only`). The pair's API beside
    /// Darkbloom is the coordinator-paired member's (`start --cluster-member --local-endpoint`), whose router takes
    /// Darkbloom work.
    public static func pairLeaderOutsideDarkbloom(local: LocalSettings?, coordinatorURL: String?) -> LocalRouterConfig {
        .host(local: local, coordinatorURL: coordinatorURL, takesCoordinatorWork: false)
    }
}
