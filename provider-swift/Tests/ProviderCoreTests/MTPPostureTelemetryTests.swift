// Copyright © 2026 Eigen Labs.
//
// Producers for the v0.8.0 MTP + paged-pool telemetry fields.
//
// These fields were allowlisted in all three mirrors (Go, Swift, TS) ahead of
// any producer. An allowlisted field with no producer is dead weight, so what
// this suite defends is emission: that a real slot actually puts the values on
// the wire, that the three `backend` axes stay three separate keys, and that
// "enabled but inert" is nameable and named.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Fixtures

private final class PostureTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }

    /// Newest posture sample, or nil.
    var posture: TelemetryEvent? {
        events.last { $0.fields?["operation"]?.description == "engine_v2_slot_posture" }
    }
}

/// Engine stub reporting a paged pool that is partly occupied. `kvBytesInUse`
/// and `kvBytesBackendCapacity` are what a paged `EngineLoopV2` publishes from
/// `PagedKVPool.bytesInUse` / `.bytesCapacity`.
private final class PagedPoolStubEngine: CBv2Engine, @unchecked Sendable {
    private let inUse: Int
    private let poolBytes: Int

    init(kvBytesInUse: Int, poolBytes: Int) {
        self.inUse = kvBytesInUse
        self.poolBytes = poolBytes
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: inUse,
            kvBytesCapacity: poolBytes, kvBytesBackendCapacity: poolBytes,
            activeTokens: 0)
    }
    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

private func makePostureBridge(
    engine: any CBv2Engine,
    kvBackendKind: EngineV2KVBackendKind,
    telemetry: PostureTelemetrySink
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: "gemma-4-26b-qat-4bit",
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        eosTokenIds: [],
        kvBackendKind: kvBackendKind,
        emitTelemetry: telemetry.callback())
}

/// A drafter that loaded and activated — the load-time truth the provider had
/// been mistaking for "MTP is working".
private func activatedStatus() -> MTPActivationStatus {
    MTPActivationStatus
        .disabled(.configDisabled, configured: true)
        .activated(assistantBytes: 236 * 1024 * 1024)
}

private func field(_ event: TelemetryEvent?, _ key: String) -> String? {
    event?.fields?[key]?.description
}

// MARK: - Tests

@Suite("MTP + paged-pool posture telemetry")
struct MTPPostureTelemetryTests {

    // MARK: Enabled but inert

    @Test("paged slot with zero MTP rounds reports inert_kv_unsupported")
    func inertPagedSlotIsNamed() async {
        // The shape observed on a paged gemma-4 slot: the drafter loaded, the
        // engine reports MTP active, and every planned row is refused by the
        // storage-eligibility guard, so not one round runs.
        var metrics = CBv2MTPMetrics()
        metrics.active = true
        metrics.rounds = 0
        metrics.skippedRows = ["kv_unsupported": 128]

        let snapshot = ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: metrics)

        #expect(snapshot.configured)
        // A slot executing zero rounds is not active. Reporting it active is
        // what hid this state for the whole migration.
        #expect(!snapshot.active)
        #expect(snapshot.fallbackReason == .inertKVUnsupported)
        #expect(snapshot.fallbackReason?.rawValue == "inert_kv_unsupported")

        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 3 << 30, poolBytes: 12 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(snapshot)

        let event = telemetry.posture
        #expect(event != nil)
        #expect(field(event, "mtp_enabled") == "true")
        #expect(field(event, "mtp_active") == "false")
        #expect(field(event, "mtp_inactive_reason") == "inert_kv_unsupported")
        // Enabled-and-inert is a PAGED-slot state; the sample must say so or
        // the rollout dashboard cannot attribute it to the backend that
        // caused it.
        #expect(field(event, "kv_backend") == "paged")
        // Nothing was proposed, so the ratio is absent rather than 0.0 — a
        // zero would read as "the target rejects every draft".
        #expect(event?.fields?["mtp_acceptance_rate"] == nil)

        await bridge.shutdown()
    }

    @Test("inert is distinct from engine_inactive")
    func inertIsNotEngineInactive() {
        var inert = CBv2MTPMetrics()
        inert.active = true
        inert.rounds = 0
        inert.skippedRows = ["kv_unsupported": 4]
        #expect(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: inert)
                .fallbackReason == .inertKVUnsupported)

        // Engine says OFF: a different fact, and it keeps its own reason.
        var off = CBv2MTPMetrics()
        off.active = false
        off.rounds = 0
        off.skippedRows = ["kv_unsupported": 4]
        #expect(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: off)
                .fallbackReason == .engineInactive)

        // No engine metrics at all is also engine-inactive, not inert.
        #expect(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: nil)
                .fallbackReason == .engineInactive)
    }

    @Test("zero rounds without kv_unsupported skips is not inert")
    func idleSlotIsNotInert() {
        // Freshly built engine: nothing has been planned yet, so rounds and
        // skips are both zero. This is the state the post-build MTP teardown
        // gate reads, and it must NOT be mistaken for inert — doing so would
        // tear down and rebuild every MTP slot at load.
        var fresh = CBv2MTPMetrics()
        fresh.active = true
        fresh.rounds = 0
        fresh.skippedRows = [:]
        let snapshot = ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: fresh)
        #expect(snapshot.active)
        #expect(snapshot.fallbackReason == nil)

        // Skipped for an unrelated reason is also not inert.
        var otherSkip = CBv2MTPMetrics()
        otherSkip.active = true
        otherSkip.rounds = 0
        otherSkip.skippedRows = ["batch_gate": 9]
        #expect(ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: otherSkip).active)
    }

    @Test("a slot that ran rounds stays active even after kv_unsupported skips")
    func productiveSlotStaysActive() async {
        // Mixed traffic: some rows unsupported, but rounds DID run. Inert
        // means zero rounds, not "some rows were skipped".
        var metrics = CBv2MTPMetrics()
        metrics.active = true
        metrics.rounds = 40
        metrics.draftedTokens = 200
        metrics.acceptedTokens = 150
        metrics.skippedRows = ["kv_unsupported": 3]

        let snapshot = ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: metrics)
        #expect(snapshot.active)
        #expect(snapshot.fallbackReason == nil)

        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 0, poolBytes: 8 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(snapshot)

        let event = telemetry.posture
        #expect(field(event, "mtp_active") == "true")
        // Productively running, so there is no inactive reason to carry.
        #expect(event?.fields?["mtp_inactive_reason"] == nil)
        #expect(field(event, "mtp_acceptance_rate") == "0.75")

        await bridge.shutdown()
    }

    // MARK: The `backend` key split

    @Test("posture keeps engine identity and KV storage kind on separate keys")
    func backendAxesStaySeparate() async {
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 1 << 30, poolBytes: 4 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: nil))

        let event = telemetry.posture
        // `backend` is the engine executing inference — the majority meaning,
        // and the one that joins RegisterMessage.backend. It must NOT carry
        // the KV storage kind, which is what mis-bucketed every `group by
        // backend` dashboard before this split.
        #expect(field(event, "backend") == "engine_v2")
        #expect(field(event, "kv_backend") == "paged")

        await bridge.shutdown()
    }

    @Test("contiguous slots report kv_backend and omit pool utilization")
    func contiguousSlotHasNoPool() async {
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 1 << 30, poolBytes: 4 << 30),
            kvBackendKind: .contiguous,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: nil))

        let event = telemetry.posture
        #expect(field(event, "backend") == "engine_v2")
        #expect(field(event, "kv_backend") == "contiguous")
        // There is no pool on a contiguous slot. Absent, never 0.0.
        #expect(event?.fields?["pool_utilization"] == nil)

        await bridge.shutdown()
    }

    // MARK: Paged pool occupancy

    @Test("pool_utilization is occupied over total pool bytes")
    func poolUtilizationIsMeasured() async {
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 3 << 30, poolBytes: 12 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: nil))

        #expect(field(telemetry.posture, "pool_utilization") == "0.25")

        await bridge.shutdown()
    }

    @Test("unknown pool capacity omits utilization rather than reporting empty")
    func unknownPoolCapacityIsOmitted() async {
        // kvBytesBackendCapacity == 0 means UNKNOWN (test stubs, idle
        // point-update snapshots) and must never read as an empty pool.
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: InertStubEngine(kvBytesCapacity: 1 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: nil))

        let event = telemetry.posture
        #expect(event != nil)
        #expect(event?.fields?["pool_utilization"] == nil)

        await bridge.shutdown()
    }

    // MARK: The producer is actually wired

    @Test("every slot emits posture on the periodic sampler, MTP or not")
    func periodicSamplerEmitsForEverySlot() async throws {
        // The point of the ticket: these fields need a PRODUCER, and the
        // producer must be a recurring per-slot inventory rather than a
        // once-per-construction notification. Drive the real timer.
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 2 << 30, poolBytes: 8 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)

        // MTP never loaded on this slot. It must still report — `mtp_enabled:
        // false` is itself the observation that resolves a partial-MTP fleet,
        // and the paged-pool fields do not depend on MTP at all.
        await bridge.configureMTPStatus(
            .disabled(.configDisabled, configured: false),
            metricsInterval: .milliseconds(20))

        // Wait for the SECOND sample. The first is the opening snapshot emitted
        // synchronously by configureMTPStatus, which would satisfy a
        // first-event wait without the timer ever firing — this test is the one
        // that has to prove the recurring loop still runs.
        let postureCount = {
            telemetry.events.filter {
                $0.fields?["operation"]?.description == "engine_v2_slot_posture"
            }.count
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while postureCount() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(postureCount() >= 2, "the periodic sampler never produced a second posture event")

        let event = try #require(telemetry.posture, "periodic sampler produced no posture event")
        #expect(event.kind == .engineHealth)
        #expect(field(event, "component") == "engine")
        #expect(field(event, "model") == "gemma-4-26b-qat-4bit")
        #expect(field(event, "backend") == "engine_v2")
        #expect(field(event, "kv_backend") == "paged")
        #expect(field(event, "mtp_enabled") == "false")
        #expect(field(event, "mtp_active") == "false")
        #expect(field(event, "mtp_inactive_reason") == "config_disabled")
        #expect(field(event, "pool_utilization") == "0.25")

        await bridge.shutdown()
    }

    @Test("a slot torn down inside its first interval still reports exactly once")
    func slotShorterThanOneIntervalEmitsOnce() async throws {
        // The rollout-visibility case: a slot that fails post-build, crashes,
        // or is swapped out 40 s into a 60 s cadence. Sleeping first made
        // exactly those slots invisible. The interval here is far longer than
        // the test's lifetime, so the ONLY emission that can occur is the
        // opening one — and there must be precisely one, not zero and not a
        // duplicate from the loop's first iteration.
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 2 << 30, poolBytes: 8 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)

        await bridge.configureMTPStatus(
            .disabled(.assistantLoadFailed, configured: true),
            metricsInterval: .seconds(600))

        // No polling: the opening sample is ordered before configureMTPStatus
        // returns, so it is already on the sink.
        let postures = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_slot_posture"
        }
        #expect(postures.count == 1)
        let event = try #require(postures.first)
        #expect(field(event, "kv_backend") == "paged")
        #expect(field(event, "mtp_enabled") == "true")
        #expect(field(event, "mtp_active") == "false")
        #expect(field(event, "mtp_inactive_reason") == "assistant_load_failed")
        #expect(field(event, "pool_utilization") == "0.25")

        await bridge.shutdown()
        try await Task.sleep(for: .milliseconds(120))
        #expect(
            telemetry.events.filter {
                $0.fields?["operation"]?.description == "engine_v2_slot_posture"
            }.count == 1)
    }

    @Test("shutdown stops the sampler")
    func shutdownStopsSampler() async throws {
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 0, poolBytes: 1 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.configureMTPStatus(
            .disabled(.configDisabled, configured: false),
            metricsInterval: .milliseconds(20))

        // Two samples, not one: the first is the opening snapshot, so waiting
        // only for it would let this test pass against a sampler that never
        // ticked — and then "shutdown stopped it" would prove nothing.
        let postureCount = {
            telemetry.events.filter {
                $0.fields?["operation"]?.description == "engine_v2_slot_posture"
            }.count
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while postureCount() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(postureCount() >= 2, "sampler never ticked, so shutdown has nothing to stop")

        await bridge.shutdown()
        let afterShutdown = telemetry.events.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(telemetry.events.count == afterShutdown)
    }

    @Test("a zero interval disables the sampler entirely")
    func zeroIntervalDisablesSampler() async throws {
        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 0, poolBytes: 1 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.configureMTPStatus(
            .disabled(.configDisabled, configured: false), metricsInterval: .zero)

        try await Task.sleep(for: .milliseconds(120))
        #expect(telemetry.posture == nil)

        await bridge.shutdown()
    }

    // MARK: Allowlist

    @Test("every posture field survives the client-side allowlist filter")
    func postureFieldsAreAllowlisted() async {
        // TelemetryFieldFilter drops unknown keys SILENTLY. A producer whose
        // keys are not mirrored would emit nothing and look healthy.
        var metrics = CBv2MTPMetrics()
        metrics.active = true
        metrics.rounds = 12
        metrics.draftedTokens = 100
        metrics.acceptedTokens = 60

        let telemetry = PostureTelemetrySink()
        let bridge = makePostureBridge(
            engine: PagedPoolStubEngine(kvBytesInUse: 1 << 30, poolBytes: 2 << 30),
            kvBackendKind: .paged,
            telemetry: telemetry)
        await bridge.emitSlotPostureTelemetry(
            ProviderMTPStatusSnapshot(status: activatedStatus(), metrics: metrics))

        let fields = telemetry.posture?.fields ?? [:]
        for key in [
            "component", "operation", "backend", "kv_backend", "model",
            "mtp_enabled", "mtp_active", "mtp_acceptance_rate", "pool_utilization",
        ] {
            #expect(fields[key] != nil, "\(key) was dropped by the allowlist filter")
        }

        await bridge.shutdown()
    }
}
