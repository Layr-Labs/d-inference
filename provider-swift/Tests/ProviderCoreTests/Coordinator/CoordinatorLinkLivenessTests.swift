/// Dead-link rows for 2 s pings, a 6 s bound, a 30 s suspension gap and 30 s
/// before the coordinator's first frame (the production bound is 20 s; the
/// rows keep 6 s so each timeline stays short). `CoordinatorLinkWatch`
/// takes the time of each tick and of the last inbound frame as arguments, so
/// each row plays a whole timeline without sleeping. A last inbound frame at or
/// before the watch's start means the coordinator has not answered yet.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Coordinator link liveness")
struct CoordinatorLinkLivenessTests {
    private static let liveness = CoordinatorLinkLiveness(
        pingInterval: .seconds(2), deadAfter: .seconds(6), suspensionGap: .seconds(30), firstFrameGrace: .seconds(30))
    private static let start = ContinuousClock.now

    private static func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int64((seconds * 1000).rounded())))
    }

    /// The bound outlasts the coordinator edge's own write budget for the
    /// largest request body (21 MiB at its 2 MiB/s floor: about 10.5 s), so a
    /// body the edge still writes, with pongs behind it, never ends the link.
    @Test("the production values are 2 s pings, a 20 s bound, a 30 s suspension gap and 30 s for the first frame")
    func productionValues() {
        let production = CoordinatorLinkLiveness()
        #expect(production.pingInterval == .seconds(2))
        #expect(production.deadAfter == .seconds(20))
        #expect(production.suspensionGap == .seconds(30))
        #expect(production.firstFrameGrace == .seconds(30))
        #expect(CoordinatorError.pongTimeout(after: production.deadAfter).localizedDescription
            == "WebSocket pong timeout (no frame from the coordinator in 20s)")
    }

    @Test("the reconnect log gives the dead-link reason, not a generic error number")
    func deadLinkErrorReadsInTheLog() {
        let error: Error = CoordinatorError.pongTimeout(after: Self.liveness.deadAfter)
        #expect(error.localizedDescription == "WebSocket pong timeout (no frame from the coordinator in 6s)")
        #expect(CoordinatorError.suspensionDetected.localizedDescription
            == "Process suspension detected (timer gap); forcing reconnect")
    }

    /// 768 MiB is the coordinator's highest in-flight cap (24 requests) times
    /// the provider's 32 MiB message limit, so no admitted backlog reaches it;
    /// the age limit is the 20 s dead bound.
    @Test("the inbound backlog limits are 768 MiB, 4,096 frames and 20 s, and passing one reads in the log")
    func inboundBacklogProductionValues() {
        let production = CoordinatorInboundBacklog()
        #expect(production.maxBytes == 768 * 1024 * 1024)
        #expect(production.maxFrames == 4_096)
        #expect(production.maxAge == .seconds(20))
        #expect(CoordinatorLinkCloseCode.inboundBacklog.rawValue == 4003)
        #expect(CoordinatorError.inboundBacklogExceeded(.age(.seconds(21))).localizedDescription
            == "Coordinator frames not handled in time (a frame waited 21s for its handling); link closed")
    }

    @Test("the backlog passes each limit, a size limit stays passed, and handled frames leave it")
    func backlogPassesEachLimit() {
        let start = ContinuousClock.now

        let bytes = CoordinatorFrameBacklog(limits: CoordinatorInboundBacklog(maxBytes: 100))
        #expect(bytes.add(size: 60, receivedAt: start))
        #expect(!bytes.add(size: 60, receivedAt: start))
        bytes.finishOldest()
        bytes.finishOldest()
        #expect(bytes.excess(now: start) == .bytes(120))

        let frames = CoordinatorFrameBacklog(limits: CoordinatorInboundBacklog(maxFrames: 2))
        #expect(frames.add(size: 1, receivedAt: start))
        #expect(frames.add(size: 1, receivedAt: start))
        #expect(!frames.add(size: 1, receivedAt: start))
        #expect(frames.excess(now: start) == .frames(3))

        // The age is the oldest frame's, until its handling returns.
        let age = CoordinatorFrameBacklog(limits: CoordinatorInboundBacklog(maxAge: .seconds(1)))
        #expect(age.add(size: 1, receivedAt: start))
        #expect(age.add(size: 1, receivedAt: start + .milliseconds(800)))
        #expect(age.excess(now: start + .seconds(1)) == nil)
        #expect(age.excess(now: start + .milliseconds(1_100)) == .age(.milliseconds(1_100)))
        age.finishOldest()
        #expect(age.excess(now: start + .milliseconds(1_100)) == nil)
        age.finishOldest()
        #expect(age.excess(now: start + .seconds(60)) == nil)
    }

    @Test("a peer that answered and went silent is declared dead after the bound and before bound plus one ping interval")
    func silentPeerIsDeadWithinTheBound() throws {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        var deadAt: Double?
        for tick in 1...10 {
            let now = Double(tick) * 2
            if watch.check(now: Self.at(now), lastInbound: Self.at(0.01)) == .dead {
                deadAt = now
                break
            }
        }
        let seconds = try #require(deadAt, "a peer silent for 20 s was never declared dead")
        // The first tick past 6 s of silence: within (6 s, 8 s].
        #expect(seconds == 8)
    }

    /// A coordinator that registers many reconnecting providers answers a new
    /// connection late; until its first frame the connection waits 30 s, not 6 s.
    @Test("a new connection that the coordinator has not answered yet is declared dead only after 30 s")
    func newConnectionWaitsForTheFirstFrame() throws {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        var deadAt: Double?
        for tick in 1...20 {
            let now = Double(tick) * 2
            if watch.check(now: Self.at(now), lastInbound: Self.at(-0.001)) == .dead {
                deadAt = now
                break
            }
        }
        // The first tick past 30 s without a first frame: within (30 s, 32 s].
        #expect(try #require(deadAt, "a connection silent for 40 s was never declared dead") == 32)
    }

    /// The reconnect log names the silence that ended the link.
    @Test("the dead-link log gives 30 s before the coordinator's first frame and 6 s after it")
    func deadLinkLogNamesTheBoundThatApplied() {
        let watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        let beforeFirstFrame: Error = CoordinatorError.pongTimeout(after: watch.silenceBound(lastInbound: Self.start))
        let afterFirstFrame: Error = CoordinatorError.pongTimeout(after: watch.silenceBound(lastInbound: Self.at(0.01)))
        #expect(beforeFirstFrame.localizedDescription == "WebSocket pong timeout (no frame from the coordinator in 30s)")
        #expect(afterFirstFrame.localizedDescription == "WebSocket pong timeout (no frame from the coordinator in 6s)")
    }

    @Test("after the coordinator's first frame the 6 s bound applies")
    func firstFrameEndsTheGrace() {
        var watch = CoordinatorLinkWatch(liveness: Self.liveness, start: Self.start)
        // No frame for 20 s: still waiting for the registration answer.
        for tick in 1...10 {
            #expect(watch.check(now: Self.at(Double(tick) * 2), lastInbound: Self.start) == .alive)
        }
        // The first frame comes at 21 s; then silence counts against 6 s.
        let first = Self.at(21)
        #expect(watch.check(now: Self.at(22), lastInbound: first) == .alive)
        #expect(watch.check(now: Self.at(24), lastInbound: first) == .alive)
        #expect(watch.check(now: Self.at(26), lastInbound: first) == .alive)
        #expect(watch.check(now: Self.at(28), lastInbound: first) == .dead)
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
