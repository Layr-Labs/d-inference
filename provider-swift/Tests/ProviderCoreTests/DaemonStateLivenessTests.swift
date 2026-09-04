// Copyright © 2026 Eigen Labs.
//
// T1-06 — the watchdog liveness stamp must not depend on engine-actor
// availability. `capacityRefreshTick` awaits every bridge (capacity summary,
// wedge recovery) before it writes the daemon-state file; a bridge stalled in
// synchronous engine work therefore froze `written_at`, and after 90 s plus
// the watchdog grace the crash-recovery watchdog kickstarted a daemon that
// was still serving on its other slots. The liveness stamp now runs on its
// own task at the poll cadence and only touches the loop actor (cached
// postures, no bridge hop).
//
// Live-isolated: a real ProviderLoop, a real EngineV2Bridge over a scripted
// in-process engine whose `capacity()` blocks the bridge actor on demand, the
// real state-file writer redirected to a temp path. No weights.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

/// Engine whose `capacity()` blocks on demand — the shape of a bridge wedged
/// in synchronous Metal/MLX work. Non-blocking until `block()` so the slot
/// can be installed first; `release()` lets the parked tick finish.
private final class BlockingCapacityEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var blocking = false
    private let gate = DispatchSemaphore(value: 0)
    private var _blockedCalls = 0

    var blockedCalls: Int { lock.withLock { _blockedCalls } }

    func block() { lock.withLock { blocking = true } }
    func release() {
        let waiters: Int = lock.withLock {
            blocking = false
            let n = _blockedCalls
            _blockedCalls = 0
            return n
        }
        for _ in 0..<max(1, waiters) { gate.signal() }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        let shouldBlock: Bool = lock.withLock {
            if blocking { _blockedCalls += 1 }
            return blocking
        }
        if shouldBlock { gate.wait() }
        return CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 1 << 30, activeTokens: 0)
    }
    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

private final class LivenessStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct LivenessStubProcessorError: Error {}

private struct LivenessStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw LivenessStubProcessorError()
    }
}

private func makeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/daemon-liveness-stub"),
            model: LivenessStubLanguageModel(),
            processor: LivenessStubProcessor(),
            tokenizer: StubBridgeTokenizer()
        ))
}

private func makeLivenessLoop() throws -> ProviderLoop {
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
            provider: ProviderSettings(name: "daemon-state-liveness-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            // heartbeat 2 s → capacity poll = 2/2 = 1 s (UInt64 division).
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 2)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("daemon-liveness-\(UUID().uuidString).json")
}

@Suite("Daemon-state liveness stamp (T1-06)", .serialized)
struct DaemonStateLivenessTests {

    /// Pre-fix: the monitor writes once at start, then its first tick parks
    /// on the blocked bridge forever and `written_at` never moves again —
    /// exactly one distinct value is ever observed. Post-fix: the liveness
    /// task keeps stamping every poll interval while the tick is parked.
    @Test("written_at keeps advancing while the capacity tick is parked on a blocked bridge")
    func livenessAdvancesWhileTickIsBlocked() async throws {
        let url = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let loop = try makeLivenessLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setDaemonStateFileForTesting(url)

        let engine = BlockingCapacityEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "test/blocked-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            eosTokenIds: [])
        await runtime.register(modelId: "test/blocked-model", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "test/blocked-model",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: bridge)
        defer { engine.release() }

        // Wedge the bridge BEFORE the monitor starts so its very first tick
        // parks (the capacity summary hops to the bridge, which blocks in
        // `engine.capacity()`).
        engine.block()
        await loop.startCapacityRefreshMonitor()
        defer { Task { await loop.stopCapacityRefreshMonitorForTesting() } }

        // Observe the file over ~3.5 poll intervals.
        var observed: [Double] = []
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(3500))
        while ContinuousClock.now < deadline {
            if let state = DaemonStateFile.read(from: url),
               observed.last != state.writtenAt {
                observed.append(state.writtenAt)
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        // The tick really is parked: the engine saw the blocked call.
        #expect(engine.blockedCalls >= 1, "the capacity tick never reached the blocked bridge")
        // ≥3 distinct, strictly increasing stamps: the monitor's initial write
        // plus at least two liveness refreshes taken while the tick was parked.
        #expect(observed.count >= 3, "written_at froze: \(observed)")
        #expect(observed == observed.sorted(), "written_at regressed: \(observed)")
        for pair in zip(observed, observed.dropFirst()) {
            #expect(pair.1 > pair.0)
        }

        // What the watchdog reads: a fresh record attributable to this live
        // process ⇒ active.
        let latest = try #require(DaemonStateFile.read(from: url))
        #expect(WatchdogProbe.providerActive(
            processRunning: true, daemonState: latest, now: Date().timeIntervalSince1970))
        // The payload is the cached last-good snapshot, not a half-built one.
        #expect(latest.pid == getpid())

        engine.release()
    }

    /// The monitor's teardown cancels the liveness task too — no stamp is
    /// written after the loop stops refreshing.
    @Test("stopping the monitor stops the liveness stamp")
    func stoppingMonitorStopsLiveness() async throws {
        let url = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let loop = try makeLivenessLoop()
        await loop.setDaemonStateFileForTesting(url)
        await loop.startCapacityRefreshMonitor()
        try await Task.sleep(for: .milliseconds(1300))
        await loop.stopCapacityRefreshMonitorForTesting()
        let stopped = try #require(DaemonStateFile.read(from: url)).writtenAt
        try await Task.sleep(for: .milliseconds(1300))
        #expect(DaemonStateFile.read(from: url)?.writtenAt == stopped)
    }
}
