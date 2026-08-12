/// ProviderLoop -- trust status persistence.
///
/// Persists daemon state and reacts to coordinator `trust_status`. Unified logs
/// are intentionally never collected or uploaded: inference failures may occur
/// while request plaintext is in memory, so a bulk log export is not an
/// acceptable diagnostics boundary.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Trust Status

    /// Handle a trust_status message from the coordinator.
    /// Assembles the current daemon state and writes it to the state file so the
    /// CLI (`status`/`doctor`) can read live state + the latest trust reason.
    /// Best-effort and cheap; safe to call from the trust handler and the
    /// periodic capacity loop.
    internal func writeDaemonState() {
        DaemonStateFile.write(currentDaemonState())
    }

    /// The snapshot `writeDaemonState` persists. Split out so a test can
    /// assert its contents without a global `DARKBLOOM_STATE_FILE` override
    /// racing every other suite.
    internal func currentDaemonState() -> DaemonState {
        let cap = state.backendCapacity
        return DaemonState(
            pid: getpid(),
            processIdentity: ProcessIdentity.current(),
            version: ProviderCore.version,
            writtenAt: Date().timeIntervalSince1970,
            startedAt: startedAtEpoch,
            trust: lastTrustStatus,
            currentModel: state.currentModel,
            warmModels: state.warmModels,
            inferenceActive: state.inferenceActive,
            stats: DaemonState.Stats(
                requestsServed: stats.requestsServed,
                tokensGenerated: stats.tokensGenerated,
                usageGaps: stats.usageGaps
            ),
            capacity: cap.map {
                DaemonState.Capacity(
                    totalMemoryGb: $0.totalMemoryGb,
                    gpuMemoryActiveGb: $0.gpuMemoryActiveGb,
                    gpuMemoryCacheGb: $0.gpuMemoryCacheGb)
            },
            lastModelLoadError: lastModelLoadError,
            // Joined at WRITE time, not at sample time: a refused explicit
            // paged request builds no engine, so its only trace is
            // `lastModelLoadError` — and `recordModelLoadError` writes the
            // state file immediately, before the next capacity refresh.
            slots: DaemonSlotPostureBuilder.build(
                live: lastLiveSlotPostures,
                requestedGlobal: loopConfig.config.backend.engineV2KVBackend,
                requestedByModel: loopConfig.config.backend.engineV2KVBackendByModel,
                lastModelLoadError: lastModelLoadError,
                desiredModels: desiredModelsForPosture(),
                // Expiry follows THIS box's idle-unload horizon, not the
                // default: 0 (unload disabled) never expires by age, a
                // longer-than-default timeout keeps evidence just as long.
                failureMaxAge: DaemonSlotPostureBuilder.failureMaxAge(
                    idleTimeoutMins: loopConfig.config.backend.idleTimeoutMins))
        )
    }

    /// The set of models this daemon still wants to serve, for the
    /// synthetic failed-slot suppression in `DaemonSlotPostureBuilder`.
    /// nil when `enabled_models` is empty — that config serves ANY
    /// downloaded or coordinator-pushed model, so membership proves
    /// nothing and the builder falls back to age expiry alone. When the
    /// allowlist is set, the pinned `model` and `preload_models` join it,
    /// and so does the LIVE advertised set: a daemon launched with
    /// `--model X` or `--all` deliberately selects models OUTSIDE
    /// `enabled_models` (the launch path seeds them into
    /// `loopConfig.models` → `advertisedModels`, and background prefetch
    /// appends more at runtime) while the config object passed in here is
    /// unchanged — a failed load of such a model is a real refusal the
    /// operator asked to see, and must never be suppressed as "undesired"
    /// by a config filter the launch flags overrode.
    internal func desiredModelsForPosture() -> Set<String>? {
        let backend = loopConfig.config.backend
        guard !backend.enabledModels.isEmpty else { return nil }
        var desired = Set(backend.enabledModels)
        desired.formUnion(backend.preloadModels)
        if let pinned = backend.model { desired.insert(pinned) }
        desired.formUnion(advertisedModels.keys)
        return desired
    }

    /// Records a model-load failure for the diagnostics state file so the
    /// operator sees the exact "Insufficient memory …" text in `doctor`.
    internal func recordModelLoadError(model: String, message: String) {
        lastModelLoadError = DaemonState.ModelLoadError(
            model: model, message: message, at: Date().timeIntervalSince1970)
        writeDaemonState()
    }

    internal func handleTrustStatus(trustLevel: String, status: String, reason: String) {
        logger.info("Trust status update: level=\(trustLevel) status=\(status)")

        // Cache + persist so `darkbloom status`/`doctor` can show the operator
        // the coordinator's reason (otherwise it is only in the logs).
        lastTrustStatus = DaemonState.Trust(
            trustLevel: trustLevel, status: status, reason: reason,
            receivedAt: Date().timeIntervalSince1970)
        writeDaemonState()
    }

}
