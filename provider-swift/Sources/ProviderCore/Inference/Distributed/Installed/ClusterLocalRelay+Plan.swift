import Foundation

// Where and when a Mac of the pair relays (`ClusterService.relayTick`): the pure rules, so the cluster service only reads
// its files, asks the Mac that runs rank 0, and starts or stops the relay. Nothing counts the Macs: every Mac whose part
// isn't rank 0 relays to rank 0's.
extension ClusterLocalRelay {
    /// One Mac of the pair's saved roster (`ClusterConfiguration.peers`): its member id, its rank and its cable address.
    public struct RosterMac: Equatable, Sendable {
        public var id: String
        public var rank: Int
        public var host: String
        public init(id: String, rank: Int, host: String) { self.id = id; self.rank = rank; self.host = host }
    }

    /// Rank 0's cable address when this Mac (`memberID`) relays to it: the pair serves with its local API on every
    /// address (`ClusterServingScope.answersOnEveryMac`: local only by default, or Both, me first), this Mac's part runs,
    /// and this Mac is in the roster but isn't rank 0. Nil when it doesn't relay.
    public static func rankZeroHost(serving: Bool, scope: ClusterServingScope, memberID: String, roster: [RosterMac],
                                    partRuns: Bool) -> String? {
        guard serving, partRuns, scope.answersOnEveryMac, let local = roster.first(where: { $0.id == memberID }),
              local.rank != 0 else { return nil }
        return roster.first { $0.rank == 0 }?.host
    }

    /// The port the relay takes on this Mac: rank 0's when it is free here, so the pair's address is the same on every
    /// Mac. Beside Darkbloom (Both), otherwise the first free port the pair's API may take
    /// (`ClusterLocalServing.localAPIPorts`: never 8000 or a cable port, which are never even test-bound); local only
    /// keeps its rule, 8000 or the next free one.
    public static func port(for target: Target, scope: ClusterServingScope,
                            isFree: (Int) -> Bool = ClusterLocalServing.portIsFree) -> Int {
        guard scope.addsLocalAPI else { return isFree(target.port) ? target.port : ClusterLocalServing.servingPort(isFree: isFree) }
        return ClusterLocalServing.localAPIPort(localFree: ClusterLocalServing.localAPIFreePorts(isFree: isFree), peersFree: nil,
                                                preferred: target.port)
    }

    /// Rank 0's API port as the status of the Mac that runs it says: where its pair API listens (`pairAPIPort`), or, from
    /// an older build serving locally only, its ready session's. Nil from any other Mac.
    public static func rankZeroPort(in status: ClusterServiceStatus) -> Int? {
        guard status.sessionLeader else { return nil }
        return status.pairAPIPort ?? (status.session?.ready == true ? status.session?.port : nil)
    }
}
