/// One cold load's stage timings and residency facts (T4-04).
///
/// Built by the two load paths (`ProviderLoop.ensureModelLoaded`,
/// `StandaloneServer.ensureModelLoaded`), rendered onto the `Model loaded:`
/// log line and emitted as one `.engineHealth` telemetry event. Pure value:
/// no wire field changes — the heartbeat's `model_load_time_ms` keeps its
/// window (`totalMs` here) and `evict_ms` is reported beside it, never
/// folded in.
///
/// `estimatedGb` = disk × 1.2 is what the admit gate and the pending-load
/// reservation charge for the LOAD TRANSIENT; `transientRatio` =
/// (peak − pre-load residency) / disk is THIS load's measured footprint on
/// the same scale (1.2 ⇒ exactly the padding) — the input for any later
/// per-family padding change. Every MLX figure is process-wide, so the
/// report carries the pre-load baseline and derives per-load deltas from
/// it; a co-resident model never inflates the ratio.

import Foundation

struct ModelLoadStageReport: Sendable, Equatable {
    /// Slot-cap LRU eviction + `evictUntilAvailable` before the
    /// `model_load_time_ms` window opens.
    var evictMs: Double = 0
    /// Every weight-hash observation on this load (pre-load capture, the
    /// post-load bracket or fingerprint re-check, drift recompute).
    var hashMs: Double = 0
    /// Full SHA-256 passes over the snapshot (0 with a seeded fingerprint on
    /// a contiguous slot, 1 on a fingerprint miss, 2 for the paged bracket).
    var hashPasses: Int = 0
    /// `loadModelContainer` (shard read + eval + sanitize + quantize wire).
    var containerLoadMs: Double = 0
    /// Cold-load `clearCache` + measured KV headroom probe + tokenizer handle.
    var postLoadProbeMs: Double = 0
    /// Engine + bridge construction, including an MTP target-only rebuild.
    var buildMs: Double = 0
    /// == `model_load_time_ms` (window unchanged).
    var totalMs: Double = 0
    /// Scanner facts: on-disk bytes and the padded admit estimate.
    var diskGb: Double
    var estimatedGb: Double
    /// Process-wide MLX peak since `ModelLoadTransientProbe.begin()` reset
    /// the counter right before shard staging — everything already resident
    /// (co-resident models, in-flight decode) is inside it. nil ⇒ the
    /// counter never rose above `peakBaselineGb` (nothing was staged).
    var peakActiveGb: Double?
    /// `MLX.Memory.activeMemory` at the peak reset: the residency this load
    /// started from, and the baseline every per-load delta subtracts.
    var peakBaselineGb: Double = 0
    /// `MLX.Memory.activeMemory` right after the post-load `clearCache`
    /// (process-wide; `steadyDeltaGb` is this load's own share).
    var steadyActiveGb: Double = 0

    init(diskGb: Double, estimatedGb: Double) {
        self.diskGb = diskGb
        self.estimatedGb = estimatedGb
    }

    /// This load's own steady residency: steady − the pre-load baseline.
    var steadyDeltaGb: Double { max(0, steadyActiveGb - peakBaselineGb) }

    /// This load's peak footprint over the pre-load baseline as a fraction
    /// of its disk bytes — directly comparable to the 1.2 admit padding
    /// (`estimatedGb / diskGb`). Process-wide peak ÷ one model's disk size
    /// would read a 14 GB model loaded beside an 11 GB resident one as 1.8.
    var transientRatio: Double? {
        guard let peakActiveGb, diskGb > 0 else { return nil }
        return max(0, peakActiveGb - peakBaselineGb) / diskGb
    }

    var peakMasked: Bool { peakActiveGb == nil }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000.0
            + Double(duration.components.attoseconds) / 1e15
    }

    /// Record the peak read around `loadModelContainer`. `beforeBytes` is
    /// the residency at the moment `ModelLoadTransientProbe.begin()` reset
    /// the process-wide peak, so `afterBytes > beforeBytes` holds for any
    /// load that raised memory at all; `peak_masked` now only means the
    /// counter did not move (nothing was staged).
    mutating func recordPeak(beforeBytes: Int, afterBytes: Int) {
        peakBaselineGb = Double(max(0, beforeBytes)) / 1_073_741_824.0
        peakActiveGb = afterBytes > beforeBytes
            ? Double(afterBytes) / 1_073_741_824.0
            : nil
    }

    /// Free-form fields for the `.engineHealth` "model loaded" event.
    var telemetryFields: [String: AnyCodableValue] {
        var fields: [String: AnyCodableValue] = [
            "evict_ms": .double(evictMs),
            "hash_ms": .double(hashMs),
            "hash_passes": .int(hashPasses),
            "container_load_ms": .double(containerLoadMs),
            "post_load_probe_ms": .double(postLoadProbeMs),
            "build_ms": .double(buildMs),
            "total_ms": .double(totalMs),
            "disk_gb": .double(diskGb),
            "estimated_gb": .double(estimatedGb),
            "steady_active_gb": .double(steadyActiveGb),
            "steady_delta_gb": .double(steadyDeltaGb),
            "peak_baseline_gb": .double(peakBaselineGb),
            "peak_masked": .bool(peakMasked),
        ]
        if let peakActiveGb {
            fields["peak_active_gb"] = .double(peakActiveGb)
        }
        if let transientRatio {
            fields["transient_ratio"] = .double(transientRatio)
        }
        return fields
    }

    /// Compact suffix for the `Model loaded:` log line.
    var logSummary: String {
        func f(_ value: Double) -> String { String(format: "%.0f", value) }
        func g(_ value: Double) -> String { String(format: "%.2f", value) }
        var parts = [
            "total_ms=\(f(totalMs))",
            "evict_ms=\(f(evictMs))",
            "hash_ms=\(f(hashMs))",
            "hash_passes=\(hashPasses)",
            "container_load_ms=\(f(containerLoadMs))",
            "post_load_probe_ms=\(f(postLoadProbeMs))",
            "build_ms=\(f(buildMs))",
            "disk_gb=\(g(diskGb))",
            "estimated_gb=\(g(estimatedGb))",
            "steady_active_gb=\(g(steadyActiveGb))",
            "steady_delta_gb=\(g(steadyDeltaGb))",
        ]
        if let peakActiveGb, let transientRatio {
            parts.append("peak_active_gb=\(g(peakActiveGb))")
            parts.append("transient_ratio=\(g(transientRatio))")
        } else {
            parts.append("peak_active_gb=masked(baseline=\(g(peakBaselineGb)))")
        }
        return parts.joined(separator: " ")
    }
}
