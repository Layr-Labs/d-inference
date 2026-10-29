import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterProcess
import DarkbloomClusterSecurity

/// One acting `darkbloom cluster` command at a time on this Mac, across processes (the command typed here, a command
/// forwarded to this Mac's cluster service), and never while the service hands leadership over: an exclusive flock on
/// `control.lock` beside the service lock. A command that waited for a hand-over finds the claim moved and is routed to
/// the new leader instead of running where nobody leads. Released by closing its descriptor (any thread may).
public final class ClusterControlCommandLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Nil when it could not be taken within `seconds` (0: one try).
    public static func acquire(seconds: Double, file: URL? = nil) -> ClusterControlCommandLock? {
        guard let path = file ?? (try? ClusterService.paths().lock.deletingLastPathComponent().appendingPathComponent("control.lock")) else { return nil }
        try? ClusterConfigurationFiles.ensureDirectory(path.deletingLastPathComponent(), create: true, privateMode: true)
        let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { close(fd); return nil }
            usleep(100_000)
        }
        return ClusterControlCommandLock(descriptor: fd)
    }

    public func release() {
        let fd: Int32 = lock.withLock { defer { descriptor = -1 }; return descriptor }
        if fd >= 0 { close(fd) }
    }

    deinit { release() }
}

/// The cluster service: one per Mac (`darkbloom cluster service`), started by
/// `darkbloom cluster` once the Mac is paired and meant to run at login (the
/// S18 LaunchAgent is not in this build: until then the onboarding starts it,
/// detached, and `darkbloom cluster` starts it again if it is not running).
///
/// It answers the leader over the link control channel (the pairing's edge
/// secret keys it, so only the paired Mac is answered): this Mac's report and
/// facts; a setup the leader syncs, which a member applies at once (its leader
/// is the Mac it pinned when it joined, and it delegated the choice to it);
/// and commands (serve, stop, status, a test request). While the leader has
/// the cluster serving, it runs this Mac's part of the saved setup (rank 0
/// with the serving API, or a follower rank), starts it again when it ends
/// (a member that restarted rejoins, a session that lost a member re-forms),
/// and stops it with SIGTERM, never SIGKILL.
public final class ClusterService: @unchecked Sendable {
    public struct Settings: Sendable {
        public var wizard: ClusterSetupOperations.LiveSettings
        /// `start --local --distributed` and `cluster link-follower`, with the provider configuration.
        public var leaderArguments: [String]
        public var followerArguments: [String]
        /// Degraded serving on this Mac alone: `start --local` with the provider configuration (the model is added).
        public var soloArguments: [String]
        /// Either Mac's part of a setup saved with a current cluster approval, served publicly: the coordinator-formed
        /// pair's member (`start --foreground --cluster-member` with the provider configuration).
        public var memberArguments: [String]
        public init(wizard: ClusterSetupOperations.LiveSettings, leaderArguments: [String], followerArguments: [String],
                    soloArguments: [String] = ["start", "--local"],
                    memberArguments: [String] = ["start", "--foreground", "--cluster-member"]) {
            self.wizard = wizard; self.leaderArguments = leaderArguments; self.followerArguments = followerArguments
            self.soloArguments = soloArguments; self.memberArguments = memberArguments
        }
    }

    let settings: Settings
    let context: LiveContext
    let store: ClusterSetupStore
    let pairingStore: ClusterPairingStore
    private let recoveryGraceSeconds: Double
    private let beforePartStart: (@Sendable () -> Void)?
    /// Main supervision thread only; a pending stop cannot be acknowledged by
    /// a cycle that read the preceding serving intent.
    private var supervisedStopDrainID: UUID?
    let lock = NSLock()
    private var child: Process?
    /// A previous service's part can outlive the cleanup deadline. Keep its identity
    /// published and reserve its memory until that exact process exits.
    private var leftoverPart: RecordedPart?
    private var childSetup: String?
    private var childStarted = Date.distantPast
    private var childStartedAt: Double?
    private var starts = 0
    private var lastEnd: String?
    private var nextStart = Date.distantPast
    /// The part whose end (or failed start) set `nextStart`: its restart backoff does not hold back another part.
    private var endedKey: String?
    private var backoff: Double = 3
    private var responder: ClusterSetupLinkExchange.Responder?
    var stopping = false
    private var syncing = false
    private var nextSync = Date.distantPast
    // Setting the cluster up again after a Darkbloom update (`checkForUpdate`).
    private var updateInFlight = false
    private var nextUpdateCheck = Date.distantPast
    private var updatingLine: String?
    // The cluster approval is asked for once per run of this service on the control leader, and again every minute
    // while the pair is offered or serves locally with its approval set aside (`checkApproval`).
    private var approvalChecked = false
    private var approvalInFlight = false
    private var nextApprovalCheck = Date.distantPast
    private var approvalWatch = ClusterApprovalCheck.Watch()
    // This Mac's coordinator-paired parts that ended in a row right after starting (`ClusterApprovalCheck.memberQuickEnds`),
    // and whether the running part is one.
    private var memberQuickEnds = 0
    private var childIsMember = false
    // Where the running part began writing its log (`lastError(in:from:)`).
    private var childLogOffset: UInt64 = 0
    // Derived control (ClusterServiceControl.swift).
    var control: ClusterControlNode?
    var controlResponder: ClusterSetupLinkExchange.Responder?
    /// The port the cluster's API last used on this Mac (rank 0's here, or the relay's); kept while it is free on both.
    private var apiPort: Int?
    /// The port the running part listens on: rank 0's API or the solo server's; nil for any other part.
    private var childPort: Int?
    /// Starts of this setup that ended on a memory-gate refusal (a Mac's memory moved after the plan was made), and
    /// when the plan may next be made again (`memoryReplan`).
    private var memoryRefusals: (key: String, count: Int)?
    private var nextMemoryReplan = Date.distantPast
    private var memoryReplanInFlight = false
    /// Re-plans in a row that came back with the same split: after `memoryReplansWithSameSplit` the service stops
    /// re-planning (the memory is short for every split) until a re-plan finds another one or the service restarts.
    private var sameSplitReplans = 0
    static let memoryReplansWithSameSplit = 3
    /// Local only, on the Mac that is not rank 0: its own port passed to rank 0's API (`ClusterLocalRelay`).
    private var relay: ClusterLocalRelay?
    /// Rank 0's API port as the other Mac's status last said it, and when it was asked (a thread of its own).
    private var relayTargetPort: Int?
    private var relayAsked = Date.distantPast
    private var relayAsking = false
    /// Seconds before the next ask: 10 while the other Mac answers, longer (to 120) while it does not, so the link's
    /// one-at-a-time request lock is not held for the other commands.
    private var relayAskInterval: Double = 10
    /// When each listener last looked for the cable on another port (`cableMove`).
    private var responderCableCheck = Date.distantPast
    var controlCableCheck = Date.distantPast
    var leaseInFlight = false
    var nextLease: Double = 0
    var lastModeLine: String?
    /// The last lease failure said (leader) and the last setup record read failure said (supervise), each said once.
    var lastLeaseProblem: String?
    var recordProblem: String?
    var localHardware: (name: String, memoryBytes: UInt64, gpuCores: Int, chipFamily: ChipFamily)?
    /// F14: solo-server ends in a row soon after their start, for one model of one plan ("<plan>|<model>").
    var soloQuickEnds: (key: String, count: Int)?
    lazy var controlLive: OnboardingLive = OnboardingLive(context: context, store: store,
        settings: .init(service: settings, serviceArguments: []))

    public convenience init(settings: Settings) throws {
        try self.init(settings: settings, paths: ClusterUserPaths())
    }

    /// Internal composition of the service's existing stores. Public callers keep
    /// the canonical user namespace and the normal recovery deadline.
    init(settings: Settings, paths: ClusterUserPaths, recoveryGraceSeconds: Double = 300,
         beforePartStart: (@Sendable () -> Void)? = nil) {
        precondition(recoveryGraceSeconds.isFinite && recoveryGraceSeconds >= 0)
        self.recoveryGraceSeconds = recoveryGraceSeconds
        self.beforePartStart = beforePartStart
        pairingStore = .default(home: paths.homeDirectory)
        var wizard = settings.wizard
        wizard.derivedPlacement = true
        wizard.answersOverLink = false
        self.settings = Settings(wizard: wizard, leaderArguments: settings.leaderArguments, followerArguments: settings.followerArguments,
            soloArguments: settings.soloArguments, memberArguments: settings.memberArguments)
        store = ClusterSetupStore(paths: .init(paths: paths))
        context = LiveContext(paths: paths, store: store, settings: wizard,
            clean: ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path))
    }

    // MARK: - Files

    public static func paths() throws -> (lock: URL, pid: URL, log: URL, rankLog: URL) {
        files(in: ClusterSetupPaths(paths: try ClusterUserPaths()).directory)
    }

    private var serviceFiles: (lock: URL, pid: URL, log: URL, rankLog: URL) {
        Self.files(in: store.paths.directory)
    }

    private static func files(in directory: URL) -> (lock: URL, pid: URL, log: URL, rankLog: URL) {
        (directory.appendingPathComponent("service.lock"), directory.appendingPathComponent("service.pid"),
                directory.appendingPathComponent("service.log"), directory.appendingPathComponent("rank.log"))
    }

    /// Whether a cluster service holds this home's lock now.
    public static func running() -> Bool {
        guard let directory = try? paths().lock.deletingLastPathComponent() else { return false }
        return running(in: directory) == true
    }

    private static func running(in directory: URL) -> Bool? {
        let lockFile = files(in: directory).lock
        let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? false : nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK ? true : nil
    }

    /// Starts `darkbloom cluster service` detached from this terminal (its own
    /// session, output to service.log) unless one runs; waits until it holds its lock.
    public static func ensureRunning(executable: URL, arguments: [String]) throws -> Bool {
        if running() { return false }
        let files = try paths()
        try ClusterConfigurationFiles.ensureDirectory(files.lock.deletingLastPathComponent(), create: true, privateMode: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, files.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard spawned == 0 else { throw ClusterOnboardingFailure("this Mac's cluster service could not be started (error \(spawned))") }
        for _ in 0..<100 {
            if running() { return true }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                throw ClusterOnboardingFailure("this Mac's cluster service stopped at start; its log is ~/.darkbloom/cluster-setup/service.log")
            }
            usleep(50_000)
        }
        throw ClusterOnboardingFailure("this Mac's cluster service did not start within 5 s")
    }

    // MARK: - Running

    /// Runs until `stop` is signalled; returns false when a rank had to be left running.
    public func run(stop: DispatchSemaphore, say: @escaping @Sendable (String) -> Void) throws -> Bool {
        let power = ClusterServicePowerAssertions()
        defer { power.release() }
        let files = serviceFiles
        try ClusterConfigurationFiles.ensureDirectory(files.lock.deletingLastPathComponent(), create: true, privateMode: true)
        let fd = open(files.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClusterOnboardingFailure("the service lock cannot be opened") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ClusterOnboardingFailure("this Mac's cluster service is already running") }
        try? Data("\(getpid())\n".utf8).write(to: files.pid, options: .atomic)
        defer { unlink(files.pid.path) }
        say("started (pid \(getpid()))")
        refreshPowerAssertions(power)
        // A part a previous run of this service started and left running (that run ended without stopping it, e.g.
        // killed): stopped before anything starts, or it would hold the model's memory and the serving port forever.
        if let previous = Self.published(in: store.paths.directory), previous.servicePID != getpid(), let left = Self.recordedPart(previous) {
            lock.withLock { leftoverPart = left }
            power.update(savedServing: nil, partRunning: true, relayRunning: false)
            say("this Mac's \(left.solo ? "solo server" : "part") from the previous service run is still running (pid \(left.pid)): stopping it first")
            say(Self.stopLeftover(left, seconds: recoveryGraceSeconds) ? "the previous run's \(left.solo ? "solo server" : "part") stopped"
                : "the previous run's \(left.solo ? "solo server" : "part") is still releasing after \(Int(recoveryGraceSeconds)) s")
        }
        let ticker = DispatchSemaphore(value: 0)
        var stopped = false
        Thread.detachNewThread { stop.wait(); ticker.signal() }
        // The control lease runs on a thread of its own: a part that takes long to release (supervise waits for it)
        // never delays a renewal past the lease's time-to-live.
        let controlDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [weak self] in
            defer { controlDone.signal() }
            while let self, !self.lock.withLock({ self.stopping }) {
                // Each tick in its own autorelease pool: these loops never return to a run loop, so the Foundation
                // objects a tick autoreleases (file and URL lookups, status data) were only freed when the service
                // ended: the service grew about 15 MB a minute (F18).
                autoreleasepool {
                    self.ensureControlResponder(say: say)
                    self.controlTick(say: say)
                }
                usleep(500_000)
            }
        }
        while !stopped {
            autoreleasepool {
                refreshPowerAssertions(power)
                ensureResponder(say: say)
                supervise(say: say)
                relayTick(say: say)
                refreshPowerAssertions(power)
                syncMembers(say: say)
                checkForUpdate(say: say)
                checkApproval(say: say)
                publish(afterSupervision: true)
            }
            if ticker.wait(timeout: .now() + 1) == .success { stopped = true }
        }
        lock.withLock { stopping = true }
        _ = controlDone.wait(timeout: .now() + 5)
        say("stopping")
        lock.withLock { () -> ClusterLocalRelay? in defer { relay = nil }; return relay }?.stop()
        lock.withLock { responder }?.stop()
        lock.withLock { controlResponder }?.stop()
        let childClean = stopChild(say: say, seconds: Double(ClusterServiceAgentPlan.partStopGraceSeconds))
        let leftoverClean = leftover().map { Self.stopLeftover($0, seconds: Double(ClusterServiceAgentPlan.partStopGraceSeconds)) } ?? true
        let clean = childClean && leftoverClean
        publish()
        say(clean ? "stopped" : "stopped with this Mac's part still releasing")
        return clean
    }

    private func refreshPowerAssertions(_ power: ClusterServicePowerAssertions) {
        let savedServing = (try? store.readRecord()).map { $0.leadership?.serving ?? false }
        let leftoverRunning = leftover() != nil
        let active = lock.withLock {
            (part: child?.isRunning == true, relay: relay.map { !$0.isStopped } ?? false)
        }
        power.update(savedServing: savedServing, partRunning: active.part || leftoverRunning, relayRunning: active.relay)
    }

    private func leftover() -> RecordedPart? {
        lock.withLock {
            leftoverPart = Self.runningPart(leftoverPart)
            return leftoverPart
        }
    }

    /// How often a listener looks for the cable on another port: a cable moved to another Thunderbolt port (or a port
    /// whose address changed) leaves the listener on the old one, where the other Mac never reaches it.
    static let cableCheckSeconds: Double = 5

    /// The cable's port now when it is not the one `listener` was started on (checked at most every
    /// `cableCheckSeconds` per listener, `checked`); nil when it has not moved, or there is no listener or cable.
    func cableMove(of listener: ClusterSetupLinkExchange.Responder?,
                   checked: ReferenceWritableKeyPath<ClusterService, Date>) -> ClusterLinkInterfaceSelection? {
        guard let bound = listener?.selection else { return nil }
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(self[keyPath: checked]) >= Self.cableCheckSeconds else { return false }
            self[keyPath: checked] = Date()
            return true
        }
        guard due, let current = try? context.linkSelection(),
              ClusterSetupLinkExchange.cableMoved(bound: bound, current: current) else { return nil }
        return current
    }

    private func ensureResponder(say: @escaping @Sendable (String) -> Void) {
        if let moved = cableMove(of: lock.withLock({ responder }), checked: \.responderCableCheck) {
            lock.withLock { responder }?.stop()
            lock.withLock { responder = nil }
            say("the cable is on \(moved.interface) now: answering the paired Mac there")
            // A port that was never set up has no fixed address: the other Mac cannot find this one there.
            if let port = OnboardingLive.unsetCablePort(ClusterLinkReadinessProbe.inspectLocalLink()) {
                say("\(port) is not set up for the cluster: run `darkbloom cluster` on this Mac and press f (macOS asks for your password once)")
            }
        }
        guard lock.withLock({ responder == nil }), let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore),
              let selection = try? context.linkSelection() else { return }
        let context = self.context, store = self.store
        // A model the leader copies here over the cable lands in this Mac's model store, verified file by file.
        let provisioner = ClusterModelProvisionResponder(store: {
            URL(fileURLWithPath: context.modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path)
        }, trust: { ClusterModelCopyTrust.refusal($0) }, worker: {
            // This Mac's own installed worker (the one its ranks load models with) checks every staged copy.
            let input = context.pairInput()
            guard let memberID = input.pair?.memberID, let local = input.description?.members.first(where: { $0.id == memberID }) else {
                throw ClusterSetupFailure(input.error ?? "this Mac's cluster worker is not set up yet")
            }
            return ClusterModelWorkerCheck(executable: URL(fileURLWithPath: local.workerExecutable), runtimeBinarySHA256: local.runtimeBinarySHA256)
        }, say: say)
        do {
            let created = try ClusterSetupLinkExchange.Responder(pairing: pairing, selection: selection, answer: {
                ClusterSetupLinkAnswer(report: context.report(input: context.pairInput(), saved: context.savedConfiguration(),
                    inbox: ClusterSetupLocalReader.inbox(store)), facts: try context.localFacts(pairing: pairing, selection: selection))
            }, receive: { [weak self] data in
                guard let self else { throw ClusterSetupFailure("the service is stopping") }
                return try self.receive(data, pairing: pairing, say: say)
            }, command: { [weak self] data in
                guard let self else { throw ClusterSetupFailure("the service is stopping") }
                return try self.command(data, pairing: pairing, say: say)
            }, provision: { tag, data in provisioner.handle(tag: tag, data) })
            try created.start()
            lock.withLock { responder = created }
            say("answering the paired Mac over the cable")
        } catch {
            // Tried again at the next tick (the cable may not be up yet).
        }
    }

    /// This Mac follows the Mac it paired with: the derived control leader is that Mac (before the service has
    /// derived anything, the Mac that drove the onboarding).
    func followsPeer(_ pairing: ClusterSetupLinkExchange.Pairing) -> Bool {
        if let claim = lock.withLock({ control?.claim }) { return claim.leaderID == pairing.peerMemberID }
        guard let record = try? store.readRecord() else { return false }
        return Self.followsPeer(record: record, pairing: pairing)
    }

    /// The same from the saved record alone (no running service needed): the recorded control claim, else the
    /// onboarding's roles. A Mac that drove the onboarding follows the other once control moved there.
    static func followsPeer(record: ClusterSetupRecord, pairing: ClusterSetupLinkExchange.Pairing) -> Bool {
        if let claim = record.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID) { return claim.leaderID == pairing.peerMemberID }
        guard let leadership = record.leadership else { return false }
        return leadership.role == ClusterOnboardingRole.member.rawValue && leadership.leaderPin == pairing.peerPin
    }

    /// The pin of the Mac whose cache settings this Mac applies: the paired Mac while this Mac follows it, else nil
    /// (this Mac's own settings). Keyed by control, not by who drove the onboarding.
    static func followedLeaderPin(record: ClusterSetupRecord?, pairingStore: ClusterPairingStore = .default()) -> String? {
        guard let record, let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore), followsPeer(record: record, pairing: pairing) else { return nil }
        return pairing.peerPin
    }

    /// A start that ended because a Mac's load gate refused its share (`memory_gate_refused` in the incidents since it
    /// began). The plan is made on the memory each Mac had then; when it has moved since (apps opened, the file cache
    /// refilled), the same split is refused again and again: a 36 GB M4 Max given 17 of Nemotron's layers kept
    /// retrying (2026-10-16). After `memoryRefusalsBeforeReplan` such ends the control leader plans the same model
    /// again on the memory now and adopts that split (at most once per `memoryReplanSeconds`).
    static let memoryRefusalsBeforeReplan = 2
    static let memoryReplanSeconds: Double = 600

    private func noteMemoryRefusal(key: String, since: Date, model: String, say: @escaping @Sendable (String) -> Void) {
        let log = ClusterIncidentLog(file: ClusterIncidentLog.defaultFile(homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
        let refused = log.feed().incidents.contains { $0.ts >= since.timeIntervalSince1970 && $0.guidanceCode == "memory_gate_refused" }
        let due = lock.withLock { () -> Bool in
            guard refused else { memoryRefusals = nil; return false }
            let count = (memoryRefusals?.key == key ? memoryRefusals!.count : 0) + 1
            memoryRefusals = (key, count)
            guard count >= Self.memoryRefusalsBeforeReplan, !memoryReplanInFlight, !stopping, Date() >= nextMemoryReplan,
                  sameSplitReplans < Self.memoryReplansWithSameSplit, control?.leads == true else { return false }
            memoryReplanInFlight = true
            nextMemoryReplan = Date().addingTimeInterval(Self.memoryReplanSeconds)
            return true
        }
        guard due else { return }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.memoryReplanInFlight = false; self.memoryRefusals = nil } }
            guard let held = ClusterControlCommandLock.acquire(seconds: 5) else { return }
            defer { held.release() }
            say("a Mac's memory no longer holds its share of \(model) (refused at load twice): planning again on the memory now")
            let before = try? self.context.savedConfiguration().reference.get()?.sha256
            let live = self.controlLive
            func failed(_ lines: [String]) { say("could not plan \(model) again: " + lines.joined(separator: " ")) }
            if case .failure(let failure) = live.localReachMembers({ _ in }) { return failed(failure.lines) }
            let choices: [ClusterOnboardingModelChoice]
            switch live.localPlanModels() {
            case .success(let value): choices = value
            case .failure(let failure): return failed(failure.lines)
            }
            guard let index = choices.firstIndex(where: { ($0.modelID ?? $0.title) == model && $0.blocker == nil && $0.provision == nil }) else {
                return failed(["\(model) does not fit these Macs' memory now: \(choices.first { ($0.modelID ?? $0.title) == model }?.blocker ?? "not offered")"])
            }
            if case .failure(let failure) = live.localAdopt(index) { return failed(failure.lines) }
            if case .failure(let failure) = live.localServe() { return failed(failure.lines) }
            let after = try? self.context.savedConfiguration().reference.get()?.sha256
            self.lock.withLock { self.sameSplitReplans = before == after ? self.sameSplitReplans + 1 : 0 }
            say(before == after ? "planned \(model) again: the same split is still the one that fits; trying it again"
                                : "planned \(model) again on the memory now: \(choices[index].lines.first ?? "a new split") is starting on both Macs")
        }
    }

    /// Local only, on the Mac whose part is not rank 0: the same port as rank 0's API (else 8000 or the next free one)
    /// passes each connection over the cable to rank 0's API, so the cluster answers at the same address whichever Mac
    /// the plan made rank 0, with the same key (`LocalEndpoint.loadOrCreateClusterToken`). Stopped whenever this Mac's part
    /// is not running or is rank 0, before rank 0 here takes the port.
    private func relayTick(say: @escaping @Sendable (String) -> Void) {
        let record = try? store.readRecord()
        let saved = context.savedConfiguration().configuration
        let runsMember = lock.withLock { child?.isRunning == true && childSetup?.hasPrefix("solo:") != true }
        var wanted: ClusterLocalRelay.Target?
        // Only when the API listens on every address (local only's default): with a loopback or one-address bind,
        // rank 0's API is not reachable over the cable, and this Mac must not open what the person kept closed.
        if let record, record.leadership?.serving == true, record.leadership?.scope.bind == "0.0.0.0",
           let saved, saved.role != .leader, saved.peers.indices.contains(0), runsMember {
            askRankZeroPort()
            if let port = lock.withLock({ relayTargetPort }) { wanted = .init(host: saved.peers[0].host, port: port) }
        }
        let current = lock.withLock { relay }
        if let current, current.target == wanted, !current.isStopped { return }
        if let current {
            current.stop()
            lock.withLock { relay = nil }
            LocalEndpoint.removeInfo(ifPID: getpid())
            say("stopped passing this Mac's port \(current.port) to the API on the other Mac")
        }
        guard let wanted, let token = try? LocalEndpoint.loadOrCreateClusterToken() else { return }
        let port = ClusterLocalServing.portIsFree(wanted.port) ? wanted.port : ClusterLocalServing.servingPort()
        guard let started = ClusterLocalRelay(port: port, target: wanted) else { return }
        lock.withLock { relay = started; apiPort = port }
        // The discovery file only when no other live server on this Mac owns it (`darkbloom start --local`).
        if LocalEndpoint.readLiveInfo().map({ $0.pid == getpid() }) ?? true {
            try? LocalEndpoint.writeInfo(.init(host: "0.0.0.0", port: UInt16(port), apiKey: token,
                version: ProviderCore.version, pid: getpid(), updatedAt: ISO8601DateFormatter().string(from: Date())))
        }
        say(port == wanted.port
            ? "the API answers on this Mac's port \(port) too, the same port as on the other Mac (rank 0), passed over the cable"
            : "port \(wanted.port) is taken on this Mac: the API answers here on port \(port), passed over the cable to port \(wanted.port) on the other Mac (rank 0)")
    }

    /// Asks the other Mac (every 10 s, never on this loop's thread) where its rank 0 API listens.
    private func askRankZeroPort() {
        let begin = lock.withLock { () -> Bool in
            guard !relayAsking, Date().timeIntervalSince(relayAsked) >= relayAskInterval else { return false }
            relayAsking = true; relayAsked = Date(); return true
        }
        guard begin else { return }
        let context = self.context, pairingStore = self.pairingStore
        Thread.detachNewThread { [weak self] in
            defer { self?.lock.withLock { self?.relayAsking = false } }
            guard let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore), let selection = try? context.linkSelection(),
                  let body = try? JSONEncoder().encode(ClusterServiceCommand(op: .status)),
                  let reply = try? ClusterSetupLinkExchange.command(pairing: pairing, selection: selection, peerAddress: nil,
                      body: body, seconds: 5).reply,
                  let status = try? JSONDecoder().decode(ClusterServiceStatus.self, from: reply) else {
                self?.lock.withLock { if let self { self.relayAskInterval = min(self.relayAskInterval * 2, 120) } }
                return
            }
            let port = status.sessionLeader && status.session?.ready == true ? status.session?.port : nil
            self?.lock.withLock { self?.relayTargetPort = port; self?.relayAskInterval = 10 }
        }
    }

    /// The ports the other Mac has free (its status's `freePorts`), asked on a thread of its own and waited for at most
    /// `seconds`; nil when it does not answer in time or its build does not say.
    private func peerFreePorts(seconds: Double) -> [Int]? {
        let context = self.context, pairingStore = self.pairingStore
        let answered = ClusterOnboardingMailbox<[Int]>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            guard let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore), let selection = try? context.linkSelection(),
                  let body = try? JSONEncoder().encode(ClusterServiceCommand(op: .status)),
                  let reply = try? ClusterSetupLinkExchange.command(pairing: pairing, selection: selection, peerAddress: nil,
                      body: body, seconds: seconds).reply,
                  let ports = try? JSONDecoder().decode(ClusterServiceStatus.self, from: reply).freePorts else { return }
            answered.post(ports)
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return answered.take().first
    }

    /// The ports this Mac reports free: those no program listens on, and those its own API, relay or solo server holds
    /// (given back when the other Mac becomes rank 0 or the pair re-forms).
    private func reportedFreePorts() -> [Int] {
        let own = lock.withLock { () -> Set<Int> in
            var ports = Set<Int>()
            if let relay, !relay.isStopped { ports.insert(relay.port) }
            if child?.isRunning == true, let childPort { ports.insert(childPort) }
            return ports
        }
        return ClusterLocalServing.freePorts { own.contains($0) || ClusterLocalServing.portIsFree($0) }
    }

    /// On the leader: every `ClusterOnboardingSync.dueEverySeconds`, ask the member for its status and send
    /// what differs from this Mac's record (serve with the model, or stop), on a thread of its own so this
    /// Mac's own supervision never waits on the cable. A member that missed a start or a stop follows once it
    /// answers again.
    private func syncMembers(say: @escaping @Sendable (String) -> Void) {
        guard let record = try? store.readRecord(), let leadership = record.leadership, leadsAndRunsCluster() else { return }
        let begin: Bool = lock.withLock {
            guard !syncing, !stopping, Date() >= nextSync else { return false }
            syncing = true
            nextSync = Date().addingTimeInterval(ClusterOnboardingSync.dueEverySeconds)
            return true
        }
        guard begin else { return }
        let context = self.context, pairingStore = self.pairingStore
        Thread.detachNewThread { [weak self] in
            defer { self?.lock.withLock { self?.syncing = false } }
            guard let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore), pairing.peerPin == leadership.peerPin,
                  let selection = try? context.linkSelection() else { return }
            let claim = self?.lock.withLock { self?.control?.claim }
            func send(_ command: ClusterServiceCommand, seconds: Double) -> ClusterServiceStatus? {
                var command = command
                command.claim = claim
                guard let body = try? JSONEncoder().encode(command),
                      let reply = try? ClusterSetupLinkExchange.command(pairing: pairing, selection: selection, peerAddress: nil,
                          body: body, seconds: seconds).reply else { return nil }
                return try? JSONDecoder().decode(ClusterServiceStatus.self, from: reply)
            }
            let member = send(.init(op: .status), seconds: 10)
            // The leader's cache choices first, so a member it starts runs with them.
            if let member, let cache = ClusterMemberCacheControl.settingsToSend(
                leader: ClusterCacheSettingsSync.leaderChoices(cacheSettings: (try? ClusterPrefixCacheSettings.savedCacheSettings(
                    providerConfiguration: context.settings.providerConfiguration)) ?? CacheSettings()),
                memberDigest: member.cacheSync), send(.init(op: .cacheSettings, cache: cache), seconds: 10) != nil {
                say("synced this Mac's cache settings to the member (\(String(ClusterMemberCacheControl.digest(cache).prefix(12))))")
            }
            guard let self,
                  let held = ClusterControlCommandLock.acquire(seconds: 0,
                    file: self.store.paths.directory.appendingPathComponent("control.lock")) else { return }
            defer { held.release() }
            guard let current = try? self.store.readRecord(), current.stopDrain == nil,
                  let leadership = current.leadership, leadership.peerPin == pairing.peerPin,
                  self.leadsAndRunsCluster() else { return }
            switch ClusterOnboardingSync.action(leaderServing: leadership.serving, leaderModel: leadership.modelName,
                                                memberServing: member?.serving, memberModel: member?.modelName,
                                                leaderLocalOnly: leadership.scope.isLocalOnly, memberLocalOnly: member?.localOnly) {
            case .none: return
            case .serve(let model):
                let runsIt = member?.serving == true && member?.modelName == model
                var serve = ClusterServiceCommand(op: .serve, model: model, deployment: leadership.deployment, scope: leadership.scope)
                if leadership.scope.isLocalOnly { serve.localToken = try? LocalEndpoint.loadOrCreateClusterToken() }
                if send(serve, seconds: 10) != nil {
                    say(runsIt ? "synced how the cluster serves to the member" : "the member had missed the start: started its part")
                }
            case .stop:
                // A member stopped before rank 0 fences the still-live pair.
                // A local retirement timeout is not proof that rank 0 drained.
                guard self.lock.withLock({
                    self.child?.isRunning != true && Self.runningPart(self.leftoverPart) == nil
                }) else { return }
                if send(.init(op: .stop), seconds: 10) != nil { say("the member had missed the stop: stopped its part") }
            }
        }
    }

    /// A setup from the leader: a member applies it at once; anything else only reaches the inbox.
    private func receive(_ data: Data, pairing: ClusterSetupLinkExchange.Pairing, say: @Sendable (String) -> Void) throws -> String {
        let digest = try store.receive(data)
        guard followsPeer(pairing), let candidate = store.inboxCandidate else { return digest }
        let configuration = settings.wizard.providerConfiguration, paths = context.paths
        // Applied exactly as received: the digest of the inbox's own bytes, read once here.
        let expected = try candidate.contents().configurationSHA256
        let result = ClusterConsoleObserver.approve(candidate, expectedSHA256: expected,
            holdingIn: try ClusterConsoleInstanceLock.userTemporaryDirectory()) { reviewed in
                try ClusterConfigurationStore(paths: paths).configure(configurationInput: reviewed.configurationInput,
                    capabilityInput: reviewed.capabilityInput, capabilitySHA256: candidate.capabilitySHA256,
                    providerConfiguration: configuration)
            }
        guard result.succeeded else { throw ClusterSetupFailure(result.lines.joined(separator: " ")) }
        store.clearInbox()
        say("applied the setup the leader synced (\(digest.prefix(12)))")
        return digest
    }

    private func command(_ data: Data, pairing: ClusterSetupLinkExchange.Pairing, say: @escaping @Sendable (String) -> Void) throws -> Data {
        let command = try JSONDecoder().decode(ClusterServiceCommand.self, from: data)
        let encoder = JSONEncoder()
        switch command.op {
        case .status:
            var value = status()
            value.freePorts = reportedFreePorts()
            return try encoder.encode(value)
        case .serve, .stop:
            if let sent = command.claim, let own = lock.withLock({ control?.claim }), own.supersedes(sent) {
                throw ClusterSetupFailure("the Mac that asked no longer leads: term \(own.term) superseded its term \(sent.term)")
            }
            guard followsPeer(pairing) else { throw ClusterSetupFailure("this Mac does not follow the Mac that asked") }
            try store.updateRecord {
                $0.leadership?.serving = command.op == .serve
                if let model = command.model { $0.leadership?.modelName = model }
                if command.op == .serve {
                    let recorded = $0.leadership?.deployment
                    $0.leadership?.deployment = ClusterOnboardingDeployment.recorded(afterStartOf: command.model, deployment: command.deployment,
                                                                                     recorded: recorded)
                    // The leader's serving scope, so it holds when control moves here (an older leader sends none).
                    if let scope = command.scope { $0.leadership?.scope = scope }
                    // The pair's one local API key, before this Mac starts a part that may be rank 0.
                    if let token = command.localToken { LocalEndpoint.saveClusterToken(token) }
                }
            }
            say(command.op == .serve ? "the leader started the cluster" : "the leader stopped the cluster")
            if command.op == .serve { lock.withLock { nextStart = .distantPast; backoff = 3 } }
            return try encoder.encode(status())
        case .prompt:
            return try encoder.encode(Self.prompt(context, text: command.text ?? "Name three colors."))
        case .cacheSettings, .unpair:
            let configuration = settings.wizard.providerConfiguration
            let reply = try ClusterMemberCacheControl.handle(command, follows: followsPeer(pairing), leaderPin: pairing.peerPin,
                pairClusterID: pairing.clusterID,
                memberSettings: { try ClusterPrefixCacheSettings.resolved(providerConfiguration: configuration) },
                store: cacheStore, status: { status() })
            if command.op == .unpair {
                // The leader left: this Mac's part stops (its rank releases its plan, then the reclaim finishes).
                try store.updateRecord { $0.leadership?.serving = false }
                say("the leader left the pair: reclaimed this Mac's pair cache and stopped its part")
            } else {
                say("applied the cache settings the leader synced")
            }
            return reply ?? Data()
        case .sendModel:
            // The leader lacks a model this Mac has: this Mac sends it over the cable (the leader's service verifies it).
            guard let folder = command.model, let digest = command.text, let name = ClusterCatalogArtifact.safeFolder(folder) else {
                throw ClusterSetupFailure("no model named")
            }
            let store = URL(fileURLWithPath: context.modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path)
            guard let data = ClusterModelStore.readSmall(store.appendingPathComponent(name).appendingPathComponent("manifest.json")),
                  let artifact = try? ClusterCatalogArtifact.parse(manifest: data), artifact.aggregateSHA256 == digest else {
                throw ClusterSetupFailure("this Mac does not have that model")
            }
            let selection = try context.linkSelection()
            say("sending \(name) to the paired Mac over the cable")
            // Answer once the leader's service took the copy (or refused it: its reason goes back at once, instead of
            // the leader waiting for bytes that never come); the bytes then flow in the background.
            let started = ClusterOnboardingMailbox<String?>()
            let answered = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                do {
                    let outcome = try ClusterSetupLinkExchange.copyModel(pairing: pairing, selection: selection, peerAddress: nil, artifact: artifact,
                        source: store.appendingPathComponent(name), folder: name, begun: { _ in started.post(nil); answered.signal() }) { _, _ in }
                    say("sent \(name): \(ClusterModelProvisioning.gigabytes(outcome.sentBytes)) in \(String(format: "%.1f", outcome.seconds)) s")
                } catch {
                    say("sending \(name) stopped: \(error)")
                    started.post(ClusterConsoleText.bounded(error)); answered.signal()
                }
            }
            // Within the leader's 30 s command wait; a slow start (a long resume check) still answers "sending".
            if answered.wait(timeout: .now() + 20) == .success, let refusal = started.take().first ?? nil {
                throw ClusterSetupFailure("\(name) could not be sent: \(refusal)")
            }
            return Data("{\"sending\":true}".utf8)
        case .control:
            guard let request = command.control else { throw ClusterSetupFailure("a control command names no request") }
            return try encoder.encode(executeControl(request, pairing: pairing, say: say))
        case .teardown:
            return try encoder.encode(Self.teardownLines())
        case .batchSetup:
            guard let change = command.batchSetup, let held = ClusterControlCommandLock.acquire(seconds: 5) else {
                throw ClusterSetupFailure("a batch replacement is missing or another cluster command is active")
            }
            defer { held.release() }
            let reference = try change.apply(paths: context.paths,
                providerConfigurations: [settings.wizard.providerConfiguration, try ConfigManager.defaultConfigPath()],
                directory: store.paths.directory, senderMemberID: pairing.peerMemberID)
            say("saved the serving leader's compatible batch setup after native release")
            return try encoder.encode(reference)
        case .approval:
            // Only from the Mac this one follows, and only once its part has stopped (the save needs the device
            // journal empty). The approval is checked against this Mac's own files and pairing: the leader's word
            // adds no trust.
            guard followsPeer(pairing) else { throw ClusterSetupFailure("this Mac does not follow the Mac that asked") }
            let line = try ClusterApprovalSync.receive(command, paths: context.paths,
                providerConfiguration: settings.wizard.providerConfiguration, pairingStore: pairingStore,
                scratch: store.paths.directory, now: Date().timeIntervalSince1970, say: say)
            return Data(line.utf8)
        case .lease:
            throw ClusterSetupFailure("leases go to the control listener")
        }
    }

    /// How often a part that has not ended yet is sent SIGTERM again while it is waited for.
    static let stopResendSeconds: Double = 5

    /// Degraded serving alone listens where `start --local` listens by default, on this Mac's loopback.
    public static let soloPort = 8000

    /// What the solo port shows: THIS service's solo server (the published solo child, checked by its start time so a
    /// recycled process number never counts, or a process it started) holding the listening socket and answering its
    /// model list; that server still loading; or another program answering there (never taken for ours).
    public enum SoloReadiness: Equatable { case ready, loading, foreign }

    static func soloReadiness(_ status: ClusterServiceStatus?, port: Int = soloPort) -> SoloReadiness {
        guard let child = status?.child, child.running, child.solo == true, let pid = child.pid, let startedAt = child.startedAt,
              let now = ClusterProcessTable.startTime(of: pid), abs(now - startedAt) < 0.001 else { return .loading }
        let ours = ([pid] + ClusterProcessTable.descendants(of: pid)).contains { ClusterProcessTable.listeningTCPPorts(of: $0).contains(port) }
        // The local API token goes only to our own solo server: another program on the port is probed without it.
        guard ours else { return soloAnswers(port: port, authorized: false) ? .foreign : .loading }
        return soloAnswers(port: port) ? .ready : .loading
    }

    /// The part this Mac's cluster service started (its rank part or its solo server), as its published status names
    /// it, while that very process still runs (same start time, so a recycled process number never counts). With the
    /// cluster stopped, or the service gone, it is left over: verify-teardown counts it, a new service run stops it.
    public struct RecordedPart: Equatable, Sendable { public var pid: Int32; public var startedAt: Double; public var solo: Bool }

    static func runningPart(_ part: RecordedPart?) -> RecordedPart? {
        guard let part, let now = ClusterProcessTable.startTime(of: part.pid), abs(now - part.startedAt) < 0.001 else { return nil }
        return part
    }

    static func recordedPart(_ status: ClusterServiceStatus?) -> RecordedPart? {
        guard let child = status?.child, child.running, let pid = child.pid, let startedAt = child.startedAt else { return nil }
        return runningPart(.init(pid: pid, startedAt: startedAt, solo: child.solo == true))
    }

    /// SIGTERM, repeated every `stopResendSeconds`, never SIGKILL (a rank releases its model itself), and only while the
    /// process is still the recorded one.
    static func stopLeftover(_ part: RecordedPart, seconds: Double) -> Bool {
        let started = Date()
        var sent = -1
        while runningPart(part) != nil {
            guard Date().timeIntervalSince(started) < seconds else { return false }
            let due = Int(Date().timeIntervalSince(started) / stopResendSeconds)
            if due > sent { sent = due; kill(part.pid, SIGTERM) }
            usleep(100_000)
        }
        return true
    }

    /// After saved serving intent is cleared, retire this Mac's exact owned
    /// part before asking its peer to stop. The live service must publish idle
    /// too: a part may have been starting when the first snapshot was read.
    /// An unavailable service can still leave a recorded part to recover.
    static func stopLocalPart(in directory: URL, seconds: Double) -> Bool {
        precondition(seconds.isFinite && seconds >= 0)
        let deadline = Date().addingTimeInterval(seconds)
        let previousAcknowledgement = supervisionAcknowledgement(in: directory)?.publication
        var owned: RecordedPart?
        repeat {
            let status = published(in: directory)
            if status == nil, FileManager.default.fileExists(atPath: directory.appendingPathComponent("service-status.json").path) {
                return false
            }
            if let child = status?.child, child.running, child.pid == nil || child.startedAt == nil { return false }
            if let part = recordedPart(status) {
                // A replacement is a new operation's custody, never another
                // process to signal using the previous stop's authority.
                if let owned, owned != part { return false }
                owned = part
                guard stopLeftover(part, seconds: max(0, deadline.timeIntervalSinceNow)) else { return false }
                continue
            }
            guard let serviceRunning = running(in: directory) else { return false }
            if !serviceRunning { return owned.map { runningPart($0) == nil } ?? true }
            let pidFile = files(in: directory).pid
            if let status, let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let writer = status.servicePID,
               let current = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), writer == current,
               !status.serving, !status.child.running,
               let acknowledgement = supervisionAcknowledgement(in: directory),
               acknowledgement.servicePID == writer, acknowledgement.idle,
               acknowledgement.publication != previousAcknowledgement { return true }
            if Date() >= deadline { return false }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// `authorized`: whether a server answers its model list on the solo port with this Mac's local API token (only
    /// ever sent to this service's own solo server: see `soloReadiness`); otherwise whether anything answers HTTP there,
    /// asked without the token.
    static func soloAnswers(port: Int = soloPort, authorized: Bool = true) -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.timeoutInterval = 3
        if authorized, let token = LocalEndpoint.readToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let prepared = request
        return blockingWizard {
            guard let (_, response) = try? await URLSession.shared.data(for: prepared), let http = response as? HTTPURLResponse else { return false }
            return authorized ? http.statusCode == 200 : true
        }
    }

    /// The leader leaving the pair with `peerPin` tells that member first,
    /// while the pairing's edge secret still keys the link: the member then
    /// reclaims the pair's prefix-tier records (and forgets the leader's
    /// cache settings). Nil when this Mac does not lead a pair with that pin;
    /// otherwise one line for the screen, also when the member was not reached.
    public static func tellMemberOfUnpair(peerPin: String, seconds: Double = 10) -> String? {
        guard let pairing = try? ClusterSetupLinkExchange.pairing(), pairing.peerPin == peerPin,
              let paths = try? ClusterUserPaths(),
              let leadership = try? ClusterSetupStore(paths: .init(paths: paths)).readRecord().leadership,
              leadership.role == ClusterOnboardingRole.leader.rawValue, leadership.peerPin == peerPin else { return nil }
        do {
            let body = try JSONEncoder().encode(ClusterServiceCommand(op: .unpair, clusterID: pairing.clusterID))
            let selection = try LiveContext.defaultLinkSelection()
            let answer = try ClusterSetupLinkExchange.command(pairing: pairing, selection: selection, peerAddress: nil,
                                                              body: body, seconds: seconds)
            let reply = try JSONDecoder().decode(ClusterMemberCacheControl.UnpairReply.self, from: answer.reply)
            return "The other Mac reclaimed its pair cache: removed \(reply.removedPlans) plan\(reply.removedPlans == 1 ? "" : "s")"
                + (reply.keptLive > 0 ? ", \(reply.keptLive) still in use (removed when its part stops)" : "") + "."
        } catch {
            return "The other Mac was not reached (\(ClusterConsoleText.bounded(String(describing: error), maximum: 160))): "
                + "its pair cache stays until it unpairs too (`darkbloom cluster pair --forget \(pairing.localPin)` there)."
        }
    }

    /// Where this Mac keeps the cache settings its leader synced.
    var cacheStore: ClusterMemberCacheControl.Store { .init(directory: store.paths.directory) }

    /// The answer tokens a test request asks for: fewer than a speed record has
    /// (`ClusterServedSpeedRule.minimumCompletionTokens`), so the onboarding's
    /// test answer never steers a plan.
    static let testAnswerTokens = 48

    /// One test request through this Mac's serving API, collected.
    static func prompt(_ context: LiveContext, text: String, port: Int? = nil) -> ClusterServicePromptAnswer {
        let collected = ClusterOnboardingMailbox<ClusterSetupPromptEvent>()
        context.prompt(text: String(text.prefix(400)), maxTokens: testAnswerTokens, port: port) { collected.post($0) }
        var answer = ClusterServicePromptAnswer(text: "", tokens: 0)
        for event in collected.take() {
            switch event {
            case .text(let piece): answer.text += piece
            case .finished(let result):
                answer.tokens = result.completionTokens; answer.firstTokenMilliseconds = result.firstTokenMilliseconds
                answer.tokensPerSecond = result.tokensPerSecond; answer.finishReason = result.finishReason
            case .failed(let reason): answer.error = reason
            }
        }
        return answer
    }

    public func status() -> ClusterServiceStatus {
        let oldPart = leftover()
        let record = try? store.readRecord()
        let saved = context.savedConfiguration()
        let configuration = saved.configuration
        let leads = configuration?.role == .leader
        var session: ClusterServiceStatus.Session?
        if leads {
            let live = context.observe(link: false)
            session = .init(observed: live.observed, ready: live.ready, readyRanks: live.readyRanks,
                ranks: max(live.members.count, configuration?.peers.count ?? 2), port: live.port, detail: live.detail ?? live.sessionPhase)
        }
        return lock.withLock {
            let reference = try? saved.reference.get()
            let wait = nextStart.timeIntervalSinceNow
            var value = ClusterServiceStatus(role: record?.leadership?.role, serving: record?.leadership?.serving ?? false,
                modelName: record?.leadership?.modelName, sessionLeader: leads, localRank: configuration?.localRank,
                setup: reference.map { String($0.sha256.prefix(12)) },
                child: .init(running: child?.isRunning == true || oldPart != nil, starts: starts, lastEnd: lastEnd,
                    restartInSeconds: child == nil && oldPart == nil && wait > 0 ? Int(wait.rounded(.up)) : nil,
                    lastError: child?.isRunning == true ? nil : Self.lastError(in: serviceFiles.rankLog),
                    pid: child?.isRunning == true ? child?.processIdentifier : oldPart?.pid,
                    startedAt: child?.isRunning == true ? childStartedAt : oldPart?.startedAt,
                    solo: child?.isRunning == true ? childSetup?.hasPrefix("solo:") == true : oldPart?.solo,
                    notice: oldPart != nil ? "the previous run's part is still releasing; waiting before starting another"
                        : child?.isRunning == true && childSetup?.hasPrefix("solo:") != true ? Self.servingNotice(in: serviceFiles.rankLog) : nil,
                    configurationSHA256: child?.isRunning == true && childSetup?.hasPrefix("cluster:") == true
                        ? String(childSetup!.dropFirst("cluster:".count).prefix(64)) : nil),
                session: session,
                // What this Mac applied from the Mac it follows (by control, not by who drove the onboarding):
                // keyed by onboarding role, a Mac that drove it and then followed reported nothing, and the
                // leader sent its settings again every 15 s.
                cacheSync: Self.followedLeaderPin(record: record, pairingStore: pairingStore).flatMap { cacheStore.digest(leaderPin: $0) },
                control: controlStatusLocked(model: record?.leadership?.modelName), servicePID: getpid())
            value.updating = updatingLine
            value.localOnly = record?.leadership.map { $0.scope.isLocalOnly }
            value.memberQuickEnds = memberQuickEnds
            value.approvalID = configuration?.nativeMember?.clusterApproval?.id ?? ""
            return value
        }
    }

    /// On the control leader, while the cluster serves: when a Darkbloom update changed a Mac's worker (its digest no
    /// longer matches the saved setup's pin, so both Macs refuse their parts), the same model is planned again,
    /// adopted, synced to the member and served, as `m` with the same model would, with nobody running a command.
    /// Checked every `ClusterOnboardingUpdate.checkEverySeconds` on a thread of its own; holds the command lock so a
    /// person's command and this never run at once.
    private func checkForUpdate(say: @escaping @Sendable (String) -> Void) {
        guard let leadership = (try? store.readRecord())?.leadership, leadership.serving, let model = leadership.modelName,
              lock.withLock({ control?.leads == true }) else { return }
        let begin: Bool = lock.withLock {
            guard !updateInFlight, !stopping, Date() >= nextUpdateCheck else { return false }
            updateInFlight = true
            nextUpdateCheck = Date().addingTimeInterval(ClusterOnboardingUpdate.checkEverySeconds)
            return true
        }
        guard begin else { return }
        let context = self.context
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.updateInFlight = false; self.updatingLine = nil } }
            guard let saved = context.savedConfiguration().configuration, saved.peers.indices.contains(saved.localRank) else { return }
            let pinned = Dictionary(saved.peers.map { ($0.id, $0.runtimeBinarySHA256) }, uniquingKeysWith: { a, _ in a })
            let local = saved.peers[saved.localRank]
            var current: [String: String?] = [local.id: try? context.workerSHA256(local.workerExecutable)]
            if case .reached = context.reachPeer(), let facts = context.peerFacts { current[facts.memberID] = facts.runtimeBinarySHA256 }
            let changed = ClusterOnboardingUpdate.changed(pinned: pinned, current: current)
            guard !changed.isEmpty else { return }
            guard let held = ClusterControlCommandLock.acquire(seconds: 5) else { return }
            defer { held.release() }
            self.lock.withLock { self.updatingLine = ClusterOnboardingUpdate.statusLine }
            self.publish()
            say("Darkbloom changed on \(changed.count == 1 && changed[0] == local.id ? "this Mac" : changed.count == 1 ? "the other Mac" : "both Macs"): "
                + "setting the cluster up again for \(model)")
            func failed(_ lines: [String]) {
                say("could not set the cluster up again after the update: " + lines.joined(separator: " "))
                self.lock.withLock { self.nextUpdateCheck = Date().addingTimeInterval(ClusterOnboardingUpdate.retryAfterFailureSeconds) }
            }
            let live = self.controlLive
            if case .failure(let failure) = live.localReachMembers({ _ in }) { return failed(failure.lines) }
            // Both Macs refuse the old parts once their workers changed, and the parts hold the model's memory until
            // they stop: stop them and wait for the memory before planning. Planned while they run, a tensor-parallel
            // pair does not fit "now" and a pipeline is chosen in its place. A failure from here on keeps the
            // serving intent, so the next check tries again.
            if case .failure(let failure) = live.localStop() { return failed(failure.lines) }
            let releasedBy = Date().addingTimeInterval(ClusterOnboardingUpdate.releaseWaitSeconds)
            while Date() < releasedBy, case .success(let lines) = live.localVerifyTeardown(),
                  !ClusterOnboardingUpdate.released(lines) {
                Thread.sleep(forTimeInterval: 2)
            }
            func failedStopped(_ lines: [String]) {
                try? self.store.updateRecord { $0.leadership?.serving = true }
                failed(lines)
            }
            // The same model keeps the mode the pair served it in, unless the planner and the pair's own served
            // requests both find another faster (`ClusterServedModes.hold`). `localPlanModels` asks the other Mac for
            // its report again: the one `localReachMembers` took above still counts its old part's memory.
            let keeping = saved.publicModelID == model ? [model: saved.selectedGenerationMode] : [:]
            let choices: [ClusterOnboardingModelChoice]
            switch live.localPlanModels(keeping: keeping) {
            case .success(let value): choices = value
            case .failure(let failure): return failedStopped(failure.lines)
            }
            // `model` is the model's id (the record keeps ids; the screens show catalog names).
            guard let index = choices.firstIndex(where: { ($0.modelID ?? $0.title) == model && $0.blocker == nil && $0.provision == nil }) else {
                return failedStopped(["\(model) is not offered on these Macs with this release: \(choices.first { ($0.modelID ?? $0.title) == model }?.blocker ?? "not found")"])
            }
            if case .failure(let failure) = live.localAdopt(index) { return failedStopped(failure.lines) }
            if case .failure(let failure) = live.localServe() { return failedStopped(failure.lines) }
            // The plan's own line and its reason for the mode (tensor parallel or a pipeline), so the log says why.
            say("set the cluster up again after the update: \(model) is starting on both Macs ("
                + choices[index].lines.joined(separator: " ") + ")")
            // The re-adopted setups carry no cluster approval: the next check looks for the entry of the updated app.
            self.lock.withLock { self.approvalChecked = false; self.nextApprovalCheck = .distantPast }
        }
    }

    /// On the control leader: asks the coordinator for its cluster approvals once per run of this service, and every
    /// `ClusterOnboardingUpdate.checkEverySeconds` while the pair is registered or serves locally with its approval set
    /// aside (`ClusterApprovalCheck.asks`). Only when a setup must change (`ClusterApprovalCheck.step`: an approval to
    /// save, or one to serve without because the coordinator gave no answer for the grace, no longer lists it, or the
    /// parts keep failing with it) it stops both parts, changes both Macs' setups and serves again. A coordinator that
    /// serves nothing new changes nothing and stops nothing. An approval that ended is removed by each Mac itself
    /// before its part starts (`supervise`), never by stopping a running pair.
    private func checkApproval(say: @escaping @Sendable (String) -> Void) {
        let begin: Bool = lock.withLock {
            guard !approvalInFlight, !updateInFlight, !stopping, control?.leads == true, Date() >= nextApprovalCheck else { return false }
            approvalInFlight = true
            return true
        }
        guard begin else { return }
        let paths = context.paths, configuration = settings.wizard.providerConfiguration, scratch = store.paths.directory
        let pairingStore = self.pairingStore
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.approvalInFlight = false } }
            let first = self.lock.withLock { !self.approvalChecked }
            func checked() {
                self.lock.withLock {
                    self.approvalChecked = true
                    self.nextApprovalCheck = Date().addingTimeInterval(ClusterOnboardingUpdate.checkEverySeconds)
                }
            }
            let live = self.controlLive
            let watchBefore = self.lock.withLock { self.approvalWatch }
            /// The step for the setup, record and other Mac as they are now, for one answer of the coordinator.
            struct Decided {
                let step: ClusterApprovalCheck.Step
                let watch: ClusterApprovalCheck.Watch
                let serving: Bool
            }
            func decide(_ answer: () -> ClusterApprovalFetch.Outcome?) -> Decided? {
                let record = try? self.store.readRecord()
                let scope = record?.leadership?.scope ?? .publicServing
                var setAside = record?.approvalSetAside
                guard let saved = try? ClusterApprovalAttachment.savedSetup(paths: paths, providerConfiguration: configuration) else {
                    return nil
                }
                let now = Date().timeIntervalSince1970
                let offered = saved.configuration.nativeMember.map { ClusterApprovalLifetime.offers($0, scope: scope, now: now) } ?? false
                // The other Mac's saved cluster approval and its coordinator-paired parts' quick ends, from its status
                // (unknown when it does not answer or does not report them): both Macs carry the same approval, or neither.
                let peer = try? JSONDecoder().decode(ClusterServiceStatus.self, from: live.command(.init(op: .status), seconds: 10))
                let peerApprovalID = ClusterApprovalCheck.peerApprovalID(peer)
                let macsDiffer = ClusterApprovalCheck.macsDiffer(saved, peerApprovalID: peerApprovalID)
                let asks = ClusterApprovalCheck.asks(first: first, serving: record?.leadership?.serving == true, scope: scope,
                                                     offered: offered, setAside: setAside != nil, macsDiffer: macsDiffer)
                guard asks || macsDiffer else { return nil }
                // A local-only cluster settles a difference between the Macs without asking the coordinator.
                guard let fetched = asks ? answer() : .unavailable("not asked") else { return nil }
                if let ended = setAside, !ClusterApprovalLifetime.current(ended.approval, now: now) {
                    try? self.store.updateRecord { $0.approvalSetAside = nil }
                    setAside = nil
                }
                let quickEnds = max(self.lock.withLock { self.memberQuickEnds }, peer?.memberQuickEnds ?? 0)
                var watch = watchBefore
                let step = ClusterApprovalCheck.step(saved: saved, fetched: fetched, setAside: setAside, scope: scope,
                    memberQuickEnds: quickEnds, peerApprovalID: peerApprovalID, watch: &watch, clock: ClusterService.monotonicSeconds(),
                    grace: ClusterService.soloGraceSeconds, now: now)
                return Decided(step: step, watch: watch, serving: record?.leadership?.serving == true)
            }
            var fetched: ClusterApprovalFetch.Outcome?
            func answer() -> ClusterApprovalFetch.Outcome? {
                if fetched == nil {
                    fetched = ClusterApprovalFetch.fetchBlocking(providerConfiguration: configuration) ?? .unavailable("no coordinator is configured")
                }
                return fetched
            }
            guard let initial = decide(answer) else { return checked() }
            self.lock.withLock { self.approvalWatch = initial.watch }
            guard initial.step != .keep else { return checked() }
            // A person's command and this never run at once. A busy lock is tried again at the next check, a minute on,
            // not at every tick.
            guard let held = ClusterControlCommandLock.acquire(seconds: 5) else {
                say("another cluster command is running: the cluster approval is checked again in a minute")
                return checked()
            }
            defer { held.release() }
            checked()
            // Decided again under the lock, with the same answer: a person's command may have changed the setup, the
            // scope or the other Mac while this check waited.
            guard let decided = decide(answer) else { return }
            self.lock.withLock { self.approvalWatch = decided.watch }
            let step = decided.step, serving = decided.serving
            guard step != .keep else { return }
            let send: (ClusterServiceCommand) throws -> Void = { request in _ = try live.command(request, seconds: 180) }
            let result = ClusterApprovalSync.apply(step, grace: ClusterService.soloGraceSeconds, paths: paths,
                providerConfiguration: configuration, pairingStore: pairingStore, scratch: scratch, now: Date().timeIntervalSince1970,
                stop: {
                    guard serving else { return nil }
                    if case .failure(let failure) = live.localStop() {
                        return "could not stop the parts to change the cluster approval: " + failure.lines.joined(separator: " ")
                    }
                    guard live.drained(seconds: 300) else {
                        try? self.store.updateRecord { $0.leadership?.serving = true }
                        return "a part did not stop within 5 minutes: the cluster approval stays as it is"
                    }
                    return nil
                },
                serve: {
                    guard serving, case .failure(let failure) = live.localServe() else { return }
                    try? self.store.updateRecord { $0.leadership?.serving = true }
                    say("could not start the parts again after the cluster approval changed: " + failure.lines.joined(separator: " "))
                },
                sendToPeer: send)
            try? self.store.updateRecord { stored in
                if let note = result.note { stored.approvalNote = note }
                // The approval set aside is kept while the pair serves locally and dropped once one is saved again.
                if case .serveLocally(let approval, let reason) = step, result.changed {
                    stored.approvalSetAside = .init(approval: approval, reason: reason)
                }
                if case .save = step, result.changed { stored.approvalSetAside = nil }
            }
            if let line = result.line { say(line) }
        }
    }

    /// The last "Error:" line of this Mac's part's log, bounded; nil when there is none.
    public static func lastError() -> String? {
        (try? paths().rankLog).flatMap { lastError(in: $0) }
    }

    /// The same in `log`, reading only from `offset` on (where the part that ended began writing), so an error an
    /// earlier part wrote is never taken for this part's. A log shorter than `offset` was replaced: it is read whole.
    static func lastError(in log: URL, from offset: UInt64 = 0) -> String? {
        guard let handle = FileHandle(forReadingAtPath: log.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = size > 16_384 ? size - 16_384 : 0
        try? handle.seek(toOffset: offset <= size ? max(offset, window) : window)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let line = tail.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Error:") }) else { return nil }
        return ClusterConsoleText.plain(ClusterConsoleText.bounded(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces), maximum: 240))
    }

    /// `ClusterLocalServing.notice` when this Mac's running part (rank 0) said it serves on its local API only.
    public static func servingNotice() -> String? {
        (try? paths().rankLog).flatMap { servingNotice(in: $0) }
    }

    private static func servingNotice(in log: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: log.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        return ClusterLocalServing.notice(inLog: String(decoding: handle.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Private local acknowledgement; only the supervision loop can advance
    /// it. An ordinary status publication can happen while a start is in flight.
    private struct SupervisionAcknowledgement: Codable {
        var servicePID: Int32
        var publication: UUID
        var idle: Bool
    }

    private static func supervisionAcknowledgement(in directory: URL) -> SupervisionAcknowledgement? {
        let file = directory.appendingPathComponent("service-supervision.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SupervisionAcknowledgement.self, from: data)
    }

    /// Kept beside the lock each tick, so `darkbloom cluster` on this Mac reads it without the link.
    private func publish(afterSupervision: Bool = false) {
        let value = status()
        let file = store.paths.directory.appendingPathComponent("service-status.json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: .atomic)
        if afterSupervision {
            var idle = !value.serving && !value.child.running
            if idle {
                idle = lock.withLock {
                    // A previously constructed running=true lease must finish
                    // before the stop becomes visible to the peer. New sends
                    // take this same lock and reread the cleared record.
                    guard !leaseInFlight else { return false }
                    do {
                        var record = try store.readRecord()
                        if let drain = record.stopDrain, drain.id == supervisedStopDrainID {
                            record = try store.updateRecord {
                                if $0.stopDrain?.id == drain.id, $0.leadership?.serving != true { $0.stopDrain = nil }
                            }
                        }
                        return record.stopDrain == nil && record.leadership?.serving != true
                    } catch { return false }
                }
            }
            let acknowledgement = SupervisionAcknowledgement(servicePID: getpid(), publication: UUID(), idle: idle)
            if let data = try? JSONEncoder().encode(acknowledgement) {
                try? data.write(to: store.paths.directory.appendingPathComponent("service-supervision.json"), options: .atomic)
            }
        }
    }

    /// The status the running service last published on this Mac.
    public static func published() -> ClusterServiceStatus? {
        guard let directory = try? paths().pid.deletingLastPathComponent() else { return nil }
        return published(in: directory)
    }

    /// Whether a model is loaded, or loading, on this Mac now: this Mac's cluster service runs its part or its solo
    /// server (its published status, while the process it names still runs), or a cluster worker runs here, whoever
    /// started it. Nothing that works the GPU for itself (the plan tool's speed index) runs then.
    public static func modelLoaded() -> Bool {
        recordedPart(published()) != nil
            || ClusterOrphanWiredGuard.otherDarkbloomProcesses().contains(ClusterBundledHelpers.workerName)
    }

    private static func published(in directory: URL) -> ClusterServiceStatus? {
        let file = directory.appendingPathComponent("service-status.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ClusterServiceStatus.self, from: data)
    }

    /// The published status only while the service that wrote it runs now (holds the lock and its pid file names it);
    /// nil otherwise, e.g. the file a stopped service left behind.
    public static func publishedLive() -> ClusterServiceStatus? {
        guard running(), let status = published(), let writer = status.servicePID, let pidFile = try? paths().pid,
              let text = try? String(contentsOf: pidFile, encoding: .utf8),
              Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == writer else { return nil }
        return status
    }

    // MARK: - This Mac's part

    private func supervise(say: @escaping @Sendable (String) -> Void) {
        // A cleanup timeout is not permission to load a second model beside the old one.
        guard leftover() == nil else { return }
        // A record that cannot be read is not "the leader stopped serving" (F17: a service out of descriptors stopped its
        // part on the failed read): this Mac's part is kept as it is, and the failure is said once, until a read works.
        let record: ClusterSetupRecord
        switch Self.supervisedRecord({ try store.readRecord() }) {
        case .failure(let failure):
            if lock.withLock({ recordProblem }) != failure.text {
                lock.withLock { recordProblem = failure.text }
                say(failure.text + ": keeping this Mac's part as it is until it can")
            }
            return
        case .success(let value):
            record = value
            if lock.withLock({ recordProblem }) != nil {
                lock.withLock { recordProblem = nil }
                say("this Mac's setup record reads again")
            }
        }
        supervisedStopDrainID = record.stopDrain?.id
        let saved = context.savedConfiguration()
        let reference = try? saved.reference.get()
        let serving = record.leadership?.serving ?? false
        // How the cluster serves (kept until the person changes it). Only rank 0's part depends on it.
        let scope = record.leadership?.scope ?? .publicServing
        let leadsSession = saved.configuration?.role == .leader
        let runningSolo = lock.withLock { child != nil && childSetup?.hasPrefix("solo:") == true }
        let want = partWanted(serving: serving, hasSetup: reference != nil && saved.configuration != nil,
                              model: saved.configuration?.publicModelID ?? record.leadership?.modelName, runningSolo: runningSolo)
        // What runs is keyed: "cluster:<setup digest>" (this Mac's part of the saved setup; rank 0's also names a
        // local-only scope) or "solo:<model>" (degraded serving on this Mac alone). A part of another key is stopped
        // before the wanted one starts, so a change of scope starts rank 0 again that way.
        let key: String?
        switch want {
        case .keep: return
        case .none: key = nil
        case .cluster: key = reference.map { ClusterLocalServing.partKey(setupSHA256: $0.sha256, scope: leadsSession ? scope : .publicServing) }
        case .solo(let model): key = "solo:" + model
        }
        let (running, setup, ended) = lock.withLock { () -> (Process?, String?, Bool) in
            (child, childSetup, child.map { !$0.isRunning } ?? false)
        }
        if let running, ended {
            let ran = Date().timeIntervalSince(lock.withLock { childStarted })
            let end = running.terminationReason == .uncaughtSignal ? "signal \(running.terminationStatus)" : "exit \(running.terminationStatus)"
            lock.withLock {
                child = nil; childSetup = nil; lastEnd = end; endedKey = setup
                backoff = ran >= 120 ? 3 : min(backoff * 2, 30)
                nextStart = Date().addingTimeInterval(ran >= 120 ? 3 : backoff)
            }
            // A coordinator-paired part that keeps ending right after its start makes the leader serve locally
            // (`ClusterApprovalCheck.step`); an end because the coordinator was out of reach is not counted.
            if lock.withLock({ childIsMember }) {
                let lastError = Self.lastError(in: serviceFiles.rankLog, from: lock.withLock { childLogOffset })
                lock.withLock { memberQuickEnds = ClusterApprovalCheck.memberQuickEnds(after: memberQuickEnds, ranSeconds: ran, lastError: lastError) }
            }
            // F14: a solo server that keeps ending right after its start is not started again for this plan and model
            // (`ClusterControlSoloAdmission`): the status then says this Mac cannot serve it alone.
            if let setup, setup.hasPrefix("solo:") {
                let soloKey = Self.soloKey(plan: saved.configuration?.selectedPlanSHA256, model: String(setup.dropFirst("solo:".count)))
                let count = lock.withLock { () -> Int in
                    let before = soloQuickEnds?.key == soloKey ? soloQuickEnds!.count : 0
                    let after = ClusterControlSoloAdmission.quickEnds(after: before, ranSeconds: ran)
                    soloQuickEnds = (soloKey, after)
                    return after
                }
                if count >= ClusterControlSoloAdmission.maximumQuickEnds {
                    say("the solo server ended \(count) times right after starting: this Mac does not serve the model alone; it waits for the other Mac")
                }
            }
            say("this Mac's \(setup?.hasPrefix("solo:") == true ? "solo server" : "part") ended (\(end)) after \(Int(ran)) s; "
                + (key != nil ? "starting it again" : "not serving"))
            if let setup, setup.hasPrefix("cluster:"), leadsSession, let model = record.leadership?.modelName {
                noteMemoryRefusal(key: setup, since: Date().addingTimeInterval(-ran - 5), model: model, say: say)
            }
            return
        }
        // A part offered to the coordinator whose approval ended, or whose leader now serves locally only, stops
        // here; the next tick saves this Mac's setup without a cluster approval and starts the part that serves
        // locally (a pair approval saved by hand stays saved: see below).
        if running != nil, setup == key, case .cluster = want, let member = saved.configuration?.nativeMember,
           !ClusterApprovalLifetime.offers(member, scope: scope, now: Date().timeIntervalSince1970) {
            say("this Mac's part is registered with the coordinator, but "
                + (scope.isLocalOnly ? "the cluster serves locally only now" : "its approval ended") + ": stopping it")
            _ = stopChild(say: say, seconds: 300)
            lock.withLock { nextStart = .distantPast; backoff = 3 }
            return
        }
        if let running, key == nil || setup != key {
            if leadsSession {
                switch ClusterAutomaticSetupHandoff.disposition(directory: store.paths.directory, paths: context.paths,
                    processID: running.processIdentifier, startedAt: lock.withLock({ childStartedAt }),
                    previousKey: setup, replacementKey: key, scope: scope) {
                case .adopted:
                    lock.withLock { childSetup = key }
                    say("kept this Mac's API listener while adopting its drained batch setup")
                    return
                case .pending: return
                case .reject: break
                }
            }
            let solo = setup?.hasPrefix("solo:") == true
            say(key == nil ? (solo ? "stopping the solo server" : "the leader stopped serving: stopping this Mac's part")
                : key!.hasPrefix("solo:") ? "serving alone: stopping this Mac's part first"
                : solo ? "the cluster re-forms: stopping the solo server first"
                : ClusterLocalServing.scopeChangedOnly(from: setup, to: key)
                    ? (scope.isLocalOnly ? "serving locally only now (no coordinator): restarting this Mac's part"
                                         : "serving through Darkbloom now: restarting this Mac's part")
                : "the setup changed: restarting this Mac's part")
            _ = running
            _ = stopChild(say: say, seconds: 300)
            if key != nil { lock.withLock { nextStart = .distantPast; backoff = 3 } }
            return
        }
        if running == nil, cacheStore.reclaimPending,
           let root = try? ClusterPrefixCacheSettings.resolved(providerConfiguration: settings.wizard.providerConfiguration).root,
           let report = ClusterMemberCacheControl.finishPendingReclaim(root: root, store: cacheStore), report.keptLive == 0 {
            say("reclaimed the pair cache the leader's unpair left in use (\(report.removedPlans) plan\(report.removedPlans == 1 ? "" : "s"))")
        }
        // The restart backoff holds back only the part that ended: serving alone after the grace starts at once.
        guard running == nil, let key, lock.withLock({ !stopping && ClusterControlPartChoice.mayStart(key: key, endedKey: endedKey,
                                                                                                  backoffElapsed: Date() >= nextStart) })
        else { return }
        let arguments: [String]
        let what: String
        var memberRoute = false
        var port: Int?
        if case .solo(let model) = want {
            arguments = ClusterLocalServing.soloArguments(settings.soloArguments, scope: scope) + ["--model", model, "--port", String(Self.soloPort)]
            what = "degraded: serving \(model) on this Mac alone"
            port = Self.soloPort
        } else {
            guard let configuration = saved.configuration else { return }
            let offered = configuration.nativeMember.map {
                ClusterApprovalLifetime.offers($0, scope: scope, now: Date().timeIntervalSince1970)
            } ?? false
            if let member = configuration.nativeMember, !offered, member.clusterApproval != nil {
                // Never a failed start: the setup is saved without the cluster approval (both Macs reach the same
                // bytes by themselves), and the part that serves on the leader's local API starts at the next tick.
                // A pair approval saved by hand (`darkbloom cluster configure`) is the operator's: it stays, and the
                // ordinary part below says why it cannot run beside it, as before the guided setup saved approvals.
                removeEndedApproval(key: key, localOnly: scope.isLocalOnly, say: say)
                return
            }
            if offered {
                memberRoute = true
                // Registered with the coordinator as a cluster member: both Macs run the coordinator-formed pair's member; the
                // leader's rank hosts the link listener and the pair's slot, the other rank dials it.
                arguments = settings.memberArguments
            } else if configuration.role == .leader {
                // This Mac is rank 0 now: the relay gives its port back first.
                if let passing = lock.withLock({ () -> ClusterLocalRelay? in defer { relay = nil }; return relay }) {
                    passing.stop(); LocalEndpoint.removeInfo(ifPID: getpid())
                }
                let leaderPort = leaderAPIPort(scope: scope, say: say)
                port = leaderPort
                arguments = ClusterLocalServing.leaderArguments(settings.leaderArguments, scope: scope) + ["--port", String(leaderPort)]
            } else {
                arguments = settings.followerArguments
            }
            what = "this Mac's part: " + (offered
                ? "rank \(configuration.localRank), registered with the coordinator as a cluster member"
                : configuration.role == .leader
                ? "rank 0 and the serving API" + (scope.isLocalOnly ? " (local only, no coordinator)" : "")
                : "rank \(configuration.localRank)")
        }
        // A cluster part starting again clears the solo record: the next time this Mac is left alone it may try again.
        if case .cluster = want { lock.withLock { soloQuickEnds = nil } }
        // The model's own pages stay in, and are read into, the file cache while the part starts: the load gate
        // counts all of it as available (58d7371a), and the rank's load reads cached pages at memory speed instead of
        // from the SSD (GLM tensor parallel: 101 GB/s against 14 GB/s on an M5 Ultra), most of a restart's time.
        if case .cluster = want, let configuration = saved.configuration, configuration.peers.indices.contains(configuration.localRank) {
            ClusterModelStore.prefetchPagesInBackground(folder: URL(fileURLWithPath: configuration.peers[configuration.localRank].modelDirectory))
        }
        let process = Process()
        process.executableURL = settings.wizard.darkbloomExecutable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let log = serviceFiles.rankLog
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        var logOffset: UInt64 = 0
        if let handle = try? FileHandle(forWritingTo: log) { logOffset = handle.seekToEndOfFile(); process.standardOutput = handle; process.standardError = handle }
        beforePartStart?()
        do { try process.run() } catch {
            say("\(what) could not start: \(error)")
            lock.withLock { nextStart = Date().addingTimeInterval(backoff); backoff = min(backoff * 2, 30); endedKey = key }
            return
        }
        let startedAt = ClusterProcessTable.startTime(of: process.processIdentifier)
        lock.withLock {
            child = process; childSetup = key; childPort = port; childStarted = Date(); childStartedAt = startedAt; starts += 1
            childIsMember = memberRoute; childLogOffset = logOffset
            if !memberRoute { memberQuickEnds = 0 }
        }
        say("started \(what) (pid \(process.processIdentifier))")
    }

    /// Saves this Mac's setup without its cluster approval (it ended, or the cluster serves locally only). A save
    /// that cannot run yet (the device lease of the part that just ended) is tried again after the restart backoff.
    private func removeEndedApproval(key: String, localOnly: Bool, say: @Sendable (String) -> Void) {
        do {
            guard let saved = try ClusterApprovalAttachment.savedSetup(paths: context.paths,
                    providerConfiguration: settings.wizard.providerConfiguration) else { return }
            try ClusterApprovalAttachment.save(nil, saved: saved, paths: context.paths,
                providerConfiguration: settings.wizard.providerConfiguration, scratch: store.paths.directory)
            let line = localOnly ? "saved this Mac's setup without its cluster approval: the cluster serves locally only"
                : "the cluster approval \(saved.configuration.nativeMember?.clusterApproval?.id ?? "") expired: saved this Mac's setup without it; "
                    + "the pair serves on the leader's local API"
            say(line)
            if !localOnly, saved.configuration.role == .leader { try? store.updateRecord { $0.approvalNote = line } }
        } catch {
            say("could not save this Mac's setup without its cluster approval yet: \(ClusterApprovalSync.refusal(error))")
            lock.withLock { nextStart = Date().addingTimeInterval(backoff); backoff = min(backoff * 2, 30); endedKey = key }
        }
    }

    /// The port rank 0's API takes on this Mac (another local server may hold 8000). Local only on every address (where
    /// the other Mac relays it), one free on both Macs (`ClusterLocalServing.sharedPort`), asked of the other Mac for
    /// at most 5 s; otherwise, or when it does not answer, one free here.
    private func leaderAPIPort(scope: ClusterServingScope, say: @Sendable (String) -> Void) -> Int {
        let peerFree = scope.bind == "0.0.0.0" ? peerFreePorts(seconds: 5) : nil
        let previous = lock.withLock { apiPort }
        let port = ClusterLocalServing.sharedPort(localFree: ClusterLocalServing.freePorts(), peerFree: peerFree, preferred: previous)
        lock.withLock { apiPort = port }
        if port != previous, port != ClusterLocalServing.servingPorts.lowerBound {
            say(peerFree == nil ? "port 8000 is taken on this Mac: the API listens on port \(port)"
                : peerFree!.contains(port) ? "port 8000 is not free on both Macs: the API listens on port \(port) on both"
                : "no port from 8000 to 8020 is free on both Macs: the API listens on port \(port) on this Mac")
        }
        return port
    }

    /// The setup record supervise acts on, or why it could not be read (a missing record reads as an empty one).
    static func supervisedRecord(_ read: () throws -> ClusterSetupRecord) -> Result<ClusterSetupRecord, ClusterSetupFailure> {
        do { return .success(try read()) } catch {
            return .failure(ClusterSetupFailure("cannot read this Mac's setup record (\(ClusterConsoleText.bounded(String(describing: error), maximum: 160)))"))
        }
    }

    /// SIGTERM, then wait: a rank that holds a model releases it itself.
    private func stopChild(say: @Sendable (String) -> Void, seconds: Double) -> Bool {
        guard let running = lock.withLock({ child }) else { return true }
        if running.isRunning { running.terminate() }
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        var resent = 0
        while running.isRunning, Date() < deadline {
            usleep(100_000)
            // A part asked to stop while it was still starting may have had SIGTERM ignored before its handler existed
            // (an ignored disposition survives exec): SIGTERM again, never SIGKILL (its handler makes repeats harmless).
            let due = Int(Date().timeIntervalSince(started) / Self.stopResendSeconds)
            if due > resent, running.isRunning { resent = due; kill(running.processIdentifier, SIGTERM) }
        }
        let clean = !running.isRunning
        if clean { lock.withLock { child = nil; childSetup = nil; lastEnd = "stopped" } }
        say(clean ? "this Mac's part stopped" : "this Mac's part is still releasing after \(Int(seconds)) s")
        return clean
    }
}

extension DistributedInstalledOwner {
    /// The workers' own diagnostics, kept beside the cluster service's logs (`worker.log`, bounded, owner-only), so
    /// a healthy session's prefix-cache and context lines can be read (`ClusterWorkerDiagnosticsLog`).
    public static func installWorkerDiagnosticsLog() {
        guard let paths = try? ClusterUserPaths() else { return }
        ClusterWorkerDiagnosticsLog.shared = .init(url: ClusterSetupPaths(paths: paths).directory.appendingPathComponent("worker.log"))
    }
}
