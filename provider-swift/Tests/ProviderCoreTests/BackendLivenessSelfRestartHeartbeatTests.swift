import Testing

@testable import ProviderCore

/// Heartbeat correctness during a liveness self-restart reload.
///
/// Regression for the recovery bug: `selfRestartForRecovery` calls
/// `loadModel`, which first runs `stopCurrentEngine` — that nils the engine and
/// clears the live `modelId` to "" BEFORE `loadModel` re-sets it. During that
/// window a heartbeat used to report a slot for `model:""` (state `reloading`).
/// The coordinator then no longer saw a `reloading` slot for the REAL model, so
/// it could treat this provider as a cold/unknown candidate for that model,
/// route to it, and hit a nil engine → "No model loaded" 500s.
///
/// The invariant: while a self-restart is in progress the slot must keep
/// advertising the REAL model id with a NOT-servable state, so the coordinator
/// deroutes the model for the whole reload window.
@Suite("Backend liveness self-restart heartbeat")
struct BackendLivenessSelfRestartHeartbeatTests {

    @Test("during a self-restart the slot keeps the REAL model id with a not-servable (reloading) state")
    func selfRestartReportsRealModelReloadingNotEmpty() async {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4, defaultMaxTokens: 4096)
        let realModel = "mlx-community/Qwen3.5-Coder-30B"

        // Reproduce the exact mid-restart window: `selfRestartForRecovery`
        // captured the real id and set the recovery flag, then
        // `loadModel` → `stopCurrentEngine` cleared the live `modelId` to "" and
        // nil'd the engine before re-setting it.
        await scheduler._enterRecoveryReloadWindowForTest(realModelId: realModel)

        // Precondition: we are genuinely IN the window — the live `modelId` is the
        // transient "" that `stopCurrentEngine` leaves behind. This is the exact
        // `model:""` state the pre-fix heartbeat would have advertised.
        let live = await scheduler.capacity()
        #expect(live.model == "", "test must reproduce the cleared-modelId reload window")

        let cap = await scheduler.backendCapacity()
        #expect(cap.slots.count == 1)
        let slot = cap.slots[0]

        // The fix: the heartbeat advertises the REAL model id, not model:"".
        #expect(
            slot.model == realModel,
            "during a self-restart the slot must advertise the real model id, not the transient empty id")
        #expect(!slot.model.isEmpty, "must never advertise model:\"\" during a reload")

        // ...and a NOT-servable state so the coordinator deroutes (never idle/running).
        #expect(
            slot.state == "reloading",
            "self-restart slot must report reloading (not-servable) for the whole window")
        #expect(
            slot.state != "idle" && slot.state != "running",
            "self-restart slot must never look servable")
    }

    @Test("not reloading: the slot reports the live model id and a servable state (no normal-path regression)")
    func steadyStateReportsLiveModel() async {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4, defaultMaxTokens: 4096)
        await scheduler._setModelIdForTest("some-model")

        let cap = await scheduler.backendCapacity()
        #expect(cap.slots.count == 1)
        // Outside a recovery restart the override is inert: the heartbeat reports
        // the live capacity model and the normal healthy/idle state.
        #expect(cap.slots[0].model == "some-model")
        #expect(cap.slots[0].state == "idle")
    }

    @Test("heartbeatSlotModel override is gated on the recovery flag (pure unit)")
    func heartbeatSlotModelOnlyOverridesDuringRecovery() async {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4, defaultMaxTokens: 4096)

        // Not reloading: pass through the live capacity model unchanged, even
        // when it is the transient "".
        var reported = await scheduler.heartbeatSlotModel(capacityModel: "")
        #expect(reported == "", "no override outside a recovery restart")
        reported = await scheduler.heartbeatSlotModel(capacityModel: "live-model")
        #expect(reported == "live-model", "no override outside a recovery restart")

        // In the recovery window the captured real id replaces the cleared "".
        await scheduler._enterRecoveryReloadWindowForTest(realModelId: "real-model")
        reported = await scheduler.heartbeatSlotModel(capacityModel: "")
        #expect(reported == "real-model", "override the transient empty modelId during a recovery restart")
    }
}
