import Foundation
import Testing
@testable import ProviderCore

/// The cluster service's own Local Network probe (`ClusterLocalNetworkAccess.startServiceProbe`), with the probe and
/// its timing injected: no datagram leaves this Mac and nothing under the real home is written.
@Suite("Cluster service Local Network probe")
struct ClusterLocalNetworkAccessTests {
    /// Refused six times, then allowed: the probe keeps asking past its fast minutes (the onboarding waits for the
    /// answer without a deadline, so a late Allow is still seen), writes each change in the service's own directory,
    /// and stops once allowed.
    @Test func probeKeepsAskingUntilAllowedAndWritesInTheServicesOwnDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-lna-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let answers = Answers(refusals: 6)
        let said = Said()
        ClusterLocalNetworkAccess.startServiceProbe(directory: directory, probe: { answers.next() }, fastSeconds: 0.005,
                                                    intervals: (fast: 1_000, slow: 20_000), say: { said.add($0) })
        let file = ClusterLocalNetworkAccess.reportFile(in: directory)
        let deadline = Date().addingTimeInterval(10)
        var state: ClusterOnboardingLocalNetwork?
        while Date() < deadline, state != .allowed {
            if let data = try? Data(contentsOf: file) {
                state = (try? JSONDecoder().decode(ClusterLocalNetworkAccess.Report.self, from: data))?.state
            }
            usleep(5_000)
        }
        #expect(state == .allowed, "the late Allow reaches the report")
        usleep(100_000)
        #expect(answers.count == 7, "six refusals, then allowed, then no more probes: \(answers.count)")
        #expect(said.all == ["local network access for this service: blocked", "local network access for this service: allowed"],
                "each change said once: \(said.all)")
        #expect(file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL, "the report is in the service's own directory")
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var refusals: Int
        private var probes = 0
        init(refusals: Int) { self.refusals = refusals }
        var count: Int { lock.withLock { probes } }
        func next() -> ClusterOnboardingLocalNetwork {
            lock.withLock {
                probes += 1
                guard refusals > 0 else { return .allowed }
                refusals -= 1
                return .blocked
            }
        }
    }

    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var lines = [String]()
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }
}
