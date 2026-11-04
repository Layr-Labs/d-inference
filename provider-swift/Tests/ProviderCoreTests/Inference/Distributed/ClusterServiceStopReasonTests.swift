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
            OnboardingLive.ownWorker(inIncidentLog: file, since: try at(time), rank: 0, otherRanks: [1])
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
                && lines.contains { $0.contains("System Settings → Privacy & Security → Local Network → turn on “Darkbloom Dev”") }
                && lines.contains { $0.contains("Screen Sharing") }, "what to do there: \(lines)")
    }
}
