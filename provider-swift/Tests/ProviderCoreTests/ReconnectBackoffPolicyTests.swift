import Foundation
import Testing
@testable import ProviderCore

@Test func backoffResetsOnlyAfterHealthyRegisteredSession() {
    // Never registered (handshake failed, coordinator booting): keep ratcheting.
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(registeredFor: nil) == false)
    // Registered but died inside the healthy window (restart loop): keep ratcheting.
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(registeredFor: .seconds(0)) == false)
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(registeredFor: .seconds(29)) == false)
    // At or beyond the minimum: the link was proven healthy, start fresh.
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(registeredFor: .seconds(30)) == true)
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(registeredFor: .seconds(3600)) == true)
}

@Test func injectedMinimumIsHonoured() {
    // The integration tests shorten the minimum; the rule is the same.
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(
        registeredFor: .milliseconds(150), minimum: .milliseconds(200)) == false)
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(
        registeredFor: .milliseconds(200), minimum: .milliseconds(200)) == true)
    #expect(ReconnectBackoffPolicy.shouldResetBackoff(
        registeredFor: nil, minimum: .milliseconds(0)) == false)
}

@Test func exponentialBackoffResetReturnsToBaseWindow() {
    var backoff = ExponentialBackoff(base: 1, max: 30)
    // Ratchet up as a failing streak would.
    for _ in 0..<6 { _ = backoff.nextDelay() }
    let ratcheted = backoff.nextDelay()
    #expect(ratcheted >= 15 && ratcheted <= 30)

    backoff.reset()
    let afterReset = backoff.nextDelay()
    #expect(afterReset >= 0.5 && afterReset <= 1.0)
}

/// End-to-end shape of the bug: a long-lived daemon that has seen several
/// unrelated outages, then a healthy multi-hour session, must reconnect on the
/// base window after that session drops — not on the 15–30 s tail.
@Test func healthySessionAfterRatchetReconnectsOnBaseWindow() {
    var backoff = ExponentialBackoff(base: 1, max: 30)
    for _ in 0..<8 { _ = backoff.nextDelay() }  // eight lifetime drops

    let registeredFor: Duration? = .seconds(2 * 3600)
    if ReconnectBackoffPolicy.shouldResetBackoff(registeredFor: registeredFor) {
        backoff.reset()
    }
    let delay = backoff.nextDelay()
    #expect(delay <= 1.0, "expected base-window reconnect, got \(delay)s")
}

@Test func healthySessionResetAddsSpreadJitterOnlyOnce() {
    // Not after a healthy session: the base delay passes through untouched.
    #expect(ReconnectBackoffPolicy.reconnectDelay(base: 0.75, afterHealthySession: false) == 0.75)
    // After a healthy session: base plus up to the extra spread, never less
    // than base, so a fleet-wide blip fans out over a few seconds instead of
    // half a second.
    for _ in 0..<200 {
        let d = ReconnectBackoffPolicy.reconnectDelay(base: 0.75, afterHealthySession: true)
        #expect(d >= 0.75)
        #expect(d <= 0.75 + ReconnectBackoffPolicy.postHealthySessionExtraJitter)
    }
}
