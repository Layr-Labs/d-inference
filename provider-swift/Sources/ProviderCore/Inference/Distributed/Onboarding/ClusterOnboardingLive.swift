import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import DarkbloomClusterPlacement

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
            developerNotice: { ClusterForcedModeSetting.notice(environment: ProcessInfo.processInfo.environment) })
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
    private var choices: [(folder: String, key: String, title: String, alone: [String], deployment: String?, plan: ClusterSetupPlanSummary?)] = []
    /// Choices that are catalog models no Mac has yet (by choice index).
    private var catalogChoices: [Int: CatalogModel] = [:]
    /// Choices that only the other Mac has (by choice index): it sends them here first.
    private var peerChoices: [Int: ClusterSetupLocalModel] = [:]
    private var chosenTitle: String?
    /// Set while this (leader) Mac answers a command forwarded from another member: its lines name this Mac by its
    /// name instead of "this Mac", which would mean the Mac that shows them.
    private var answeringForward = false
    private lazy var ownName: String = ClusterPairingProvider.displayName(chipName: (try? HardwareDetector.detect().chipName) ?? "Mac")

    /// "this Mac", or this Mac's name in an answer shown on another member.
    var here: String { lock.withLock { answeringForward } ? ownName : "this Mac" }

    init(context: LiveContext, store: ClusterSetupStore, settings: ClusterOnboardingOperations.LiveSettings) {
        self.context = context; self.store = store; self.settings = settings
    }

    var leadership: ClusterOnboardingLeadership? { (try? store.readRecord())?.leadership }
    var peerName: String { leadership?.peerName ?? "the other Mac" }

    func resume() -> ClusterOnboardingResume {
        guard let leadership, let role = ClusterOnboardingRole(rawValue: leadership.role),
              let pairing = try? ClusterSetupLinkExchange.pairing(), pairing.peerPin == leadership.peerPin else { return .init() }
        // After onboarding the role is the derived control leadership, not who drove the screens.
        let record = try? store.readRecord()
        guard let claim = record?.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID) else {
            return .init(role: role, peerName: leadership.peerName, serving: leadership.serving, modelName: leadership.modelName)
        }
        let leads = claim.leaderID == pairing.localMemberID
        var resume = ClusterOnboardingResume(role: leads ? .leader : .member, peerName: leadership.peerName, serving: leadership.serving,
                                             modelName: leadership.modelName)
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
        case .adopt: return lines(localAdopt(request.index ?? -1))
        case .serve: return lines(localServe())
        case .stop: return lines(localStop())
        case .readiness:
            let once = readinessOnce()
            return .init(lines: [], failed: false, leaderID: leaderID, ready: once.ready, progress: once.line)
        case .test: return lines(localTestRequest())
        case .verifyTeardown: return lines(localVerifyTeardown())
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

    func pair(_ events: @escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult {
        let pairingStore = ClusterPairingStore.default()
        let identity: any ClusterPairingIdentity
        do { identity = try ClusterPairingProvider.identity() } catch { return .failed(["\(error)"]) }
        let interface: String
        do { interface = try ClusterPairCommandLine.resolveInterface(ClusterPairCommandRequest(), peer: nil) } catch {
            return .failed(["The cable carries no address on this Mac yet: \(error)"])
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

    /// The service for this session only (no login agent), with the reason it will not start at login.
    private func sessionService(executable: URL, arguments: [String], reason: String) -> Result<String, ClusterOnboardingFailure> {
        do {
            let started = try ClusterService.ensureRunning(executable: executable, arguments: arguments)
            return .success((started ? "Started this Mac's cluster service for this session" : "This Mac's cluster service is running")
                + ", but it could not be set to start at login (\(reason)): after a restart of this Mac, "
                + "run `darkbloom cluster` here again.")
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
        lock.withLock { peerReport = peer }
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

    func planModels() -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
        routed(.init(op: .planModels), seconds: 240, acting: false, local: { localPlanModels() }) { $0.choices ?? [] }
    }

    func localPlanModels() -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
        guard let peer = lock.withLock({ peerReport }) else { return .failure(.init("The other Mac has not answered yet.")) }
        // The models single-Mac Darkbloom installed on this Mac are cluster models too (cloned in: no new blocks), when a
        // pair may serve them with this build (as for models copied from the other Mac or downloaded).
        let store = URL(fileURLWithPath: context.modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path)
        for installed in ClusterProductModelStore.installed() where ClusterModelCopyTrust.servableArtifacts.contains(installed.artifact.aggregateSHA256) {
            _ = try? ClusterProductModelStore.cloneIntoClusterStore(installed, store: store, providerConfiguration: settings.service.wizard.providerConfiguration)
        }
        switch context.plan(peer: peer) {
        case .failed(let reason): return .failure(.init("Planning failed: \(reason)"))
        case .ready(let options):
            let localName = ClusterPairingProvider.displayName(chipName: context.snapshot().local.mac.chip)
            // The catalog, fetched once: each model is shown by its display name (its id when the catalog has none or
            // does not answer), and the catalog's downloadable models are offered below.
            let catalogAll = fetchCatalog()
            let names = Dictionary(catalogAll.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            var keys = [(folder: String, key: String, title: String, alone: [String], deployment: String?, plan: ClusterSetupPlanSummary?)]()
            let choices = options.map { option -> ClusterOnboardingModelChoice in
                let gigabytes = String(format: "%.1f GB", Double(option.model.totalBytes) / 1e9)
                let modelID = option.model.modelID
                let title = ClusterOnboardingDeployment.title(modelID: modelID, displayNames: names)
                guard let plan = option.plan else {
                    keys.append((option.model.folder, "", modelID, [], nil, nil))
                    return .init(title: title, lines: [], blocker: option.blocker ?? "Not offered on these Macs.", modelID: modelID)
                }
                let offer = option.onOtherMac != false ? nil : copyOffer(model: option.model, peer: peer, localName: localName)
                // One line: size, how it is split (the planner's choice), each Mac's share, the expected speed.
                let shares = plan.ranks.sorted { $0.rank < $1.rank }.map { rank in
                    ClusterOnboardingDeployment.Share(name: rank.local ? localName : peerName, layers: rank.endLayer - rank.firstLayer,
                                                      weightsBytes: rank.weightsBytes)
                }
                let speed = plan.absolute ? "about \(Int(plan.decodeTokensPerSecond.rounded())) tokens/s\(plan.measured ? "" : " (estimate)")" : nil
                let line = ClusterOnboardingDeployment.choiceLine(size: gigabytes, mode: plan.mode, shares: shares, speed: speed)
                let deployment = ClusterOnboardingDeployment.line(model: title, mode: plan.mode, shares: shares)
                keys.append((option.model.folder, ClusterSetupState.planKey(option.model, plan), modelID, plan.alone.filter(\.holds).map(\.memberID),
                             deployment, plan))
                // A running model is stopped (its memory released) before a new one starts, so its memory is no reason here.
                let remedy = leadership?.serving == true || plan.fitsNow ? nil : Self.fitRemedy(plan, localName: localName, peerName: peerName)
                // Served for the owner either way; one line says whether public traffic may reach it yet.
                return .init(title: title, lines: [line] + (plan.publicTraffic.map { [$0] } ?? []), blocker: option.blocker,
                             provision: offer, fitRemedy: remedy, modelID: modelID)
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
            for model in peer.models where !offered.contains(where: { $0.sameEntry(model) })
                && ClusterModelCopyTrust.servableArtifacts.contains(model.artifactSHA256) {
                held.insert(model.artifactSHA256)
                offered.append(model)
                fromPeer[ordered.count] = model
                let plan = ClusterModelProvisioning.plan(totalBytes: model.totalBytes,
                    leader: .init(name: "\(localName) (this Mac)", holding: .missing, freeBytes: ClusterModelStore.freeBytes(at: ClusterModelStoreLocation.defaultDirectory())),
                    members: [.init(name: peerName, holding: .complete(folder: model.folder), freeBytes: nil)],
                    linkBytesPerSecond: measuredCopyRate, catalogHasIt: false)
                ordered.append((.init(title: ClusterOnboardingDeployment.title(modelID: model.modelID, displayNames: names),
                    lines: ["on \(peerName) only: planned once it is on this Mac too"], blocker: nil,
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
            case "now": return nil
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
        case .now: return nil
        case .afterApplicationsRelease: return "Quit apps on \(mac) first."
        case .gateCountsLess, .afterRestart: return "Restart \(mac) to free memory."
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
        if case .reached(let report, _) = context.reachPeer() { lock.withLock { peerReport = report }; peerProfile = report.mac.profile }
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

    func copyOffer(model: ClusterSetupLocalModel, peer: ClusterSetupReport, localName: String) -> ClusterOnboardingProvisionOffer {
        let plan = ClusterModelProvisioning.plan(totalBytes: model.totalBytes,
            leader: .init(name: "\(localName) (this Mac)", holding: .complete(folder: model.folder), freeBytes: nil),
            members: [.init(name: peerName, holding: holding(model, in: peer), freeBytes: peer.modelStoreFreeBytes)],
            linkBytesPerSecond: measuredCopyRate, catalogHasIt: true)
        return .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: false, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan))
    }

    func downloadChoice(_ model: CatalogModel, peer: ClusterSetupReport, localName: String) -> ClusterOnboardingModelChoice {
        let bytes = model.totalSizeBytes ?? Int64(model.sizeGb * 1e9)
        let local = ClusterModelStoreLocation.defaultDirectory()
        let plan = ClusterModelProvisioning.plan(totalBytes: bytes,
            leader: .init(name: "\(localName) (this Mac)", holding: .missing, freeBytes: ClusterModelStore.freeBytes(at: local)),
            members: [.init(name: peerName, holding: .missing, freeBytes: peer.modelStoreFreeBytes)],
            linkBytesPerSecond: measuredCopyRate, catalogHasIt: true)
        return .init(title: ClusterOnboardingDeployment.title(modelID: model.id, displayNames: [model.id: model.displayName]),
            lines: ["not on these Macs yet: \(ClusterModelProvisioning.gigabytes(bytes)) from Darkbloom's catalog; planned once it is on this Mac"],
            blocker: nil, provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan)), modelID: model.id)
    }

    /// Darkbloom's catalog of text models, as single-Mac Darkbloom reads it; empty when it does not answer within a few seconds.
    func fetchCatalog() -> [CatalogModel] {
        guard let config = try? ConfigManager.loadOrDefaults(from: settings.service.wizard.providerConfiguration) else { return [] }
        let client = ModelCatalogClient(coordinatorURL: config.coordinator.url)
        let box = ClusterOnboardingMailbox<[CatalogModel]>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.post((try? await client.fetchCatalog(typeFilter: "text")) ?? []); done.signal() }
        guard done.wait(timeout: .now() + 6) == .success, let models = box.take().first else { return [] }
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
        let capabilities = (try? HardwareDetector.detect()).map { ProviderRuntimeCapabilityDetector.detectPrepared(hardware: $0, boundMetallibHash: nil) } ?? []
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
        _ = try ClusterProductModelStore.cloneIntoClusterStore(installed, store: store, providerConfiguration: settings.service.wizard.providerConfiguration)
        guard case .complete(let folder) = ClusterModelStore.holding(store: store, artifact: installed.artifact) else {
            throw ClusterSetupFailure("\(model.id) could not be placed in the cluster's model store")
        }
        progress("Downloaded \(ClusterModelProvisioning.gigabytes(installed.artifact.totalBytes)) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; every file matched the catalog manifest.")
        return folder
    }

    func adopt(_ index: Int) -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .adopt, index: index), seconds: 240, acting: true, local: { localAdopt(index) }) { $0.lines }
    }

    func localAdopt(_ index: Int) -> Result<[String], ClusterOnboardingFailure> {
        guard let peer = lock.withLock({ peerReport }), let choice = lock.withLock({ choices.indices.contains(index) ? choices[index] : nil }) else {
            return .failure(.init("Nothing to adopt: plan again."))
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
        return try ClusterSetupLinkExchange.command(pairing: pairing, selection: try context.linkSelection(), peerAddress: nil,
            body: try JSONEncoder().encode(command), seconds: seconds).reply
    }

    func serve() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .serve), acting: true, local: { localServe() }) { $0.lines }
    }

    func localServe() -> Result<[String], ClusterOnboardingFailure> {
        let title = lock.withLock { chosenTitle } ?? context.savedConfiguration().configuration?.publicModelID
        do {
            try store.updateRecord { $0.leadership?.serving = true; if let title { $0.leadership?.modelName = title } }
            _ = try command(.init(op: .serve, model: title, deployment: leadership?.deployment))
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
            if once.line != said { progress(once.line); said = once.line }
            sleep(2)
        }
        return .failure(.init(["The cluster did not report ready within 15 minutes."] + lastErrors(fallback: said)))
    }

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
                return (.init(servedBy: now.local ? here : peerName, port: port, deployment: leadership?.deployment,
                              notice: now.local ? ClusterService.servingNotice() : now.child?.notice), "ready")
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
        } else if let session = now.session, session.observed {
            if session.ready {
                // The deployment first, then where the API is.
                // The local-serving line is worded for the screen it lands on (`noticeLine`): a member's status says
                // that Mac's API, as the API line above names it.
                let ready = ClusterOnboardingReady(servedBy: now.local ? here : peerName, port: session.port ?? 0, deployment: leadership?.deployment,
                                                   notice: now.local ? ClusterService.servingNotice() : now.child?.notice)
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
            _ = try command(.init(op: .stop))
        } catch {
            let reason = (error as? ClusterSetupFailure)?.text ?? "\(error)"
            return .failure(.init("This Mac stopped serving; \(peerName) did not answer (\(reason)). This Mac's cluster service tells it to stop as soon as it answers again."))
        }
        return .success(["Both Macs stop their parts now (each releases its memory first). Run `darkbloom cluster` here to serve again."])
    }
}
