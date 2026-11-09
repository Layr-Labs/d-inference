import Foundation

// Me first for a pair: while the owner uses the pair through its leader's local
// API, the pair takes no Darkbloom work, and it takes Darkbloom work again once
// the owner has been idle for `[local] me_first_idle_minutes`. It is a single
// Mac's owner pause (`ProviderLoop+MeFirst`), run by the leader and fed by its
// local lanes' hook (`noteClusterPairLocalUse`) from the moment a request
// starts waiting for a lane. What holds:
//
// - The leader decides for the pair, whatever its number of Macs: the process
//   that owns the pair's local API (the member that hosts the slot) owns the
//   pause. Its draining heartbeat takes the whole pair out of routing without
//   ending the pair's session. Nothing here counts ranks.
// - A request on another Mac's own port counts here like any local request:
//   that Mac's cluster service relays it to this local API
//   (`ClusterLocalRelay`).
// - Every other member stays control-only: its part runs no local API, so me
//   first stays off there, and its heartbeat stays `draining` with no busy
//   fields.
// - Nothing in flight is cancelled: Darkbloom requests already running finish,
//   and a dispatch that races the heartbeat gets the pause's typed refusal
//   before it reaches the pair.
// - Nothing polls: a request's start and end are O(1) updates, heartbeats go
//   out only when the pause begins and ends, and the owner's idle time is
//   checked by the pause's one timer and by the member beat that already runs
//   every 5 s (`clusterMemberHeartbeat`), because a member runs no idle
//   monitor.
extension ProviderLoop {
    /// Turns me first on for the pair this member leads, where `[local]` wants
    /// it: on unless `me_first = false`, resuming `me_first_idle_minutes` (two
    /// by default) after the owner's last request. Whatever single-Mac mode
    /// `[local]` saved, a leader's local API beside Darkbloom serves both. A
    /// member without the slot or a local API never pauses. Called when
    /// `run()` admits the member's local API, before it can take a request.
    func enableClusterPairMeFirstIfConfigured() {
        guard let endpoint = loopConfig.localEndpoint, admitsClusterPairLocalAPI(endpoint) else { return }
        let local = loopConfig.config.local ?? LocalSettings()
        guard local.meFirstEnabled(in: .both) else { return }
        enableMeFirst(idle: .seconds(60 * local.resolvedMeFirstIdleMinutes))
    }
}
