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
    /// The supervision loop's period: one supervise/publish cycle per interval.
    private let supervisionIntervalSeconds: Double
    private let beforePartStart: (@Sendable () -> Void)?
    /// The environment this Mac's parts start from (`partEnvironment`); nil: this process's own at each start.
    private let environment: [String: String]?
    /// The name of this service's power assertions. macOS lists a process's assertions together, so a check that
    /// runs several services in one process gives each a name of its own.
    private let powerAssertionReason: String
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
    /// How long the last part ran (`ClusterServiceStatus.Child.lastRunSeconds`).
    private var lastRunSeconds: Double?
    private var nextStart = Date.distantPast
    /// The part whose end (or failed start) set `nextStart`: its restart backoff does not hold back another part.
    private var endedKey: String?
    private var backoff: Double = 3
    var responder: ClusterSetupLinkExchange.Responder?
    var stopping = false
    private var syncing = false
    /// On the leader: why the other Mac's part can't start now, as its status last said (`ClusterService.heldBack(of:)`);
    /// this Mac's part waits for it instead of starting and ending again. Nil when it says none or didn't answer.
    private var peerHeldBack: String?
    /// Why this Mac's part waits while the other Darkbloom app holds this Mac's GPU (`holdsBackForOtherApp`); nil when
    /// it doesn't.
    private var otherAppHolds: String?
    /// Production serving on this Mac, in words (`ClusterMachineDeviceLock.productionServingHere`): this build's check,
    /// nil in production's own build; tests stand in.
    var productionServes: (@Sendable () -> String?)?
    /// Fences the GPU work of this Mac's part (`partPID`) at once when it steps aside for production, and says how many
    /// worker owners it asked (`fenceOwners`); tests stand in.
    var fenceGPUWork: @Sendable (_ partPID: Int32) -> Int = { ClusterService.fenceOwners(of: $0) }
    /// A step aside of single-Mac serving runs (`stepAsideIfUnchosen`), and the process it was for.
    private var steppingAside = false
    private var steppedAsidePID: Int32?
    /// How single-Mac serving is stopped (`stop --solo`); tests stand in.
    var stopSingleMac: @Sendable (URL) -> Result<Void, ClusterSetupFailure> = { ClusterService.stopSoloServing(executable: $0) }
    /// The re-plan after an update (`checkForUpdate`): each Mac's running worker digest by member, and the re-plan's
    /// steps; tests stand in. Nil: this Mac's worker and the other Mac's as it answers over the cable, and the control
    /// leader's onboarding operations.
    var updateReplan: (running: () -> [String: String?], steps: UpdateReplan)?
    private var peerHeldBackSaid: String?
    private var nextSync = Date.distantPast
    // Setting the cluster up again after a Darkbloom update (`checkForUpdate`); a test moves the next check instead of
    // waiting for it.
    private var updateInFlight = false
    var nextUpdateCheck = Date.distantPast
    private var updatingLine: String?
    /// Said once while the Macs run different builds after an update.
    private var updateWaitLine: String?
    /// The member's line while its saved setup pins an earlier build than it runs (said once per wait).
    private var memberSetupWaitLine: String?
    /// The other Mac's version as its service last published it (`pairUpdate.running`), for the wait lines, and when it
    /// may be asked again (`otherMacVersion`).
    private var otherVersion: String?
    private var otherVersionAsked = Date.distantPast
    private var otherVersionAsking = false
    // The cluster approval is asked for once per run of this service on the control leader, and again every minute
    // while the pair is offered or serves locally with its approval set aside (`checkApproval`); a test moves the next
    // check instead of waiting for it.
    private var approvalChecked = false
    private var approvalInFlight = false
    var nextApprovalCheck = Date.distantPast
    private var approvalWatch = ClusterApprovalCheck.Watch()
    // This Mac's coordinator-paired parts that ended in a row right after starting (`ClusterApprovalCheck.memberQuickEnds`),
    // and whether the running part is one.
    private var memberQuickEnds = 0
    private var childIsMember: Bool { childMemberRank != nil }
    /// The running coordinator-paired part's rank (nil for any other part): only rank 0, which hosts the pair's slot,
    /// writes the pair's `Pair: …` lines.
    private var childMemberRank: Int?
    /// The running part is the link follower (`followerArguments`), the only part that writes a Local Network refusal.
    private var childIsLinkFollower = false
    /// The running follower's refusal as last read, by its log's size (`runningPartRefusal`).
    private var followerRefusalRead: FollowerRefusalRead?
    /// A single-Mac provider serving on this Mac, seen before this Mac's part would start (`supervise`): nothing starts
    /// beside it, and the status names it, until it stops.
    private var soloServing: ProviderInstanceHolder.Holder?
    /// Whether the pair actually runs here (`watchPair`), and its last verdict.
    private var pairWatch = ClusterPairWatch()
    private var pairVerdict: ClusterPairWatch.Verdict = .running
    private let providerInstanceLock: URL
    // Where the running part began writing its log (`lastError(in:from:)`).
    private var childLogOffset: UInt64 = 0
    // Derived control (ClusterServiceControl.swift).
    var control: ClusterControlNode?
    var controlResponder: ClusterSetupLinkExchange.Responder?
    /// The port the cluster's API last used on this Mac (rank 0's here, or the relay's): kept, while free, only when this
    /// Mac's own port (`thisMacPort`) can't be read.
    private var apiPort: Int?
    /// The port the running part listens on: rank 0's API or the solo server's; nil for any other part.
    private var childPort: Int?
    /// The memory re-plan's steps (`replanForMemory`); tests stand in. Nil: the control leader's onboarding operations.
    var memoryReplan: MemoryReplan?
    /// Starts of this setup that ended on a memory-gate refusal (a Mac's memory moved after the plan was made), and
    /// when the plan may next be made again (`noteMemoryRefusal`); tests read whether one is under way.
    private var memoryRefusals: (key: String, count: Int)?
    private var nextMemoryReplan = Date.distantPast
    var memoryReplanInFlight = false
    /// Re-plans in a row that came back with the same split: after `memoryReplansWithSameSplit` the service stops
    /// re-planning (the memory is short for every split) until a re-plan finds another one or the service restarts.
    private var sameSplitReplans = 0
    static let memoryReplansWithSameSplit = 3
    /// The pair's API on every address (local only, or Both), on a Mac that is not rank 0: its own port passed to rank
    /// 0's API (`ClusterLocalRelay`).
    private var relay: ClusterLocalRelay?
    /// Rank 0's API port as the other Mac's status last said it, and when it was asked (a thread of its own).
    private var relayTargetPort: Int?
    /// What this Mac's relay waits on, as `status()` publishes it (`relayStatus`); tests set it.
    var relayState = RelayState()
    /// The last reason this Mac's own port couldn't be read (`thisMacPort`), said once.
    private var portProblem: String?
    static let relayRetrySeconds: Double = 10
    /// How long the other Mac may go unheard over the cable (two missed lease renewals) before this Mac's relay answers
    /// that it can't be reached (`relayAway`).
    static let otherMacSilentSeconds: Double = 12

    /// What this Mac's relay waits on: set by `relayTick` and `askRankZeroPort`.
    struct RelayState: Equatable {
        /// Rank 0's cable address while this Mac would relay the pair's API (`ClusterLocalRelay.rankZeroHost`); nil
        /// otherwise.
        var host: String?
        /// Rank 0's last status said it answers on its own Mac only (`ClusterLocalRelay.rankZeroAnswersOnItsMacOnly`).
        var waitsForOffer = false
        /// A relay that couldn't listen on this Mac's port, which another program holds: for which target, on which port,
        /// and when it is tried again (`relayRetrySeconds`), so this Mac's port is never read on every tick.
        var held: Held?
        /// Asks of rank 0's Mac that failed in a row (`askRankZeroPort`).
        var askFailures = 0
        /// Rank 0's Mac is away (`relayAway`): the relay answers each request a 503 that says so.
        var away = false

        struct Held: Equatable {
            var target: ClusterLocalRelay.Target
            var port: Int
            var retryAt: Date
        }
    }

    /// What `status()` says of this Mac's relay, only while this Mac would relay: the port another program holds, rank
    /// 0 answering on its own Mac only, and rank 0's Mac away.
    static func relayStatus(_ state: RelayState) -> (portHeld: Int?, waitsForOffer: Bool?, away: Bool?) {
        guard state.host != nil else { return (nil, nil, nil) }
        return (state.held?.port, state.waitsForOffer ? true : nil, state.away ? true : nil)
    }

    /// Whether rank 0's Mac is away for this Mac's relay: an ask of it failed (`askFailures`), or it hasn't answered over
    /// the cable (`otherAnsweredAt`, `ClusterControlNode`) for `otherMacSilentSeconds`.
    static func relayAway(askFailures: Int, otherAnsweredAt: Double?, now: Double) -> Bool {
        askFailures > 0 || otherAnsweredAt.map { now - $0 >= otherMacSilentSeconds } == true
    }
    private var relayAsked = Date.distantPast
    private var relayAsking = false
    /// Seconds before the next ask: 10 while the other Mac answers, longer (to 120) while it does not, so the link's
    /// one-at-a-time request lock is not held for the other commands.
    private var relayAskInterval: Double = 10
    /// When each listener last checked its cable port and its pairing (`listenerChange`).
    var responderCheck = Date.distantPast
    var controlCheck = Date.distantPast
    let listening: Listening
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

    /// Internal composition of the service's existing stores. Public callers keep the canonical user namespace,
    /// the normal recovery deadline, the one-second supervision interval, the cable's listeners and the power
    /// assertions' name.
    init(settings: Settings, paths: ClusterUserPaths, recoveryGraceSeconds: Double = 300,
         supervisionIntervalSeconds: Double = 1, beforePartStart: (@Sendable () -> Void)? = nil,
         environment: [String: String]? = nil, listening: Listening = .init(),
         powerAssertionReason: String = ClusterServicePowerAssertions.servingReason) {
        precondition(recoveryGraceSeconds.isFinite && recoveryGraceSeconds >= 0)
        precondition(supervisionIntervalSeconds.isFinite && supervisionIntervalSeconds > 0)
        self.recoveryGraceSeconds = recoveryGraceSeconds
        self.supervisionIntervalSeconds = supervisionIntervalSeconds
        self.beforePartStart = beforePartStart
        self.environment = environment
        self.listening = listening
        self.powerAssertionReason = powerAssertionReason
        pairingStore = .default(home: paths.homeDirectory, environment: paths.environment)
        // This home's provider instance lock (`ProcessLifecycle.defaultPIDFile`'s, unless DARKBLOOM_PID_FILE moves it).
        providerInstanceLock = (ProcessInfo.processInfo.environment["DARKBLOOM_PID_FILE"].map { URL(fileURLWithPath: $0) }
            ?? paths.installDirectory.appendingPathComponent("provider.pid"))
            .appendingPathExtension("lock")
        var wizard = settings.wizard
        wizard.derivedPlacement = true
        wizard.answersOverLink = false
        self.settings = Settings(wizard: wizard, leaderArguments: settings.leaderArguments, followerArguments: settings.followerArguments,
            soloArguments: settings.soloArguments, memberArguments: settings.memberArguments)
        store = ClusterSetupStore(paths: .init(paths: paths))
        context = LiveContext(paths: paths, store: store, settings: wizard,
            clean: ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path))
        productionServes = paths.machineDeviceLock.otherHolder
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

    /// Holds this home's service lock, so no cluster service starts here until the hold is released (a start fails as
    /// "already running", and its login agent retries). Nil when a service holds the lock; throws when the lock
    /// cannot be opened. `darkbloom update --rollback` holds it across its swap, so this Mac cannot join a pair while
    /// its release changes.
    public static func holdStopped(operation: String) throws -> UpdateProcessLock? {
        try holdStopped(operation: operation, lockFile: try paths().lock)
    }

    static func holdStopped(operation: String, lockFile: URL) throws -> UpdateProcessLock? {
        try ClusterConfigurationFiles.ensureDirectory(lockFile.deletingLastPathComponent(), create: true, privateMode: true)
        return try UpdateProcessLock.attempt(at: lockFile, operation: operation).lock
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
                throw ClusterOnboardingFailure("this Mac's cluster service stopped at start; its log is \(ClusterUserPaths.serviceLogShown)")
            }
            usleep(50_000)
        }
        throw ClusterOnboardingFailure("this Mac's cluster service did not start within 5 s")
    }

    // MARK: - Running

    /// Runs until `stop` is signalled; returns false when a rank had to be left running.
    public func run(stop: DispatchSemaphore, say: @escaping @Sendable (String) -> Void) throws -> Bool {
        let power = ClusterServicePowerAssertions(reason: powerAssertionReason)
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
        // Makes macOS ask once about Darkbloom's Local Network access now: the onboarding starts this service right
        // after pairing, while the person is at this Mac, and waits for the answer (`ClusterLocalNetworkAccess`).
        // Only the service of this Mac's own home probes: one run on other paths (a test's) neither sends on the cable
        // nor writes the report the onboarding reads.
        if (try? Self.paths())?.pid == files.pid {
            ClusterLocalNetworkAccess.startServiceProbe(directory: store.paths.directory, say: say)
        }
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
            if ticker.wait(timeout: .now() + supervisionIntervalSeconds) == .success { stopped = true }
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

    /// Where this service's two listeners answer: the cable's interface, on the exchange's and the control lease's own
    /// ports. The checks put them on loopback, on ports of their own.
    struct Listening: Sendable {
        var exchangePort = ClusterSetupLinkExchange.port
        var controlPort = ClusterSetupLinkExchange.controlPort
        var policy = ClusterLinkInterfacePolicy.thunderboltOnly
        /// Nil: the cable's interface on this Mac, read at each use (`LiveContext.linkSelection`).
        var selection: ClusterLinkInterfaceSelection?
    }

    func listenerSelection() throws -> ClusterLinkInterfaceSelection {
        try listening.selection ?? context.linkSelection()
    }

    /// How often a listener checks that it still reaches the paired Mac: a cable moved to another Thunderbolt port (or a
    /// port whose address changed) leaves it on the old one, where the other Mac never reaches it, and a pairing made
    /// since it started leaves it keyed with the old one, so it refuses the other Mac's every connection (2026-10-31).
    static let listenerCheckSeconds: Double = 5

    /// What leaves a running listener unable to answer the paired Mac.
    enum ListenerChange {
        /// The cable is on another port, or its port has another address, now.
        case cableMoved(ClusterLinkInterfaceSelection)
        /// The pairing this Mac uses now is another one (`darkbloom cluster` or `darkbloom cluster pair` paired it
        /// again).
        case pairingChanged(ClusterSetupLinkExchange.Pairing.Identity)
        /// This Mac holds no pairing now.
        case unpaired
    }

    /// What changed since `listener` started (checked at most every `listenerCheckSeconds` per listener, `checked`); nil
    /// when nothing did, or there is no listener. A cable or pairing store that cannot be read now changes nothing.
    func listenerChange(of listener: ClusterSetupLinkExchange.Responder?,
                        checked: ReferenceWritableKeyPath<ClusterService, Date>) -> ListenerChange? {
        guard let listener else { return nil }
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(self[keyPath: checked]) >= Self.listenerCheckSeconds else { return false }
            self[keyPath: checked] = Date()
            return true
        }
        guard due else { return nil }
        if let current = try? listenerSelection(), ClusterSetupLinkExchange.cableMoved(bound: listener.selection, current: current) {
            return .cableMoved(current)
        }
        let pairing: ClusterSetupLinkExchange.Pairing?
        do { pairing = try ClusterSetupLinkExchange.pairing(store: pairingStore) } catch { return nil }
        guard let identity = pairing?.identity else { return .unpaired }
        return identity == listener.pairing ? nil : .pairingChanged(identity)
    }

    func ensureResponder(say: @escaping @Sendable (String) -> Void) {
        if let change = listenerChange(of: lock.withLock({ responder }), checked: \.responderCheck) {
            lock.withLock { responder }?.stop()
            lock.withLock { responder = nil }
            switch change {
            case .cableMoved(let moved):
                say("the cable is on \(moved.interface) now: answering the paired Mac there")
                // A port that was never set up has no fixed address: the other Mac cannot find this one there.
                if let port = OnboardingLive.unsetCablePort(ClusterLinkReadinessProbe.inspectLocalLink()) {
                    say("\(port) is not set up for the cluster: run `\(OnboardingLive.cli) cluster` on this Mac and choose \(ClusterOnboardingDriver.fixPortItem) (macOS asks for your password once)")
                }
            case .pairingChanged(let current):
                say("this Mac's pairing changed (\(current.clusterID)): answering the paired Mac with the new one")
            case .unpaired:
                say("this Mac is no longer paired: it stopped answering over the cable")
            }
        }
        guard lock.withLock({ responder == nil }), let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore),
              let selection = try? listenerSelection() else { return }
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
            let created = try ClusterSetupLinkExchange.Responder(pairing: pairing, selection: selection,
                port: listening.exchangePort, policy: listening.policy, answer: {
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

    /// The memory re-plan's steps (`replanForMemory`), as the control leader's onboarding operations run them
    /// (`controlLive`); tests stand in.
    struct MemoryReplan {
        var reachMembers: () -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>
        var planModels: () -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure>
        var adopt: (Int) -> Result<[String], ClusterOnboardingFailure>
        var serve: () -> Result<[String], ClusterOnboardingFailure>
        /// Puts the pair's saved start back (`ClusterService.restoreStart`).
        var restoreStart: () -> Void
    }

    func noteMemoryRefusal(key: String, since: Date, model: String, say: @escaping @Sendable (String) -> Void) {
        let log = ClusterIncidentLog.forThisInstall(homeDirectory: context.paths.homeDirectory)
        let refused = log.feed().incidents.contains { $0.ts >= since.timeIntervalSince1970 && $0.guidanceCode == "memory_gate_refused" }
        let due = lock.withLock { () -> Bool in
            guard refused else { memoryRefusals = nil; return false }
            let count = (memoryRefusals?.key == key ? memoryRefusals!.count : 0) + 1
            memoryRefusals = (key, count)
            guard count >= Self.memoryRefusalsBeforeReplan, !memoryReplanInFlight, !stopping, Date().timeIntervalSince(nextMemoryReplan) >= 0,
                  sameSplitReplans < Self.memoryReplansWithSameSplit, control?.leads == true else { return false }
            memoryReplanInFlight = true
            nextMemoryReplan = Date().addingTimeInterval(Self.memoryReplanSeconds)
            return true
        }
        guard due else { return }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.memoryReplanInFlight = false; self.memoryRefusals = nil } }
            self.replanForMemory(model: model, say: say)
        }
    }

    /// `noteMemoryRefusal`'s re-plan of `model` on the memory now, on a thread of its own: it holds the command lock so a
    /// person's command and this never run at once.
    func replanForMemory(model: String, say: @escaping @Sendable (String) -> Void) {
        // It comes due when a part ends, so also right after the owner's `darkbloom stop`, which holds the command
        // lock: its `localServe` would start that pair again. A hand-over may have finished meanwhile too.
        guard let held = commandLockIfStillStarted() else {
            // The owner stopped the pair: this re-plan did nothing, so its slot is given back, and a start of theirs
            // within the 10 minutes is re-planned at its next refusals instead of being refused until the slot passes.
            if (try? store.readRecord())?.leadership?.serving != true { lock.withLock { nextMemoryReplan = .distantPast } }
            return
        }
        defer { held.release() }
        say("a Mac's memory no longer holds its share of \(model) (refused at load twice): planning again on the memory now")
        let before = try? context.savedConfiguration().reference.get()?.sha256
        let live = controlLive
        let steps = memoryReplan ?? .init(reachMembers: { live.localReachMembers({ _ in }) }, planModels: { live.localPlanModels() },
                                          adopt: { live.localAdopt($0) }, serve: { live.localServe() },
                                          restoreStart: { self.restoreStart() })
        func failed(_ lines: [String]) { say("could not plan \(model) again: " + lines.joined(separator: " ")) }
        if case .failure(let failure) = steps.reachMembers() { return failed(failure.lines) }
        let choices: [ClusterOnboardingModelChoice]
        switch steps.planModels() {
        case .success(let value): choices = value
        case .failure(let failure): return failed(failure.lines)
        }
        guard let index = ClusterOnboardingUpdate.servableIndex(of: model, in: choices) else {
            return failed(["\(model) does not fit these Macs' memory now: \(choices.first { ($0.modelID ?? $0.title) == model }?.blocker ?? "not offered")"])
        }
        // On a serving pair `localAdopt` stops both parts first, and that stop clears the saved start. From there every
        // failure, the stop's own included, puts it back (`restoreStart`), so the pair serves as before and the next
        // refusals bring the next re-plan. Always before `held` is let go: every stop of the pair takes this lock, so an
        // owner's stop can't land just before the restore and be undone.
        func restored(_ lines: [String]) {
            steps.restoreStart()
            failed(lines + ["The pair stays started."])
        }
        if case .failure(let failure) = steps.adopt(index) { return restored(failure.lines) }
        if case .failure(let failure) = steps.serve() { return restored(failure.lines) }
        let after = try? context.savedConfiguration().reference.get()?.sha256
        lock.withLock { sameSplitReplans = before == after ? sameSplitReplans + 1 : 0 }
        // `localAdopt` stops the serving parts and plans once more when their memory is back, so the split adopted
        // need not be `choices[index]` (planned while they ran): it is said from the setup the start recorded.
        let deployment = (try? store.readRecord())?.leadership?.deployment
        say(before == after ? "planned \(model) again: the same split is still the one that fits; trying it again"
                            : "planned \(model) again on the memory now: a new split is starting on both Macs" + (deployment.map { " (\($0))" } ?? ""))
    }

    /// Local only or Both, me first, with the API on every address, on each Mac whose part is not rank 0: this Mac's own
    /// port (`thisMacPort`, its saved `[local] port`) passes each connection over the cable to rank 0's API
    /// (`ClusterLocalRelay.rankZeroHost`, `port(own:for:scope:isFree:)`), so the pair answers on every Mac, each at its own
    /// address whichever Mac the plan made rank 0. Tools here use this Mac's own key, which the relay passes on as the
    /// pair's (`ClusterLocalRelay.Keys`). This Mac's port is read only when a relay starts: a port another program holds
    /// is said once and tried again every `relayRetrySeconds`. Stopped whenever this Mac's part is not running or is rank
    /// 0, before rank 0 here takes the port.
    private func relayTick(say: @escaping @Sendable (String) -> Void) {
        let leadership = (try? store.readRecord())?.leadership
        let saved = context.savedConfiguration().configuration
        let partRuns = lock.withLock { child?.isRunning == true && childSetup?.hasPrefix("solo:") != true }
        var wanted: ClusterLocalRelay.Target?
        let host = leadership.flatMap { leadership in saved.flatMap { saved in
            ClusterLocalRelay.rankZeroHost(serving: leadership.serving, scope: leadership.scope, memberID: saved.memberID,
                                           roster: saved.peers.map { .init(id: $0.id, rank: $0.rank, host: $0.host) }, partRuns: partRuns)
        } }
        // Rank 0's Mac away (a failed ask, or silent over the cable): the relay answers each request a 503 that says so.
        // Once that Mac answers over the cable again, asks go back to every 10 s (from up to 120 s), so relaying resumes
        // within about 10 s, without asking on every tick.
        let now = Self.monotonicSeconds()
        let (away, words) = lock.withLock { () -> (Bool, ClusterLocalRelay.Refusals) in
            relayState.host = host
            let answered = control?.otherAnsweredAt
            if host != nil, relayState.askFailures > 0, let answered, now - answered < Self.otherMacSilentSeconds {
                relayAskInterval = 10
            }
            relayState.away = host != nil && Self.relayAway(askFailures: relayState.askFailures, otherAnsweredAt: answered, now: now)
            return (relayState.away, .pair(otherMac: otherMacNameLocked(), cli: BuildEnvironment.current.cliName))
        }
        if let host {
            askRankZeroPort()
            if let port = lock.withLock({ relayTargetPort }) { wanted = .init(host: host, port: port) }
        }
        let current = lock.withLock { relay }
        if let current, current.target == wanted, !current.isStopped {
            current.setRefusals(words)
            current.setAway(away)
            return
        }
        if let current {
            current.stop()
            lock.withLock { relay = nil }
            LocalEndpoint.removeInfo(ifPID: getpid())
            say("stopped passing this Mac's port \(current.port) to the API on the other Mac")
        }
        guard let wanted, let scope = leadership?.scope,
              let keys = try? ClusterLocalRelay.Keys(own: LocalEndpoint.loadOrCreateToken(), pair: LocalEndpoint.loadOrCreateClusterToken())
        else { lock.withLock { relayState.held = nil }; return }
        let due = lock.withLock { () -> Bool in
            guard let held = relayState.held, held.target == wanted else { return true }
            return Date().timeIntervalSince(held.retryAt) >= 0
        }
        guard due, let started = startRelay(to: wanted, scope: scope, keys: keys, say: say) else { return }
        started.setAway(away)
        lock.withLock { relay = started; apiPort = started.port }
        // The discovery file only when no other live server on this Mac owns it (`darkbloom start --local`).
        if LocalEndpoint.readLiveInfo().map({ $0.pid == getpid() }) ?? true {
            try? LocalEndpoint.writeInfo(Self.relayDiscovery(port: started.port, keys: keys))
        }
        say("the pair's API answers on this Mac's own port \(started.port) too, passed over the cable to port \(wanted.port) on the other Mac (rank 0)")
    }

    /// This Mac's relay to `wanted`, on this Mac's own port (`thisMacPort`, read only here, when a relay starts; else the
    /// earlier rule). Nil when another program holds that port: said once per port, and tried again every
    /// `relayRetrySeconds` (`relayState.held`).
    func startRelay(to wanted: ClusterLocalRelay.Target, scope: ClusterServingScope, keys: ClusterLocalRelay.Keys,
                    say: @Sendable (String) -> Void) -> ClusterLocalRelay? {
        let port = ClusterLocalRelay.port(own: thisMacPort(say: say), for: wanted, scope: scope)
        let words = lock.withLock { ClusterLocalRelay.Refusals.pair(otherMac: otherMacNameLocked(), cli: BuildEnvironment.current.cliName) }
        guard let started = ClusterLocalRelay(port: port, target: wanted, keys: keys, refusals: words) else {
            let first = lock.withLock { () -> Bool in
                defer { relayState.held = .init(target: wanted, port: port, retryAt: Date().addingTimeInterval(Self.relayRetrySeconds)) }
                return relayState.held.map { $0.target != wanted || $0.port != port } ?? true
            }
            if first {
                say("this Mac's port \(port) is held by another program, so the pair's API doesn't answer on this Mac: free it, "
                    + "or set another [local] port in \(settings.wizard.providerConfiguration.path), then `\(BuildEnvironment.current.cliName) restart`; "
                    + "trying again every \(Int(Self.relayRetrySeconds)) s")
            }
            return nil
        }
        lock.withLock { relayState.held = nil }
        return started
    }

    /// This Mac's own port for the pair's API or relay (`ownAPIPort`), saying one newly saved; nil when it can't be read
    /// or chosen (the earlier rules then), said once per reason.
    private func thisMacPort(say: @Sendable (String) -> Void) -> Int? {
        let path = settings.wizard.providerConfiguration
        do {
            let choice = try Self.ownAPIPort(configPath: path)
            lock.withLock { portProblem = nil }
            if let note = choice.note { say(note) }
            return Int(choice.port)
        } catch {
            let line = "this Mac's local API port can't be read from \(path.path) (\(error)): the pair's API or relay here takes a free port"
            if lock.withLock({ () -> Bool in defer { portProblem = line }; return portProblem != line }) { say(line) }
            return nil
        }
    }

    /// The discovery record this Mac's relay writes for its tools (`darkbloom local`, `start --opencode`): its port on
    /// every address, and this Mac's own key, which the relay passes on as the pair's.
    public static func relayDiscovery(port: Int, keys: ClusterLocalRelay.Keys) -> LocalEndpoint.Info {
        LocalEndpoint.Info(host: ClusterServingScope.localOnlyDefaultBind, port: UInt16(port), apiKey: keys.own,
                           version: ProviderCore.version, pid: getpid(), updatedAt: ISO8601DateFormatter().string(from: Date()))
    }

    /// This Mac's one local API port, which the pair's API or relay on this Mac takes as every local API here does
    /// (`LocalAPIPort.thisMac`, from the provider config at `configPath`): the saved `[local] port` as it is, else the
    /// one this Mac's local API already uses, else a new choice, saved there. Throws without a provider config (the
    /// service writes none), when the config can't be read, and when no port is free for a new choice.
    static func ownAPIPort(configPath: URL, ownLivePort: () -> UInt16? = LocalAPIPort.ownLivePort,
                           installedPort: () -> UInt16? = LocalAPIPort.installedJobPort,
                           isFree: (UInt16) -> Bool = LocalAPIPort.isFreeOnThisMac) throws -> LocalAPIPort.Choice {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: configPath.path])
        }
        return try LocalAPIPort.thisMac(configPath: configPath, fallbackConfig: ConfigManager.load(from: configPath),
                                        ownLivePort: ownLivePort, installedPort: installedPort, isFree: isFree)
    }

    /// This Mac is rank 0 now: its relay gives the port back first.
    private func handRelayPortBack() {
        guard let passing = lock.withLock({ () -> ClusterLocalRelay? in defer { relay = nil }; return relay }) else { return }
        passing.stop()
        LocalEndpoint.removeInfo(ifPID: getpid())
    }

    /// Where the pair's API listens on every address of this Mac, for the other Macs' relays: its part's discovery
    /// record (written once that part's API is bound). Nil while there is none, for a solo server, and for an API on
    /// loopback or one address.
    private func pairAPIPort() -> Int? {
        let part = lock.withLock { child?.isRunning == true && childSetup?.hasPrefix("cluster:") == true ? child?.processIdentifier : nil }
        return ClusterLocalRelay.pairAPIPort(part: part, record: LocalEndpoint.readLiveInfo().map { ($0.pid, $0.host, $0.port) })
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
                self?.lock.withLock {
                    guard let self else { return }
                    self.relayAskInterval = min(self.relayAskInterval * 2, 120)
                    self.relayState.askFailures += 1
                }
                return
            }
            let port = ClusterLocalRelay.rankZeroPort(in: status), ownMacOnly = ClusterLocalRelay.rankZeroAnswersOnItsMacOnly(in: status)
            self?.lock.withLock {
                guard let self else { return }
                self.relayTargetPort = port; self.relayState.waitsForOffer = ownMacOnly; self.relayAskInterval = 10
                self.relayState.askFailures = 0
            }
        }
    }

    /// The ports this Mac reports free: those no program listens on, and those its own API, relay or solo server holds
    /// (given back when the other Mac becomes rank 0 or the pair re-forms). An older build's rank 0 reads them to take a
    /// port free on both Macs; this build's takes its own.
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
            guard !syncing, !stopping, Date().timeIntervalSince(nextSync) >= 0 else { return false }
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
            // A Mac that doesn't answer holds nothing back: the control leadership handles its absence.
            self?.lock.withLock { self?.peerHeldBack = member.flatMap(ClusterService.heldBack(of:)) }
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
                                                leaderLocalOnly: leadership.scope.isLocalOnly, memberLocalOnly: member?.localOnly,
                                                leaderLocalAPI: leadership.scope.addsLocalAPI, memberLocalAPI: member?.localAPI) {
            case .none: return
            case .serve(let model):
                let runsIt = member?.serving == true && member?.modelName == model
                var serve = ClusterServiceCommand(op: .serve, model: model, deployment: leadership.deployment, scope: leadership.scope)
                if leadership.scope.localAPIBind != nil { serve.localToken = try? LocalEndpoint.loadOrCreateClusterToken() }
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
            value.pairAPIPort = pairAPIPort()
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
        case .stopSolo:
            // The person chose on the other Mac's screen to stop single-Mac serving on both Macs: it blocks the pair.
            guard ProviderInstanceHolder.current(lockFile: providerInstanceLock)?.kind == .singleMac else { return try encoder.encode(status()) }
            if case .failure(let failure) = Self.stopSoloServing(executable: settings.wizard.darkbloomExecutable) { throw failure }
            say("stopped single-Mac serving on this Mac, as the other Mac's screen asked")
            ClusterSoloChoice.clear(in: store.paths.directory)
            blockerCleared(say: say)
            lock.withLock { nextStart = .distantPast; backoff = 3 }
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

    /// Degraded serving alone listens on this Mac's own saved port (`thisMacPort`), as every local API here does; only
    /// when that can't be read, where `start --local` listened by default.
    public static let defaultSoloPort = 8000

    /// The port the solo server in `status` listens on (its published part's), for the screens that check it.
    public static func soloPort(of status: ClusterServiceStatus?) -> Int {
        guard status?.child.solo == true, let port = status?.child.port else { return defaultSoloPort }
        return port
    }

    /// What the solo port shows: THIS service's solo server (the published solo child, checked by its start time so a
    /// recycled process number never counts, or a process it started) holding the listening socket and answering its
    /// model list; that server still loading; or another program answering there (never taken for ours).
    public enum SoloReadiness: Equatable { case ready, loading, foreign }

    static func soloReadiness(_ status: ClusterServiceStatus?, port given: Int? = nil) -> SoloReadiness {
        let port = given ?? soloPort(of: status)
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
            if status == nil, FileManager.default.fileExists(atPath: directory.appendingPathComponent(ClusterServiceStatus.fileName).path) {
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
            if Date().timeIntervalSince(deadline) >= 0 { return false }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// `authorized`: whether a server answers its model list on the solo port with this Mac's local API token (only
    /// ever sent to this service's own solo server: see `soloReadiness`); otherwise whether anything answers HTTP there,
    /// asked without the token.
    static func soloAnswers(port: Int = defaultSoloPort, authorized: Bool = true) -> Bool {
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
            let reason = (error as? ClusterSetupFailure)?.text ?? String(describing: error)
            return "The other Mac was not reached (\(ClusterConsoleText.bounded(reason, maximum: 160))): "
                + "its pair cache stays until it unpairs too (`\(OnboardingLive.cli) cluster pair --forget \(pairing.localPin)` there)."
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
                ranks: max(live.members.count, configuration?.peers.count ?? 2), port: live.port, detail: live.detail ?? live.sessionPhase,
                readyRankList: live.members.filter(\.ready).map(\.rank))
        }
        // Single-Mac serving on this Mac, read now whether or not a part is wanted yet: the other Mac's start reads it before
        // it starts anything (0.10.9 DevNet f1: it was reported only once this Mac wanted to start its part, so the leading
        // Mac started first and its part kept ending). Never while this Mac's own part holds the lock.
        let ownPartRuns = lock.withLock { child?.isRunning == true } || oldPart != nil
        let soloNow = ownPartRuns ? nil
            : ProviderInstanceHolder.current(lockFile: providerInstanceLock).flatMap { $0.kind == .singleMac ? $0 : nil }
        return lock.withLock {
            let reference = try? saved.reference.get()
            let wait = nextStart.timeIntervalSinceNow
            var value = ClusterServiceStatus(role: record?.leadership?.role, serving: record?.leadership?.serving ?? false,
                modelName: record?.leadership?.modelName, sessionLeader: leads, localRank: configuration?.localRank,
                setup: reference.map { String($0.sha256.prefix(12)) },
                child: .init(running: child?.isRunning == true || oldPart != nil, starts: starts, lastEnd: lastEnd,
                    restartInSeconds: child == nil && oldPart == nil && wait > 0 ? Int(wait.rounded(.up)) : nil,
                    // A running part says only a refusal its follower got (it keeps retrying, P2-1); an ended one its error.
                    lastError: soloNow != nil ? Self.soloServingError(soloNow!)
                        : child?.isRunning == true
                        ? Self.runningPartRefusal(linkFollower: childIsLinkFollower, in: serviceFiles.rankLog, from: childLogOffset,
                                                  remembered: &followerRefusalRead)
                        : Self.lastError(in: serviceFiles.rankLog, from: childLogOffset),
                    pid: child?.isRunning == true ? child?.processIdentifier : oldPart?.pid,
                    startedAt: child?.isRunning == true ? childStartedAt : oldPart?.startedAt, lastRunSeconds: lastRunSeconds,
                    solo: child?.isRunning == true ? childSetup?.hasPrefix("solo:") == true : oldPart?.solo,
                    port: child?.isRunning == true ? childPort : nil,
                    notice: oldPart != nil ? "the previous run's part is still releasing; waiting before starting another"
                        : child?.isRunning == true && childSetup?.hasPrefix("solo:") != true ? Self.servingNotice(in: serviceFiles.rankLog, from: childLogOffset) : nil,
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
            value.localAPI = record?.leadership.map { $0.scope.addsLocalAPI }
            value.loggedIn = AuthTokenStore.load() != nil
            value.startsAtLogin = ClusterServiceAgent.startsAtLogin(environment: ProcessInfo.processInfo.environment,
                                                                    installedAgents: { ClusterServiceAgent.installedLabels() })
            if child?.isRunning == true, childIsMember {
                value.child.pair = Self.pairReport(in: serviceFiles.rankLog, from: childLogOffset).map(ClusterOnboardingPairReport.text)
                let state = DaemonStateFile.read()
                value.child.appAttest = Self.memberAppAttest(pid: child?.processIdentifier, state: state)
                value.child.appAttestRetryAt = Self.memberAppAttestRetryAt(pid: child?.processIdentifier, state: state)
            }
            value.soloServing = soloNow.map { .init(pid: $0.pid) }
            value.heldBack = soloNow.map(Self.soloServingError) ?? otherAppHolds
            value.pairRunning = value.serving && pairVerdict.running
            value.pairNotRunning = value.serving ? ClusterPairWatch.line(pairVerdict, otherMac: otherMacNameLocked(),
                                                                         cli: BuildEnvironment.current.cliName) : nil
            (value.relayPortHeld, value.relayWaitsForOffer, value.relayRankZeroAway) = Self.relayStatus(relayState)
            value.memberQuickEnds = memberQuickEnds
            value.approvalID = configuration?.nativeMember?.clusterApproval?.id ?? ""
            value.pairUpdate = ClusterPairUpdate.readProgress(from: ClusterServiceAgent.updateProgressPath(serviceDirectory: store.paths.directory))
            return value
        }
    }

    /// The other Mac's version for the wait lines: asked over the cable at most every 30 s, off the caller's thread unless
    /// `refresh` (already a background thread); the last answer meanwhile, nil before the first.
    private func otherMacVersion(refresh: Bool = false) -> String? {
        let ask: Bool = lock.withLock {
            guard !otherVersionAsking, Date().timeIntervalSince(otherVersionAsked) >= 30 else { return false }
            otherVersionAsking = true
            otherVersionAsked = Date()
            return true
        }
        if ask {
            let read: @Sendable () -> Void = { [weak self] in
                var version: String?
                if case .reported(let progress) = ClusterPairUpdateCycle.livePartner(.init()) { version = progress.running }
                self?.lock.withLock { self?.otherVersion = version ?? self?.otherVersion; self?.otherVersionAsking = false }
            }
            if refresh { read() } else { Thread.detachNewThread(read) }
        }
        return lock.withLock { otherVersion }
    }

    /// On the control leader, while the cluster serves: when a Darkbloom update changed a Mac's worker (its digest no
    /// longer matches the saved setup's pin, so both Macs refuse their parts), the same model is planned again,
    /// adopted, synced to the member and served, as `m` with the same model would, with nobody running a command.
    /// Checked every `ClusterOnboardingUpdate.checkEverySeconds` on a thread of its own (every `recheckWhileWaitingSeconds`
    /// while the Macs run different builds, `retryAfterFailureSeconds` after a failure); holds the command lock so a
    /// person's command and this never run at once.
    private func checkForUpdate(say: @escaping @Sendable (String) -> Void) {
        // Only on a claim the other Mac confirmed: the Macs restart into an update seconds apart, and the one back first
        // may take control meanwhile, so a restarted leader's saved claim may be superseded (and its stop refused).
        guard let leadership = (try? store.readRecord())?.leadership, leadership.serving, let model = leadership.modelName,
              leadershipConfirmed() else { return }
        let begin: Bool = lock.withLock {
            guard !updateInFlight, !stopping, Date().timeIntervalSince(nextUpdateCheck) >= 0 else { return false }
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
            let standIn = self.updateReplan
            var current: [String: String?] = [local.id: try? context.workerSHA256(local.workerExecutable)]
            if let standIn {
                current = standIn.running()
            } else if case .reached = context.reachPeer(), let facts = context.peerFacts {
                current[facts.memberID] = facts.runtimeBinarySHA256
            }
            let changed = ClusterOnboardingUpdate.changed(pinned: pinned, current: current)
            guard !changed.isEmpty else { return }
            let macs = changed.count == 1 && changed[0] == local.id ? "this Mac" : changed.count == 1 ? "the other Mac" : "both Macs"
            // The two Macs restart into an update seconds apart, or one was updated alone: plan once both run one build.
            guard ClusterOnboardingUpdate.oneBuild(pinned: pinned, current: current) else {
                let line = ClusterOnboardingUpdate.leaderWaitLine(macs: macs, model: model, thisVersion: ProviderCore.version,
                                                                  otherVersion: self.otherMacVersion(refresh: true))
                if self.lock.withLock({ self.updateWaitLine != line }) {
                    self.lock.withLock { self.updateWaitLine = line }
                    say(line)
                }
                self.lock.withLock {
                    self.nextUpdateCheck = Date().addingTimeInterval(ClusterOnboardingUpdate.recheckWhileWaitingSeconds)
                }
                return
            }
            self.lock.withLock { self.updateWaitLine = nil }
            // Held, the command lock keeps a hand-over and a person's stop off; either may have finished while the builds
            // were compared, and the re-plan's stop would put back a start the person cleared.
            guard let held = self.commandLockIfStillStarted() else { return }
            defer { held.release() }
            self.lock.withLock { self.updatingLine = ClusterOnboardingUpdate.statusLine }
            self.publish()
            say("Darkbloom changed on \(macs): setting the cluster up again for \(model)")
            let live = self.controlLive
            // The same model keeps the mode the pair served it in, unless the planner and the pair's own served
            // requests both find another faster (`ClusterServedModes.hold`). `localPlanModels` asks the other Mac for
            // its report again: the one `localReachMembers` took still counts its old part's memory.
            let keeping = saved.publicModelID == model ? [model: saved.selectedGenerationMode] : [:]
            let replanned = Self.replanAfterUpdate(model: model, standIn?.steps ?? .init(
                reachMembers: { live.localReachMembers({ _ in }) }, stop: { live.localStop() },
                awaitReleased: { live.awaitReleased() }, planModels: { live.localPlanModels(keeping: keeping) },
                adopt: { live.localAdopt($0) }, serve: { live.localServe() }, restoreStart: { self.restoreStart() }))
            let choice: ClusterOnboardingModelChoice
            switch replanned {
            case .success(let value): choice = value
            case .failure(let failure):
                // `replanAfterUpdate` kept the saved start: the next check tries again.
                say("could not set the cluster up again after the update: " + failure.lines.joined(separator: " ")
                    + " The pair stays started; this is tried again in \(Int(ClusterOnboardingUpdate.retryAfterFailureSeconds) / 60) minutes.")
                self.lock.withLock { self.nextUpdateCheck = Date().addingTimeInterval(ClusterOnboardingUpdate.retryAfterFailureSeconds) }
                return
            }
            // The plan's own line and its reason for the mode (tensor parallel or a pipeline), so the log says why.
            say("set the cluster up again after the update: \(model) is starting on both Macs ("
                + choice.lines.joined(separator: " ") + ")")
            // The re-adopted setups carry no cluster approval: the next check finds the same model approval again, or the
            // build-pinned entry of the updated app.
            self.lock.withLock { self.approvalChecked = false; self.nextApprovalCheck = .distantPast }
        }
    }

    /// On the control leader: asks the coordinator for its cluster approvals once per run of this service, and every
    /// `ClusterOnboardingUpdate.checkEverySeconds` while the pair is registered or serves locally with its approval set
    /// aside (`ClusterApprovalCheck.asks`). Only when a setup must change (`ClusterApprovalCheck.step`: an approval to
    /// save, or one to serve without because the coordinator gave no answer for the grace, no longer lists it, or the
    /// parts keep failing with it) it stops both parts, changes both Macs' setups and serves again; a change that would
    /// stop a serving pair waits while the other Mac doesn't answer its status. A coordinator that serves nothing new
    /// changes nothing and stops nothing. An approval that ended is removed by each Mac itself before its part starts
    /// (`supervise`), never by stopping a running pair.
    private func checkApproval(say: @escaping @Sendable (String) -> Void) {
        // Only on a claim the other Mac confirmed, as `checkForUpdate`: a change of approval stops the pair.
        guard leadershipConfirmed() else { return }
        let begin: Bool = lock.withLock {
            guard !approvalInFlight, !updateInFlight, !stopping, Date().timeIntervalSince(nextApprovalCheck) >= 0 else { return false }
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
                /// The saved setup's worker digest, recorded with an approval set aside.
                let worker: String
                /// The other Mac answered its status: every change of the approval sends to it.
                let peerAnswered: Bool
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
                return Decided(step: step, watch: watch, serving: record?.leadership?.serving == true,
                               worker: saved.capability.runtimeBinarySHA256, peerAnswered: peer != nil)
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
            guard let held = ClusterControlCommandLock.acquire(seconds: 5,
                file: self.store.paths.directory.appendingPathComponent("control.lock")) else {
                say("another cluster command is running: the cluster approval is checked again in a minute")
                return checked()
            }
            defer { held.release() }
            checked()
            // Confirmed and decided again under the lock, with the same answer: a hand-over, or a person's command that
            // changed the setup, the scope or the other Mac, may have finished while this check waited.
            guard self.leadershipConfirmed() else { return }
            guard let decided = decide(answer) else { return }
            self.lock.withLock { self.approvalWatch = decided.watch }
            let step = decided.step, serving = decided.serving
            guard step != .keep else { return }
            // A change can't succeed while the other Mac doesn't answer: one that stops a serving pair waits for it, or this
            // Mac's part would stop for nothing at every check.
            guard decided.peerAnswered || !serving else { return }
            let send: (ClusterServiceCommand) throws -> Void = { request in _ = try live.command(request, seconds: 180) }
            let result = ClusterApprovalSync.apply(step, grace: ClusterService.soloGraceSeconds, paths: paths,
                providerConfiguration: configuration, pairingStore: pairingStore, scratch: scratch, now: Date().timeIntervalSince1970,
                stop: {
                    Self.stopForApprovalChange(serving: serving, stop: { live.localStop() }, drained: { live.drained(seconds: 300) },
                                               restoreStart: { self.restoreStart() })
                },
                serve: {
                    if let line = Self.restartAfterApprovalChange(serving: serving, serve: { live.localServe() },
                                                                  restoreStart: { self.restoreStart() }) { say(line) }
                },
                sendToPeer: send)
            try? self.store.updateRecord { stored in
                if let note = result.note { stored.approvalNote = note }
                // The approval set aside is kept while the pair serves locally and dropped once one is saved again.
                if result.changed, let setAside = ClusterApprovalCheck.setAside(by: step, worker: decided.worker,
                                                                                now: Date().timeIntervalSince1970) {
                    stored.approvalSetAside = setAside
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
    /// The part's last error in `log` since `offset`, where it began: its last "Error:" line, or, when that is a generic
    /// cancellation (or there is none), the reason the part stopped serving, which it says first ("Distributed serving
    /// stops: <reason>."): the 0.10.8 candidate, 2026-11-04, showed "CancellationError()" where the part had said "the
    /// coordinator reported this member's runtime as outdated". `preferStopReason` false: the raw error line, for counts
    /// that read specific member errors (`ClusterApprovalCheck.memberQuickEnds`).
    static func lastError(in log: URL, from offset: UInt64 = 0, preferStopReason: Bool = true) -> String? {
        let error = lastErrorLine(in: log, from: offset)
        guard preferStopReason, error.map(isCancellation) ?? true else { return error }
        if let stop = ClusterLogScan.lastLine(in: log, from: offset, where: { $0.hasPrefix(stopReasonPrefix) }) {
            var reason = stop.dropFirst(stopReasonPrefix.count).trimmingCharacters(in: .whitespaces)
            if reason.hasSuffix(".") { reason.removeLast() }
            if !reason.isEmpty { return ClusterConsoleText.plain(ClusterConsoleText.bounded(reason, maximum: 240)) }
        }
        // A link follower macOS kept off the local network says so and ends cleanly: that is its reason (A-3), unless a
        // link it opened since says the dial worked (`followerRefusal`), so a planned stop after it is a clean stop.
        if error == nil, let refusal = followerRefusal(in: log, from: offset) { return refusal }
        return error
    }

    /// How a part's link follower says macOS kept it off the local network: `ClusterLinkFollowerCommand` writes this
    /// phrase, and `lastError` finds it. The part then ends cleanly, with no "Error:" line, and the Mac that leads only
    /// saw the other Mac not answering (the DevNet run, A-3).
    public static let localNetworkRefusal = "may not reach the local network"

    /// How a part's refusal reads in its Mac's status (`lastError`), which the other Mac's screens read.
    public static let localNetworkReasonPrefix = "its part can't reach the local network"

    /// The prefix of each line the link follower writes (`ClusterLinkFollowerCommand`), and the words after it that
    /// `followerRefusal` reads: once it has opened its link to the other Mac, and when a dial fails. The follower writes
    /// them from here, as it does `localNetworkRefusal`.
    public static let followerLinePrefix = "link-follower: "
    public static let followerConnected = "connected"
    public static let followerSessionOpened = "session opened"
    public static let followerLinkRefused = "link refused: "

    /// What the link follower writes once it has opened its link to the other Mac. A refusal before them no longer holds
    /// (`followerRefusal`), so turning Local Network on clears it.
    public static let followerLinkOpenedLines = [followerConnected, followerSessionOpened].map { followerLinePrefix + $0 }

    /// The app's own name: the build identity's `CFBundleName`. Every line that names the app reads it here: the
    /// screens (`ClusterOnboardingCommand.app`) and the follower's refusal.
    public static let appName = BuildEnvironment.current.appDisplayName

    /// The row System Settings → Privacy & Security → Local Network shows for this app: the production app's name in
    /// every build. Both apps share the bundle ID `io.darkbloom.provider`, so macOS lists the DevNet app as "Darkbloom",
    /// never by the DevNet display name (R4-4). A Mac where macOS never recorded an answer for the app lists no row at all.
    public static let localNetworkRow = BuildEnvironment.prod.appDisplayName

    /// What the link follower writes when a dial fails, before the refusal line for macOS's own refusal. A later one
    /// without that line says its last dial got further and failed another way (`followerRefusal`).
    public static let followerLinkRefusedLine = followerLinePrefix + followerLinkRefused

    /// A running part's `lastError`: only a link follower's refusal (another part never writes one, so its log isn't
    /// read), remembered by the log's size since the part started, so a status read with nothing new written reads
    /// nothing (the joining Mac's window asks every second; each read used to walk up to 8 MiB back under the lock).
    static func runningPartRefusal(linkFollower: Bool, in log: URL, from offset: UInt64, remembered: inout FollowerRefusalRead?,
                                   scan: (URL, UInt64) -> String? = { ClusterService.followerRefusal(in: $0, from: $1) }) -> String? {
        guard linkFollower else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if let read = remembered, read.offset == offset, read.size == size { return read.refusal }
        let refusal = scan(log, offset)
        remembered = .init(offset: offset, size: size, refusal: refusal)
        return refusal
    }

    /// What `runningPartRefusal` last read: the part's start in its log, the log's size then, and the refusal.
    struct FollowerRefusalRead: Equatable { var offset: UInt64; var size: UInt64; var refusal: String? }

    /// The reason the follower this service runs can't dial the other Mac now, from its log since it started: its last
    /// dial's outcome, the refusal macOS gave it ("this process may not reach the local network", P2-1, A-2), or a
    /// link it opened since ("connected", "session opened"), or a dial that failed another way since. The follower is
    /// the process that dials, so this is the truth the service's broadcast probe can't give; it keeps running and
    /// retrying, so it never ends with an error.
    static func followerRefusal(in log: URL, from offset: UInt64 = 0) -> String? {
        guard let last = ClusterLogScan.lastLine(in: log, from: offset, where: { line in
                  line.contains(localNetworkRefusal) || line.contains(followerLinkRefusedLine)
                      || followerLinkOpenedLines.contains { line.contains($0) }
              }), let at = last.range(of: localNetworkRefusal) else { return nil }
        return refusalReason(String(last[at.upperBound...]))
    }

    static func refusalReason(_ rest: String) -> String {
        var reason = localNetworkReasonPrefix + rest
        if reason.hasSuffix(".") { reason.removeLast() }
        return ClusterConsoleText.plain(ClusterConsoleText.bounded(reason, maximum: 300))
    }

    /// How a part says why it stops serving (`StartCommand+Distributed`, the member's stop reason).
    static let stopReasonPrefix = "Distributed serving stops: "

    /// A run that ended because it was cancelled, which says nothing of why.
    static func isCancellation(_ error: String) -> Bool { error.contains("CancellationError") }

    private static func lastErrorLine(in log: URL, from offset: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: log.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = size > 16_384 ? size - 16_384 : 0
        try? handle.seek(toOffset: offset <= size ? max(offset, window) : window)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let line = tail.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Error:") }) else { return nil }
        return ClusterConsoleText.plain(ClusterConsoleText.bounded(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces), maximum: 240))
    }

    /// The latest pair line (`ClusterOnboardingPairReport`) the running coordinator-paired part wrote in `log` since
    /// `offset`, where it began writing: a line an earlier part wrote is never this part's.
    /// The line is written once per change and every request adds a line after it, so it is read backwards from the end
    /// (`ClusterLogScan`), not from a fixed tail.
    static func pairReport(in log: URL, from offset: UInt64) -> ClusterOnboardingPairReport.State? {
        ClusterOnboardingPairReport.latest(inLogFile: log, from: offset)
    }

    /// Whether the coordinator's latest trust status for the running coordinator-paired part (`pid`, the process that
    /// wrote the daemon state) carries a current App Attest serving authorization; nil when it has sent none yet.
    static func memberAppAttest(pid: Int32?, state: DaemonState? = DaemonStateFile.read(), now: Double = Date().timeIntervalSince1970) -> Bool? {
        guard let pid, let state, state.pid == pid, let trust = state.trust else { return nil }
        return trust.authorization?.hasCurrentAppAttestAuthorization(now: now) ?? false
    }

    /// When the running coordinator-paired part (`pid`) may make a new App Attest key again: its local key-generation
    /// safeguard as its daemon state last reported it (read only); nil when nothing blocks it or nothing is known.
    static func memberAppAttestRetryAt(pid: Int32?, state: DaemonState?, now: Double = Date().timeIntervalSince1970) -> Double? {
        guard let pid, let state, state.pid == pid, let until = state.appAttest?.key?.generationBlockedUntil, until > now else { return nil }
        return until
    }

    /// `ClusterLocalServing.notice` when this Mac's running part (rank 0) said it serves on its local API only.
    public static func servingNotice() -> String? {
        (try? paths().rankLog).flatMap { servingNotice(in: $0) }
    }

    /// The same notice in `log` from `offset` on (where the running part began writing): a part writes it once its API
    /// listens and every request adds a line after it, so it is read backwards from the end (`ClusterLogScan`).
    static func servingNotice(in log: URL, from offset: UInt64 = 0) -> String? {
        ClusterLogScan.lastLine(in: log, from: offset) { $0.hasPrefix(ClusterLocalServing.logPrefix) }
            .flatMap { ClusterLocalServing.notice(inLog: String($0)) }
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
        let file = store.paths.directory.appendingPathComponent(ClusterServiceStatus.fileName)
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
                            // Under the service lock: one try; a busy record waits for the next tick.
                            record = try store.updateRecord(lockWaitSeconds: 0) {
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
        let file = directory.appendingPathComponent(ClusterServiceStatus.fileName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ClusterServiceStatus.self, from: data)
    }

    /// This Mac's cluster service runs and the pair is started (its record serves): this Mac's serving lock is the pair's.
    /// A single-Mac provider job left loaded on this Mac (an earlier `darkbloom start`, which meant single-Mac serving
    /// before 0.10.8) is then neither restarted by an update nor revived by the watchdog: it would take the lock the
    /// pair's part needs whenever the part lets it go (an update's restart), and the pair could never start again.
    /// The pair actually runs here (`ClusterPairWatch`), not only its saved intent: a Mac whose other Mac stopped taking
    /// part serves alone again. A service from before 0.10.9 publishes no verdict: its intent decides, as before.
    public static func pairServesHere() -> Bool { pairKeepsLock(publishedLive()) }

    /// Nothing automatic (an update's restart, the watchdog) gives this Mac's serving lock to single-Mac serving while
    /// the pair runs here, or while its other Mac answers: a pair that hasn't served yet may still be loading (a first
    /// load can outlast `ClusterPairWatch.giveUpSeconds`), and only the person (`start --solo`, the terminal's choice)
    /// stops it then.
    public static func pairKeepsLock(_ status: ClusterServiceStatus?) -> Bool {
        guard let status, status.serving else { return false }
        return pairRuns(status) || status.control.map { !otherMacAbsentModes.contains($0.mode) } == true
    }

    /// How `releaseForSingleMac` ended.
    public enum SingleMacRelease: Equatable, Sendable {
        /// This Mac's saved start is cleared, and its part stopped.
        case released
        /// A cluster command held the command lock for the whole wait: nothing was read or written.
        case commandStillRunning
        /// The start couldn't be cleared, or the part didn't stop in time.
        case partNotStopped
    }

    /// Going back to single-Mac serving on a Mac whose pair isn't running: this Mac's saved start is cleared, so its
    /// cluster service runs no part (and never takes the serving lock back by itself), and the part still running stops
    /// within `seconds`, freeing the lock. The pairing stays: `darkbloom cluster` starts the pair again. It holds the
    /// control command lock, as every stop of the pair does (waiting up to 600 s for a cluster command that runs), so
    /// the service's steps that stop the pair only to start it again never put this start back (`restoreStart`).
    /// `waiting` is called once, before that wait, so the person is told at once.
    public static func releaseForSingleMac(seconds: Double, waiting: () -> Void = {}) -> SingleMacRelease {
        guard let paths = try? ClusterUserPaths() else { return .partNotStopped }
        return releaseForSingleMac(seconds: seconds, paths: paths, waiting: waiting)
    }

    /// `releaseForSingleMac(seconds:waiting:)` in the home `paths` names, waiting `commandSeconds` for the command lock;
    /// tests give their own.
    static func releaseForSingleMac(seconds: Double, paths: ClusterUserPaths, commandSeconds: Double = 600,
                                    waiting: () -> Void = {}) -> SingleMacRelease {
        let setup = ClusterSetupPaths(paths: paths)
        let store = ClusterSetupStore(paths: setup)
        let file = setup.directory.appendingPathComponent("control.lock")
        var taken = ClusterControlCommandLock.acquire(seconds: 0, file: file)
        if taken == nil {
            waiting()
            taken = ClusterControlCommandLock.acquire(seconds: commandSeconds, file: file)
        }
        guard let held = taken else { return .commandStillRunning }
        defer { held.release() }
        do {
            if (try? store.readRecord())?.leadership?.serving == true {
                try store.updateRecord { $0.leadership?.serving = false }
            }
        } catch { return .partNotStopped }
        return stopLocalPart(in: setup.directory, seconds: seconds) ? .released : .partNotStopped
    }

    public static func pairRuns(_ status: ClusterServiceStatus?) -> Bool {
        guard let status, status.serving else { return false }
        if let running = status.pairRunning { return running }
        // A service from before 0.10.9 (a 0.10.8 one still running after the update): its control mode says whether
        // the other Mac takes part; without one, its intent.
        guard let mode = status.control?.mode else { return true }
        return !otherMacAbsentModes.contains(mode)
    }

    /// Control modes in which the other Mac isn't taking part (`ClusterServiceStatus.Control.mode`).
    public static let otherMacAbsentModes: Set<String> = ["waiting", "alone", "cannotServe", "idle"]

    /// The published status only while the service that wrote it runs now (holds the lock and its pid file names it);
    /// nil otherwise, e.g. the file a stopped service left behind.
    public static func publishedLive() -> ClusterServiceStatus? {
        guard running(), let status = published(), let writer = status.servicePID, let pidFile = try? paths().pid,
              let text = try? String(contentsOf: pidFile, encoding: .utf8),
              Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == writer else { return nil }
        return status
    }

    // MARK: - This Mac's part

    /// Whether single-Mac serving on this Mac holds back this Mac's part now: said once when it is first seen, and once
    /// when it stopped.
    private func holdsBackForSoloServing(key: String?, say: @escaping @Sendable (String) -> Void) -> Bool {
        let found = ProviderInstanceHolder.current(lockFile: providerInstanceLock).flatMap { $0.kind == .singleMac ? $0 : nil }
        let before = lock.withLock { () -> ProviderInstanceHolder.Holder? in defer { soloServing = found }; return soloServing }
        if let found {
            if before != found { say(Self.soloServingError(found) + "; this Mac's part waits for it to stop") }
            stepAsideIfUnchosen(found, key: key, say: say)
            return true
        }
        if before != nil {
            say("single-Mac serving stopped on this Mac: starting this Mac's part")
            blockerCleared(say: say)
        }
        return false
    }

    /// Whether the other Darkbloom app on this Mac holds its GPU now (`ClusterMachineDeviceLock.heldByAnotherBuild`), so
    /// this Mac's part waits instead of starting, being refused and counting as failing: said once, and named in the
    /// status. It starts on the first tick after the hold ends, with its restart backoff and any approval set aside as
    /// failing cleared (`blockerCleared`).
    private func holdsBackForOtherApp(say: @escaping @Sendable (String) -> Void) -> Bool {
        let now = ClusterMachineDeviceLock.heldByAnotherBuild(context.paths, otherHolder: productionServes)
        let before = lock.withLock { () -> String? in defer { otherAppHolds = now }; return otherAppHolds }
        switch ClusterOtherAppHold.step(before: before, now: now) {
        case .none: return false
        case .waits(let reason, let first):
            if first { say(reason + " This Mac's part waits for it.") }
            return true
        case .resumes:
            say("the other Darkbloom app no longer holds this Mac's GPU: starting this Mac's part")
            blockerCleared(say: say)
            return false
        }
    }

    /// SIGUSR1 to the worker owners the part `partPID` started (`fenceTargets`): their force-cancel hook
    /// (`ClusterOwnerForceCancel`) fences each one's worker, which cancels its requests, releases its model and exits by
    /// itself, the protocol's own drain. Its owner journals and reports that end, so nothing of the part's own state is
    /// left behind. Returns how many were asked.
    static func fenceOwners(of partPID: Int32) -> Int {
        let targets = fenceTargets(processes: ClusterProcessTable.running(), partPID: partPID,
                                   image: ClusterProcessTable.executablePath(of:))
        return targets.filter { kill($0, SIGUSR1) == 0 }.count
    }

    /// The worker owners among `partPID`'s descendants that run the part's own executable (`image`), chosen as
    /// `cluster cancel-all` chooses the owners it signals (`ClusterOrphanReaper.cancelTargets`): only such an owner
    /// carries the force-cancel hook for certain, and any other process would die of SIGUSR1. No other build's process is
    /// ever one of them, and there are none once the part's executable can't be read (it is gone).
    static func fenceTargets(processes: [ClusterProcessTable.Entry], partPID: Int32, image: (Int32) -> String?) -> [Int32] {
        var lineage: Set<Int32> = [partPID]
        var grew = true
        while grew {
            grew = false
            for entry in processes where !lineage.contains(entry.processIdentifier) {
                guard let parent = entry.parentProcessIdentifier, lineage.contains(parent) else { continue }
                lineage.insert(entry.processIdentifier)
                grew = true
            }
        }
        let tree = processes.filter { lineage.contains($0.processIdentifier) }
        return ClusterOrphanReaper.cancelTargets(processes: tree, ownImage: image(partPID),
                                                 protectedProcessIdentifiers: [partPID], image: image).signal
    }

    /// Single-Mac serving that nobody chose since the pair was last started here (`ClusterSoloChoice.stepsAside`; for
    /// example 0.10.8's updater restarted it) is stopped as `darkbloom stop --solo` stops it, once per process, on a thread
    /// of its own. A choice the person made keeps it, and the block stays on both screens.
    private func stepAsideIfUnchosen(_ holder: ProviderInstanceHolder.Holder, key: String?, say: @escaping @Sendable (String) -> Void) {
        let directory = store.paths.directory
        guard ClusterSoloChoice.stepsAside(wantedKey: key, chosenAt: ClusterSoloChoice.chosenAt(in: directory)) else { return }
        let begin = lock.withLock { () -> Bool in
            guard !steppingAside, steppedAsidePID != holder.pid || holder.pid == nil else { return false }
            steppingAside = true; steppedAsidePID = holder.pid; return true
        }
        guard begin else { return }
        let executable = settings.wizard.darkbloomExecutable, stop = stopSingleMac
        say(ProviderInstanceHolder.clause(holder) + ", and nobody chose it since the pair was started here: stopping it as "
            + "`\(BuildEnvironment.current.cliName) stop --solo` does, so the pair can start")
        Thread.detachNewThread { [weak self] in
            let result = stop(executable)
            self?.lock.withLock { self?.steppingAside = false }
            switch result {
            case .success:
                ClusterSoloChoice.noteSteppedAside(.init(at: Date().timeIntervalSince1970, pid: holder.pid), in: directory)
                say(ClusterSoloChoice.line(.init(at: Date().timeIntervalSince1970, pid: holder.pid), cli: BuildEnvironment.current.cliName))
            case .failure(let failure):
                say("single-Mac serving could not step aside: \(failure.text); `\(BuildEnvironment.current.cliName) stop --solo` on this Mac stops it")
            }
        }
    }

    /// The blocker cleared (single-Mac serving stopped here, or on the other Mac): its blocked ends are forgotten, and an
    /// approval they set aside as failing is taken again now, so the pair goes back to Darkbloom at once, not after an hour.
    private func blockerCleared(say: @escaping @Sendable (String) -> Void) {
        lock.withLock { memberQuickEnds = 0; nextStart = .distantPast; backoff = 3 }
        guard let record = try? store.readRecord(), let setAside = record.approvalSetAside,
              ClusterApprovalCheck.clearsAfterBlocker(setAside.reason) else { return }
        try? store.updateRecord { if $0.approvalSetAside.map { ClusterApprovalCheck.clearsAfterBlocker($0.reason) } == true { $0.approvalSetAside = nil } }
        say("the blocker cleared: offering the pair to Darkbloom again with approval \(setAside.approval.id)")
    }

    /// This Mac's cluster setup directory, where the person's choice of single-Mac serving is kept (`ClusterSoloChoice`).
    public static func soloChoiceDirectory() -> URL? {
        (try? ClusterUserPaths()).map { ClusterSetupPaths(paths: $0).directory }
    }

    /// How long a consented stop of single-Mac serving lets its accepted requests finish (`stop --solo --timeout`).
    public static let soloStopSeconds = 120

    /// Stops single-Mac serving on this Mac as `darkbloom stop --solo` does: its accepted requests finish first, and it
    /// stays stopped after a restart. Only after the person chose it on a screen.
    static func stopSoloServing(executable: URL, seconds: Int = soloStopSeconds) -> Result<Void, ClusterSetupFailure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["stop", "--solo", "--timeout", String(seconds)]
        let output = Pipe()
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .failure(ClusterSetupFailure("could not run `\(BuildEnvironment.current.cliName) stop --solo`: \(error)")) }
        let text = ClusterOnboardingMailbox<Data>()
        Thread.detachNewThread { text.post(output.fileHandleForReading.readDataToEndOfFile()) }
        if finished.wait(timeout: .now() + .seconds(seconds + 30)) == .timedOut {
            process.terminate()
            return .failure(ClusterSetupFailure("`\(BuildEnvironment.current.cliName) stop --solo` did not finish in \(seconds + 30) s"))
        }
        guard process.terminationStatus == 0 else {
            usleep(100_000)
            let last = text.take().first.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            return .failure(ClusterSetupFailure(ClusterConsoleText.boundedAtWord(last, maximum: 200)))
        }
        return .success(())
    }

    /// Why the other Mac's part can't start now, from its status: its own held-back reason (`heldBack`, from 0.10.9), or the
    /// single-Mac provider it reports. Nil when it reports none.
    static func heldBack(of status: ClusterServiceStatus) -> String? {
        status.heldBack ?? status.soloServing.map { solo in
            "a single-Mac Darkbloom provider (" + (solo.pid.map { "process \($0)" } ?? "a process it doesn't name") + ") is serving there"
        }
    }

    /// This Mac's part's error while single-Mac serving holds it back, in the words the other Mac's screen shows too.
    static func soloServingError(_ holder: ProviderInstanceHolder.Holder) -> String {
        ProviderInstanceHolder.clause(holder) + ", so this Mac's part can't start: `\(BuildEnvironment.current.cliName) stop --solo` stops it"
    }

    /// Ticks `pairWatch` and gives up this Mac's part once the other Mac hasn't answered for
    /// `ClusterPairWatch.giveUpSeconds`: the part stops and frees this Mac's serving lock (the watchdog brings back
    /// single-Mac serving set up here), and it starts again by itself when the other Mac answers. The degraded solo
    /// server of a pair serving through Darkbloom (local API only) gives way too while single-Mac serving is set up here.
    private func watchPair(_ want: PartWant, intent: Bool, scope: ClusterServingScope,
                           say: @escaping @Sendable (String) -> Void) -> PartWant {
        let now = Self.monotonicSeconds()
        let (answered, partUp, memberRank, offset) = lock.withLock {
            (control?.otherAnsweredAt, child?.isRunning == true && childSetup?.hasPrefix("cluster:") == true, childMemberRank, childLogOffset)
        }
        let servingNow = Self.partServesNow(partUp: partUp, otherAnsweredAt: answered, now: now, memberRank: memberRank) {
            Self.pairReport(in: serviceFiles.rankLog, from: offset)
        }
        let (verdict, previous) = lock.withLock { () -> (ClusterPairWatch.Verdict, ClusterPairWatch.Verdict) in
            let verdict = pairWatch.tick(raw: now, awake: ClusterControlClock.awakeSeconds(), intent: intent,
                                         otherAnsweredAt: answered, serving: servingNow)
            defer { pairVerdict = verdict }
            return (verdict, pairVerdict)
        }
        guard verdict.givesUpPart else {
            if previous.givesUpPart, verdict.running { say("the other Mac answers again: this Mac's part may start again") }
            return want
        }
        // Set up means loaded (an enabled job): the plist outlives `stop --solo`, which disables and unloads it.
        let singleMacJob = LaunchAgent.singleMacSetUp()
        let part = ClusterPairWatch.part(want, verdict: verdict, localOnly: scope.isLocalOnly, singleMacJob: singleMacJob)
        if part != want, !previous.givesUpPart, let line = ClusterPairWatch.line(verdict, otherMac: lock.withLock { otherMacNameLocked() },
                                                                                 cli: BuildEnvironment.current.cliName) {
            say(line)
        }
        return part
    }

    /// Whether this Mac's part serves now, as far as this Mac can tell (`pairWatch`'s `serving`): it runs, and the other
    /// Mac answered within the lease's time-to-live. Rank 0 of a coordinator-paired pair (`memberRank` 0), which hosts the
    /// pair's slot, must also have written `Pair: serving` to its log (`pairReport`, read only then). The other rank writes
    /// no pair line (its link follower reports to rank 0 over the cable), so its log can never say the pair serves: it
    /// goes by its running part and the other Mac's answers, as every part that isn't coordinator-paired does.
    static func partServesNow(partUp: Bool, otherAnsweredAt: Double?, now: Double, memberRank: Int?,
                              pairReport: () -> ClusterOnboardingPairReport.State?) -> Bool {
        guard partUp, let answered = otherAnsweredAt, now - answered < leaseTTLSeconds else { return false }
        guard memberRank == 0 else { return true }
        if case .serving = pairReport() { return true }
        return false
    }

    /// The other Mac's name as control knows it; nil before control.
    private func otherMacNameLocked() -> String? {
        guard let node = control else { return nil }
        return node.members.first { $0.key != node.localID }?.value.name
    }

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
        let want = watchPair(partWanted(serving: serving, hasSetup: reference != nil && saved.configuration != nil,
                                        model: saved.configuration?.publicModelID ?? record.leadership?.modelName, runningSolo: runningSolo),
                             intent: serving, scope: scope, say: say)
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
                child = nil; childSetup = nil; lastEnd = end; lastRunSeconds = ran; endedKey = setup
                backoff = ran >= 120 ? 3 : min(backoff * 2, 30)
                nextStart = Date().addingTimeInterval(ran >= 120 ? 3 : backoff)
            }
            // A part refused because the other Darkbloom app holds this Mac's GPU (`ClusterMachineDeviceLock`) waits for
            // it from the next tick (`holdsBackForOtherApp`), which starts it again as soon as the hold ends.
            let lastError = setup?.hasPrefix("cluster:") == true
                ? Self.lastError(in: serviceFiles.rankLog, from: lock.withLock { childLogOffset }, preferStopReason: false) : nil
            if ClusterMachineDeviceLock.isRefusal(lastError) { lock.withLock { otherAppHolds = otherAppHolds ?? lastError } }
            // A coordinator-paired part that keeps ending right after its start makes the leader serve locally
            // (`ClusterApprovalCheck.step`); an end the coordinator decided (out of reach, or the member role not
            // accepted in time) is not counted.
            if lock.withLock({ childIsMember }) {
                // An end while either Mac's part is held back (single-Mac serving, or the other app on a Mac holding its
                // GPU) is the blocker's, not the approval's.
                let heldBack = lock.withLock { peerHeldBack != nil || soloServing != nil || otherAppHolds != nil }
                lock.withLock { memberQuickEnds = ClusterApprovalCheck.memberQuickEnds(after: memberQuickEnds, ranSeconds: ran, lastError: lastError,
                                                                                        heldBack: heldBack) }
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
        // Outside production's build, this Mac's part steps aside once production serves here: production before 0.10.11
        // takes no GPU lock, so its pair started after this one (both start at login, say) would load beside it. The part's
        // GPU work is fenced at once, not drained (`fenceGPUWork`); the part then stops, never counted as failing, and
        // waits (`holdsBackForOtherApp`) until production stops serving here.
        if let part = running, setup?.hasPrefix("cluster:") == true, let reason = productionServes?() {
            lock.withLock { otherAppHolds = reason }
            say(reason + " This Mac's part stops and waits for it.")
            let fenced = fenceGPUWork(part.processIdentifier)
            if fenced > 0 { say("asked this part's \(fenced == 1 ? "worker owner" : "\(fenced) worker owners") to release the GPU now") }
            _ = stopChild(say: say, seconds: 300)
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
                : ClusterLocalServing.scopeChangedOnly(from: setup, to: key) ? Self.scopeChangeRestartLine(scope)
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
        // Single-Mac serving holds this Mac's one serving lock and never ends by itself: a part started beside it only
        // ended at once and started again every few seconds (0.10.8, 2026-11-04: "this Mac's part ended (exit 1: …)"
        // in a loop on both Macs). Nothing starts until it stops; the status names it meanwhile.
        if running == nil, key != nil, holdsBackForSoloServing(key: key, say: say) { return }
        if key == nil { lock.withLock { soloServing = nil } }
        // The other Darkbloom app's pair (or model check) holds this Mac's GPU: this Mac's part waits for it, not counted as
        // failing, and starts as soon as it ends (re-review of #1846: the refusals took production off Darkbloom for an hour).
        if running == nil, let key, key.hasPrefix("cluster:"), holdsBackForOtherApp(say: say) { return }
        if key == nil || key?.hasPrefix("cluster:") == false { lock.withLock { otherAppHolds = nil } }
        // The other Mac said its part can't start for a reason that doesn't clear by itself: this Mac's part waits for that
        // to change instead of starting, waiting for its missing follower and ending every 38 s (0.10.9 DevNet f1).
        if running == nil, let key {
            let reason = ClusterControlPartChoice.waitsForOtherMac(key: key, otherMacHeldBack: lock.withLock { peerHeldBack },
                                                                    leads: leadsAndRunsCluster())
            let before = lock.withLock { () -> String? in defer { peerHeldBackSaid = reason }; return peerHeldBackSaid }
            if let reason {
                if before != reason { say("the other Mac's part can't start (\(reason)): this Mac's part waits for that to change") }
                return
            }
            if before != nil {
                say("the other Mac's part can start again: starting this Mac's part")
                blockerCleared(say: say)
            }
        }
        // The restart backoff holds back only the part that ended: serving alone after the grace starts at once.
        guard running == nil, let key, lock.withLock({ !stopping && ClusterControlPartChoice.mayStart(key: key, endedKey: endedKey,
                                                                                                  backoffElapsed: Date().timeIntervalSince(nextStart) >= 0) })
        else { return }
        let arguments: [String]
        let what: String
        var linkFollower = false
        var memberRank: Int?
        var port: Int?
        if case .solo(let model) = want {
            // This Mac's own port, as every local API here takes it: a relay that held it gives it back first.
            handRelayPortBack()
            let soloPort = thisMacPort(say: say) ?? Self.defaultSoloPort
            arguments = ClusterLocalServing.soloArguments(settings.soloArguments, scope: scope) + ["--model", model, "--port", String(soloPort)]
            what = "degraded: serving \(model) on this Mac alone"
            port = soloPort
        } else {
            guard let configuration = saved.configuration else { return }
            // After an update a member's saved setup still pins the earlier build's worker: its part would refuse the
            // installed inputs and end at once, again and again, until the leader syncs the setup for the new build.
            // Nothing of the old setup starts or is rewritten meanwhile; the part's own checks stay as strict.
            if configuration.role != .leader, configuration.peers.indices.contains(configuration.localRank) {
                let local = configuration.peers[configuration.localRank]
                if ClusterOnboardingUpdate.memberWaitsForLeaderSetup(pinned: local.runtimeBinarySHA256,
                                                                     installed: try? context.workerSHA256(local.workerExecutable)) {
                    let line = ClusterOnboardingUpdate.memberWaitLine(version: ProviderCore.version, otherVersion: otherMacVersion())
                    if lock.withLock({ memberSetupWaitLine != line }) {
                        lock.withLock { memberSetupWaitLine = line }
                        say(line)
                    }
                    return
                }
                if lock.withLock({ memberSetupWaitLine != nil }) {
                    lock.withLock { memberSetupWaitLine = nil }
                    say("this Mac's saved setup is for the build it runs: starting its part")
                }
            }
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
                memberRank = configuration.localRank
                // Registered with the coordinator as a cluster member: both Macs run the coordinator-formed pair's member; the
                // leader's rank hosts the link listener and the pair's slot, the other rank dials it. With Both, me first,
                // the part that runs rank 0 (the slot's host) also runs the pair's local API, on this Mac's own port
                // (`leaderAPIPort`); no other part takes a port (the other Macs' relays take theirs).
                if scope.addsLocalAPI, configuration.localRank == 0 {
                    handRelayPortBack()
                    let apiPort = leaderAPIPort(scope: scope, say: say)
                    port = apiPort
                    arguments = ClusterLocalServing.memberArguments(settings.memberArguments, scope: scope,
                                                                    localRank: configuration.localRank, port: apiPort)
                } else {
                    arguments = settings.memberArguments
                }
            } else if configuration.role == .leader {
                handRelayPortBack()
                let leaderPort = leaderAPIPort(scope: scope, say: say)
                port = leaderPort
                arguments = ClusterLocalServing.leaderArguments(settings.leaderArguments, scope: scope) + ["--port", String(leaderPort)]
            } else {
                arguments = settings.followerArguments
                linkFollower = true
            }
            what = "this Mac's part: " + (offered
                ? "rank \(configuration.localRank), registered with the coordinator as a cluster member"
                    + (port.map { " with the pair's local API on port \($0)" } ?? "")
                : configuration.role == .leader
                ? "rank 0 and the serving API" + (scope.isLocalOnly ? " (local only, no coordinator)" : "")
                : "rank \(configuration.localRank)")
        }
        // A cluster part starting again clears the solo record: the next time this Mac is left alone it may try again.
        if case .cluster = want { lock.withLock { soloQuickEnds = nil } }
        // The model's own pages leave the file cache before the part starts, so its load reads them from the SSD into
        // free pages. A load into a cache full of its own model makes macOS compress other memory to free that cache
        // page by page; past the load gate's compression guard (512 MiB) the gate counts no cache and refuses, and a
        // restart that read the model back in was refused again (MiMo on two 128 GB Macs, 680 of 680 starts,
        // 2026-11-01). The worker's hashing and loads read uncached and add none back, except GLM's tensor-parallel
        // load, which reads through the cache on purpose.
        if case .cluster = want, let configuration = saved.configuration, configuration.peers.indices.contains(configuration.localRank) {
            ClusterModelStore.dropCachedPages(folder: URL(fileURLWithPath: configuration.peers[configuration.localRank].modelDirectory))
        }
        let process = Process()
        process.executableURL = settings.wizard.darkbloomExecutable
        process.arguments = arguments
        process.environment = Self.partEnvironment(environment ?? ProcessInfo.processInfo.environment,
                                                   serviceDirectory: store.paths.directory)
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
            childMemberRank = memberRank; childLogOffset = logOffset
            childIsLinkFollower = linkFollower; followerRefusalRead = nil
            if memberRank == nil { memberQuickEnds = 0 }
        }
        say("started \(what) (pid \(process.processIdentifier))")
    }

    /// The environment of this Mac's part: this service's own, except the heartbeat file. Under its supervisor the
    /// service beats into the file `ClusterSupervisionFiles.healthPathEnvironmentKey` names, and a coordinator-paired
    /// part (`start --cluster-member`) beats into the file the same key names, with its own pid. Inherited as is, the
    /// part overwrote the service's heartbeat, and the supervisor's liveness guard reads a beat of another pid as no
    /// beat: whenever the part's beats landed last at the guard's probes for its down budget, the guard restarted a
    /// healthy service and the pair dropped. The part beats into a file of its own instead; it keeps the key, so it
    /// still waits for its registration as a supervised member does.
    static func partEnvironment(_ environment: [String: String], serviceDirectory: URL) -> [String: String] {
        var environment = environment
        let key = ClusterSupervisionFiles.healthPathEnvironmentKey
        if let path = environment[key], !path.isEmpty {
            environment[key] = ClusterServiceAgent.partHealthPath(serviceDirectory: serviceDirectory).path
        }
        return environment
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

    /// What this Mac's part says when it starts again only because the scope changed.
    private static func scopeChangeRestartLine(_ scope: ClusterServingScope) -> String {
        switch scope {
        case .localOnly: return "serving locally only now (no coordinator): restarting this Mac's part"
        case .publicServingWithLocalAPI: return "serving through Darkbloom with the pair's local API now: restarting this Mac's part"
        case .publicServing: return "serving through Darkbloom now: restarting this Mac's part"
        }
    }

    /// The port rank 0's API takes on this Mac, for every way the pair serves: this Mac's own (`thisMacPort`, its saved
    /// `[local] port`, the same for every local API here), whatever the other Macs' are, so tools on this Mac keep its
    /// address whichever Mac runs rank 0. Only when it can't be read or chosen, the earlier rule on this Mac alone
    /// (`ClusterLocalServing.apiPort`). A port another program holds stays this Mac's: the part's bind fails and says so.
    private func leaderAPIPort(scope: ClusterServingScope, say: @Sendable (String) -> Void) -> Int {
        let previous = lock.withLock { apiPort }
        let port = ClusterLocalServing.apiPort(own: thisMacPort(say: say), scope: scope, previous: previous)
        lock.withLock { apiPort = port }
        if port != previous { say("the pair's local API listens on this Mac's port \(port)") }
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
