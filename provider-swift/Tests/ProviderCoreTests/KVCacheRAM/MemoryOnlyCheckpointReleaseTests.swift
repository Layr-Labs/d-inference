import Foundation
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

/// The process's own release points drop the shared RAM-only tier: an OS
/// memory-pressure warning or critical, a model load that needs room, a
/// refused memory charge and shutdown. Each case asserts its own entry is gone,
/// which holds even when another suite releases the shared pool meanwhile.
@Suite("RAM-only tier releases", .serialized)
struct MemoryOnlyCheckpointReleaseTests {
    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "memory-only-release-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    /// Holds one entry in the shared pool and checks it is gone after `release`.
    private func expectReleased(_ release: () async throws -> Void) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let shared = MemoryOnlyCheckpointPool.shared
        let previousBudget = shared.budgetBytes
        shared.setBudget(1 << 30)
        defer { shared.setBudget(previousBudget) }
        let tier = MemoryOnlyCheckpointTierTests.tier(fixture, pool: shared)
        defer { tier.close() }
        let marked = MemoryOnlyCheckpointTierTests.marked
        try #require(try await MemoryOnlyCheckpointTierTests.donate(tier, fixture, receipt: marked(1)) == [256])
        try await release()
        #expect(await MemoryOnlyCheckpointTierTests.stage(tier, fixture, receipt: marked(2)).disposition == .missAbsent)
    }

    @Test("an OS memory-pressure warning or critical releases the tier", arguments: [
        MemoryPressureLevel.warning, .critical,
    ])
    func pressure(level: MemoryPressureLevel) async throws {
        let loop = try makeLoop()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-only-pressure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        await loop.startMemoryProtection(
            markerURL: scratch.appendingPathComponent("oom-marker"),
            lastScanURL: scratch.appendingPathComponent("last-scan"), diagnosticReportsDirs: [])
        let monitor = try #require(await loop.memoryPressureMonitor)
        defer { monitor.cancel() }
        try await expectReleased { monitor.handle(level) }
    }

    @Test("a model load that needs room releases the tier first, and counts it as reclaimable")
    func loadGate() async throws {
        let loop = try makeLoop()
        try await expectReleased {
            let reclaimable = await loop.reclaimableMemoryBytes(from: [:], countingRetainedKVSegments: false)
            #expect(reclaimable >= MemoryOnlyCheckpointPool.shared.bytesInUse)
            await loop.releaseReclaimableMemoryForLoad()
        }
    }

    @Test("shutdown releases the tier")
    func shutdown() async throws {
        let loop = try makeLoop()
        try await expectReleased { await loop.unloadAllModelsForShutdown() }
    }

    @Test("a refused memory charge releases the tier before the caller retries")
    func refusedCharge() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        })
        try await expectReleased {
            #expect(!(await budget.reserveBytes(requestID: "too-large", bytes: 64 << 30)))
        }
    }
}
