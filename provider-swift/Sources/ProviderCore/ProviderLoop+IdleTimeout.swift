/// ProviderLoop -- idle-timeout model unload monitor.
///
/// Polls resident models and unloads those idle past the configured timeout
/// (default 60 minutes) to free GPU memory; reloads lazily on the next request.

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
    // MARK: - Idle timeout

    /// Start the background idle-monitor task. Polls every minute; if
    /// `idleTimeoutMins` minutes have elapsed since the last inference
    /// activity AND no requests are in flight, the loaded model is
    /// unloaded to free GPU memory. The next inference request lazy-
    /// reloads it.
    ///
    /// `idleTimeoutMins == 0` disables the monitor entirely (model stays
    /// resident forever).
    internal func startIdleMonitor() {
        idleMonitorTask?.cancel()
        let timeoutMinutes = loopConfig.config.backend.idleTimeoutMins
        guard timeoutMinutes > 0 else {
            logger.info("Idle-timeout disabled (idle_timeout_mins=0)")
            return
        }

        let timeout = Duration.seconds(Int64(timeoutMinutes) * 60)
        let pollInterval = Duration.seconds(60)
        let me = self
        idleMonitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                await me.tickIdleMonitor(timeout: timeout)
            }
        }
        logger.info("Idle monitor started (timeout: \(timeoutMinutes) min)")
    }

    /// Single tick: check each loaded model for idle timeout. Unloads any
    /// model that has no in-flight requests and has exceeded the timeout.
    /// Re-validates each candidate before unloading since `await unloadModel`
    /// is a suspension point that could allow new requests to arrive.
    private func tickIdleMonitor(timeout: Duration) async {
        guard !modelSlots.isEmpty else { return }

        let now = ContinuousClock.now

        var candidates: [String] = []
        let modelsWithInflight = Set(requestToModel.values)
        for (modelId, slot) in modelSlots {
            if modelsUnloading.contains(modelId) { continue }
            let elapsed = now - slot.lastInferenceAt
            let hasInflight = modelsWithInflight.contains(modelId) || hasLocalReservation(modelId)
            if IdleTimeoutPolicy.shouldUnload(
                elapsed: elapsed,
                timeout: timeout,
                hasInflight: hasInflight,
                hasLoadedModel: true
            ) {
                candidates.append(modelId)
            }
        }

        for modelId in candidates {
            let currentInflight = Set(requestToModel.values)
            guard !currentInflight.contains(modelId),
                  !hasLocalReservation(modelId),
                  !modelsUnloading.contains(modelId),
                  let slot = modelSlots[modelId] else { continue }

            let elapsed = ContinuousClock.now - slot.lastInferenceAt
            guard IdleTimeoutPolicy.shouldUnload(
                elapsed: elapsed,
                timeout: timeout,
                hasInflight: false,
                hasLoadedModel: true
            ) else { continue }

            logger.info("Idle timeout exceeded (\(formatDuration(elapsed)) since last activity); unloading \(modelId)")
            await unloadModel(modelId)
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        DurationFormatting.compact(Double(duration.components.seconds), spaced: false)
    }

}
