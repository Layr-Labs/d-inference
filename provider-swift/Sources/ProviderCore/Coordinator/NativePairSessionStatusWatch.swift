import Foundation

/// Watches a member session's heartbeat report (`cluster_session`) while the
/// session is the member control's current one, and calls `changed` with each
/// new value: when its owner launched, and when its worker published
/// readiness with the data plane's protection (S16). The member then sends a
/// heartbeat at once (`CoordinatorClient.adoptNativePairMember`) instead of at
/// its next periodic interval: the coordinator lets a cluster serve public
/// requests only once every member reported the current session as encrypted
/// and peer-verified, and waiting for the interval refused a re-formed pair as
/// "data plane unencrypted" for ~12 s (integration round 4, finding 1).
///
/// Each distinct value is reported once. The watch stops when the session is
/// no longer live or has reached its final report (encrypted and verified).
/// It polls every `pollMilliseconds` for the first two minutes (formation),
/// then once a second, so an unkeyed session that never reaches the final
/// report costs nearly nothing for the rest of its life.
enum NativePairSessionStatusWatch {
    static let formationNanoseconds: UInt64 = 120_000_000_000

    static func start(pollMilliseconds: Int = 25, current: @escaping @Sendable () -> ClusterSessionStatus?,
                      live: @escaping @Sendable () -> Bool, changed: @escaping @Sendable (ClusterSessionStatus) -> Void) {
        let fast = UInt32(max(1, min(pollMilliseconds, 1_000))) * 1_000
        let started = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .utility).async {
            var last: ClusterSessionStatus?
            while live() {
                if let now = current(), now != last {
                    last = now
                    changed(now)
                }
                if let last, last.encryptedDataPlane, last.peerVerified { return }
                let formation = DispatchTime.now().uptimeNanoseconds &- started < formationNanoseconds
                usleep(formation ? fast : 1_000_000)
            }
        }
    }
}
