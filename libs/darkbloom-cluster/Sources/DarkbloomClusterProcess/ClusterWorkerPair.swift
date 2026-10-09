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

/// How long a pair's owner waits for a rank to answer. Neither wait ends in a
/// signal: when one passes, the rank's command stream is closed and the rank
/// ends itself. The caller chooses the values for the model its ranks hold.
public struct ClusterWorkerPairTiming: Sendable, Equatable {
    /// Longest a rank may take to answer a reservation.
    public let admissionWaitNanoseconds: UInt64
    /// Longest a rank may take to answer `shutdown`.
    public let shutdownAcknowledgementNanoseconds: UInt64

    public init(admissionWaitNanoseconds: UInt64, shutdownAcknowledgementNanoseconds: UInt64) {
        self.admissionWaitNanoseconds = admissionWaitNanoseconds
        self.shutdownAcknowledgementNanoseconds = shutdownAcknowledgementNanoseconds
    }

    public static let standard = ClusterWorkerPairTiming(admissionWaitNanoseconds: 5_000_000_000,
                                                         shutdownAcknowledgementNanoseconds: 2_000_000_000)
    /// No wait is absent and none outlasts a minute.
    static let longestWaitNanoseconds: UInt64 = 60_000_000_000
    var isWithinLimits: Bool {
        [admissionWaitNanoseconds, shutdownAcknowledgementNanoseconds].allSatisfy { (1...Self.longestWaitNanoseconds).contains($0) }
    }
}

/// Coordinates two owned native endpoints. The direct-child implementation is
/// local; any remote endpoint must authenticate its owner, translate deadlines
/// and retain ownership until actual native cleanup is acknowledged.
public final class ClusterWorkerPair: @unchecked Sendable {
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    public let maximumRequests: Int
    public let timing: ClusterWorkerPairTiming
    let workers: [any ClusterWorkerEndpoint]
    private let lock = NSLock()
    private var active: ClusterWorkerRequest?
    private var invalid = false
    private var stopping = false
    private var draining = false
    private var activeReleased: WorkerCompletion?
    private let shutdownFinished = WorkerCompletion()
    private var handler: (@Sendable () -> Void)?
    private var notificationSent = false
    private let notifications = DispatchQueue(label: "darkbloom.worker-pair.invalidation")
    private var admittedCount = 0
    private var requestIDs = Set<UUID>()
    /// Same-Mac absolute ceiling only. A remote endpoint must translate a
    /// remaining duration against its own lifetime, never forward this uptime.
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 {
        min(workers[0].localLifetimeDeadlineUptimeNanoseconds, workers[1].localLifetimeDeadlineUptimeNanoseconds)
    }
    public var readiness: ClusterWorkerPairReadiness? {
        lock.withLock {
            guard !invalid && !stopping && (!draining || active != nil) && (admittedCount < maximumRequests || active != nil)
                && DispatchTime.now().uptimeNanoseconds < localLifetimeDeadlineUptimeNanoseconds, let a = workers[0].readiness, let b = workers[1].readiness else { return nil }
            let sum = a.requestCapacityBytes.addingReportingOverflow(b.requestCapacityBytes)
            guard !sum.overflow, sum.partialValue <= ClusterWorkerLimits.capacityBytes else { return nil }
            return .init(identity: identity, profile: profile, executionPlanSHA256: executionPlanSHA256,
                requestCapacityBytes: sum.partialValue)
        }
    }

    public init(workers: [any ClusterWorkerEndpoint], startupDeadline: UInt64,
                maximumRequests: Int = ClusterWorkerLimits.requestsPerEpoch,
                timing: ClusterWorkerPairTiming = .standard) throws {
        guard timing.isWithinLimits else {
            throw ClusterWorkerOwnerError.invalid("Pair waits must be between one nanosecond and one minute")
        }
        guard (1...ClusterWorkerLimits.requestsPerEpoch).contains(maximumRequests), workers.count == 2, workers[0] !== workers[1], workers.map(\.rank) == [0, 1],
              workers[0].expectedIdentity == workers[1].expectedIdentity,
              workers[0].expectedProfile == workers[1].expectedProfile,
              workers[0].executionPlanSHA256 == workers[1].executionPlanSHA256 else {
            throw ClusterWorkerOwnerError.invalid("Expected two ordered workers with one identity/profile/plan")
        }
        self.maximumRequests = maximumRequests; self.timing = timing
        self.workers = workers; identity = workers[0].expectedIdentity; profile = workers[0].expectedProfile
        executionPlanSHA256 = workers[0].executionPlanSHA256
        do { try Self.awaitReadiness(of: workers, until: startupDeadline) }
        catch { for worker in workers { worker.requestNativeCleanup() }; throw error }
        for worker in workers { worker.setInvalidationHandler { [weak self] in self?.invalidate() } }
    }

    /// Both ranks are watched at once. A rank that fails or exits while its peer
    /// is still loading ends the wait for both; nothing waits out the startup
    /// deadline on a peer that can no longer become a pair.
    private static func awaitReadiness(of workers: [any ClusterWorkerEndpoint], until deadline: UInt64) throws {
        let watch = ReadinessWatch(), finished = DispatchGroup()
        for worker in workers {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do {
                    let first = try worker.receiveWorkerEvent(until: deadline, cancelled: { watch.failed })
                    guard case .ready = first.event, first.requestID == nil else { throw ClusterWorkerOwnerError.unavailable }
                } catch { watch.record(error) }
            }
        }
        finished.wait() // Each receive is bounded by the startup deadline.
        if let error = watch.failure { throw error }
    }

    /// Keeps the first rank's own failure; the peer's induced cancellation is not it.
    private final class ReadinessWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Error?
        var failed: Bool { lock.withLock { first != nil } }
        var failure: Error? { lock.withLock { first } }
        func record(_ error: Error) { lock.withLock { if first == nil { first = error } } }
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
            guard !invalid && !stopping && !draining && active == nil, admittedCount < maximumRequests, !requestIDs.contains(requestID),
                  reservation.profileID == profile.id,
                  reservation.promptTokenIDs.count <= profile.maximumPromptTokens,
                  reservation.outputCount <= profile.maximumOutputTokens,
                  reservation.chunkSize <= profile.maximumChunkTokens,
                  workers.allSatisfy({ reservation.deadlineUptimeNanoseconds <= $0.localLifetimeDeadlineUptimeNanoseconds }),
                  reservation.promptTokenIDs.count <= profile.maximumContextTokens - reservation.outputCount,
                  (reservation.promptTokenIDs + reservation.stopTokenIDs).allSatisfy({ $0 < profile.vocabularySize }),
                  let a = workers[0].readiness, let b = workers[1].readiness,
                  a.requestCapacityBytes <= ClusterWorkerLimits.capacityBytes - b.requestCapacityBytes,
                  reservation.capacityLimitBytes <= a.requestCapacityBytes + b.requestCapacityBytes else {
                throw ClusterWorkerOwnerError.unavailable
            }
            let value = ClusterWorkerRequest(owner: self, requestID: requestID, reservation: reservation)
            active = value; activeReleased = WorkerCompletion(); admittedCount += 1; requestIDs.insert(requestID); return value
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
        let completion = lock.withLock { () -> WorkerCompletion? in
            guard active === lease else { return nil }
            active = nil; let value = activeReleased; activeReleased = nil; return value
        }
        completion?.complete()
    }

    /// This snapshot reports policy/admission state, not an estimate of how
    /// long a particular prompt or output will take.
    public var admissionState: ClusterWorkerPairAdmissionState {
        lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            let deadline = localLifetimeDeadlineUptimeNanoseconds
            return .init(remainingLifetimeNanoseconds: deadline > now ? deadline - now : 0,
                admissionsRemaining: max(0, maximumRequests - admittedCount),
                hasActiveRequest: active != nil, isDraining: draining || stopping,
                isValid: !invalid && !stopping && !draining)
        }
    }

    /// Stops new reservations atomically with the normal reserve guard. It does
    /// not cancel the current request or treat retirement as resource release.
    public func stopAcceptingRequests() { lock.withLock { draining = true } }

    public func drainAndShutdown() async {
        let completion = lock.withLock { draining = true; return activeReleased }
        if let completion { await completion.value() }
        await shutdown()
    }

    public func shutdown() async {
        let first = lock.withLock { () -> (Bool, ClusterWorkerRequest?) in
            if stopping { return (false, nil) }; stopping = true; return (true, active)
        }
        guard first.0 else { await shutdownFinished.value(); return }
        let lease = first.1
        if let lease { lease.cancel(reason: .callerCancelled); await lease.waitUntilRetired(); lease.releaseResources() }
        let deadline = DispatchTime.now().uptimeNanoseconds + timing.shutdownAcknowledgementNanoseconds
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask {
                    if !worker.nativeCleanupObserved {
                        do {
                            try worker.sendWorkerCommand(.shutdown, requestID: nil, deadline: deadline)
                            let event = try worker.receiveWorkerEvent(until: deadline)
                            guard event.requestID == nil, event.event == .shutdownComplete else { throw ClusterWorkerOwnerError.closed }
                        } catch { worker.requestNativeCleanup() }
                        // A shutdown message may go unanswered. After its grace the
                        // endpoint is fenced: its command stream closes and the
                        // worker ends itself. No signal follows from this timer.
                        DispatchQueue.global().asyncAfter(deadline: .init(uptimeNanoseconds: deadline)) { worker.requestNativeCleanup() }
                    }
                    await worker.waitUntilNativeCleanup()
                }
            }
        }
        shutdownFinished.complete()
    }
}
