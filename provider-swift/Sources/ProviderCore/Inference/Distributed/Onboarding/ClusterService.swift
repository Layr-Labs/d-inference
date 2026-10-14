import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterProcess

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
        _ = try? ClusterConfigurationFiles.directory(path.deletingLastPathComponent(), create: true, privateMode: true)
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
        public init(wizard: ClusterSetupOperations.LiveSettings, leaderArguments: [String], followerArguments: [String],
                    soloArguments: [String] = ["start", "--local"]) {
            self.wizard = wizard; self.leaderArguments = leaderArguments; self.followerArguments = followerArguments
            self.soloArguments = soloArguments
        }
    }

    let settings: Settings
    let context: LiveContext
    let store: ClusterSetupStore
    let lock = NSLock()
    private var child: Process?
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
    // Derived control (ClusterServiceControl.swift).
    var control: ClusterControlNode?
    var controlResponder: ClusterSetupLinkExchange.Responder?
    var leaseInFlight = false
    var nextLease: Double = 0
    var lastModeLine: String?
    var localHardware: (name: String, memoryBytes: UInt64, gpuCores: Int)?
    lazy var controlLive: OnboardingLive = OnboardingLive(context: context, store: store,
        settings: .init(service: settings, serviceArguments: []))

    public init(settings: Settings) throws {
        var wizard = settings.wizard
        wizard.derivedPlacement = true
        wizard.answersOverLink = false
        self.settings = Settings(wizard: wizard, leaderArguments: settings.leaderArguments, followerArguments: settings.followerArguments,
            soloArguments: settings.soloArguments)
        let paths = try ClusterUserPaths()
        store = ClusterSetupStore(paths: .init(paths: paths))
        context = LiveContext(paths: paths, store: store, settings: wizard,
            clean: ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path))
    }

    // MARK: - Files

    public static func paths() throws -> (lock: URL, pid: URL, log: URL, rankLog: URL) {
        let directory = ClusterSetupPaths(paths: try ClusterUserPaths()).directory
        return (directory.appendingPathComponent("service.lock"), directory.appendingPathComponent("service.pid"),
                directory.appendingPathComponent("service.log"), directory.appendingPathComponent("rank.log"))
    }

    /// Whether a cluster service holds this home's lock now.
    public static func running() -> Bool {
        guard let lockFile = try? paths().lock else { return false }
        let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }

    /// Starts `darkbloom cluster service` detached from this terminal (its own
    /// session, output to service.log) unless one runs; waits until it holds its lock.
    public static func ensureRunning(executable: URL, arguments: [String]) throws -> Bool {
        if running() { return false }
        let files = try paths()
        _ = try ClusterConfigurationFiles.directory(files.lock.deletingLastPathComponent(), create: true, privateMode: true)
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
        let files = try Self.paths()
        _ = try ClusterConfigurationFiles.directory(files.lock.deletingLastPathComponent(), create: true, privateMode: true)
        let fd = open(files.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClusterOnboardingFailure("the service lock cannot be opened") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ClusterOnboardingFailure("this Mac's cluster service is already running") }
        try? Data("\(getpid())\n".utf8).write(to: files.pid, options: .atomic)
        defer { unlink(files.pid.path) }
        say("started (pid \(getpid()))")
        // A part a previous run of this service started and left running (that run ended without stopping it, e.g.
        // killed): stopped before anything starts, or it would hold the model's memory and the serving port forever.
        if let previous = Self.published(), previous.servicePID != getpid(), let left = Self.recordedPart(previous) {
            say("this Mac's \(left.solo ? "solo server" : "part") from the previous service run is still running (pid \(left.pid)): stopping it first")
            say(Self.stopLeftover(left, seconds: 300) ? "the previous run's \(left.solo ? "solo server" : "part") stopped"
                : "the previous run's \(left.solo ? "solo server" : "part") is still releasing after 300 s")
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
                self.ensureControlResponder(say: say)
                self.controlTick(say: say)
                usleep(500_000)
            }
        }
        while !stopped {
            ensureResponder(say: say)
            supervise(say: say)
            syncMembers(say: say)
            publish()
            if ticker.wait(timeout: .now() + 1) == .success { stopped = true }
        }
        lock.withLock { stopping = true }
        _ = controlDone.wait(timeout: .now() + 5)
        say("stopping")
        lock.withLock { responder }?.stop()
        lock.withLock { controlResponder }?.stop()
        let clean = stopChild(say: say, seconds: Double(ClusterServiceAgentPlan.partStopGraceSeconds))
        say(clean ? "stopped" : "stopped with this Mac's part still releasing")
        return clean
    }

    private func ensureResponder(say: @escaping @Sendable (String) -> Void) {
        guard lock.withLock({ responder == nil }), let pairing = try? ClusterSetupLinkExchange.pairing(),
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
        if let claim = record.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID) { return claim.leaderID == pairing.peerMemberID }
        guard let leadership = record.leadership else { return false }
        return leadership.role == ClusterOnboardingRole.member.rawValue && leadership.leaderPin == pairing.peerPin
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
        let context = self.context
        Thread.detachNewThread { [weak self] in
            defer { self?.lock.withLock { self?.syncing = false } }
            guard let pairing = try? ClusterSetupLinkExchange.pairing(), pairing.peerPin == leadership.peerPin,
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
            switch ClusterOnboardingSync.action(leaderServing: leadership.serving, leaderModel: leadership.modelName,
                                                memberServing: member?.serving, memberModel: member?.modelName) {
            case .none: return
            case .serve(let model):
                if send(.init(op: .serve, model: model), seconds: 10) != nil { say("the member had missed the start: started its part") }
            case .stop:
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
            return try encoder.encode(status())
        case .serve, .stop:
            if let sent = command.claim, let own = lock.withLock({ control?.claim }), own.supersedes(sent) {
                throw ClusterSetupFailure("the Mac that asked no longer leads: term \(own.term) superseded its term \(sent.term)")
            }
            guard followsPeer(pairing) else { throw ClusterSetupFailure("this Mac does not follow the Mac that asked") }
            try store.updateRecord {
                $0.leadership?.serving = command.op == .serve
                if let model = command.model { $0.leadership?.modelName = model }
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

    static func recordedPart(_ status: ClusterServiceStatus?) -> RecordedPart? {
        guard let child = status?.child, child.running, let pid = child.pid, let startedAt = child.startedAt,
              let now = ClusterProcessTable.startTime(of: pid), abs(now - startedAt) < 0.001 else { return nil }
        return .init(pid: pid, startedAt: startedAt, solo: child.solo == true)
    }

    /// SIGTERM, repeated every `stopResendSeconds`, never SIGKILL (a rank releases its model itself), and only while the
    /// process is still the recorded one.
    static func stopLeftover(_ part: RecordedPart, seconds: Double) -> Bool {
        func same() -> Bool { ClusterProcessTable.startTime(of: part.pid).map { abs($0 - part.startedAt) < 0.001 } ?? false }
        let started = Date()
        var sent = -1
        while same() {
            guard Date().timeIntervalSince(started) < seconds else { return false }
            let due = Int(Date().timeIntervalSince(started) / stopResendSeconds)
            if due > sent { sent = due; kill(part.pid, SIGTERM) }
            usleep(100_000)
        }
        return true
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

    /// One test request through this Mac's serving API, collected.
    static func prompt(_ context: LiveContext, text: String, port: Int? = nil) -> ClusterServicePromptAnswer {
        let collected = ClusterOnboardingMailbox<ClusterSetupPromptEvent>()
        context.prompt(text: String(text.prefix(400)), maxTokens: 48, port: port) { collected.post($0) }
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
            return ClusterServiceStatus(role: record?.leadership?.role, serving: record?.leadership?.serving ?? false,
                modelName: record?.leadership?.modelName, sessionLeader: leads, localRank: configuration?.localRank,
                setup: reference.map { String($0.sha256.prefix(12)) },
                child: .init(running: child?.isRunning ?? false, starts: starts, lastEnd: lastEnd,
                    restartInSeconds: child == nil && wait > 0 ? Int(wait.rounded(.up)) : nil,
                    lastError: child?.isRunning == true ? nil : Self.lastError(),
                    pid: child?.isRunning == true ? child?.processIdentifier : nil,
                    startedAt: child?.isRunning == true ? childStartedAt : nil,
                    solo: child?.isRunning == true ? childSetup?.hasPrefix("solo:") == true : nil),
                session: session,
                cacheSync: record?.leadership.flatMap { $0.role == ClusterOnboardingRole.member.rawValue
                    ? cacheStore.digest(leaderPin: $0.leaderPin) : nil },
                control: controlStatusLocked(model: record?.leadership?.modelName), servicePID: getpid())
        }
    }

    /// The last "Error:" line of this Mac's part's log, bounded; nil when there is none.
    public static func lastError() -> String? {
        guard let log = try? paths().rankLog, let handle = FileHandle(forReadingAtPath: log.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let line = tail.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Error:") }) else { return nil }
        return ClusterConsoleText.bounded(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces), maximum: 240)
    }

    /// Kept beside the lock each tick, so `darkbloom cluster` on this Mac reads it without the link.
    private func publish() {
        guard let file = try? Self.paths().pid.deletingLastPathComponent().appendingPathComponent("service-status.json"),
              let data = try? JSONEncoder().encode(status()) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The status the running service last published on this Mac.
    public static func published() -> ClusterServiceStatus? {
        guard let file = try? paths().pid.deletingLastPathComponent().appendingPathComponent("service-status.json"),
              let data = try? Data(contentsOf: file) else { return nil }
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

    private func supervise(say: @Sendable (String) -> Void) {
        let record = try? store.readRecord()
        let saved = context.savedConfiguration()
        let reference = try? saved.reference.get()
        let serving = record?.leadership?.serving ?? false
        let runningSolo = lock.withLock { child != nil && childSetup?.hasPrefix("solo:") == true }
        let want = partWanted(serving: serving, hasSetup: reference != nil && saved.configuration != nil,
                              model: saved.configuration?.publicModelID ?? record?.leadership?.modelName, runningSolo: runningSolo)
        // What runs is keyed: "cluster:<setup digest>" (this Mac's part of the saved setup) or "solo:<model>"
        // (degraded serving on this Mac alone). A part of another key is stopped before the wanted one starts.
        let key: String?
        switch want {
        case .keep: return
        case .none: key = nil
        case .cluster: key = reference.map { "cluster:" + $0.sha256 }
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
            say("this Mac's \(setup?.hasPrefix("solo:") == true ? "solo server" : "part") ended (\(end)) after \(Int(ran)) s; "
                + (key != nil ? "starting it again" : "not serving"))
            return
        }
        if let running, key == nil || setup != key {
            let solo = setup?.hasPrefix("solo:") == true
            say(key == nil ? (solo ? "stopping the solo server" : "the leader stopped serving: stopping this Mac's part")
                : key!.hasPrefix("solo:") ? "serving alone: stopping this Mac's part first"
                : solo ? "the cluster re-forms: stopping the solo server first" : "the setup changed: restarting this Mac's part")
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
        if case .solo(let model) = want {
            arguments = settings.soloArguments + ["--model", model, "--port", String(Self.soloPort)]
            what = "degraded: serving \(model) on this Mac alone"
        } else {
            guard let configuration = saved.configuration else { return }
            arguments = configuration.role == .leader ? settings.leaderArguments : settings.followerArguments
            what = "this Mac's part: " + (configuration.role == .leader ? "rank 0 and the serving API" : "rank \(configuration.localRank)")
        }
        let process = Process()
        process.executableURL = settings.wizard.darkbloomExecutable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let log = try? Self.paths().rankLog {
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); process.standardOutput = handle; process.standardError = handle }
        }
        do { try process.run() } catch {
            say("\(what) could not start: \(error)")
            lock.withLock { nextStart = Date().addingTimeInterval(backoff); backoff = min(backoff * 2, 30); endedKey = key }
            return
        }
        let startedAt = ClusterProcessTable.startTime(of: process.processIdentifier)
        lock.withLock { child = process; childSetup = key; childStarted = Date(); childStartedAt = startedAt; starts += 1 }
        say("started \(what) (pid \(process.processIdentifier))")
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
