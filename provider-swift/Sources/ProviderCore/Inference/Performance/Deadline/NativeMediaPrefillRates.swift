import Foundation
import MLXLMCommon

/// A phase sample is eligible only if its entire interval kept the same
/// observed power/thermal posture and exclusive whole-Mac ownership.
struct NativeMediaRateEvidence: Sendable {
    let rate: DeadlineRateEvidence
    let guardToken: CBv2FirstContentEvidenceGuard
    let validUntil: ContinuousClock.Instant

    func completedEpoch() -> UUID? {
        guard guardToken.isValid else { return nil }
        return rate.currentEpoch()
    }
}

/// Online observations, not a release-certified error envelope. Never
/// extrapolate outside the actually observed prompt range in one size band.
/// The slowest retained sample protects against a fast one-off warm sample.
struct NativeMediaPrefillRates {
    private struct Sample {
        let epoch: UUID
        let tokens: Int
        let rate: Double
        let at: ContinuousClock.Instant
    }
    private var samples: [Int: [Sample]] = [:]
    static let maximumAge: Duration = .seconds(120)
    private static let samplesPerBand = 32

    mutating func observe(tokens: Int, rate: Double, epoch: UUID,
        at observedAt: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) {
        guard tokens > 0, rate.isFinite, rate > 0,
            rate <= EngineV2Bridge.maxPlausiblePrefillTps,
            now >= observedAt, now - observedAt <= Self.maximumAge else { return }
        let key = EnginePerformanceMeasurements.bucket(tokens)
        var retained = (samples[key] ?? []).filter {
            $0.epoch == epoch && now >= $0.at && now - $0.at <= Self.maximumAge
        }
        retained.append(Sample(epoch: epoch, tokens: tokens, rate: rate, at: observedAt))
        retained.sort { $0.at < $1.at }
        samples[key] = Array(retained.suffix(Self.samplesPerBand))
    }

    func observation(tokens: Int, evidence: NativeMediaRateEvidence,
        now: ContinuousClock.Instant) -> CBv2NativeTargetPrefillRate? {
        guard let epoch = evidence.completedEpoch() else { return nil }
        let retained = (samples[EnginePerformanceMeasurements.bucket(tokens)] ?? []).filter {
            $0.epoch == epoch && now >= $0.at && now - $0.at <= Self.maximumAge
        }
        guard let minimum = retained.map(\.tokens).min(), let maximum = retained.map(\.tokens).max(),
            tokens >= minimum, tokens <= maximum, let slowest = retained.map(\.rate).min(),
            let oldest = retained.map(\.at).min() else { return nil }
        return .init(tokensPerSecond: slowest,
            promptTokensMin: minimum, promptTokensMax: maximum,
            validUntil: min(evidence.validUntil, oldest + Self.maximumAge),
            evidenceGuard: evidence.guardToken)
    }
}
