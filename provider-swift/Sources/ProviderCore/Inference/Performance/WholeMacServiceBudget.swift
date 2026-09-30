import Foundation
import MLXLMCommon

/// One normalized service allowance shared by every resident model. A profile
/// of width N consumes 1/N per request; three models never get three budgets.
/// Leases have no timeout: cancellation releases only after engine retirement.
final class WholeMacServiceBudget: @unchecked Sendable {
    private let lock = NSLock()
    struct Work: Sendable {
        let modelID: String
        let profileID: String?
        let promptTokens: Int
        let maxOutputTokens: Int
        var calibratedContextTokensMax: Int = .max
    }
    private struct DeadlineProof {
        let applicability: DeadlineApplicability
        let postureEpoch: UUID
        let activityEpoch: UInt64
    }
    private struct Charge {
        let fraction: Double
        let reservationID: String?
        let lifetime: ServiceReservationLifetime?
        let work: Work?
        let deadlineProof: DeadlineProof?
    }
    struct Snapshot: Sendable, Equatable {
        let usedFraction: Double
        let reservations: [WholeMacServiceReservation]
        let deadlineWorkByModel: [String: DeadlineWork]

        init(usedFraction: Double, reservations: [WholeMacServiceReservation],
            deadlineWorkByModel: [String: DeadlineWork] = [:]) {
            self.usedFraction = usedFraction
            self.reservations = reservations
            self.deadlineWorkByModel = deadlineWorkByModel
        }
    }
    private let clockNow: @Sendable () -> ContinuousClock.Instant
    private let posture: DeadlinePostureState
    private var postureObserver: UUID?
    private var idleSince: ContinuousClock.Instant
    private var activityEpoch: UInt64 = 0
    private var advertisedEligibility: [DeadlineApplicability: Bool] = [:]
    private var charges: [String: Charge] = [:]
    private var unboundedActivities: Set<UUID> = []
    private var evidenceGuard = CBv2FirstContentEvidenceGuard()
    private var observerID: UUID?
    private var observer: AsyncStream<Void>.Continuation?

    init(clockNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        posture: DeadlinePostureState = DeadlinePostureMonitor.shared.state) {
        self.clockNow = clockNow
        self.posture = posture
        self.idleSince = clockNow()
        postureObserver = posture.observeChanges { [weak self] in
            guard let self else { return }
            self.postureChanged()
        }
    }

    deinit { if let postureObserver { posture.removeObserver(postureObserver) } }

    func currentDeadlineRateEpoch(at now: ContinuousClock.Instant = .now) -> UUID? {
        posture.rateEpoch(at: now)
    }

    func captureDeadlineRateEvidence(at now: ContinuousClock.Instant = .now) -> DeadlineRateEvidence? {
        posture.captureRateEvidence(at: now)
    }

    func deadlineEligibleForAdvertisement(_ requirement: DeadlineApplicability) -> Bool {
        lock.withLock {
            let now = clockNow()
            let ready = quiescenceSatisfiedLocked(requirement, at: now)
                && posture.snapshot(requirement: requirement, at: now) != nil
            advertisedEligibility[requirement] = ready
            return ready
        }
    }

    private func postureChanged() {
        let notification = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            let now = clockNow()
            var changed = false
            for (requirement, previous) in advertisedEligibility {
                let ready = quiescenceSatisfiedLocked(requirement, at: now)
                    && posture.snapshot(requirement: requirement, at: now) != nil
                if ready != previous { advertisedEligibility[requirement] = ready; changed = true }
            }
            return changed ? observer : nil
        }
        notification?.yield()
    }

    private func quiescenceSatisfiedLocked(_ requirement: DeadlineApplicability,
        at now: ContinuousClock.Instant) -> Bool {
        charges.isEmpty && unboundedActivities.isEmpty
                && now >= idleSince.advanced(by: .milliseconds(requirement.minimumWholeMacQuiescenceMs))
    }

    func acquire(ownerID: String, concurrency: Int, serviceReservationID: String? = nil,
        serviceReservation: ServiceReservationLifetime? = nil, work: Work? = nil,
        deadlineApplicability: DeadlineApplicability? = nil, requiresIdle: Bool = false) -> Bool {
        // Correlation is optional. Malformed input gets no overlap credit; it
        // never bypasses the actual provider-side service allowance.
        let reservationID = serviceReservation?.id
            ?? ServiceReservationLifetime.normalizedID(serviceReservationID)
        let (acquired, notification) = lock.withLock { () -> (Bool, AsyncStream<Void>.Continuation?) in
            guard charges[ownerID] == nil, concurrency > 0 else { return (false, nil) }
            if requiresIdle, !charges.isEmpty || !unboundedActivities.isEmpty { return (false, nil) }
            if let reservationID, charges.values.contains(where: { $0.reservationID == reservationID }) {
                return (false, nil)
            }
            let charge = 1 / Double(concurrency)
            guard charges.values.reduce(0, { $0 + $1.fraction }) + charge <= 1 + 1e-12 else { return (false, nil) }
            guard serviceReservation?.acquireLease() ?? true else { return (false, nil) }
            let now = clockNow()
            let captured = deadlineApplicability.flatMap { requirement in
                quiescenceSatisfiedLocked(requirement, at: now)
                    ? posture.snapshot(requirement: requirement, at: now) : nil
            }
            invalidateEvidenceLocked()
            let proof: DeadlineProof?
            if let captured, let deadlineApplicability {
                proof = .init(applicability: deadlineApplicability,
                    postureEpoch: captured.epoch, activityEpoch: activityEpoch)
            } else { proof = nil }
            charges[ownerID] = Charge(fraction: charge, reservationID: reservationID,
                lifetime: serviceReservation, work: work, deadlineProof: proof)
            return (true, observer)
        }
        notification?.yield()
        return acquired
    }

    func release(ownerID: String) {
        let (charge, notification) = lock.withLock { () -> (Charge?, AsyncStream<Void>.Continuation?) in
            guard let charge = charges.removeValue(forKey: ownerID) else { return (nil, nil) }
            if charges.isEmpty && unboundedActivities.isEmpty { idleSince = clockNow() }
            invalidateEvidenceLocked()
            return (charge, observer)
        }
        charge?.lifetime?.releaseLease()
        notification?.yield()
    }

    /// One provider-loop observer sees changes from all shared model bridges.
    /// Coalesce bursts before the actor hop; the consumer reads current usage,
    /// never a possibly reordered fraction captured by the notifying thread.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        let previous = lock.withLock {
            let previous = observer
            observerID = id
            observer = continuation
            return previous
        }
        previous?.finish()
        continuation.yield() // include ownership acquired before registration
        return stream
    }

    private func removeObserver(_ id: UUID) {
        lock.withLock {
            guard observerID == id else { return }
            observerID = nil
            observer = nil
        }
    }

    /// Total and correlations must be from one lock epoch. In particular, a
    /// heartbeat cannot pair a pre-retirement total with post-retirement IDs.
    func snapshot(slotEpochs: [String: String] = [:], profileIDs: [String: String] = [:]) -> Snapshot {
        lock.withLock {
            let reservations = charges.values.compactMap { charge in
                charge.reservationID.map { WholeMacServiceReservation(id: $0, usedFraction: charge.fraction) }
            }.sorted { $0.id < $1.id }
            var byModel: [String: DeadlineWork] = [:]
            for (model, epoch) in slotEpochs {
                byModel[model] = deadlineWorkLocked(modelID: model, epoch: epoch, profileID: profileIDs[model])
            }
            return Snapshot(usedFraction: charges.values.reduce(0, { $0 + $1.fraction }),
                reservations: Array(reservations.prefix(64)), deadlineWorkByModel: byModel)
        }
    }

    var usedFraction: Double { lock.withLock { charges.values.reduce(0, { $0 + $1.fraction }) } }
    var count: Int { lock.withLock { charges.count } }

    func exclusiveEvidenceGuard(ownerID: String) -> CBv2FirstContentEvidenceGuard? {
        lock.withLock {
            guard charges.count == 1 && charges[ownerID]?.fraction == 1 && unboundedActivities.isEmpty
            else { return nil }
            return evidenceGuard
        }
    }

    /// Preparation, model loading and cache device transfers cannot borrow a
    /// token-work calibration. Each independent owner invalidates old guards;
    /// ending one owner cannot erase a later or overlapping activity.
    func beginUnboundedActivity() -> WholeMacUnboundedActivity {
        let id = UUID()
        let notification = lock.withLock {
            unboundedActivities.insert(id)
            invalidateEvidenceLocked()
            return observer
        }
        notification?.yield()
        return WholeMacUnboundedActivity { [self] in endUnboundedActivity(id) }
    }

    private func endUnboundedActivity(_ id: UUID) {
        let notification = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard unboundedActivities.remove(id) != nil else { return nil }
            if charges.isEmpty && unboundedActivities.isEmpty { idleSince = clockNow() }
            invalidateEvidenceLocked()
            return observer
        }
        notification?.yield()
    }

    private func invalidateEvidenceLocked() {
        activityEpoch &+= 1
        evidenceGuard.invalidate()
        evidenceGuard = CBv2FirstContentEvidenceGuard()
    }

    struct CalibrationSnapshot: Sendable {
        let postureEpoch: UUID?
        let postureValidUntil: ContinuousClock.Instant?
        let evidenceGuard: CBv2FirstContentEvidenceGuard
        let sameModelRequests: Int
        let otherModelRequests: Int
        let otherModelServiceFraction: Double
        let competitorProfileIDs: [String]
        let existingContextTokensMax: Int
        let otherModelPrefillTokens: Int
        let otherModelDecodeTokens: Int
        let sameModelPrefillTokens: Int
        let sameModelDecodeTokens: Int
    }

    func calibrationSnapshot(ownerID: String, modelID: String, profileID: String,
        applicability: DeadlineApplicability? = nil) -> CalibrationSnapshot? {
        lock.withLock {
            guard unboundedActivities.isEmpty,
                charges[ownerID]?.work?.modelID == modelID else { return nil }
            var postureEpoch: UUID?
            var postureValidUntil: ContinuousClock.Instant?
            if let applicability {
                guard let proof = charges[ownerID]?.deadlineProof, proof.applicability == applicability,
                    charges.count == 1 && proof.activityEpoch == activityEpoch else { return nil }
                if !evidenceGuard.isValid { evidenceGuard = CBv2FirstContentEvidenceGuard() }
                guard let observed = posture.snapshot(requirement: applicability, at: clockNow(),
                    registering: evidenceGuard), observed.epoch == proof.postureEpoch else { return nil }
                postureValidUntil = observed.validUntil
                postureEpoch = observed.epoch
            }
            var same = 0, other = 0
            var fraction = 0.0
            var competitors = Set<String>()
            var contextMax = 0
            var otherPrefill = 0, otherDecode = 0
            var samePrefill = 0, sameDecode = 0
            for (owner, charge) in charges {
                guard let work = charge.work, work.promptTokens > 0, work.maxOutputTokens >= 0,
                    let actualProfile = work.profileID else { return nil }
                if owner != ownerID {
                    let (context, overflow) = work.promptTokens.addingReportingOverflow(work.maxOutputTokens)
                    guard !overflow, context <= work.calibratedContextTokensMax else { return nil }
                }
                if work.modelID == modelID {
                    guard actualProfile == profileID else { return nil }
                    same += 1
                    if owner != ownerID {
                        let (context, overflow) = work.promptTokens.addingReportingOverflow(work.maxOutputTokens)
                        let (prefill, prefillOverflow) = samePrefill.addingReportingOverflow(work.promptTokens)
                        let (decode, decodeOverflow) = sameDecode.addingReportingOverflow(work.maxOutputTokens)
                        guard !overflow, !prefillOverflow, !decodeOverflow else { return nil }
                        samePrefill = prefill
                        sameDecode = decode
                        contextMax = max(contextMax, context)
                    }
                } else {
                    let (prefill, prefillOverflow) = otherPrefill.addingReportingOverflow(work.promptTokens)
                    let (decode, decodeOverflow) = otherDecode.addingReportingOverflow(work.maxOutputTokens)
                    guard !prefillOverflow, !decodeOverflow else { return nil }
                    otherPrefill = prefill
                    otherDecode = decode
                    other += 1
                    fraction += charge.fraction
                    competitors.insert(actualProfile)
                }
            }
            return CalibrationSnapshot(postureEpoch: postureEpoch, postureValidUntil: postureValidUntil, evidenceGuard: evidenceGuard, sameModelRequests: same,
                otherModelRequests: other, otherModelServiceFraction: fraction,
                competitorProfileIDs: competitors.sorted(), existingContextTokensMax: contextMax,
                otherModelPrefillTokens: otherPrefill, otherModelDecodeTokens: otherDecode,
                sameModelPrefillTokens: samePrefill, sameModelDecodeTokens: sameDecode)
        }
    }

    /// Full original work is a conservative bound across queued submissions,
    /// cancellations and transferred retirement. Keep it until the lease ends;
    /// a client terminal alone must not advertise an idle device.
    func deadlineWork(modelID: String, epoch: String) -> DeadlineWork {
        lock.withLock { deadlineWorkLocked(modelID: modelID, epoch: epoch) }
    }

    private func deadlineWorkLocked(modelID: String, epoch: String, profileID: String? = nil) -> DeadlineWork {
            var prefill = 0, decode = 0, count = 0, context = 0
            var fraction = 0.0
            var known = unboundedActivities.isEmpty
            for charge in charges.values {
                guard let work = charge.work else { known = false; continue }
                guard work.modelID == modelID else { continue }
                if work.profileID == nil || (profileID != nil && work.profileID != profileID) { known = false }
                count += 1
                fraction += charge.fraction
                let (nextPrefill, promptOverflow) = prefill.addingReportingOverflow(work.promptTokens)
                let (nextDecode, decodeOverflow) = decode.addingReportingOverflow(work.maxOutputTokens)
                let (totalContext, contextOverflow) = work.promptTokens.addingReportingOverflow(work.maxOutputTokens)
                guard work.promptTokens > 0, work.maxOutputTokens >= 0,
                    !promptOverflow, !decodeOverflow, !contextOverflow else { known = false; continue }
                if totalContext > work.calibratedContextTokensMax { known = false }
                prefill = nextPrefill
                decode = nextDecode
                context = max(context, totalContext)
            }
            return DeadlineWork(version: 1, epoch: epoch, known: known,
                prefillTokens: Int64(prefill), decodeTokens: Int64(decode), requestCount: count,
                contextTokensMax: context, serviceFraction: fraction)
    }
}
