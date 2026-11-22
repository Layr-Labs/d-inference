import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom cluster stop --service` on a leading Mac whose cluster service restarted and hasn't confirmed its claim
/// yet, while the other Mac doesn't answer (seen on a DevNet pair: the Studio's service had restarted while its disk was
/// full, and the MacBook's service was off). The wait before acting refused, and this Mac's service stayed up. Now its
/// own service stops alone, as `--local-only` does, and the lines say the pair wasn't stopped from here. The login agent
/// stands in; nothing of this Mac's own cluster is read or stopped.
struct ClusterStopUnconfirmedLeaderTests {
    private final class Count: @unchecked Sendable { var removed = 0 }

    private static let refused = ClusterOnboardingFailure(
        ["This Mac's leadership is not confirmed yet (…); run `darkbloom cluster` again in a moment."], unconfirmedLeaderAlone: true)

    @Test func anUnconfirmedLeaderWhoseOtherMacIsSilentStopsItsOwnServiceAlone() throws {
        let count = Count()
        let off = try Cluster.Stop.finishStop(.failure(Self.refused), stopsAlone: true) { count.removed += 1; return ["agent"] }
        #expect(count.removed == 1, "this Mac's service was stopped")
        #expect(off.otherMac == .unanswered(ClusterUnconfirmedLeadership.otherMacUnanswered))
        #expect(Array(off.lines.prefix(2)) == ClusterUnconfirmedLeadership.stopAloneLines)
        #expect(off.lines.contains { $0.hasPrefix("This Mac's cluster service is stopped and will not start at login.") })
        #expect(off.lines.last == "If the other Mac's cluster service is still on, run `\(ClusterPairSummary.cli) cluster stop --service` there too.")
        #expect(!off.lines.contains("This Mac stopped serving."), "the pair wasn't stopped from here, and no line says it was")
        #expect(Cluster.Stop.BeforeUnpairing.stopped(off.otherMac).outcome
            == .done("the other Mac did not answer, so it was not asked to stop"))
    }

    @Test func itStillRefusesWhenTheOtherMacAnswersWhenForwardedOrWithTheSwitchOff() {
        var answering = Self.refused
        answering.unconfirmedLeaderAlone = false
        for (failure, forwarded, stopsAlone) in [(answering, false, true), (Self.refused, true, true), (Self.refused, false, false)] {
            let count = Count()
            #expect(throws: Cluster.Stop.Failure.self) {
                try Cluster.Stop.finishStop(.failure(failure), forwarded: forwarded, stopsAlone: stopsAlone) { count.removed += 1; return [] }
            }
            #expect(count.removed == 0, "this Mac's service kept running (forwarded \(forwarded), switch \(stopsAlone))")
        }
    }
}
