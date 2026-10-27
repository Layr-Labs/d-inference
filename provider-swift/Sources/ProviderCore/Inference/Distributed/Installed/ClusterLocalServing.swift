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

    /// The port the leading part's API listens on: `preferred` when no other program listens there, else the first
    /// free one of the next `span` ports, else `preferred` (the start then says the port is taken). Another server on
    /// 8000 (oMLX on the owner's M5 Max, 2026-10-15) made every start end after its workers loaded.
    public static func servingPort(preferred: Int = 8000, span: Int = 20, isFree: (Int) -> Bool = portIsFree) -> Int {
        (preferred...(preferred + span)).first(where: isFree) ?? preferred
    }

    /// The ports the cluster's API may take, on either Mac.
    public static let servingPorts = 8000...8020

    /// The ports of `servingPorts` no other program listens on (what a Mac's status reports as `freePorts`).
    public static func freePorts(isFree: (Int) -> Bool = portIsFree) -> [Int] {
        servingPorts.filter(isFree)
    }

    /// One port for the API on both Macs, so its address does not change with which Mac runs rank 0: `preferred` (the
    /// port used last) while it is free on both, else the lowest free on both. When the other Mac does not say
    /// (`peerFree` nil, an older build or no answer) or no port is free on both, this Mac's own choice: `preferred`
    /// when free here, else the lowest free here, else 8000 (the start then says the port is taken).
    public static func sharedPort(localFree: [Int], peerFree: [Int]?, preferred: Int? = nil) -> Int {
        let both = peerFree.map { peer in localFree.filter(peer.contains) } ?? []
        for candidates in [both, localFree] {
            if let preferred, candidates.contains(preferred) { return preferred }
            if let lowest = candidates.min() { return lowest }
        }
        return servingPorts.lowerBound
    }

    /// No other program listens on `port` (IPv4, every address or loopback): a test bind as a server makes it, with
    /// `SO_REUSEADDR` so this Mac's own closed connections on the port do not count.
    public static func portIsFree(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        for address in [INADDR_ANY, INADDR_LOOPBACK] {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = in_port_t(UInt16(port).bigEndian)
            socketAddress.sin_addr = in_addr(s_addr: address.bigEndian)
            let bound = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { return false }
        }
        return true
    }

    /// Two part keys of the same saved setup that differ only by scope (the restart is the scope's, not a new setup).
    public static func scopeChangedOnly(from old: String?, to new: String?) -> Bool {
        guard let old, let new, old != new, old.hasPrefix("cluster:"), new.hasPrefix("cluster:") else { return false }
        func setup(_ key: String) -> Substring { key.split(separator: localOnlyKeyMarker, maxSplits: 1).first ?? Substring(key) }
        return setup(old) == setup(new)
    }
}
