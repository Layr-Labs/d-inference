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
///    starts again from the new binary (`ClusterMemberUpdateSlot`).
///
/// It sends SIGKILL only as the guard's last resort for a member that
/// ignored a SIGTERM for the whole grace; an operator stop always waits.
final class ClusterMemberSupervisor: @unchecked Sendable {
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
        var restartHint: String = "`darkbloom restart` (or `darkbloom stop` then start)"
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var stopRequested = false
    private var child: Process?
    private var state: ClusterMemberSupervisorState
    private var budget: ClusterMemberRestartBudget

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
            case .updateInstalled:
                reexecAfterUpdate()
                // execv returned: the new binary could not be started; keep the old one running.
                log("re-exec after the update failed; starting the member from this binary")
                continue
            case .updateDrainedWithoutInstall:
                continue
            case .ended(let end, let runSeconds, let detail):
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
                }
            }
            if isStopping || state.phase == .exhausted { break }
        }
        update(phase: .stopped, detail: "operator stop")
        log("supervisor stopped")
        return 0
    }

    // MARK: - Orphan sweep

    /// The orphan sweep on the supervisor's own clock; the member it starts
    /// sweeps again at its start. Waits for a leftover's contract (bounded),
    /// so a member recycled a moment ago is given its own exit first.
    private func sweepOrphansBeforeRun() async {
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
        case ended(ClusterMemberRunEnd, runSeconds: Double, detail: String)
        case updateInstalled
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
            return .ended(.failure(exitCode: -1), runSeconds: 0, detail: "spawn failed: \(error)")
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
        while process.isRunning {
            // A plain sleep: during an operator stop the member may take long
            // to drain, and an interruptible sleep would spin.
            try? await Task.sleep(nanoseconds: 500_000_000)
            let now = Date().timeIntervalSince1970
            guard process.isRunning, now >= nextProbe else { continue }
            nextProbe = now + configuration.guardLimits.intervalSeconds
            if isStopping || recycleReason != nil || drainedForUpdate != nil { continue }
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
        }
        // The loop above already saw the member end (`isRunning` is false, so its status is final). No blocking
        // `waitUntilExit()` here: it parks this thread in its own run loop until a termination message arrives, and
        // on a Swift-concurrency thread that message can go to another thread's run loop, so the supervisor waited
        // forever after its member ended and never restarted it (sampled stuck in -[NSConcreteTask waitUntilExit]).
        lock.withLock { child = nil }
        let ended = Date().timeIntervalSince1970
        let signal: Int32? = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        let exitCode: Int32? = process.terminationReason == .exit ? process.terminationStatus : nil
        if let intent = drainedForUpdate, !isStopping {
            state.lastRun = .init(pid: pid, startedAt: started, endedAt: ended, exitCode: exitCode, signal: signal,
                                  end: "drained for update")
            state.current = nil
            return await applyUpdate(intent) ? .updateInstalled : .updateDrainedWithoutInstall
        }
        let end = ClusterMemberRunEnd.classify(stopRequested: isStopping, exitCode: exitCode, signal: signal)
        let detail: String
        switch end {
        case .operatorStop: detail = "operator stop"
        case .guardTeardown: detail = "JACCL guard teardown (exit 75)"
        case .failure(let code): detail = recycleReason.map { "recycled by the liveness guard: \($0)" } ?? "exit \(code)"
        case .signaled(let number): detail = recycleReason.map { "recycled by the liveness guard: \($0)" } ?? "signal \(number)"
        }
        state.lastRun = .init(pid: pid, startedAt: started, endedAt: ended, exitCode: exitCode, signal: signal, end: detail)
        state.current = nil
        if end == .operatorStop { return .stopped }
        return .ended(end, runSeconds: ended - started, detail: detail)
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
        update(phase: .updating, detail: "starting the updated binary")
        let arguments = configuration.reexecArguments
        guard let program = arguments.first else { return }
        log("re-executing \(program) after the coordinated update")
        var cArguments = arguments.map { strdup($0) }
        cArguments.append(nil)
        execv(program, &cArguments)
        for pointer in cArguments { free(pointer) }
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
