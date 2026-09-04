// Copyright © 2026 Eigen Labs.
//
// Model-load transient measurement (T3-08).
//
// Every admit-time gate (load gate, pending-load reservation, startup
// preload, doctor, the coordinator's cold-load gate) charges a model at
// `disk × 1.2` (`ModelScanner.memoryOverheadFactor`), justified as covering
// the LOAD TRANSIENT — shard staging that briefly exceeds the steady
// post-load residency — which nothing measured. MLX keeps a process-lifetime
// peak counter; resetting it right before the container load and reading
// it once the weights are resident yields the transient per load, on the
// production load path, for every model the fleet serves. Log-first: no
// wire field (a telemetry field needs the three-language allowlist mirror
// — follow-up).
//
// Consequence for every other reader of `MLX.Memory.peakMemory`
// (heartbeat `gpu_memory_peak_gb`, the OOM marker's `peak_memory_bytes`,
// the per-request `mlx_peak` diagnostic): the figure is now "peak since the
// last model load", not "peak since process start".

import Foundation
import MLX

struct ModelLoadTransientProbe: Sendable {
    struct Summary: Equatable, Sendable {
        /// MLX active bytes at the reset — anything already resident (other
        /// models, in-flight decode on a serve-while-load box). When this is
        /// non-zero the peak may include CONCURRENT activations, so the
        /// overshoot is only a clean load-transient figure on an idle load.
        let activeAtResetBytes: UInt64
        /// MLX active bytes once the weights are resident.
        let steadyActiveBytes: UInt64
        /// MLX peak since the reset.
        let peakBytes: UInt64
        /// The artifact's on-disk bytes (the base of the ×1.2 padding).
        let diskBytes: UInt64

        /// This load's own steady residency (steady − whatever was resident
        /// before it).
        var residentDeltaBytes: UInt64 {
            steadyActiveBytes > activeAtResetBytes ? steadyActiveBytes - activeAtResetBytes : 0
        }
        /// How far the load overshot its steady residency.
        var peakOverSteadyBytes: UInt64 {
            peakBytes > steadyActiveBytes ? peakBytes - steadyActiveBytes : 0
        }
        /// Overshoot as a fraction of disk bytes — comparable to the 0.2 the
        /// ×1.2 padding budgets for it.
        var peakOverSteadyDiskRatio: Double {
            diskBytes > 0 ? Double(peakOverSteadyBytes) / Double(diskBytes) : 0
        }

        func logLine(modelId: String) -> String {
            let mib = 1024.0 * 1024.0
            return String(
                format: "Model load transient: model=%@ disk=%.0fMiB steady_delta=%.0fMiB "
                    + "peak_over_steady=%.0fMiB (%.1f%% of disk; admit padding budgets 20%%) "
                    + "active_at_reset=%.0fMiB",
                modelId,
                Double(diskBytes) / mib,
                Double(residentDeltaBytes) / mib,
                Double(peakOverSteadyBytes) / mib,
                peakOverSteadyDiskRatio * 100,
                Double(activeAtResetBytes) / mib)
        }
    }

    let activeAtResetBytes: UInt64

    /// Reset MLX's peak counter and remember what was already resident.
    /// Call immediately before the container load — after every earlier
    /// suspension — so the peak covers exactly the shard staging.
    static func begin(
        activeBytes: UInt64 = UInt64(max(0, MLX.Memory.activeMemory)),
        resetPeak: () -> Void = { MLX.GPU.resetPeakMemory() }
    ) -> ModelLoadTransientProbe {
        resetPeak()
        return ModelLoadTransientProbe(activeAtResetBytes: activeBytes)
    }

    /// Read the load's peak against the now-steady residency.
    func end(
        diskBytes: UInt64,
        steadyActiveBytes: UInt64 = UInt64(max(0, MLX.Memory.activeMemory)),
        peakBytes: UInt64 = UInt64(max(0, MLX.Memory.peakMemory))
    ) -> Summary {
        Summary(
            activeAtResetBytes: activeAtResetBytes,
            steadyActiveBytes: steadyActiveBytes,
            peakBytes: peakBytes,
            diskBytes: diskBytes)
    }
}
