import Foundation

/// A rate may qualify admission only when its entire engine interval belongs
/// to one continuously observed eligible posture. Recovery never revives a
/// receipt captured before a transition or observation gap.
struct DeadlineRateEvidence: Sendable {
    let epoch: UUID
    let posture: DeadlinePostureState

    func currentEpoch(at now: ContinuousClock.Instant = .now) -> UUID? {
        posture.rateEpoch(at: now) == epoch ? epoch : nil
    }
}
