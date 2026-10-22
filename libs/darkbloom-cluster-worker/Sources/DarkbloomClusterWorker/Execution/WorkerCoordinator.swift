import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation

/// What the coordinator does the moment it knows the worker will not go on:
/// the reader saw its input end before shutdown or fail, or the executor
/// caught a failure. The worker begins its one forced exit there (release
/// first, dead-man armed), then unwinds; tests record the call instead.
struct WorkerExitHooks: Sendable {
    let begin: @Sendable (String) -> Void
    static let none = WorkerExitHooks(begin: { _ in })
    static let forcedExit = WorkerExitHooks(begin: { ProcessForcedExit.begin(status: 1, reason: $0) })
}

/// Keep-warm tier 1 timing (owner's latent-Metal keep-warm design): a pulse
/// every half second while idle, armed by the first real request, and a
/// minute's back-off after a submission that took more than a second.
struct WorkerKeepWarmTiming: Sendable {
    let intervalNanoseconds: UInt64
    let slowNanoseconds: UInt64
    let backoffNanoseconds: UInt64
    static let standard = WorkerKeepWarmTiming(intervalNanoseconds: 500_000_000, slowNanoseconds: 1_000_000_000,
                                               backoffNanoseconds: 60_000_000_000)
}

/// When an idle worker gives back what its runtime holds beyond the model
/// (`WorkerRuntime.releaseIdleMemory`, `ClusterIdleMemory`): once, `delay`
/// after a request retired with nothing queued or active since, and on every
/// idle tick on which the host reports memory pressure.
struct WorkerIdleRelease: Sendable {
    let delayNanoseconds: UInt64
    let hostUnderPressure: @Sendable () -> Bool
    static let standard = WorkerIdleRelease(delayNanoseconds: ClusterIdleMemory.releaseDelayNanoseconds,
                                            hostUnderPressure: { ClusterIdleMemory.hostUnderPressure() })
}

/// The main process thread is the dedicated synchronous native executor. The
/// reader only validates control, queues one next action, and signals cancel.
/// All protocol state and event publication share the condition lock; a failed
/// write never advances the published event sequence or authorizes more work.
///
/// The reader starts at launch, before any weights load (`startReading`), so
/// the owner's rank-lease renewals (`extendDeadline`) are read while the model
/// loads; a renewal moves the process deadline on. Any other input before
/// readiness ends the worker, as before. While idle the executor also runs the
/// two keep-warm tiers: its own GPU pulse every half second (tier 1), and the
/// data-plane exchange its owner sequences (tier 2, `keepWarm`); and it gives
/// back idle memory (`WorkerIdleRelease`).
final class WorkerCoordinator: @unchecked Sendable {
    private var runtime: (any WorkerRuntime)?
    private let pipes: WorkerPipes
    private let exitHooks: WorkerExitHooks
    private let membershipEpoch: UUID?
    private let renewal: @Sendable (UInt64) -> Void
    private let keepWarmEnabled: Bool
    private let keepWarmTiming: WorkerKeepWarmTiming
    private let idleRelease: WorkerIdleRelease
    private var ready: ClusterWorkerReady?
    private let condition = NSCondition()
    private let readerDone = DispatchGroup()
    private var readerStarted = false
    private var session: ClusterWorkerSession?
    /// With batch lanes (continuous batching) every request has its own
    /// ordering here instead of in `session`; exactly one of the two is set.
    private var laneSession: ClusterWorkerLaneSession?
    private var eventSequence: UInt64 = 0
    private var actions: [ClusterWorkerCommandFrame] = []
    private var decision: ClusterWorkerTokenDecision?
    /// Batch lanes: rank 0's decisions, by request, until the loop takes them.
    private var laneDecisions: [UUID: ClusterWorkerTokenDecision] = [:]
    /// Published admissions whose start has not been accepted by the reader.
    /// Runtime start may still be queued after this set loses the ID.
    private var unstartedLanes = Set<UUID>()
    /// Lanes given back before they started, whose cancel the executor answers
    /// with their retirement (condition lock).
    private var withdrawnLanes = Set<UUID>()
    /// Started lanes that left the loop before their owner's cancel arrived
    /// (rank 0 dropped them, or their deadline passed): the cancel, when it
    /// comes, is answered with their retirement (condition lock).
    private var leftLanes = Set<UUID>()
    private static let laneActionBound = 64
    private var failure: Error?
    private var stopped = false
    private var shutdownReceived = false
    private var requestDeadline: UInt64?
    /// Tier 1 arms after the first real request and never before it.
    private var keepWarmArmed = false
    private var lastActivity: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var keepWarmBackoffUntil: UInt64 = 0
    /// When the last request retired, until its idle release ran.
    private var retiredAt: UInt64?
    /// The request this executor admitted and has not started; executor only.
    private var admittedNotStarted: UUID?

    /// Before load. `membershipEpoch` is the configured epoch every lease
    /// renewal must carry; `renewal` is told each renewal's time to live, for
    /// the process's alarm. Keep-warm tier 1 runs only when `keepWarm`.
    init(pipes: WorkerPipes, membershipEpoch: UUID?, keepWarm: Bool, exitHooks: WorkerExitHooks = .none,
         keepWarmTiming: WorkerKeepWarmTiming = .standard, idleRelease: WorkerIdleRelease = .standard,
         renewal: @escaping @Sendable (UInt64) -> Void = { _ in }) {
        self.pipes = pipes; self.membershipEpoch = membershipEpoch; self.keepWarmEnabled = keepWarm
        self.exitHooks = exitHooks; self.keepWarmTiming = keepWarmTiming; self.idleRelease = idleRelease
        self.renewal = renewal
    }

    /// After load, for a caller that has its runtime already (tests).
    convenience init(runtime: any WorkerRuntime, pipes: WorkerPipes, exitHooks: WorkerExitHooks = .none,
                     idleRelease: WorkerIdleRelease = .standard) throws {
        guard let ready = runtime.readiness else { throw WorkerFailure.invalid("Native owner did not establish bilateral readiness") }
        self.init(pipes: pipes, membershipEpoch: ready.identity.membershipEpoch, keepWarm: false, exitHooks: exitHooks,
            idleRelease: idleRelease)
        self.runtime = runtime
    }

    /// The rank-side force-cancel (owner's oMLX 85480430 hook, by signal):
    /// ends every active request of this rank the way a lost input does. The
    /// forced exit is claimed first (release, dead-man), the executor's
    /// failure path then cancels each active request, publishes it as failed,
    /// releases the model and the process exits; the owner records the
    /// terminal. One line on standard error acknowledges the request.
    /// Returns the requests that were active.
    @discardableResult
    func forceCancel(reason: String) -> Int {
        let ids = activeRequests()
        exitHooks.begin("force-cancel-\(reason)")
        fail(WorkerFailure.invalid("Force-cancel: \(reason)"))
        WorkerForceCancelSignal.note("darkbloom-force-cancel-v1 role=worker reason=\(reason) applied=yes requests=\(ids.count)")
        return ids.count
    }

    /// Starts the control reader. Idempotent. From here a lost input or a
    /// failed read begins the forced exit even while the model loads.
    func startReading() {
        condition.lock()
        if readerStarted { condition.unlock(); return }
        readerStarted = true; readerDone.enter()
        condition.unlock()
        Thread.detachNewThread { [self] in
            defer { readerDone.leave() }
            do { try readControl() } catch {
                // Lost or failed input, or a deadline seen while awaiting
                // control: an executor blocked in a collective (or in the
                // load) would not see it until its guard; release now, bound
                // the unwind, then wake it.
                exitHooks.begin(Self.exitReason(error))
                fail(error)
            }
        }
    }

    func run(runtime: any WorkerRuntime) throws {
        condition.lock(); self.runtime = runtime; condition.unlock()
        try run()
    }

    func run() throws {
        guard let runtime else { throw WorkerFailure.invalid("Worker has no runtime") }
        var modelReleased = false
        defer {
            condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
            if readerStarted { _ = readerDone.wait(timeout: .now() + 2) }
        }
        do {
            guard let value = runtime.readiness else { throw WorkerFailure.invalid("Native owner did not establish bilateral readiness") }
            let lanes = runtime.batchLanes
            let fresh = lanes > 1 ? nil : try ClusterWorkerSession(identity: value.identity, rank: value.rank,
                profile: value.profile, executionPlanSHA256: value.executionPlanSHA256)
            let freshLanes = lanes > 1 ? try ClusterWorkerLaneSession(identity: value.identity, rank: value.rank,
                profile: value.profile, executionPlanSHA256: value.executionPlanSHA256, lanes: lanes) : nil
            condition.lock()
            if let failure { condition.unlock(); throw failure }
            guard membershipEpoch == nil || membershipEpoch == value.identity.membershipEpoch else {
                condition.unlock(); throw WorkerFailure.invalid("Native readiness epoch differs from the configured epoch")
            }
            ready = value; session = fresh; laneSession = freshLanes
            condition.unlock()
            try publish(.ready(value), requestID: nil)
            startReading()
            if lanes > 1 {
                // Continuous batching: control is applied as it arrives, and
                // the batch loop runs while any started lane waits for it.
                while true {
                    guard let command = try nextAction() else {
                        keepWarmPulseIfIdle(runtime)
                        releaseIdleMemoryIfDue(runtime)
                        continue
                    }
                    if try applyLaneCommand(command, runtime: runtime) {
                        modelReleased = true
                        return
                    }
                    while runtime.hasStartedLanes {
                        try runtime.serveBatch(host: LaneHost(coordinator: self, runtime: runtime))
                        condition.lock(); keepWarmArmed = true; retiredAt = DispatchTime.now().uptimeNanoseconds
                        condition.unlock()
                        if runtime.readiness == nil { try publish(.unavailable(.runtimeError), requestID: nil) }
                    }
                    condition.lock(); lastActivity = DispatchTime.now().uptimeNanoseconds; condition.unlock()
                }
            }
            while true {
                guard let command = try nextAction() else {
                    keepWarmPulseIfIdle(runtime)
                    releaseIdleMemoryIfDue(runtime)
                    continue
                }
                switch command.command {
                case .reserve(let value):
                    do {
                        try Self.requireLogprobCapture(value, runtime: runtime)
                        let bytes = try runtime.reserve(command.requestID!, value)
                        try publish(.admitted(reservedBytes: bytes), requestID: command.requestID)
                        admittedNotStarted = command.requestID
                    } catch let refusal as ClusterResidentRequestRefusal where runtime.readiness != nil {
                        // This request alone: the runtime gave the reservation
                        // back and stays available (its own log line names why).
                        try publish(.refused(refusal.reason), requestID: command.requestID)
                    } catch {
                        let available = runtime.readiness != nil
                        try publish(.refused(available ? .unsupported : .unavailable), requestID: command.requestID)
                        if !available { throw error }
                    }
                case .start:
                    let id = command.requestID!
                    admittedNotStarted = nil
                    // Publication and the owner's answer apart: a runtime may read
                    // the answer after submitting its next step (the token credit
                    // still holds: the session refuses a token before the answer).
                    let reason = try runtime.start(id, tokens: ClusterCommittedTokenChannel(
                        publishToken: { ordinal, token, frontier, logprobs in
                            try self.publish(.committedToken(ordinal: ordinal, tokenID: token, committedTokens: frontier,
                                logprobs: logprobs), requestID: id)
                        },
                        answer: { try self.nextDecision() == .proceed }))
                    // The native facade returns only after bilateral retirement
                    // and after its request/autorelease scope has ended.
                    let cache = runtime.lastPromptCache
                    if cache.reused > 0 || !cache.stored.isEmpty {
                        try publish(.promptCache(reusedTokens: cache.reused,
                            storedFrontiers: Array(cache.stored.sorted().suffix(32))), requestID: id)
                    }
                    if let telemetry = runtime.lastRequestTelemetry, !telemetry.isEmpty {
                        try publish(.requestTelemetry(telemetry), requestID: id)
                    }
                    try publish(.finished(reason), requestID: id)
                    try publish(.retired(.clean), requestID: id)
                    condition.lock(); keepWarmArmed = true; retiredAt = DispatchTime.now().uptimeNanoseconds
                    condition.unlock()
                    if runtime.readiness == nil { try publish(.unavailable(.runtimeError), requestID: nil) }
                case .keepWarm(let ordinal):
                    // Tier 2. A failure of the data plane is a failed worker:
                    // it ends cleanly through the failure path below. The
                    // answer carries the serving context re-derived now.
                    let elapsed = try runtime.dataPlanePing()
                    let serving = runtime.refreshServingContext().map { min($0, ready?.profile.maximumContextTokens ?? $0) }
                    try publish(.keptWarm(ordinal: ordinal, microseconds: Int(min(elapsed / 1_000, UInt64(Int32.max))),
                        servingContextTokens: serving), requestID: nil)
                    // The owner's pings may keep every wait above from timing out.
                    releaseIdleMemoryIfDue(runtime)
                case .shutdown:
                    condition.lock(); keepWarmArmed = false; condition.unlock()
                    try runtime.shutdown()
                    modelReleased = true
                    try publish(.shutdownComplete, requestID: nil)
                    return
                case .cancel:
                    // The owner gives back a reservation that never started
                    // (the other rank refused the request): release it and
                    // stay available. Any other cancel here is a failure.
                    guard let id = command.requestID, activeRequests() == [id], admittedNotStarted == id else {
                        throw WorkerFailure.invalid("Request cancelled before native start or after its return")
                    }
                    try runtime.releaseReservation(id)
                    admittedNotStarted = nil
                    try publish(.retired(.cancelled), requestID: id)
                case .tokenDecision:
                    throw WorkerFailure.invalid("Token decision escaped its callback credit")
                }
                condition.lock(); lastActivity = DispatchTime.now().uptimeNanoseconds; condition.unlock()
            }
        } catch {
            let primary = error
            // Includes a JACCL guard error: release first, and bound the local
            // cleanup below by the dead-man.
            exitHooks.begin("worker-failure")
            for id in activeRequests() {
                runtime.cancel(id); runtime.cancelLane(id)
                // A protocol/pipe failure may make this publication impossible.
                // Never invent retired merely because native start threw.
                try? publish(.failed(.runtimeError), requestID: id)
            }
            if !modelReleased {
                do { try runtime.shutdown() }
                catch { throw WorkerFailure.invalid("Worker failed (\(primary)); local cleanup failed (\(error))") }
            }
            throw primary
        }
    }

    /// Tier 1 on the executor: idle, armed, out of back-off, and at least one
    /// interval since the last activity or pulse. Submission only.
    private func keepWarmPulseIfIdle(_ runtime: any WorkerRuntime) {
        let now = DispatchTime.now().uptimeNanoseconds
        condition.lock()
        let due = keepWarmEnabled && keepWarmArmed && actions.isEmpty && failure == nil && !stopped
            && session?.activeRequestID == nil && (laneSession?.activeRequestIDs.isEmpty ?? true)
            && now >= keepWarmBackoffUntil
            && now - lastActivity >= keepWarmTiming.intervalNanoseconds
        condition.unlock()
        guard due else { return }
        let elapsed = (try? runtime.keepWarmPulse()) ?? 0
        condition.lock()
        lastActivity = DispatchTime.now().uptimeNanoseconds
        if elapsed > keepWarmTiming.slowNanoseconds { keepWarmBackoffUntil = lastActivity + keepWarmTiming.backoffNanoseconds }
        condition.unlock()
    }

    /// On the executor while idle (nothing queued, reserved or running): the
    /// runtime gives back what it holds beyond its model, once the last
    /// retired request is `idleRelease.delayNanoseconds` old, and on any tick
    /// under host memory pressure.
    private func releaseIdleMemoryIfDue(_ runtime: any WorkerRuntime) {
        let now = DispatchTime.now().uptimeNanoseconds
        condition.lock()
        let idle = actions.isEmpty && failure == nil && !stopped
            && session?.activeRequestID == nil && (laneSession?.activeRequestIDs.isEmpty ?? true)
        let due = idle && retiredAt.map { now >= $0 &+ idleRelease.delayNanoseconds } == true
        condition.unlock()
        guard idle else { return }
        let pressure = idleRelease.hostUnderPressure()
        guard due || pressure else { return }
        _ = runtime.releaseIdleMemory(underPressure: pressure)
        if due { condition.lock(); retiredAt = nil; condition.unlock() }
    }

    /// The reason a reader failure gives the forced exit, for the log.
    static func exitReason(_ error: Error) -> String {
        guard case WorkerFailure.invalid(let message) = error else { return "worker-input" }
        if message.hasPrefix("EOF preceded") { return "lost-input" }
        if message.hasPrefix("Worker request deadline") { return "request-deadline" }
        if message.hasPrefix("Worker rank lease") { return "lease-expired" }
        return "worker-input"
    }

    private func publish(_ event: ClusterWorkerEvent, requestID: UUID?) throws {
        condition.lock(); defer { condition.unlock() }
        try publishLocked(event, requestID: requestID)
    }

    /// `publish` with the condition lock held, so a lane's check and its
    /// events are one step against the reader.
    private func publishLocked(_ event: ClusterWorkerEvent, requestID: UUID?,
                               now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        if let failure { throw failure }
        guard let ready, session != nil || laneSession != nil else { throw WorkerFailure.invalid("Event before readiness") }
        let frame = ClusterWorkerEventFrame(membershipEpoch: ready.identity.membershipEpoch,
            sequence: eventSequence, requestID: requestID, event: event)
        do {
            if var proposed = laneSession {
                try proposed.accept(frame, now: now)
                try pipes.write(ClusterWorkerCodec.encode(frame), requestDeadline: nil)
                laneSession = proposed; eventSequence += 1
                if let requestID {
                    switch event {
                    case .admitted: unstartedLanes.insert(requestID)
                    case .retired, .refused:
                        unstartedLanes.remove(requestID); withdrawnLanes.remove(requestID); leftLanes.remove(requestID)
                        laneDecisions[requestID] = nil
                    default: break
                    }
                }
                return
            }
            var proposed = session!
            try proposed.accept(frame, now: now)
            try pipes.write(ClusterWorkerCodec.encode(frame), requestDeadline: requestDeadline)
            session = proposed; eventSequence += 1
            switch event {
            case .refused, .retired: requestDeadline = nil
            default: break
            }
        } catch { failure = error; condition.broadcast(); throw error }
    }

    private func readControl() throws {
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        while true {
            condition.lock(); let done = stopped; let deadline = requestDeadline; condition.unlock()
            if done { return }
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                throw WorkerFailure.invalid("Worker request deadline expired while awaiting control")
            }
            guard let chunk = try pipes.readChunk() else { continue }
            if chunk.isEmpty {
                try decoder.finish()
                condition.lock(); let normal = shutdownReceived || stopped; condition.unlock()
                guard normal else { throw WorkerFailure.invalid("EOF preceded explicit worker shutdown") }
                return
            }
            let lines = try decoder.append(chunk).map(ClusterWorkerCodec.decodeControl)
            condition.lock()
            do {
                // Validate every already-read command before waking the native
                // executor: start+early tokenDecision in one pipe read cannot
                // borrow the token credit created while parsing that batch.
                for line in lines {
                    if let failure { throw failure }
                    if case .extendDeadline(let value) = line {
                        // The rank lease, outside the request sequence; read
                        // during the load as much as after it.
                        guard membershipEpoch == nil || value.membershipEpoch == membershipEpoch else {
                            throw WorkerFailure.invalid("Lease renewal for another epoch")
                        }
                        // The owner renews until it has read shutdownComplete and
                        // closed the input: a renewal that crosses the stop is
                        // moot, not a failed input (it ended clean runs with 1).
                        if !stopped {
                            pipes.lease.renew(now: DispatchTime.now().uptimeNanoseconds, ttl: value.ttlNanoseconds)
                            renewal(value.ttlNanoseconds)
                        }
                        continue
                    }
                    guard !stopped else { throw WorkerFailure.invalid("Control after worker stop") }
                    guard case .command(let frame) = line else { continue }
                    if laneSession != nil {
                        try acceptLaneCommandLocked(frame)
                        continue
                    }
                    guard session != nil else { throw WorkerFailure.invalid("Input or EOF arrived before worker readiness") }
                    try session!.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
                    switch frame.command {
                    case .reserve(let value):
                        requestDeadline = value.deadlineUptimeNanoseconds
                        guard actions.isEmpty else { throw WorkerFailure.invalid("Reservation overlaps a pending action") }
                        actions.append(frame)
                    case .tokenDecision(_, let value): decision = value
                    case .cancel:
                        // This method touches only the facade's locked flag.
                        runtime?.cancel(frame.requestID!)
                        guard actions.count < 2 else { throw WorkerFailure.invalid("Worker action queue exceeded its bound") }
                        actions.append(frame)
                    case .shutdown:
                        shutdownReceived = true
                        guard actions.isEmpty else { throw WorkerFailure.invalid("Shutdown overlaps a pending action") }
                        actions.append(frame)
                    default:
                        guard actions.isEmpty else { throw WorkerFailure.invalid("Worker received an overlapping action") }
                        actions.append(frame)
                    }
                }
                condition.broadcast(); condition.unlock()
            } catch { condition.unlock(); throw error }
        }
    }

    /// The next action, or nil when none arrived within the keep-warm interval
    /// (the executor may then pulse).
    private func nextAction() throws -> ClusterWorkerCommandFrame? {
        condition.lock(); defer { condition.unlock() }
        if actions.isEmpty && failure == nil {
            let interval = Double(keepWarmTiming.intervalNanoseconds) / 1e9
            _ = condition.wait(until: Date(timeIntervalSinceNow: keepWarmEnabled ? interval : 1))
        }
        if let failure { throw failure }
        return actions.isEmpty ? nil : actions.removeFirst()
    }

    private func nextDecision() throws -> ClusterWorkerTokenDecision {
        condition.lock(); defer { condition.unlock() }
        while decision == nil && failure == nil && actions.isEmpty { condition.wait() }
        if let failure { throw failure }
        guard actions.isEmpty, let value = decision else { throw WorkerFailure.invalid("Token decision interrupted by cancellation") }
        decision = nil
        return value
    }

    private func activeRequests() -> [UUID] {
        condition.lock(); defer { condition.unlock() }
        return laneSession?.activeRequestIDs ?? session?.activeRequestID.map { [$0] } ?? []
    }

    private func fail(_ error: Error) {
        condition.lock()
        failure = failure ?? error
        let ids = laneSession?.activeRequestIDs ?? session?.activeRequestID.map { [$0] } ?? []
        condition.broadcast(); condition.unlock()
        for id in ids { runtime?.cancel(id); runtime?.cancelLane(id) }
    }

    // MARK: Batch lanes (continuous batching)

    /// Called with the condition lock held, from the reader. Decisions are
    /// kept by request; every other command queues for the executor.
    private func acceptLaneCommandLocked(_ frame: ClusterWorkerCommandFrame) throws {
        try laneSession!.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
        switch frame.command {
        case .tokenDecision(_, let value):
            laneDecisions[frame.requestID!] = value
        case .cancel where !laneSession!.holds(frame.requestID!):
            // It crossed the request's own retirement: nothing to answer.
            return
        case .cancel:
            // A repeated cancel before its retirement needs only one queued
            // acknowledgment; the protocol still validates its sequence.
            if withdrawnLanes.contains(frame.requestID!) { return }
            // A lane that never started is given back on its own (the pair's
            // other rank refused it); the lanes that run go on. Any other
            // lane: only the facade's locked flag; the loop's next check ends it.
            // Accepted start is the cutoff, even when the executor has not
            // applied it yet. Never withdraw beneath a queued/in-flight start.
            if unstartedLanes.remove(frame.requestID!) != nil,
               runtime?.withdrawLane(frame.requestID!) == true {
                withdrawnLanes.insert(frame.requestID!)
            } else {
                runtime?.cancel(frame.requestID!); runtime?.cancelLane(frame.requestID!)
            }
            guard actions.count < Self.laneActionBound else { throw WorkerFailure.invalid("Worker action queue exceeded its bound") }
            actions.append(frame)
        case .shutdown:
            shutdownReceived = true
            guard actions.isEmpty else { throw WorkerFailure.invalid("Shutdown overlaps a pending action") }
            actions.append(frame)
        default:
            guard actions.count < Self.laneActionBound else { throw WorkerFailure.invalid("Worker action queue exceeded its bound") }
            if case .start = frame.command { unstartedLanes.remove(frame.requestID!) }
            actions.append(frame)
        }
    }

    /// A request asking for logprobs reaches only a runtime that sends them;
    /// any other refuses it alone (unsupported) and stays available.
    static func requireLogprobCapture(_ value: ClusterWorkerReservation, runtime: any WorkerRuntime) throws {
        guard value.sampling?.capturedLogprobs == nil || runtime.capturesLogprobs else {
            throw ClusterResidentRequestRefusal(reason: .unsupported,
                message: "This runtime does not send token logprobs")
        }
    }

    /// One queued command on the executor. True after the model was released
    /// by an acknowledged shutdown.
    private func applyLaneCommand(_ command: ClusterWorkerCommandFrame, runtime: any WorkerRuntime) throws -> Bool {
        switch command.command {
        case .reserve(let value):
            if value.sampling?.capturedLogprobs != nil, !runtime.capturesLogprobs {
                try publish(.refused(.unsupported), requestID: command.requestID)
                return false
            }
            do {
                let bytes = try runtime.reserveLane(command.requestID!, value)
                try publish(.admitted(reservedBytes: bytes), requestID: command.requestID)
            } catch {
                let available = runtime.readiness != nil
                try publish(.refused(available ? .capacity : .unavailable), requestID: command.requestID)
                if !available { throw error }
            }
        case .start:
            try runtime.startLane(command.requestID!)
        case .keepWarm(let ordinal):
            let elapsed = try runtime.dataPlanePing()
            try publish(.keptWarm(ordinal: ordinal, microseconds: Int(min(elapsed / 1_000, UInt64(Int32.max)))), requestID: nil)
        case .shutdown:
            condition.lock(); keepWarmArmed = false; condition.unlock()
            try runtime.shutdown()
            try publish(.shutdownComplete, requestID: nil)
            return true
        case .cancel:
            let id = command.requestID!
            condition.lock(); let withdrawn = withdrawnLanes.contains(id); condition.unlock()
            if runtime.retiresCancelledLanes && !withdrawn {
                // A started lane leaves the loop at its next step boundary,
                // which publishes its retirement; one that left before this
                // cancel arrived is retired now.
                try completeLaneLeft(id)
            } else {
                try completeLaneWithdrawal(id)
            }
        case .tokenDecision:
            throw WorkerFailure.invalid("Token decision escaped its callback credit")
        }
        return false
    }

    /// Executor-only: the cancel of a lane that already left the loop.
    private func completeLaneLeft(_ id: UUID) throws {
        condition.lock(); defer { condition.unlock() }
        guard leftLanes.contains(id), laneSession?.isCancelled(id) == true else { return }
        try publishLocked(.retired(.cancelled), requestID: id)
    }

    /// Executor-only. Keep the disposition until publication succeeds, so a
    /// reader-side duplicate cannot turn the pending acknowledgment fatal.
    private func completeLaneWithdrawal(_ id: UUID) throws {
        condition.lock(); let withdrawn = withdrawnLanes.contains(id); condition.unlock()
        guard withdrawn else { throw WorkerFailure.invalid("Request cancelled") }
        try publish(.retired(.cancelled), requestID: id)
    }

    /// Every queued command, without waiting (between batch steps).
    fileprivate func serviceLaneControl(runtime: any WorkerRuntime) throws {
        while true {
            condition.lock()
            if let failure { condition.unlock(); throw failure }
            // A keep-warm exchange is a collective of its own, and shutdown
            // releases the model: both wait for the loop to end (their owner
            // sends them only once every lane retired, so it ends at its next step).
            if let first = actions.first, Self.waitsForLoopEnd(first.command) { condition.unlock(); return }
            let next = actions.isEmpty ? nil : actions.removeFirst()
            condition.unlock()
            guard let next else { return }
            _ = try applyLaneCommand(next, runtime: runtime)
        }
    }

    private static func waitsForLoopEnd(_ command: ClusterWorkerCommand) -> Bool {
        switch command {
        case .keepWarm, .shutdown: true
        default: false
        }
    }

    fileprivate func awaitLaneDecisions(_ ids: [UUID]) throws -> [UUID: Bool] {
        condition.lock()
        while true {
            if let failure { condition.unlock(); throw failure }
            if let index = actions.firstIndex(where: { if case .cancel = $0.command { return true }; return false }) {
                let command = actions.remove(at: index)
                condition.unlock()
                // Only a successful unstarted withdrawal is safe to service
                // while waiting for another lane's decision. A started-lane
                // cancel still fails the batch. Publish without holding the
                // condition: publish acquires it and commits the protocol state.
                try completeLaneWithdrawal(command.requestID!)
                condition.lock()
                continue
            }
            if ids.allSatisfy({ laneDecisions[$0] != nil }) {
                var result: [UUID: Bool] = [:]
                for id in ids { result[id] = laneDecisions.removeValue(forKey: id)! == .proceed }
                condition.unlock()
                return result
            }
            condition.wait()
        }
    }

    fileprivate func publishLaneToken(_ id: UUID, ordinal: Int, token: Int, committed: Int) throws {
        condition.lock(); defer { condition.unlock() }
        // A lane its owner cancelled, or past its deadline, publishes nothing
        // more of its own (the runtime retiring lanes alone then drops it).
        let now = DispatchTime.now().uptimeNanoseconds
        if runtime?.retiresCancelledLanes == true, laneSession?.accepts(id, now: now) != true { return }
        try publishLocked(.committedToken(ordinal: ordinal, tokenID: token, committedTokens: committed), requestID: id, now: now)
    }

    fileprivate func publishLanePromptCache(_ id: UUID, reused: Int, stored: [Int]) throws {
        condition.lock(); defer { condition.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if runtime?.retiresCancelledLanes == true, laneSession?.accepts(id, now: now) != true { return }
        try publishLocked(.promptCache(reusedTokens: reused, storedFrontiers: stored), requestID: id, now: now)
    }

    fileprivate func publishLaneFinished(_ id: UUID, reason: ClusterWorkerFinishReason) throws {
        condition.lock(); defer { condition.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if runtime?.retiresCancelledLanes == true, laneSession?.accepts(id, now: now) != true {
            // Cancelled (or past its deadline) while it finished: it retires
            // as cancelled, now or when the cancel arrives.
            try leaveLaneLocked(id)
            return
        }
        try publishLocked(.finished(reason), requestID: id, now: now)
        try publishLocked(.retired(.clean), requestID: id, now: now)
    }

    /// A started lane left the loop without finishing.
    fileprivate func publishLaneLeft(_ id: UUID) throws {
        condition.lock(); defer { condition.unlock() }
        try leaveLaneLocked(id)
    }

    private func leaveLaneLocked(_ id: UUID) throws {
        guard laneSession?.holds(id) == true else { return }
        if laneSession?.isCancelled(id) == true {
            try publishLocked(.retired(.cancelled), requestID: id)
        } else {
            leftLanes.insert(id)
        }
    }

    /// Rank 0: the owner's answer to one lane's last token, if it arrived;
    /// false once the lane was cancelled or passed its deadline.
    fileprivate func pollLaneDecision(_ id: UUID) throws -> Bool? {
        condition.lock(); defer { condition.unlock() }
        return try laneDecisionLocked(id)
    }

    fileprivate func awaitLaneDecision(_ id: UUID) throws -> Bool {
        condition.lock(); defer { condition.unlock() }
        while true {
            if let value = try laneDecisionLocked(id) { return value }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func laneDecisionLocked(_ id: UUID) throws -> Bool? {
        if let failure { throw failure }
        if let value = laneDecisions.removeValue(forKey: id) { return value == .proceed }
        guard laneSession?.accepts(id, now: DispatchTime.now().uptimeNanoseconds) == true else { return false }
        return nil
    }
}

/// The batch loop's view of the worker: control, publication and decisions.
private final class LaneHost: QwenBatchServingHost {
    private let coordinator: WorkerCoordinator
    private let runtime: any WorkerRuntime
    init(coordinator: WorkerCoordinator, runtime: any WorkerRuntime) { self.coordinator = coordinator; self.runtime = runtime }
    func serviceControl() throws { try coordinator.serviceLaneControl(runtime: runtime) }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
        try coordinator.publishLaneToken(requestID, ordinal: ordinal, token: tokenID, committed: committedTokens)
    }
    func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] { try coordinator.awaitLaneDecisions(requestIDs) }
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {
        try coordinator.publishLaneFinished(requestID, reason: reason)
    }
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {
        try coordinator.publishLanePromptCache(requestID, reused: reusedTokens, stored: storedFrontiers)
    }
    func pollDecision(_ requestID: UUID) throws -> Bool? { try coordinator.pollLaneDecision(requestID) }
    func awaitDecision(_ requestID: UUID) throws -> Bool { try coordinator.awaitLaneDecision(requestID) }
    func publishLeft(requestID: UUID) throws { try coordinator.publishLaneLeft(requestID) }
}
