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
    /// and this Mac is in the roster but isn't rank 0. Nil when it doesn't relay. With a loopback or one-address bind,
    /// rank 0's API isn't reachable over the cable, and this Mac must not open what the person kept closed.
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
    public static func port(own: Int?, for target: Target, scope: ClusterServingScope,
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

    /// Rank 0's status says the pair answers on that Mac only, as Both, me first does while Darkbloom doesn't have the
    /// pair: a ready local session (on loopback, with that Mac's own key alone) and no API on every address. A member then
    /// has nothing to pass on.
    public static func rankZeroAnswersOnItsMacOnly(in status: ClusterServiceStatus) -> Bool {
        false
    }

    /// Where the pair's API listens on every address of the Mac whose part runs rank 0, for the other Macs' relays
    /// (`ClusterServiceStatus.pairAPIPort`): the port of the discovery record (`record`) that this Mac's running part
    /// (`part`, its pid) wrote once its API was bound. Nil without a running part, for a record another process wrote,
    /// and for an API on loopback or one address, which the cable doesn't reach (Both, me first while Darkbloom doesn't
    /// have the pair, or an API kept on its Mac with `--bind`).
    public static func pairAPIPort(part: Int32?, record: (pid: Int32, host: String, port: UInt16)?) -> Int? {
        guard let part, let record, record.pid == part, ClusterServingScope.answersOnEveryMac(bind: record.host) else { return nil }
        return Int(record.port)
    }
}
