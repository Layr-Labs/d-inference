import Foundation
import DarkbloomClusterProtocol

public final class ClusterWorkerRequest: @unchecked Sendable {
    public let requestID: UUID
    public let reservation: ClusterWorkerReservation
    private let owner: ClusterWorkerPair
    private let lock = NSLock()
    private let retired = WorkerCompletion()
    private let queue = DispatchQueue(label: "darkbloom.worker.request")
    private var started = false
    /// True once the caller started the request (`start`): before that no
    /// rank ran anything for it, so a cancel gives its reservations back.
    private var begun = false
    /// True when cleanup had to fence a rank (no clean answer in time).
    private var fencedRank = false
    private var admitted = false
    private var admitting = true
    private var released = false
    private var cancellation: ClusterWorkerCancellationReason?
    private var cleanStopRequested = false
    private var byteReservation = 0
    private enum Submission { case none, submitted, admitted, refused }
    private var submissions: [Submission] = [.none, .none]
    private var callback: (@Sendable (ClusterWorkerRequestEvent) -> Bool)?
    public var reservedBytes: Int { lock.withLock { byteReservation } }
    public var bytesInUse: Int { lock.withLock { released ? 0 : byteReservation } }
    public var isRetired: Bool { retired.isComplete }
    private var isCancelled: Bool { lock.withLock { cancellation != nil } }

    init(owner: ClusterWorkerPair, requestID: UUID, reservation: ClusterWorkerReservation) {
        self.owner = owner; self.requestID = requestID; self.reservation = reservation
        byteReservation = reservation.capacityLimitBytes
    }

    func admit(until admissionDeadline: UInt64? = nil) throws {
        defer {
            let cleanup = lock.withLock { () -> Bool in
                admitting = false
                if cancellation != nil && !started { started = true; return true }; return false
            }
            if cleanup { queue.async { self.cleanup(acknowledged: [false, false]) } }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < reservation.deadlineUptimeNanoseconds,
              reservation.deadlineUptimeNanoseconds - now <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw ClusterWorkerOwnerError.deadline
        }
        let deadline = min(reservation.deadlineUptimeNanoseconds, admissionDeadline ?? UInt64.max,
                           now + owner.admissionWaitNanoseconds)
        guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
        var bytes = 0
        for (index, worker) in owner.workers.enumerated() {
            guard let capacity = worker.readiness?.requestCapacityBytes,
                  bytes < reservation.capacityLimitBytes else { throw ClusterWorkerOwnerError.unavailable }
            let local = ClusterWorkerReservation(profileID: reservation.profileID, promptTokenIDs: reservation.promptTokenIDs,
                stopTokenIDs: reservation.stopTokenIDs, outputCount: reservation.outputCount, chunkSize: reservation.chunkSize,
                deadlineUptimeNanoseconds: reservation.deadlineUptimeNanoseconds,
                capacityLimitBytes: min(capacity, reservation.capacityLimitBytes - bytes),
                // Both ranks get the request's sampling (the selecting rank draws with it) and its route.
                sampling: reservation.sampling, route: reservation.route, mimoImages: reservation.mimoImages, stillImages: reservation.stillImages,
                // GLM media bytes go to rank 0 alone, which runs the vision tower; rank 1 gets their digests.
                glmMedia: index == 0 ? reservation.glmMedia : reservation.glmMedia?.withoutEncodedBytes)
            try lock.withLock {
                guard cancellation == nil else { throw ClusterWorkerOwnerError.cancelled }
                do {
                    try worker.sendWorkerCommand(.reserve(local), requestID: requestID, deadline: deadline)
                } catch ClusterWorkerOwnerError.refused(let reason) where reason != .unavailable {
                    // The rank's endpoint could not take this reservation now
                    // (its command queue) or carry it: nothing reached the
                    // rank. That is this request's refusal, as a rank's own
                    // would be, and the caller gives back what the other rank
                    // admitted (`withdrawRefused`).
                    submissions[index] = .refused
                    throw ClusterWorkerOwnerError.refused(reason)
                } catch is ClusterWorkerProtocolError {
                    // The command could not be encoded for this rank: never sent.
                    submissions[index] = .refused
                    throw ClusterWorkerOwnerError.refused(.profile)
                }
                submissions[index] = .submitted
            }
            let event = try owner.receive(rank: index, requestID: requestID, until: deadline, cancelled: { self.isCancelled })
            guard event.requestID == requestID else { throw ClusterWorkerOwnerError.unavailable }
            if case .refused(let reason) = event.event {
                lock.withLock { submissions[index] = .refused }
                // A rank that says it is unavailable is gone for every request;
                // any other refusal (memory, deadline, profile) is this
                // request's alone, and the caller gives back what the other
                // rank admitted (`withdrawRefused`).
                throw reason == .unavailable ? ClusterWorkerOwnerError.unavailable : ClusterWorkerOwnerError.refused(reason)
            }
            guard case .admitted(let allocation) = event.event,
                  allocation <= local.capacityLimitBytes, allocation <= capacity else {
                throw ClusterWorkerOwnerError.unavailable
            }
            lock.withLock { submissions[index] = .admitted }
            bytes += allocation // Bounded by the remaining global ceiling above.
        }
        try lock.withLock {
            guard cancellation == nil else { throw ClusterWorkerOwnerError.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ClusterWorkerOwnerError.deadline }
            byteReservation = bytes; admitted = true
        }
        // A lane is cancelled early enough to leave both ranks' loops and
        // retire before its deadline, which each rank's owner holds it to.
        let margin = owner.lanesRetireAlone ? Self.laneDeadlineMarginNanoseconds : 0
        let cancelAt = max(DispatchTime.now().uptimeNanoseconds, reservation.deadlineUptimeNanoseconds - min(margin,
            reservation.deadlineUptimeNanoseconds))
        DispatchQueue.global().asyncAfter(deadline: .init(uptimeNanoseconds: cancelAt)) { [weak self] in
            if let self, !self.retired.isComplete { self.cancel(reason: .deadline) }
        }
    }

    /// After a request-scoped refusal (`ClusterWorkerOwnerError.refused`):
    /// every rank that admitted the reservation is told to cancel it and must
    /// answer with its own `retired(cancelled)` before `deadline`; nothing was
    /// started, so no rank ran a forward or touched the data plane. True when
    /// every admitted rank gave its reservation back (the request is then
    /// retired and the pair keeps serving); false when any did not, and the
    /// caller must then quarantine the pair as for any other failure.
    func withdrawRefused(until deadline: UInt64) -> Bool {
        let state = lock.withLock { () -> (submitted: [Submission], clean: Bool) in
            (submissions, cancellation == nil && !started && !admitted)
        }
        guard state.clean, state.submitted.contains(.refused),
              state.submitted.allSatisfy({ $0 == .admitted || $0 == .refused || $0 == .none }) else { return false }
        for index in 0..<2 where state.submitted[index] == .admitted {
            do {
                try owner.workers[index].sendWorkerCommand(.cancel(.callerCancelled), requestID: requestID, deadline: deadline)
                // Routed with lanes: another lane's events stay with that lane.
                let value = try owner.receive(rank: index, requestID: requestID, until: deadline)
                guard value.requestID == requestID, value.event == .retired(.cancelled) else { return false }
            } catch { return false }
        }
        lock.withLock { started = true; released = false; byteReservation = 0 }
        retired.complete()
        return true
    }

    public func start(emit: @escaping @Sendable (ClusterWorkerRequestEvent) -> Bool) throws {
        try lock.withLock {
            guard admitted && !started && cancellation == nil && !released else { throw ClusterWorkerOwnerError.unavailable }
            callback = emit; started = true; begun = true
        }
        queue.async { self.run() }
    }

    public func cancel(reason: ClusterWorkerCancellationReason = .callerCancelled) {
        let action = lock.withLock { () -> (run: Bool, first: Bool, begun: Bool) in
            if retired.isComplete { return (false, false, begun) }
            let first = cancellation == nil
            cancellation = cancellation ?? reason
            if started || admitting { return (false, first, begun) }; started = true; return (true, first, begun)
        }
        if action.run { queue.async { self.cleanup(acknowledged: [false, false]) } }
        guard action.first else { return }
        // With lanes, a request its caller cancels or whose deadline passed
        // leaves both ranks at their next step boundary, and each answers
        // `retired(cancelled)`: the other lanes and the pair go on. `cleanup`
        // (run by the request's own loop, or above) waits for both answers
        // and fences a rank only when its answer does not come in time; the
        // watchdog below, later than that wait, covers a loop that never got
        // there (a consumer callback that does not return).
        let alone = retiresAlone(reason, begun: action.begun)
        // Cancellation cannot rely on a responsive callback or native receive.
        // The watchdog is independent of the request queue and observes real exit.
        // Its fence closes each worker's command stream; a worker still inside
        // a collective ends itself at its own progress limit or deadline, and
        // the wait below lasts until that exit is actually observed.
        let watchdog: DispatchTimeInterval = alone
            ? .nanoseconds(Int(Self.laneRetirementWaitNanoseconds + 10_000_000_000)) : .seconds(2)
        DispatchQueue.global().asyncAfter(deadline: .now() + watchdog) { [weak self] in
            guard let self, !self.retired.isComplete else { return }
            if alone { self.owner.invalidate() }
            for worker in self.owner.workers { worker.requestNativeCleanup() }
            // Even a stuck consumer callback cannot prevent independently observed
            // process fences from satisfying native ownership retirement.
            DispatchQueue.global().async {
                for worker in self.owner.workers { worker.waitForNativeCleanup() }
                self.retired.complete()
            }
        }
        if !alone { owner.invalidate() }
    }

    /// A lane (the pair serves several requests at once and its workers
    /// retire lanes alone) cancelled by its caller or its deadline retires
    /// alone, and so does any request its caller or its deadline cancels
    /// before it was started (`begun` false): no rank ran anything for it, a
    /// rank that admitted it gives its reservation back (`retired(cancelled)`)
    /// and a rank that was never asked has nothing to give back. Any other
    /// cause (a rank's failure, a protocol violation, a peer that is gone)
    /// ends the pair.
    private func retiresAlone(_ reason: ClusterWorkerCancellationReason, begun: Bool) -> Bool {
        (owner.lanesRetireAlone || !begun) && (reason == .callerCancelled || reason == .deadline)
    }

    /// The request was cancelled by its caller or its deadline before it was
    /// started, and every rank gave back what it held (or was never asked):
    /// only this request ended, and the pair serves on.
    public var withdrewBeforeStart: Bool {
        lock.withLock {
            retired.isComplete && !begun && !fencedRank
                && cancellation.map({ $0 == .callerCancelled || $0 == .deadline }) == true
        }
    }

    /// The longest `cleanup` waits for a rank's retirement before fencing it:
    /// a lane leaves at its loop's next step boundary, after the step that
    /// runs (at most one bulk prefill frame and every lane's decode unit).
    static let laneRetirementWaitNanoseconds: UInt64 = 30_000_000_000
    /// The longest a lane's reservation (or its withdrawal) may take: each
    /// rank answers at its loop's next step boundary, after at most one
    /// prefill frame and every lane's decode unit, and the ranks are asked in
    /// turn.
    static let laneAdmissionWaitNanoseconds: UInt64 = 30_000_000_000

    /// How long before its deadline a lane is cancelled: one loop step (a
    /// bulk prefill frame and every lane's decode unit) and the cancel's way
    /// to the other Mac fit well inside it.
    static let laneDeadlineMarginNanoseconds: UInt64 = 20_000_000_000

    /// Ends the request the way a client stop does, without giving up the pair:
    /// the next committed token is answered with the protocol's clean stop, both
    /// ranks retire and the pair can take another request. For a consumer that
    /// went away and for an owner that is stopping. Nothing is fenced and no
    /// time limit is set here: the request's own deadline still applies, and a
    /// caller that cannot wait calls `cancel`, which ends the ranks.
    ///
    /// A request that has produced no token yet stops at its first one. False
    /// when the request can no longer stop this way (cancelled, or retired).
    @discardableResult public func requestCleanStop() -> Bool {
        lock.withLock {
            guard cancellation == nil, !retired.isComplete else { return false }
            cleanStopRequested = true; return true
        }
    }
    /// True once `requestCleanStop` was accepted.
    public var cleanStopWasRequested: Bool { lock.withLock { cleanStopRequested } }
    /// Why the request was cancelled first, if it was.
    public var cancellationReason: ClusterWorkerCancellationReason? { lock.withLock { cancellation } }
    /// True once the ranks were told to start: only then can a token arrive.
    var isRunning: Bool { lock.withLock { started && cancellation == nil } }

    public func waitUntilRetired() async { await retired.value() }
    /// False when the request has not retired by `deadline`; it keeps running.
    func waitUntilRetired(until deadline: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.retired.wait(until: deadline)) }
        }
    }
    public func releaseResources() {
        let release = lock.withLock { () -> Bool in
            guard retired.isComplete && !released else { return false }; released = true; return true
        }
        if release { owner.release(self) }
    }
    func waitForRetirement() { retired.wait() }

    private func event(_ rank: Int) throws -> ClusterWorkerEvent {
        let value = try owner.receive(rank: rank, requestID: requestID, until: reservation.deadlineUptimeNanoseconds,
            cancelled: { self.isCancelled })
        guard value.requestID == requestID else { throw ClusterWorkerOwnerError.invalid("Stale worker request event") }
        return value.event
    }

    private func run() {
        var acknowledged = [false, false]
        do {
            try lock.withLock {
                guard cancellation == nil else { throw ClusterWorkerOwnerError.cancelled }
                // Enqueue is bounded/nonblocking. Linearize both start commands
                // against cancellation without holding a lock across native IO.
                for worker in owner.workers { try worker.sendWorkerCommand(.start, requestID: requestID, deadline: reservation.deadlineUptimeNanoseconds) }
            }
            var count = 0, last: Int?, cleanStop = false
            var finish: ClusterWorkerFinishReason?
            var cacheReport: (reused: Int, stored: [Int])?
            var telemetry: ClusterWorkerRequestTelemetry?
            while finish == nil {
                let value = try event(0)
                switch value {
                case .committedToken(let ordinal, let token, let committed, let logprobs):
                    guard !cleanStop, ordinal == count, count < reservation.outputCount,
                          committed == reservation.promptTokenIDs.count + ordinal, token < owner.profile.vocabularySize,
                          last.map({ !reservation.stopTokenIDs.contains($0) }) ?? true,
                          logprobs?.top.count == reservation.sampling?.capturedLogprobs else {
                        throw ClusterWorkerOwnerError.invalid("Unexpected committed worker token")
                    }
                    count += 1; last = token
                    let emit = lock.withLock { callback }
                    // The token is committed on both ranks and is delivered even
                    // when a clean stop was requested meanwhile; the stop is the
                    // answer to it.
                    let wanted = emit?(.token(token, logprobs)) ?? false
                    if isCancelled { throw ClusterWorkerOwnerError.cancelled }
                    let keepGoing = wanted && !cleanStopWasRequested
                    cleanStop = !keepGoing
                    try owner.workers[0].sendWorkerCommand(.tokenDecision(ordinal: ordinal, decision: keepGoing ? .proceed : .cleanStop),
                        requestID: requestID, deadline: reservation.deadlineUptimeNanoseconds)
                case .promptCache(let reused, let stored):
                    guard count > 0, cacheReport == nil, reused < reservation.promptTokenIDs.count,
                          stored.allSatisfy({ $0 < reservation.promptTokenIDs.count }) else {
                        throw ClusterWorkerOwnerError.invalid("Unexpected prompt cache report")
                    }
                    cacheReport = (reused, stored)
                case .requestTelemetry(let value):
                    guard count > 0, telemetry == nil else { throw ClusterWorkerOwnerError.invalid("Unexpected request telemetry") }
                    telemetry = value
                case .finished(let reason):
                    guard count > 0, let last else { throw ClusterWorkerOwnerError.invalid("Finish precedes committed token") }
                    let expected: ClusterWorkerFinishReason? = reservation.stopTokenIDs.contains(last) ? .eos
                        : count == reservation.outputCount ? .length : cleanStop ? .clientStop : nil
                    guard reason == expected else { throw ClusterWorkerOwnerError.invalid("Worker clean finish differs") }
                    finish = reason
                case .failed(let reason):
                    throw ClusterWorkerOwnerError.invalid("Rank 0 reported failure: \(reason.rawValue)")
                case .unavailable(let reason):
                    throw ClusterWorkerOwnerError.invalid("Rank 0 became unavailable: \(reason.rawValue)")
                default: throw ClusterWorkerOwnerError.invalid("Rank 0 emitted an unexpected request event: \(String(describing: value).prefix(80))")
                }
                guard DispatchTime.now().uptimeNanoseconds < reservation.deadlineUptimeNanoseconds else { throw ClusterWorkerOwnerError.deadline }
            }
            guard try event(0) == .retired(.clean) else { throw ClusterWorkerOwnerError.invalid("Rank 0 lacks local retirement") }
            acknowledged[0] = true
            // Rank 1 restored exactly what rank 0 did, or neither did. What
            // both hold is what both stored.
            var next = try event(1), peerReport: (reused: Int, stored: [Int])?
            if case .promptCache(let reused, let stored) = next { peerReport = (reused, stored); next = try event(1) }
            var peerTelemetry: ClusterWorkerRequestTelemetry?
            if case .requestTelemetry(let value) = next { peerTelemetry = value; next = try event(1) }
            guard (cacheReport?.reused ?? 0) == (peerReport?.reused ?? 0) else {
                throw ClusterWorkerOwnerError.invalid("Ranks reused different prompt prefixes")
            }
            let bothStored = Set(cacheReport?.stored ?? []).intersection(peerReport?.stored ?? []).sorted()
            if case .failed(let reason) = next { throw ClusterWorkerOwnerError.invalid("Rank 1 reported failure: \(reason.rawValue)") }
            if case .unavailable(let reason) = next { throw ClusterWorkerOwnerError.invalid("Rank 1 became unavailable: \(reason.rawValue)") }
            guard next == .finished(finish!), try event(1) == .retired(.clean) else {
                throw ClusterWorkerOwnerError.invalid("Rank 1 finish or local retirement differs")
            }
            acknowledged[1] = true
            if isCancelled { throw ClusterWorkerOwnerError.cancelled }
            let emit = lock.withLock { callback }
            if (cacheReport?.reused ?? 0) > 0 || !bothStored.isEmpty {
                _ = emit?(.promptCache(reused: cacheReport?.reused ?? 0, stored: bothStored))
            }
            if telemetry != nil || peerTelemetry != nil { _ = emit?(.telemetry(rank0: telemetry, rank1: peerTelemetry)) }
            _ = emit?(.finished(finish!))
            retired.complete()
        } catch {
            if retired.isComplete { return }
            // The cause is named for the pair's incident and for the fence the
            // other Mac receives (S24): the owner side's own fixed text or a
            // rank's reason code, never prompt or token text.
            let cause = Self.failureText(error)
            // The request's own loop stopped because it was cancelled alone;
            // a rank's failure or a protocol violation still ends the pair.
            let cancelledAlone = (error as? ClusterWorkerOwnerError) == .cancelled
                && lock.withLock { cancellation.map { retiresAlone($0, begun: begun) } ?? false }
            if !cancelledAlone { owner.noteRequestFailure(self, cause) }
            if !cancelledAlone && lock.withLock({ cancellation.map { retiresAlone($0, begun: begun) } ?? false }) { owner.invalidate() }
            cancel(reason: .runtimeError) // Own the watchdog before any callback can block.
            let emit = lock.withLock { callback }
            _ = emit?(.failed("Worker request failed: \(cause); cleanup is still owned"))
            cleanup(acknowledged: acknowledged, cause: cause)
        }
    }

    /// One bounded line for why a request failed on the owner side.
    static func failureText(_ error: Error) -> String {
        let text: String
        switch error as? ClusterWorkerOwnerError {
        case .invalid(let message)?: text = message
        case .deadline?: text = "the request's deadline passed"
        case .cancelled?: text = "the request was cancelled"
        case .closed?: text = "a rank's command stream closed"
        case .unavailable?: text = "a rank is unavailable"
        case .refused(let reason)?: text = "a rank refused the reservation: \(reason.rawValue)"
        default: text = String(describing: error)
        }
        return String(text.prefix(300))
    }

    private func cleanup(acknowledged original: [Bool], cause: String = "the request was cancelled before it started") {
        if retired.isComplete { return }
        var acknowledged = original
        let reason = lock.withLock { cancellation ?? .runtimeError }
        let submitted = lock.withLock { submissions }
        let alone = retiresAlone(reason, begun: lock.withLock { begun })
        let deadline = DispatchTime.now().uptimeNanoseconds + (alone ? Self.laneRetirementWaitNanoseconds : 2_000_000_000)
        for index in 0..<2 where !acknowledged[index] {
            // Never-submitted/refused ranks have no request to cancel. Pending
            // submission can race an unread refusal, so only confirmed admission
            // permits request cancel. All other ranks need actual native cleanup.
            if alone && (submitted[index] == .none || submitted[index] == .refused) {
                // Never asked, or it refused: this rank holds nothing for the request.
                acknowledged[index] = true
                continue
            }
            if alone && submitted[index] == .submitted {
                // Its answer is still on the way: read it, then give back an admission.
                if let value = try? owner.receive(rank: index, requestID: requestID, until: deadline),
                   value.requestID == requestID {
                    if case .refused = value.event { acknowledged[index] = true; continue }
                    if case .admitted = value.event,
                       (try? owner.workers[index].sendWorkerCommand(.cancel(reason), requestID: requestID, deadline: deadline)) != nil {
                        continue
                    }
                }
                lock.withLock { fencedRank = true }
                owner.workers[index].requestNativeCleanup(reason: cause)
                continue
            }
            guard submitted[index] == .admitted else {
                lock.withLock { fencedRank = true }
                owner.workers[index].requestNativeCleanup(reason: cause)
                continue
            }
            do { try owner.workers[index].sendWorkerCommand(.cancel(reason), requestID: requestID, deadline: deadline) }
            catch { lock.withLock { fencedRank = true }; owner.workers[index].requestNativeCleanup(reason: cause) }
        }
        for index in 0..<2 where !acknowledged[index] {
            let worker = owner.workers[index]
            while !worker.nativeCleanupObserved && DispatchTime.now().uptimeNanoseconds < deadline {
                do {
                    let value = try owner.receive(rank: index, requestID: requestID, until: deadline)
                    guard value.requestID == requestID || value.requestID == nil else { throw ClusterWorkerOwnerError.invalid("Stale cleanup event") }
                    if value.requestID == requestID, case .retired = value.event { acknowledged[index] = true; break }
                    // In-flight committed/finished/failed records cannot undo cancellation.
                } catch { break }
            }
            if !acknowledged[index] {
                // A lane whose rank did not retire it in time ends the pair after all.
                lock.withLock { fencedRank = true }
                if alone { owner.invalidate() }
                worker.requestNativeCleanup(reason: cause); worker.waitForNativeCleanup() // No timeout can manufacture this acknowledgment.
                acknowledged[index] = true
            }
        }
        retired.complete()
    }
}
