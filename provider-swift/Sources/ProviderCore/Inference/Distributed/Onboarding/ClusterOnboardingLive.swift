import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

extension ClusterOnboardingOperations {
    public struct LiveSettings: Sendable {
        public var service: ClusterService.Settings
        /// How to start this Mac's cluster service: `cluster service` with the provider configuration.
        public var serviceArguments: [String]
        public init(service: ClusterService.Settings, serviceArguments: [String]) {
            self.service = service; self.serviceArguments = serviceArguments
        }
    }

    /// The onboarding as the installed command runs it: the guided link setup,
    /// the pairing ceremony (S17) with discovery, the setup exchange over the
    /// paired link, the planner, and the cluster services on both Macs.
    public static func live(_ settings: LiveSettings) throws -> ClusterOnboardingOperations {
        var wizard = settings.service.wizard
        wizard.derivedPlacement = true
        wizard.answersOverLink = false
        let paths = try ClusterUserPaths()
        let store = ClusterSetupStore(paths: .init(paths: paths))
        if let given = wizard.modelsDirectory { _ = try? store.updateRecord { $0.modelsDirectory = given } }
        let context = LiveContext(paths: paths, store: store, settings: wizard, clean: ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path))
        let live = OnboardingLive(context: context, store: store, settings: settings)
        return ClusterOnboardingOperations(
            resume: { live.resume() },
            checkLink: { say in live.checkLink(say) },
            pair: { events in live.pair(events) },
            answerCode: { live.answer($0) },
            ensureService: { live.ensureService() },
            reachMembers: { say in live.reachMembers(say) },
            planModels: { live.planModels() },
            adopt: { live.adopt($0) },
            serve: { live.serve() },
            waitReady: { progress in live.waitReady(progress) },
            testRequest: { live.testRequest() },
            status: { live.status() },
            stop: { live.stop() },
            provision: { index, download, progress in live.provision(index, download: download, progress) },
            verifyTeardown: { live.verifyTeardown() },
            useLinkPort: { live.useLinkPort($0) },
            recheckFit: { live.recheckFit($0) },
            afterRestart: { live.afterRestart() },
            saveDiagnostics: { live.saveDiagnostics() },
            developerNotice: { ClusterForcedModeSetting.notice(environment: ProcessInfo.processInfo.environment) },
            setScope: { live.setScope($0) })
    }
}

final class OnboardingLive: @unchecked Sendable {
    let context: LiveContext
    let store: ClusterSetupStore
    let settings: ClusterOnboardingOperations.LiveSettings
    private let lock = NSLock()
    private var respond: (@Sendable (Bool) -> Void)?
    private var pendingAnswer: Bool?
    private var peerReport: ClusterSetupReport?
    private var peerReportMemberID: String?
    /// When the other Mac's report was taken, and when this Mac last stopped the cluster's parts: a report taken
    /// before the stop prices the other Mac's memory with its old part still loaded
    /// (`ClusterOnboardingUpdate.reportPricesPlan`).
    private var peerReportAt: Date?
    private var partsStoppedAt: Date?
    private let readPairing: @Sendable () throws -> ClusterSetupLinkExchange.Pairing?
    private var choices: [(folder: String, key: String, title: String, alone: [String], deployment: String?, plan: ClusterSetupPlanSummary?)] = []
    /// Choices that are catalog models no Mac has yet (by choice index).
    private var catalogChoices: [Int: CatalogModel] = [:]
    /// Choices that only the other Mac has (by choice index): it sends them here first.
    private var peerChoices: [Int: ClusterSetupLocalModel] = [:]
    private var chosenTitle: String?
    /// The list `planModels` last returned on this Mac (from the leader when forwarded), so a choice names its model.
    private var listedChoices: [ClusterOnboardingModelChoice] = []
    /// Set while this (leader) Mac answers a command forwarded from another member: its lines name this Mac by its
    /// name instead of "this Mac", which would mean the Mac that shows them.
    private var answeringForward = false
    private lazy var ownName: String = ClusterPairingProvider.displayName(chipName: (try? HardwareDetector.detect().chipName) ?? "Mac")

    /// "this Mac", or this Mac's name in an answer shown on another member.
    var here: String { lock.withLock { answeringForward } ? ownName : "this Mac" }

    init(context: LiveContext, store: ClusterSetupStore, settings: ClusterOnboardingOperations.LiveSettings,
         readPairing: @escaping @Sendable () throws -> ClusterSetupLinkExchange.Pairing? = { try ClusterSetupLinkExchange.pairing() }) {
        self.context = context; self.store = store; self.settings = settings
        self.readPairing = readPairing
    }

    var leadership: ClusterOnboardingLeadership? { (try? store.readRecord())?.leadership }
    var peerName: String {
        let fresh = lock.withLock { (peerReport, peerReportMemberID) }
        if let report = fresh.0, let memberID = fresh.1,
           let pairing = try? readPairing(), pairing.peerMemberID == memberID {
            let chip = report.mac.chip.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
                .map(String.init).joined()
            let gigabytes = report.mac.physicalMemoryBytes >> 30
            return String("\(chip.isEmpty ? "Mac" : chip), \(gigabytes) GB".prefix(ClusterPairingPolicy.maximumNameBytes))
        }
        return leadership?.peerName ?? "the other Mac"
    }

    /// The active cable port when Darkbloom has not set it up (its own network service with the fixed address).
    static func unsetCablePort(_ report: ClusterLinkReadinessReport) -> String? {
        let active = report.devices.filter(\.portActive)
        guard active.count == 1, let device = active.first, let interface = device.interface,
              let isolation = device.isolation, !isolation.clusterServicePresent else { return nil }
        return isolation.hardwarePort.map { "\($0) (\(interface))" } ?? interface
    }

    func resume() -> ClusterOnboardingResume {
        guard let leadership, let role = ClusterOnboardingRole(rawValue: leadership.role),
              let pairing = try? readPairing(), pairing.peerPin == leadership.peerPin else { return .init() }
        // After onboarding the role is the derived control leadership, not who drove the screens.
        let record = try? store.readRecord()
        guard let claim = record?.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID) else {
            var resume = ClusterOnboardingResume(role: role, peerName: peerName, serving: leadership.serving, modelName: leadership.modelName)
            resume.scope = leadership.scope
            return resume
        }
        let leads = claim.leaderID == pairing.localMemberID
        var resume = ClusterOnboardingResume(role: leads ? .leader : .member, peerName: peerName, serving: leadership.serving,
                                             modelName: leadership.modelName)
        resume.unsetCablePort = Self.unsetCablePort(ClusterLinkReadinessProbe.inspectLocalLink())
        resume.scope = leadership.scope
        resume.leaderName = leads ? nil : leaderName
        resume.leaderReason = claim.reason
        resume.term = claim.term
        resume.localLine = ClusterService.published()?.control?.line
        return resume
    }

    // MARK: - Where a command runs (the derived control leader)

    /// The control leader's name as this Mac knows it.
    var leaderName: String {
        guard let record = try? store.readRecord(), let claim = currentClaim(record) else { return peerName }
        return record.control?.members.first { $0.memberID == claim.leaderID }?.name ?? peerName
    }

    /// The recorded claim while it belongs to the current pairing (never one of an earlier pairing with another Mac).
    func currentClaim(_ record: ClusterSetupRecord?) -> ClusterControlClaim? {
        guard let pairing = try? ClusterSetupLinkExchange.pairing() else { return nil }
        return record?.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID)
    }

    func route() -> ClusterControlRouting.Route {
        guard let pairing = try? ClusterSetupLinkExchange.pairing() else { return .local }
        if let claim = currentClaim(try? store.readRecord()) { return ClusterControlRouting.route(localID: pairing.localMemberID, claim: claim) }
        return leadership?.role == ClusterOnboardingRole.member.rawValue ? .forward(to: pairing.peerMemberID) : .local
    }

    var forwards: Bool { if case .forward = route() { return true } else { return false } }

    /// Before this Mac acts as the leader (reaches the members to choose a model, adopts a setup, starts or stops the
    /// cluster): while its saved claim says it leads, wait until its cluster service confirmed that claim with the
    /// members, or the confirmation window passed with none reachable. A restarted Mac whose claim was superseded
    /// steps down meanwhile, and the command is then forwarded to the current leader instead of running here.
    func awaitConfirmedLeadership(seconds: Double = ClusterService.leaseTTLSeconds + 10) -> ClusterOnboardingFailure? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            guard case .local = route(), let pairing = try? ClusterSetupLinkExchange.pairing(),
                  currentClaim(try? store.readRecord())?.leaderID == pairing.localMemberID else { return nil }
            if let control = ClusterService.publishedLive()?.control, control.leads, control.confirmed == true { return nil }
            guard Date() < deadline else {
                return .init("This Mac's leadership is not confirmed yet (its cluster service has not heard from \(peerName) and the \(Int(ClusterService.leaseTTLSeconds)) s window has not passed); run `darkbloom cluster` again in a moment.")
            }
            usleep(250_000)
        }
    }

    /// Runs `request` on the control leader over the link control channel and returns its answer as it is.
    func forward(_ request: ClusterControlRequest, seconds: Double = 60) -> Result<ClusterControlReply, ClusterOnboardingFailure> {
        forwardReply(request, seconds: seconds).flatMap { $0.failed ? .failure(.init($0.lines)) : .success($0) }
    }

    /// Runs one `darkbloom cluster` command where the control leader is now. `acting` (a model change, a start, a stop):
    /// only once this Mac's own leadership is confirmed when it leads. When leadership moves while the command is sent
    /// (a hand-over finishing on the other Mac), the Mac that no longer leads runs nothing and says so (`notLeader`), and
    /// the command is routed again (up to 3 more times, 2 s apart) instead of failing or running where nobody leads.
    func routed<T>(_ request: ClusterControlRequest, seconds: Double = 60, acting: Bool, forwarding: (() -> Void)? = nil,
                   local: () -> Result<T, ClusterOnboardingFailure>, remote: (ClusterControlReply) -> T) -> Result<T, ClusterOnboardingFailure> {
        var moved: ClusterOnboardingFailure?
        for attempt in 0..<4 {
            if attempt > 0 { sleep(2) }
            if acting, let failure = awaitConfirmedLeadership() { return .failure(failure) }
            if !forwards {
                guard acting else { return local() }
                // Acting here: hold this Mac's command lock (the service never hands leadership over meanwhile), and
                // run only if this Mac still leads once it is held (a hand-over may have finished while it waited).
                guard let held = ClusterControlCommandLock.acquire(seconds: 600) else {
                    return .failure(.init("Another cluster command is still running on this Mac; run `darkbloom cluster` again."))
                }
                defer { held.release() }
                if !forwards { return local() }
                continue
            }
            if context.settings.privateImageQualification {
                return .failure(.init("Control leadership moved; rerun private image qualification on the current leader. The selection was not forwarded."))
            }
            forwarding?()
            switch forwardReply(request, seconds: seconds) {
            case .success(let reply) where reply.failed && reply.notLeader == true: moved = .init(reply.lines)
            case .success(let reply): return reply.failed ? .failure(.init(reply.lines)) : .success(remote(reply))
            case .failure(let failure): return .failure(failure)
            }
        }
        return .failure(moved ?? .init("The control leader kept changing; run `darkbloom cluster` again."))
    }

    /// The leader's reply as it came, failed or not.
    func forwardReply(_ request: ClusterControlRequest, seconds: Double) -> Result<ClusterControlReply, ClusterOnboardingFailure> {
        guard case .forward(let to) = route() else { return .failure(.init("This Mac leads: nothing to forward.")) }
        guard let pairing = try? ClusterSetupLinkExchange.pairing(), pairing.peerMemberID == to else {
            return .failure(.init("The control leader is not the Mac this one paired with (forwarding to a third Mac is not built)."))
        }
        do {
            let data = try command(.init(op: .control, control: request), seconds: seconds)
            return .success(try JSONDecoder().decode(ClusterControlReply.self, from: data))
        } catch let failure as ClusterSetupFailure {
            return .failure(.init(["\(leaderName) did not answer over the cable: \(failure.text)", Self.localNetworkHint(leaderName)]))
        } catch {
            return .failure(.init(["\(leaderName) did not answer over the cable: \(error)", Self.localNetworkHint(leaderName)]))
        }
    }

    /// The leader's half: one forwarded command, run here as `darkbloom cluster` would run it on this Mac.
    func execute(_ request: ClusterControlRequest, leaderID: String) -> ClusterControlReply {
        lock.withLock { answeringForward = true }
        defer { lock.withLock { answeringForward = false } }
        func lines(_ result: Result<[String], ClusterOnboardingFailure>) -> ClusterControlReply {
            switch result {
            case .success(let lines): return .init(lines: lines, failed: false, leaderID: leaderID)
            case .failure(let failure): return .init(lines: failure.lines, failed: true, leaderID: leaderID)
            }
        }
        switch request.op {
        case .status: return .init(lines: localStatus(), failed: false, leaderID: leaderID)
        case .reachMembers:
            switch localReachMembers({ _ in }) {
            case .success(let machines): return .init(lines: [], failed: false, leaderID: leaderID, machines: machines)
            case .failure(let failure): return .init(lines: failure.lines, failed: true, leaderID: leaderID)
            }
        case .planModels:
            switch localPlanModels() {
            case .success(let choices): return .init(lines: [], failed: false, leaderID: leaderID, choices: choices)
            case .failure(let failure): return .init(lines: failure.lines, failed: true, leaderID: leaderID)
            }
        case .adopt: return lines(localAdopt(request.index ?? -1, model: request.model))
        case .serve: return lines(localServe())
        case .stop: return lines(localStop())
        case .readiness:
            let once = readinessOnce()
            return .init(lines: [], failed: false, leaderID: leaderID, ready: once.ready, progress: once.line)
        case .test: return lines(localTestRequest())
        case .verifyTeardown: return lines(localVerifyTeardown())
        case .scope:
            guard let scope = request.scope else { return lines(.failure(.init("No way of serving was named, or its address is not one the API takes."))) }
            return lines(localSetScope(scope))
        }
    }

    // MARK: - Checks and the one approval

    /// The cable port the person chose on screen when more than one was active (by interface).
    private var chosenPort: String?

    func useLinkPort(_ interface: String) { lock.withLock { chosenPort = interface } }

    func checkLink(_ say: @escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult {
        // The device behind the chosen interface, read fresh (names come from validated tool output).
        let chosen = lock.withLock { chosenPort }
        var device: String?
        var last: ClusterLinkReadinessReport?
        if let chosen {
            let report = ClusterLinkReadinessProbe.inspectLocalLink()
            device = report.devices.first { $0.interface == chosen }?.device
        }
        var flow = ClusterLinkSetupFlow(mayPrompt: true, device: device, plain: true)
        var step = flow.begin()
        let started = Date()
        while true {
            for line in step.lines { say(line) }
            switch step.action {
            case .inspect:
                let report = ClusterLinkReadinessProbe.inspectLocalLink()
                last = report
                step = flow.observed(report)
            case .awaitConnection:
                var report: ClusterLinkReadinessReport
                repeat {
                    sleep(2)
                    report = ClusterLinkReadinessProbe.inspectLocalLink()
                } while report.state == last?.state && Date().timeIntervalSince(started) < 600
                last = report
                step = Date().timeIntervalSince(started) < 600 ? flow.observed(report) : flow.interrupted()
            case .awaitKeeper:
                sleep(UInt32(ClusterLinkSetupFlow.keeperWaitSeconds))
                let report = ClusterLinkReadinessProbe.inspectLocalLink()
                last = report
                step = flow.observed(report)
            case .fix(let device):
                // The one macOS approval; where no prompt can show, one owner-only script and one line to run.
                say("Darkbloom needs network access for the cluster cable: approve the macOS prompt (once per Mac).")
                let result = ClusterLinkRepair.fix(device: device, mode: .durable, dryRun: false)
                if let script = result.manualScript {
                    say("No macOS prompt can show here. Run this one line once, as an administrator, then run `darkbloom cluster` again:")
                    say("  sudo sh \(script)")
                }
                step = flow.repaired(result)
            case .finish(let code):
                if !flow.choices.isEmpty { return .init(ready: false, exitCode: max(code, 1), ports: flow.choices.map { $0.interface }) }
                guard code == 0, flow.linkState == .ready else { return .init(ready: false, exitCode: max(code, 1)) }
                // A port isolated as link setup v2 leaves it but with no record (an administrator ran the commands
                // by hand): recorded now, with no prompt and no change, so the earlier settings can be restored.
                if let ready = last?.devices.first(where: { $0.portActive && $0.verdict == .ready && (device == nil || $0.device == device) }),
                   ready.isolation?.isolated == true {
                    _ = ClusterLinkRepair.fix(device: ready.device, mode: .durable, dryRun: false)
                }
                return .init(ready: true, exitCode: 0)
            }
        }
    }

    // MARK: - Discovery and pairing

    /// How long pairing waits for the cable port's address before it says to try again.
    static let cableAddressWaitSeconds: Double = 20

    func pair(_ events: @escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult {
        let pairingStore = ClusterPairingStore.default()
        let identity: any ClusterPairingIdentity
        do { identity = try ClusterPairingProvider.identity() } catch { return .failed(["\(error)"]) }
        // The port's address arrives a moment after the link setup applied it (or after the cable moved): wait for it.
        var interface: String?
        let deadline = Date().addingTimeInterval(Self.cableAddressWaitSeconds)
        repeat {
            interface = try? ClusterPairCommandLine.resolveInterface(ClusterPairCommandRequest(), peer: nil)
            if interface == nil { sleep(1) }
        } while interface == nil && Date() < deadline
        guard let interface else {
            return .failed(["The cable has no address on this Mac yet. Run `darkbloom cluster` again in a moment;"
                + " if this repeats, run `darkbloom cluster doctor` and check the cable on both Macs."])
        }
        let chipName = (try? HardwareDetector.detect().chipName) ?? "Mac"
        let participant = ClusterPairingProvider.participant(identity: identity, chipName: chipName, interface: interface,
            store: pairingStore, clusterID: nil)
        var options = ClusterLinkPairing.Options(role: .listener, interface: interface)
        // Find a Mac waiting on the cable and join it; when none waits, wait here and lead.
        options.discovery = .find
        let callbacks = ClusterLinkPairing.Callbacks(progress: { progress in
            switch progress {
            case .searching: events(.searching)
            case .listening: events(.waitingAsLeader)
            case .dialing: events(.joining)
            case .connected: events(.connected)
            case .refused(let reason): events(.note("The cable connection was refused (\(reason)); still trying…"))
            case .storing: events(.note("Pinning each other's Secure Enclave keys (owner-only files)…"))
            }
        }, askConfirmation: { [self] code, peer, respond in
            let early: Bool? = lock.withLock {
                self.respond = respond
                defer { pendingAnswer = nil }
                return pendingAnswer
            }
            let posture = peer.posture
            let security = [posture.sipEnabled ? "SIP on" : "SIP OFF", posture.secureBootEnabled ? "Secure Boot full" : "Secure Boot reduced",
                            posture.authenticatedRootEnabled ? "sealed system volume" : "system volume NOT sealed"].joined(separator: ", ")
            events(.code(code, peer: [peer.name, "\(posture.hardwareModel), macOS \(posture.osVersion); \(security)",
                                      "Secure Enclave key pin \(peer.pin.prefix(16))…"]))
            if let early { answer(early) }
        }, peerDecided: { events(.peerDecided($0)) })
        let result = ClusterLinkPairing.run(options: options, participant: participant, hooks: ClusterPairingProvider.hooks,
            store: pairingStore, callbacks: callbacks)
        lock.withLock { respond = nil; pendingAnswer = nil }
        switch result {
        case .success(let paired):
            let record = paired.record
            let role: ClusterOnboardingRole = record.role == .listener ? .leader : .member
            do {
                guard let localPin = try pairingStore.load()?.localPin else { return .failed(["The pairing was not stored."]) }
                try store.updateRecord {
                    $0.leadership = .init(role: role.rawValue, leaderPin: role == .leader ? localPin : record.peerPin,
                        peerPin: record.peerPin, peerName: record.peerName, since: ClusterConsoleText.timestamp())
                }
            } catch { return .failed(["The pairing is stored, but who leads could not be recorded: \(error)"]) }
            return .paired(role: role, peerName: record.peerName)
        case .failure:
            return .failed(ClusterPairingTerminal.summary(result))
        }
    }

    func answer(_ accept: Bool) {
        let current: (@Sendable (Bool) -> Void)? = lock.withLock {
            defer { respond = nil }
            if respond == nil { pendingAnswer = accept }
            return respond
        }
        current?(accept)
    }

    // MARK: - The cluster service

    /// The service was installed as a login agent in this run (nil: not yet asked; false: session only).
    private var serviceAtLogin: Bool?

    /// What this Mac does after a restart, from its auto-login and FileVault settings (read, never changed).
    func restartLine(mac: String = "this Mac") -> String {
        ClusterOnboardingRestart.line(mac: mac, autoLogin: AttestationReadiness.configuredAutoLoginUser() != nil, fileVault: Self.fileVaultOn())
    }

    /// `fdesetup isactive` (no privileges needed): true when FileVault is on; nil when it could not be read.
    static func fileVaultOn() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["isactive"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        guard !process.isRunning else { process.terminate(); process.waitUntilExit(); return nil }
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    func afterRestart() -> String? {
        lock.withLock { serviceAtLogin } == true ? restartLine() : nil
    }

    /// Installs this Mac's cluster service as its login agent (it starts at login, and its supervisor restarts it
    /// with backoff), idempotently, and says what happens after a restart. Where launchd cannot take the job, the
    /// service still starts for this session, and the screen says it will not come back by itself.
    func ensureService() -> Result<String, ClusterOnboardingFailure> {
        let executable = settings.service.wizard.darkbloomExecutable
        let arguments = settings.serviceArguments
        let options = Array(arguments.starts(with: ["cluster", "service"]) ? arguments.dropFirst(2) : arguments[...])
        // A login agent this build's launchd job runs could not reach the other Mac (no one-time Local Network
        // approval for an ad-hoc build or one outside the signed app): keep the service in this session instead.
        let identity = ClusterMemberPermissionIdentity.current(executablePath: ClusterService.resolvedExecutable(executable))
        if let refusal = identity.launchdLinkRefusal {
            lock.withLock { serviceAtLogin = false }
            return sessionService(executable: executable, arguments: arguments,
                                  reason: refusal + "; install the signed Darkbloom release for a service that starts at login")
        }
        do {
            let outcome = try ClusterService.installAtLogin(executable: executable, serviceOptions: options)
            lock.withLock { serviceAtLogin = true }
            switch outcome {
            case .installed, .replaced:
                return .success("Started this Mac's cluster service: it runs this Mac's part whenever the cluster serves. " + restartLine())
            case .restarted:
                return .success("Restarted this Mac's cluster service. " + restartLine())
            case .unchanged:
                return .success("This Mac's cluster service is running. " + restartLine())
            }
        } catch let agentError {
            lock.withLock { serviceAtLogin = false }
            return sessionService(executable: executable, arguments: arguments, reason: Self.reason(agentError))
        }
    }

    /// The service for this session only (no login agent). The screen says what to do after a restart; why it cannot
    /// start at login (`reason`, e.g. an ad-hoc signed build) goes to the service log, not the screen.
    private func sessionService(executable: URL, arguments: [String], reason: String) -> Result<String, ClusterOnboardingFailure> {
        do {
            let started = try ClusterService.ensureRunning(executable: executable, arguments: arguments)
            // Once per service start, not on every `darkbloom cluster`.
            if started { Self.logLoginAgentReason(reason) }
            return .success((started ? "Started this Mac's cluster service" : "This Mac's cluster service is running")
                + " for this development session; it is not installed at login. "
                + "Keep the originating Terminal or SSH session open: a detached service can lose Local Network access "
                + "when that session closes. Use a signed Darkbloom.app for reliable background serving.")
        } catch let failure as ClusterOnboardingFailure {
            return .failure(failure)
        } catch {
            return .failure(.init("\(error)"))
        }
    }

    /// Said when the other Mac's service does not answer: a denied Local Network prompt there is the usual cause on a
    /// fresh pair, and nothing else would tell the person where to undo it.
    static func localNetworkHint(_ mac: String) -> String {
        "If you denied the Local Network prompt on \(mac), allow Darkbloom in System Settings → Privacy & Security → Local Network there, then run `darkbloom cluster` again."
    }

    static func reason(_ error: Error) -> String {
        (error as? ClusterOnboardingFailure)?.lines.joined(separator: " ") ?? "\(error)"
    }

    /// Why the service runs for this session only, appended to its log (`~/.darkbloom/cluster-setup/service.log`,
    /// opened append-only because the running service writes there too).
    static func logLoginAgentReason(_ reason: String) {
        guard let log = try? ClusterService.paths().log else { return }
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) onboarding: the cluster service does not start at login: "
            + ClusterConsoleText.bounded(reason, maximum: 300) + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - The leader

    func reachMembers(_ say: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure> {
        let local = (try? ClusterSetupLinkExchange.pairing())?.localMemberID
        return routed(.init(op: .reachMembers), seconds: 150, acting: true, forwarding: { say("Asking the control leader, \(self.leaderName), over the cable…") },
                      local: { localReachMembers(say) }) { reply in
            (reply.machines ?? []).map { machine in
                var machine = machine
                machine.here = machine.memberID != nil && machine.memberID == local
                return machine
            }
        }
    }

    func localReachMembers(_ say: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure> {
        let deadline = Date().addingTimeInterval(120)
        var lastReason: String?
        var reached: (ClusterSetupReport, Double)?
        while reached == nil {
            switch context.reachPeer() {
            case .reached(let report, let seconds): reached = (report, seconds)
            case .failed(let reason):
                if reason != lastReason { say("Waiting for \(peerName)'s cluster service: \(reason)"); lastReason = reason }
                guard Date() < deadline else {
                    return .failure(.init(["\(peerName) did not answer over the cable within 2 minutes: \(reason)", Self.localNetworkHint(peerName)]))
                }
                sleep(3)
            }
        }
        let (peer, seconds) = reached!
        rememberPeerReport(peer, memberID: context.peerFacts?.memberID)
        say("\(peerName) answered over the cable in \(String(format: "%.1f", seconds)) s.")
        let local = context.snapshot().local
        func machine(_ report: ClusterSetupReport, name: String, leads: Bool, memberID: String?, here: Bool) -> ClusterOnboardingMachine {
            .init(name: name, memoryGB: report.mac.physicalMemoryBytes >> 30, gpuCores: report.mac.profile?.gpuCores, leads: leads,
                models: report.models.count, memberID: memberID, here: here)
        }
        let pairing = try? ClusterSetupLinkExchange.pairing()
        return .success([machine(local, name: ClusterPairingProvider.displayName(chipName: local.mac.chip), leads: true,
                                 memberID: pairing?.localMemberID, here: true),
                         machine(peer, name: peerName, leads: false, memberID: pairing?.peerMemberID, here: false)])
    }

    /// Reports enter here only after the setup exchange has authenticated the peer.
    /// Keep its member identity with the display facts so another pairing cannot reuse them.
    func rememberPeerReport(_ report: ClusterSetupReport, memberID: String?) {
        lock.withLock {
            peerReport = report
            peerReportMemberID = memberID
            peerReportAt = Date()
        }
    }

    func planShares(_ ranks: [ClusterSetupPlanSummary.Rank], localName: String) -> [ClusterOnboardingDeployment.Share] {
        ranks.sorted { $0.rank < $1.rank }.map { rank in
            .init(name: rank.local ? localName : peerName, layers: rank.endLayer - rank.firstLayer,
                  weightsBytes: rank.weightsBytes)
        }
    }

    func planModels() -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
        let result = routed(.init(op: .planModels), seconds: 240, acting: false, local: { localPlanModels() }) { $0.choices ?? [] }
        if case .success(let listed) = result { lock.withLock { listedChoices = listed } }
        return result
    }

    /// `keeping`: the mode each model id keeps (`LiveContext.plan`); the service's re-plan after an update passes the
    /// mode the pair served the model in.
    func localPlanModels(keeping: [String: ClusterGenerationMode] = [:]) -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
        // The plan judges each Mac by the memory its report sampled. A report taken before this Mac stopped the
        // cluster's parts still counts the other Mac's old part (the re-plan after an update stops them first):
        // ask again, so both Macs are priced with that memory given back. 2026-10-22: the other Mac's report was
        // taken while its tensor-parallel part still held 98 GB, its share of tensor parallel looked 6 GB short,
        // and the update came back as a pipeline at half the speed.
        let stale = lock.withLock { !ClusterOnboardingUpdate.reportPricesPlan(reportedAt: peerReportAt, partsStoppedAt: partsStoppedAt) }
        if stale, case .failure(let failure) = localReachMembers({ _ in }) { return .failure(failure) }
        guard let peer = lock.withLock({ peerReport }) else { return .failure(.init("The other Mac has not answered yet.")) }
        // The models single-Mac Darkbloom installed on this Mac are cluster models too (cloned in: no new blocks), when a
        // pair may serve them with this build (as for models copied from the other Mac or downloaded).
        let store = URL(fileURLWithPath: context.modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path)
        // Every model's own pages out of the file cache first: the plan judges each Mac by what its load gate counts,
        // and a model's pages left active by a download or a copy are not counted (nor needed: a load reads them back).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [] where !name.hasPrefix(".") {
            ClusterModelStore.dropCachedPages(folder: store.appendingPathComponent(name))
        }
        for installed in ClusterProductModelStore.installed() where ClusterModelCopyTrust.servableArtifacts.contains(installed.artifact.aggregateSHA256) {
            ClusterModelStore.dropCachedPages(folder: installed.directory)
            _ = try? ClusterProductModelStore.cloneIntoClusterStore(installed, store: store, providerConfiguration: settings.service.wizard.providerConfiguration,
                                                                    accepts: context.workerAcceptsManifest)
        }
        switch context.plan(peer: peer, keeping: keeping) {
        case .failed(let reason): return .failure(.init("Planning failed: \(reason)"))
        case .ready(let options):
            let localName = ClusterPairingProvider.displayName(chipName: context.snapshot().local.mac.chip)
            // The catalog, fetched once: each model is shown by its display name (its id when the catalog has none or
            // does not answer), and the catalog's downloadable models are offered below.
            // Private qualification only uses the already-present immutable artifact.
            let catalogAll = context.settings.privateImageQualification ? [] : fetchCatalog()
            let names = Dictionary(catalogAll.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            // A folder whose manifest id is not a catalog id (an EigenLabs repository id) holds that catalog entry's
            // bytes when its aggregate is the entry's: it is shown by that entry's name.
            let namesByArtifact = Dictionary(catalogAll.compactMap { model in model.aggregateSHA256.map { ($0, model.displayName) } },
                                             uniquingKeysWith: { first, _ in first })
            var keys = [(folder: String, key: String, title: String, alone: [String], deployment: String?, plan: ClusterSetupPlanSummary?)]()
            let choices = options.map { option -> ClusterOnboardingModelChoice in
                let gigabytes = String(format: "%.1f GB", Double(option.model.totalBytes) / 1e9)
                let modelID = option.model.modelID
                let title = ClusterOnboardingDeployment.title(modelID: modelID, displayNames: names[modelID] == nil
                    ? namesByArtifact[option.model.artifactSHA256].map { [modelID: $0] } ?? [:] : names)
                guard let plan = option.plan else {
                    keys.append((option.model.folder, "", modelID, [], nil, nil))
                    return .init(title: title, lines: [], blocker: option.blocker ?? "Not offered on these Macs.", modelID: modelID)
                }
                let offer = option.onOtherMac != false ? nil : copyOffer(model: option.model, peer: peer, localName: localName)
                // One line: size, how it is split (the planner's choice), each Mac's share, the expected speed.
                let shares = planShares(plan.ranks, localName: localName)
                let speed = plan.absolute ? "about \(Int(plan.decodeTokensPerSecond.rounded())) tokens/s\(plan.measured ? "" : " (estimate)")" : nil
                let line = ClusterOnboardingDeployment.choiceLine(size: gigabytes, mode: plan.mode, shares: shares, speed: speed)
                let deployment = ClusterOnboardingDeployment.line(model: title, mode: plan.mode, shares: shares)
                keys.append((option.model.folder, ClusterSetupState.planKey(option.model, plan), modelID, plan.alone.filter(\.holds).map(\.memberID),
                             deployment, plan))
                // A running model is stopped (its memory released) before a new one starts, so its memory is no reason here.
                let remedy = leadership?.serving == true || plan.fitsNow ? nil : Self.fitRemedy(plan, localName: localName, peerName: peerName)
                // Served for the owner either way. Once chosen: the planner's one-line reason for tensor parallel or
                // a pipeline, and (serving through Darkbloom) whether public traffic may reach it yet.
                return .init(title: title, lines: [line] + (plan.modeReason.map { [$0] } ?? []),
                             blocker: option.blocker, provision: offer, fitRemedy: remedy, modelID: modelID,
                             publicTraffic: context.settings.privateImageQualification
                                ? "Private unqualified image candidate; public traffic is prohibited." : plan.publicTraffic)
            }
            // Open choices first (the models this Mac has), then catalog models no Mac has yet, then the blocked ones.
            var ordered = [(ClusterOnboardingModelChoice, (folder: String, key: String, title: String, alone: [String], deployment: String?, plan: ClusterSetupPlanSummary?))]()
            let pairs = Array(zip(choices, keys))
            ordered += pairs.filter { $0.0.blocker == nil }
            var catalog = [Int: CatalogModel](), fromPeer = [Int: ClusterSetupLocalModel]()
            var held = Set((options.map(\.model.artifactSHA256)))
            // Models only the other Mac has: it copies them here over the cable, then this Mac plans them. Only those a
            // pair may serve with this build (its qualification records), so nobody waits for bytes these Macs could not serve.
            var offered = options.map(\.model)
            for model in peer.models where !context.settings.privateImageQualification
                && !offered.contains(where: { $0.sameEntry(model) })
                && ClusterModelCopyTrust.servableArtifacts.contains(model.artifactSHA256) {
                held.insert(model.artifactSHA256)
                offered.append(model)
                fromPeer[ordered.count] = model
                let plan = ClusterModelProvisioning.plan(totalBytes: model.totalBytes,
                    leader: .init(name: leaderLabel(localName), holding: .missing, freeBytes: ClusterModelStore.freeBytes(at: ClusterModelStoreLocation.defaultDirectory())),
                    members: [.init(name: peerName, holding: .complete(folder: model.folder), freeBytes: nil)],
                    linkBytesPerSecond: measuredCopyRate, catalogHasIt: false)
                ordered.append((.init(title: ClusterOnboardingDeployment.title(modelID: model.modelID, displayNames: names),
                    lines: ["\(ClusterModelProvisioning.gigabytes(model.totalBytes)) · only on \(peerName): copied over the cable first"], blocker: nil,
                    provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
                        quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan)), modelID: model.modelID),
                    (model.folder, "", model.modelID, [], nil, nil)))
            }
            for model in catalogModels(catalogAll, peer: peer) where !held.contains(model.aggregateSHA256 ?? "")
                && ClusterModelCopyTrust.servableArtifacts.contains(model.aggregateSHA256 ?? "") {
                catalog[ordered.count] = model
                ordered.append((downloadChoice(model, peer: peer, localName: localName), ("", "", model.id, [], nil, nil)))
            }
            ordered += pairs.filter { $0.0.blocker != nil }
            lock.withLock { self.choices = ordered.map(\.1); self.catalogChoices = catalog; self.peerChoices = fromPeer }
            return .success(ordered.map(\.0))
        }
    }

    /// What frees the memory a plan needs, in plain words, per Mac that is short now (from the planner's fit).
    static func fitRemedy(_ plan: ClusterSetupPlanSummary, localName: String, peerName: String) -> String? {
        let words = plan.ranks.compactMap { rank -> String? in
            let mac = rank.local ? localName : peerName
            switch rank.fit {
            // The gate counts less than macOS would give (files it keeps in memory): the part's load lets the kernel
            // drop that cache first (`QwenDenseStageLoadReclaim`), so it fits. A restart is said only when nothing
            // else could free enough.
            case "now", "gateCountsLess": return nil
            case "afterApplicationsRelease": return "Quit apps on \(mac) first."
            case "never": return "\(mac) cannot hold its part at all."
            default: return "Restart \(mac) to free memory."
            }
        }
        var unique = [String]()
        for word in words where !unique.contains(word) { unique.append(word) }
        return unique.isEmpty ? nil : unique.joined(separator: " ")
    }

    /// The same words from a fit measured now.
    static func remedy(_ fit: ClusterPlacementFit, mac: String) -> String? {
        switch fit {
        case .now, .gateCountsLess: return nil
        case .afterApplicationsRelease: return "Quit apps on \(mac) first."
        case .afterRestart: return "Restart \(mac) to free memory."
        case .never: return "\(mac) cannot hold its part at all."
        }
    }

    /// Right before the start: each Mac's memory measured again against what its part needs (memory moves while the
    /// person reads the list). Nil when it fits, or when a running model is stopped first (its memory comes back).
    func recheckFit(_ index: Int) -> String? {
        guard !forwards, leadership?.serving != true,
              let plan = lock.withLock({ choices.indices.contains(index) ? choices[index].plan : nil }) else { return nil }
        let local = context.snapshot().local.mac
        let localName = ClusterPairingProvider.displayName(chipName: local.chip)
        let localProfile = local.profile
        var peerProfile: ClusterDeviceProfile?
        if case .reached(let report, _) = context.reachPeer() {
            rememberPeerReport(report, memberID: context.peerFacts?.memberID)
            peerProfile = report.mac.profile
        }
        let words = plan.ranks.compactMap { rank -> String? in
            guard let profile = rank.local ? localProfile : peerProfile else { return nil }
            return Self.remedy(profile.memory.fit(rank.needBytes), mac: rank.local ? localName : peerName)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: - Provisioning: no manual model downloads

    var copyRateFile: URL { store.paths.directory.appendingPathComponent("model-copy-rate.txt") }

    /// The last copy rate measured over this cable (bytes per second), for the time estimate; nil before the first copy.
    var measuredCopyRate: Double? {
        guard let data = ClusterModelStore.readSmall(copyRateFile), let value = Double(String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    func holding(_ model: ClusterSetupLocalModel, in report: ClusterSetupReport) -> ClusterModelHolding {
        report.models.first { $0.sameEntry(model) }.map { .complete(folder: $0.folder) } ?? .missing
    }

    /// The leading Mac as a copy or download line names it: "(this Mac)" only on its own screen, never in an answer a
    /// member shows (that screen is the other Mac).
    func leaderLabel(_ localName: String) -> String {
        here == "this Mac" ? "\(localName) (this Mac)" : localName
    }

    func copyOffer(model: ClusterSetupLocalModel, peer: ClusterSetupReport, localName: String) -> ClusterOnboardingProvisionOffer {
        let plan = ClusterModelProvisioning.plan(totalBytes: model.totalBytes,
            leader: .init(name: leaderLabel(localName), holding: .complete(folder: model.folder), freeBytes: nil),
            members: [.init(name: peerName, holding: holding(model, in: peer), freeBytes: peer.modelStoreFreeBytes)],
            linkBytesPerSecond: measuredCopyRate, catalogHasIt: true)
        return .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: false, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan))
    }

    func downloadChoice(_ model: CatalogModel, peer: ClusterSetupReport, localName: String) -> ClusterOnboardingModelChoice {
        let bytes = model.totalSizeBytes ?? Int64(model.sizeGb * 1e9)
        let local = ClusterModelStoreLocation.defaultDirectory()
        let plan = ClusterModelProvisioning.plan(totalBytes: bytes,
            leader: .init(name: leaderLabel(localName), holding: .missing, freeBytes: ClusterModelStore.freeBytes(at: local)),
            members: [.init(name: peerName, holding: .missing, freeBytes: peer.modelStoreFreeBytes)],
            linkBytesPerSecond: measuredCopyRate, catalogHasIt: true)
        return .init(title: ClusterOnboardingDeployment.title(modelID: model.id, displayNames: [model.id: model.displayName]),
            lines: ["\(ClusterModelProvisioning.gigabytes(bytes)) · not on these Macs: downloaded from Darkbloom's catalog first"],
            blocker: nil, provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan)), modelID: model.id)
    }

    /// Darkbloom's catalog of text models, as single-Mac Darkbloom reads it. When it does not answer within a few
    /// seconds (a Mac still busy after a restart, no network), the last list it gave is used, so models and their
    /// names do not vanish from the screen; empty only before the first answer.
    func fetchCatalog() -> [CatalogModel] {
        let saved = store.paths.directory.appendingPathComponent("catalog.json")
        func last() -> [CatalogModel] {
            guard let data = ClusterModelStore.readSmall(saved) else { return [] }
            return (try? JSONDecoder().decode([CatalogModel].self, from: data)) ?? []
        }
        guard let config = try? ConfigManager.loadOrDefaults(from: settings.service.wizard.providerConfiguration) else { return last() }
        let client = ModelCatalogClient(coordinatorURL: config.coordinator.url)
        let box = ClusterOnboardingMailbox<[CatalogModel]>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.post((try? await client.fetchCatalog(typeFilter: "text")) ?? []); done.signal() }
        guard done.wait(timeout: .now() + 10) == .success, let models = box.take().first, !models.isEmpty else { return last() }
        if let data = try? JSONEncoder().encode(models) { try? data.write(to: saved, options: [.atomic]) }
        return models
    }

    /// The catalog models this Mac could fetch for the cluster (a verified manifest, small enough for both Macs'
    /// memory together); empty when the catalog does not answer within a few seconds.
    func catalogModels(_ models: [CatalogModel], peer: ClusterSetupReport) -> [CatalogModel] {
        let memory = Double(context.snapshot().local.mac.physicalMemoryBytes + peer.mac.physicalMemoryBytes)
        return models.filter { $0.r2Prefix != nil && $0.aggregateSHA256 != nil && Double($0.totalSizeBytes ?? Int64($0.sizeGb * 1e9)) < memory * 0.75 }
            .sorted { ($0.totalSizeBytes ?? 0) < ($1.totalSizeBytes ?? 0) }.prefix(32).map { $0 }
    }

    func provision(_ index: Int, download: Bool, _ progress: @escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure> {
        var index = index
        // A list made on the control leader (this Mac forwarded `planModels`) holds no choices here. Getting the files
        // onto both Macs needs no leadership: this Mac plans the same models itself and fetches the one the list showed
        // (by id); the adopt then runs on the leader, which finds it on both Macs. ("Nothing to copy: plan again." on
        // an M4 Max member, 2026-10-16.)
        let listed = lock.withLock { listedChoices.indices.contains(index) ? (listedChoices[index].modelID ?? listedChoices[index].title) : nil }
        if let listed, lock.withLock({ !choices.indices.contains(index) || choices[index].title != listed }) {
            if case .failure(let failure) = localReachMembers({ _ in }) { return .failure(failure) }
            if case .failure(let failure) = localPlanModels() { return .failure(failure) }
            guard let found = lock.withLock({ choices.firstIndex { $0.title == listed } }) else {
                return .failure(.init("\(listed) is not offered on these Macs any more; run `darkbloom cluster` again to choose."))
            }
            index = found
        }
        guard let choice = lock.withLock({ choices.indices.contains(index) ? choices[index] : nil }) else {
            return .failure(.init("Nothing to copy: plan again."))
        }
        let store = URL(fileURLWithPath: context.modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path)
        var lines = [String]()
        var folder = choice.folder
        do {
            if let model = lock.withLock({ peerChoices[index] }) {
                lines.append(try receiveFromPeer(model, store: store, progress: progress))
                if case .reached(let report, _) = context.reachPeer() { lock.withLock { peerReport = report } }
                return .success(lines)
            }
            if let model = lock.withLock({ catalogChoices[index] }) {
                folder = try downloadOnThisMac(model, store: store, progress: progress)
                lines.append("\(model.id) is on this Mac now (downloaded from Darkbloom's catalog and verified, as `darkbloom` downloads models).")
            }
            let manifest = store.appendingPathComponent(folder).appendingPathComponent("manifest.json")
            guard let data = ClusterModelStore.readSmall(manifest) else { throw ClusterSetupFailure("this Mac's \(folder) has no readable manifest") }
            let artifact = try ClusterCatalogArtifact.parse(manifest: data)
            if let peer = lock.withLock({ peerReport }),
               peer.models.contains(where: { artifact.sameEntry(modelID: $0.modelID, version: $0.version, aggregate: $0.artifactSHA256)
                   && ($0.filesSHA256 == nil || $0.filesSHA256 == artifact.filesDigest) }) {
                lines.append("\(peerName) has it already (same catalog digest).")
                return .success(lines)
            }
            guard let pairing = try ClusterSetupLinkExchange.pairing() else { throw ClusterSetupFailure("This Mac is not paired.") }
            let selection = try context.linkSelection()
            let name = peerName
            let started = Date()
            let outcome = try ClusterSetupLinkExchange.copyModel(pairing: pairing, selection: selection, peerAddress: nil, artifact: artifact,
                source: store.appendingPathComponent(folder), folder: folder) { sent, total in
                    progress(Self.copyLine(model: artifact.modelID, to: name, sent: sent, total: total, seconds: Date().timeIntervalSince(started)))
                }
            if outcome.alreadyThere {
                lines.append("\(name) has it already (same catalog digest).")
            } else {
                let rate = outcome.seconds > 0 ? Double(outcome.sentBytes) / outcome.seconds : 0
                if rate > 0 { try? Data(String(format: "%.0f", rate).utf8).write(to: copyRateFile, options: .atomic) }
                lines.append("Copied \(ClusterModelProvisioning.gigabytes(outcome.sentBytes)) to \(name) over the Thunderbolt cable in \(String(format: "%.1f", outcome.seconds)) s (\(String(format: "%.2f", rate / 1e9)) GB/s); every file matched the catalog manifest's SHA-256.")
            }
            // The member's answer now lists the model, so the plan and the start see it there.
            if case .reached(let report, _) = context.reachPeer() { lock.withLock { peerReport = report } }
            return .success(lines)
        } catch let failure as ClusterSetupFailure {
            return .failure(.init(lines + [failure.text]))
        } catch {
            return .failure(.init(lines + ["\(error)"]))
        }
    }

    /// "Copying Qwen3.5-9B to Apple M5 Ultra, 256 GB over the Thunderbolt cable: 3.1 of 6.1 GB, 2.40 GB/s, about 1 s left".
    static func copyLine(model: String, to peer: String, sent: Int64, total: Int64, seconds: Double) -> String {
        let rate = seconds > 0 ? Double(sent) / seconds : 0
        let left = rate > 0 && total > sent ? ", " + ClusterModelProvisioning.duration(Double(total - sent) / rate) + " left" : ""
        return "Copying \(model) to \(peer) over the Thunderbolt cable: \(String(format: "%.1f", Double(sent) / 1e9)) of \(ClusterModelProvisioning.gigabytes(total)), \(String(format: "%.2f", rate / 1e9)) GB/s\(left)"
    }

    /// The other Mac sends a model only it has: asked over the link, it copies it into this Mac's store (this Mac's
    /// cluster service verifies every file); this Mac follows the staged bytes for the progress.
    func receiveFromPeer(_ model: ClusterSetupLocalModel, store: URL, progress: @escaping @Sendable (String) -> Void) throws -> String {
        // The other Mac answers once this Mac's service took (or refused) the copy, so a refusal shows at once.
        _ = try command(.init(op: .sendModel, model: model.folder, text: model.artifactSHA256), seconds: 30)
        let started = Date()
        var lastBytes: Int64 = -1, lastChange = Date()
        let deadline = started.addingTimeInterval(120 + Double(model.totalBytes) / 50e6)
        let staging = store.appendingPathComponent(".darkbloom-incoming-" + String(model.artifactSHA256.prefix(32)))
        var lastLine = Date.distantPast
        while Date() < deadline {
            if let data = ClusterModelStore.readSmall(store.appendingPathComponent(model.folder).appendingPathComponent("manifest.json")),
               let artifact = try? ClusterCatalogArtifact.parse(manifest: data),
               artifact.sameEntry(modelID: model.modelID, version: model.version, aggregate: model.artifactSHA256),
               model.filesSHA256 == nil || model.filesSHA256 == artifact.filesDigest {
                let seconds = Date().timeIntervalSince(started)
                return "\(peerName) copied \(ClusterModelProvisioning.gigabytes(model.totalBytes)) of \(model.modelID) to this Mac over the Thunderbolt cable in \(String(format: "%.1f", seconds)) s; every file matched the catalog manifest's SHA-256."
            }
            if Date().timeIntervalSince(lastLine) >= 1 {
                lastLine = Date()
                let bytes = Self.stagedBytes(staging)
                if bytes != lastBytes { lastBytes = bytes; lastChange = Date() }
                // Nothing new staged for 90 s: the other Mac stopped sending (its `darkbloom cluster` service says why).
                if Date().timeIntervalSince(lastChange) > 90 {
                    throw ClusterSetupFailure("\(peerName) stopped sending \(model.modelID) (nothing arrived for 90 s); run `darkbloom cluster` here again (the copy resumes)")
                }
                let seconds = Date().timeIntervalSince(started), rate = seconds > 0 ? Double(bytes) / seconds : 0
                let left = rate > 0 && model.totalBytes > bytes ? ", " + ClusterModelProvisioning.duration(Double(model.totalBytes - bytes) / rate) + " left" : ""
                if bytes > 0 {
                    progress("Receiving \(model.modelID) from \(peerName) over the Thunderbolt cable: \(String(format: "%.1f", Double(bytes) / 1e9)) of \(ClusterModelProvisioning.gigabytes(model.totalBytes)), \(String(format: "%.2f", rate / 1e9)) GB/s\(left)")
                }
            }
            usleep(250_000)
        }
        throw ClusterSetupFailure("\(model.modelID) did not arrive from \(peerName) in time; run `darkbloom cluster` here again (the copy resumes)")
    }

    static func stagedBytes(_ directory: URL) -> Int64 {
        guard let names = FileManager.default.enumerator(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for case let name as String in names {
            var info = stat()
            if lstat(directory.appendingPathComponent(name).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { total += Int64(info.st_size) }
        }
        return total
    }

    /// Downloads a catalog model exactly as single-Mac Darkbloom does (verified manifest, resumable, into the
    /// product's model store), then clones it into the cluster's store. Returns its folder there.
    func downloadOnThisMac(_ model: CatalogModel, store: URL, progress: @escaping @Sendable (String) -> Void) throws -> String {
        var capabilities = (try? HardwareDetector.detect()).map { ProviderRuntimeCapabilityDetector.detectPrepared(hardware: $0, boundMetallibHash: nil) } ?? []
        // The catalog's runtime requirements are single-Mac serving's (Qwen 3.8 27B needs an M5's neural accelerators
        // when one Mac serves it alone). A model this build's cluster runtime serves (its records pin the digest) is
        // the cluster's own: its adapters, grants and memory gates decide, so the leader downloads it whatever its
        // chip (owner: chips never gate what is offered). The single-Mac provider keeps its own check when it loads.
        if let digest = model.aggregateSHA256, ClusterModelCopyTrust.servableArtifacts.contains(digest) {
            capabilities.formUnion(ModelRuntimeRequirements.evaluate(modelID: model.id,
                catalogRequirements: model.requiredProviderCapabilities, available: []).required)
        }
        let catalog = (try? ConfigManager.loadOrDefaults(from: settings.service.wizard.providerConfiguration)).map { ModelCatalogClient(coordinatorURL: $0.coordinator.url) }
        var downloader = ModelDownloader(catalogClient: catalog, runtimeCapabilities: capabilities)
        // Written and verified uncached, like the copy over the cable: a download does not take memory from a model load.
        downloader.uncachedWrites = true
        let started = Date()
        let lastLine = ClusterOnboardingMailbox<Date>()
        let verifying = ClusterOnboardingMailbox<Bool>()
        downloader.byteProgress = { done, total in
            let now = Date()
            if done >= total {
                // Every byte is here; the downloader checks each file and the aggregate digest before it publishes.
                if verifying.take().isEmpty { progress("Downloaded \(ClusterModelProvisioning.gigabytes(total)); checking every file against the catalog manifest…") }
                verifying.post(true)
                return
            }
            if let last = lastLine.take().last, now.timeIntervalSince(last) < 1 { lastLine.post(last); return }
            lastLine.post(now)
            let rate = Double(done) / max(now.timeIntervalSince(started), 0.001)
            progress("Downloading \(model.id) from Darkbloom's catalog: \(ClusterModelProvisioning.gigabytes(done)) of \(ClusterModelProvisioning.gigabytes(total)), \(String(format: "%.0f", rate / 1e6)) MB/s")
        }
        let failure = ClusterOnboardingMailbox<String>()
        let done = DispatchSemaphore(value: 0)
        let worker = downloader
        Task.detached {
            do { try await worker.download(model: model) } catch { failure.post(ClusterConsoleText.bounded(error)) }
            done.signal()
        }
        done.wait()
        if let reason = failure.take().first { throw ClusterSetupFailure("The download of \(model.id) stopped: \(reason)") }
        guard let installed = ClusterProductModelStore.installed().first(where: {
            $0.artifact.aggregateSHA256 == model.aggregateSHA256 && $0.artifact.version == (model.version ?? $0.artifact.version)
        }) else {
            throw ClusterSetupFailure("\(model.id) downloaded, but the product's model store does not list it")
        }
        _ = try ClusterProductModelStore.cloneIntoClusterStore(installed, store: store, providerConfiguration: settings.service.wizard.providerConfiguration,
                                                               accepts: context.workerAcceptsManifest)
        // The download's pages stay in this Mac's file cache, active, even written and verified with the cache off:
        // 21 GB after Qwen 3.6 35B on a 36 GB M4 Max, its load gate admitting 1.7 GB; dropped, 14.7 GB (2026-10-16).
        ClusterModelStore.dropCachedPages(folder: installed.directory)
        guard case .complete(let folder) = ClusterModelStore.holding(store: store, artifact: installed.artifact) else {
            throw ClusterSetupFailure("\(model.id) could not be placed in the cluster's model store")
        }
        progress("Downloaded \(ClusterModelProvisioning.gigabytes(installed.artifact.totalBytes)) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; every file matched the catalog manifest.")
        return folder
    }

    func adopt(_ index: Int) -> Result<[String], ClusterOnboardingFailure> {
        // The choice travels with its model's id: a leader that restarted since it made the list plans again and finds it.
        let model = lock.withLock { listedChoices.indices.contains(index) ? (listedChoices[index].modelID ?? listedChoices[index].title) : nil }
        return routed(.init(op: .adopt, index: index, model: model), seconds: 240, acting: true, local: { localAdopt(index) }) { $0.lines }
    }

    /// `model`: the id of the model the list showed at `index` (a choice forwarded from another Mac). When this Mac's
    /// list is gone (its service restarted) or no longer shows that model there, it plans again and adopts it by id.
    func localAdopt(_ index: Int, model: String? = nil) -> Result<[String], ClusterOnboardingFailure> {
        var index = index
        if let model, lock.withLock({ !choices.indices.contains(index) || choices[index].title != model }) {
            if case .failure(let failure) = localReachMembers({ _ in }) { return .failure(failure) }
            if case .failure(let failure) = localPlanModels() { return .failure(failure) }
            guard let found = lock.withLock({ choices.firstIndex { $0.title == model } }) else {
                return .failure(.init("\(model) is not offered on these Macs any more; run `darkbloom cluster` again to choose."))
            }
            index = found
        }
        guard let peer = lock.withLock({ peerReport }), let choice = lock.withLock({ choices.indices.contains(index) ? choices[index] : nil }) else {
            return .failure(.init("The list of models is out of date; run `darkbloom cluster` again to choose."))
        }
        var lines = [String]()
        if leadership?.serving == true {
            // A running part holds its Mac's setup and native device lease: a model change drains both Macs first
            // (each part releases its memory), then changes the setup; `serve` starts the new one.
            if case .failure(let failure) = localStop() { return .failure(failure) }
            lines.append("Stopped both Macs' parts to change the model (each released its memory first).")
            guard drained(seconds: 300) else {
                return .failure(.init(lines + ["A part did not stop within 5 minutes, so the setup was not changed; run `darkbloom cluster` again."]))
            }
        }
        var result = context.adopt(folder: choice.folder, planKey: choice.key, peer: peer)
        // The device lease is released a moment after the part's process ends.
        for _ in 0..<10 where !result.succeeded && result.lines.joined(separator: " ").contains("lease is currently held") {
            sleep(3)
            result = context.adopt(folder: choice.folder, planKey: choice.key, peer: peer)
        }
        guard result.succeeded else { return .failure(.init(lines + result.lines)) }
        lock.withLock { chosenTitle = choice.title }
        // The deployment line the screen and status show, from the plan just adopted.
        try? store.updateRecord { $0.leadership?.deployment = choice.deployment }
        // Which members the planner said hold this model alone: what failover may serve alone (synced by the lease),
        // bound to the plan just saved so a verdict never outlives its plan.
        let plan = context.savedConfiguration().configuration?.selectedPlanSHA256
        try? store.updateRecord { $0.aloneHolders = choice.alone.sorted(); $0.aloneHoldersPlan = plan }
        return .success(lines + result.lines)
    }

    /// Both Macs' parts ended (this Mac's service publishes its own; the other Mac's is asked over the link).
    func drained(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let own = ClusterService.published()?.child.running == false
            let peer = (try? JSONDecoder().decode(ClusterServiceStatus.self, from: command(.init(op: .status), seconds: 10)))?.child.running == false
            if own && peer { return true }
            sleep(2)
        }
        return false
    }

    func command(_ command: ClusterServiceCommand, seconds: Double = 30) throws -> Data {
        guard let pairing = try ClusterSetupLinkExchange.pairing() else { throw ClusterOnboardingFailure("This Mac is not paired.") }
        var command = command
        if command.claim == nil { command.claim = currentClaim(try? store.readRecord()) }
        if command.op == .serve, command.scope?.isLocalOnly == true { command.localToken = try? LocalEndpoint.loadOrCreateClusterToken() }
        return try ClusterSetupLinkExchange.command(pairing: pairing, selection: try context.linkSelection(), peerAddress: nil,
            body: try JSONEncoder().encode(command), seconds: seconds).reply
    }

    func serve() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .serve), acting: true, local: { localServe() }) { $0.lines }
    }

    func setScope(_ scope: ClusterServingScope) -> Result<[String], ClusterOnboardingFailure> {
        // Long enough for the rank 0 part to stop (it releases its memory first) and start again.
        routed(.init(op: .scope, scope: scope), seconds: Self.scopeRestartSeconds + 30, acting: true, local: { localSetScope(scope) }) { $0.lines }
    }

    static let scopeRestartSeconds: Double = 400

    /// Saves how the cluster serves on this (control leader) Mac and gives the member the same scope. While the
    /// cluster serves, the Mac that runs rank 0 starts its part again that way (its service keys the part by the
    /// scope); this waits until that part started again, so the readiness asked next is the new part's.
    func localSetScope(_ scope: ClusterServingScope) -> Result<[String], ClusterOnboardingFailure> {
        guard let current = leadership else { return .failure(.init("This Mac is not paired with a cluster.")) }
        let saved = scope.isLocalOnly ? "Saved on \(here): the cluster serves locally only and never contacts a coordinator."
            : "Saved on \(here): the cluster serves through Darkbloom (its leading Mac registers with the coordinator)."
        if current.scope == scope { return .success([saved]) }
        let startsBefore = rankZeroStarts()
        do {
            try store.updateRecord { $0.leadership?.scope = scope }
        } catch {
            return .failure(.init("This Mac's setup record could not be saved: \(ClusterConsoleText.bounded(String(describing: error), maximum: 200))"))
        }
        guard current.serving else { return .success([saved]) }
        // The member records the scope from a start of the model it already runs (it needs it only if control moves).
        _ = try? command(.init(op: .serve, model: current.modelName, deployment: savedDeployment() ?? current.deployment, scope: scope), seconds: 10)
        let later = "The leading Mac's part has not started again yet; its cluster service does so by itself."
        guard let before = startsBefore else { return .success([saved, later]) }
        let deadline = Date().addingTimeInterval(Self.scopeRestartSeconds)
        while Date() < deadline {
            if let now = rankZeroStarts(), now > before {
                return .success([saved, "The leading Mac's part started again this way; it loads the model now."])
            }
            sleep(2)
        }
        return .success([saved, later])
    }

    /// How many times the part that runs rank 0 has started (this Mac's, or the other Mac's over the link).
    func rankZeroStarts() -> Int? {
        if context.savedConfiguration().configuration?.role == .leader { return ClusterService.published()?.child.starts }
        return (try? JSONDecoder().decode(ClusterServiceStatus.self, from: command(.init(op: .status), seconds: 10)))?.child.starts
    }

    func localServe() -> Result<[String], ClusterOnboardingFailure> {
        let title = lock.withLock { chosenTitle } ?? context.savedConfiguration().configuration?.publicModelID
        do {
            try store.updateRecord { $0.leadership?.serving = true; if let title { $0.leadership?.modelName = title } }
            // The line of the setup that runs, so the member shows the same one when it leads.
            let deployment = savedDeployment() ?? leadership?.deployment
            try store.updateRecord { $0.leadership?.deployment = deployment }
            _ = try command(.init(op: .serve, model: title, deployment: deployment, scope: leadership?.scope))
        } catch let failure as ClusterSetupFailure {
            return .failure(.init(["\(peerName) was not started yet: \(failure.text)", Self.startsWhenItAnswers(peerName)]))
        } catch {
            return .failure(.init(["\(peerName) was not started yet: \(error)", Self.startsWhenItAnswers(peerName)]))
        }
        return .success(["Started \(peerName)'s part over the cable (its cluster service runs it); this Mac's service runs its own."])
    }

    static func startsWhenItAnswers(_ peer: String) -> String {
        "This Mac's cluster service starts \(peer)'s part as soon as it answers; run `darkbloom cluster` here to see how it is going."
    }

    /// The Mac that runs rank 0 and the serving API, and its session.
    func session() -> (local: Bool, session: ClusterServiceStatus.Session?, child: ClusterServiceStatus.Child?, error: String?) {
        if context.savedConfiguration().configuration?.role == .leader {
            let live = context.observe(link: false)
            let ranks = max(live.members.count, context.savedConfiguration().configuration?.peers.count ?? 2)
            return (true, .init(observed: live.observed, ready: live.ready, readyRanks: live.readyRanks, ranks: ranks, port: live.port,
                detail: live.detail ?? live.sessionPhase), nil, nil)
        }
        do {
            let status = try JSONDecoder().decode(ClusterServiceStatus.self, from: try command(.init(op: .status), seconds: 15))
            return (false, status.session, status.child, nil)
        } catch let failure as ClusterSetupFailure {
            return (false, nil, nil, failure.text)
        } catch {
            return (false, nil, nil, "\(error)")
        }
    }

    func waitReady(_ progress: @escaping @Sendable (String) -> Void) -> Result<ClusterOnboardingReady, ClusterOnboardingFailure> {
        let deadline = Date().addingTimeInterval(900)
        var said: String?
        var seen = [String: Int](), previous: String?
        while Date() < deadline {
            var once: (ready: ClusterOnboardingReady?, line: String)
            if forwards {
                switch forward(.init(op: .readiness), seconds: 30) {
                case .success(let reply): once = (reply.ready, reply.progress ?? "starting")
                case .failure(let failure): once = (nil, failure.lines.joined(separator: " "))
                }
            } else {
                once = readinessOnce()
            }
            if let ready = once.ready { return .success(ready) }
            // Each line once (a part that keeps restarting alternated two lines every 2 s); a part that ends the
            // same way again and again is said and the wait ends: both Macs keep trying by themselves. An end is
            // counted when the line turns to it (a poll that sees the same end again is the same end).
            if once.line != previous { seen[once.line, default: 0] += 1 }
            previous = once.line
            if once.line.contains("part ended"), seen[once.line, default: 0] >= Self.sameEndsBeforeSaying {
                return .failure(.init(["A part keeps ending the same way: \(once.line)."] + lastErrors(fallback: nil)))
            }
            if seen[once.line] == 1, once.line != said { progress(once.line); said = once.line }
            sleep(2)
        }
        return .failure(.init(["The cluster did not report ready within 15 minutes."] + lastErrors(fallback: said)))
    }

    /// The same part end seen this many times stops the wait on screen (the service keeps restarting it).
    static let sameEndsBeforeSaying = 3

    /// The last error each Mac's part reported, one line per Mac, also for parts still running (shown on screen after a
    /// start that did not finish, instead of a log path).
    func lastErrors(fallback: String?) -> [String] {
        func line(_ mac: String, _ child: ClusterServiceStatus.Child?, unreachable: String? = nil) -> String {
            if let unreachable { return "\(mac): did not answer over the cable (\(unreachable))." }
            guard let child else { return "\(mac): no report." }
            if let error = child.lastError { return "\(mac): \(error)" + (child.running ? " (its part is still running)." : ".") }
            if let end = child.lastEnd, !child.running { return "\(mac): its part ended (\(end))." }
            return "\(mac): " + (child.running ? "its part is running, no error reported." : "its part is not running.")
        }
        var lines = [line(ownName, ClusterService.published()?.child)]
        do {
            let status = try JSONDecoder().decode(ClusterServiceStatus.self, from: try command(.init(op: .status), seconds: 10))
            lines.append(line(peerName, status.child))
        } catch {
            lines.append(line(peerName, nil, unreachable: (error as? ClusterSetupFailure)?.text ?? "\(error)"))
        }
        if let fallback { lines.append("Last progress: \(fallback).") }
        return lines.map { ClusterConsoleText.bounded(context.clean($0), maximum: 300) }
    }

    /// A redacted diagnostics file (no keys, addresses, host or user names, home paths): this Mac's cluster status and
    /// checks as `darkbloom cluster status --json` and `doctor --json` report them, and each Mac's last error.
    func saveDiagnostics() -> Result<[String], ClusterOnboardingFailure> {
        let configuration = settings.service.wizard.providerConfiguration
        let box = ClusterOnboardingMailbox<(Data?, Data?)>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let status = try? encoder.encode(await ClusterDiagnostics.status(providerConfiguration: configuration))
            let doctor = try? encoder.encode(await ClusterDiagnostics.doctor(providerConfiguration: configuration))
            box.post((status, doctor)); done.signal()
        }
        guard done.wait(timeout: .now() + 60) == .success, let read = box.take().first else {
            return .failure(.init("The diagnostics could not be read within a minute; nothing was saved."))
        }
        let (status, doctor) = read
        // The console export's redaction: every identifier known here (serials, the computer's names, the local tokens,
        // the saved setup's peers), each string on its own, and nothing written when the second look still finds one.
        let redaction = ClusterDiagnosticRedaction(identifiers: ClusterConsoleOperations.localIdentifiers(paths: context.paths,
            providerConfiguration: configuration, candidate: nil))
        var sections = [String: Data]()
        if let status { sections["status"] = status }
        if let doctor { sections["doctor"] = doctor }
        do {
            // The home folder itself: Desktop, Documents and Downloads would bring a macOS prompt to the terminal app.
            let file = try ClusterDiagnosticExport.writeOnboarding(lastErrors: lastErrors(fallback: nil), sections: sections,
                redaction: redaction, home: context.paths.homeDirectory)
            return .success(["Saved a diagnostics file (no keys, addresses or names in it): \(file.lastPathComponent) in your home folder."])
        } catch {
            return .failure(.init("The diagnostics file was not saved: \(ClusterConsoleText.bounded(String(describing: error), maximum: 200))"))
        }
    }

    /// The deployment line of the setup this Mac saved (what runs), from that setup's own Plan and the members' names:
    /// never a line recorded for an earlier start. Control can move between the adopt (on one Mac) and the start (on
    /// the rank 0 Mac), and the recorded line then named the earlier split (2x M4 Max / M5 Max, 2026-10-15).
    func savedDeployment() -> String? {
        guard case .success(let reference?) = context.savedConfiguration().reference,
              let saved = try? ClusterConfigurationStore(paths: context.paths).load(reference: reference),
              let stages = try? saved.capability.selection(planSHA256: saved.configuration.selectedPlanSHA256).stages
                .sorted(by: { $0.rank < $1.rank }),
              stages.allSatisfy({ saved.configuration.peers.indices.contains($0.rank) }) else { return nil }
        let members = (try? store.readRecord())?.control?.members ?? []
        let names = Dictionary(members.map { ($0.memberID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let shares = stages.map { stage -> ClusterOnboardingDeployment.Share in
            let id = saved.configuration.peers[stage.rank].id
            return .init(name: names[id] ?? id, layers: stage.sourceLayerEnd - stage.sourceLayerStart)
        }
        let modelID = saved.configuration.publicModelID
        let catalog = (ClusterModelStore.readSmall(store.paths.directory.appendingPathComponent("catalog.json"))
            .flatMap { try? JSONDecoder().decode([CatalogModel].self, from: $0) }) ?? []
        let title = ClusterOnboardingDeployment.title(modelID: modelID,
            displayNames: Dictionary(catalog.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
        return ClusterOnboardingDeployment.line(model: title, mode: saved.configuration.selectedGenerationMode.rawValue, shares: shares)
    }

    /// Where a ready cluster serves, as `session()` saw it. The API reaches the network only once the part that serves
    /// says it serves locally only by choice (its log line), so a part still running the earlier way is never named so.
    func ready(_ now: (local: Bool, session: ClusterServiceStatus.Session?, child: ClusterServiceStatus.Child?, error: String?),
               port: Int) -> ClusterOnboardingReady {
        let notice = now.local ? ClusterService.servingNotice() : now.child?.notice
        let byChoice = notice == ClusterLocalServing.localOnlyNotice
        return .init(servedBy: now.local ? here : peerName, port: port, deployment: savedDeployment() ?? leadership?.deployment, notice: notice,
                     network: byChoice ? (leadership?.scope.reachableFromNetwork ?? false) : nil)
    }

    /// One look at the cluster from the control leader: ready (where the serving API listens) or a progress line.
    func readinessOnce() -> (ready: ClusterOnboardingReady?, line: String) {
        let published = ClusterService.published()
        if let control = published?.control, control.mode == "alone" {
            // Only THIS service's solo server counts as ready, never whatever answers on the port.
            switch ClusterService.soloReadiness(published) {
            case .ready: return (.init(servedBy: here, port: ClusterService.soloPort, deployment: "Serving \(leadership?.modelName ?? "the model") on \(here) alone while the other Mac is away"), control.line)
            case .loading: return (nil, control.line + " (loading)")
            case .foreign: return (nil, control.line + " (another program answers on port \(ClusterService.soloPort), so \(here)'s solo server cannot serve there)")
            }
        }
        if let updating = published?.updating { return (nil, updating) }
        // Inside the absence grace: not ready, and the line says how long until this Mac serves alone.
        if let control = published?.control, control.mode == "waiting" { return (nil, control.line) }
        let now = session()
        var line: String
        if let session = now.session, session.observed {
            if session.ready, let port = session.port {
                return (ready(now, port: port), "ready")
            }
            line = "\(session.readyRanks) of \(session.ranks) parts ready" + (session.detail.map { " (\($0))" } ?? "")
        } else if let child = now.child, let end = child.lastEnd, !child.running {
            line = "rank 0 on \(peerName) ended (\(end)\(child.lastError.map { ": " + $0 } ?? "")); it starts again by itself"
        } else if let error = now.error {
            line = "waiting for \(peerName): \(error)"
        } else {
            line = "starting"
        }
        // This Mac's own part, when it is the one that keeps ending.
        if let own = ClusterService.published()?.child, !own.running, let end = own.lastEnd, end != "stopped" {
            line += "; this Mac's part ended (\(end)\(own.lastError.map { ": " + $0 } ?? "")) and starts again by itself"
        }
        // Members are asked for their own part only when rank 0 is here.
        if now.local, let member = try? JSONDecoder().decode(ClusterServiceStatus.self, from: try command(.init(op: .status), seconds: 10)),
           !member.child.running, let end = member.child.lastEnd {
            line += "; \(peerName)'s part ended (\(end)\(member.child.lastError.map { ": " + $0 } ?? "")) and starts again by itself"
        }
        return (nil, line)
    }

    func testRequest() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .test), seconds: 240, acting: false, local: { localTestRequest() }) { $0.lines }
    }

    func localTestRequest() -> Result<[String], ClusterOnboardingFailure> {
        let text = "Name three colors."
        let answer: ClusterServicePromptAnswer
        if ClusterService.published()?.control?.mode == "alone" {
            // Degraded: this Mac serves alone on its own loopback, once its own solo server holds the port.
            guard ClusterService.soloReadiness(ClusterService.published()) == .ready else {
                return .failure(.init("\(here) serves alone, but its solo server is not answering on port \(ClusterService.soloPort) yet."))
            }
            answer = ClusterService.prompt(context, text: text, port: ClusterService.soloPort)
        } else if context.savedConfiguration().configuration?.role == .leader {
            answer = ClusterService.prompt(context, text: text)
        } else {
            do {
                answer = try JSONDecoder().decode(ClusterServicePromptAnswer.self, from: try command(.init(op: .prompt, text: text), seconds: 200))
            } catch {
                return .failure(.init("The test request did not reach \(peerName): \((error as? ClusterSetupFailure)?.text ?? "\(error)")"))
            }
        }
        if let error = answer.error { return .failure(.init("The test request failed: \(error)")) }
        let reply = answer.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var figures = "\(answer.tokens) tokens"
        if let first = answer.firstTokenMilliseconds { figures += ", first token \(String(format: "%.2f", Double(first) / 1000)) s" }
        if let rate = answer.tokensPerSecond { figures += ", \(String(format: "%.1f", rate)) tokens/s" }
        if let finish = answer.finishReason { figures += ", finished: \(finish)" }
        return .success(["\"\(text)\" -> \"\(String(reply.prefix(200)))\"", figures])
    }

    func status() -> [String] {
        var forwarded = false
        var lines: [String]
        switch routed(.init(op: .status), seconds: 30, acting: false, forwarding: { forwarded = true }, local: { .success(localStatus()) }, remote: { $0.lines }) {
        case .success(let value): lines = value
        case .failure(let failure): lines = failure.lines
        }
        // This Mac's own state, when it adds something (a member that just follows already said where commands go).
        if forwarded, let own = ClusterService.published()?.control, own.mode != "following" { lines.append("This Mac: " + own.line + ".") }
        return lines
    }

    func localStatus() -> [String] {
        var lines = [String]()
        // After a Darkbloom update this Mac's service sets the cluster up again by itself; said first while it runs.
        if let updating = ClusterService.publishedLive()?.updating { lines.append(updating) }
        if let control = ClusterService.published()?.control, ["alone", "cannotServe", "waiting"].contains(control.mode) {
            lines.append((here == "this Mac" ? "" : here + ": ") + control.line + ".")
            lines.append("Commands typed here are handled by \(here).")
            return lines
        }
        let model = leadership?.modelName ?? "the chosen model"
        let now = session()
        if leadership?.serving != true {
            lines.append("Not serving (stopped)\(leadership?.modelName.map { "; the last model was " + $0 } ?? "").")
            if let scope = leadership?.scope, scope.isLocalOnly { lines.append("When it starts: " + scope.line + ".") }
        } else if let session = now.session, session.observed {
            if session.ready {
                // The deployment first, then where the API is.
                // The local-serving line is worded for the screen it lands on (`noticeLine`): a member's status says
                // that Mac's API, as the API line above names it.
                let ready = ready(now, port: session.port ?? 0)
                lines.append(ready.lines(model: model)[0] + ".")
                lines.append(ready.apiLine + " (\(session.readyRanks) of \(session.ranks) parts ready).")
                if let notice = ready.noticeLine { lines.append(notice + ".") }
            } else {
                lines.append("\(model): \(session.readyRanks) of \(session.ranks) parts ready" + (session.detail.map { " (\($0))" } ?? "") + ".")
            }
        } else if let error = now.error {
            lines.append("\(peerName) does not answer over the cable now (\(error)); it rejoins by itself when it is back.")
        } else {
            lines.append("\(model) is starting (both Macs keep trying by themselves).")
        }
        lines.append(here == "this Mac" ? "Member: \(peerName). This Mac leads." : "Members: \(here) (leads), \(peerName).")
        // On the leader's own screen only: a member that forwarded this already says where its commands go.
        if let control = ClusterService.published()?.control, control.leads, here == "this Mac" {
            lines.append("Commands typed here are handled by this Mac.")
        }
        return lines
    }

    func stop() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .stop), acting: true, local: { localStop() }) { $0.lines }
    }

    func verifyTeardown() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .verifyTeardown), seconds: 60, acting: false, local: { localVerifyTeardown() }) { $0.lines }
    }

    /// Each Mac's verify-teardown summary: this one's, and the other's over the link.
    func localVerifyTeardown() -> Result<[String], ClusterOnboardingFailure> {
        var lines = ClusterService.teardownLines()
        do {
            lines += try JSONDecoder().decode([String].self, from: try command(.init(op: .teardown), seconds: 30))
        } catch {
            lines.append("\(peerName): did not answer (\((error as? ClusterSetupFailure)?.text ?? "\(error)"))")
        }
        return .success(lines)
    }

    func localStop() -> Result<[String], ClusterOnboardingFailure> {
        do {
            try store.updateRecord { $0.leadership?.serving = false }
            lock.withLock { partsStoppedAt = Date() }
            _ = try command(.init(op: .stop))
        } catch {
            let reason = (error as? ClusterSetupFailure)?.text ?? "\(error)"
            return .failure(.init("This Mac stopped serving; \(peerName) did not answer (\(reason)). This Mac's cluster service tells it to stop as soon as it answers again."))
        }
        return .success(["Both Macs stop their parts now (each releases its memory first). Run `darkbloom cluster` here to serve again."])
    }
}
