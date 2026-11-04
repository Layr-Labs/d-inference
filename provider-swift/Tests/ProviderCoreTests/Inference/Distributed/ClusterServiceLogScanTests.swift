import Foundation
import Testing
@testable import ProviderCore

/// The pair's progress line and the serving notice are written once per change, while every request adds a line to
/// the same `rank.log` (160–300 bytes each). On the production pair (0.10.7) the log's last 16 KiB held only about nine
/// minutes of request lines, so a busy pair that serves lost its `Pair: serving` line and read as not serving. These
/// read the latest such line however many request lines follow it, never before the part's start and within a bound.
@Suite("Cluster service log scan")
struct ClusterServiceLogScanTests {
    /// A temporary rank log; removed by the caller.
    private func log(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rank-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// `bytes` of request lines as the production log has them.
    private func requests(_ bytes: Int) -> String {
        let line = "2026-11-04T01:50:40Z darkbloom.distributed.request: lane=0 prompt=1834 output=212 first_token_ms=412 decode_tps=41.7 outcome=stop\n"
        return String(repeating: line, count: bytes / line.utf8.count + 1)
    }

    private let offered = "Notice: " + ClusterOnboardingReady.registeredNotice + " with an installed cluster approval\n"

    @Test func pairLineIsFoundBehindMoreThanSixteenKiBOfRequests() throws {
        for followed in [20 * 1024, 1_200 * 1024] {
            let url = try log(offered + ClusterOnboardingPairReport.startingLine + "\n"
                + ClusterOnboardingPairReport.servingLine(warmupSeconds: 0.84) + "\n" + requests(followed))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(ClusterService.pairReport(in: url, from: 0) == .serving(test: "in 0.84 s"),
                    "a serving pair stays serving behind \(followed) bytes of request lines")
        }
    }

    @Test func pairLineOfAnEarlierPartIsNeverThisParts() throws {
        let earlier = ClusterOnboardingPairReport.servingLine(warmupSeconds: 1) + "\n" + requests(4 * 1024)
        let url = try log(earlier + offered + requests(40 * 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.pairReport(in: url, from: UInt64(earlier.utf8.count)) == nil, "the line before the part's start is not its")
        #expect(ClusterService.pairReport(in: url, from: 0) == .serving(test: "in 1.00 s"), "from the log's start it is found")
    }

    @Test func servingNoticeIsFoundBehindMoreThanSixteenKiBOfRequests() throws {
        let url = try log("Notice: " + ClusterLocalServing.localOnlyNotice + "\n" + requests(300 * 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClusterService.servingNotice(in: url) == ClusterLocalServing.localOnlyNotice)
        #expect(ClusterService.servingNotice(in: url, from: UInt64(("Notice: " + ClusterLocalServing.localOnlyNotice + "\n").utf8.count)) == nil,
                "a notice written before the part's start is not its")
    }

    @Test func theScanStopsAtItsBoundAndAcrossChunkEdges() throws {
        let pair = ClusterOnboardingPairReport.servingLine(warmupSeconds: 0.5) + "\n"
        let url = try log(pair + requests(100 * 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        let isPair: (Substring) -> Bool = { $0.hasPrefix(ClusterOnboardingPairReport.logPrefix) }
        #expect(ClusterLogScan.lastLine(in: url, limit: 64 * 1024, where: isPair) == nil, "a line beyond the bound is not read")
        #expect(ClusterLogScan.lastLine(in: url, limit: 200 * 1024, where: isPair).map(String.init) == String(pair.dropLast()),
                "within the bound it is found whole")
        // Tiny chunks: a line split across several chunk edges is still read whole.
        #expect(ClusterLogScan.lastLine(in: url, limit: 200 * 1024, chunk: 7, where: isPair).map(String.init) == String(pair.dropLast()),
                "chunk edges inside the line")
        #expect(ClusterLogScan.limitBytes == 8 * 1024 * 1024, "the production bound")
    }
}
