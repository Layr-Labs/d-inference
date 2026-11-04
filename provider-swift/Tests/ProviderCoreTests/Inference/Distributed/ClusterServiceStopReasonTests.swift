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
}
