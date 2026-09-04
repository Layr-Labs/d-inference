// Copyright © 2026 Eigen Labs.
//
// The real cancellation path of `ProviderLoop.run()` (step 5 + teardown,
// `serveCoordinatorEvents`): cancelling the run task must NOT close the
// socket at once — the pre-fix `onCancel` did, and the coordinator flushed
// every in-flight request as a 502 while generation kept decoding into a
// finished router. It must start the drain in a non-cancelled task, keep the
// consumer answering (a routed request bounces with the slot_state 503), send
// the goingAway close only once the in-flight work finished, and return.
//
// Live-isolated: a real ProviderLoop, a real CoordinatorClient over a real
// WebSocket to the in-process MockCoordinator, the production consumer.

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
            provider: ProviderSettings(name: "run-path-test", memoryReserveGB: 1),
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

@Suite("ProviderShutdownOrdering run() cancellation path", .serialized)
struct ProviderShutdownOrderingRunPathTests {

    @Test("cancelling run() refuses, drains, then closes with goingAway and returns")
    func cancellationDrainsThenCloses() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try makeLoop()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-path-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
        let client = makeClient(
            url: baseURL.mockProviderWebSocketURL(), publicKey: providerKey, state: state)
        await loop.setCoordinatorClientForTesting(client)
        let (events, sendFn) = await client.start()
        let send = SendHandle(sendFn, chunkSender: client.chunkSender)

        // The production path from step 5 on, as a cancellable task.
        let serve = Task {
            await loop.serveCoordinatorEvents(coordinator: client, events: events, send: send)
        }
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)

        // In-flight work gated on the test.
        let release = AsyncStream<Void>.makeStream()
        let finished = Flag()
        let work = Task {
            for await _ in release.stream { break }
            finished.set()
            await loop.finishInflightRequest(requestId: "req-run-path")
        }
        await loop.installInflightRequestForTesting(requestId: "req-run-path", task: work)

        // Cancel run(): the drain begins, the socket stays open.
        serve.cancel()
        let draining = try await mock.waitForSnapshot(timeout: .seconds(5)) { _ in
            state.refusingNewWork
        }
        #expect(draining != nil, "the drain never started after cancellation")
        #expect(await loop.isShuttingDownForTesting())
        #expect(GracefulShutdownProgress.drainStarted)
        #expect(mock.snapshot().closeCodes.isEmpty, "the link closed before the drain")
        #expect(mock.snapshot().socketCloses == 0, "the link ended before the drain")
        #expect(!finished.value)

        // The consumer is still answering: a routed request bounces 503.
        let chat = ChatCompletionRequest(
            model: "mlx-community/Qwen3-0.6B-8bit",
            messages: [.init(role: "user", content: "ping")],
            stream: true)
        try await mock.pushInferenceRequest(
            requestId: "req-during-run-drain",
            providerPublicKeyBase64: providerKey,
            chatRequestJSON: try JSONEncoder().encode(chat),
            firstContentBudgetMs: 60_000)
        let bounced = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.inferenceErrors.contains { $0.requestId == "req-during-run-drain" }
        }
        let bounce = try #require(
            bounced?.inferenceErrors.first { $0.requestId == "req-during-run-drain" },
            "request routed during the drain was not refused")
        #expect(bounce.statusCode == 503)
        #expect(mock.snapshot().socketCloses == 0)

        // Let the work finish: the close follows, and run() returns.
        release.continuation.yield(())
        release.continuation.finish()
        await serve.value
        #expect(finished.value)
        let closed = try await mock.waitForSnapshot(timeout: .seconds(2)) { !$0.closeCodes.isEmpty }
        #expect(closed?.closeCodes == [1001], "expected one goingAway close frame, got \(String(describing: closed?.closeCodes))")
        #expect(closed?.socketCloses == 1)
        // shutdown() is permanent: no reconnect follows the close.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(mock.snapshot().registers.count == 1)
    }
}
