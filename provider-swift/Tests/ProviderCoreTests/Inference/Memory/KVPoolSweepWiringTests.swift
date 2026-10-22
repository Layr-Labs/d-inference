// Copyright © 2026 Eigen Labs.
//
// Regression tests for the post-v0.7.5 MLX buffer-pool leak: the proactive
// KV-pool sweep (DAR-338) was driven by the legacy engine's liveness
// watchdog, and the v0.7.5 legacy-engine deletion removed that watchdog —
// the sweep's ONLY caller — leaving `proactiveReclaimSweep()` dead code.
// Under sustained serving nothing returned freed KV/activation buffers to
// the OS: MLX's cache grew toward the cache limit (0.75 × RAM at the time,
// ~380 GB allowed on a 512 GB Mac Studio — observed in the field as 377 GB
// of Metal allocation for a ~21 GB model) and only macOS memory pressure
// ever trimmed it.
//
// These tests pin the two periodic drivers that now exist:
//   * `ProviderLoop.capacityRefreshTick` — the fleet-serving path;
//   * `StandaloneServer`'s sweep task — the local-serving path.
// Both are asserted through `KVPoolReclaimer.sweepSignalCount`, which counts
// sweep signals BEFORE the threshold gate, so no multi-GiB real MLX pool is
// needed in the test process.

import Dispatch
import Foundation
import Testing

@testable import ProviderCore

@Suite("KV pool sweep wiring")
struct KVPoolSweepWiringTests {

    @Test("ProviderLoop.capacityRefreshTick signals the proactive pool sweep")
    func capacityTickSignalsSweep() async throws {
        // The tick also writes the daemon state file; redirect it through the
        // per-loop seam (NOT the process-global DARKBLOOM_STATE_FILE env var,
        // which races concurrently running suites).
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dstate-sweep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let loop = try makeSweepWiringLoop()
        await loop.setDaemonStateFileForTesting(stateURL)
        let reclaimer = await loop.kvBudgetForTesting().reclaimerForTesting
        #expect(await reclaimer.sweepSignalCount == 0)

        await loop.capacityRefreshTick()

        // `scheduleSweep` is fire-and-forget (it only spawns a task); poll
        // until the signal lands on the reclaimer actor.
        let signalled = await pollUntil { await reclaimer.sweepSignalCount > 0 }
        #expect(signalled, "the capacity tick must signal the proactive pool sweep")

        // The next capacity sample exports the reclaimer counters on the
        // heartbeat wire. This pins the operational telemetry path, not merely
        // the internal caller.
        await loop.updateAggregateCapacity()
        let capacity = try #require(await loop.backendCapacityForTesting())
        let telemetry = try #require(capacity.mlxCacheReclaimer)
        #expect(telemetry.sweepSignals > 0)
    }

    @Test("StandaloneServer.start spawns the periodic pool sweep")
    func standaloneStartSpawnsSweep() async throws {
        let server = StandaloneServer(config: StandaloneServerConfig(port: 0))
        await server.setKVSweepIntervalForTesting(.milliseconds(10))
        try await server.start()

        let signalled = await pollUntil { await server.debugKVSweepSignalCount() > 0 }
        await server.stop()
        #expect(signalled, "start() must spawn the periodic sweep task")

        // The sweep task dies with the server: after stop(), the signal
        // stream quiesces. Already-spawned fire-and-forget signal tasks may
        // still land right after stop, so poll until the count holds still
        // for 100ms — ten idle sweep cycles at this test's 10ms cadence, so
        // a still-alive task cannot fake it — rather than assuming a fixed
        // in-flight allowance.
        let quiesced = await pollUntil {
            let before = await server.debugKVSweepSignalCount()
            try? await taskSleep(.milliseconds(100))
            let after = await server.debugKVSweepSignalCount()
            return before == after
        }
        #expect(quiesced, "the sweep task must stop with the server")
    }

    @Test("the proactive sweep waits for an idle calibration or shape warmup session")
    func sweepWaitsForIdleCalibrationSession() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let reclaimer = await budget.reclaimerForTesting
        let (held, release) = AsyncStream<Void>.makeStream()
        let session = try #require(budget.serviceBudget.idleCalibration.startIfIdle(isIdle: { true }) {
            for await _ in held {}
        })
        // A flush is device work and would cancel the session mid-cell.
        budget.proactiveReclaimSweep()
        try? await taskSleep(.milliseconds(50))
        #expect(await reclaimer.sweepSignalCount == 0)
        release.finish()
        await session.value
        budget.proactiveReclaimSweep()
        #expect(await pollUntil { await reclaimer.sweepSignalCount == 1 })
    }

    @Test("a sweep signalled before a session starts does not flush when it runs after the start")
    func queuedSweepRechecksIdleCalibrationSession() async throws {
        let flushes = HeldFirstFlush()
        // A pool over the 2 GiB proactive threshold and no rate-limit window:
        // only the session check can stop the queued flush.
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 4 << 30, systemAvailable: 64 << 30) },
            clearCache: { flushes.flush() }, selfHealMinInterval: .zero)
        let reclaimer = await budget.reclaimerForTesting
        // The first flush holds the reclaimer, so the next signal queues behind it.
        budget.proactiveReclaimSweep()
        #expect(flushes.waitUntilFirstFlushStarted())
        budget.proactiveReclaimSweep()
        // As in the provider tick: the session starts after the sweep was signalled.
        let (held, release) = AsyncStream<Void>.makeStream()
        let session = try #require(budget.serviceBudget.idleCalibration.startIfIdle(isIdle: { true }) {
            for await _ in held {}
        })
        flushes.releaseFirstFlush()
        // The isolated count reads after the queued sweep's whole synchronous step.
        #expect(await pollUntil { await reclaimer.sweepSignalCount == 2 })
        #expect(flushes.count == 1)
        #expect(!session.isCancelled)
        #expect(budget.serviceBudget.idleCalibration.cancellationSource == nil)
        release.finish()
        await session.value
    }
}

/// Blocks the first flush on the reclaimer actor until released; later flushes return at once.
private final class HeldFirstFlush: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var flushes = 0

    var count: Int { lock.withLock { flushes } }

    func flush() {
        let first = lock.withLock { () -> Bool in
            flushes += 1
            return flushes == 1
        }
        guard first else { return }
        started.signal()
        release.wait()
    }

    func waitUntilFirstFlushStarted() -> Bool { started.wait(timeout: .now() + 10) == .success }
    func releaseFirstFlush() { release.signal() }
}

private func makeSweepWiringLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546
        ),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "kv-sweep-wiring-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, attestationSigner: nil)
}

/// Poll `condition` until true or the timeout elapses. Returns the final
/// verdict — polling, not sleeping a fixed amount, keeps the pass fast and
/// the failure bounded.
private func pollUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await taskSleep(.milliseconds(10))
    }
    return await condition()
}
