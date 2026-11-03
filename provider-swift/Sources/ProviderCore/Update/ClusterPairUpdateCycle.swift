import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// One coordinated update of this Mac in a `darkbloom cluster` pair, run by its cluster service supervisor at the
/// pair's update slot or for `darkbloom update` (`ClusterPairUpdate`).
///
/// `AutoUpdateController` sequences it as it sequences a single Mac's background update: check and stage while
/// serving, stop taking requests only once the release is staged, drain to zero with a bound (deferring, never
/// cancelling, when accepted work does not finish), commit, restart. Two steps differ. The drain is the pair's: it
/// begins once the other Mac has the release too, and it is complete once both Macs drained. The restart is the
/// supervisor's: it stops the cluster service and starts again from the installed binary.
public final class ClusterPairUpdateCycle: @unchecked Sendable {
    public struct Timing: Sendable {
        public var partnerStageWait = ClusterPairUpdate.partnerStageWaitSeconds
        public var drainTimeout = ClusterPairUpdate.drainTimeoutSeconds
        public var partnerDrainWait = ClusterPairUpdate.partnerDrainWaitSeconds
        public var poll = ClusterPairUpdate.pollSeconds
        /// How long this Mac's part may take to answer the drain request at all.
        public var partAnswer: Double = 15
        public static let production = Timing()
    }

    /// This Mac's part as its cluster service publishes it.
    public enum Part: Equatable, Sendable {
        case notRunning
        case running(ProcessIdentity)
        /// It serves without answering the drain (`ProviderLoopConfig.clusterMemberAnswersUpdateDrain`): rank 0 on the
        /// leader's local API, or a solo server.
        case undrainable
        /// The service runs but its status cannot be read: nothing is assumed.
        case unknown
    }

    public struct Environment: Sendable {
        public var updater: SelfUpdater
        /// Where this Mac's progress is written (`ClusterServiceAgent.updateProgressPath`).
        public var progressPath: URL
        public var partner: @Sendable () -> ClusterPairUpdate.Partner
        public var part: @Sendable () -> Part
        /// Whether a part that has not answered is still starting (it holds no request and no pair yet).
        public var partStarting: @Sendable (ProcessIdentity) -> Bool
        /// The parts' lifecycle mailboxes (`LifecycleMailbox`).
        public var mailboxDirectory: URL
        /// Whether a cluster worker runs on this Mac, so a pair is loaded here.
        public var pairRunsHere: @Sendable () -> Bool
        public var log: @Sendable (String) -> Void
        public var timing: Timing = .production

        public init(updater: SelfUpdater, progressPath: URL, partner: @escaping @Sendable () -> ClusterPairUpdate.Partner,
                    part: @escaping @Sendable () -> Part, partStarting: @escaping @Sendable (ProcessIdentity) -> Bool,
                    mailboxDirectory: URL, pairRunsHere: @escaping @Sendable () -> Bool,
                    log: @escaping @Sendable (String) -> Void) {
            self.updater = updater; self.progressPath = progressPath; self.partner = partner; self.part = part
            self.partStarting = partStarting; self.mailboxDirectory = mailboxDirectory; self.pairRunsHere = pairRunsHere
            self.log = log
        }
    }

    private struct PartDrain {
        var identity: ProcessIdentity
        var requestID: String
        var outcome: ClusterUpdateDrainStatus.Outcome?
    }

    private let environment: Environment
    private let lock = NSLock()
    private var startedAt: Double = 0
    private var request: String?
    private var session: SelfUpdater.UpdateSession?
    private var staged: SelfUpdater.StagedBundle?
    private var installed: String?
    private var target: String?
    private var progress: ClusterPairUpdateProgress?
    private var partDrain: PartDrain?
    /// Why the pair cannot drain this cycle (said once, published with the deferral).
    private var gaveUp: String?

    public init(environment: Environment) {
        self.environment = environment
    }

    /// `request`: the `darkbloom update` request this cycle answers. `restart` stops the cluster service and starts
    /// again from the installed binary; it is called with the installed version, only after both Macs drained.
    public func run(request: String? = nil,
                    restart: @escaping @Sendable (String) async throws -> Void) async -> AutoUpdateController.Outcome {
        lock.withLock { startedAt = Self.now(); self.request = request }
        let heartbeat = Task { [weak self, environment] in
            while !Task.isCancelled {
                await ClusterPairUpdateCycle.sleep(environment.timing.poll)
                self?.rewriteProgress()
            }
        }
        let updater = environment.updater, log = environment.log
        let deps = AutoUpdateController.Dependencies(
            claimStart: { self.claim() },
            resumeServing: { self.resume() },
            check: { await self.check() },
            downloadVerifyStage: { await self.stage($0) },
            beginDraining: { await self.beginPairDrain() },
            waitForDrain: { await self.waitForPairDrain($0) },
            commitInstall: { self.commit() },
            prepareInstalledRestart: { self.prepareRestart() },
            restart: {
                guard let version = self.lock.withLock({ self.target }) else { throw CancellationError() }
                try await restart(version)
            },
            restartDidFail: { try? updater.cancelPendingCandidateAttempt(operation: "cluster-restart-failure") },
            log: { log("cluster update: \($0)") })
        let drainTimeout = Duration.milliseconds(Int64(environment.timing.drainTimeout * 1000))
        let outcome = await AutoUpdateController(deps: deps, drainTimeout: drainTimeout).run()
        heartbeat.cancel()
        await heartbeat.value
        finish(outcome)
        return outcome
    }

    // MARK: - Steps

    private func claim() -> Bool {
        do {
            let session = try environment.updater.beginUpdateSession(operation: "cluster-auto-update", timeout: 0)
            try session.recover()
            lock.withLock { self.session = session }
        } catch {
            environment.log("cluster update: another update or recovery holds the update lease (\(error)); the next update slot tries again")
            return false
        }
        let requested = lock.withLock { request } != nil
        publish(.checking)
        environment.log("cluster update: checking for a release" + (requested ? " (asked by `darkbloom update`)" : " at the update slot"))
        return true
    }

    private func check() async -> UpdateCheckResult {
        guard let session = lock.withLock({ session }) else { return .checkFailed(reason: "the update lease was lost") }
        let result = await environment.updater.checkForUpdate(session: session)
        lock.withLock {
            switch result {
            case .updateAvailable(let current, let release): installed = current; target = release.version
            case .restartRequired(let current, let version): installed = current; target = version
            case .quarantined(let version, _): target = version
            case .upToDate(let current): installed = current
            case .checkFailed: break
            }
        }
        return result
    }

    private func stage(_ release: ReleaseInfo) async -> AutoUpdateController.StepOutcome {
        // A release the pair cannot drain for, or the other Mac will not take (its automatic updates are off, or it gave
        // this one up), is not downloaded.
        if environment.part() == .undrainable { return .failed(Self.undrainable) }
        if case .gaveUp(let reason) = partnerState(.staged, target: release.version) { return .failed(reason) }
        switch await environment.updater.downloadAndVerify(release: release) {
        case .failure(let error):
            return .failed("\(error)")
        case .success(let file):
            defer { try? FileManager.default.removeItem(at: file) }
            guard let session = lock.withLock({ session }) else { return .failed("the update lease was lost before staging") }
            switch environment.updater.stageBundle(from: file, release: release, session: session) {
            case .success(let bundle):
                lock.withLock { staged = bundle }
                publish(.staged)
                return .completed
            case .failure(let error):
                return .failed("\(error)")
            }
        }
    }

    /// The pair stops taking requests only once both Macs have the release: then this Mac's part is asked to drain.
    private func beginPairDrain() async {
        guard let target = lock.withLock({ target }) else { return giveUp("no release to install") }
        let (started, timing) = (lock.withLock { startedAt }, environment.timing)
        publish(.staged)
        let deadline = started + timing.partnerStageWait
        var said = false
        wait: while true {
            switch partnerState(.staged, target: target) {
            case .ready:
                environment.log("cluster update: the other Mac has v\(target) too")
                break wait
            case .gaveUp(let reason):
                return giveUp(reason)
            case .cannotCoordinate where !environment.pairRunsHere():
                environment.log("cluster update: the other Mac cannot coordinate an update and no pair runs on this Mac: updating this Mac alone")
                break wait
            case .cannotCoordinate, .waiting:
                if !said {
                    said = true
                    environment.log("cluster update: waiting for the other Mac to have v\(target) (at most \(Int(max(0, deadline - Self.now()))) s)")
                }
            }
            if Task.isCancelled { return giveUp("the cycle was stopped") }
            guard Self.now() < deadline else {
                return giveUp("the other Mac did not have v\(target) within \(Int(timing.partnerStageWait)) s")
            }
            await Self.sleep(timing.poll)
        }
        publish(.draining)
        switch environment.part() {
        case .notRunning:
            environment.log("cluster update: this Mac runs no part: nothing to drain here")
        case .undrainable:
            giveUp(Self.undrainable)
        case .unknown:
            giveUp("this Mac's cluster service status cannot be read, so its part cannot be drained")
        case .running(let identity):
            let request = ClusterUpdateDrainRequest(action: .drain, target: identity,
                timeoutSeconds: Int(timing.drainTimeout.rounded(.up)), createdAt: Self.now())
            do {
                try LifecycleMailbox(identity: identity, directory: environment.mailboxDirectory).writeClusterUpdateDrainRequest(request)
                lock.withLock { partDrain = PartDrain(identity: identity, requestID: request.id) }
                environment.log("cluster update: asked this Mac's part (pid \(identity.pid)) to take no new requests and finish the accepted ones")
            } catch {
                giveUp("this Mac's part could not be asked to drain (\(error))")
            }
        }
    }

    /// Both Macs drained: this Mac's part finished its accepted requests (or serves none), then the other Mac's did.
    private func waitForPairDrain(_ timeout: Duration) async -> Bool {
        guard lock.withLock({ gaveUp }) == nil, let target = lock.withLock({ target }) else { return false }
        let timing = environment.timing
        let started = Self.now()
        let bound = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if let drain = lock.withLock({ partDrain }) {
            let mailbox = LifecycleMailbox(identity: drain.identity, directory: environment.mailboxDirectory)
            var answered = false
            own: while true {
                if let status = mailbox.readClusterUpdateDrainStatus(), status.requestID == drain.requestID {
                    answered = true
                    lock.withLock { partDrain?.outcome = status.outcome }
                    switch status.outcome {
                    case .drained:
                        environment.log("cluster update: this Mac's part finished its accepted requests")
                        break own
                    case .notServing:
                        environment.log("cluster update: this Mac's part serves no requests of its own")
                        break own
                    case .timedOut:
                        giveUp("\(status.remaining) accepted request(s) were still running on this Mac's part after \(Int(bound)) s; none was cancelled"); return false
                    case .refused, .released:
                        giveUp("this Mac's part is stopping or changing its model"); return false
                    case .draining:
                        break
                    }
                }
                if !drain.identity.isCurrent() {
                    guard case .notRunning = environment.part() else { giveUp("this Mac's part restarted during the drain"); return false }
                    environment.log("cluster update: this Mac's part ended during the drain")
                    break own
                }
                if !answered, Self.now() - started > timing.partAnswer {
                    if environment.partStarting(drain.identity) {
                        environment.log("cluster update: this Mac's part is still starting: it holds no request yet")
                        break own
                    }
                    giveUp(Self.undrainable); return false
                }
                if Task.isCancelled { giveUp("the cycle was stopped"); return false }
                guard Self.now() - started <= bound + timing.partAnswer else {
                    giveUp("this Mac's part did not finish draining within \(Int(bound)) s"); return false
                }
                await Self.sleep(timing.poll)
            }
        }
        publish(.drained)
        let deadline = started + timing.partnerDrainWait
        while true {
            switch partnerState(.drained, target: target) {
            case .ready:
                environment.log("cluster update: both Macs drained for v\(target)")
                return true
            case .gaveUp(let reason):
                giveUp(reason); return false
            // Asked again, not remembered from the stage wait: a pair that formed on this Mac since keeps it waiting.
            case .cannotCoordinate where !environment.pairRunsHere():
                return true
            case .cannotCoordinate, .waiting:
                break
            }
            if Task.isCancelled { giveUp("the cycle was stopped"); return false }
            guard Self.now() < deadline else {
                giveUp("the other Mac did not drain for v\(target) within \(Int(timing.partnerDrainWait)) s"); return false
            }
            await Self.sleep(timing.poll)
        }
    }

    private func commit() -> AutoUpdateController.StepOutcome {
        let (bundle, session, from) = lock.withLock { () -> (SelfUpdater.StagedBundle?, SelfUpdater.UpdateSession?, String?) in
            defer { staged = nil }
            return (staged, self.session, installed)
        }
        guard let bundle, let session else { return .failed("no staged release to install") }
        switch environment.updater.commitStagedBundle(bundle, session: session) {
        case .success:
            environment.log("cluster update: installed v\(bundle.release.version)" + (from.map { " (was v\($0))" } ?? ""))
            return .completed
        case .failure(let error):
            return .failed("\(error)")
        }
    }

    /// Records the launch the watchdog would record for a single Mac, so the restarted supervisor tracks the
    /// candidate (`ClusterCandidateRecovery`), and frees the lease before the restart.
    private func prepareRestart() -> AutoUpdateController.StepOutcome {
        guard let session = lock.withLock({ session }) else { return .failed("the update lease was lost before the restart") }
        do {
            try environment.updater.prepareCandidateLaunch(session: session, baseline: nil, now: Self.now())
        } catch {
            return .failed("\(error)")
        }
        session.release()
        lock.withLock { self.session = nil }
        publish(.restarting)
        return .completed
    }

    /// Every exit that does not restart: this Mac's part takes requests again, nothing staged is kept.
    private func resume() {
        let (drain, bundle, session) = lock.withLock { () -> (PartDrain?, SelfUpdater.StagedBundle?, SelfUpdater.UpdateSession?) in
            defer { partDrain = nil; staged = nil; self.session = nil }
            return (partDrain, staged, self.session)
        }
        if let drain, drain.outcome != .timedOut, drain.outcome != .notServing, drain.identity.isCurrent() {
            let release = ClusterUpdateDrainRequest(action: .release, target: drain.identity, timeoutSeconds: 0,
                                                    createdAt: Self.now())
            try? LifecycleMailbox(identity: drain.identity, directory: environment.mailboxDirectory).writeClusterUpdateDrainRequest(release)
            environment.log("cluster update: this Mac's part takes requests again")
        }
        bundle?.discard()
        session?.release()
    }

    private func finish(_ outcome: AutoUpdateController.Outcome) {
        let reason = lock.withLock { gaveUp }
        let retry = "; the next update slot tries again"
        switch outcome {
        case .alreadyRunning:
            return
        case .upToDate:
            let current = lock.withLock { installed }
            publish(.idle, detail: "up to date")
            environment.log("cluster update: up to date" + (current.map { " (v\($0))" } ?? ""))
        case .quarantined(let version):
            publish(.failed, detail: "v\(version) is quarantined on this Mac")
        case .checkFailed(let failure):
            publish(.failed, detail: failure)
            environment.log("cluster update: the check failed (\(failure))" + retry)
        case .stageFailed(let failure):
            publish(.failed, detail: failure)
            environment.log("cluster update: not staged; this Mac kept serving" + retry)
        case .drainTimedOut, .cancelled:
            let why = reason ?? (outcome == .cancelled ? "the cycle was stopped" : "the drain did not complete")
            publish(.deferred, detail: why)
            environment.log("cluster update deferred: \(why); no request was cancelled" + retry)
        case .commitFailed(let failure):
            publish(.failed, detail: failure)
            environment.log("cluster update: installing failed; this Mac takes requests again" + retry)
        case .restarted(let from, let to, _):
            environment.log("cluster update: restarting the cluster service into v\(to) (was v\(from))")
        case .restartFailed(let failure):
            publish(.failed, detail: failure)
            environment.log("cluster update: the restart failed (\(failure))" + retry)
        }
    }

    // MARK: - Helpers

    static let undrainable = "this Mac's part does not drain for an update (it serves on its local API or alone)"

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private func partnerState(_ step: ClusterPairUpdate.Step, target: String) -> ClusterPairUpdate.PartnerState {
        let (started, requested) = lock.withLock { (startedAt, request != nil) }
        return ClusterPairUpdate.partnerState(environment.partner(), target: target, step: step, cycleStartedAt: started,
                                              now: Self.now(), requested: requested)
    }

    private func giveUp(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            guard gaveUp == nil else { return false }
            gaveUp = reason
            return true
        }
        if first { environment.log("cluster update: \(reason)") }
    }

    /// Written under the lock: a heartbeat's rewrite never lands after a later phase, and never after the cycle ended.
    private func publish(_ phase: ClusterPairUpdateProgress.Phase, detail: String? = nil) {
        lock.withLock {
            let value = ClusterPairUpdateProgress(phase: phase, target: phase == .idle ? nil : target,
                running: environment.updater.currentVersion, cycleStartedAt: phase == .idle ? nil : startedAt,
                request: request, writtenAt: Self.now(), detail: detail)
            progress = value
            ClusterPairUpdate.writeProgress(value, to: environment.progressPath)
        }
    }

    /// Keeps the working phase fresh for the other Mac while a step waits (`ClusterPairUpdate.progressStaleSeconds`).
    private func rewriteProgress() {
        lock.withLock {
            guard var value = progress, !value.isEnd, value.phase != .idle, value.phase != .restarting else { return }
            value.writtenAt = Self.now()
            progress = value
            ClusterPairUpdate.writeProgress(value, to: environment.progressPath)
        }
    }
}

extension ClusterPairUpdateCycle.Environment {
    /// This Mac's cluster service: the installed release's updater (with the watchdog's bounded network session), the
    /// part its status publishes, and the other Mac's progress over the link.
    public static func live(serviceDirectory: URL, coordinatorURL: String,
                            log: @escaping @Sendable (String) -> Void) -> Self {
        let partHealth = ClusterServiceAgent.partHealthPath(serviceDirectory: serviceDirectory)
        let peer = ClusterPairUpdateCycle.PeerAddress()
        return Self(
            updater: SelfUpdater(coordinatorBaseURL: coordinatorURL, urlSession: SelfUpdater.watchdogURLSession()),
            progressPath: ClusterServiceAgent.updateProgressPath(serviceDirectory: serviceDirectory),
            partner: { ClusterPairUpdateCycle.livePartner(peer) },
            part: { ClusterPairUpdateCycle.livePart() },
            partStarting: { identity in
                guard let health = ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: partHealth) else { return false }
                return health.pid == identity.pid && health.phase == .starting
                    && Date().timeIntervalSince1970 - health.writtenAt < 30
            },
            mailboxDirectory: DaemonStateFile.path().deletingLastPathComponent().appendingPathComponent("lifecycle"),
            pairRunsHere: { ClusterOrphanWiredGuard.otherDarkbloomProcesses().contains(ClusterBundledHelpers.workerName) },
            log: log)
    }
}

extension ClusterPairUpdateCycle {
    static func livePart() -> Part {
        guard ClusterService.running() else { return .notRunning }
        guard let status = ClusterService.publishedLive() else { return .unknown }
        guard status.child.running else { return .notRunning }
        if status.child.solo == true || status.localOnly == true { return .undrainable }
        guard let pid = status.child.pid, let startedAt = status.child.startedAt else { return .unknown }
        guard let identity = ProcessIdentity.read(pid: pid) else { return .notRunning }
        return abs(Double(identity.startTimeMicros) / 1e6 - startedAt) < 0.001 ? .running(identity) : .notRunning
    }

    /// The other Mac's address on the cable, kept between one cycle's polls so each skips the discovery.
    final class PeerAddress: @unchecked Sendable {
        private let lock = NSLock()
        private var address: ClusterLinkIPv4Address?
        var value: ClusterLinkIPv4Address? {
            get { lock.withLock { address } }
            set { lock.withLock { address = newValue } }
        }
    }

    static func livePartner(_ peer: PeerAddress) -> ClusterPairUpdate.Partner {
        guard let pairing = try? ClusterSetupLinkExchange.pairing(), let selection = try? LiveContext.defaultLinkSelection(),
              let body = try? JSONEncoder().encode(ClusterServiceCommand(op: .status)) else { return .unreachable }
        guard let answer = try? ClusterSetupLinkExchange.command(pairing: pairing, selection: selection, peerAddress: peer.value,
                                                                 body: body, seconds: 10),
              let status = try? JSONDecoder().decode(ClusterServiceStatus.self, from: answer.reply) else {
            peer.value = nil
            return .unreachable
        }
        peer.value = answer.peerAddress
        return status.pairUpdate.map { .reported($0) } ?? .silent
    }
}
