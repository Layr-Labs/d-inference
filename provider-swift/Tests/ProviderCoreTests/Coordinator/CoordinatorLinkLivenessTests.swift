/// Dead-link rows for the production values (2 s pings, 6 s bound, 30 s
/// suspension gap). `CoordinatorLinkWatch` takes the time of each tick and of
/// the last inbound frame as arguments, so each row plays a whole timeline
/// without sleeping.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Coordinator link liveness")
struct CoordinatorLinkLivenessTests {
    private static let liveness = CoordinatorLinkLiveness()
    private static let start = ContinuousClock.now

    private static func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int64((seconds * 1000).rounded())))
    }

    @Test("the production values are 2 s pings, a 6 s bound and a 30 s suspension gap")
    func productionValues() {
        #expect(Self.liveness.pingInterval == .seconds(2))
        #expect(Self.liveness.deadAfter == .seconds(6))
        #expect(Self.liveness.suspensionGap == .seconds(30))
    }

    @Test("the reconnect log gives the dead-link reason, not a generic error number")
    func deadLinkErrorReadsInTheLog() {
        let error: Error = CoordinatorError.pongTimeout(after: Self.liveness.deadAfter)
        #expect(error.localizedDescription == "WebSocket pong timeout (no frame from the coordinator in 6s)")
        #expect(CoordinatorError.suspensionDetected.localizedDescription
            == "Process suspension detected (timer gap); forcing reconnect")
    }

    @Test("a silent peer is declared dead after the bound and before bound plus one ping interval")
    func silentPeerIsDeadWithinTheBound() throws {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        var deadAt: Double?
        for tick in 1...10 {
            let now = Double(tick) * 2
            if watch.check(now: Self.at(now), lastInbound: Self.start) == .dead {
                deadAt = now
                break
            }
        }
        let seconds = try #require(deadAt, "a peer silent for 20 s was never declared dead")
        // The first tick past 6 s of silence: within (6 s, 8 s].
        #expect(seconds == 8)
    }

    @Test("a busy stream without a single pong is never declared dead")
    func busyStreamWithoutPongsStaysAlive() {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        // One hour of ticks; a frame came in 1 s before each tick, no pongs.
        for tick in 1...1800 {
            let now = Double(tick) * 2
            #expect(watch.check(now: Self.at(now), lastInbound: Self.at(now - 1)) == .alive)
        }
    }

    @Test("two missed pongs in a row are tolerated and a third declares the link dead")
    func twoMissedPongsAreToleratedAndThreeAreNot() {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        // The ping of tick k leaves at 2k s; its pong comes back 10 ms later.
        // The pings of ticks 3, 4 and 5 get no pong.
        let answered: Set<Int> = [1, 2]
        var lastInbound = Self.start
        var verdicts: [CoordinatorLinkVerdict] = []
        for tick in 1...6 {
            verdicts.append(watch.check(now: Self.at(Double(tick) * 2), lastInbound: lastInbound))
            if answered.contains(tick) { lastInbound = Self.at(Double(tick) * 2 + 0.01) }
        }
        #expect(verdicts == [.alive, .alive, .alive, .alive, .alive, .dead])
    }

    @Test("a late tick shorter than the suspension gap is not counted as missed pongs",
          arguments: [7.0, 10.0, 29.0])
    func lateTickRestartsTheSilenceWindow(gap: Double) {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        // Pongs answer until 2 s; then the ping task does not run for `gap` s.
        #expect(watch.check(now: Self.at(2), lastInbound: Self.at(0.01)) == .alive)
        let lastPong = Self.at(2.01)
        let late = 2 + gap
        #expect(watch.check(now: Self.at(late), lastInbound: lastPong) == .alive)
        // The silence counts from the late tick, as if the link had just answered.
        #expect(watch.check(now: Self.at(late + 2), lastInbound: lastPong) == .alive)
        #expect(watch.check(now: Self.at(late + 4), lastInbound: lastPong) == .alive)
        #expect(watch.check(now: Self.at(late + 6), lastInbound: lastPong) == .alive)
        #expect(watch.check(now: Self.at(late + 8), lastInbound: lastPong) == .dead)
    }

    @Test("a sleep of the suspension gap or more gives one suspension verdict, not a dead link",
          arguments: [30.0, 600.0, 36_000.0])
    func sleepIsASuspensionNotADeadLink(gap: Double) {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        #expect(watch.check(now: Self.at(2), lastInbound: Self.at(0.01)) == .alive)
        #expect(watch.check(now: Self.at(2 + gap), lastInbound: Self.at(2.01)) == .suspended)
    }
}
