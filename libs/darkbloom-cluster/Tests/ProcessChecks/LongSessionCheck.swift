import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }

/// A fake-worker pair kept past the old 300-second lifetime and sixteen-request
/// cap on rank-lease renewals alone, with keep-warm on (S03, S27). Each owner
/// launches its child with one 30-second grant and renews it every five
/// seconds; nothing else keeps the children. Run by `run.sh` only when
/// `PROCESS_CHECKS_LONG_SECONDS` is set (it takes that long): model-free.
@main struct LongSessionCheck {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let seconds = Double(CommandLine.arguments[2]) ?? 330
        let now = DispatchTime.now().uptimeNanoseconds
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 5_000_000_000, initialLeaseDeadline: now + ClusterWorkerLease.ttlNanoseconds)
        }
        defer { for worker in workers { worker.fence() } }
        for worker in workers { try worker.launch() }
        let pair = try ClusterWorkerPair(workers: workers, startupDeadline: now + 5_000_000_000, keepWarm: .standard)
        let started = Date()
        var served = 0
        while Date().timeIntervalSince(started) < seconds {
            let lease: ClusterWorkerRequest
            do {
                lease = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                    deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000, capacityLimitBytes: 1800, sampling: nil))
            } catch {
                throw Failure(message: "request \(served + 1) at \(Int(Date().timeIntervalSince(started))) s refused (\(error)): "
                    + "\(pair.admissionState), exited \(workers.map(\.observedExit)), renewals \(workers.map(\.renewalsSent))")
            }
            try lease.start { _ in true }
            await lease.waitUntilRetired(); lease.releaseResources(); served += 1
            try await Task.sleep(for: .seconds(15))
        }
        let elapsed = Date().timeIntervalSince(started)
        let state = pair.admissionState
        try require(served > 16 && state.requestsServed == served && state.isValid && pair.readiness != nil,
            "the pair did not stay ready past sixteen requests: served \(served), \(state)")
        try require(workers.allSatisfy { !$0.observedExit && $0.renewalsSent >= UInt64(elapsed / 5) - 2 },
            "a child ended or was not renewed: \(workers.map(\.renewalsSent))")
        try require(state.keepWarmExchanges > 0, "keep-warm exchanged nothing while idle")
        await pair.shutdown()
        try require(workers.allSatisfy { $0.observedExit && $0.termination == .exited(0) && $0.sentSignals.isEmpty },
            "the long session did not shut down cleanly")
        print("{\"passed\":true,\"seconds\":\(Int(elapsed)),\"requests\":\(served),\"renewals\":\(workers.map(\.renewalsSent)),\"keepWarmExchanges\":\(state.keepWarmExchanges)}")
    }
}
