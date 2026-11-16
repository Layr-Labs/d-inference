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

    /// DevNet builds are versioned `0.10.13-dev.branch.N`. W1 on DevNet pair-2 (2026-11-16, W14 note 2): only the Studio
    /// updated (`.202`; the MacBook's update had failed, `.199`), and the Studio's `status` repeated "this Mac's part ended
    /// (exit 1: Installed input identity or SHA-256 differs)" every 12 s without naming the other Mac's update: the split
    /// was never detected between such versions. They compare as semantic versions now, release versions as before.
    @Test func aSplitBetweenDevNetBuildsNamesTheMacToUpdate() throws {
        let newer = "0.10.13-dev.branch.202", older = "0.10.13-dev.branch.199"
        let split = try #require(ClusterOnboardingVersionSplit.detect(thisVersion: newer, otherVersion: older, other: otherMac))
        #expect(!split.behindHere && split.newer == newer && split.older == older)
        #expect(split.remedies.first?.hasPrefix("On the other Mac (Apple M4 Max, 128 GB), run `") == true
                && split.remedies.first?.hasSuffix("update`; the pair starts once both Macs run \(newer).") == true,
                "\(split.remedies)")
        #expect(ClusterOnboardingVersionSplit.next(reason: split.reason, thisVersion: newer, other: otherMac, cli: cli)
                == "On the other Mac (Apple M4 Max, 128 GB), run `\(cli) update`; then check that `\(cli) --version` shows \(newer) on both Macs.")
        #expect(ClusterOnboardingVersionSplit.next(reason: split.reason, thisVersion: older, other: otherMac, cli: cli)
                == "On this Mac, run `\(cli) update`; then check that `\(cli) --version` shows \(newer) on both Macs.")
        let behind = try #require(ClusterOnboardingVersionSplit.detect(thisVersion: older, otherVersion: newer, other: otherMac))
        #expect(behind.behindHere && behind.remedies.first?.hasPrefix("On this Mac, run `") == true)
        // A release is newer than any DevNet build of its own or an earlier version; one build is no split; a version
        // that is no version still says nothing.
        #expect(ClusterOnboardingVersionSplit.detect(thisVersion: "0.10.14", otherVersion: newer, other: otherMac)?.older == newer)
        #expect(ClusterOnboardingVersionSplit.detect(thisVersion: newer, otherVersion: "v" + newer, other: otherMac) == nil)
        #expect(ClusterOnboardingVersionSplit.detect(thisVersion: newer, otherVersion: "dev", other: otherMac) == nil)
        #expect(ClusterOnboardingVersionSplit.detect(thisVersion: "0.10.13", otherVersion: "0.10.12", other: otherMac)?.older == "0.10.12")
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
        // A pair that serves only on its local API restarts at once for a request, so only `darkbloom update` asks it;
        // `DARKBLOOM_CLUSTER_LOCAL_UPDATE_RESTART=0` asks it as 0.10.13 did (its cycle then drains for nothing).
        #expect(!ClusterPairUpdate.askPairToFollow(pairServes: true, localOnly: true, requestPath: path, now: now))
        #expect(!FileManager.default.fileExists(atPath: path.path), "an unattended install took a local-only pair down")
        #expect(ClusterPairUpdate.askPairToFollow(pairServes: true, localOnly: true, requestPath: path, now: now,
                                                  localOnlyUpdatedByHand: false))
        #expect(ClusterPairUpdate.takeRequest(from: path, now: now) != nil)
    }
}
