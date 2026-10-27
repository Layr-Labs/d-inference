import Foundation
import Testing
@testable import ProviderCore

/// `darkbloom status` can only say how many served requests ended early on a
/// cancel if the daemon writes that count beside the served totals.
@Suite("Daemon state served counts")
struct DaemonStateServedCountTests {
    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "daemon-state-served-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    @Test func theStateFileCarriesServedRequestsThatEndedEarly() async throws {
        let loop = try makeLoop()
        let stats = await loop.stats
        for _ in 0..<3 { stats.incrementRequestsServed() }
        stats.addTokensGenerated(120)
        stats.incrementCancellationsPartialComplete()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-state-served-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("daemon-state.json")
        DaemonStateFile.write(await loop.currentDaemonState(), to: file)

        let state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let written = try #require(state["stats"] as? [String: Any])
        #expect(written["requests_served"] as? Int == 3)
        #expect(written["tokens_generated"] as? Int == 120)
        #expect(written["cancellations_partial_complete"] as? Int == 1)
        #expect(DaemonStateFile.read(from: file)?.stats.cancellationsPartialComplete == 1)
    }
}
