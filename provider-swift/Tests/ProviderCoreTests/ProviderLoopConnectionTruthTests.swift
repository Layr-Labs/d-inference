import Foundation
import Testing
@testable import ProviderCore

@Suite("ProviderLoop coordinator connection truth")
struct ProviderLoopConnectionTruthTests {
    private func makeLoop() throws -> ProviderLoop {
        try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/ignored",
                hardware: HardwareInfo(
                    machineModel: "Mac16,5",
                    chipName: "Apple M4 Max",
                    chipFamily: .m4,
                    chipTier: .max,
                    memoryGb: 128,
                    memoryAvailableGb: 124,
                    cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                    gpuCores: 40,
                    memoryBandwidthGbs: 546
                ),
                models: [],
                config: ProviderConfig(
                    provider: ProviderSettings(name: "connection-truth-test"),
                    coordinator: CoordinatorSettings(heartbeatIntervalSecs: 5)
                )
            ),
            purgeLegacyFiles: false,
            attestationSigner: nil
        )
    }

    @Test("transport lifecycle persists verified → offline → connected/offline → fresh verified")
    func lifecyclePersistsImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-loop-connection-\(UUID().uuidString)", isDirectory: true)
        let stateURL = directory.appendingPathComponent("daemon-state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let loop = try makeLoop()
        await loop.setDaemonStateFileForTesting(stateURL)
        let base = Date(timeIntervalSince1970: 1_784_500_000)

        await loop.handleCoordinatorConnected(at: base)
        await loop.handleTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "MDM verification passed",
            at: base.addingTimeInterval(1)
        )
        var state = try #require(DaemonStateFile.read(from: stateURL))
        #expect(state.trust?.status == "verified")
        #expect(state.connectivity?.status == .connected)

        await loop.handleCoordinatorDisconnected(
            reason: "transport reset",
            at: base.addingTimeInterval(2)
        )
        state = try #require(DaemonStateFile.read(from: stateURL))
        #expect(state.writtenAt == base.addingTimeInterval(2).timeIntervalSince1970)
        #expect(state.trust?.status == "offline")
        #expect(state.connectivity?.status == .disconnected)
        #expect(state.connectivity?.reconnectCount == 1)

        await loop.handleCoordinatorConnected(at: base.addingTimeInterval(3))
        state = try #require(DaemonStateFile.read(from: stateURL))
        #expect(state.trust?.status == "offline")
        #expect(state.connectivity?.status == .connected)

        await loop.handleTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "fresh verification",
            at: base.addingTimeInterval(4)
        )
        state = try #require(DaemonStateFile.read(from: stateURL))
        #expect(state.trust?.status == "verified")
        #expect(state.trust?.receivedAt == base.addingTimeInterval(4).timeIntervalSince1970)
        #expect(state.connectivity?.status == .connected)
    }
}
