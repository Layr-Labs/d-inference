import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterRemote
@testable import ProviderCore

/// A coordinator-formed pair whose start the Mac that follows refused for memory (a DevNet pair: its share needed
/// 73.57 GiB of admissible memory and the Mac had 66.6–70.5 GiB). The leading Mac's record of the failed start
/// carries rank 1's own words, so its incident, its stopped line and both Macs' screens say that the other Mac lacks
/// memory, with both figures, instead of an unclassified failure the screens blamed on the coordinator.
@Suite("A pair that did not form says why rank 1 ended")
struct ClusterPairStopReasonTests {
    static let followerSaid = "worker ended before it was ready: its owner exited with status 0: darkbloom-worker-tail-v1 "
        + "darkbloom-cluster-worker: Tensor-parallel shard load needs 73.57 GiB of admissible memory and has 68.20 GiB: "
        + "22.5 GiB free plus 45.7 GiB of file cache"

    @Test func aFollowersMemoryRefusalReachesTheIncidentTheStoppedLineAndTheScreens() {
        let reason = ClusterPairServingContext.notReadyReason(ClusterWorkerOwnerError.closed,
            rankZero: (false, "running"), rankOne: (false, "exited(0)"), followerSaid: Self.followerSaid)
        let error = ClusterPairSlotError.notServing(reason)
        // The leader records the failure as it always did (`recordClusterPairIncident`): its text now classifies.
        let explanation = ClusterFailureClassifier.classify(message: String(describing: error))
        #expect(explanation.guidance.code == "memory_gate_refused", "\(explanation.guidance.code): \(reason)")
        let words = ClusterOnboardingPairReport.stoppedWords(guidance: explanation.guidance.code, error: String(describing: error))
        #expect(words == "memory_gate_refused: rank 1 needs 73.57 GiB, has 68.20 GiB", "\(words)")
        // The status carries the stopped line's text, and either Mac reads it back.
        let state = ClusterOnboardingPairReport.state(ClusterOnboardingPairReport.text(.stopped(words)))
        #expect(state == .stopped(words))
        #expect(ClusterOnboardingNotServing.words(reason: words, mac: "one of the Macs", viewerRank: 0)
                == "The other Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)")
        #expect(ClusterOnboardingNotServing.words(reason: words, mac: "one of the Macs", viewerRank: 1)
                == "This Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)")
    }

    /// The words are for the screen they reach: the leading Mac's own (rank 0), or the Mac that follows (rank 1),
    /// whose status and `darkbloom cluster` the leading Mac answers.
    @Test func theWordsNameTheMacOfTheScreenTheyReach() {
        #expect(OnboardingLive.viewerRank(localRankZero: true, answering: false) == 0)
        #expect(OnboardingLive.viewerRank(localRankZero: true, answering: true) == 1, "the leading Mac answering the Mac that follows")
        #expect(OnboardingLive.viewerRank(localRankZero: false, answering: false) == 1)
        #expect(OnboardingLive.viewerRank(localRankZero: false, answering: true) == 0)
    }

    /// A follower that refused for another reason and ended properly is no crash: its clean exit is said as such, so
    /// the incident stays unclassified instead of reading "a rank's process ended unexpectedly". A real exit status is
    /// kept.
    @Test func aFollowersCleanExitIsNoCrash() {
        func guidance(_ said: String) -> String {
            let reason = ClusterPairServingContext.notReadyReason(ClusterWorkerOwnerError.closed,
                rankZero: (false, "running"), rankOne: (false, "exited(0)"), followerSaid: said)
            return ClusterFailureClassifier.classify(message: String(describing: ClusterPairSlotError.notServing(reason))).guidance.code
        }
        #expect(guidance("worker ended before it was ready: its owner exited with status 0: fixture: refused for a reason no rule names")
                == "unknown_failure")
        #expect(guidance("worker ended before it was ready: its owner exited with status 3: fixture") == "worker_crashed")
        #expect(guidance(Self.followerSaid) == "memory_gate_refused")
    }

    /// Without rank 1's words the record is as before, and the stopped line keeps the guidance code.
    @Test func withoutRankOnesWordsTheStoppedLineIsTheGuidanceCode() {
        let reason = ClusterPairServingContext.notReadyReason(ClusterWorkerOwnerError.closed,
            rankZero: (false, "running"), rankOne: (false, "exited(0)"), followerSaid: nil)
        #expect(reason == "the pair did not become ready: DarkbloomClusterProcess.ClusterWorkerOwnerError.closed; "
                + "rank 0 ready false owner running; rank 1 ready false owner exited(0)")
        let error = String(describing: ClusterPairSlotError.notServing(reason))
        #expect(ClusterOnboardingPairReport.stoppedWords(guidance: "unknown_failure", error: error) == "unknown_failure")
        #expect(ClusterOnboardingPairReport.stoppedWords(guidance: nil, error: error) == "the pair did not form")
        #expect(ClusterOnboardingNotServing.words(reason: "unknown_failure", mac: "one of the Macs", viewerRank: 0)
                == "The pair stopped (unknown_failure)")
    }
}
