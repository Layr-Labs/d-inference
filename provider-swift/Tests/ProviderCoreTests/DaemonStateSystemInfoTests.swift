// Copyright © 2026 Eigen Labs.
//
// T13-06 (b): `currentDaemonState()` carries the last heartbeat's
// system_metrics (`DaemonState.system` was always nil before), read from
// the stored copy rather than a second collect().

import Foundation
import Testing

@testable import ProviderCore

@Test("daemon state carries the last heartbeat's system metrics")
func daemonStateCarriesLastHeartbeatSystemMetrics() async throws {
    let loop = try ProviderLoop(
        config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "test", chipName: "test", chipFamily: .unknown,
                chipTier: .unknown, memoryGb: 32, memoryAvailableGb: 28,
                cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
                gpuCores: 10, memoryBandwidthGbs: 100),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "daemon-system-info-test"),
                backend: BackendSettings(),
                coordinator: CoordinatorSettings())),
        purgeLegacyFiles: false,
        attestationSigner: nil)

    // No heartbeat built yet: not reported (nil), never a fabricated zero.
    #expect(await loop.currentDaemonState().system == nil)

    let metrics = SystemMetrics(memoryPressure: 0.61, cpuUsage: 0.12, thermalState: .serious)
    let state = await loop.state
    state.lastSystemMetrics = metrics
    let system = try #require(await loop.currentDaemonState().system)
    #expect(system == DaemonState.SystemInfo(
        memoryPressure: 0.61, cpuUsage: 0.12, thermalState: "serious"))

    // Round-trips through the file `status`/`doctor` read.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("daemon-system-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    await loop.setDaemonStateFileForTesting(url)
    await loop.writeDaemonState()
    #expect(DaemonStateFile.read(from: url)?.system == system)
}
