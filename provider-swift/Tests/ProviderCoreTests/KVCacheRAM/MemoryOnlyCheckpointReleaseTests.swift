import Foundation
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

/// The process's own release points drop the RAM-only tier: an OS
/// memory-pressure warning or critical, a model load that needs room, a
/// refused memory charge the tier covers and shutdown, in both servers. Each
/// case uses a private pool through its server's memory budget.
@Suite("RAM-only tier releases", .serialized)
struct MemoryOnlyCheckpointReleaseTests {
    static func makeLoop(
        name: String = "memory-only-release-test", kvBudget: GlobalKVCacheBudget? = nil
    ) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: name, memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: config, attestationSigner: nil, kvBudgetForTesting: kvBudget)
    }

    /// A memory budget whose RAM-only tier is a private pool.
    static func privateBudget(totalBytes: UInt64 = 64 << 30) -> (MemoryOnlyCheckpointPool, GlobalKVCacheBudget) {
        let pool = MemoryOnlyCheckpointTierTests.pool()
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9, activationReserveBytes: 0,
            memorySnapshot: { .init(total: totalBytes, active: 0, cache: 0, systemAvailable: totalBytes) },
            memoryOnlyPool: pool)
        return (pool, budget)
    }

    /// Holds one entry in `pool` and checks it is gone after `release`.
    private func expectReleased(
        _ pool: MemoryOnlyCheckpointPool, _ release: () async throws -> Void
    ) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let tier = MemoryOnlyCheckpointTierTests.tier(fixture, pool: pool)
        defer { tier.close() }
        let marked = MemoryOnlyCheckpointTierTests.marked
        try #require(try await MemoryOnlyCheckpointTierTests.donate(tier, fixture, pool: pool, receipt: marked(1)))
        try await release()
        #expect(pool.snapshot.entries == 0 && pool.bytesInUse == 0)
        #expect(await MemoryOnlyCheckpointTierTests.stage(tier, fixture, receipt: marked(2)).disposition == .missAbsent)
    }

    @Test("an OS memory-pressure warning or critical releases the tier", arguments: [
        MemoryPressureLevel.warning, .critical,
    ])
    func pressure(level: MemoryPressureLevel) async throws {
        let (pool, budget) = Self.privateBudget()
        let loop = try Self.makeLoop(kvBudget: budget)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-only-pressure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        await loop.startMemoryProtection(
            markerURL: scratch.appendingPathComponent("oom-marker"),
            lastScanURL: scratch.appendingPathComponent("last-scan"), diagnosticReportsDirs: [])
        let monitor = try #require(await loop.memoryPressureMonitor)
        defer { monitor.cancel() }
        try await expectReleased(pool) { monitor.handle(level) }
    }

    @Test("a model load that needs room releases the tier first, and counts it as reclaimable")
    func loadGate() async throws {
        let (pool, budget) = Self.privateBudget()
        let loop = try Self.makeLoop(kvBudget: budget)
        try await expectReleased(pool) {
            let reclaimable = await loop.reclaimableMemoryBytes(from: [:], countingRetainedKVSegments: false)
            #expect(reclaimable >= pool.bytesInUse)
            await loop.releaseReclaimableMemoryForLoad()
        }
    }

    @Test("shutdown releases the tier")
    func shutdown() async throws {
        let (pool, budget) = Self.privateBudget()
        let loop = try Self.makeLoop(kvBudget: budget)
        try await expectReleased(pool) { await loop.unloadAllModelsForShutdown() }
    }

    @Test("a charge the tier covers releases its oldest entries and succeeds at once; a larger one keeps them")
    func refusedCharge() async throws {
        let (pool, budget) = Self.privateBudget(totalBytes: 16 << 30)
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let tier = MemoryOnlyCheckpointTier(
            config: .init(identity: fixture.identity, backendLayout: fixture.backendLayout, minEffectiveTokens: 256),
            kvBudget: budget, pool: pool)
        defer { tier.close() }
        #expect(try await MemoryOnlyCheckpointTierTests.donate(
            tier, fixture, pool: pool, receipt: MemoryOnlyCheckpointTierTests.marked(1)))
        let held = pool.bytesInUse
        let remaining = budget.processLedger.snapshot().remainingBytes
        #expect(held > 0)

        #expect(!(await budget.reserveBytes(requestID: "never-fits", bytes: remaining + held + (1 << 20))))
        #expect(pool.bytesInUse == held, "a release that can't make room isn't done")

        #expect(await budget.reserveBytes(requestID: "fits-without-tier", bytes: remaining + held / 2))
        #expect(pool.bytesInUse == 0 && pool.snapshot.evictions[.shortfall] == 1)
        await budget.release(requestID: "fits-without-tier")
    }

    @Test("the local server releases the tier on pressure, before a load and at shutdown")
    func standaloneServer() async throws {
        let (pool, budget) = Self.privateBudget()
        let server = StandaloneServer(config: .init(port: 0), models: [], kvBudgetForTesting: budget)
        try await server.start()
        let monitor = try #require(await server.memoryPressureMonitor)
        try await expectReleased(pool) { monitor.handle(.critical) }
        try await expectReleased(pool) { await server.releaseReclaimableMemoryForLoad() }
        try await expectReleased(pool) { await server.stop() }
    }
}
