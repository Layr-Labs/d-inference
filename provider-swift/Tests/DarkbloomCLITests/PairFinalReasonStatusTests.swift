import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// A started pair that hasn't served for 15 minutes reads one line in `darkbloom status` and `darkbloom cluster status`
// ("The pair hasn't served for 15 min since it started …", `ClusterPairWatch.line`). That line took the place of every
// reason but two Macs on different versions, including the reasons a start's wait already ends on because only a
// person mends them (`ClusterPairSummary.isFinalReason`). Fixtures only: no pairing, cluster service or launchd is read.

private let cli = ClusterPairSummary.cli
private let fifteen = ClusterPairWatch.line(.notServing(seconds: 960), otherMac: "Apple M4 Max, 128 GB", cli: cli)!

/// The leading Mac's view 16 minutes after a start that never served, with `reason` as its status line says it.
private func afterFifteenMinutes(reason: String?) -> ClusterPairSummary {
    var summary = ClusterPairSummary(paired: true)
    summary.role = .leader
    summary.otherMacName = "Apple M4 Max, 128 GB"
    summary.modelID = "gemma-4-26b-qat-4bit"
    summary.modelName = "Gemma 4 26B"
    summary.started = true
    summary.serviceRunning = true
    summary.pairRunning = false
    summary.pairNotRunning = fifteen
    if let reason {
        summary.read(status: [ClusterOnboardingNotServing.statusLine(model: "Gemma 4 26B", reason: reason)], leaderMode: nil)
    }
    return summary
}

@Suite("A reason only a person mends outranks the pair's 15-minute line")
struct PairFinalReasonStatusTests {
    typealias Words = ClusterOnboardingNotServing

    /// One reason of each kind a start's wait ends on.
    static let finalReasons: [String] = [
        Words.notLoggedIn(["this Mac"]),
        Words.words(reason: "clock skew", mac: "one of the Macs"),
        Words.words(reason: "serves_model", mac: "one of the Macs"),
        Words.words(reason: "build_hash", mac: "one of the Macs"),
        Words.words(reason: "version_mismatch", mac: "one of the Macs"),
        ClusterOnboardingReady.notOfferedReason(nil),
        ClusterOnboardingSoloServing.title([.init(mac: "this Mac", pid: 9523)]),
        ClusterOnboardingVersionSplit(thisVersion: ProviderCore.version, otherVersion: "0.0.1",
                                      other: "the other Mac (Apple M4 Max, 128 GB)").reason,
    ]

    @Test(arguments: finalReasons)
    func aFinalReasonIsSaidInsteadOfTheFifteenMinuteLine(reason: String) {
        #expect(ClusterPairSummary.isFinalReason(reason), "\(reason)")
        let summary = afterFifteenMinutes(reason: reason)
        #expect(summary.state == .notServing && summary.reason == reason)
        #expect(summary.startedButNotRunningLine == nil, "\(summary.startedButNotRunningLine ?? "")")
        #expect(summary.clusterStatusLines.contains { $0.contains(reason) }, "\(summary.clusterStatusLines)")
        #expect(!summary.clusterStatusLines.contains { $0.contains("hasn't served for") }, "\(summary.clusterStatusLines)")
        #expect(summary.statusLine.contains(reason) && !summary.statusLine.contains("hasn't served for"), "\(summary.statusLine)")
    }

    /// A reason the pair is waited through (memory that may free, a part that starts again) keeps the 15-minute line,
    /// and so does a pair with no reason at all: a missing reason ends a start's wait, but it is nothing to say.
    @Test func anyOtherReasonKeepsTheFifteenMinuteLine() {
        let waitedThrough = [Words.words(reason: "memory_gate_refused", mac: "one of the Macs"),
                             Words.words(reason: "peer_lost", mac: "one of the Macs"),
                             "this Mac's part ended (exit 1: closed) and starts again by itself"]
        for reason in waitedThrough {
            #expect(!ClusterPairSummary.isFinalReason(reason), "\(reason)")
            let summary = afterFifteenMinutes(reason: reason)
            #expect(summary.startedButNotRunningLine == fifteen, "\(reason)")
            #expect(summary.clusterStatusLines.contains(fifteen), "\(summary.clusterStatusLines)")
        }
        let unknown = afterFifteenMinutes(reason: nil)
        #expect(ClusterPairSummary.isFinalReason(unknown.reason) && unknown.reason == nil)
        #expect(unknown.startedButNotRunningLine == fifteen)
    }

    /// Two ranks whose workers speak different versions: the pair can't start until both Macs run one release, so the
    /// next step is the update, not "Both Macs keep trying by themselves".
    @Test func aVersionMismatchNamesTheUpdate() {
        let summary = afterFifteenMinutes(reason: Words.words(reason: "version_mismatch", mac: "one of the Macs"))
        #expect(summary.next == "Run `\(cli) update` on both Macs; then check that `\(cli) --version` shows the same version on both.",
                "\(summary.next ?? "")")
    }

    /// The next step of each stopped start a person can mend, read from its words as the other Mac's window reads them
    /// (`ClusterOnboardingNotServing.stopRemedy`); an unresolved device journal is waited through, with the command
    /// that clears it.
    @Test func aStoppedStartAPersonCanMendNamesWhatToRun() {
        func next(_ text: String, viewerRank: Int? = nil) -> String? {
            var summary = afterFifteenMinutes(reason: nil)
            summary.pairRunning = true
            summary.pairNotRunning = nil
            let reason = Words.words(reason: text, mac: "one of the Macs", viewerRank: viewerRank)
            summary.read(status: [Words.statusLine(model: "Gemma 4 26B", reason: reason)], leaderMode: nil)
            return summary.next
        }
        let memory = "Quit apps on that Mac; the cluster starts again by itself. Or choose a smaller model: `\(cli) cluster` on this Mac."
        #expect(next("memory_gate_refused") == memory)
        #expect(next("memory_gate_refused: rank 1 needs 73.57 GiB, has 68.20 GiB", viewerRank: 0) == memory)
        #expect(next("device_busy") == "Run `\(cli) cluster recover` on each Mac; the cluster starts again by itself.")
        #expect(!ClusterPairSummary.isFinalReason(Words.words(reason: "device_busy", mac: "one of the Macs")))
        #expect(next("peer_lost") == "Both Macs keep trying by themselves; `\(cli) cluster` on this Mac shows more.")
    }
}
