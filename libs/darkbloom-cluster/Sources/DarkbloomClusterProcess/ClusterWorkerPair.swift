import Foundation
import DarkbloomClusterProtocol

public enum ClusterWorkerRequestEvent: Sendable {
    case token(Int), finished(ClusterWorkerFinishReason), failed(String)
    /// Both ranks restored `reused` prompt tokens from their prefix caches and
    /// both now hold `stored` frontiers of this prompt. Delivered once, just
    /// before `finished`, only when either is not empty.
    case promptCache(reused: Int, stored: [Int])
    /// What each rank measured of the request (hand-off, MTP acceptance).
    /// Delivered once, just before `finished`, only when either rank sent any.
    case telemetry(rank0: ClusterWorkerRequestTelemetry?, rank1: ClusterWorkerRequestTelemetry?)
}

public struct ClusterWorkerPairReadiness: Sendable {
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    /// Sum of named local request allowances, never a sum of physical RAM.
    public let requestCapacityBytes: Int
    /// The data plane both ranks report (S16): present only when both report
    /// the same encrypted, peer-verified session (one transcript, one edge).
    /// Nil when both ranks run without a credential.
    public let dataPlane: ClusterWorkerDataPlane?
    /// What a public route may require (decision D1 / S20): every transfer
    /// between the ranks encrypted and authenticated, each peer verified
    /// against its pin.
    public var encryptedDataPlane: Bool { dataPlane?.protection == ClusterWorkerDataPlane.encrypted }
    public var peerVerified: Bool { dataPlane?.encryptedAndVerified == true }
    /// The longest context (prompt plus output) both ranks' host memory gates
    /// admit now (`ClusterWorkerPair.servingContextTokens`); a request longer
    /// than this is refused before either rank is asked.
    public let servingContextTokens: Int
}

/// How long a pair's owner waits for a rank to answer. None of these waits
/// ends in a signal: when one passes, the rank's command stream is closed and
/// the rank ends itself. The caller chooses the values for the model its ranks hold.
public struct ClusterWorkerPairTiming: Sendable, Equatable {
    /// Longest a rank may take to answer a reservation.
    public let admissionWaitNanoseconds: UInt64
    /// Longest a rank may take to answer `shutdown`.
    public let shutdownAcknowledgementNanoseconds: UInt64
    /// Longest `shutdown` waits for a request that is still running to stop at
    /// its next committed token before it cancels the request. A request that
    /// stops this way leaves both ranks able to answer `shutdown`; a cancelled
    /// one ends them, and a rank still inside a collective then needs its
    /// progress limit. Zero cancels at once.
    public let cleanStopWaitNanoseconds: UInt64

    public init(admissionWaitNanoseconds: UInt64, shutdownAcknowledgementNanoseconds: UInt64,
                cleanStopWaitNanoseconds: UInt64 = 0) {
        self.admissionWaitNanoseconds = admissionWaitNanoseconds
        self.shutdownAcknowledgementNanoseconds = shutdownAcknowledgementNanoseconds
        self.cleanStopWaitNanoseconds = cleanStopWaitNanoseconds
    }

    public static let standard = ClusterWorkerPairTiming(admissionWaitNanoseconds: 5_000_000_000,
                                                         shutdownAcknowledgementNanoseconds: 2_000_000_000)
    /// No answer wait is absent and no wait outlasts a minute. Public so a
    /// caller that derives its waits keeps them within it.
    public static let longestWaitNanoseconds: UInt64 = 60_000_000_000
    var isWithinLimits: Bool {
        [admissionWaitNanoseconds, shutdownAcknowledgementNanoseconds].allSatisfy { (1...Self.longestWaitNanoseconds).contains($0) }
            && cleanStopWaitNanoseconds <= Self.longestWaitNanoseconds
    }
}

/// Coordinates two owned native endpoints. The direct-child implementation is
/// local; any remote endpoint must authenticate its owner, translate deadlines
/// and retain ownership until actual native cleanup is acknowledged.
public final class ClusterWorkerPair: @unchecked Sendable {
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    public let timing: ClusterWorkerPairTiming
    public let keepWarm: ClusterWorkerKeepWarmPolicy
    /// Whether a request longer than the serving context is refused before
    /// either rank is asked (the default). Off only to qualify a rank's own
    /// gate refusal at reservation.
    public let refusesAboveServingContext: Bool
    let workers: [any ClusterWorkerEndpoint]
    /// Requests served at once (continuous batching). One keeps the earlier
    /// one-request-at-a-time pair exactly; more need workers launched with as
    /// many batch lanes, and route each worker's events by request.
    public let lanes: Int
    /// The workers retire a cancelled started lane alone (a cancel or a
    /// deadline ends that request, not the pair): GLM tensor parallel's lane
    /// loop. Otherwise any cancel of a started request ends the pair.
    public let lanesRetireAlone: Bool
    private let routers: [ClusterWorkerEventRouter]
    private let lock = NSLock()
    private var active: ClusterWorkerRequest?
    /// With lanes: every reserved or running request, and its release.
    private var laneActive: [UUID: (request: ClusterWorkerRequest, released: WorkerCompletion)] = [:]
    private var hasAnyActive: Bool { active != nil || !laneActive.isEmpty }
    private var invalid = false
    private var stopping = false
    private var draining = false
    private var activeReleased: WorkerCompletion?
    private let shutdownFinished = WorkerCompletion()
    private var handler: (@Sendable () -> Void)?
    private var notificationSent = false
    private let notifications = DispatchQueue(label: "darkbloom.worker-pair.invalidation")
    /// Requests admitted, for diagnostics. Never a limit: a pair has no
    /// request count and no lifetime.
    private var admittedCount = 0
    /// Recent request IDs, to refuse a replay; a window, not a count.
    private var requestIDs = Set<UUID>()
    private var requestOrder: [UUID] = []
    /// A keep-warm exchange is outstanding; no request is reserved meanwhile.
    private var warming = false
    private var keepWarmOrdinal = 0
    private var keepWarmExchanges = 0
    private var lastKeepWarmMicroseconds: Int?
    private var keepWarmTimer: DispatchSourceTimer?
    private let keepWarmQueue = DispatchQueue(label: "darkbloom.worker-pair.keep-warm")
    /// Each rank's latest serving context: from its readiness, then from
    /// every keep-warm answer (a rank re-derives it from its live admissible
    /// memory while idle). Nil for a rank that reports none.
    private var rankServingContext: [Int?] = [nil, nil]
    /// Requests refused before they started (request-scoped), for diagnostics.
    private var refusedCount = 0
    /// The last request that failed on this pair, for the incident the owner
    /// records when the pair stops (S24): the request's public prefix and the
    /// bounded fixed text the owner side derived (never prompt or token text).
    private var lastFailure: String?
    public var lastRequestFailure: String? { lock.withLock { lastFailure } }
    /// The longest a rank may take to answer a reservation or give one back:
    /// the timing's, or with lanes at least a loop step on each rank
    /// (`ClusterWorkerRequest.laneAdmissionWaitNanoseconds`).
    var admissionWaitNanoseconds: UInt64 {
        lanes > 1 ? max(timing.admissionWaitNanoseconds, ClusterWorkerRequest.laneAdmissionWaitNanoseconds)
            : timing.admissionWaitNanoseconds
    }
    func noteRequestFailure(_ lease: ClusterWorkerRequest, _ cause: String) {
        let id = lease.requestID.uuidString.lowercased().prefix(8)
        lock.withLock { lastFailure = "request \(id) failed on the pair: \(cause)" }
    }
    /// The earliest current rank-lease deadline of the two ranks on THIS Mac's
    /// clock: each owner renews its rank's lease while it keeps the pair, so
    /// this moves forward and is never a lifetime.
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 {
        min(workers[0].localLifetimeDeadlineUptimeNanoseconds, workers[1].localLifetimeDeadlineUptimeNanoseconds)
    }
    public var readiness: ClusterWorkerPairReadiness? {
        lock.withLock {
            guard !invalid && !stopping && (!draining || hasAnyActive),
                  let a = workers[0].readiness, let b = workers[1].readiness else { return nil }
            let sum = a.requestCapacityBytes.addingReportingOverflow(b.requestCapacityBytes)
            guard !sum.overflow, sum.partialValue <= ClusterWorkerLimits.capacityBytes else { return nil }
            // One keyed session or none: ranks that disagree are not a pair.
            guard a.dataPlane == b.dataPlane, a.dataPlane.map({ $0.peerVerified }) ?? true else { return nil }
            return .init(identity: identity, profile: profile, executionPlanSHA256: executionPlanSHA256,
                requestCapacityBytes: sum.partialValue, dataPlane: a.dataPlane, servingContextTokens: servingContextLocked)
        }
    }

    /// The longest context (prompt plus output) the pair serves now: the
    /// smaller of what each rank's host memory gate last admitted with its
    /// weights resident (at readiness, then re-derived on every keep-warm
    /// exchange while idle), never more than the profile's maximum. A request
    /// above it is refused before either rank is asked
    /// (`ClusterWorkerOwnerError.refused(.capacity)`); one within it can still
    /// be refused by a rank's live gate at reservation, for that request alone.
    public var servingContextTokens: Int { lock.withLock { servingContextLocked } }
    private var servingContextLocked: Int {
        rankServingContext.compactMap { $0 }.reduce(profile.maximumContextTokens) { min($0, $1) }
    }
    /// Requests refused before they started since the pair became ready.
    public var requestsRefused: Int { lock.withLock { refusedCount } }

    /// `keepWarm` is explicit at every serving call site: the installed
    /// session and the pair driver pass `.standard` (keep-warm is on by
    /// default in the product); a caller that names nothing gets none.
    public init(workers: [any ClusterWorkerEndpoint], startupDeadline: UInt64,
                timing: ClusterWorkerPairTiming = .standard,
                keepWarm: ClusterWorkerKeepWarmPolicy = .off, refusesAboveServingContext: Bool = true, lanes: Int = 1,
                lanesRetireAlone: Bool = false) throws {
        self.refusesAboveServingContext = refusesAboveServingContext
        guard timing.isWithinLimits else {
            throw ClusterWorkerOwnerError.invalid("Pair waits must be between one nanosecond and one minute")
        }
        guard (1...8).contains(lanes) else { throw ClusterWorkerOwnerError.invalid("A pair serves 1...8 lanes") }
        self.lanes = lanes; self.lanesRetireAlone = lanes > 1 && lanesRetireAlone
        routers = workers.map { ClusterWorkerEventRouter(endpoint: $0) }
        guard workers.count == 2, workers[0] !== workers[1], workers.map(\.rank) == [0, 1],
              workers[0].expectedIdentity == workers[1].expectedIdentity,
              workers[0].expectedProfile == workers[1].expectedProfile,
              workers[0].executionPlanSHA256 == workers[1].executionPlanSHA256 else {
            throw ClusterWorkerOwnerError.invalid("Expected two ordered workers with one identity/profile/plan")
        }
        self.timing = timing; self.keepWarm = keepWarm
        self.workers = workers; identity = workers[0].expectedIdentity; profile = workers[0].expectedProfile
        executionPlanSHA256 = workers[0].executionPlanSHA256
        do { try Self.awaitReadiness(of: workers, until: startupDeadline) }
        catch { for worker in workers { worker.requestNativeCleanup() }; throw error }
        rankServingContext = workers.map { $0.readiness?.servingContextTokens }
        for worker in workers { worker.setInvalidationHandler { [weak self] in self?.invalidate() } }
        if keepWarm.enabled { startKeepWarm() }
    }

    deinit { keepWarmTimer?.cancel() }

    // MARK: Keep-warm tier 2

    private func startKeepWarm() {
        let timer = DispatchSource.makeTimerSource(queue: keepWarmQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(keepWarm.dataPlaneIntervalNanoseconds)),
                       repeating: .nanoseconds(Int(keepWarm.dataPlaneIntervalNanoseconds)))
        timer.setEventHandler { [weak self] in self?.keepWarmTick() }
        lock.withLock { keepWarmTimer = timer }
        timer.resume()
    }

    /// One exchange when the pair is valid and idle. Exclusive with requests:
    /// `reserve` waits while it is outstanding, and it never starts while a
    /// request is reserved or running. A failure invalidates the pair.
    private func keepWarmTick() {
        let ordinal = lock.withLock { () -> Int? in
            guard !invalid, !stopping, !draining, !hasAnyActive, !warming,
                  workers[0].readiness != nil, workers[1].readiness != nil,
                  keepWarmOrdinal + 1 < ClusterWorkerLimits.keepWarmOrdinals else { return nil }
            warming = true; keepWarmOrdinal += 1; return keepWarmOrdinal
        }
        guard let ordinal else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + keepWarm.answerNanoseconds
        var longest = 0, failed = false
        var serving: [Int?] = [nil, nil]
        do {
            for worker in workers { try worker.sendWorkerCommand(.keepWarm(ordinal: ordinal), requestID: nil, deadline: deadline) }
            for index in workers.indices {
                // Routed with lanes: the routers own each worker's event stream.
                let event = try receive(rank: index, requestID: nil, until: deadline)
                guard event.requestID == nil, case .keptWarm(let answered, let microseconds, let context) = event.event,
                      answered == ordinal else {
                    throw ClusterWorkerOwnerError.invalid("Keep-warm was answered with another event")
                }
                longest = max(longest, microseconds); serving[index] = context
            }
        } catch { failed = true }
        lock.withLock {
            warming = false
            if !failed {
                keepWarmExchanges += 1; lastKeepWarmMicroseconds = longest
                // A rank that re-derived its serving context reports it here.
                for index in 0..<2 where serving[index] != nil { rankServingContext[index] = serving[index] }
            }
        }
        if failed {
            // Any failure of the data plane while idle is a failed pair: its
            // owner shuts it down cleanly rather than serve on a broken link.
            invalidate()
        }
    }

    /// Waits, bounded, for an outstanding keep-warm exchange to finish.
    private func awaitKeepWarmIdle(until deadline: UInt64) {
        while lock.withLock({ warming }) && DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
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
        let values = lock.withLock { () -> ([ClusterWorkerRequest], (@Sendable () -> Void)?) in
            if invalid { return ([], nil) }; invalid = true
            return ((active.map { [$0] } ?? []) + laneActive.values.map(\.request), notificationLocked())
        }
        values.0.forEach { $0.cancel(reason: .peerFailure) }
        if let notify = values.1 { notifications.async(execute: notify) }
    }

    /// The next event of `requestID` from one rank. With one lane this is the
    /// worker's own stream, as it always was; with lanes it is routed.
    func receive(rank: Int, requestID: UUID?, until deadline: UInt64,
                 cancelled: () -> Bool = { false }) throws -> ClusterWorkerEventFrame {
        if lanes == 1 { return try workers[rank].receiveWorkerEvent(until: deadline, cancelled: cancelled) }
        return try routers[rank].receive(for: requestID, until: deadline, cancelled: cancelled)
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
        // A keep-warm exchange takes milliseconds; a request waits it out.
        awaitKeepWarmIdle(until: min(admissionDeadline ?? UInt64.max,
            DispatchTime.now().uptimeNanoseconds + keepWarm.answerNanoseconds))
        let lease = try lock.withLock { () -> ClusterWorkerRequest in
            guard !invalid && !stopping && !draining, lanes == 1 ? active == nil : laneActive.count < lanes,
                  !warming, !requestIDs.contains(requestID),
                  reservation.profileID == profile.id,
                  reservation.promptTokenIDs.count <= profile.maximumPromptTokens,
                  reservation.outputCount <= profile.maximumOutputTokens,
                  reservation.chunkSize <= profile.maximumChunkTokens,
                  reservation.deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds,
                  reservation.deadlineUptimeNanoseconds - DispatchTime.now().uptimeNanoseconds <= ClusterWorkerLimits.deadlineNanoseconds,
                  reservation.promptTokenIDs.count <= profile.maximumContextTokens - reservation.outputCount,
                  (reservation.promptTokenIDs + reservation.stopTokenIDs).allSatisfy({ $0 < profile.vocabularySize }),
                  let a = workers[0].readiness, let b = workers[1].readiness,
                  a.requestCapacityBytes <= ClusterWorkerLimits.capacityBytes - b.requestCapacityBytes,
                  reservation.capacityLimitBytes <= a.requestCapacityBytes + b.requestCapacityBytes else {
                throw ClusterWorkerOwnerError.unavailable
            }
            // Longer than a rank's gate admits now: refused up front, for this
            // request alone; neither rank is asked and the pair stays as it is.
            guard !refusesAboveServingContext
                    || reservation.promptTokenIDs.count + reservation.outputCount <= servingContextLocked else {
                refusedCount += 1
                throw ClusterWorkerOwnerError.refused(.capacity)
            }
            let value = ClusterWorkerRequest(owner: self, requestID: requestID, reservation: reservation)
            if lanes == 1 { active = value; activeReleased = WorkerCompletion() }
            else { laneActive[requestID] = (value, WorkerCompletion()) }
            admittedCount += 1
            requestIDs.insert(requestID); requestOrder.append(requestID)
            if requestOrder.count > ClusterWorkerLimits.requestReplayWindow { requestIDs.remove(requestOrder.removeFirst()) }
            return value
        }
        do { try lease.admit(until: admissionDeadline); return lease }
        catch ClusterWorkerOwnerError.refused(let reason)
            where lease.withdrawRefused(until: DispatchTime.now().uptimeNanoseconds + admissionWaitNanoseconds) {
            // A rank refused this request (its live gate, its deadline or its
            // profile) and every rank that had admitted it gave it back. Only
            // this request failed: the pair is valid and idle again.
            lease.releaseResources()
            lock.withLock { refusedCount += 1 }
            throw ClusterWorkerOwnerError.refused(reason)
        } catch {
            // Named for the pair's incident (S24), as a started request's failure is.
            noteRequestFailure(lease, "admission: " + ClusterWorkerRequest.failureText(error))
            invalidate(); lease.cancel(reason: .runtimeError)
            // A refusal whose reservation could not be given back on every
            // rank ends the pair like any other failure; say so to the caller.
            let failure: Error = (error as? ClusterWorkerOwnerError).map {
                if case .refused = $0 { return ClusterWorkerOwnerError.unavailable }; return $0
            } ?? error
            // Provider reserve must not throw with a reservation left behind.
            // Internal IO/watchdog queues continue independently while this caller
            // waits for actual cleanup or process exit; no timeout releases state.
            lease.waitForRetirement(); lease.releaseResources(); throw failure
        }
    }

    func release(_ lease: ClusterWorkerRequest) {
        let completion = lock.withLock { () -> WorkerCompletion? in
            if lanes > 1 {
                guard let entry = laneActive[lease.requestID], entry.request === lease else { return nil }
                laneActive[lease.requestID] = nil; return entry.released
            }
            guard active === lease else { return nil }
            active = nil; let value = activeReleased; activeReleased = nil; return value
        }
        completion?.complete()
    }

    /// This snapshot reports policy/admission state, not an estimate of how
    /// long a particular prompt or output will take.
    public var admissionState: ClusterWorkerPairAdmissionState {
        lock.withLock {
            .init(requestsServed: admittedCount, hasActiveRequest: lanes == 1 ? active != nil : laneActive.count >= lanes,
                isDraining: draining || stopping,
                isValid: !invalid && !stopping && !draining, keepWarmExchanges: keepWarmExchanges,
                lastKeepWarmMicroseconds: lastKeepWarmMicroseconds,
                activeRequests: lanes == 1 ? (active == nil ? 0 : 1) : laneActive.count, lanes: lanes)
        }
    }

    /// Stops new reservations atomically with the normal reserve guard. It does
    /// not cancel the current request or treat retirement as resource release.
    public func stopAcceptingRequests() { lock.withLock { draining = true } }

    public func drainAndShutdown() async {
        let completions = lock.withLock { () -> [WorkerCompletion] in
            draining = true; return (activeReleased.map { [$0] } ?? []) + laneActive.values.map(\.released)
        }
        for completion in completions { await completion.value() }
        await shutdown()
    }

    public func shutdown() async {
        let first = lock.withLock { () -> (Bool, [ClusterWorkerRequest]) in
            if stopping { return (false, []) }; stopping = true
            return (true, (active.map { [$0] } ?? []) + laneActive.values.map(\.request))
        }
        guard first.0 else { await shutdownFinished.value(); return }
        lock.withLock { keepWarmTimer?.cancel(); keepWarmTimer = nil }
        awaitKeepWarmIdle(until: DispatchTime.now().uptimeNanoseconds + keepWarm.answerNanoseconds)
        // A request that is still running is first asked to stop at its next
        // committed token, which leaves both ranks retired and able to answer
        // the shutdown below. Cancelling ends the ranks instead, and is what
        // remains for a request that does not get there in time.
        if timing.cleanStopWaitNanoseconds > 0 {
            let limit = DispatchTime.now().uptimeNanoseconds + timing.cleanStopWaitNanoseconds
            for lease in first.1 where lease.isRunning && lease.requestCleanStop() {
                _ = await lease.waitUntilRetired(until: limit)
            }
        }
        for lease in first.1 {
            lease.cancel(reason: .callerCancelled); await lease.waitUntilRetired(); lease.releaseResources()
        }
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
