import Foundation
import Darwin
import DarkbloomClusterRemote

/// What one Mac's cluster service reports to its leader.
public struct ClusterServiceStatus: Codable, Sendable, Equatable {
    public struct Child: Codable, Sendable, Equatable {
        public var running: Bool
        public var starts: Int
        /// How the last run ended ("exit 1", "signal 15"), nil before the first end.
        public var lastEnd: String?
        /// Seconds until the next start while it waits after an end.
        public var restartInSeconds: Int?
    }
    public struct Session: Codable, Sendable, Equatable {
        public var observed: Bool
        public var ready: Bool
        public var readyRanks: Int
        public var ranks: Int
        public var port: Int?
        public var detail: String?
    }
    public var role: String?
    public var serving: Bool
    public var modelName: String?
    /// This Mac's saved setup runs rank 0 and the serving API.
    public var sessionLeader: Bool
    public var localRank: Int?
    public var setup: String?
    public var child: Child
    /// Only on the Mac that runs rank 0.
    public var session: Session?
}

/// One command from the leader to a member's cluster service.
public struct ClusterServiceCommand: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable { case serve, stop, status, prompt }
    public var op: Operation
    public var model: String?
    public var text: String?
    public init(op: Operation, model: String? = nil, text: String? = nil) { self.op = op; self.model = model; self.text = text }
}

/// A test request's answer, sent back over the link.
public struct ClusterServicePromptAnswer: Codable, Sendable, Equatable {
    public var text: String
    public var tokens: Int
    public var firstTokenMilliseconds: Int?
    public var tokensPerSecond: Double?
    public var finishReason: String?
    public var error: String?
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
        public init(wizard: ClusterSetupOperations.LiveSettings, leaderArguments: [String], followerArguments: [String]) {
            self.wizard = wizard; self.leaderArguments = leaderArguments; self.followerArguments = followerArguments
        }
    }

    let settings: Settings
    let context: LiveContext
    let store: ClusterSetupStore
    private let lock = NSLock()
    private var child: Process?
    private var childSetup: String?
    private var childStarted = Date.distantPast
    private var starts = 0
    private var lastEnd: String?
    private var nextStart = Date.distantPast
    private var backoff: Double = 3
    private var responder: ClusterSetupLinkExchange.Responder?
    private var stopping = false

    public init(settings: Settings) throws {
        var wizard = settings.wizard
        wizard.derivedPlacement = true
        wizard.answersOverLink = false
        self.settings = Settings(wizard: wizard, leaderArguments: settings.leaderArguments, followerArguments: settings.followerArguments)
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
        let ticker = DispatchSemaphore(value: 0)
        var stopped = false
        Thread.detachNewThread { stop.wait(); ticker.signal() }
        while !stopped {
            ensureResponder(say: say)
            supervise(say: say)
            if ticker.wait(timeout: .now() + 1) == .success { stopped = true }
        }
        lock.withLock { stopping = true }
        say("stopping")
        lock.withLock { responder }?.stop()
        let clean = stopChild(say: say, seconds: 300)
        say(clean ? "stopped" : "stopped with this Mac's part still releasing")
        return clean
    }

    private func ensureResponder(say: @escaping @Sendable (String) -> Void) {
        guard lock.withLock({ responder == nil }), let pairing = try? ClusterSetupLinkExchange.pairing(),
              let selection = try? context.linkSelection() else { return }
        let context = self.context, store = self.store
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
            })
            try created.start()
            lock.withLock { responder = created }
            say("answering the paired Mac over the cable")
        } catch {
            // Tried again at the next tick (the cable may not be up yet).
        }
    }

    /// This Mac follows the Mac it paired with.
    private func followsPeer(_ pairing: ClusterSetupLinkExchange.Pairing) -> Bool {
        guard let leadership = try? store.readRecord().leadership else { return false }
        return leadership.role == ClusterOnboardingRole.member.rawValue && leadership.leaderPin == pairing.peerPin
    }

    /// A setup from the leader: a member applies it at once; anything else only reaches the inbox.
    private func receive(_ data: Data, pairing: ClusterSetupLinkExchange.Pairing, say: @Sendable (String) -> Void) throws -> String {
        let digest = try store.receive(data)
        guard followsPeer(pairing), let candidate = store.inboxCandidate else { return digest }
        let configuration = settings.wizard.providerConfiguration, paths = context.paths
        let result = ClusterConsoleObserver.approve(candidate, expectedSHA256: digest,
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

    private func command(_ data: Data, pairing: ClusterSetupLinkExchange.Pairing, say: @Sendable (String) -> Void) throws -> Data {
        let command = try JSONDecoder().decode(ClusterServiceCommand.self, from: data)
        let encoder = JSONEncoder()
        switch command.op {
        case .status:
            return try encoder.encode(status())
        case .serve, .stop:
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
        }
    }

    /// One test request through this Mac's serving API, collected.
    static func prompt(_ context: LiveContext, text: String) -> ClusterServicePromptAnswer {
        let collected = ClusterOnboardingMailbox<ClusterSetupPromptEvent>()
        context.prompt(text: String(text.prefix(400)), maxTokens: 48) { collected.post($0) }
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
                    restartInSeconds: child == nil && wait > 0 ? Int(wait.rounded(.up)) : nil),
                session: session)
        }
    }

    // MARK: - This Mac's part

    private func supervise(say: @Sendable (String) -> Void) {
        let record = try? store.readRecord()
        let saved = context.savedConfiguration()
        let reference = try? saved.reference.get()
        let desired = (record?.leadership?.serving ?? false) && reference != nil && saved.configuration != nil
        let (running, setup, ended) = lock.withLock { () -> (Process?, String?, Bool) in
            (child, childSetup, child.map { !$0.isRunning } ?? false)
        }
        if let running, ended {
            let ran = Date().timeIntervalSince(lock.withLock { childStarted })
            let end = running.terminationReason == .uncaughtSignal ? "signal \(running.terminationStatus)" : "exit \(running.terminationStatus)"
            lock.withLock {
                child = nil; childSetup = nil; lastEnd = end
                backoff = ran >= 120 ? 3 : min(backoff * 2, 30)
                nextStart = Date().addingTimeInterval(ran >= 120 ? 3 : backoff)
            }
            say("this Mac's part ended (\(end)) after \(Int(ran)) s; " + (desired ? "starting it again" : "not serving"))
            return
        }
        if let running, !desired || setup != reference?.sha256 {
            say(desired ? "the setup changed: restarting this Mac's part" : "the leader stopped serving: stopping this Mac's part")
            _ = running
            _ = stopChild(say: say, seconds: 300)
            return
        }
        guard running == nil, desired, let configuration = saved.configuration, let reference,
              lock.withLock({ !stopping && Date() >= nextStart }) else { return }
        let arguments = configuration.role == .leader ? settings.leaderArguments : settings.followerArguments
        let process = Process()
        process.executableURL = settings.wizard.darkbloomExecutable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let log = try? Self.paths().rankLog {
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); process.standardOutput = handle; process.standardError = handle }
        }
        do { try process.run() } catch {
            say("this Mac's part could not start: \(error)")
            lock.withLock { nextStart = Date().addingTimeInterval(backoff); backoff = min(backoff * 2, 30) }
            return
        }
        lock.withLock { child = process; childSetup = reference.sha256; childStarted = Date(); starts += 1 }
        say("started this Mac's part: \(configuration.role == .leader ? "rank 0 and the serving API" : "rank \(configuration.localRank)") (pid \(process.processIdentifier))")
    }

    /// SIGTERM, then wait: a rank that holds a model releases it itself.
    private func stopChild(say: @Sendable (String) -> Void, seconds: Double) -> Bool {
        guard let running = lock.withLock({ child }) else { return true }
        if running.isRunning { running.terminate() }
        let deadline = Date().addingTimeInterval(seconds)
        while running.isRunning, Date() < deadline { usleep(100_000) }
        let clean = !running.isRunning
        if clean { lock.withLock { child = nil; childSetup = nil; lastEnd = "stopped" } }
        say(clean ? "this Mac's part stopped" : "this Mac's part is still releasing after \(Int(seconds)) s")
        return clean
    }
}
