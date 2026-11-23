import Foundation
import Testing
@testable import ProviderCore

/// Before this Mac acts as the leader it waits, up to the claim's window and 10 s more, until its cluster service
/// confirmed its claim (`OnboardingLive.awaitConfirmedLeadership`). Right after both services restarted, the guided
/// setup's "Reading both Macs over the cable" stood still that long with no line. The wait is now said once, when it
/// begins, with the seconds it can take; a confirmed claim, or a Mac that no longer leads, waits for nothing and says
/// nothing. A fake clock; no service.
struct ClusterOnboardingLeadershipWaitTests {
    private final class Run: @unchecked Sendable {
        var lines: [String] = []
        var events: [String] = []
        var polls = 0
        var clock = Date(timeIntervalSince1970: 1_000)
    }

    private func wait(_ run: Run, seconds: Double = 40, latest: Double? = nil, leads: Bool = true,
                      confirmedAfter: Int?, window: @escaping (Date) -> Double? = { _ in nil }) -> ClusterOnboardingFailure? {
        let deadline = run.clock.addingTimeInterval(seconds), last = run.clock.addingTimeInterval(latest ?? seconds)
        return OnboardingLive.awaitLeadership(deadline: deadline, latest: last,
            waiting: { run.lines.append($0); run.events.append("said") },
            leadsHere: { leads },
            confirmed: {
                defer { run.polls += 1 }
                return confirmedAfter.map { run.polls >= $0 } ?? false
            },
            window: { window(run.clock) },
            other: "the other Mac",
            failure: { .init("not confirmed") },
            pause: { run.events.append("pause"); run.clock.addTimeInterval(0.25) },
            now: { run.clock })
    }

    @Test func aConfirmedClaimWaitsForNothingAndSaysNothing() {
        let run = Run()
        #expect(wait(run, confirmedAfter: 0) == nil)
        #expect(run.lines.isEmpty && run.events.isEmpty)
    }

    @Test func aMacThatNoLongerLeadsWaitsForNothing() {
        let run = Run()
        #expect(wait(run, leads: false, confirmedAfter: nil) == nil)
        #expect(run.lines.isEmpty && run.events.isEmpty)
    }

    @Test func theWaitIsSaidOnceBeforeItBeginsWithTheSecondsItCanTake() {
        let run = Run()
        #expect(wait(run, confirmedAfter: 4) == nil)
        #expect(run.lines == ["Waiting for this Mac's cluster service to confirm it leads the pair: it hasn't heard from the other Mac yet (at most 40 s)"])
        #expect(run.events == ["said", "pause", "pause", "pause", "pause"], "said once, before the first pause")
    }

    @Test func aClaimNeverConfirmedEndsInTheRefusalAfterOneLine() {
        let run = Run()
        let failure = wait(run, seconds: 2.1, confirmedAfter: nil)
        #expect(failure == .init("not confirmed"))
        #expect(run.lines == [OnboardingLive.leadershipWaitLine(other: "the other Mac", seconds: 3)], "rounded up")
        #expect(run.events.filter { $0 == "said" }.count == 1 && run.events.filter { $0 == "pause" }.count == 9)
    }

    // The window the service publishes (`ClusterUnconfirmedLeadership.windowWaitKey`): a claim that confirms a little
    // after the fixed wait is waited for, never past `latest`.

    @Test func theWaitCoversTheWindowTheServicePublishes() {
        let run = Run()
        let start = run.clock
        // A 30 s window counting down; at 20 s it starts again (the service woke from a stall), so it ends at 50 s.
        let failure = wait(run, seconds: 40, latest: 80, confirmedAfter: nil, window: { clock in
            let t = clock.timeIntervalSince(start)
            return t < 20 ? 30 - t : max(0, 50 - t)
        })
        #expect(failure == .init("not confirmed"))
        #expect(run.lines == [OnboardingLive.leadershipWaitLine(other: "the other Mac", seconds: 40)], "said once, at the start")
        #expect(run.clock.timeIntervalSince(start) >= 52 && run.clock.timeIntervalSince(start) < 52.5,
                "refused 2 s after the restarted window, not at 40 s: \(run.clock.timeIntervalSince(start))")
    }

    @Test func onlyARecentlyWrittenStatusCounts() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ClusterService.writtenRecently(now.addingTimeInterval(-9), now: now, within: 10))
        #expect(!ClusterService.writtenRecently(now.addingTimeInterval(-11), now: now, within: 10), "a stalled service's status")
        #expect(!ClusterService.writtenRecently(nil, now: now, within: 10))
        #expect(!ClusterService.writtenRecently(now.addingTimeInterval(5), now: now, within: 10), "a clock that stepped back")
    }

    @Test func aWindowThatNeverEndsIsWaitedForAtMostUntilTheLatest() {
        let run = Run()
        let start = run.clock
        // A service that stalled keeps publishing the same window.
        #expect(wait(run, seconds: 40, latest: 80, confirmedAfter: nil, window: { _ in 30 }) == .init("not confirmed"))
        #expect(run.clock.timeIntervalSince(start) >= 80 && run.clock.timeIntervalSince(start) < 80.5, "capped at the latest")
    }

    @Test func withTheWindowWaitOffTheFixedWaitHolds() {
        let run = Run()
        let start = run.clock
        // `awaitConfirmedLeadership` passes `latest` = `deadline` when the switch is off.
        #expect(wait(run, seconds: 40, latest: 40, confirmedAfter: nil, window: { _ in 30 }) == .init("not confirmed"))
        #expect(run.clock.timeIntervalSince(start) >= 40 && run.clock.timeIntervalSince(start) < 40.5)
        #expect(ClusterUnconfirmedLeadership.waitsWindow([:]) && !ClusterUnconfirmedLeadership.waitsWindow(
            [ClusterUnconfirmedLeadership.windowWaitKey: " Off "]))
        #expect(ClusterUnconfirmedLeadership.stopsAlone([:]) && !ClusterUnconfirmedLeadership.stopsAlone(
            [ClusterUnconfirmedLeadership.stopAloneKey: "0"]))
    }
}
