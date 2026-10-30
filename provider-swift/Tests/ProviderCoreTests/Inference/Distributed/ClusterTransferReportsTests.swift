import Foundation
import Testing

@testable import ProviderCore

/// The live reports a model copy or download sends the `darkbloom cluster` screen.
@Suite("Cluster transfer reports")
struct ClusterTransferReportsTests {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [ClusterOnboardingProgress] = []

        func append(_ report: ClusterOnboardingProgress) { lock.withLock { reports.append(report) } }

        var live: [(text: @Sendable (Int?) -> String, logged: Bool)] {
            lock.withLock {
                reports.compactMap {
                    guard case .live(let text, let logged) = $0 else { return nil }
                    return (text, logged)
                }
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 500

        var now: TimeInterval { lock.withLock { seconds } }

        func advance(_ interval: TimeInterval) { lock.withLock { seconds += interval } }
    }

    @Test("the first count starts the clock and is logged, then one per 10 points and 30 s; each report fits the width it is given")
    func reports() throws {
        let clock = Clock()
        let sent = Sent()
        let reports = ClusterTransferReports(label: "Copying Qwen3.5-9B to the other Mac", clock: { clock.now },
                                             send: { sent.append($0) })
        let total: Int64 = 6_100_000_000
        reports.report(done: 1_000_000_000, total: total)
        clock.advance(1)
        reports.report(done: 3_400_000_000, total: total)
        clock.advance(30)
        reports.report(done: 6_000_000_000, total: total)

        let live = sent.live
        try #require(live.count == 3)
        #expect(live.map(\.logged) == [true, false, true])
        // The bytes already there when the first count came are not credited to the rate.
        #expect(live[0].text(nil) == "Copying Qwen3.5-9B to the other Mac  16%  1.0/6.1 GB")
        #expect(live[1].text(nil) == "Copying Qwen3.5-9B to the other Mac  55%  3.4/6.1 GB  2.4 GB/s  1s left")
        #expect(live[1].text(40) == "Copying Qwen3.5-9B to the\u{2026}  55%  1s left")
    }
}
