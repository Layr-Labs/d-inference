import Foundation
import Testing

@testable import ProviderCore

/// Only rank 0 of a coordinator-paired pair, which hosts the pair's slot, writes the pair's `Pair: …` lines
/// (`ProviderLoop.serveCommittedStart`, `publishClusterPairSlot`). Rank 1's link follower reports to rank 0 over the cable
/// and writes none. The Mac that follows read its own log for `Pair: serving` all the same, so 15 minutes after every
/// start its service said "The pair hasn't served for 15 min" while the pair served, and `cluster status` there put that
/// line before the leading Mac's ✓ (b3-restart.md §4; DevNet pair-2 and .95).
@Suite("The Mac that follows judges the pair only by what it knows")
struct ClusterPairFollowerVerdictTests {
    private let ttl = ClusterService.leaseTTLSeconds
    private let serving = ClusterOnboardingPairReport.State.serving(test: nil)

    @Test("rank 1 of a coordinator-paired pair serves while its part runs and the leading Mac answers; it reads no pair line")
    func followingRankNeedsNoPairLine() {
        var read = false
        #expect(ClusterService.partServesNow(partUp: true, otherAnsweredAt: 100, now: 101, memberRank: 1,
                                             pairReport: { read = true; return nil }))
        #expect(!read, "rank 1's log has no pair line to read")
    }

    @Test("rank 0 of a coordinator-paired pair serves only once its own pair line says so")
    func rankZeroNeedsItsServingLine() {
        let reports: [(ClusterOnboardingPairReport.State?, Bool)] = [(nil, false), (.starting, false),
                                                                      (.stopped("memory_gate_refused"), false), (serving, true)]
        for (report, serves) in reports {
            #expect(ClusterService.partServesNow(partUp: true, otherAnsweredAt: 100, now: 101, memberRank: 0,
                                                 pairReport: { report }) == serves, "\(String(describing: report))")
        }
    }

    @Test("a part that isn't coordinator-paired (the local-only leader, the link follower) serves while it runs and the other Mac answers")
    func otherPartsAsBefore() {
        #expect(ClusterService.partServesNow(partUp: true, otherAnsweredAt: 100, now: 101, memberRank: nil, pairReport: { nil }))
    }

    @Test("no part running, or no answer from the other Mac within the lease: never serving, whatever the rank")
    func notUpOrSilent() {
        for rank in [0, 1, nil] as [Int?] {
            #expect(!ClusterService.partServesNow(partUp: false, otherAnsweredAt: 100, now: 101, memberRank: rank,
                                                  pairReport: { serving }), "\(String(describing: rank))")
            #expect(!ClusterService.partServesNow(partUp: true, otherAnsweredAt: nil, now: 101, memberRank: rank,
                                                  pairReport: { serving }), "\(String(describing: rank))")
            #expect(!ClusterService.partServesNow(partUp: true, otherAnsweredAt: 100, now: 100 + ttl, memberRank: rank,
                                                  pairReport: { serving }), "\(String(describing: rank))")
        }
    }

    @Test("the Mac that follows a serving pair stays `running` past 15 minutes, with no line to say otherwise")
    func followerVerdictStaysRunning() {
        var watch = ClusterPairWatch()
        for minute in 0...30 {
            let now = 1_000 + Double(minute) * 60
            let servingNow = ClusterService.partServesNow(partUp: true, otherAnsweredAt: now - 5, now: now, memberRank: 1,
                                                          pairReport: { nil })
            let verdict = watch.tick(now: now, intent: true, otherAnsweredAt: now - 5, serving: servingNow)
            #expect(verdict == .running, "minute \(minute)")
            #expect(ClusterPairWatch.line(verdict, otherMac: nil, cli: "darkbloom") == nil, "minute \(minute)")
        }
    }

    @Test("a following part that never ran while the leading Mac answered is still `notServing` after 15 minutes")
    func followerThatNeverRan() {
        var watch = ClusterPairWatch()
        var verdict = ClusterPairWatch.Verdict.stopped
        for minute in 0...15 {
            let now = 1_000 + Double(minute) * 60
            let servingNow = ClusterService.partServesNow(partUp: false, otherAnsweredAt: now - 5, now: now, memberRank: 1,
                                                          pairReport: { nil })
            verdict = watch.tick(now: now, intent: true, otherAnsweredAt: now - 5, serving: servingNow)
        }
        #expect(verdict == .notServing(seconds: 15 * 60))
    }
}
