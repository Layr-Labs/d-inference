import Foundation

// Energy attribution ledger.
//
// Turns a stream of measured energy samples (joules consumed since the last
// tick, by SoC subsystem) plus a live activity signal into a per-operation
// energy breakdown:
//
//   measured = idle-floor baseline + prefill + decode + model-load
//
// Attribution is driven by LIVE per-tick signals, not end-of-request totals:
//   - `inferenceActive` (the engine is serving) classifies a tick as active.
//   - `loading` classifies a tick as a model load.
//   - otherwise the tick is idle (only counted as warm idle when a model is
//     resident — machine idle with no model resident is excluded from the warm
//     baseline so it can't bias the idle floor or per-token coefficients).
//
// On an active tick, energy ABOVE the measured idle floor is bucketed by whether
// the engine emitted output tokens during the tick: ticks with decode-token
// progress are decode work; active ticks with no output are prefill/compute.
// Per-token energy is then a direct ratio (bucket joules / bucket tokens), which
// is robust to continuous-batching timing and needs no regression.
//
// Caveats (inherent to measuring the idle floor from quiet ticks):
//   - If the box never goes idle (continuous load), `idleWatts` keeps its last
//     learned value (or 0 if it has never idled), so early data slightly
//     over-attributes to the active buckets.
//   - On a cold start whose first ticks are already active, `idleWatts` stays 0
//     until the first sustained quiet period.
//
// All energy values are joules. `1 Wh = 3600 J`.

/// One measured energy delta over a wall-clock interval, split by subsystem.
public struct EnergySample: Sendable, Equatable {
    public var seconds: Double
    public var cpuJoules: Double
    public var gpuJoules: Double
    public var aneJoules: Double
    public var dramJoules: Double

    public init(seconds: Double, cpuJoules: Double, gpuJoules: Double, aneJoules: Double, dramJoules: Double) {
        self.seconds = seconds
        self.cpuJoules = cpuJoules
        self.gpuJoules = gpuJoules
        self.aneJoules = aneJoules
        self.dramJoules = dramJoules
    }

    public var totalJoules: Double { cpuJoules + gpuJoules + aneJoules + dramJoules }
}

/// Per-tick work signal. Token fields are DELTAS for the tick; the flags
/// classify the tick. `decodeTokens` must reflect live streaming progress (not
/// an end-of-request total) for attribution to be correct.
public struct EnergyActivity: Sendable, Equatable {
    public var prefillTokens: Double
    public var decodeTokens: Double
    public var inferenceActive: Bool
    public var modelResident: Bool
    public var loading: Bool

    public init(prefillTokens: Double, decodeTokens: Double, inferenceActive: Bool, modelResident: Bool, loading: Bool) {
        self.prefillTokens = prefillTokens
        self.decodeTokens = decodeTokens
        self.inferenceActive = inferenceActive
        self.modelResident = modelResident
        self.loading = loading
    }
}

public struct EnergyLedger: Sendable {

    // Cumulative joules per operation bucket (since process start).
    public private(set) var idleJoules = 0.0
    public private(set) var prefillJoules = 0.0
    public private(set) var decodeJoules = 0.0
    public private(set) var loadJoules = 0.0
    // Machine-idle energy while NO model is resident — tracked for completeness
    // but deliberately excluded from the warm baseline and the wire snapshot.
    public private(set) var offJoules = 0.0

    // Cumulative joules per subsystem (across all buckets).
    public private(set) var cpuJoules = 0.0
    public private(set) var gpuJoules = 0.0
    public private(set) var aneJoules = 0.0
    public private(set) var dramJoules = 0.0

    // Normalizers / counters.
    public private(set) var prefillTokens = 0.0
    public private(set) var decodeTokens = 0.0
    public private(set) var warmSeconds = 0.0    // time a model was resident (idle warm + active + loading)
    public private(set) var loadSeconds = 0.0
    public private(set) var modelLoads = 0

    // Derived: idle baseline watts, measured from sustained quiet (model resident,
    // not serving). The stability filter prevents a transient spike from
    // corrupting the floor.
    public private(set) var idleWatts = 0.0

    // Most recent instantaneous total power (W) for live stats.
    public private(set) var lastWatts = 0.0

    private var consecutiveIdleTicks = 0
    private static let idleStabilityThreshold = 2
    private static let idleAlpha = 0.2

    public init() {}

    /// Fold one measured sample + its activity into the ledger.
    public mutating func record(_ sample: EnergySample, activity: EnergyActivity) {
        let dt = sample.seconds
        guard dt > 0 else { return }
        let joules = max(0, sample.totalJoules)
        lastWatts = joules / dt

        // Subsystem totals accrue regardless of bucket.
        cpuJoules += max(0, sample.cpuJoules)
        gpuJoules += max(0, sample.gpuJoules)
        aneJoules += max(0, sample.aneJoules)
        dramJoules += max(0, sample.dramJoules)

        // Token deltas accrue regardless of how this tick is bucketed; they are
        // the denominators for the per-token energy ratios.
        prefillTokens += max(0, activity.prefillTokens)
        decodeTokens += max(0, activity.decodeTokens)

        if activity.loading {
            consecutiveIdleTicks = 0
            warmSeconds += dt
            loadSeconds += dt
            loadJoules += joules
            return
        }

        if !activity.inferenceActive {
            // Not serving. Only count as warm idle when a model is resident;
            // otherwise it's machine-idle and must not bias the warm baseline.
            if activity.modelResident {
                warmSeconds += dt
                idleJoules += joules
                consecutiveIdleTicks += 1
                if consecutiveIdleTicks >= Self.idleStabilityThreshold {
                    let w = joules / dt
                    idleWatts = idleWatts > 0 ? (Self.idleAlpha * w + (1 - Self.idleAlpha) * idleWatts) : w
                }
            } else {
                offJoules += joules
                consecutiveIdleTicks = 0
            }
            return
        }

        // Active (serving). Subtract the measured idle baseline (clamped to the
        // tick's actual joules so buckets never exceed measured energy), then
        // bucket the remainder by whether output tokens advanced this tick.
        consecutiveIdleTicks = 0
        warmSeconds += dt
        let base = min(joules, idleWatts * dt)
        idleJoules += base
        let residual = joules - base
        if activity.decodeTokens > 0 {
            decodeJoules += residual
        } else {
            prefillJoules += residual
        }
    }

    /// Record that a model finished loading (call once per load completion).
    public mutating func noteModelLoad() { modelLoads += 1 }

    /// Average energy per token, derived directly from the buckets.
    public func coefficients() -> (jPerPrefillToken: Double, jPerDecodeToken: Double) {
        let a = prefillTokens > 0 ? prefillJoules / prefillTokens : 0
        let b = decodeTokens > 0 ? decodeJoules / decodeTokens : 0
        return (a, b)
    }

    public var totalJoules: Double { idleJoules + prefillJoules + decodeJoules + loadJoules }

    /// Immutable wire/report snapshot.
    public func snapshot() -> EnergyLedgerSnapshot {
        let (a, b) = coefficients()
        return EnergyLedgerSnapshot(
            currentWatts: lastWatts,
            idleWatts: idleWatts,
            idleJoules: idleJoules,
            prefillJoules: prefillJoules,
            decodeJoules: decodeJoules,
            loadJoules: loadJoules,
            cpuJoules: cpuJoules,
            gpuJoules: gpuJoules,
            aneJoules: aneJoules,
            dramJoules: dramJoules,
            prefillTokens: prefillTokens,
            decodeTokens: decodeTokens,
            warmSeconds: warmSeconds,
            modelLoads: modelLoads,
            jPerPrefillToken: a,
            jPerDecodeToken: b
        )
    }
}
