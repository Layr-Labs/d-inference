// Copyright © 2026 Eigen Labs.
//
// T1-08 — graceful shutdown/restart ordering: refuse → drain → close.
//
// Before: run()'s cancellation handler closed the coordinator socket at once
// and only then reached the drain — which short-circuits under cancellation
// anyway — so the coordinator flushed every in-flight request as a 502
// "provider disconnected" (a served fault on the stable identity) while the
// generation tasks kept decoding into a finished router. The auto-update
// restart never sent a close frame at all (kickstart -k + exit), so the
// coordinator recorded a read_error disconnect.
//
// Live-isolated: a real ProviderLoop, a real CoordinatorClient over a real
// WebSocket to the in-process MockCoordinator, the production event consumer
// (`dispatchCoordinatorEvent`), fake in-flight tasks in place of engine work.

import Foundation
import Testing

@testable import ProviderCore

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

private struct RestartCommandFailed: Error {}

private func integrationHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)
}

private func makeLoop() async throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: integrationHardware(),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "shutdown-ordering-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    // The drain stamps the daemon-state file (`shutting_down`); keep that
    // off the operator's real ~/.darkbloom/daemon-state.json.
    let stateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("shutdown-ordering-\(UUID().uuidString).json")
    await loop.setDaemonStateFileForTesting(stateURL)
    return loop
}

private func makeClient(url: String, publicKey: String, state: ProviderState) -> CoordinatorClient {
    let cfg = CoordinatorClientConfig(
        url: url,
        hardware: integrationHardware(),
        models: [ModelInfo(
            id: "mlx-community/Qwen3-0.6B-8bit", modelType: "qwen3", quantization: "8bit",
            sizeBytes: 700_000_000, estimatedMemoryGb: 1.0)],
        backendName: "mlx-swift",
        heartbeatInterval: 60,
        publicKey: publicKey,
        privacyCapabilities: PrivacyCapabilities(
            textBackendInprocess: true, textProxyDisabled: true,
            pythonRuntimeLocked: false, dangerousModulesBlocked: false,
            sipEnabled: true, antiDebugEnabled: false,
            coreDumpsDisabled: false, envScrubbed: false)
    )
    return CoordinatorClient(config: cfg, stats: AtomicProviderStats(), state: state)
}

@Suite("Provider shutdown ordering (T1-08)", .serialized)
struct ProviderShutdownOrderingTests {

    /// The whole invariant in one run: while an in-flight request is still
    /// finishing the socket stays open, a routed request is bounced with the
    /// slot_state 503 (reroute, not first_chunk_timeout), and the goingAway
    /// close is sent only after the in-flight work completed. Pre-fix the
    /// close lands first (socketCloses == 1 while the work is still running).
    @Test("shutdown refuses new work, lets in-flight work finish, then closes the link")
    func refuseDrainThenClose() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try await makeLoop()
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
        let client = makeClient(
            url: baseURL.mockProviderWebSocketURL(), publicKey: providerKey, state: state)
        await loop.setCoordinatorClientForTesting(client)
        let (events, sendFn) = await client.start()
        let send = SendHandle(sendFn, chunkSender: client.chunkSender)
        // The production consumer, verbatim (`run()` spawns the same task).
        let consumer = Task {
            for await event in events {
                await loop.dispatchCoordinatorEvent(event, send: send)
            }
        }
        defer { consumer.cancel() }

        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)

        // In-flight work gated on the test (released after the assertions
        // below, so there is no wall-clock window to miss). Like the
        // production task, its terminal goes out (here: the flag) BEFORE the
        // defer-time `finishInflightRequest` releases the drain.
        let release = AsyncStream<Void>.makeStream()
        let finished = Flag()
        let work = Task {
            for await _ in release.stream { break }
            finished.set()
            await loop.finishInflightRequest(requestId: "req-drain-1")
        }
        await loop.installInflightRequestForTesting(requestId: "req-drain-1", task: work)

        let drain = Task { await loop.beginShutdownDrain(coordinator: client) }

        // Refusing + draining: the socket is still up and the work still running.
        let draining = try await mock.waitForSnapshot(timeout: .seconds(5)) { _ in state.refusingNewWork }
        #expect(draining != nil, "the drain never started")
        #expect(await loop.isShuttingDownForTesting())
        #expect(!finished.value)
        #expect(mock.snapshot().socketCloses == 0, "link closed before the drain finished")

        // A request routed during the drain is answered with the slot_state
        // 503 so the coordinator reroutes it, instead of dying unanswered.
        let chat = ChatCompletionRequest(
            model: "mlx-community/Qwen3-0.6B-8bit",
            messages: [.init(role: "user", content: "ping")],
            stream: true)
        try await mock.pushInferenceRequest(
            requestId: "req-during-drain",
            providerPublicKeyBase64: providerKey,
            chatRequestJSON: try JSONEncoder().encode(chat),
            firstContentBudgetMs: 60_000)
        let bounced = try await mock.waitForSnapshot(timeout: .seconds(3)) {
            $0.inferenceErrors.contains { $0.requestId == "req-during-drain" }
        }
        let bounce = try #require(
            bounced?.inferenceErrors.first { $0.requestId == "req-during-drain" },
            "request routed during the drain was not refused")
        #expect(bounce.statusCode == 503)
        #expect(bounce.failureCode == .capacity)
        #expect(mock.snapshot().socketCloses == 0)

        // Only now may the work finish; the close must follow it.
        release.continuation.yield(())
        release.continuation.finish()
        await drain.value
        #expect(finished.value, "the link was closed before the in-flight work completed")
        // A close FRAME with goingAway (1001) — the clean close the
        // coordinator records — not a transport drop (`read_error`).
        let closed = try await mock.waitForSnapshot(timeout: .seconds(2)) { !$0.closeCodes.isEmpty }
        #expect(closed?.closeCodes == [1001], "expected one goingAway close frame, got \(String(describing: closed?.closeCodes))")
        #expect(closed?.socketCloses == 1, "the link ended without a close frame")

        // shutdown() is permanent: no reconnect follows the close.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(mock.snapshot().registers.count == 1)
    }

    /// Past the drain bound the stragglers are cancelled, their terminals get
    /// a short flush window, and the link still closes cleanly afterwards.
    @Test("drain timeout force-cancels stragglers and still closes the link afterwards")
    func drainTimeoutForceCancelsThenCloses() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try await makeLoop()
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
        let client = makeClient(
            url: baseURL.mockProviderWebSocketURL(), publicKey: providerKey, state: state)
        await loop.setCoordinatorClientForTesting(client)
        let (events, _) = await client.start()
        let drainEvents = Task { for await _ in events {} }
        defer { drainEvents.cancel() }
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)

        // A "generation" that only ends when cancelled.
        let cancelled = Flag()
        let work = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.set()
            }
            await loop.finishInflightRequest(requestId: "req-straggler")
        }
        await loop.installInflightRequestForTesting(requestId: "req-straggler", task: work)

        let started = ContinuousClock.now
        await loop.beginShutdownDrain(coordinator: client, drainTimeout: .milliseconds(300))
        let elapsed = ContinuousClock.now - started
        #expect(cancelled.value, "straggler was not force-cancelled")
        // Bound 300 ms + 2 s terminal flush + 500 ms close frame; the
        // straggler alone would have taken 30 s. Generous for a loaded runner.
        #expect(elapsed < .seconds(15), "drain took \(elapsed)")
        let closed = try await mock.waitForSnapshot(timeout: .seconds(2)) { !$0.closeCodes.isEmpty }
        #expect(closed?.closeCodes == [1001], "expected one goingAway close frame, got \(String(describing: closed?.closeCodes))")
        #expect(closed?.socketCloses == 1)
    }

    /// The auto-update restart step closes the link with a goingAway frame
    /// BEFORE the process restart, and because the close is not a shutdown
    /// request the link recovers when the restart command fails (the
    /// controller's resumeServing path keeps the old binary serving).
    @Test("the update restart closes the link first, and a failed restart reconnects")
    func updateRestartClosesLinkBeforeRestart() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try await makeLoop()
        let providerKey = await loop.keyPair.publicKeyBase64
        let state = await loop.state
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

        let closedBeforeRestart = Flag()
        await #expect(throws: RestartCommandFailed.self) {
            try await loop.closeLinkThenRestart {
                // The restart command runs only after the goingAway close
                // frame went out (not merely after the socket ended).
                if try await mock.waitForSnapshot(timeout: .seconds(1), where: { $0.closeCodes == [1001] }) != nil {
                    closedBeforeRestart.set()
                }
                throw RestartCommandFailed()
            }
        }
        #expect(closedBeforeRestart.value, "restart ran before the link was closed with goingAway")
        #expect(mock.snapshot().socketCloses == 1)

        // Not a shutdown: the reconnect loop re-registers after its backoff.
        let reRegistered = try await mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.registers.count >= 2
        }
        #expect(reRegistered != nil, "link did not recover after the failed restart")
    }
}
