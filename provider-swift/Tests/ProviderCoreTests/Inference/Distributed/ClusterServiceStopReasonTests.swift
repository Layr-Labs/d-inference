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
}
