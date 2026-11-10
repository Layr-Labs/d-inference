import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// 0.10.8, account 668cf2b3 (2026-11-04): the M5 Max updated alone through single-Mac serving and the pair never served;
// no screen or status named the versions. Fixtures only: no pairing, cluster service, launchd or ~/.darkbloom is read.

private let otherMac = "the other Mac (Apple M4 Max, 128 GB)"
private let cli = ClusterPairSummary.cli

private func pair(role: ClusterPairSummary.Role) -> ClusterPairSummary {
    var pair = ClusterPairSummary(paired: true)
    pair.role = role
    pair.otherMacName = "Apple M4 Max, 128 GB"
    pair.modelID = "gemma-4-26b-qat-4bit"
    pair.modelName = "Gemma 4 26B"
    pair.started = true
    pair.serviceRunning = true
    return pair
}

@Suite("Pair version split")
struct PairVersionSplitTests {
    /// The status line both Macs read (the joining Mac shows the leading Mac's): not serving, why, and on each Mac the
    /// Mac to update with the build's command; a final reason, so a start's wait ends on it.
    @Test(arguments: [true, false])
    func statusNamesTheMacToUpdateOnEachMac(thisMacNewer: Bool) {
        let older = "0.0.1", newer = "999.0.0"
        let split = ClusterOnboardingVersionSplit(thisVersion: thisMacNewer ? ProviderCore.version : older,
                                                  otherVersion: thisMacNewer ? older : newer, other: otherMac)
        let line = ClusterOnboardingNotServing.statusLine(model: "Gemma 4 26B", reason: split.reason)
        var summary = pair(role: thisMacNewer ? .leader : .member)
        summary.read(status: [line] + split.remedies, leaderMode: nil)
        #expect(summary.state == .notServing)
        #expect(summary.reason?.contains("the two Macs run different Darkbloom versions") == true, "\(summary.reason ?? "")")
        #expect(ClusterPairSummary.isFinalReason(summary.reason))
        let expected = thisMacNewer
            ? "On the other Mac (Apple M4 Max, 128 GB), run `\(cli) update`; then check that `\(cli) --version` shows \(ProviderCore.version) on both Macs."
            : "On the Mac with \(older), run `\(cli) update`; then check that `\(cli) --version` shows \(newer) on both Macs."
        #expect(summary.next == expected, "\(summary.next ?? "")")
    }

    /// This Mac on the older version reads "On this Mac".
    @Test func statusOnTheOlderMacSaysThisMac() {
        let split = ClusterOnboardingVersionSplit(thisVersion: "999.0.0", otherVersion: ProviderCore.version, other: otherMac)
        var summary = pair(role: .member)
        summary.read(status: [ClusterOnboardingNotServing.statusLine(model: "Gemma 4 26B", reason: split.reason)], leaderMode: nil)
        #expect(summary.next == "On this Mac, run `\(cli) update`; then check that `\(cli) --version` shows 999.0.0 on both Macs.")
    }

    /// The watchdog installs only for single-Mac serving: never for a member's job, never while the pair runs here
    /// (actual state); a Mac whose pair is gone simply updates.
    @Test func watchdogNeverUpdatesUnderARunningPair() {
        #expect(Watchdog.updates(autoUpdate: true, jobIsClusterMember: false, pairServes: false))
        #expect(!Watchdog.updates(autoUpdate: true, jobIsClusterMember: false, pairServes: true))
        #expect(!Watchdog.updates(autoUpdate: true, jobIsClusterMember: true, pairServes: false))
        #expect(!Watchdog.updates(autoUpdate: false, jobIsClusterMember: false, pairServes: false))
    }

    /// The background updater on a Mac whose pair runs here asks its cluster service to restart into the release with the
    /// other Mac (`darkbloom update`'s request); a Mac serving alone, its pair gone, asks nothing.
    @Test func singleMacUpdateAsksARunningPairToFollow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pair-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = ClusterServiceAgent.updateRequestPath(serviceDirectory: directory)
        let now = Date().timeIntervalSince1970
        #expect(!ClusterPairUpdate.askPairToFollow(pairServes: false, requestPath: path, now: now))
        #expect(!FileManager.default.fileExists(atPath: path.path), "a Mac whose pair is gone simply updates")
        #expect(ClusterPairUpdate.askPairToFollow(pairServes: true, requestPath: path, now: now))
        #expect(ClusterPairUpdate.takeRequest(from: path, now: now) != nil, "the supervisor takes it as `darkbloom update`'s")
    }
}
