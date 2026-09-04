// Copyright © 2026 Eigen Labs.
//
// The shutdown drain keeps the socket up for the drain window, so the
// coordinator's warm-pool planner can still send `load_model` (and
// `prefetch_model`) to a shutting-down box. The refusal must carry a
// "draining" reason: the coordinator's load-failure classifier buckets on
// that word, and anything else is booked as a real warm-pool load failure
// with a memory backoff (`routing.load_model_rejects reason:other`).

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

@Suite("ProviderShutdownOrdering load_model during the drain", .serialized)
struct ProviderShutdownOrderingLoadModelTests {

    @Test("load_model and prefetch_model during the shutdown drain are refused as draining")
    func loadModelRefusedAsDraining() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/ignored",
                hardware: integrationHardware(),
                models: [],
                config: ProviderConfig(
                    provider: ProviderSettings(name: "load-model-drain-test", memoryReserveGB: 1),
                    backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
                    coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60))),
            purgeLegacyFiles: false, attestationSigner: nil)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("load-model-drain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: baseURL.mockProviderWebSocketURL(), hardware: integrationHardware(),
                models: [], backendName: "mlx-swift", heartbeatInterval: 60, publicKey: providerKey,
                privacyCapabilities: PrivacyCapabilities(
                    textBackendInprocess: true, textProxyDisabled: true,
                    pythonRuntimeLocked: false, dangerousModulesBlocked: false,
                    sipEnabled: true, antiDebugEnabled: false,
                    coreDumpsDisabled: false, envScrubbed: false)),
            stats: AtomicProviderStats(), state: state)
        await loop.setCoordinatorClientForTesting(client)
        let (events, sendFn) = await client.start()
        let send = SendHandle(sendFn, chunkSender: client.chunkSender)
        let consumer = Task {
            for await event in events {
                await loop.dispatchCoordinatorEvent(event, send: send)
            }
        }
        defer { consumer.cancel() }
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)

        // Hold the drain open with gated in-flight work.
        let release = AsyncStream<Void>.makeStream()
        let work = Task {
            for await _ in release.stream { break }
            await loop.finishInflightRequest(requestId: "req-hold")
        }
        await loop.installInflightRequestForTesting(requestId: "req-hold", task: work)
        let drain = Task { await loop.beginShutdownDrain(coordinator: client) }
        let draining = try await mock.waitForSnapshot(timeout: .seconds(5)) { _ in state.refusingNewWork }
        try #require(draining != nil, "the drain never started")

        try await mock.pushLoadModel(modelId: "mlx-community/Qwen3-0.6B-8bit")
        let refused = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.loadModelStatuses.contains { $0.modelId == "mlx-community/Qwen3-0.6B-8bit" && $0.status == .failed }
        }
        let status = try #require(
            refused?.loadModelStatuses.first { $0.modelId == "mlx-community/Qwen3-0.6B-8bit" },
            "load_model during the drain was not answered")
        #expect(status.error?.lowercased().contains("draining") == true,
                "reason '\(status.error ?? "")' is not classified as draining by the coordinator")

        try await mock.pushPrefetchModel(modelId: "mlx-community/Qwen3-0.6B-8bit")
        let prefetchRefused = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.prefetchModelStatuses.contains { $0.modelId == "mlx-community/Qwen3-0.6B-8bit" && $0.status == .failed }
        }
        let prefetch = try #require(
            prefetchRefused?.prefetchModelStatuses.first { $0.modelId == "mlx-community/Qwen3-0.6B-8bit" },
            "prefetch_model during the drain was not answered")
        #expect(prefetch.error?.lowercased().contains("draining") == true)

        release.continuation.yield(())
        release.continuation.finish()
        await drain.value
    }
}
