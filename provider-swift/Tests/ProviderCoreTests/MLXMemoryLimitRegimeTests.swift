// Copyright © 2026 Eigen Labs.
//
// MLX active-over-limit regime detection (T13-05). Above `memoryLimit`,
// MLX's `eval_impl` commits every open stream and waits for one task after
// EVERY primitive (transforms.cpp) — a silent per-primitive serialization
// that turns a ~1,760-dispatch decode step into ~1,760 GPU round-trips and
// looks exactly like a wedged slot. Nothing logged, counted or exported it.
// The pure transition function is unit-tested; the loop-level case drives
// the real `capacityRefreshTick` sampler against real MLX counters with the
// limit injected through the test seam (no process-global mutation).

import Foundation
import MLX
import Testing

@testable import ProviderCore

@Suite("MLXMemoryLimitRegime.transition")
struct MLXMemoryLimitRegimeTransitionTests {

    @Test("enter above the limit, exit only below the hysteresis band, nothing in between")
    func hysteresis() {
        let limit = 1_000
        // Below the limit, not over: nothing.
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 999, limitBytes: limit, wasOver: false) == .none)
        // At the limit is not over (the engine's predicate is strict `>`).
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 1_000, limitBytes: limit, wasOver: false) == .none)
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 1_001, limitBytes: limit, wasOver: false) == .enter)
        // Once over, hovering just under the limit does NOT exit (would flap
        // one event per tick): exit needs active < 0.95 × limit.
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 1_001, limitBytes: limit, wasOver: true) == .none)
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 960, limitBytes: limit, wasOver: true) == .none)
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 950, limitBytes: limit, wasOver: true) == .none)
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 949, limitBytes: limit, wasOver: true) == .exit)
    }

    @Test("no configured limit: never enters; a stale over-state exits")
    func unknownLimit() {
        #expect(MLXMemoryLimitRegime.transition(activeBytes: Int.max, limitBytes: nil, wasOver: false) == .none)
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 1, limitBytes: 0, wasOver: false) == .none)
        #expect(MLXMemoryLimitRegime.transition(activeBytes: 1, limitBytes: nil, wasOver: true) == .exit)
    }
}

private func makeRegimeLoop() throws -> ProviderLoop {
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
            provider: ProviderSettings(name: "mlx-limit-regime-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private final class RegimeTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }
}

@Suite("ProviderLoop MLX over-limit sampler (live-isolated: real MLX counters)")
struct ProviderLoopMLXMemoryLimitRegimeTests {

    @Test("enter WARN + engine_health event once, ticks counted while over, exit INFO once, never per tick")
    func transitionsAreEdgeTriggeredAndCounted() async throws {
        let loop = try makeRegimeLoop()
        let sink = RegimeTelemetrySink()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                emitTelemetry: sink.callback(),
                makeEngine: { _, _ in throw CancellationError() }))
        // Hold a real MLX allocation so `Memory.activeMemory` is provably
        // above a 1-byte limit, whatever else is resident in the process.
        let held = MLXArray.zeros([256, 1024], dtype: .float32)
        eval(held)
        #expect(MLX.Memory.activeMemory > 1)

        // No limit configured (guard never ran in this process, or the seam
        // is nil): the sampler never enters the regime.
        await loop.setMLXMemoryLimitBytesForTesting(nil)
        await loop.sampleMLXMemoryLimitRegime()
        #expect(await loop.mlxOverLimitStateForTesting() == (over: false, ticks: 0))

        // Limit below active: ENTER on the first tick, counted; the second
        // tick counts again but emits nothing new.
        await loop.setMLXMemoryLimitBytesForTesting(1)
        await loop.sampleMLXMemoryLimitRegime()
        #expect(await loop.mlxOverLimitStateForTesting() == (over: true, ticks: 1))
        await loop.sampleMLXMemoryLimitRegime()
        #expect(await loop.mlxOverLimitStateForTesting() == (over: true, ticks: 2))
        let entered = sink.events.filter {
            $0.fields?["operation"]?.description == "mlx_memory_limit_exceeded"
        }
        #expect(entered.count == 1)
        #expect(entered.first?.kind == .engineHealth)
        #expect(entered.first?.severity == .warn)
        #expect(entered.first?.fields?["backend"]?.description == "engine_v2")
        let active = Int64(entered.first?.fields?["mlx_active_bytes"]?.description ?? "")
        #expect((active ?? 0) > 1, "mlx_active_bytes must ride the enter event")

        // Limit far above active: EXIT once; a further tick is quiet.
        await loop.setMLXMemoryLimitBytesForTesting(Int.max)
        await loop.sampleMLXMemoryLimitRegime()
        #expect(await loop.mlxOverLimitStateForTesting() == (over: false, ticks: 2))
        await loop.sampleMLXMemoryLimitRegime()
        #expect(await loop.mlxOverLimitStateForTesting() == (over: false, ticks: 2))
        let recovered = sink.events.filter {
            $0.fields?["operation"]?.description == "mlx_memory_limit_recovered"
        }
        #expect(recovered.count == 1)
        #expect(recovered.first?.severity == .info)
        #expect(sink.events.count == 2)
        withExtendedLifetime(held) {}
    }
}
