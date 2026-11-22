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

    private func wait(_ run: Run, seconds: Double = 40, leads: Bool = true,
                      confirmedAfter: Int?) -> ClusterOnboardingFailure? {
        let deadline = run.clock.addingTimeInterval(seconds)
        return OnboardingLive.awaitLeadership(deadline: deadline,
            waiting: { run.lines.append($0); run.events.append("said") },
            leadsHere: { leads },
            confirmed: {
                defer { run.polls += 1 }
                return confirmedAfter.map { run.polls >= $0 } ?? false
            },
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
}
