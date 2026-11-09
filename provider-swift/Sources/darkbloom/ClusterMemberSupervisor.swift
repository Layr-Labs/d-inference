import Foundation
import Darwin
import ProviderCore

/// The always-on process for a cluster member (S18): what launchd keeps for
/// `darkbloom start --cluster-member --always-on`, and what an operator can run
/// in a terminal with `--supervise`. It never serves anything itself. It
///
/// 1. waits for this Mac's cluster port (`ClusterMemberLinkGate`) so a member
///    never registers into a pair it cannot reach;
/// 2. runs the ordinary member (`darkbloom start --cluster-member`) as a child
///    and watches its heartbeat (`ClusterMemberLivenessGuard`);
/// 3. restarts it after any end it did not ask for, with the owner's restart
///    budget and backoff (`ClusterMemberRestartBudget`), and parks when the
///    budget is spent instead of looping against JACCL and Metal memory;
/// 4. at the cluster's update slot drains its member, installs a release and
///    starts again from the new binary (`ClusterMemberUpdateSlot`). Around the
///    cluster service (`pairUpdate`), the pair's coordinated update runs while
///    the service serves (`ClusterPairUpdateCycle`), and a release it installed
///    is promoted or rolled back by its service's health (`ClusterCandidateRecovery`),
///    or rolled back at once when its binary fails the start check before the restart.
///
/// It sends SIGKILL only as the guard's last resort for a member that
/// ignored a SIGTERM for the whole grace; an operator stop always waits.
final class ClusterMemberSupervisor: @unchecked Sendable {
    /// The cluster service route's coordinated update and candidate recovery.
    struct PairUpdate: Sendable {
        /// The pairing's cluster ID, the same on both Macs: it fixes the update slot. Read at each slot.
        var clusterID: @Sendable () -> String?
        /// One coordinated update cycle (`ClusterPairUpdateCycle.run`) for `request` (a `darkbloom update`), logging
        /// with `log`; `restart` stops the service so the supervisor starts again from the installed binary.
        var run: @Sendable (_ request: String?, _ log: @escaping @Sendable (String) -> Void,
                            _ restart: @escaping @Sendable (String) async throws -> Void) async -> AutoUpdateController.Outcome
        /// Where `darkbloom update` asks for a restart into the release it installed (`ClusterPairUpdate.Request`).
        var requestPath: URL
        /// Where this Mac's progress is written; idle (or disabled) outside a cycle.
        var progressPath: URL
        var recovery: ClusterCandidateRecovery?
        /// Whether the service's published status says this Mac's part serves again (logged once after an update).
        var partServes: @Sendable () -> Bool = { false }
        /// One check whether the other Mac rolled back the release this Mac runs, and if so the same rollback here
        /// (`ClusterPairUpdateCycle.followRollback`), run every `ClusterPairUpdate.followCheckSeconds` while no cycle runs.
        var follow: @Sendable (_ log: @escaping @Sendable (String) -> Void,
                               _ restart: @escaping @Sendable (String) async throws -> Void) async
            -> ClusterPairUpdateCycle.FollowOutcome = { _, _ in .nothingToFollow }
        /// The release quarantined on this Mac, which its progress reports to the other Mac.
        var quarantined: @Sendable () -> String? = { nil }
    }

    struct Configuration {
        var executable: String
        var childArguments: [String]
        var environment: [String: String]
        var statePath: URL
        var healthPath: URL
        var setup: ClusterMemberSupervisionSetup?
        var coordinatorURL: String
        var autoUpdate: Bool
        var budgetLimits: ClusterMemberRestartBudget.Limits
        var guardLimits: ClusterMemberLivenessGuard.Limits
        /// SIGTERM grace for a member the guard recycles before the last-resort SIGKILL.
        var recycleGraceSeconds: Double = 300
        /// The original argv, for re-executing after an update.
        var reexecArguments: [String]
        /// How its log lines start: the member's supervisor, or the cluster service's (login agent).
        var logName: String = "cluster-member supervisor"
        /// What the operator runs to start again after the budget is spent.
        var restartHint: String = "`\(ClusterPairSummary.cli) restart` (or `\(ClusterPairSummary.cli) stop` then start)"
        /// How often a running member is checked for its end and its next probe.
        var childPollSeconds: Double = 0.5
        /// The cluster service route's coordinated update; nil on the member route, which uses the slot above.
        var pairUpdate: PairUpdate? = nil
        /// Replaces this process with the installed binary (`execv`); a test observes the call instead.
        var reexec: (@Sendable ([String]) -> Void)? = nil
        /// How long that binary may take to pass its start check first (`ClusterCandidateRecovery.startCheckFailure`).
        var startCheckTimeoutSeconds = ClusterCandidateRecovery.startCheckTimeoutSeconds
        /// The orphan sweep before every run signals this user's orphaned cluster processes; a test never does.
        var sweepsOrphans = true
        /// Why another Darkbloom build holds this Mac's GPU now (`ClusterGPUHold.now`); a test stands in.
        var gpuHold: @Sendable () -> String? = { ClusterGPUHold.now() }
        /// How often a member held back by another build's hold on the GPU looks again.
        var gpuHoldPollSeconds: Double = 2
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var stopRequested = false
    private var child: Process?
    private var state: ClusterMemberSupervisorState
    private var budget: ClusterMemberRestartBudget
    // The coordinated update of the cluster service route: the next slot (main loop only), whether a cycle runs and
    // the version it asked to restart into (under `lock`, set from the cycle's task).
    private var pairSlot: Double?
    private var pairCycle: Task<Void, Never>?
    private var pairCycleRunning = false
    private var requestedRestart: String?
    // When the next check for a rollback of the other Mac to follow is due (main loop only), and the last reason it
    // could not be followed (under `lock`), said once.
    private var nextFollowCheck: Double = 0
    private var followNotice: String?
    /// A deferred follow is tried again only at the pair's next update slot, as a deferred update is (under `lock`).
    private var followDeferredUntil: Double = 0
    /// The newer release the other Mac runs, which the next tick updates to without waiting for the slot, and the one
    /// already tried that way (under `lock`): one immediate cycle per release, then the slots as usual.
    private var forwardDue: String?
    private var forwardTried: String?
    // The candidate this run's service is (main loop only), until it is promoted.
    private var candidate: String?
    private var updatedServiceServes = false

    init(configuration: Configuration) {
        self.configuration = configuration
        budget = ClusterMemberRestartBudget(limits: configuration.budgetLimits)
        let now = Date().timeIntervalSince1970
        state = ClusterMemberSupervisorState(
            supervisorPID: getpid(), version: ProviderCore.version,
            bootTime: now - ProcessInfo.processInfo.systemUptime, phase: .waitingForLink,
            budget: budget, updatedAt: now)
    }

    // MARK: - Signals

    /// SIGTERM/SIGINT: an operator stop. Forwarded to the member, never escalated.
    func requestStop() {
        let current: Process? = lock.withLock {
            stopRequested = true
            return child
        }
        if let current, current.isRunning {
            log("stop requested; asking member pid \(current.processIdentifier) to stop (SIGTERM, no deadline)")
            kill(current.processIdentifier, SIGTERM)
        }
    }

    private var isStopping: Bool { lock.withLock { stopRequested } }

    // MARK: - Main loop

    /// Returns the process exit code: 0 after an operator stop or a parked
    /// budget the operator then stopped; 1 when another supervisor holds the lock.
    func run() async -> Int32 {
        guard let lockFD = acquireLock() else {
            log("another cluster-member supervisor already runs for \(configuration.statePath.lastPathComponent); not starting a second")
            return 1
        }
        defer { close(lockFD) }
        let supervised = configuration.setup.map { "member \($0.role) on \($0.linkDevice)" }
            ?? "`\(configuration.childArguments.prefix(2).joined(separator: " "))`"
        log("supervisor \(ProviderCore.version) started: \(supervised); budget \(budget.limits.maxQuickFailures) quick failures "
            + "in \(Int(budget.limits.quickFailureWindowSeconds)) s, backoff \(budget.limits.initialBackoffSeconds)-"
            + "\(budget.limits.maxBackoffSeconds) s; heartbeat down \(Int(configuration.guardLimits.downSeconds)) s after "
            + "\(Int(configuration.guardLimits.startGraceSeconds)) s grace")
        // What macOS keys the one-time Local Network and firewall approvals on.
        log(ClusterMemberPermissionIdentity.current(executablePath: configuration.executable).summary)
        var updateSlot = configuration.setup.map {
            ClusterMemberUpdateSlot.nextSlot(after: Date().timeIntervalSince1970, clusterID: $0.clusterID)
        }
        if let pair = configuration.pairUpdate {
            // A cycle of an earlier supervisor run is over: the other Mac must not wait for it.
            ClusterPairUpdate.writeProgress(restingProgress(now: Date().timeIntervalSince1970), to: pair.progressPath)
            log(configuration.autoUpdate
                ? "cluster update: automatic updates on; both Macs check at the pair's update slot every \(Int(ClusterMemberUpdateSlot.periodSeconds / 60)) min"
                : "cluster update: automatic updates are off (auto_update, DARKBLOOM_NO_UPDATE_CHECK); `darkbloom update` still updates the pair")
        }
        while !isStopping {
            guard await waitForLink() else { break }
            // Before every run (the first and each restart): nothing of the
            // previous run or of a dead session may be left, so a restart
            // never counts a leftover as a crash and never loads over memory
            // an orphan still holds (the owner's auto_restart orphan gate).
            await sweepOrphansBeforeRun()
            let outcome = await superviseOneRun(updateSlot: &updateSlot)
            switch outcome {
            case .stopped:
                break
            case .updateInstalled(let version):
                if let version, let failure = await startCheckFailure(version) {
                    stayAfterFailedStartCheck(of: version, failure: failure)
                    continue
                }
                reexecAfterUpdate()
                // execv returned: the new binary could not be started; keep the old one running.
                log("re-exec after the update failed; starting the member from this binary")
                continue
            case .updateDrainedWithoutInstall:
                continue
            case .ended(let end, let runSeconds, let detail, let recycled):
                if let restored = recordCandidateEnd(end, recycled: recycled, detail: detail) {
                    if let failure = await startCheckFailure(restored) {
                        log("cluster update: the restored v\(restored) failed its start check (\(failure)), so the supervisor "
                            + "does not restart into it; starting the cluster service again from this supervisor")
                        continue
                    }
                    reexecAfterUpdate()
                    log("re-exec after the rollback failed; starting the member from this binary")
                    continue
                }
                let decision = budget.record(end, runSeconds: runSeconds)
                state.budget = budget
                switch decision {
                case .stop:
                    break
                case .restart(let wait):
                    log("member ended after \(Int(runSeconds)) s (\(detail)); restarting in \(wait) s "
                        + "(quick failures \(budget.quickFailures)/\(budget.limits.maxQuickFailures), "
                        + "guard teardowns \(budget.guardTeardowns)/\(budget.limits.maxGuardTeardowns))")
                    update(phase: .backoff, detail: detail, restartAt: Date().timeIntervalSince1970 + Double(wait))
                    await sleepInterruptibly(seconds: Double(wait))
                    continue
                case .exhausted(let reason):
                    log("member ended after \(Int(runSeconds)) s (\(detail)); \(reason). Nothing runs until "
                        + "\(configuration.restartHint); see the log")
                    update(phase: .exhausted, detail: reason)
                    while !isStopping { await sleepInterruptibly(seconds: 3600) }
                case .waitForGPU:
                    await waitForGPU(after: runSeconds, detail: detail)
                    continue
                }
            }
            if isStopping || state.phase == .exhausted { break }
        }
        update(phase: .stopped, detail: "operator stop")
        log("supervisor stopped")
        return 0
    }

    // MARK: - Another build's hold on the GPU

    /// The member ended because another Darkbloom build holds this Mac's GPU, or production serves here
    /// (`ClusterMemberRunEnd.gpuHeld`): a wait, never a failure, so the restart budget is not spent. The member starts
    /// again as soon as the hold ends. A hold already over by now starts it after the first backoff, so refusals that
    /// keep coming never spin.
    private func waitForGPU(after runSeconds: Double, detail: String) async {
        var said: String?
        while !isStopping, let hold = configuration.gpuHold() {
            if hold != said {
                log("member ended after \(Int(runSeconds)) s (\(detail)): \(hold) The member waits for it; not counted")
                update(phase: .backoff, detail: hold)
                said = hold
            }
            await sleepInterruptibly(seconds: configuration.gpuHoldPollSeconds)
        }
        guard !isStopping else { return }
        if said != nil {
            log("this Mac's GPU is free again: starting the member")
            return
        }
        let wait = budget.limits.initialBackoffSeconds
        log("member ended after \(Int(runSeconds)) s (\(detail)); starting it again in \(wait) s, not counted")
        update(phase: .backoff, detail: detail, restartAt: Date().timeIntervalSince1970 + Double(wait))
        await sleepInterruptibly(seconds: Double(wait))
    }

    // MARK: - Orphan sweep

    /// The orphan sweep on the supervisor's own clock; the member it starts
    /// sweeps again at its start. Waits for a leftover's contract (bounded),
    /// so a member recycled a moment ago is given its own exit first.
    private func sweepOrphansBeforeRun() async {
        guard configuration.sweepsOrphans else { return }
        let outcome = await Task.detached(priority: .utility) { () -> String? in
            do { return ClusterOrphanSweep.summary(try ClusterOrphanSweep.reap(waitForContract: true)) }
            catch { return "orphan sweep skipped: \(error)" }
        }.value
        if let outcome { log(outcome) }
    }

    // MARK: - Link gate

    private func waitForLink() async -> Bool {
        guard let device = configuration.setup?.linkDevice else { return !isStopping }
        update(phase: .waitingForLink, detail: "checking \(device)")
        var failingSince: Double?
        var lastLogged: (ClusterLinkReadinessState, Double)?
        while !isStopping {
            let reading = await Task.detached { ClusterMemberSupervisionSetup.inspectLink(device: device) }.value
            let now = Date().timeIntervalSince1970
            let failing = reading.machine == .probeFailed || reading.device == nil || reading.device == .probeFailed
            if failing { failingSince = failingSince ?? now } else { failingSince = nil }
            let decision = ClusterMemberLinkGate.decide(machine: reading.machine, device: reading.device,
                probeFailingForSeconds: Int(now - (failingSince ?? now)))
            switch decision {
            case .ready:
                log("cluster link \(device) is ready" + (lastLogged == nil ? "" : " after waiting"))
                return true
            case .proceedUnverified:
                log("cluster link readings keep failing; starting the member and letting its own launch check decide")
                return true
            case .wait(let linkState), .blocked(let linkState):
                if ClusterMemberLinkGate.shouldLog(state: linkState, previous: lastLogged?.0,
                                                   secondsSinceLastLog: now - (lastLogged?.1 ?? 0)) {
                    log("waiting for the cluster link before registering: \(device) is \(linkState.rawValue). "
                        + (linkState.guidance ?? ""))
                    lastLogged = (linkState, now)
                }
                update(phase: .waitingForLink, detail: "\(device) is \(linkState.rawValue)")
                let recheck: Int
                if case .blocked = decision { recheck = ClusterMemberLinkGate.blockedRecheckSeconds }
                else { recheck = ClusterMemberLinkGate.recheckSeconds }
                await sleepInterruptibly(seconds: Double(recheck))
            }
        }
        return false
    }

    // MARK: - One run

    private enum RunOutcome {
        case stopped
        /// `recycled`: the supervisor's liveness guard asked the member to stop.
        case ended(ClusterMemberRunEnd, runSeconds: Double, detail: String, recycled: Bool)
        /// A release is installed: the supervisor restarts into it. `version`: the release the pair's cycle installed,
        /// which passes the start check first; nil on the member route, whose job the watchdog recovers.
        case updateInstalled(version: String?)
        case updateDrainedWithoutInstall
    }

    private func superviseOneRun(updateSlot: inout Double?) async -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.childArguments
        var environment = configuration.environment
        environment[ClusterSupervisionFiles.healthPathEnvironmentKey] = configuration.healthPath.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        try? FileManager.default.removeItem(at: configuration.healthPath)
        let started = Date().timeIntervalSince1970
        noteCandidateLaunch(now: started)
        do {
            try lock.withLock {
                guard !stopRequested else { throw CancellationError() }
                try process.run()
                child = process
            }
        } catch is CancellationError {
            return .stopped
        } catch {
            log("could not start the member: \(error)")
            return .ended(.failure(exitCode: -1), runSeconds: 0, detail: "spawn failed: \(error)", recycled: false)
        }
        let pid = process.processIdentifier
        state.runs += 1
        state.current = .init(pid: pid, startedAt: started)
        update(phase: .running, detail: nil)
        log("member started: pid \(pid) (run \(state.runs))")

        var livenessGuard = ClusterMemberLivenessGuard(limits: configuration.guardLimits)
        var recycleReason: String?
        var drainedForUpdate: UpdateIntent?
        var nextProbe = started + configuration.guardLimits.intervalSeconds
        var lastHealthPhase: ClusterMemberHealth.Phase?
        var restarting = false
        while process.isRunning {
            // A plain sleep: during an operator stop the member may take long
            // to drain, and an interruptible sleep would spin.
            try? await Task.sleep(nanoseconds: UInt64(configuration.childPollSeconds * 1_000_000_000))
            let now = Date().timeIntervalSince1970
            guard process.isRunning, now >= nextProbe else { continue }
            nextProbe = now + configuration.guardLimits.intervalSeconds
            if !restarting, let version = lock.withLock({ requestedRestart }) {
                restarting = true
                update(phase: .updating, detail: "restarting into v\(version)")
            }
            if isStopping || recycleReason != nil || drainedForUpdate != nil || restarting { continue }
            let health = ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: configuration.healthPath)
            if let phase = health.flatMap({ $0.pid == pid ? $0.phase : nil }), phase != lastHealthPhase {
                log("member pid \(pid) is \(phase.rawValue)" + (health?.warmup.map { "; warmup \($0)" } ?? ""))
                lastHealthPhase = phase
            }
            switch livenessGuard.observe(health: health, childPID: pid, runStartedAt: started, now: now) {
            case .recycle(let reason):
                recycleReason = reason
                log("liveness guard: \(reason); asking member pid \(pid) to stop (SIGTERM), then restarting it")
                kill(pid, SIGTERM)
                Task.detached { [weak self] in await self?.escalateIfStuck(pid: pid, reason: reason) }
            case .downFor(let seconds):
                log("member pid \(pid) heartbeat missing for \(Int(seconds)) s")
            case .healthy, .starting:
                break
            }
            if recycleReason == nil, let slot = updateSlot, configuration.autoUpdate {
                let busy = health.map { $0.pid == pid && ($0.busy == true || $0.activeRequest != nil) } ?? false
                switch ClusterMemberUpdateSlot.decide(now: now, slot: slot, busy: busy) {
                case .wait, .deferBusy:
                    break
                case .skip:
                    log("update slot skipped: the pair stayed busy")
                    updateSlot = configuration.setup.map { ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: $0.clusterID) }
                case .check:
                    updateSlot = configuration.setup.map { ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: $0.clusterID) }
                    if let intent = await checkForUpdate() {
                        drainedForUpdate = intent
                        log("coordinated update: \(intent.description); draining member pid \(pid) (SIGTERM)")
                        update(phase: .updating, detail: intent.description)
                        kill(pid, SIGTERM)
                    }
                }
            }
            if recycleReason == nil, let pair = configuration.pairUpdate {
                observeCandidate(pair, health: health, pid: pid, started: started, now: now)
                startPairCycleIfDue(pair, pid: pid, now: now)
            }
        }
        // The loop above already saw the member end (`isRunning` is false, so its status is final). No blocking
        // `waitUntilExit()` here: it parks this thread in its own run loop until a termination message arrives, and
        // on a Swift-concurrency thread that message can go to another thread's run loop, so the supervisor waited
        // forever after its member ended and never restarted it (sampled stuck in -[NSConcreteTask waitUntilExit]).
        lock.withLock { child = nil }
        let ended = Date().timeIntervalSince1970
        let signal: Int32? = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        let exitCode: Int32? = process.terminationReason == .exit ? process.terminationStatus : nil
        await endPairCycle()
        if let version = lock.withLock({ () -> String? in defer { requestedRestart = nil }; return requestedRestart }), !isStopping {
            state.lastRun = .init(pid: pid, startedAt: started, endedAt: ended, exitCode: exitCode, signal: signal,
                                  end: "stopped to restart into v\(version)")
            state.current = nil
            candidate = nil
            return .updateInstalled(version: version)
        }
        if let intent = drainedForUpdate, !isStopping {
            state.lastRun = .init(pid: pid, startedAt: started, endedAt: ended, exitCode: exitCode, signal: signal,
                                  end: "drained for update")
            state.current = nil
            return await applyUpdate(intent) ? .updateInstalled(version: nil) : .updateDrainedWithoutInstall
        }
        let end = ClusterMemberRunEnd.classify(stopRequested: isStopping, exitCode: exitCode, signal: signal)
        let detail: String
        switch end {
        case .operatorStop: detail = "operator stop"
        case .guardTeardown: detail = "JACCL guard teardown (exit 75)"
        case .gpuHeld: detail = "another Darkbloom build held this Mac's GPU (exit \(ClusterMemberRunEnd.gpuHeldExitCode))"
        case .failure(let code): detail = recycleReason.map { "recycled by the liveness guard: \($0)" } ?? "exit \(code)"
        case .signaled(let number): detail = recycleReason.map { "recycled by the liveness guard: \($0)" } ?? "signal \(number)"
        }
        state.lastRun = .init(pid: pid, startedAt: started, endedAt: ended, exitCode: exitCode, signal: signal, end: detail)
        state.current = nil
        if end == .operatorStop { return .stopped }
        return .ended(end, runSeconds: ended - started, detail: detail, recycled: recycleReason != nil)
    }

    /// The guard's last resort: a member that ignored SIGTERM for the whole
    /// grace. Its native owner and workers watch their parent and release
    /// their memory when it is gone (S00).
    private func escalateIfStuck(pid: Int32, reason: String) async {
        // Only the supervisor's current, still-running child: a reaped pid
        // may already belong to another process.
        func stillRunning() -> Bool { lock.withLock { child?.processIdentifier == pid && child?.isRunning == true } }
        let deadline = Date().timeIntervalSince1970 + configuration.recycleGraceSeconds
        while stillRunning(), Date().timeIntervalSince1970 < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard stillRunning(), !isStopping else { return }
        log("member pid \(pid) ignored SIGTERM for \(Int(configuration.recycleGraceSeconds)) s after the guard recycled it "
            + "(\(reason)); sending SIGKILL as the last resort")
        kill(pid, SIGKILL)
    }

    // MARK: - Coordinated update

    private enum UpdateIntent: CustomStringConvertible {
        case install(from: String, to: String)
        case restartInto(installed: String)
        var description: String {
            switch self {
            case .install(let from, let to): return "release \(to) available (running \(from))"
            case .restartInto(let installed): return "release \(installed) already installed; restarting into it"
            }
        }
    }

    private func checkForUpdate() async -> UpdateIntent? {
        let updater = SelfUpdater(coordinatorBaseURL: configuration.coordinatorURL)
        switch await updater.checkForUpdate() {
        case .updateAvailable(let current, let release):
            return .install(from: current, to: release.version)
        case .restartRequired(_, let installed):
            return .restartInto(installed: installed)
        case .upToDate, .quarantined, .checkFailed:
            return nil
        }
    }

    private func applyUpdate(_ intent: UpdateIntent) async -> Bool {
        switch intent {
        case .restartInto:
            return true
        case .install:
            let result = await SelfUpdater(coordinatorBaseURL: configuration.coordinatorURL).update()
            switch result {
            case .updated(let from, let to):
                log("coordinated update installed \(to) (was \(from))")
                return true
            case .restartRequired(_, let to):
                log("coordinated update: \(to) already installed")
                return true
            default:
                log("coordinated update not installed: \(result); starting the member again on this version")
                return false
            }
        }
    }

    private func reexecAfterUpdate() {
        update(phase: .updating, detail: "starting the installed binary")
        let arguments = configuration.reexecArguments
        guard let program = arguments.first else { return }
        log("re-executing \(program) to start the installed release")
        if let reexec = configuration.reexec { return reexec(arguments) }
        var cArguments = arguments.map { strdup($0) }
        cArguments.append(nil)
        execv(program, &cArguments)
        for pointer in cArguments { free(pointer) }
    }

    // MARK: - The cluster service's coordinated update

    /// At the pair's update slot (with automatic updates on), or for a `darkbloom update` request, one cycle runs
    /// beside the service it supervises, which keeps serving until the cycle asks for the restart.
    private func startPairCycleIfDue(_ pair: PairUpdate, pid: Int32, now: Double) {
        guard !lock.withLock({ pairCycleRunning }) else { return }
        if pairSlot == nil, let clusterID = pair.clusterID() {
            pairSlot = ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: clusterID)
        }
        let request = ClusterPairUpdate.takeRequest(from: pair.requestPath, now: now)
        let slotDue = pairSlot.map { now >= $0 } ?? false
        if let request {
            log("cluster update: `darkbloom update` asked for a restart into the installed release together with the other Mac (\(request.id.prefix(8)))")
        } else if !configuration.autoUpdate {
            restAsDisabled(pair, now: now)
            return startFollowCheckIfDue(pair, pid: pid, now: now)
        } else if !slotDue, lock.withLock({ forwardDue }) == nil {
            return startFollowCheckIfDue(pair, pid: pid, now: now)
        }
        lock.withLock {
            if let due = forwardDue { forwardTried = due }
            forwardDue = nil
        }
        // A cycle at or after the slot is that slot's.
        if slotDue { pairSlot = pair.clusterID().map { ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: $0) } }
        lock.withLock { pairCycleRunning = true }
        let log: @Sendable (String) -> Void = { [weak self] in self?.log($0) }
        let restart: @Sendable (String) async throws -> Void = { [weak self] version in
            try self?.restartForUpdate(into: version, pid: pid)
        }
        pairCycle = Task.detached { [weak self] in
            _ = await pair.run(request?.id, log, restart)
            guard let self else { return }
            self.lock.withLock { self.pairCycleRunning = false }
        }
    }

    /// While no cycle runs, every `ClusterPairUpdate.followCheckSeconds` (and at once after a start): whether the other
    /// Mac rolled back the release this Mac runs, which this Mac then follows, as a cycle of its own. Automatic updates
    /// off do not stop it: it restores a release this Mac ran before, as a rollback after failed starts does.
    private func startFollowCheckIfDue(_ pair: PairUpdate, pid: Int32, now: Double) {
        guard now >= nextFollowCheck, now >= lock.withLock({ followDeferredUntil }) else { return }
        nextFollowCheck = now + ClusterPairUpdate.followCheckSeconds
        publishQuarantine(pair)
        lock.withLock { pairCycleRunning = true }
        let log: @Sendable (String) -> Void = { [weak self] in self?.log($0) }
        let restart: @Sendable (String) async throws -> Void = { [weak self] version in
            try self?.restartForUpdate(into: version, pid: pid)
        }
        pairCycle = Task.detached { [weak self] in
            let outcome = await pair.follow(log, restart)
            guard let self else { return }
            // Each reason is said once, until the outcome changes.
            let notice: String?
            switch outcome {
            case .cannotFollow(let reason): notice = "not following the other Mac's rollback: " + reason
            case .otherMacStillRuns(let reason): notice = reason
            case .otherMacNewer(let version): notice = self.followForward(version)
            default: notice = nil
            }
            // From the deferral, not the check's start: a follow that ran past a slot waits for the next.
            var deferredUntil: Double?
            if case .followed(let ended) = outcome {
                if case .restarted = ended {} else {
                    let now = Date().timeIntervalSince1970
                    deferredUntil = pair.clusterID().map { ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: $0) }
                        ?? now + ClusterMemberUpdateSlot.periodSeconds
                }
            }
            let say: String? = self.lock.withLock {
                defer { self.pairCycleRunning = false; self.followNotice = notice }
                if let deferredUntil { self.followDeferredUntil = deferredUntil }
                return notice == self.followNotice ? nil : notice
            }
            if let say { self.log("cluster update: \(say)") }
        }
    }

    /// The other Mac runs `version`, newer than this Mac's: with automatic updates on, the next tick runs the pair's cycle
    /// at once (once per release; after that, the slots), which finds the other Mac ready. The line says what happens.
    private func followForward(_ version: String) -> String {
        let here = "the other Mac runs v\(version), newer than this Mac's v\(ProviderCore.version)"
        guard configuration.autoUpdate else {
            return here + ", and automatic updates are off on this Mac: run `\(BuildEnvironment.current.cliName) update` on this Mac"
        }
        return lock.withLock {
            guard forwardTried != version else { return here + ": this Mac tries again at the pair's next update slot" }
            forwardDue = version
            return here + ": updating this Mac now, without waiting for the pair's update slot"
        }
    }

    /// A rollback since the progress was written (a candidate's third failed start, while no cycle ran) reaches the
    /// other Mac with the next follow check: only the quarantine changes, the rest stays as the last cycle left it.
    private func publishQuarantine(_ pair: PairUpdate) {
        guard var progress = ClusterPairUpdate.readProgress(from: pair.progressPath) else { return }
        let quarantined = pair.quarantined()
        guard progress.quarantined != quarantined else { return }
        progress.quarantined = quarantined
        ClusterPairUpdate.writeProgress(progress, to: pair.progressPath)
    }

    /// This Mac outside a cycle: idle, or disabled while its automatic updates are off.
    private func restingProgress(now: Double) -> ClusterPairUpdateProgress {
        .init(phase: configuration.autoUpdate ? .idle : .disabled, running: ProviderCore.version, writtenAt: now,
              quarantined: configuration.pairUpdate?.quarantined())
    }

    /// With automatic updates off, the end of a cycle `darkbloom update` asked for stays the other Mac's (and the
    /// command's) answer for a minute; then this Mac says `disabled` again, or the other Mac's every slot would download
    /// the release and wait for this one.
    private func restAsDisabled(_ pair: PairUpdate, now: Double) {
        let last = ClusterPairUpdate.readProgress(from: pair.progressPath)
        guard last?.phase != .disabled, now - (last?.writtenAt ?? 0) > ClusterPairUpdate.progressStaleSeconds else { return }
        ClusterPairUpdate.writeProgress(restingProgress(now: now), to: pair.progressPath)
    }

    /// The cycle's restart, once both Macs drained and the release is installed: the service stops (its drained part
    /// with it) and the supervisor starts again from the installed binary.
    private func restartForUpdate(into version: String, pid: Int32) throws {
        let running: Process? = lock.withLock {
            guard !stopRequested, let current = child, current.processIdentifier == pid, current.isRunning else { return nil }
            requestedRestart = version
            return current
        }
        guard running != nil else { throw CancellationError() }
        log("cluster update: v\(version) installed; stopping the cluster service (pid \(pid), SIGTERM) to start again from it")
        kill(pid, SIGTERM)
    }

    /// The run ended: a cycle still running belonged to the service that ended. Its cancellation undoes the part's
    /// drain and keeps nothing staged.
    private func endPairCycle() async {
        guard let cycle = pairCycle else { return }
        cycle.cancel()
        await cycle.value
        pairCycle = nil
    }

    /// Before each start of the service: a release installed and not yet promoted is a candidate (`ClusterCandidateRecovery`),
    /// once the update record is reconciled with the installed app.
    private func noteCandidateLaunch(now: Double) {
        candidate = nil
        guard let recovery = configuration.pairUpdate?.recovery,
              case .candidate(let version, let failed) = recovery.noteLaunch(now: now, log: { log("cluster update: \($0)") })
        else { return }
        candidate = version
        updatedServiceServes = false
        log("cluster update: starting the cluster service on candidate v\(version)"
            + (failed > 0 ? " (\(failed) failed start\(failed == 1 ? "" : "s") so far)" : "")
            + "; it is promoted once its service stays healthy, rolled back after \(UpdateRecoveryState.rollbackThreshold) failed starts")
    }

    /// The candidate's health is the service's own heartbeat: from this run's process, with the candidate version,
    /// fresh. It promotes the candidate once continuous for the stabilization window, as the watchdog's daemon-state
    /// heartbeat does for a single Mac.
    private func observeCandidate(_ pair: PairUpdate, health: ClusterMemberHealth?, pid: Int32, started: Double, now: Double) {
        guard let version = candidate, let recovery = pair.recovery else { return }
        if !updatedServiceServes, pair.partServes() {
            updatedServiceServes = true
            log("cluster update: this Mac's part serves again on v\(version)")
        }
        let healthy = health.map { $0.pid == pid && $0.version == version && now - $0.writtenAt <= Self.candidateHeartbeatSeconds } ?? false
        switch recovery.observe(healthy: healthy, processStartedAt: started, now: now) {
        case .promoted(let promoted):
            candidate = nil
            log("cluster update: v\(promoted) promoted: its cluster service stayed healthy through the stabilization window")
        case .noCandidate:
            candidate = nil
        case .stabilizing:
            break
        }
    }

    /// A service heartbeat (every 2 s) older than this does not count toward promotion.
    static let candidateHeartbeatSeconds: Double = 30

    /// A candidate's service that ended without being asked to by this supervisor is a failed start, unless it stopped
    /// cleanly when asked to from outside (`ClusterCandidateRecovery.endIsFailedStart`); returns the verified predecessor
    /// the third restored, which the supervisor then starts again from.
    private func recordCandidateEnd(_ end: ClusterMemberRunEnd, recycled: Bool, detail: String) -> String? {
        guard let version = candidate, let recovery = configuration.pairUpdate?.recovery else { return nil }
        candidate = nil
        guard ClusterCandidateRecovery.endIsFailedStart(end, recycled: recycled) else {
            log("cluster update: v\(version)'s cluster service stopped cleanly when asked to from outside this supervisor "
                + "(\(detail)); not a failed start")
            return nil
        }
        switch recovery.recordFailedStart(now: Date().timeIntervalSince1970, log: { log("cluster update: \($0)") }) {
        case .counted(let version, let failures):
            log("cluster update: v\(version) failed start \(failures)/\(UpdateRecoveryState.rollbackThreshold) (\(detail))")
            return nil
        case .rolledBack(let from, let to):
            log("cluster update: v\(from) failed \(UpdateRecoveryState.rollbackThreshold) starts; restored v\(to) and quarantined v\(from)")
            return to
        case .rollbackRefused(let version, let reason):
            log("cluster update: rolling v\(version) back was refused (\(reason)); the installed release is kept and tried again later")
            return nil
        case .notCandidate:
            return nil
        }
    }

    /// Before this process replaces itself (`execv`) with the installed `version`, on the route that rolls releases
    /// back (`PairUpdate.recovery`), that binary runs once as its child (`ClusterCandidateRecovery.startCheckFailure`).
    /// Nil when it passed, or when there is no check to run.
    private func startCheckFailure(_ version: String) async -> String? {
        guard configuration.pairUpdate?.recovery != nil, let program = configuration.reexecArguments.first else { return nil }
        let timeout = configuration.startCheckTimeoutSeconds
        return await Task.detached {
            ClusterCandidateRecovery.startCheckFailure(executable: program, version: version, timeout: timeout)
        }.value
    }

    /// A release that failed its start check would fail every start, and after an `execv` no supervisor would be left
    /// to count them: this supervisor stays, restores the verified predecessor and quarantines the release at once,
    /// then starts the cluster service again from what is installed. The cycle that asked for the restart is over.
    private func stayAfterFailedStartCheck(of version: String, failure: String) {
        guard let pair = configuration.pairUpdate, let recovery = pair.recovery else { return }
        let now = Date().timeIntervalSince1970
        let outcome: String
        switch recovery.recordFailedStartCheck(version: version, reason: failure, now: now) {
        case .rolledBack(_, let restored):
            outcome = "restored v\(restored) and quarantined v\(version)"
        case .rollbackRefused(_, let reason):
            outcome = "rolling it back was refused (\(reason)); the installed release is kept"
        case .counted, .notCandidate:
            outcome = "it was not rolled back (another update holds the lease, or it is no longer the pending release)"
        }
        log("cluster update: v\(version) failed its start check (\(failure)), so the supervisor does not restart into it; \(outcome)")
        ClusterPairUpdate.writeProgress(restingProgress(now: now), to: pair.progressPath)
    }

    // MARK: - Helpers

    private func acquireLock() -> Int32? {
        let path = ClusterSupervisionFiles.lockPath(forState: configuration.statePath)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    private func update(phase: ClusterMemberSupervisorState.Phase, detail: String?, restartAt: Double? = nil) {
        state.phase = phase
        state.detail = detail
        state.restartAt = restartAt
        state.budget = budget
        state.updatedAt = Date().timeIntervalSince1970
        ClusterSupervisionFiles.write(state, to: configuration.statePath)
    }

    private func sleepInterruptibly(seconds: Double) async {
        let deadline = Date().timeIntervalSince1970 + seconds
        while !isStopping, Date().timeIntervalSince1970 < deadline {
            let remaining = deadline - Date().timeIntervalSince1970
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, min(0.5, remaining)) * 1_000_000_000))
        }
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(configuration.logName): \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
