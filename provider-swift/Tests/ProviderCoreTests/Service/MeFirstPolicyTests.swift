import Testing

@testable import ProviderCore

/// The owner pause's state machine on a fake millisecond clock: every edge is a
/// plain input, so no test waits.
@Suite("Me first policy")
struct MeFirstPolicyTests {
    static let t0: Int64 = 1_800_000_000_000
    static let oneMinute: Int64 = 60_000

    @Test func theFirstLocalRequestPausesDarkbloomAtOnce() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        #expect(!policy.isPausingPublic)
        #expect(policy.sinceMs == nil && policy.lastUseMs == nil && policy.resumesAtMs == nil)
        #expect(policy.localStarted(atMs: Self.t0) == .paused)
        #expect(policy.isPausingPublic && policy.sinceMs == Self.t0 && policy.inFlight == 1)
        // Further requests are a count and a timestamp, never another transition.
        #expect(policy.localStarted(atMs: Self.t0 + 500) == nil)
        #expect(policy.inFlight == 2 && policy.sinceMs == Self.t0 && policy.lastUseMs == Self.t0 + 500)
    }

    @Test func withOneIdleMinuteItResumesAtSixtySecondsAndNotAtFiftyNinePointNine() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        _ = policy.localStarted(atMs: Self.t0)
        let end = Self.t0 + 4_000
        policy.localEnded(atMs: end)
        #expect(policy.resumesAtMs == end + 60_000)
        #expect(policy.tick(atMs: end + 59_900) == nil)
        #expect(policy.isPausingPublic)
        #expect(policy.tick(atMs: end + 60_000) == .resumed)
        #expect(!policy.isPausingPublic && policy.sinceMs == nil && policy.resumesAtMs == nil)
        // It resumes once, and remembers the owner's last request.
        #expect(policy.tick(atMs: end + 120_000) == nil)
        #expect(policy.lastUseMs == end)
    }

    @Test func theDefaultIdleOfTwoMinutesResumesAt120SecondsAndNotAt119Point9() {
        let idle = Int64(LocalSettings.defaultMeFirstIdleMinutes) * 60_000
        #expect(idle == 120_000)
        var policy = MeFirstPolicy(idleMs: idle)
        _ = policy.localStarted(atMs: Self.t0)
        let end = Self.t0 + 1_000
        policy.localEnded(atMs: end)
        #expect(policy.tick(atMs: end + 119_900) == nil)
        #expect(policy.tick(atMs: end + 120_000) == .resumed)
    }

    @Test func noResumeWhileALocalRequestIsStillInFlight() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        _ = policy.localStarted(atMs: Self.t0)
        // A long stream holds the pause, hours past the idle time.
        #expect(policy.resumesAtMs == nil)
        #expect(policy.tick(atMs: Self.t0 + 3 * 3_600_000) == nil)
        #expect(policy.isPausingPublic)
        // With two overlapping requests the idle time counts from the end of the last one.
        _ = policy.localStarted(atMs: Self.t0 + 10_000)
        policy.localEnded(atMs: Self.t0 + 20_000)
        #expect(policy.inFlight == 1 && policy.resumesAtMs == nil)
        #expect(policy.tick(atMs: Self.t0 + 20_000 + 60_000) == nil)
        let last = Self.t0 + 200_000
        policy.localEnded(atMs: last)
        #expect(policy.resumesAtMs == last + 60_000)
        #expect(policy.tick(atMs: last + 59_999) == nil)
        #expect(policy.tick(atMs: last + 60_000) == .resumed)
    }

    @Test func aRequestDuringTheCountdownRestartsItAndKeepsThePauseStart() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        _ = policy.localStarted(atMs: Self.t0)
        policy.localEnded(atMs: Self.t0)
        #expect(policy.localStarted(atMs: Self.t0 + 50_000) == nil)
        policy.localEnded(atMs: Self.t0 + 55_000)
        #expect(policy.tick(atMs: Self.t0 + 60_000) == nil)
        #expect(policy.resumesAtMs == Self.t0 + 115_000)
        #expect(policy.sinceMs == Self.t0)
    }

    @Test func anUnmatchedEndChangesNothing() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        policy.localEnded(atMs: Self.t0)
        #expect(policy == MeFirstPolicy(idleMs: Self.oneMinute))
        _ = policy.localStarted(atMs: Self.t0)
        policy.localEnded(atMs: Self.t0 + 1)
        policy.localEnded(atMs: Self.t0 + 2)
        #expect(policy.inFlight == 0 && policy.lastUseMs == Self.t0 + 1)
        _ = policy.localStarted(atMs: Self.t0 + 3)
        #expect(policy.inFlight == 1 && policy.resumesAtMs == nil)
    }

    @Test func aClockThatJumpsBackHoldsThePauseForOneIdleTimeAtMost() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        _ = policy.localStarted(atMs: Self.t0)
        policy.localEnded(atMs: Self.t0)
        let earlier = Self.t0 - 3_600_000
        #expect(policy.tick(atMs: earlier) == nil)
        #expect(policy.resumesAtMs == earlier + 60_000)
        #expect(policy.tick(atMs: earlier + 60_000) == .resumed)
    }

    @Test func theNextRequestAfterAResumePausesAgainFromItsOwnStart() {
        var policy = MeFirstPolicy(idleMs: Self.oneMinute)
        _ = policy.localStarted(atMs: Self.t0)
        policy.localEnded(atMs: Self.t0)
        #expect(policy.tick(atMs: Self.t0 + 60_000) == .resumed)
        #expect(policy.localStarted(atMs: Self.t0 + 90_000) == .paused)
        #expect(policy.sinceMs == Self.t0 + 90_000)
    }
}
