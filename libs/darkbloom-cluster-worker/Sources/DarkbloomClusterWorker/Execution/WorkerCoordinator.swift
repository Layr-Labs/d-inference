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
/// data-plane exchange its owner sequences (tier 2, `keepWarm`).
final class WorkerCoordinator: @unchecked Sendable {
    private var runtime: (any WorkerRuntime)?
    private let pipes: WorkerPipes
    private let exitHooks: WorkerExitHooks
    private let membershipEpoch: UUID?
    private let renewal: @Sendable (UInt64) -> Void
    private let keepWarmEnabled: Bool
    private let keepWarmTiming: WorkerKeepWarmTiming
    private var ready: ClusterWorkerReady?
    private let condition = NSCondition()
    private let readerDone = DispatchGroup()
    private var readerStarted = false
    private var session: ClusterWorkerSession?
    private var eventSequence: UInt64 = 0
    private var actions: [ClusterWorkerCommandFrame] = []
    private var decision: ClusterWorkerTokenDecision?
    private var failure: Error?
    private var stopped = false
    private var shutdownReceived = false
    private var requestDeadline: UInt64?
    /// Tier 1 arms after the first real request and never before it.
    private var keepWarmArmed = false
    private var lastActivity: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var keepWarmBackoffUntil: UInt64 = 0

    /// Before load. `membershipEpoch` is the configured epoch every lease
    /// renewal must carry; `renewal` is told each renewal's time to live, for
    /// the process's alarm. Keep-warm tier 1 runs only when `keepWarm`.
    init(pipes: WorkerPipes, membershipEpoch: UUID?, keepWarm: Bool, exitHooks: WorkerExitHooks = .none,
         keepWarmTiming: WorkerKeepWarmTiming = .standard, renewal: @escaping @Sendable (UInt64) -> Void = { _ in }) {
        self.pipes = pipes; self.membershipEpoch = membershipEpoch; self.keepWarmEnabled = keepWarm
        self.exitHooks = exitHooks; self.keepWarmTiming = keepWarmTiming; self.renewal = renewal
    }

    /// After load, for a caller that has its runtime already (tests).
    convenience init(runtime: any WorkerRuntime, pipes: WorkerPipes, exitHooks: WorkerExitHooks = .none) throws {
        guard let ready = runtime.readiness else { throw WorkerFailure.invalid("Native owner did not establish bilateral readiness") }
        self.init(pipes: pipes, membershipEpoch: ready.identity.membershipEpoch, keepWarm: false, exitHooks: exitHooks)
        self.runtime = runtime
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
            let fresh = try ClusterWorkerSession(identity: value.identity, rank: value.rank, profile: value.profile,
                executionPlanSHA256: value.executionPlanSHA256)
            condition.lock()
            if let failure { condition.unlock(); throw failure }
            guard membershipEpoch == nil || membershipEpoch == value.identity.membershipEpoch else {
                condition.unlock(); throw WorkerFailure.invalid("Native readiness epoch differs from the configured epoch")
            }
            ready = value; session = fresh
            condition.unlock()
            try publish(.ready(value), requestID: nil)
            startReading()
            while true {
                guard let command = try nextAction() else {
                    keepWarmPulseIfIdle(runtime)
                    continue
                }
                switch command.command {
                case .reserve(let value):
                    do {
                        let bytes = try runtime.reserve(command.requestID!, value)
                        try publish(.admitted(reservedBytes: bytes), requestID: command.requestID)
                    } catch {
                        let available = runtime.readiness != nil
                        try publish(.refused(available ? .unsupported : .unavailable), requestID: command.requestID)
                        if !available { throw error }
                    }
                case .start:
                    let id = command.requestID!
                    let reason = try runtime.start(id) { ordinal, token, frontier in
                        try self.publish(.committedToken(ordinal: ordinal, tokenID: token, committedTokens: frontier), requestID: id)
                        return try self.nextDecision() == .proceed
                    }
                    // The native facade returns only after bilateral retirement
                    // and after its request/autorelease scope has ended.
                    let cache = runtime.lastPromptCache
                    if cache.reused > 0 || !cache.stored.isEmpty {
                        try publish(.promptCache(reusedTokens: cache.reused,
                            storedFrontiers: Array(cache.stored.sorted().suffix(32))), requestID: id)
                    }
                    try publish(.finished(reason), requestID: id)
                    try publish(.retired(.clean), requestID: id)
                    condition.lock(); keepWarmArmed = true; condition.unlock()
                    if runtime.readiness == nil { try publish(.unavailable(.runtimeError), requestID: nil) }
                case .keepWarm(let ordinal):
                    // Tier 2. A failure of the data plane is a failed worker:
                    // it ends cleanly through the failure path below.
                    let elapsed = try runtime.dataPlanePing()
                    try publish(.keptWarm(ordinal: ordinal, microseconds: Int(min(elapsed / 1_000, UInt64(Int32.max)))), requestID: nil)
                case .shutdown:
                    condition.lock(); keepWarmArmed = false; condition.unlock()
                    try runtime.shutdown()
                    modelReleased = true
                    try publish(.shutdownComplete, requestID: nil)
                    return
                case .cancel:
                    throw WorkerFailure.invalid("Request cancelled before native start or after its return")
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
            let id = activeRequest()
            if let id {
                runtime.cancel(id)
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
            && session?.activeRequestID == nil && now >= keepWarmBackoffUntil
            && now - lastActivity >= keepWarmTiming.intervalNanoseconds
        condition.unlock()
        guard due else { return }
        let elapsed = (try? runtime.keepWarmPulse()) ?? 0
        condition.lock()
        lastActivity = DispatchTime.now().uptimeNanoseconds
        if elapsed > keepWarmTiming.slowNanoseconds { keepWarmBackoffUntil = lastActivity + keepWarmTiming.backoffNanoseconds }
        condition.unlock()
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
        if let failure { throw failure }
        guard var proposed = session, let ready else { throw WorkerFailure.invalid("Event before readiness") }
        let frame = ClusterWorkerEventFrame(membershipEpoch: ready.identity.membershipEpoch,
            sequence: eventSequence, requestID: requestID, event: event)
        do {
            try proposed.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
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
                    guard !stopped else { throw WorkerFailure.invalid("Control after worker stop") }
                    let frame: ClusterWorkerCommandFrame
                    switch line {
                    case .extendDeadline(let value):
                        // The rank lease, outside the request sequence; read
                        // during the load as much as after it.
                        guard membershipEpoch == nil || value.membershipEpoch == membershipEpoch else {
                            throw WorkerFailure.invalid("Lease renewal for another epoch")
                        }
                        pipes.lease.renew(now: DispatchTime.now().uptimeNanoseconds, ttl: value.ttlNanoseconds)
                        renewal(value.ttlNanoseconds)
                        continue
                    case .command(let value): frame = value
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

    private func activeRequest() -> UUID? {
        condition.lock(); defer { condition.unlock() }; return session?.activeRequestID
    }

    private func fail(_ error: Error) {
        condition.lock()
        failure = failure ?? error
        let id = session?.activeRequestID
        condition.broadcast(); condition.unlock()
        if let id { runtime?.cancel(id) }
    }
}
