/// ProviderLoop -- wedge self-recovery for v2 slots (v0.7.5 §1.10).
///
/// Port of the legacy `BatchScheduler+Liveness.selfRestartForRecovery`
/// (wedge verdict → full engine reload) onto the one-engine slot shape.
/// The v2 engine detects wedges (`WedgeMonitor` + `stepsExecuted` flatline
/// → heartbeat state "crashed") but a wedged CBv2 step loop cannot heal
/// itself; this driver HEALS by rebuilding the engine over the RETAINED
/// container — the weights stay resident, so recovery costs an engine
/// construction, not a multi-minute weight reload (much cheaper than the
/// legacy full `loadModel` restart).
///
/// State machine, driven from the capacity-refresh tick (heartbeat/2
/// cadence — the same place the wedge verdict already surfaces via
/// `updateAggregateCapacity` → `backendSlotCapacity`):
///
///   serving ──confirmed wedge (≥120s stall + step flatline)──▶ recovering
///     recovering: telemetry `engine_v2_self_restart` (ERROR)
///                 → old bridge marked "reloading" (heartbeat honesty)
///                 → drain: cancel pumps + bounded engine drain
///                 → rebuild engine+bridge over the SAME container with the
///                   slot's CURRENT grant (no re-slice) via the existing
///                   factory path (re-registers in `EngineV2Runtime`)
///                 → swap the ModelSlot's bridge → serving
///     recovering ──rebuild throws──▶ unload (fail loud: slot gone, the
///                 coordinator's heartbeat view drops it and routes around)
///   serving ──second confirmed wedge INSIDE the 120s cooldown──▶ unload
///                 (legacy `livenessRestartCooldown` semantic: never
///                 thrash rebuilds; requests 503 / deroute instead)
///
/// Serialization: the drain→rebuild→swap stretch holds the RE-SLICE GATE
/// (grants are read + re-granted across suspension points — a concurrent
/// load's shrink or an unload's regrow must never interleave, or the
/// rebuilt engine would carry a stale grant and Σ(grants) ≤ budget could
/// break). Eviction/idle-unload of the recovering slot is prevented by a
/// synthetic in-flight pin in `requestToModel` (the same signal every
/// eviction filter and the idle monitor already honor); explicit unloads
/// (retirement, shutdown) win by design — every suspension point re-checks
/// slot identity and aborts the swap if the slot vanished or was replaced.
///
/// Config/env parity with legacy: NONE — the legacy watchdog had no
/// env/config gate (always on, 120s wedge threshold from the pending
/// timeout, 120s restart cooldown); this port keeps all three semantics
/// and adds no new knobs.

import Foundation
import MLX
#if canImport(os)
import os
#endif

extension ProviderLoop {

    /// Minimum spacing between recovery attempts per model — the legacy
    /// `livenessRestartCooldown`. A second confirmed wedge inside this
    /// window unloads the slot instead of rebuilding again.
    internal static let engineV2RecoveryCooldown: Duration = .seconds(120)

    /// One liveness pass over every live v2 slot. Called from the
    /// capacity-refresh tick; `now` is injectable so tests can drive the
    /// 120s thresholds without waiting.
    internal func recoverWedgedEngineV2Slots(now: ContinuousClock.Instant = .now) async {
        guard hasEngineV2Slots, !isShuttingDown else { return }
        for modelId in modelSlots.keys.sorted() {
            await recoverEngineV2SlotIfWedged(modelId: modelId, now: now)
        }
    }

    /// Check one slot's confirmed-wedge verdict and run the recovery state
    /// machine for it. See the file header for the states.
    internal func recoverEngineV2SlotIfWedged(
        modelId: String, now: ContinuousClock.Instant
    ) async {
        guard let slot = modelSlots[modelId],
            !modelsUnloading.contains(modelId),
            !modelsLoading.contains(modelId)
        else { return }
        let bridge = slot.engineV2

        guard await bridge.confirmedWedgeForRecovery(now: now) else { return }
        // Re-validate after the verdict's suspension: an unload/reload may
        // have swapped the slot while we awaited the bridge actor.
        guard modelSlots[modelId]?.engineV2 === bridge,
            !modelsUnloading.contains(modelId),
            !modelsLoading.contains(modelId),
            !isShuttingDown
        else { return }

        // Cooldown: a second confirmed wedge within 120s of the last
        // recovery ATTEMPT means the rebuild did not stick — stop
        // thrashing and fail loud: unload the slot (heartbeats drop it,
        // the coordinator routes around; stray requests 503 through the
        // load path until a later lazy reload gets a fresh chance).
        if let last = engineV2LastRecoveryAt[modelId],
            now - last < Self.engineV2RecoveryCooldown {
            logger.error(
                "engine_v2 liveness: \(modelId) wedged again inside the recovery cooldown — unloading (fail loud)")
            await bridge.emitSelfRestartTelemetry(
                operation: "engine_v2_self_restart_cooldown_unload",
                severity: .error,
                message: "engine_v2: wedged again inside the recovery cooldown — unloading",
                now: now)
            recordModelLoadError(
                model: modelId,
                message: "engine wedged twice within \(Self.engineV2RecoveryCooldown) — slot unloaded")
            await unloadModel(modelId)
            return
        }
        engineV2LastRecoveryAt[modelId] = now

        // Pin the slot as in-flight for the whole recovery so the idle
        // monitor and every eviction filter (they all key off
        // `requestToModel`) leave it alone mid-swap.
        let pinId = "engine-v2-recovery:\(modelId)"
        requestToModel[pinId] = modelId
        defer { requestToModel.removeValue(forKey: pinId) }

        logger.error(
            "engine_v2 liveness: confirmed wedge on \(modelId) — rebuilding the engine over the retained container")
        await bridge.emitSelfRestartTelemetry(
            operation: "engine_v2_self_restart",
            severity: .error,
            message: "engine_v2: confirmed step wedge — self-restarting engine to recover",
            now: now)

        // Grant mutations ahead: serialize against loads' shrink→build→
        // install stretches and unloads' regrows.
        await acquireResliceGate()
        guard modelSlots[modelId]?.engineV2 === bridge, !isShuttingDown else {
            // The slot vanished / was replaced while we waited for the
            // gate (explicit unload or retirement won the race) — nothing
            // left to recover. (`beginRecoveryReload` has not run yet, so
            // no reloading flag needs clearing.)
            releaseResliceGate()
            return
        }

        // Heartbeats report "reloading" from here until the swap (the old
        // bridge stays registered in the runtime for exactly that reason).
        await bridge.beginRecoveryReload()

        // The recovered engine keeps the slot's CURRENT grant — recovery
        // is not a re-slice; co-resident slots' grants are untouched and
        // Σ(grants) ≤ fleet budget is preserved by construction.
        let grant = await bridge.engineKVBytesCapacity()

        // Drain: cancel the bridge's pump tasks (in-flight requests get
        // their teardown terminal + shared-KV release) and drain the
        // engine — BOUNDED by the engine's shutdown timeout (a wedged
        // queue force-finishes streams instead of hanging forever).
        await bridge.shutdown()
        MLX.Memory.clearCache()

        let rebuildStartedAt = ContinuousClock.now
        do {
            let newBridge = try await makeEngineV2BridgeForSlot(
                modelId: modelId,
                modelType: slot.modelType,
                isVLM: slot.isVLM,
                modelDirectory: ModelScanner.resolveLocalPath(modelID: modelId),
                container: slot.container,
                tokenizer: slot.tokenizer,
                sizing: slot.sizing,
                kvBytesCapacity: grant)
            // makeEngineV2BridgeForSlot re-registered `newBridge` in
            // engineV2Runtime (replacing the old bridge's entry).

            let rebuildElapsed = ContinuousClock.now - rebuildStartedAt
            let rebuildMs = Int64(
                (Double(rebuildElapsed.components.seconds) * 1000.0
                    + Double(rebuildElapsed.components.attoseconds) / 1e15).rounded())
            await newBridge.recordModelLoadTime(ms: max(0, rebuildMs))

            guard modelSlots[modelId]?.engineV2 === bridge, !isShuttingDown else {
                // The slot was torn down while the engine rebuilt (explicit
                // unload/retirement or shutdown). Abort the swap: retire
                // our runtime registration and drain the never-served
                // fresh bridge; whoever removed the slot owns the rest.
                releaseResliceGate()
                await engineV2Runtime.unregister(modelId: modelId)
                await newBridge.shutdown()
                logger.warning(
                    "engine_v2 liveness: \(modelId) was unloaded mid-recovery — rebuilt engine discarded")
                return
            }

            modelSlots[modelId] = ModelSlot(
                engineV2: newBridge,
                container: slot.container,
                tokenizer: slot.tokenizer,
                sizing: slot.sizing,
                isVLM: slot.isVLM,
                modelType: slot.modelType,
                lastInferenceAt: .now
            )
            releaseResliceGate()

            await newBridge.emitSelfRestartTelemetry(
                operation: "engine_v2_self_restart_complete",
                severity: .info,
                message: "engine_v2: self-restart complete (engine rebuilt over retained container)",
                durationMs: max(0, rebuildMs),
                now: now)
            logger.info(
                "engine_v2 liveness: \(modelId) recovered — engine rebuilt in \(max(0, rebuildMs)) ms with its retained \(grant) B KV grant")
            syncWarmModelState()
            await updateAggregateCapacity()
        } catch {
            // Rebuild failed (refusal telemetry already fired inside the
            // factory). The slot cannot serve — fail loud: unload it so
            // heartbeats stop advertising and the coordinator reroutes.
            releaseResliceGate()
            let message =
                "engine_v2 self-restart of '\(modelId)' failed to rebuild the engine: \(error) — unloading"
            logger.error("\(message)")
            await bridge.emitSelfRestartTelemetry(
                operation: "engine_v2_self_restart_failed",
                severity: .error,
                message: "engine_v2: self-restart failed to rebuild the engine — unloading",
                now: now)
            recordModelLoadError(model: modelId, message: message)
            await unloadModel(modelId)
        }
    }
}
