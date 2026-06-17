import Foundation

// Energy attribution ledger.
//
// Turns a stream of measured energy samples (joules consumed since the last
// tick, broken down by SoC subsystem) plus a coarse activity signal (how many
// prefill / decode tokens were produced in that tick) into a per-operation
// energy breakdown:
//
//   total = idle-floor baseline + prefill + decode + model-load
//
// The idle floor (watts the machine draws while a model is resident but no
// request is running) is measured directly from quiet ticks. The energy ABOVE
// that baseline on active ticks is attributed to prefill vs decode with an
// online 2x2 non-negative least-squares fit:
//
//   residual_i  ~=  a * prefill_tokens_i  +  b * decode_tokens_i
//
// where `a` is J per prefill token and `b` is J per decode token. Pure-decode
// ticks pin `b`; pure-prefill ticks pin `a`. Continuous-batching overlap (a
// request prefilling while another decodes) is exactly what the regression
// disentangles — you cannot get clean per-token numbers by bucketing alone.
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

/// Coarse work signal for a tick. Token deltas drive the regression; the flags
/// classify the tick.
public struct EnergyActivity: Sendable, Equatable {
    public var prefillTokens: Double
    public var decodeTokens: Double
    public var modelResident: Bool
    public var loading: Bool

    public init(prefillTokens: Double, decodeTokens: Double, modelResident: Bool, loading: Bool) {
        self.prefillTokens = prefillTokens
        self.decodeTokens = decodeTokens
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

    // Cumulative joules per subsystem (across all buckets).
    public private(set) var cpuJoules = 0.0
    public private(set) var gpuJoules = 0.0
    public private(set) var aneJoules = 0.0
    public private(set) var dramJoules = 0.0

    // Normalizers / counters.
    public private(set) var prefillTokens = 0.0
    public private(set) var decodeTokens = 0.0
    public private(set) var warmSeconds = 0.0
    public private(set) var loadSeconds = 0.0
    public private(set) var modelLoads = 0

    // Derived: idle baseline watts, measured from quiet ticks.
    public private(set) var idleWatts = 0.0

    // Most recent instantaneous total power (W) for live stats.
    public private(set) var lastWatts = 0.0

    // Online 2x2 regression accumulators (residual above idle on active ticks).
    private var sPP = 0.0, sPD = 0.0, sDD = 0.0, sPR = 0.0, sDR = 0.0
    // Idle-floor stability filter: only learn the floor from sustained quiet,
    // so a one-tick model-load / GC spike can't corrupt the baseline.
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

        if activity.loading {
            consecutiveIdleTicks = 0
            loadJoules += joules
            loadSeconds += dt
            return
        }

        let isActive = activity.prefillTokens > 0 || activity.decodeTokens > 0
        if isActive {
            consecutiveIdleTicks = 0
            warmSeconds += dt
            prefillTokens += activity.prefillTokens
            decodeTokens += activity.decodeTokens

            let base = idleWatts * dt
            idleJoules += base
            let residual = max(0, joules - base)

            // Update regression accumulators.
            let p = activity.prefillTokens, d = activity.decodeTokens
            sPP += p * p
            sPD += p * d
            sDD += d * d
            sPR += p * residual
            sDR += d * residual

            // Attribute this tick's residual using the current coefficients.
            let (a, b) = coefficients()
            let estP = a * p, estD = b * d
            let denom = estP + estD
            if denom > 1e-9 {
                prefillJoules += residual * estP / denom
                decodeJoules += residual * estD / denom
            } else if d > 0 {
                decodeJoules += residual
            } else if p > 0 {
                prefillJoules += residual
            } else {
                idleJoules += residual
            }
        } else {
            // Quiet tick: whole sample is idle baseline.
            warmSeconds += dt
            idleJoules += joules
            consecutiveIdleTicks += 1
            if consecutiveIdleTicks >= Self.idleStabilityThreshold {
                let w = joules / dt
                idleWatts = idleWatts > 0 ? (Self.idleAlpha * w + (1 - Self.idleAlpha) * idleWatts) : w
            }
        }
    }

    /// Record that a model finished loading (call once per load completion).
    public mutating func noteModelLoad() { modelLoads += 1 }

    /// Solve [sPP sPD; sPD sDD][a;b] = [sPR; sDR], clamped to non-negative, with
    /// graceful fallbacks when one dimension hasn't been excited yet.
    public func coefficients() -> (jPerPrefillToken: Double, jPerDecodeToken: Double) {
        let det = sPP * sDD - sPD * sPD
        if abs(det) > 1e-6 && sPP > 1e-6 && sDD > 1e-6 {
            let a = (sDD * sPR - sPD * sDR) / det
            let b = (sPP * sDR - sPD * sPR) / det
            return (max(0, a), max(0, b))
        }
        let a = sPP > 1e-6 ? max(0, sPR / sPP) : 0
        let b = sDD > 1e-6 ? max(0, sDR / sDD) : 0
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
