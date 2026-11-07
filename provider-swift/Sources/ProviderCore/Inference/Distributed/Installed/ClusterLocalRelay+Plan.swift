import Foundation

// Where and when a Mac of the pair relays (`ClusterService.relayTick`): the pure rules, so the cluster service only
// reads its files, asks the other Mac and starts or stops the relay.
extension ClusterLocalRelay {
    /// One Mac of the pair's saved roster (`ClusterConfiguration.peers`): its member id, its rank and its cable address.
    public struct RosterMac: Equatable, Sendable {
        public var id: String
        public var rank: Int
        public var host: String
        public init(id: String, rank: Int, host: String) { self.id = id; self.rank = rank; self.host = host }
    }

    /// Rank 0's cable address when this Mac (`memberID`) relays to it; nil when it doesn't.
    public static func rankZeroHost(serving: Bool, scope: ClusterServingScope, memberID: String, roster: [RosterMac],
                                    partRuns: Bool) -> String? {
        guard serving, scope.bind == ClusterServingScope.localOnlyDefaultBind, partRuns,
              let local = roster.first(where: { $0.id == memberID }), local.rank != 0 else { return nil }
        return roster.first { $0.rank == 0 }?.host
    }

    /// The port the relay takes on this Mac for `target`.
    public static func port(for target: Target, scope: ClusterServingScope,
                            isFree: (Int) -> Bool = ClusterLocalServing.portIsFree) -> Int {
        isFree(target.port) ? target.port : ClusterLocalServing.servingPort(isFree: isFree)
    }

    /// Rank 0's API port as the status of the Mac that runs it says it.
    public static func rankZeroPort(in status: ClusterServiceStatus) -> Int? {
        status.sessionLeader && status.session?.ready == true ? status.session?.port : nil
    }
}
