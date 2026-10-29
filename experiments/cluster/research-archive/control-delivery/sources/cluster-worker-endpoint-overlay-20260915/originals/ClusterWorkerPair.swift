import Foundation
import DarkbloomClusterProtocol

public enum ClusterWorkerRequestEvent: Sendable {
    case token(Int), finished(ClusterWorkerFinishReason), failed(String)
}

public struct ClusterWorkerPairReadiness: Sendable {
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    /// Sum of named local request allowances, never a sum of physical RAM.
    public let requestCapacityBytes: Int
}

/// Coordinates two same-Mac owned endpoints for the current prototype. A remote
/// endpoint requires authenticated remote-owner supervision and clock translation.
public final class ClusterWorkerPair: @unchecked Sendable {
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    let workers: [ClusterWorkerProcess]
    private let lock = NSLock()
    private var active: ClusterWorkerRequest?
    private var invalid = false
    private var stopping = false
    private let shutdownFinished = WorkerCompletion()
    private var handler: (@Sendable () -> Void)?
    private var notificationSent = false
    private let notifications = DispatchQueue(label: "darkbloom.worker-pair.invalidation")
    private var admittedCount = 0
    private var requestIDs = Set<UUID>()
    /// Same-Mac absolute ceiling only. A remote endpoint must translate a
    /// remaining duration against its own lifetime, never forward this uptime.
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 {
        min(workers[0].lifetimeDeadline, workers[1].lifetimeDeadline)
    }
    public var readiness: ClusterWorkerPairReadiness? {
        lock.withLock {
            guard !invalid && !stopping, let a = workers[0].readiness, let b = workers[1].readiness else { return nil }
            let sum = a.requestCapacityBytes.addingReportingOverflow(b.requestCapacityBytes)
            guard !sum.overflow, sum.partialValue <= ClusterWorkerLimits.capacityBytes else { return nil }
            return .init(identity: identity, profile: profile, executionPlanSHA256: executionPlanSHA256,
                requestCapacityBytes: sum.partialValue)
        }
    }

    public init(workers: [ClusterWorkerProcess], startupDeadline: UInt64) throws {
        guard workers.count == 2, workers[0] !== workers[1], workers.map(\.rank) == [0, 1],
              workers[0].expectedIdentity == workers[1].expectedIdentity,
              workers[0].expectedProfile == workers[1].expectedProfile,
              workers[0].executionPlanSHA256 == workers[1].executionPlanSHA256 else {
            throw ClusterWorkerOwnerError.invalid("Expected two ordered workers with one identity/profile/plan")
        }
        self.workers = workers; identity = workers[0].expectedIdentity; profile = workers[0].expectedProfile
        executionPlanSHA256 = workers[0].executionPlanSHA256
        do {
            for worker in workers {
                let first = try worker.next(until: startupDeadline)
                guard case .ready = first.event, first.requestID == nil else { throw ClusterWorkerOwnerError.unavailable }
            }
        } catch { for worker in workers { worker.fence() }; throw error }
        for worker in workers { worker.setInvalidationHandler { [weak self] in self?.invalidate() } }
    }

    public func setInvalidationHandler(_ value: @escaping @Sendable () -> Void) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            handler = value
            return invalid || stopping ? notificationLocked() : nil
        }
        if let notify { notifications.async(execute: notify) }
    }

    private func notificationLocked() -> (@Sendable () -> Void)? {
        guard !notificationSent, let handler else { return nil }; notificationSent = true; return handler
    }

    func invalidate() {
        let values = lock.withLock { () -> (ClusterWorkerRequest?, (@Sendable () -> Void)?) in
            if invalid { return (nil, nil) }; invalid = true; return (active, notificationLocked())
        }
        values.0?.cancel(reason: .peerFailure)
        if let notify = values.1 { notifications.async(execute: notify) }
    }

    /// Performs CPU/resource admission only. The exclusive worker does not run
    /// forward until start. Partial refusal is quarantined and fenced before reuse.
    public func reserve(requestID: UUID, reservation: ClusterWorkerReservation,
                        admissionDeadline: UInt64? = nil) throws -> ClusterWorkerRequest {
        // An expired admission budget acquires no request ID or reservation.
        if let admissionDeadline, DispatchTime.now().uptimeNanoseconds >= admissionDeadline {
            throw ClusterWorkerOwnerError.deadline
        }
        _ = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: identity.membershipEpoch,
            sequence: 0, requestID: requestID, command: .reserve(reservation)))
        let lease = try lock.withLock { () -> ClusterWorkerRequest in
            guard !invalid && !stopping && active == nil, admittedCount < ClusterWorkerLimits.requestsPerEpoch, !requestIDs.contains(requestID),
                  reservation.profileID == profile.id,
                  reservation.promptTokenIDs.count <= profile.maximumPromptTokens,
                  reservation.outputCount <= profile.maximumOutputTokens,
                  reservation.chunkSize <= profile.maximumChunkTokens,
                  workers.allSatisfy({ reservation.deadlineUptimeNanoseconds <= $0.lifetimeDeadline }),
                  reservation.promptTokenIDs.count <= profile.maximumContextTokens - reservation.outputCount,
                  (reservation.promptTokenIDs + reservation.stopTokenIDs).allSatisfy({ $0 < profile.vocabularySize }),
                  let a = workers[0].readiness, let b = workers[1].readiness,
                  a.requestCapacityBytes <= ClusterWorkerLimits.capacityBytes - b.requestCapacityBytes,
                  reservation.capacityLimitBytes <= a.requestCapacityBytes + b.requestCapacityBytes else {
                throw ClusterWorkerOwnerError.unavailable
            }
            let value = ClusterWorkerRequest(owner: self, requestID: requestID, reservation: reservation)
            active = value; admittedCount += 1; requestIDs.insert(requestID); return value
        }
        do { try lease.admit(until: admissionDeadline); return lease }
        catch {
            invalidate(); lease.cancel(reason: .runtimeError)
            // Provider reserve must not throw with a reservation left behind.
            // Internal IO/watchdog queues continue independently while this caller
            // waits for actual cleanup or process exit; no timeout releases state.
            lease.waitForRetirement(); lease.releaseResources(); throw error
        }
    }

    func release(_ lease: ClusterWorkerRequest) {
        lock.withLock { if active === lease { active = nil } }
    }

    public func shutdown() async {
        let first = lock.withLock { () -> (Bool, ClusterWorkerRequest?) in
            if stopping { return (false, nil) }; stopping = true; return (true, active)
        }
        guard first.0 else { await shutdownFinished.value(); return }
        let lease = first.1
        if let lease { lease.cancel(reason: .callerCancelled); await lease.waitUntilRetired(); lease.releaseResources() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask {
                    if !worker.observedExit {
                        do {
                            try worker.send(.shutdown, requestID: nil, deadline: deadline)
                            let event = try worker.next(until: deadline)
                            guard event.requestID == nil, event.event == .shutdownComplete else { throw ClusterWorkerOwnerError.closed }
                        } catch { worker.fence() }
                        // A shutdown message is not a process fence. Bound its grace.
                        DispatchQueue.global().asyncAfter(deadline: .init(uptimeNanoseconds: deadline)) { worker.fence() }
                    }
                    await worker.waitUntilExited()
                }
            }
        }
        shutdownFinished.complete()
    }
}
