// Copyright © 2026 Eigen Labs.
//
// While a provider refuses new work (shutdown drain, update drain) its
// heartbeat must stop advertising routable slots: the coordinator prices an
// idle/running slot as a prime warm target, so for the whole drain window it
// kept selecting the box and every routed request bounced with the slot_state
// 503 — a reroute hop per request. The drain now folds every loaded slot to
// `reloading` (which the scheduler prices as not routable and the cache
// status still counts as loaded) and fires one event heartbeat at drain
// start, so routing stops within a heartbeat instead of after the close.
//
// Live-isolated: a real ProviderLoop and CoordinatorClient over a real
// WebSocket to the in-process MockCoordinator.

import Foundation
import Testing

@testable import ProviderCore

private func integrationHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)
}

private func makeLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: integrationHardware(),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "drain-posture-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func makeClient(url: String, publicKey: String, state: ProviderState) -> CoordinatorClient {
    CoordinatorClient(
        config: CoordinatorClientConfig(
            url: url, hardware: integrationHardware(),
            models: [ModelInfo(
                id: "mlx-community/Qwen3-0.6B-8bit", modelType: "qwen3", quantization: "8bit",
                sizeBytes: 700_000_000, estimatedMemoryGb: 1.0)],
            backendName: "mlx-swift", heartbeatInterval: 60, publicKey: publicKey,
            privacyCapabilities: PrivacyCapabilities(
                textBackendInprocess: true, textProxyDisabled: true,
                pythonRuntimeLocked: false, dangerousModulesBlocked: false,
                sipEnabled: true, antiDebugEnabled: false,
                coreDumpsDisabled: false, envScrubbed: false)),
        stats: AtomicProviderStats(), state: state)
}

private func idleSlot(_ model: String, state: String = "idle") -> BackendSlotCapacity {
    BackendSlotCapacity(
        model: model, state: state, numRunning: 0, numWaiting: 0,
        activeTokens: 0, maxTokensPotential: 32_000, maxConcurrency: 4,
        observedDecodeTps: 40)
}

private func servingCapacity(slots: [BackendSlotCapacity]) -> BackendCapacity {
    BackendCapacity(
        slots: slots, gpuMemoryActiveGb: 1, gpuMemoryPeakGb: 1, gpuMemoryCacheGb: 0,
        totalMemoryGb: 128, freeForLoadGb: 100)
}

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("drain-posture-\(UUID().uuidString).json")
}

@Suite("ProviderShutdownOrdering drain posture (routable capacity withdrawn)", .serialized)
struct ProviderShutdownOrderingDrainPostureTests {

    @Test("withdrawing admission folds every admitting slot to reloading and leaves faults alone")
    func foldIsPure() {
        let slots = [
            idleSlot("a", state: "idle"),
            idleSlot("b", state: "running"),
            idleSlot("c", state: ""),
            idleSlot("d", state: "crashed"),
            idleSlot("e", state: "reloading"),
        ]
        let folded = ProviderLoop.withdrawingAdmission(from: slots)
        #expect(folded.map(\.state) == ["reloading", "reloading", "reloading", "crashed", "reloading"])
        #expect(folded.map(\.model) == slots.map(\.model))
        // Everything else the coordinator prices rides along unchanged.
        #expect(folded[0].maxTokensPotential == 32_000)
        #expect(folded[0].observedDecodeTps == 40)
        #expect(ProviderLoop.withdrawingAdmission(from: []).isEmpty)
    }

    /// The whole invariant on the wire: an idle slot is advertised before
    /// the drain; the moment the drain starts an event heartbeat reports it
    /// non-routable, BEFORE the link closes; a rebuild during the drain
    /// (a request finishing) keeps it withdrawn.
    @Test("the shutdown drain heartbeats a non-routable posture before it closes the link")
    func shutdownDrainWithdrawsCapacity() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try makeLoop()
        let stateURL = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
        // The last capacity tick's payload: one idle, routable slot.
        state.backendCapacity = servingCapacity(slots: [idleSlot("mlx-community/Qwen3-0.6B-8bit")])
        let client = makeClient(
            url: baseURL.mockProviderWebSocketURL(), publicKey: providerKey, state: state)
        await loop.setCoordinatorClientForTesting(client)
        let (events, _) = await client.start()
        let drainEvents = Task { for await _ in events {} }
        defer { drainEvents.cancel() }
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)
        // The on-connect heartbeat advertised the idle slot.
        let advertised = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.heartbeats.contains { $0.backendCapacity?.slots.first?.state == "idle" }
        }
        try #require(advertised != nil, "the idle slot was never advertised")
        let heartbeatsBefore = mock.snapshot().heartbeats.count

        // In-flight work gated on the test, so the drain stays open until released.
        let release = AsyncStream<Void>.makeStream()
        let work = Task {
            for await _ in release.stream { break }
            await loop.finishInflightRequest(requestId: "req-posture")
        }
        await loop.installInflightRequestForTesting(requestId: "req-posture", task: work)
        let drain = Task { await loop.beginShutdownDrain(coordinator: client) }

        // Drain start: one event heartbeat, every slot non-routable, link still up.
        let withdrawn = try await mock.waitForSnapshot(timeout: .seconds(5)) { snap in
            snap.heartbeats.dropFirst(heartbeatsBefore).contains { hb in
                guard let slots = hb.backendCapacity?.slots, !slots.isEmpty else { return false }
                return slots.allSatisfy { $0.state == "reloading" }
            }
        }
        #expect(withdrawn != nil, "no non-routable heartbeat at drain start")
        #expect(mock.snapshot().closeCodes.isEmpty, "the link closed before the posture heartbeat")

        // A capacity rebuild during the drain (a request finishing) keeps the posture.
        release.continuation.yield(())
        release.continuation.finish()
        await drain.value
        let closed = try await mock.waitForSnapshot(timeout: .seconds(2)) { !$0.closeCodes.isEmpty }
        #expect(closed?.closeCodes == [1001])
        let afterDrain = mock.snapshot().heartbeats.dropFirst(heartbeatsBefore)
        #expect(!afterDrain.isEmpty)
        for hb in afterDrain {
            for slot in hb.backendCapacity?.slots ?? [] {
                #expect(slot.state == "reloading", "a routable slot leaked during the drain: \(slot.state)")
            }
        }
    }

    /// Same posture for the update drain, and admission visibly returns
    /// when a cycle aborts after draining (commit/restart failure).
    @Test("the update drain withdraws capacity and resumeServing advertises it again")
    func updateDrainWithdrawsAndResumeRestores() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try makeLoop()
        let stateURL = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
        state.backendCapacity = servingCapacity(slots: [idleSlot("mlx-community/Qwen3-0.6B-8bit")])
        let client = makeClient(
            url: baseURL.mockProviderWebSocketURL(), publicKey: providerKey, state: state)
        await loop.setCoordinatorClientForTesting(client)
        let (events, _) = await client.start()
        let drainEvents = Task { for await _ in events {} }
        defer {
            drainEvents.cancel()
            Task { await client.shutdown() }
        }
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)
        let heartbeatsBefore = mock.snapshot().heartbeats.count

        await loop.beginUpdateDrainingForTesting()
        let withdrawn = try await mock.waitForSnapshot(timeout: .seconds(5)) { snap in
            snap.heartbeats.dropFirst(heartbeatsBefore).contains { hb in
                guard let slots = hb.backendCapacity?.slots, !slots.isEmpty else { return false }
                return slots.allSatisfy { $0.state == "reloading" }
            }
        }
        #expect(withdrawn != nil, "no non-routable heartbeat at update-drain start")
        let heartbeatsAfterWithdraw = mock.snapshot().heartbeats.count

        await loop.resumeServingAfterUpdateForTesting()
        // The rebuild after resume has no engine slots (none installed), so
        // the seeded slot is gone rather than idle — what matters is that a
        // fresh heartbeat without the withdrawn posture reaches the coordinator.
        let restored = try await mock.waitForSnapshot(timeout: .seconds(5)) { snap in
            snap.heartbeats.dropFirst(heartbeatsAfterWithdraw).contains { hb in
                !(hb.backendCapacity?.slots ?? []).contains { $0.state == "reloading" }
            }
        }
        #expect(restored != nil, "admission was not re-advertised after resumeServing")
    }
}
