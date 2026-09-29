import Foundation
import MLXLMCommon

/// Bounded, observed posture history. No OS calls or subprocesses occur when
/// admission reads this state. Lost or stale observations never regain an old
/// evidence token, even after the machine recovers.
final class DeadlinePostureState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let epoch: UUID
        let nominalSince: ContinuousClock.Instant
        let validUntil: ContinuousClock.Instant
    }
    struct PowerObservation: Sendable {
        let source: String
        let automatic: Bool
        let powerReadAgeMilliseconds: Double
    }
    private final class WeakGuard {
        weak var value: CBv2FirstContentEvidenceGuard?
        init(_ value: CBv2FirstContentEvidenceGuard) { self.value = value }
    }
    private let lock = NSLock()
    private var epoch = UUID()
    private var nominalSince: ContinuousClock.Instant?
    private var observedAt: ContinuousClock.Instant?
    private var powerReadAt: ContinuousClock.Instant?
    private var powerSource: String?
    private var automaticPowerMode = false
    private var guards: [WeakGuard] = []
    private var observers: [UUID: @Sendable () -> Void] = [:]

    func observe(nominal: Bool, lowPower: Bool, automatic: Bool, source: String?,
        powerReadAt: ContinuousClock.Instant?, at now: ContinuousClock.Instant) {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            let continuous = observedAt.map { now >= $0 && now < $0.advanced(by: .seconds(1)) } ?? false
            let freshPower = powerReadAt.map { now >= $0 && now < $0.advanced(by: .seconds(3)) } ?? false
            // This deadline-policy revision is qualified on AC Automatic only.
            // Battery Automatic cannot reuse those rates after its stability
            // window; battery qualification requires an explicit extension.
            let eligible = nominal && !lowPower && automatic && source == "ac" && freshPower
            if !eligible || !continuous || self.powerSource != source {
                invalidateLocked()
                nominalSince = eligible ? now : nil
            } else if nominalSince == nil {
                nominalSince = now
            }
            self.observedAt = now
            self.powerReadAt = powerReadAt
            self.powerSource = source
            self.automaticPowerMode = automatic
            // The bounded capacity stream coalesces these ticks. It must also
            // notice elapsed stable/idle thresholds without a new request.
            return Array(observers.values)
        }
        callbacks.forEach { $0() }
    }

    /// Read the same bounded cached OS observations used by admission without
    /// launching or awaiting IO. Thermal recovery can remain observable while
    /// nominal eligibility is false; callers retain the actual mode verdict.
    func powerObservation(at now: ContinuousClock.Instant = .now) -> PowerObservation? {
        lock.withLock {
            guard let observedAt, let powerReadAt, let powerSource,
                powerSource == "ac" || powerSource == "battery",
                now >= observedAt, now < observedAt.advanced(by: .seconds(1)),
                now >= powerReadAt, now < powerReadAt.advanced(by: .seconds(3)) else { return nil }
            let age = powerReadAt.duration(to: now).components
            return PowerObservation(source: powerSource, automatic: automaticPowerMode,
                powerReadAgeMilliseconds: Double(age.seconds) * 1_000 + Double(age.attoseconds) / 1e15)
        }
    }

    func snapshot(requirement: DeadlineApplicability, at now: ContinuousClock.Instant,
        registering guardToken: CBv2FirstContentEvidenceGuard? = nil) -> Snapshot? {
        lock.withLock {
            guard requirement.isValid, let since = nominalSince, let observedAt, let powerReadAt,
                now >= observedAt, now < observedAt.advanced(by: .seconds(1)),
                now >= powerReadAt, now < powerReadAt.advanced(by: .seconds(3)),
                now >= since.advanced(by: .milliseconds(requirement.minimumNominalStabilityMs)) else { return nil }
            if let guardToken {
                guards.removeAll { $0.value == nil || $0.value?.isValid == false }
                if !guards.contains(where: { $0.value === guardToken }) { guards.append(WeakGuard(guardToken)) }
            }
            return Snapshot(epoch: epoch, nominalSince: since,
                validUntil: min(observedAt.advanced(by: .seconds(1)), powerReadAt.advanced(by: .seconds(3))))
        }
    }

    /// Sampling need not wait for the stability window, but must start and end
    /// inside the same fresh AC/nominal epoch. Admission still enforces the
    /// complete stability and whole-Mac quiescence requirements separately.
    func rateEpoch(at now: ContinuousClock.Instant = .now) -> UUID? {
        lock.withLock {
            guard nominalSince != nil, let observedAt, let powerReadAt,
                now >= observedAt, now < observedAt.advanced(by: .seconds(1)),
                now >= powerReadAt, now < powerReadAt.advanced(by: .seconds(3)) else { return nil }
            return epoch
        }
    }

    func captureRateEvidence(at now: ContinuousClock.Instant = .now) -> DeadlineRateEvidence? {
        rateEpoch(at: now).map { DeadlineRateEvidence(epoch: $0, posture: self) }
    }

    func observeChanges(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.withLock { let id = UUID(); observers[id] = callback; return id }
    }
    func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    private func invalidateLocked() {
        epoch = UUID()
        guards.forEach { $0.value?.invalidate() }
        guards.removeAll(keepingCapacity: true)
    }
}
