// ReconnectBackoffPolicy: when a failed session should reset the reconnect
// backoff to its base delay.
//
// `ExponentialBackoff` only ever reset when `connectAndRun` returned WITHOUT
// throwing — and a live session never returns normally (the receive loop and
// heartbeat task exit only on shutdown; the ping and failure-monitor tasks only
// throw). So in a long-lived daemon the backoff ratcheted monotonically: after
// ~5 lifetime drops, every later reconnect — including the wake-from-sleep
// reconnect that is the fleet's dominant disconnect cause — waited 15–30 s
// before even trying, on a box whose network had been fine for hours.
//
// The rule here: a session that REGISTERED and then stayed up for at least
// `healthySessionMinimum` proves the link and the coordinator were healthy, so
// its eventual failure is a fresh incident that starts backoff from the base.
// A session that failed before registering, or within the minimum, keeps the
// ratchet — that is exactly the coordinator-restart herd the jitter exists for.

import Foundation

enum ReconnectBackoffPolicy {
    /// How long a registered session must stay up before its failure resets
    /// the backoff. Long enough that a coordinator that accepts registrations
    /// and immediately dies (bad deploy, restart loop) still ratchets the
    /// fleet's retries apart; short enough that any real session counts.
    static let healthySessionMinimum: Duration = .seconds(30)

    /// `registeredFor` is how long the just-failed session was up after its
    /// `register` frame was handed to the transport, or nil when it never
    /// registered. `minimum` defaults to ``healthySessionMinimum``; the
    /// integration tests inject a shorter one so the reset can be observed
    /// without holding a real session open for 30 s.
    static func shouldResetBackoff(
        registeredFor: Duration?,
        minimum: Duration = healthySessionMinimum
    ) -> Bool {
        guard let registeredFor else { return false }
        return registeredFor >= minimum
    }

    /// Extra uniform jitter added to the FIRST retry after a healthy-session
    /// reset. The base window alone is [0.5, 1] s; when a coordinator blip
    /// drops the whole fleet at once, a reset would bring ~1,300 registrations
    /// (each an ECDSA verify plus store reads on the coordinator) back inside
    /// half a second. Spreading that first wave over an extra few seconds
    /// costs one reconnecting box at most this much and keeps the herd
    /// survivable; later retries keep the ordinary doubling schedule.
    static let postHealthySessionExtraJitter: TimeInterval = 4.0

    /// The delay to sleep before the next attempt, given the backoff's own
    /// delay and whether this failure ended a healthy session.
    static func reconnectDelay(base: TimeInterval, afterHealthySession: Bool) -> TimeInterval {
        guard afterHealthySession else { return base }
        return base + Double.random(in: 0...postHealthySessionExtraJitter)
    }
}
