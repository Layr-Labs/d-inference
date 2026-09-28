import Foundation

/// A trusted local handler instant, never a client header or cross-host clock.
/// The HTTP responder scopes it to one request. The scheduler copies it before
/// its first suspension and then passes the value explicitly to the bridge.
enum DistributedRequestOrigin {
    @TaskLocal static var current: ContinuousClock.Instant?

    static func earliest(handler: ContinuousClock.Instant?,
                         profile: ContinuousClock.Instant?,
                         now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        [handler, profile].compactMap { $0 }.reduce(now, min)
    }
}
