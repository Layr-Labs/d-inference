/// Drain awareness (provider half). While the provider refuses new work
/// (update drain / shutdown) its heartbeat reports `status: "draining"` and
/// its admission rejection carries `error_reason: "draining"`, so the
/// coordinator can stop routing to the box immediately instead of discovering
/// the drain one 503 bounce at a time — and without derating the
/// (provider, model) pair as if it were merely busy. Both wire strings are
/// mirrored in coordinator/protocol/messages.go.

import Foundation
import Testing
@testable import ProviderCore

// MARK: - Fixtures

private func drainTestHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546
    )
}

private func drainTestModel() -> ModelInfo {
    ModelInfo(id: "org/model-a", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
}

/// A real `ProviderLoop` (no coordinator connection, no model on disk): the
/// drain transitions and the admission gate are actor-isolated plain state.
private func makeDrainTestLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: drainTestHardware(),
        models: [drainTestModel()],
        config: ProviderConfig(
            provider: ProviderSettings(name: "drain-awareness-test", memoryReserveGB: 1),
            backend: BackendSettings(
                model: nil, enabledModels: ["org/model-a"], idleTimeoutMins: 0, preloadModels: []),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

/// A `CoordinatorClient` sharing `state` with the loop — exactly how the
/// production heartbeat reads the loop's refuse-new-work window.
private func makeHeartbeatClient(
    state: ProviderState,
    url: String = "ws://127.0.0.1:0/ignored",
    heartbeatInterval: TimeInterval = 0.5
) -> CoordinatorClient {
    CoordinatorClient(
        config: CoordinatorClientConfig(
            url: url,
            hardware: drainTestHardware(),
            models: [drainTestModel()],
            backendName: "mlx-swift",
            heartbeatInterval: heartbeatInterval,
            publicKey: "cHVibGlj"
        ),
        stats: AtomicProviderStats(),
        state: state,
        liveAPNsToken: { nil }
    )
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func heartbeatObject(_ client: CoordinatorClient) async throws -> [String: Any] {
    try jsonObject(Data(await client.buildHeartbeatJSON().utf8))
}

private final class OutboundCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var all: [OutboundMessage] { lock.withLock { messages } }
}

@Suite("Update drain awareness")
struct UpdateDrainAwarenessTests {

    // MARK: Heartbeat status

    @Test("heartbeat reports draining whenever the provider refuses new work, even mid-decode")
    func heartbeatReportsDrainingWhileRefusingNewWork() async throws {
        let state = ProviderState()
        let client = makeHeartbeatClient(state: state)

        state.inferenceActive = true
        #expect(try await heartbeatObject(client)["status"] as? String == "serving")

        // Drain outranks serving: in-flight decodes may still be running, but
        // the box must not be selected for new work.
        state.refusingNewWork = true
        #expect(try await heartbeatObject(client)["status"] as? String == "draining")

        // Non-draining heartbeats are unchanged.
        state.refusingNewWork = false
        state.inferenceActive = false
        #expect(try await heartbeatObject(client)["status"] as? String == "idle")
    }

    @Test("the encode-failure fallback heartbeat carries the computed status, not a literal idle")
    func encodeFailureFallbackKeepsComputedStatus() async throws {
        let state = ProviderState()
        let client = makeHeartbeatClient(state: state)
        // JSONEncoder's default non-conforming-float strategy is .throw, so a
        // NaN in the capacity payload forces the catch branch deterministically;
        // the fallback must be the minimal frame (no backend_capacity) but with
        // the status the drain/serving logic computed.
        state.backendCapacity = BackendCapacity(
            slots: [], gpuMemoryActiveGb: .nan, gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0,
            totalMemoryGb: 128)

        state.refusingNewWork = true
        var fallback = try await heartbeatObject(client)
        #expect(fallback["backend_capacity"] == nil)
        #expect(fallback["type"] as? String == "heartbeat")
        #expect(fallback["status"] as? String == "draining")

        state.refusingNewWork = false
        state.inferenceActive = true
        fallback = try await heartbeatObject(client)
        #expect(fallback["backend_capacity"] == nil)
        #expect(fallback["status"] as? String == "serving")

        state.inferenceActive = false
        fallback = try await heartbeatObject(client)
        #expect(fallback["backend_capacity"] == nil)
        #expect(fallback["status"] as? String == "idle")

        // A finite payload encodes normally again.
        state.backendCapacity = BackendCapacity(
            slots: [], gpuMemoryActiveGb: 1, gpuMemoryPeakGb: 1, gpuMemoryCacheGb: 0,
            totalMemoryGb: 128)
        let normal = try await heartbeatObject(client)
        #expect(normal["backend_capacity"] != nil)
        #expect(normal["status"] as? String == "idle")
    }

    @Test("beginUpdateDraining flips the phase and the shared flag the heartbeat reads")
    func beginUpdateDrainingFlipsHeartbeatStatus() async throws {
        let loop = try makeDrainTestLoop()
        let state = await loop.state
        let client = makeHeartbeatClient(state: state)

        #expect(try await heartbeatObject(client)["status"] as? String == "idle")
        #expect(await loop.updatePhase == .idle)

        await loop.beginUpdateDraining()

        #expect(await loop.updatePhase == .draining)
        #expect(state.refusingNewWork)
        #expect(try await heartbeatObject(client)["status"] as? String == "draining")
    }

    // MARK: Drain / un-drain announcements

    @Test("drain and un-drain transitions each push an event heartbeat the coordinator can act on immediately")
    func drainAndResumeAnnounceThemselvesOnTheWire() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let loop = try makeDrainTestLoop()
        let state = await loop.state
        // 60 s baseline: every heartbeat the mock sees is event-triggered.
        let client = makeHeartbeatClient(
            state: state, url: baseURL.mockProviderWebSocketURL(), heartbeatInterval: 60)
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }

        // `.connected` is announced only once the session is registered, i.e.
        // once event heartbeats are permitted on it.
        var connected = false
        for await event in events {
            if case .connected = event { connected = true; break }
        }
        try #require(connected)
        await loop.setCoordinatorClientForTesting(client)

        // Drain: the coordinator learns `draining` from an out-of-band
        // heartbeat, not from the next 503 bounce or baseline tick.
        await loop.beginUpdateDraining()
        let drained = try await mock.waitForSnapshot(timeout: .seconds(5)) { $0.heartbeats.count >= 1 }
        #expect(try #require(drained).heartbeats.last?.status == .draining)

        // A failed commit/restart resumes serving: the flag clears, the next
        // heartbeat reports idle again, and the un-drain is announced right
        // away so the coordinator's TTL-aged drain mark is lifted now rather
        // than on the next 5 s baseline tick.
        await loop.resumeServingAfterUpdate()
        #expect(await loop.updatePhase == .idle)
        #expect(!state.refusingNewWork)
        #expect(try await heartbeatObject(client)["status"] as? String == "idle")
        let resumed = try await mock.waitForSnapshot(timeout: .seconds(5)) { $0.heartbeats.count >= 2 }
        #expect(try #require(resumed).heartbeats.last?.status == .idle)
    }

    // MARK: Drain rejection reason

    @Test("the drain rejection frame carries error_reason=draining alongside the slot_state enrichment")
    func drainRejectionCarriesTypedReason() async throws {
        let loop = try makeDrainTestLoop()
        let captured = OutboundCapture()
        let send = SendHandle { captured.append($0) }

        // Not draining: the gate admits (returns false, sends nothing).
        let admitted = await loop.rejectIfDrainingForUpdate(
            requestId: "req-admit", send: send,
            lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer(callback: nil))
        #expect(admitted == false)
        #expect(captured.all.isEmpty)

        await loop.beginUpdateDraining()
        let rejected = await loop.rejectIfDrainingForUpdate(
            requestId: "req-drain", send: send,
            lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer(callback: nil))
        #expect(rejected)

        let message = try #require(captured.all.first)
        let frame = try jsonObject(try CoordinatorClientCodec.encodeOutboundMessage(message))
        #expect(frame["type"] as? String == "inference_error")
        #expect(frame["request_id"] as? String == "req-drain")
        #expect(frame["status_code"] as? Int == 503)
        #expect(frame["error_reason"] as? String == "draining")
        // Enrichment is unchanged: the typed reason maps onto the same
        // slot_state the bare 503 used to fall back to.
        #expect(frame["rejection_reason"] as? String == "slot_state")
    }

    // MARK: Protocol symmetry

    @Test("ProviderStatus.draining and InferenceErrorReason.draining round-trip with the Go wire strings")
    func drainingWireStringsRoundTrip() throws {
        #expect(ProviderStatus.draining.rawValue == "draining")
        #expect(ProviderStatus(rawValue: "draining") == .draining)
        #expect(InferenceErrorReason.draining.rawValue == "draining")
        #expect(InferenceErrorReason(rawValue: "draining") == .draining)
        #expect(CapacityRejectionReason(errorReason: .draining) == .slotState)

        let heartbeat = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
            status: .draining,
            stats: ProviderStats(),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal)))
        let heartbeatData = try ProviderProtocolCodec.encodeProviderMessage(heartbeat)
        #expect(try jsonObject(heartbeatData)["status"] as? String == "draining")
        guard case .heartbeat(let decodedHeartbeat) =
            try ProviderProtocolCodec.decodeProviderMessage(from: heartbeatData)
        else {
            Issue.record("expected a heartbeat")
            return
        }
        #expect(decodedHeartbeat.status == .draining)

        let error = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
            requestId: "r",
            failure: InferenceFailure(code: .capacity, statusCode: 503, errorReason: .draining)))
        let errorData = try ProviderProtocolCodec.encodeProviderMessage(error)
        #expect(try jsonObject(errorData)["error_reason"] as? String == "draining")
        guard case .inferenceError(let decodedError) =
            try ProviderProtocolCodec.decodeProviderMessage(from: errorData)
        else {
            Issue.record("expected an inference_error")
            return
        }
        #expect(decodedError.errorReason == .draining)
    }
}
