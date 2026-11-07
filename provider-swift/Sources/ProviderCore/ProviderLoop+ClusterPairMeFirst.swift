import Foundation

// Me first for a pair: while the owner uses the pair through its leader's local
// API, the pair takes no Darkbloom work, and it takes Darkbloom work again once
// the owner has been idle for `[local] me_first_idle_minutes`.
//
// The leader decides for the pair. Its loop owns the pair's slot and the local
// API, so its owner pause (`ProviderLoop+MeFirst`) drains the leader's
// heartbeat, which makes the whole pair unroutable without ending the pair's
// session. A dispatch that races the heartbeat gets the pause's typed refusal,
// and Darkbloom requests already running finish. The owner's use is the local
// lanes' hook (`noteClusterPairLocalUse`), from the moment a request starts
// waiting for a lane. A member runs no idle monitor, so the member beat
// (`clusterMemberHeartbeat`) also checks the owner's idle time, beside the
// pause's own timer. Every other member runs no local API, so it never pauses
// and its heartbeat stays control-only. Nothing here counts ranks.
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
