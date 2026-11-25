import Foundation
import Testing
@testable import ProviderCore

/// A Mac whose boot security refuses Darkbloom serving keeps its provider
/// process up without a coordinator connection, so the crash-recovery
/// watchdog never reads the refusal as a crash loop, and it ends on a stop.
@Suite("Boot security hold")
struct BootSecurityHoldTests {
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
                provider: ProviderSettings(name: "boot-security-hold-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    @Test func theHoldStampsLivenessNeverConnectsAndEndsOnAStop() async throws {
        let loop = try makeLoop()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-security-hold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("daemon-state.json")
        await loop.setDaemonStateFileForTesting(file)

        let refusals = BootSecuritySnapshot(
            macOSMajorVersion: 27, sip: .enabled,
            sipConfiguration: SIPConfiguration(rawValue: 0x4), secureBoot: .permissive
        ).servingRefusals
        #expect(refusals.count == 2)
        let hold = Task { await loop.holdWithoutDarkbloomServing(refusals) }

        // The liveness stamp is written at once; the hold opens no coordinator connection.
        var stamped = false
        for _ in 0..<100 where !stamped {
            stamped = DaemonStateFile.read(from: file) != nil
            if !stamped { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(stamped)
        #expect(await loop.coordinatorClient == nil)

        // A stop (a lifecycle drain) ends the hold within a few poll intervals.
        await loop.beginServingDrain(owner: .lifecycle)
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await hold.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 15_000_000_000); return false }
            let first = await group.next() ?? false
            if !first { hold.cancel() }
            group.cancelAll()
            return first
        }
        #expect(ended)
        #expect(await loop.coordinatorClient == nil)
    }
}
