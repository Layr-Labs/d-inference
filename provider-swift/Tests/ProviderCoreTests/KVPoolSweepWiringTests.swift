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
        let sleeper = ManualSweepSleeper()
        let scheduled = SweepScheduleSpy()
        let server = StandaloneServer(config: StandaloneServerConfig(port: 0))
        await server.setKVSweepSchedulerForTesting(
            sleep: sleeper.sleep,
            didSchedule: scheduled.record)
        try await server.start()

        // start() must create the task and park it on its first production
        // cadence boundary. Releasing one manual tick invokes the real
        // proactiveReclaimSweep() call before the observer is signalled.
        await sleeper.waitForRequest()
        sleeper.resume()
        await scheduled.wait()
        #expect(scheduled.count == 1)

        // Stop while the task is parked on its next interval. The server joins
        // the cancelled task, so no elapsed-time quiescence guess is needed.
        await sleeper.waitForRequest()
        let stop = Task { await server.stop() }
        await sleeper.waitForCancellation()
        sleeper.resume()
        await stop.value
        #expect(scheduled.count == 1)

        // A stale manual tick after the joined shutdown has no consumer.
        sleeper.resume()
        #expect(scheduled.count == 1)
    }
}

private final class ManualSweepSleeper: @unchecked Sendable {
    private let requested = AsyncTestLatch()
    private let advance = AsyncTestLatch()
    private let cancelled = AsyncTestLatch()

    func sleep(_ duration: Duration) async throws {
        _ = duration
        requested.signal()
        try await withTaskCancellationHandler {
            await advance.wait()
            try Task.checkCancellation()
        } onCancel: {
            cancelled.signal()
        }
    }

    func waitForRequest() async {
        await requested.wait()
    }

    func resume() {
        advance.signal()
    }

    func waitForCancellation() async {
        await cancelled.wait()
    }
}

private final class SweepScheduleSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let recorded = AsyncTestLatch()
    private var _count = 0

    var count: Int {
        lock.withLock { _count }
    }

    func record() {
        lock.withLock { _count += 1 }
        recorded.signal()
    }

    func wait() async {
        await recorded.wait()
    }
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
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
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
