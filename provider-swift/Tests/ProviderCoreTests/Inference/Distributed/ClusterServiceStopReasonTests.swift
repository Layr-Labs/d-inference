import DarkbloomClusterRemote
import Foundation
import Testing
@testable import ProviderCore

/// The 0.10.8 candidate on real Macs (2026-11-04): the ✗ said "this Mac's part ended (exit 1: CancellationError())" and
/// the diagnostics file carried only "CancellationError()", while the part had said why just before, in its log:
/// "Distributed serving stops: the coordinator reported this member's runtime as outdated; serving stops until it is
/// updated." The part's last error now reads that reason instead of the cancellation, from the part's own start on.
@Suite("Cluster part stop reason")
struct ClusterServiceStopReasonTests {
    private func log(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rank-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        return url
    }

    private let banner = "darkbloom 0.10.8 (registered cluster member; solo inference disabled)\n"
    private let stop = "Distributed serving stops: the coordinator reported this member's runtime as outdated; serving stops until it is updated.\n"
    private let cancelled = "Error: CancellationError()\n"
    private let reason = "the coordinator reported this member's runtime as outdated; serving stops until it is updated"

    @Test func theStopReasonIsSaidInsteadOfTheCancellation() throws {
        let url = try log(banner + stop + cancelled)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.lastError(in: url) == reason)
        #expect(ClusterService.lastError(in: url, preferStopReason: false) == "CancellationError()", "the raw error stays readable")
    }

    @Test func theStopReasonIsFoundBehindRequestLines() throws {
        let line = "2026-11-04T01:50:40Z darkbloom.distributed.request: lane=0 prompt=1834 output=212 first_token_ms=412 decode_tps=41.7 outcome=stop\n"
        let url = try log(banner + stop + String(repeating: line, count: 200) + cancelled)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.lastError(in: url) == reason)
    }

    @Test func anEarlierPartsStopReasonIsNeverThisParts() throws {
        let earlier = banner + stop + cancelled
        let url = try log(earlier + banner + cancelled)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.lastError(in: url, from: UInt64(earlier.utf8.count)) == "CancellationError()")
    }

    @Test func aSpecificErrorStaysTheReason() throws {
        let url = try log(banner + stop + "Error: Tensor-parallel shard load needs 49.08 GiB of admissible memory and has 0.17 GiB\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.lastError(in: url) == "Tensor-parallel shard load needs 49.08 GiB of admissible memory and has 0.17 GiB")
    }

    /// The 0.10.8 candidate on pair-2 (c3, B17): the member's worker was SIGKILLed three times in one load. Each time
    /// the leader's part ended because its link to the member closed ("Error: closed"), while the member's service kept
    /// its link follower running and logged nothing. The ✗ said "A part keeps ending the same way: starting; this Mac's
    /// part ended (exit 1: closed) …", "This Mac: closed." and "The other Mac (Apple M5 Max, 128 GB): its part is
    /// running, no error reported.": it blamed the leader and cleared the Mac whose worker died.
    @Test func aLinkThatKeepsClosingNamesTheOtherMacsSide() {
        let line = "starting; this Mac's part ended (exit 1: closed) and starts again by itself"
        let own = ClusterServiceStatus.Child(running: false, starts: 4, lastEnd: "exit 1", restartInSeconds: 2, lastError: "closed")
        let other = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil)
        let title = OnboardingLive.keepsEndingTitle(line, own: own)
        #expect(!title.contains("starting;"), "no progress word in the title: \(title)")
        #expect(title.contains("the link to the other Mac keeps closing") && title.contains("the other Mac's worker ended or the cable dropped"),
                "the other Mac's side, both possible causes: \(title)")
        let lines = OnboardingLive.errorLines(here: "This Mac", there: "The other Mac (Apple M5 Max, 128 GB)", own: own, other: other,
                                              otherUnreachable: nil)
        #expect(lines.count == 2 && !lines[1].contains("no error reported"), "the member isn't cleared: \(lines)")
        #expect(lines[0].contains("link to the other Mac closed") && lines[1].contains("doesn't report its worker restarting"),
                "what each Mac can and can't say: \(lines)")
    }

    /// The two Macs run different versions (one updated alone, account 668cf2b3 on 11-04): the ✗ says so first, with
    /// both versions and the command on the Mac that's behind, in each direction, instead of guessing at the link.
    @Test func aVersionSplitIsNamedFirstWithTheMacAndTheCommand() {
        let own = ClusterServiceStatus.Child(running: false, starts: 13, lastEnd: "exit 1", restartInSeconds: 30, lastError: "closed")
        let other = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil)
        let there = "The other Mac (Apple M4 Max, 128 GB)"
        let behindThere = OnboardingLive.errorLines(here: "This Mac", there: there, own: own, other: other, otherUnreachable: nil,
                                                    thisVersion: "0.10.8", otherVersion: "0.10.7")
        #expect(behindThere.first == "The two Macs run different Darkbloom versions: The other Mac (Apple M4 Max, 128 GB) runs 0.10.7, this Mac runs 0.10.8.")
        #expect(behindThere.dropFirst().first == "On the other Mac (Apple M4 Max, 128 GB), run `\(ClusterOnboardingCommand.name) update`; the pair starts once both Macs run 0.10.8.")
        #expect(!behindThere.contains { $0.contains("doesn't report its worker restarting") }, "no guess at the cause: \(behindThere)")

        let behindHere = OnboardingLive.errorLines(here: "This Mac", there: there, own: own, other: other, otherUnreachable: nil,
                                                   thisVersion: "0.10.8", otherVersion: "0.10.9")
        #expect(behindHere.dropFirst().first == "On this Mac, run `\(ClusterOnboardingCommand.name) update`; the pair starts once both Macs run 0.10.9.")

        let same = OnboardingLive.errorLines(here: "This Mac", there: there, own: own, other: other, otherUnreachable: nil,
                                             thisVersion: "0.10.9", otherVersion: "0.10.9")
        let unknown = OnboardingLive.errorLines(here: "This Mac", there: there, own: own, other: other, otherUnreachable: nil,
                                                thisVersion: "0.10.9", otherVersion: nil)
        let before = OnboardingLive.errorLines(here: "This Mac", there: there, own: own, other: other, otherUnreachable: nil)
        #expect(same == before && unknown == before, "one version, or the other Mac's unknown: the lines as before")
    }

    /// A part that ends by itself keeps its own reason, without the live row's progress word.
    @Test func aPartThatEndsByItselfKeepsItsReason() {
        let line = "starting; this Mac's part ended (exit 1: Tensor-parallel shard load needs 49.08 GiB) and starts again by itself"
        let own = ClusterServiceStatus.Child(running: false, starts: 3, lastEnd: "exit 1", restartInSeconds: 2,
                                             lastError: "Tensor-parallel shard load needs 49.08 GiB")
        #expect(OnboardingLive.keepsEndingTitle(line, own: own)
                == "A part keeps ending the same way: this Mac's part ended (exit 1: Tensor-parallel shard load needs 49.08 GiB) and starts again by itself")
    }

    /// The refactor pass on the c3 fix: the title cut the live row at its first "; ", so a head with its own "; " lost
    /// its opening clause ("A part keeps ending the same way: it starts again by itself; …"). The title reads as a
    /// whole sentence that names what ends, for each such head.
    @Test func theTitleNeverStartsMidSentence() {
        let own = ClusterServiceStatus.Child(running: false, starts: 3, lastEnd: "exit 1", restartInSeconds: 2, lastError: "boom")
        let ownEnd = "this Mac's part ended (exit 1: boom) and starts again by itself"
        // A rank-0 end seen from a Mac that isn't rank 0: the head names an end itself, so the whole row stays.
        let rankZero = "rank 0 on the other Mac (Apple M3 Ultra, 256 GB) ended (exit 1: closed); it starts again by itself; " + ownEnd
        #expect(OnboardingLive.keepsEndingTitle(rankZero, own: own) == "A part keeps ending the same way: " + rankZero)
        // A failure text with its own "; ", and a session detail with one: from the clause that names the end.
        for head in ["waiting for the other Mac (Apple M3 Ultra, 256 GB): connection refused; retrying", "1 of 2 parts ready (loading; 40%)"] {
            #expect(OnboardingLive.keepsEndingTitle(head + "; " + ownEnd, own: own) == "A part keeps ending the same way: " + ownEnd, "\(head)")
        }
    }

    /// The DevNet run on the M5 Ultra pair (A-4), B17's mirror: a part whose own worker dies ends "closed" too (the
    /// worker's pipe), and the ✗ blamed the other Mac. This Mac's incident log said `worker_crashed` (source leader)
    /// for its own worker each time: the ✗ names this Mac then, and blames neither when it can't be told.
    @Test func aWorkerThatEndsHereIsNamedHere() {
        let line = "starting; this Mac's part ended (exit 1: closed) and starts again by itself"
        let own = ClusterServiceStatus.Child(running: false, starts: 4, lastEnd: "exit 1", restartInSeconds: 2, lastError: "closed")
        let other = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil)
        let here = OnboardingLive.keepsEndingTitle(line, own: own, ownWorker: .ended)
        #expect(here.contains("this Mac's worker keeps ending") && !here.contains("the other Mac's worker"), "names this Mac: \(here)")
        let lines = OnboardingLive.errorLines(here: "This Mac", there: "The other Mac (Apple M5 Ultra, 256 GB)", own: own, other: other,
                                              otherUnreachable: nil, ownWorker: .ended)
        #expect(lines[0].contains("its worker ended") && !lines[1].contains("can't be read from here"), "the other Mac isn't blamed: \(lines)")
        let unknown = OnboardingLive.keepsEndingTitle(line, own: own, ownWorker: .unknown)
        #expect(unknown.contains("can't be told") && !unknown.contains("the other Mac's worker ended")
                && !unknown.contains("this Mac's worker keeps ending"), "blames neither: \(unknown)")
    }

    /// The DevNet run (A-3): the member couldn't dial, because macOS kept its link follower off the local network. Its
    /// part said so in its log and ended cleanly (exit 0), so its status carried no reason and the leader's ✗ said "Make
    /// sure it is on". The part's last error now carries that reason.
    @Test func aLocalNetworkRefusalIsThePartsReason() throws {
        let url = try log(banner + "link refused: connect failed (unreachable)\n"
            + "this process may not reach the local network: macOS refused the dial before the cable was tried. Allow darkbloom under "
            + "System Settings > Privacy & Security > Local Network (once), or start the follower from a session that has that access.\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.lastError(in: url) == "its part can't reach the local network: macOS refused the dial before the cable was "
            + "tried. Allow darkbloom under System Settings > Privacy & Security > Local Network (once), or start the follower from a session that has that access")
    }

    /// The DevNet run (A-10, B18): a planned switch showed the old model's clean stop as a crash, "this Mac's part ended
    /// (exit 0) and starts again by itself; the other Mac's part ended (stopped) and s…". A clean stop (stopped, or exit 0
    /// with no reason) is a stop on either Mac; an exit 0 that says why (a refused dial) is still said.
    @Test func aCleanStopIsNotAnEnd() {
        for end in ["stopped", "exit 0"] {
            let stopped = ClusterServiceStatus.Child(running: false, starts: 2, lastEnd: end, restartInSeconds: nil, lastError: nil)
            #expect(!OnboardingLive.endShown(stopped), "\(end): a stop")
        }
        let refused = ClusterServiceStatus.Child(running: false, starts: 2, lastEnd: "exit 0", restartInSeconds: 2,
                                                 lastError: "its part can't reach the local network")
        let crashed = ClusterServiceStatus.Child(running: false, starts: 3, lastEnd: "exit 1", restartInSeconds: 2, lastError: "closed")
        #expect(OnboardingLive.endShown(refused) && OnboardingLive.endShown(crashed), "ends with a reason are said")
    }

    /// The leader's incident log in the DevNet run (Mac A, 2026-11-04), as recorded: the member's worker killed four times
    /// (07:39:50–07:41:50Z), then the leader's own worker (07:43:54–07:46:41Z). Every kill reads `source` leader and
    /// `worker_crashed` on the leader; only the message says whose worker ended. "<user>" is the log's own redaction of
    /// the `darkbloom` prefix. Fields: time (UTC), source, reason code, message.
    static let devnetIncidents = """
        07:39:50\tfollower\tworker_crashed\tsession fenced: follower worker ended before it was ready: its owner exited \
        with status 0: darkbloom-worker-tail-v1 darkbloom-qmv-batch-invariant-v1 enabled=1 source=worker
        07:39:50\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:39:50\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | rank 1 follower said: worker ended before it \
        was ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:40:22\tfollower\tworker_crashed\tsession fenced: follower worker ended before it was ready: its owner exited \
        with status 0: darkbloom-worker-tail-v1 darkbloom-qmv-batch-invariant-v1 enabled=1 source=worker
        07:40:22\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:40:22\tfollower\tunclassified\t[rank 1] the leader's session was fenced: leader fenced
        07:40:22\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | rank 1 follower said: worker ended before it \
        was ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:40:59\tfollower\tworker_crashed\tsession fenced: follower worker ended before it was ready: its owner exited \
        with status 0: darkbloom-worker-tail-v1 darkbloom-qmv-batch-invariant-v1 enabled=1 source=worker
        07:40:59\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:40:59\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | rank 1 follower said: worker ended before it \
        was ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:41:50\tfollower\tworker_crashed\tsession fenced: follower worker ended before it was ready: its owner exited \
        with status 0: darkbloom-worker-tail-v1 darkbloom-qmv-batch-invariant-v1 enabled=1 source=worker
        07:41:50\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:41:50\tfollower\tunclassified\t[rank 1] the leader's session was fenced: leader fenced
        07:41:50\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | rank 1 follower said: worker ended before it \
        was ready: its owner exited with status 0: <user>-worker-tail-v1 <user>-qmv-batch-invariant-v1 enabled=1 source=worker
        07:43:54\tfollower\tunclassified\tsession fenced: leader fenced
        07:43:54\tfollower\tunclassified\t[rank 1] the leader's session was fenced: leader fenced
        07:43:54\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | <user>-worker-exit-v1 rank=0 termination=signalled(9)
        07:44:14\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 JACCL bootstrap through the authenticated owner \
        (rank 1); no coordi...
        07:44:49\tfollower\tunclassified\tsession fenced: leader fenced
        07:44:49\tfollower\tunclassified\t[rank 1] the leader's session was fenced: leader fenced
        07:44:49\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | <user>-worker-exit-v1 rank=0 termination=signalled(9)
        07:45:09\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 JACCL bootstrap through the authenticated owner \
        (rank 1); no coordi...
        07:45:44\tfollower\tunclassified\tsession fenced: leader fenced
        07:45:44\tfollower\tunclassified\t[rank 1] the leader's session was fenced: leader fenced
        07:45:44\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | <user>-worker-exit-v1 rank=0 termination=signalled(9)
        07:46:04\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 JACCL bootstrap through the authenticated owner \
        (rank 1); no coordi...
        07:46:41\tfollower\tunclassified\tsession fenced: leader fenced
        07:46:41\tfollower\tunclassified\t[rank 1] the leader's session was fenced: leader fenced
        07:46:41\tleader\tworker_crashed\tClusterWorkerOwnerError: closed | <user>-worker-exit-v1 rank=0 termination=signalled(9)
        07:47:01\tfollower\tworker_crashed\t[rank 1] the leader's session was fenced: follower worker ended before it was \
        ready: its owner exited with status 0: <user>-worker-tail-v1 JACCL bootstrap through the authenticated owner \
        (rank 1); no coordi...
        """

    /// A-4 on the leader's real records: a crash names this Mac only when it is this Mac's rank's own worker exit
    /// (`ClusterWorkerOwnerService.workerExitMarker`), the other Mac when it is what that Mac's follower said
    /// (`DistributedInstalledSession.followerSaid`, B17's words), and neither Mac otherwise. The leader records both
    /// with `source` leader, so a `worker_crashed` alone named the leader for the member's kills. A log that is missing or
    /// can't be read blames neither Mac, and a field this build doesn't know (the log is shared between installs) is
    /// ignored.
    @Test func onlyThisMacsOwnWorkerExitNamesThisMac() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("incidents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func at(_ time: Substring) throws -> Date { try #require(ISO8601DateFormatter().date(from: "2026-11-04T\(time)Z")) }
        func log(_ name: String, _ records: [Substring]) throws -> URL {
            let file = directory.appendingPathComponent("\(name).json")
            for record in records {
                let field = record.split(separator: "\t", maxSplits: 3).map(String.init)
                let ts = try at(Substring(field[0])).timeIntervalSince1970
                try ClusterIncidentLog(file: file, clock: { ts }).record(.init(severity: .error, source: field[1],
                    stateCode: "activation_launch_failed", reasonCode: field[2], guidanceCode: nil, message: field[3]))
            }
            return file
        }
        func worker(_ file: URL, since time: Substring) throws -> OnboardingLive.OwnWorker {
            OnboardingLive.ownWorker(inIncidentLog: ClusterIncidentLog(file: file), since: try at(time), rank: 0, otherRanks: [1])
        }
        let records = Self.devnetIncidents.split(separator: "\n")
        #expect(records.filter { $0.contains("\tleader\t") }.allSatisfy {
            $0.contains(DistributedInstalledSession.followerSaid(rank: 1))
                || $0.contains(ClusterWorkerOwnerService.workerExitMarker + "0 termination=")
        }, "each of the leader's records is in a format its writer shares with the reader")
        #expect(try worker(directory.appendingPathComponent("none.json"), since: "07:39:37") == .unknown, "no log: neither Mac")

        // Each kill alone, with what the leader's log recorded at that second.
        let kills: [(Substring, OnboardingLive.OwnWorker)] = [("07:39:50", .notSeen), ("07:40:22", .notSeen), ("07:40:59", .notSeen),
            ("07:41:50", .notSeen), ("07:43:54", .ended), ("07:44:49", .ended), ("07:45:44", .ended), ("07:46:41", .ended)]
        for (time, whose) in kills {
            let file = try log(time.replacingOccurrences(of: ":", with: ""), records.filter { $0.hasPrefix(time) })
            #expect(try worker(file, since: time) == whose,
                    "\(time): \(whose == .ended ? "this Mac's own worker" : "the other Mac's worker (B17)")")
        }
        let all = try log("all", records)
        #expect(try worker(all, since: "07:39:37") == .unknown, "both Macs' kills in one wait: neither Mac is named")
        #expect(try worker(all, since: "07:43:44") == .ended, "the leader's own kills, once the member's are before the wait")

        var stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: all)) as? [String: Any])
        let incidents = try #require(stored["incidents"] as? [[String: Any]])
        stored["incidents"] = incidents.map { $0.merging(["build": "0.10.6-dev.branch.76"]) { $1 } }
        try JSONSerialization.data(withJSONObject: stored).write(to: all)
        #expect(try worker(all, since: "07:43:44") == .ended, "a field this build doesn't know is ignored")

        try Data("{\"schema_version\": 1, \"incidents\": [{\"seq\": 1}]}".utf8).write(to: all)
        #expect(try worker(all, since: "07:39:37") == .unknown, "a malformed log: neither Mac")
    }

    /// A-4 reads this install's incident log (`ClusterIncidentLog.forThisInstall`): with Darkbloom and Darkbloom Dev on one
    /// Mac, the other install's record of its own worker never names this Mac's.
    @Test func onlyThisInstallsRecordsNameThisMac() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("incidents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let since = Date().addingTimeInterval(-60)
        try ClusterIncidentLog(file: file, install: "prod").record(.init(severity: .error, source: "leader",
            stateCode: "activation_launch_failed", reasonCode: "worker_crashed", guidanceCode: nil,
            message: "closed | " + ClusterWorkerOwnerService.workerExitMarker + "0 termination=signalled(9)"))
        func worker(install: String) -> OnboardingLive.OwnWorker {
            OnboardingLive.ownWorker(inIncidentLog: ClusterIncidentLog(file: file, install: install), since: since, rank: 0, otherRanks: [1])
        }
        #expect(worker(install: "prod") == .ended, "this install's own record")
        #expect(worker(install: "dev") == .unknown, "another install's record: neither Mac")
    }

    /// One CLI name and one app name: the screens, the live operations and the cluster service start from this build's
    /// identity with nothing set at startup, so a DevNet build's texts and its tests say the same names.
    @Test func theNamesAreThisBuildsWithoutBeingSet() {
        #expect(ClusterOnboardingCommand.name == BuildEnvironment.current.cliName)
        #expect(OnboardingLive.cli == BuildEnvironment.current.cliName)
        #expect(ClusterOnboardingCommand.app == BuildEnvironment.current.appDisplayName)
        #expect(ClusterService.appName == BuildEnvironment.current.appDisplayName)
    }

    /// The pair-2 DevNet run (P2-1) and the M5 Ultra pair's headless Mac B (A-2): macOS kept the member's link follower
    /// off the local network ("link refused: connectFailed (unreachable)", "this process may not reach the local
    /// network"), while the service's own probe (one broadcast datagram) logged "allowed". The follower kept running and
    /// retrying, so its Mac's status said "running, no error". The truth is the follower's own last dial.
    @Test func theFollowersOwnRefusalIsTheTruth() throws {
        let refused = "2026-11-04T07:32:14Z link-follower: link refused: connectFailed (unreachable)\n"
            + "2026-11-04T07:32:14Z link-follower: this process may not reach the local network: macOS refused the dial before the cable "
            + "was tried. Allow darkbloom under System Settings > Privacy & Security > Local Network (once), or start the follower from a "
            + "session that has that access.\n"
        let url = try log(banner + refused)
        defer { try? FileManager.default.removeItem(at: url) }
        let reason = ClusterService.followerRefusal(in: url)
        #expect(reason?.hasPrefix("its part can't reach the local network: macOS refused the dial") == true, "\(String(describing: reason))")
        let later = try log(banner + refused + "2026-11-04T07:40:02Z link-follower: connected\n2026-11-04T07:40:02Z link-follower: session opened\n")
        defer { try? FileManager.default.removeItem(at: later) }
        #expect(ClusterService.followerRefusal(in: later) == nil, "allowed later: the last dial connected")
        let running = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: reason)
        #expect(ClusterLocalNetworkAccess.state(report: .allowed, published: running) == .blocked, "the probe's allowed doesn't hide the refusal")
        #expect(ClusterLocalNetworkAccess.state(report: .allowed, published: nil) == .allowed)
        #expect(OnboardingLive.otherMacRefused(running), "the leader reads the member's refusal")
        let lines = OnboardingLive.localNetworkRefusalLines(otherMac: "The other Mac (Apple M5 Max, 128 GB)", app: "Darkbloom Dev")
        #expect(lines.first?.contains("macOS keeps Darkbloom Dev there off the local network") == true
                && lines.contains { $0.contains("System Settings → Privacy & Security → Local Network → turn on “Darkbloom” "
                    + "(macOS lists Darkbloom Dev as “Darkbloom”)") }
                && lines.contains { $0.contains("Screen Sharing") }, "what to do there: \(lines)")
    }

    /// A refusal the follower got past (Local Network turned on, then "connected") is not its part's reason once that
    /// part ends either: a planned stop after it is a clean stop, not a refusal that would end the leader's wait at once
    /// and keep the Mac "blocked". Without a later link, the refusal is still the ended part's reason (A-3).
    @Test func aRefusalTheFollowerGotPastIsNotItsEnd() throws {
        let refused = "2026-11-04T07:32:14Z link-follower: link refused: connectFailed (unreachable)\n"
            + "2026-11-04T07:32:14Z link-follower: this process may not reach the local network: macOS refused the dial before the cable "
            + "was tried. Allow darkbloom under System Settings > Privacy & Security > Local Network (once), or start the follower from a "
            + "session that has that access.\n"
        let stoppedLater = try log(banner + refused + "2026-11-04T07:40:02Z link-follower: connected\n"
            + "2026-11-04T07:40:02Z link-follower: session opened\n2026-11-04T08:07:27Z link-follower: session fenced: leader fenced\n"
            + "2026-11-04T08:07:29Z link-follower: stopped idle\n")
        defer { try? FileManager.default.removeItem(at: stoppedLater) }
        let reason = ClusterService.lastError(in: stoppedLater)
        #expect(reason == nil, "connected since: \(String(describing: reason))")
        let stopped = ClusterServiceStatus.Child(running: false, starts: 2, lastEnd: "exit 0", restartInSeconds: nil, lastError: reason)
        #expect(!OnboardingLive.otherMacRefused(stopped) && !OnboardingLive.endShown(stopped), "a planned stop, not a refusal")
        let endedRefused = try log(banner + refused + "2026-11-04T07:42:00Z link-follower: stopped idle\n")
        defer { try? FileManager.default.removeItem(at: endedRefused) }
        #expect(ClusterService.lastError(in: endedRefused)?.hasPrefix(ClusterService.localNetworkReasonPrefix) == true,
                "never connected: the refusal is still its reason")
    }

    /// The refusal is said of the Mac it happened on, on either screen. The leader's own wait names the other Mac; a wait
    /// the member forwarded to the leader (which answers it, `answering`) names the member, "this Mac" on its screen.
    @Test func aRefusalIsSaidOfTheMacItHappenedOn() {
        let app = "Darkbloom Dev", leader = "The other Mac (Apple M5 Ultra, 256 GB)"
        let own = OnboardingLive.localNetworkRefusalLines(line: OnboardingLive.localNetworkLine(forwarded: false), otherMac: leader, app: app)
        #expect(own?.first == "The other Mac can't reach this Mac over the cable: macOS keeps Darkbloom Dev there off the local network")
        #expect(own?.last == "\(leader): System Settings → Privacy & Security → Local Network → turn on “Darkbloom” (macOS lists "
                + "Darkbloom Dev as “Darkbloom”); if it isn't listed, click Allow when macOS asks on that Mac's screen, the next time "
                + "Darkbloom Dev dials over the cable (on a Mac with no display, through Screen Sharing). Then choose Retry here.",
                "the screen's own step: \(String(describing: own))")
        let forwarded = OnboardingLive.localNetworkRefusalLines(line: OnboardingLive.localNetworkLine(forwarded: true), otherMac: leader,
                                                                app: app)
        #expect(forwarded?.first == "This Mac can't reach the other Mac over the cable: macOS keeps Darkbloom Dev off the local network."
                && forwarded?.last?.hasPrefix("On this Mac: System Settings → Privacy & Security → Local Network") == true
                && forwarded?.last?.contains("choose Retry here") == true, "the member's own screen: \(String(describing: forwarded))")
        #expect(OnboardingLive.localNetworkRefusalLines(line: "starting", otherMac: leader, app: app) == nil)
    }

    /// R4-4 (the M5 Ultra pair's DevNet runs): the hints sent the owner to a "Darkbloom Dev" row under Local Network.
    /// Both apps share the bundle ID `io.darkbloom.provider`, so macOS lists the DevNet app as "Darkbloom"; and where macOS
    /// never recorded an answer for the app there is no row at all: it asks on that Mac's screen at the next dial, and
    /// someone must click Allow. Every hint names the row macOS shows, in both identities, and says what to do without one.
    @Test func theLocalNetworkHintsNameTheRowMacOSShows() {
        #expect(ClusterService.localNetworkRow == "Darkbloom", "the row is the bundle ID's name in every build")
        #expect(ClusterOnboardingCommand.localNetworkRow == ClusterService.localNetworkRow)
        let leader = "The other Mac (Apple M5 Ultra, 256 GB)"
        for (app, alias) in [("Darkbloom", ""), ("Darkbloom Dev", " (macOS lists Darkbloom Dev as “Darkbloom”)")] {
            func steps(_ screen: String) -> String {
                "System Settings → Privacy & Security → Local Network → turn on “Darkbloom”\(alias); if it isn't listed, click Allow when "
                    + "macOS asks on \(screen), the next time \(app) dials over the cable (on a Mac with no display, through Screen Sharing)"
            }
            let blocked = ClusterOnboardingDriver.localNetworkBlockedLines(app: app, row: "Darkbloom")
            #expect(blocked == ["This Mac can't reach the other Mac over the cable: macOS keeps \(app) off the local network.",
                                "On this Mac: " + steps("this Mac's screen") + "; the start goes on by itself once it's on."],
                    "\(app), this Mac: \(blocked)")
            let refused = OnboardingLive.localNetworkRefusalLines(otherMac: leader, app: app, row: "Darkbloom")
            #expect(refused == ["The other Mac can't reach this Mac over the cable: macOS keeps \(app) there off the local network",
                                "\(leader): " + steps("that Mac's screen") + ". Then choose Retry here."],
                    "\(app), the other Mac: \(refused)")
            #expect(!(blocked + refused).joined().contains("turn on “Darkbloom Dev”"), "never a row macOS doesn't show")
        }
        // `cluster status` says the same, with the command that starts the pair again.
        let status = ClusterLocalNetworkAccess.statusWords(.otherMac, otherMac: leader, app: "Darkbloom Dev", cli: "darkbloom-dev")
        #expect(status.next.contains("turn on “Darkbloom” (macOS lists Darkbloom Dev as “Darkbloom”); if it isn't listed, click Allow")
                && status.next.hasSuffix("Then run `darkbloom-dev start` here, or choose Retry in `darkbloom-dev cluster`."), "\(status.next)")
    }

    /// The pair-2 re-test (R-4): the leader's Local Network ✗ said the refusal three times, the last in the follower's own
    /// words. That ✗'s own lines already say it plainly, so each Mac's line there only says that its part can't reach the
    /// local network; any other ✗ keeps the part's own reason (A-3).
    @Test func theLocalNetworkCrossSaysTheRefusalOnce() {
        let reason = ClusterService.refusalReason(": macOS refused the dial before the cable was tried. Allow Darkbloom under System "
            + "Settings > Privacy & Security > Local Network (once), or start the follower from a session that has that access.")
        let refused = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: reason)
        let running = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil)
        let ended = ClusterServiceStatus.Child(running: false, starts: 1, lastEnd: "exit 0", restartInSeconds: nil, lastError: reason)
        let there = "The other Mac (Apple M5 Max, 128 GB)"
        let cross = OnboardingLive.errorLines(here: "This Mac", there: there, own: running, other: refused, otherUnreachable: nil,
                                              refusalSaid: true)
        #expect(cross == ["This Mac: its part is running, no error reported.",
                          "\(there): its part is running and can't reach the local network."], "\(cross)")
        let forwarded = OnboardingLive.errorLines(here: "This Mac", there: there, own: ended, other: running, otherUnreachable: nil,
                                                  refusalSaid: true)
        #expect(forwarded[0] == "This Mac: its part can't reach the local network.", "the joining Mac's own: \(forwarded)")
        let other = OnboardingLive.errorLines(here: "This Mac", there: there, own: running, other: refused, otherUnreachable: nil)
        #expect(other[1] == "\(there): \(reason) (its part is still running).", "any other ✗ keeps A-3's reason: \(other)")
    }

    /// R-4: a line too long for the ✗ (300 characters) is cut at a word, never inside a parenthesis, and says it was cut.
    @Test func aLongLineIsCutAtAWordOutsideAnyParenthesis() {
        // The leader's fourth line on the re-test, 302 characters; it was cut at "(its part is still running".
        let line = "The other Mac (Apple M5 Max, 128 GB): its part can't reach the local network: macOS refused the dial before the "
            + "cable was tried. Allow Darkbloom Dev under System Settings > Privacy & Security > Local Network (once), or start the "
            + "follower from a session that has that access (its part is still running)."
        let cut = ClusterConsoleText.boundedAtWord(line, maximum: 300)
        #expect(cut.count <= 300 && cut.hasSuffix(" from a session that has that access…"), "\(cut)")
        #expect(cut.filter { $0 == "(" }.count == cut.filter { $0 == ")" }.count, "never inside a parenthesis: \(cut)")
        #expect(ClusterConsoleText.boundedAtWord("one two three four", maximum: 12) == "one two…", "at a word")
        #expect(ClusterConsoleText.boundedAtWord("This Mac: its part is running, no error reported.", maximum: 300)
                == "This Mac: its part is running, no error reported.", "a short line is kept whole")
    }

    /// R-3 (the pair-2 re-test): the pairing hint's firewall line and the line that asks to pair again after a reinstall
    /// name this build's app, as macOS lists it (its firewall entry), not production's in the DevNet app.
    @Test func thePairingLinesNameThisBuildsApp() {
        let app = BuildEnvironment.current.appDisplayName
        #expect(ClusterOnboardingPairing.otherMacNotFoundLines
            .contains("· macOS's firewall lets \(app) in on both Macs (System Settings → Network → Firewall);"))
        #expect(ClusterOnboardingPairingProblem.keyChanged.line
            .contains("(\(app) was reinstalled, or this Mac moved between the Darkbloom and DevNet apps)"))
    }

    private static let refusedLines = "2026-11-04T07:32:14Z link-follower: link refused: connectFailed (unreachable)\n"
        + "2026-11-04T07:32:14Z link-follower: this process may not reach the local network: macOS refused the dial before the cable "
        + "was tried. Allow darkbloom under System Settings > Privacy & Security > Local Network (once), or start the follower from a "
        + "session that has that access.\n"

    /// A running part's status reads its log for a refusal only when the part is the link follower (no other part writes
    /// one), and only when the log grew since the last read: the joining Mac's window asks every second, and each read
    /// walked up to 8 MiB back under the service's lock (P2-8, a member's status took up to 29 s).
    @Test func onlyALinkFollowersLogIsReadAndOnlyOnceItGrew() throws {
        let url = try log(banner)
        defer { try? FileManager.default.removeItem(at: url) }
        var scans = 0
        let scan: (URL, UInt64) -> String? = { url, offset in scans += 1; return ClusterService.followerRefusal(in: url, from: offset) }
        var read: ClusterService.FollowerRefusalRead?
        #expect(ClusterService.runningPartRefusal(linkFollower: false, in: url, from: 0, remembered: &read, scan: scan) == nil
                && scans == 0, "rank 0, a member or a solo server: its log isn't read")
        _ = ClusterService.runningPartRefusal(linkFollower: true, in: url, from: 0, remembered: &read, scan: scan)
        #expect(ClusterService.runningPartRefusal(linkFollower: true, in: url, from: 0, remembered: &read, scan: scan) == nil
                && scans == 1, "nothing written since: read once")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile(); handle.write(Data(Self.refusedLines.utf8)); try handle.close()
        let refusal = ClusterService.runningPartRefusal(linkFollower: true, in: url, from: 0, remembered: &read, scan: scan)
        #expect(refusal?.hasPrefix(ClusterService.localNetworkReasonPrefix) == true && scans == 2, "it grew: read again")
        #expect(ClusterService.runningPartRefusal(linkFollower: true, in: url, from: 0, remembered: &read, scan: scan) == refusal
                && scans == 2, "the same refusal, remembered")
    }

    /// A member allowed just now: its follower logs a refusal only when it changes, so the old one stays in its log until
    /// it connects, which needs this Mac's part listening. The refusal ends the leader's wait only once this Mac's part has
    /// run long enough for one more dial (20 ms doubling to 1 s between dials), only from a follower that runs (an ended
    /// one's is history: Retry starting a stopped pair must not end at once on it), and not after a later dial failed
    /// another way.
    @Test func aRefusalCountsOnlyWhileTheFollowerCouldStillBeRefused() throws {
        let now = 1_000_000.0
        func own(running: Bool, since: Double?) -> ClusterServiceStatus.Child {
            .init(running: running, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil, startedAt: since)
        }
        #expect(OnboardingLive.refusalIsCurrent(own: own(running: true, since: now - 60), now: now), "this Mac's part ran a minute")
        #expect(!OnboardingLive.refusalIsCurrent(own: own(running: true, since: now - 3), now: now), "just started: no dial reached it yet")
        #expect(!OnboardingLive.refusalIsCurrent(own: own(running: false, since: nil), now: now)
                && !OnboardingLive.refusalIsCurrent(own: nil, now: now), "nothing listens here")

        let url = try log(banner + Self.refusedLines)
        defer { try? FileManager.default.removeItem(at: url) }
        let reason = try #require(ClusterService.followerRefusal(in: url))
        let ended = ClusterServiceStatus.Child(running: false, starts: 2, lastEnd: "exit 0", restartInSeconds: 2, lastError: reason)
        #expect(!OnboardingLive.otherMacRefused(ended), "an ended part's refusal is history")
        #expect(ClusterLocalNetworkAccess.state(report: .allowed, published: ended) == .allowed, "nor does it block this Mac")

        let later = try log(banner + Self.refusedLines + "2026-11-04T07:40:02Z link-follower: link refused: handshakeRejected\n")
        defer { try? FileManager.default.removeItem(at: later) }
        #expect(ClusterService.followerRefusal(in: later) == nil, "its last dial reached the other Mac and failed another way")
    }
}
