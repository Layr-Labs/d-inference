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
        var made = ClusterOnboardingOperations(
            resume: { live.resume() },
            checkLink: { say in live.checkLink(say) },
            pair: { events in live.pair(events) },
            answerCode: { live.answer($0) },
            ensureService: { live.ensureService() },
            reachMembers: { waiting in live.reachMembers(waiting) },
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
            setScope: { live.setScope($0) },
            register: { live.register() },
            localNetwork: { subject in
                subject == .service ? ClusterLocalNetworkAccess.serviceState() : ClusterLocalNetworkAccess.probe()
            },
            commandApp: { ClusterLocalNetworkAccess.commandApp() },
            runAsAdministrator: { ClusterLocalNetworkAccess.runLinkScriptWithSudo($0, paths: paths) },
            serviceOutlivesWindow: { live.serviceOutlivesWindow() },
            remote: { ClusterLinkApprovalSession.cannotPrompt() },
            thisMacName: { ClusterLocalNetworkAccess.computerName() },
            otherMacAnswers: { live.otherMacAnswers() },
            unpair: { live.unpair() },
            pairServing: { progress in live.pairServing(progress) },
            missingLogins: { live.missingLogins() },
            login: { live.login() },
            useMode: { index, mode in live.useMode(index, mode) })
        made.markRegistrationPending = { live.markRegistrationPending() }
        made.planScope = { live.usePlanningScope($0) }
        made.notOfferedStatus = { ClusterOnboardingReady.notOfferedLines(inStatus: live.status()) }
        made.otherMacStartsAtLogin = { live.otherMacStartsAtLogin() }
        made.leaderStatus = { live.leaderStatus() }
        made.publishStep = { live.publishStep($0) }
        made.thisVersion = ProviderCore.version
        made.soloServing = { live.soloServing() }
        made.versionSplit = { live.versionSplit() }
        made.stopSoloServing = { live.stopSoloServing() }
        made.markSoloBlocked = { live.markSoloBlocked($0) }
        made.publishStart = { live.publishStart($0) }
        made.thisRank = { live.context.savedConfiguration().configuration?.localRank }
        made.servesThroughDarkbloom = { live.leadership?.scope.isLocalOnly != true }
        return made
    }
}

extension ClusterSetupRecord {
    /// The start's pending mark as one value (`registrationPendingPID` with `registrationPendingStarted`).
    var registrationPending: ClusterOnboardingPendingRegistration.Mark? {
        get { registrationPendingPID.map { .init(pid: $0, started: registrationPendingStarted) } }
        set { registrationPendingPID = newValue?.pid; registrationPendingStarted = newValue?.started }
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
    /// When the last start's wait for ready began (`waitReady`): `lastErrors` reads this Mac's incidents since then.
    private var waitBegan: Date?
    private let readPairing: @Sendable () throws -> ClusterSetupLinkExchange.Pairing?
    /// This Mac's pin as a pairing made now would store it (nil: no key could be read).
    private let currentPin: @Sendable () -> String?
    /// What adopting a listed choice needs: its folder, plan key, model id, the members that hold it alone, its
    /// deployment line and plan.
    typealias ChoiceKey = (folder: String, key: String, title: String, alone: [String], deployment: String?, plan: ClusterSetupPlanSummary?)
    private var choices: [ChoiceKey] = []
    /// Choices that are catalog models no Mac has yet (by choice index).
    private var catalogChoices: [Int: CatalogModel] = [:]
    /// Choices that only the other Mac has (by choice index): it sends them here first.
    private var peerChoices: [Int: ClusterSetupLocalModel] = [:]
    private var chosenTitle: String?
    /// The command this build answers to (`ClusterOnboardingCommand.name`, from the build identity), in every
    /// command these operations and the cluster service write, including the lines `darkbloom cluster stop --service` prints.
    static var cli: String { ClusterOnboardingCommand.name }
    /// The way of serving the screen's coming plan and adopt are for (`ClusterOnboardingOperations.planScope`).
    private var plannedScope: ClusterServingScope?
    /// The list `planModels` last returned on this Mac (from the leader when forwarded), so a choice names its model.
    private var listedChoices: [ClusterOnboardingModelChoice] = []
    /// The mode family the person chose per model id (`useMode`), for the next adopt of that model.
    private var chosenFamilies: [String: ClusterForcedMode] = [:]
    /// What adopting each other mode the question offered needs, by folder and family (`ClusterSetupModelOption.familyPlans`):
    /// the plan whose split the question showed, adopted as it is when nothing serves (`adoption`).
    private var familyChoices: [String: [ClusterForcedMode: ChoiceKey]] = [:]
    /// Set while this (leader) Mac answers a command forwarded from the other Mac: its lines are shown on that Mac, so
    /// they name the two Macs the other way round (`here`, `there`).
    private var answeringForward = false
    private lazy var ownName: String = ClusterPairingProvider.displayName(chipName: (try? HardwareDetector.detect().chipName) ?? "Mac")

    /// How this Mac's lines name the two Macs (`ClusterOnboardingMacName`), for the screen that shows them: this Mac
    /// is "this Mac" and the other "the other Mac (<its hardware name>)" on its own screen; in an answer to a command
    /// the other Mac forwarded, which that Mac shows, the other way round. The short forms leave the hardware name out
    /// where a nearby line gives it.
    var here: String { answering ? ClusterOnboardingMacName.other(named: ownName) : ClusterOnboardingMacName.this }
    var hereShort: String { answering ? ClusterOnboardingMacName.other : ClusterOnboardingMacName.this }
    var there: String { answering ? ClusterOnboardingMacName.this : ClusterOnboardingMacName.other(named: peerName) }
    var thereShort: String { answering ? ClusterOnboardingMacName.this : ClusterOnboardingMacName.other }
    private var answering: Bool { lock.withLock { answeringForward } }
    /// The phase `publishStart` last recorded, and when.
    private var startPublished: (phase: ClusterOnboardingStartProgress.Phase?, at: Double) = (nil, 0)

    /// `text` at the start of a sentence.
    static func sentence(_ text: String) -> String { ClusterOnboardingMacName.sentence(text) }

    init(context: LiveContext, store: ClusterSetupStore, settings: ClusterOnboardingOperations.LiveSettings,
         readPairing: @escaping @Sendable () throws -> ClusterSetupLinkExchange.Pairing? = { try ClusterSetupLinkExchange.pairing() },
         currentPin: @escaping @Sendable () -> String? = { ClusterPairingProvider.existingPin() }) {
        self.context = context; self.store = store; self.settings = settings
        self.readPairing = readPairing; self.currentPin = currentPin
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
        // A pairing made with another Secure Enclave key (the other app's, or the one before a reinstall) cannot
        // register: its roster names that key (2026-11-03). Said only when this Mac's key could be read.
        let problem: ClusterOnboardingPairingProblem? = currentPin().flatMap { $0 == pairing.localPin ? nil : .keyChanged }
        // After onboarding the role is the derived control leadership, not who drove the screens.
        let record = try? store.readRecord()
        guard let claim = record?.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID) else {
            var resume = ClusterOnboardingResume(role: role, peerName: peerName, serving: leadership.serving, modelName: leadership.modelName)
            resume.scope = leadership.scope
            resume.pairingProblem = problem
            resume.modelTitle = leadership.modelName.map(modelTitle); resume.servingMode = savedMode
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
        resume.pairingProblem = problem
        resume.modelTitle = leadership.modelName.map(modelTitle); resume.servingMode = savedMode
        return resume
    }

    /// The mode the saved setup serves its model in (a `ClusterGenerationMode` raw value).
    var savedMode: String? { context.savedConfiguration().configuration?.selectedGenerationMode.rawValue }

    /// The person's mode for the model of choice `index`, as the family the planner places: kept for the next adopt
    /// of that model (`localAdopt`), whichever family it is.
    func useMode(_ index: Int, _ mode: String) {
        lock.withLock {
            guard listedChoices.indices.contains(index), ClusterGenerationMode(rawValue: mode) != nil else { return }
            let model = listedChoices[index].modelID ?? listedChoices[index].title
            chosenFamilies[model] = Self.keptFamily(mode)
        }
    }

    /// The family `useMode` kept for the next adopt of `model` (a choice's model id, else its title).
    func keptFamily(forModel model: String) -> ClusterForcedMode? {
        lock.withLock { chosenFamilies[model] }
    }

    /// The family kept for the next adopt of a model the person chose `mode` for: always the person's, never inferred
    /// from the listing's order, which says nothing of the plan (the DevNet run, A-9: GLM listed Pipeline first while its
    /// plan was tensor parallel, so choosing Pipeline kept nothing and tensor parallel loaded again). `localAdopt` plans
    /// again only when the listed plan's mode isn't in it.
    static func keptFamily(_ mode: String) -> ClusterForcedMode? {
        guard let generation = ClusterGenerationMode(rawValue: mode) else { return nil }
        return ClusterForcedMode.allCases.first(where: { $0.admits(generation) })
    }

    /// Whether the kept `family` is another than the listed plan's mode (`localAdopt`).
    static func replansInFamily(_ family: ClusterForcedMode?, listedPlanMode: String?) -> Bool {
        guard let family else { return false }
        return listedPlanMode.flatMap { ClusterGenerationMode(rawValue: $0) }.map(family.admits) != true
    }

    /// The plan a start adopts (`localAdopt`).
    enum Adoption: Equatable {
        /// The listed plan: its mode is the one chosen.
        case listed
        /// The plan the question showed for the mode chosen (`familyChoices`): its split is the one that loads.
        case shown
        /// Planned again: a model serves (its memory comes back first, so the question said "decided when it loads"),
        /// or no plan was made for the mode chosen.
        case planAgain
    }

    /// `modeDiffers`: the mode chosen isn't the listed plan's (`replansInFamily`). `shown`: the question showed a plan
    /// made for it. R4-13: the start planned the chosen mode again, with this Mac's speed measured again, and GLM's
    /// pipeline offered as 1 / 44 loaded 44 / 1.
    static func adoption(modeDiffers: Bool, serving: Bool, shown: Bool) -> Adoption {
        if serving { return .planAgain }
        guard modeDiffers else { return .listed }
        return shown ? .shown : .planAgain
    }

    /// The adopt this Mac forwards to the leader: the mode chosen on this Mac's screen (`useMode`) goes with it, so the
    /// leader adopts that mode's plan, not its own list's default.
    static func adoptRequest(index: Int, model: String?, scope: ClusterServingScope?, family: ClusterForcedMode?) -> ClusterControlRequest {
        ClusterControlRequest(op: .adopt, index: index, model: model, scope: scope, mode: family?.rawValue)
    }

    /// One status request over the cable, which only a Mac holding this pairing's link key can answer.
    func otherMacAnswers() -> Bool {
        (try? command(.init(op: .status), seconds: Self.answerSeconds)) != nil
    }

    static let answerSeconds: Double = 8

    /// The other Mac's `ClusterServiceStatus.startsAtLogin`, from one status request over the cable: nil when it doesn't
    /// answer or doesn't say (an older build).
    func otherMacStartsAtLogin() -> Bool? {
        (try? command(.init(op: .status), seconds: Self.answerSeconds))
            .flatMap { try? JSONDecoder().decode(ClusterServiceStatus.self, from: $0) }?.startsAtLogin
    }

    /// Pair again: this Mac's saved pairing removed as `darkbloom cluster pair --forget` removes it.
    func unpair() -> Result<[String], ClusterOnboardingFailure> {
        let pairing: ClusterSetupLinkExchange.Pairing?
        do { pairing = try readPairing() } catch {
            return .failure(.init("This Mac's pairing could not be read: \(ClusterConsoleText.bounded(String(describing: error), maximum: 200))"))
        }
        guard let pairing else { return .success([]) }
        let wizard = settings.service.wizard
        do {
            let outcome = try ClusterUnpairing.run(peerPin: pairing.peerPin, executable: wizard.darkbloomExecutable,
                                                   providerConfiguration: wizard.providerConfiguration)
            return .success(["\(ClusterOnboardingDriver.done) Unpaired this Mac."]
                + (outcome.serviceProblem.map { ["Its cluster service is still running: \(ClusterConsoleText.bounded($0, maximum: 200))"] } ?? []))
        } catch {
            return .failure(.init("This Mac could not unpair: \(ClusterConsoleText.bounded(String(describing: error), maximum: 200))"))
        }
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
                return .init("This Mac's leadership is not confirmed yet (its cluster service has not heard from \(there) and the \(Int(ClusterService.leaseTTLSeconds)) s window has not passed); run `\(Self.cli) cluster` again in a moment.")
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
                    return .failure(.init("Another cluster command is still running on this Mac; run `\(Self.cli) cluster` again."))
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
        return .failure(moved ?? .init("The control leader kept changing; run `\(Self.cli) cluster` again."))
    }

    /// The leader's reply as it came, failed or not.
    func forwardReply(_ request: ClusterControlRequest, seconds: Double) -> Result<ClusterControlReply, ClusterOnboardingFailure> {
        guard case .forward(let to) = route() else { return .failure(.init("This Mac leads: nothing to forward.")) }
        guard let pairing = try? ClusterSetupLinkExchange.pairing(), pairing.peerMemberID == to else {
            return .failure(.init("The control leader is not the Mac this one paired with (forwarding to a third Mac is not built)."))
        }
        // The control leader is the Mac this one paired with (checked above).
        let leader = ClusterOnboardingMacName.other(named: leaderName)
        do {
            let data = try command(.init(op: .control, control: request), seconds: seconds)
            return .success(try JSONDecoder().decode(ClusterControlReply.self, from: data))
        } catch let failure as ClusterSetupFailure {
            return .failure(.init(["\(Self.sentence(leader)) did not answer over the cable: \(failure.text)", Self.localNetworkHint(leader)]))
        } catch {
            return .failure(.init(["\(Self.sentence(leader)) did not answer over the cable: \(error)", Self.localNetworkHint(leader)]))
        }
    }

    /// Runs `body` as the answer to a command the other Mac forwarded: its lines are worded for that Mac's screen.
    func answeringForwarded<T>(_ body: () -> T) -> T {
        lock.withLock { answeringForward = true }
        defer { lock.withLock { answeringForward = false } }
        return body()
    }

    /// The leader's half: one forwarded command, run here as `darkbloom cluster` would run it on this Mac.
    func execute(_ request: ClusterControlRequest, leaderID: String) -> ClusterControlReply {
        var reply = answeringForwarded { executeForwarded(request, leaderID: leaderID) }
        // The status carries how far the start is, for the Mac that joined (an older Mac ignores it).
        if request.op == .status { reply.start = currentStart() }
        return reply
    }

    /// Records how far this screen's start is (nil clears it) on the Mac whose status both Macs read, with this
    /// process, so it stops counting once the screen is gone (`ClusterOnboardingStartProgressMark`). `every`: at most
    /// once in that many seconds for the same phase (a copy's bytes, a load's parts); a new phase is always recorded.
    func publishStart(_ progress: ClusterOnboardingStartProgress?, every seconds: Double = 0) {
        let pid = getpid()
        guard !forwards, let started = Self.processStarted(pid) else { return }
        let now = Date().timeIntervalSince1970
        let due = lock.withLock { () -> Bool in
            guard progress?.phase != startPublished.phase || now - startPublished.at >= seconds else { return false }
            startPublished = (progress?.phase, now)
            return true
        }
        guard due else { return }
        try? store.updateRecord { record in
            record.startProgress = progress.map {
                .init(progress: $0.continuing(record.startProgress?.progress, now: now), pid: pid, started: started, at: now)
            }
        }
    }

    /// The start's progress the status publishes, while it counts.
    func currentStart() -> ClusterOnboardingStartProgress? {
        (try? store.readRecord())?.startProgress?.current(now: Date().timeIntervalSince1970, started: Self.processStarted)
    }

    /// A copy's or download's bytes, published about once a second.
    func publishingBytes(_ phase: ClusterOnboardingStartProgress.Phase, toLeader: Bool? = nil) -> @Sendable (Int64, Int64) -> Void {
        { [self] done, total in publishStart(.init(phase, done: done, total: total, toLeader: toLeader), every: 1) }
    }

    private func executeForwarded(_ request: ClusterControlRequest, leaderID: String) -> ClusterControlReply {
        func lines(_ result: Result<[String], ClusterOnboardingFailure>) -> ClusterControlReply {
            switch result {
            case .success(let lines): return .init(lines: lines, failed: false, leaderID: leaderID)
            case .failure(let failure): return .init(lines: failure.lines, failed: true, leaderID: leaderID)
            }
        }
        switch request.op {
        case .status: return .init(lines: localStatus(), failed: false, leaderID: leaderID, step: currentLeaderStep())
        case .reachMembers:
            switch localReachMembers({ _ in }) {
            case .success(let machines): return .init(lines: [], failed: false, leaderID: leaderID, machines: machines)
            case .failure(let failure): return .init(lines: failure.lines, failed: true, leaderID: leaderID)
            }
        case .planModels:
            switch localPlanModels(scope: request.scope) {
            case .success(let choices): return .init(lines: [], failed: false, leaderID: leaderID, choices: choices)
            case .failure(let failure): return .init(lines: failure.lines, failed: true, leaderID: leaderID)
            }
        case .adopt:
            return lines(localAdopt(request.index ?? -1, model: request.model, scope: request.scope,
                                    family: request.mode.flatMap(ClusterForcedMode.init(rawValue:))))
        case .serve: return lines(localServe())
        case .stop: return lines(localStop())
        case .readiness:
            let once = readinessOnce()
            if once.ready == nil { publishStart(.init(.loading, parts: once.parts), every: 1) }
            return .init(lines: [], failed: false, leaderID: leaderID, ready: once.ready, progress: once.line)
        case .test: return lines(localTestRequest())
        case .verifyTeardown: return lines(localVerifyTeardown())
        case .scope:
            guard let scope = request.scope else { return lines(.failure(.init("No way of serving was named, or its address is not one the API takes."))) }
            return lines(localSetScope(scope))
        case .register: return lines(localRegister())
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
        // Where macOS could not show its prompt: the script of the same commands, which the onboarding runs with sudo.
        var manualScript: String?
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
                // The one macOS approval (Connect's first line said macOS asks for the password; its window says
                // what for); where no prompt can show (an SSH session has no window to show it in), one owner-only
                // script, which the onboarding runs with sudo in this terminal (the person never has to find it, so
                // the link flow's line telling them to run it by hand is not shown).
                let result = ClusterLinkRepair.fix(device: device, mode: .durable, dryRun: false)
                manualScript = result.manualScript
                step = flow.repaired(result)
                if manualScript != nil { step = .init(lines: step.lines.filter { $0 != result.message }, action: step.action) }
            case .finish(let code):
                if !flow.choices.isEmpty { return .init(ready: false, exitCode: max(code, 1), ports: flow.choices.map { $0.interface }) }
                guard code == 0, flow.linkState == .ready else { return .init(ready: false, exitCode: max(code, 1), manualScript: manualScript) }
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
            return .failed(["The cable has no address on this Mac yet. Run `\(Self.cli) cluster` again in a moment;"
                + " if this repeats, run `\(Self.cli) cluster doctor` and check the cable on both Macs."])
        }
        let chipName = (try? HardwareDetector.detect().chipName) ?? "Mac"
        let participant = ClusterPairingProvider.participant(identity: identity, chipName: chipName, interface: interface,
            store: pairingStore, clusterID: nil)
        var options = ClusterLinkPairing.Options(role: .listener, interface: interface)
        options.port = ClusterCablePorts.current.pairing
        // Find a Mac waiting on the cable and join it; when none waits, wait here and lead.
        options.discovery = .find
        let callbacks = ClusterLinkPairing.Callbacks(progress: { progress in
            switch progress {
            case .searching: events(.searching)
            case .listening: events(.waitingAsLeader)
            case .dialing: events(.joining)
            case .connected: events(.connected)
            case .refused(let reason): events(.note("The cable connection was refused (\(reason)); still trying…"))
            // Saving each other's keys takes a moment and needs nothing from the person: no line for it.
            case .storing: break
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
        let childExit = ProcessExitObserver()
        do { try childExit.run(process) } catch { return nil }
        guard childExit.wait(timeout: 5) || !process.isRunning else {
            process.terminate()
            _ = childExit.wait(timeout: 2)
            return nil
        }
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    func afterRestart() -> String? {
        startsAtLoginNow() == true ? restartLine() : nil
    }

    /// This Mac's cluster service keeps serving once the window closes (a login agent of the signed app), not a
    /// development build's session service.
    func serviceOutlivesWindow() -> Bool {
        startsAtLoginNow() != false
    }

    /// One look when a line says it: the running service's own word, else this run's service setup. The joining Mac's
    /// window ended "After a restart, this Mac serves again by itself" with a session service put in place while it
    /// followed (R3-2): that was this run's setup, read at its start.
    private func startsAtLoginNow() -> Bool? {
        Self.startsAtLogin(now: ClusterService.publishedLive()?.startsAtLogin, setUp: lock.withLock { serviceAtLogin })
    }

    /// Installs this Mac's cluster service as its login agent (it starts at login, and its supervisor restarts it
    /// with backoff), idempotently. Where launchd cannot take the job, the service still starts for this session, and
    /// the screen says to keep the window open (`serviceOutlivesWindow`).
    func ensureService() -> Result<Void, ClusterOnboardingFailure> {
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
            _ = try ClusterService.installAtLogin(executable: executable, serviceOptions: options)
            lock.withLock { serviceAtLogin = true }
            return .success(())
        } catch let agentError {
            lock.withLock { serviceAtLogin = false }
            return sessionService(executable: executable, arguments: arguments, reason: Self.reason(agentError))
        }
    }

    /// The service for this session only (no login agent): the screen says to keep the window open; why it cannot
    /// start at login (`reason`, e.g. an ad-hoc signed build) goes to the service log, not the screen.
    private func sessionService(executable: URL, arguments: [String], reason: String) -> Result<Void, ClusterOnboardingFailure> {
        do {
            let started = try ClusterService.ensureRunning(executable: executable, arguments: arguments)
            // Once per service start, not on every `darkbloom cluster`.
            if started { Self.logLoginAgentReason(reason) }
            return .success(())
        } catch let failure as ClusterOnboardingFailure {
            return .failure(failure)
        } catch {
            return .failure(.init("\(error)"))
        }
    }

    /// Said when the other Mac's service does not answer: a denied Local Network prompt there is the usual cause on a
    /// fresh pair, and nothing else would tell the person where to undo it.
    static func localNetworkHint(_ mac: String) -> String {
        let row = ClusterService.localNetworkRow, app = ClusterService.appName
        return "If you denied the Local Network prompt on \(mac), turn on “\(row)”"
            + ClusterOnboardingDriver.localNetworkRowNote(app: app, row: row)
            + " in System Settings → Privacy & Security → Local Network there, then run `\(Self.cli) cluster` again."
    }

    static func reason(_ error: Error) -> String {
        (error as? ClusterOnboardingFailure)?.lines.joined(separator: " ") ?? "\(error)"
    }

    /// Why the service runs for this session only, appended to its log (this install's `cluster-setup/service.log`,
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

    /// `waiting`: each new reason the other Mac has not answered yet, said on screen while the reading keeps asking.
    func reachMembers(_ waiting: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure> {
        let local = (try? ClusterSetupLinkExchange.pairing())?.localMemberID
        return routed(.init(op: .reachMembers), seconds: 150, acting: true, local: { localReachMembers(waiting) }) { reply in
            (reply.machines ?? []).map { machine in
                var machine = machine
                machine.here = machine.memberID != nil && machine.memberID == local
                return machine
            }
        }
    }

    /// `waiting`: each new reason the other Mac has not answered yet (`reachMembers` says them on screen).
    func localReachMembers(_ waiting: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure> {
        let deadline = Date().addingTimeInterval(120)
        var lastReason: String?
        var reached: ClusterSetupReport?
        while reached == nil {
            switch context.reachPeer() {
            case .reached(let report, _): reached = report
            case .failed(let reason):
                if reason != lastReason { waiting("Waiting for \(thereShort)'s cluster service: \(reason)"); lastReason = reason }
                guard Date() < deadline else {
                    return .failure(.init(["\(Self.sentence(there)) did not answer over the cable within 2 minutes: \(reason)", Self.localNetworkHint(there)]))
                }
                sleep(3)
            }
        }
        let peer = reached!
        rememberPeerReport(peer, memberID: context.peerFacts?.memberID)
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

    /// Each Mac's share in rank order, by hardware name; `perspective` adds how the screen names each Mac ("this Mac",
    /// "the other Mac"), for a line shown now rather than recorded for both Macs.
    func planShares(_ ranks: [ClusterSetupPlanSummary.Rank], localName: String, perspective: Bool = false) -> [ClusterOnboardingDeployment.Share] {
        let peer = peerName
        let labels = perspective ? (local: hereShort, peer: thereShort) : nil
        return ranks.sorted { $0.rank < $1.rank }.map { rank in
            .init(name: rank.local ? localName : peer, layers: rank.endLayer - rank.firstLayer,
                  weightsBytes: rank.weightsBytes, label: labels.map { rank.local ? $0.local : $0.peer })
        }
    }

    func planModels() -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
        let request = ClusterControlRequest(op: .planModels, scope: runScope)
        let result = routed(request, seconds: 240, acting: false, local: { localPlanModels() }) { $0.choices ?? [] }
        if case .success(let listed) = result { useListing(listed) }
        return result
    }

    /// The list a choice's index refers to (`useMode`, the adopt), as `planModels` last returned it.
    func useListing(_ listed: [ClusterOnboardingModelChoice]) {
        lock.withLock { listedChoices = listed }
    }

    /// How the cluster will serve the setup being planned: the way a forwarded command names, else this run's
    /// (`runScope`), else the one saved on this Mac. A cluster served through Darkbloom is planned for its coordinator
    /// (`ClusterPlacementTensorAssistantSelection.discoveryMode`).
    func planningScope(_ named: ClusterServingScope? = nil) -> ClusterServingScope {
        named ?? runScope ?? leadership?.scope ?? .publicServing
    }

    /// The way of serving this run's plan and adopt are for, and send to the control leader: the one the screen named
    /// (`usePlanningScope`), else the one this run was asked for (`darkbloom cluster local`); nil keeps the saved one.
    private var runScope: ClusterServingScope? { lock.withLock { plannedScope } ?? context.settings.servingScope }

    /// The screen names the way of serving its coming plan and adopt are for: a start whose scope changed after the list
    /// was planned (the login check's "Serve locally only") is planned and adopted for that way (B14).
    func usePlanningScope(_ scope: ClusterServingScope) { lock.withLock { plannedScope = scope } }

    /// Each Mac's share in the screen's words ("this Mac 44 layers / the other Mac 1 layer", "this Mac 40% / the other
    /// Mac 60%"), each named for the Mac that runs it (`local`); nil without shares. While a model serves, the list's plan
    /// counts that model's memory as taken, but the start stops it and plans again with its memory free (A-8), so the
    /// split offered then is not the one that loads (R3-3: 1 / 44 and 26 / 19 offered, 44 / 1 loaded): it says so.
    static func modeSplit(_ shares: [ClusterSetupPlanSummary.Mode.Share], here: String, there: String, serving: Bool) -> String? {
        guard !shares.isEmpty else { return nil }
        if serving { return ClusterOnboardingMode.decidedWhenItLoads }
        return shares.map { share in
            let mac = share.local ? here : there
            if let fraction = share.share { return "\(mac) \(Int((fraction * 100).rounded()))%" }
            return "\(mac) \(ClusterOnboardingDeployment.layers(share.endLayer - share.firstLayer))"
        }.joined(separator: " / ")
    }

    /// The mode question's recommendation (`ClusterOnboardingModeAdvice.advise`) from the plans the list made: each mode's
    /// own plan (the listed one for its family, else its family plan) says whether it fits now and its predicted speed;
    /// the mode says its measured speed (this build's, and an earlier build's), its requests at once and whether
    /// Darkbloom serves it publicly.
    static func modeAdvice(_ modes: [ClusterSetupPlanSummary.Mode], listed: ClusterSetupPlanSummary, families: [ClusterSetupPlanSummary],
                           throughDarkbloom: Bool, serving: Bool) -> ClusterOnboardingModeAdvice? {
        func family(_ raw: String) -> ClusterForcedMode? { ClusterGenerationMode(rawValue: raw).flatMap { m in ClusterForcedMode.allCases.first { $0.admits(m) } } }
        let options = modes.map { mode -> ClusterOnboardingModeAdvice.Option in
            let own = family(mode.mode).flatMap { f in ([listed] + families).first { family($0.mode) == f } }
            return .init(mode: mode.mode, planned: own != nil && !mode.shares.isEmpty, fitsNow: own?.fitsNow == true,
                         measuredTokensPerSecond: mode.servedDecodeTokensPerSecond,
                         earlierMeasuredTokensPerSecond: mode.earlierServedDecodeTokensPerSecond,
                         predictedTokensPerSecond: own.flatMap { $0.absolute ? $0.decodeTokensPerSecond : nil },
                         concurrentRequests: mode.concurrentRequests, publicTraffic: mode.publicTraffic)
        }
        return ClusterOnboardingModeAdvice.advise(options, throughDarkbloom: throughDarkbloom, serving: serving)
    }

    /// Whether this Mac's cluster service starts by itself at login: as the running service says (`now`,
    /// `ClusterServiceStatus.startsAtLogin`), else as this run's own service setup left it (`setUp`).
    static func startsAtLogin(now: Bool?, setUp: Bool?) -> Bool? { now ?? setUp }

    /// A planned mode as the screen shows it: each Mac's share (`modeSplit`; `serving`: a model serves now), the decode
    /// rate this pair served it at, and the requests it serves at once.
    func screenMode(_ mode: ClusterSetupPlanSummary.Mode, serving: Bool) -> ClusterOnboardingMode {
        .init(mode: mode.mode, split: Self.modeSplit(mode.shares, here: hereShort, there: thereShort, serving: serving),
              measuredTokensPerSecond: mode.servedDecodeTokensPerSecond, concurrentRequests: mode.concurrentRequests)
    }

    /// `keeping`: the mode each model id keeps (`LiveContext.plan`); the service's re-plan after an update passes the
    /// mode the pair served the model in. `scope`: the way of serving a forwarded command names (`planningScope`).
    /// `chosenModes`: the mode family the person chose per model id (`useMode`), placed only in that family.
    func localPlanModels(keeping: [String: ClusterGenerationMode] = [:], scope: ClusterServingScope? = nil,
                         chosenModes: [String: ClusterForcedMode] = [:]) -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
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
        // Models' pages stay in the file cache: the plan judges each Mac by what its load gate counts, which is all
        // of the cache (58d7371a, de782ff1), and the start that follows reads the cached part at memory speed.
        // Folders copied over the cable (no receipt on this Mac) are repaired before the plan describes them.
        ClusterProductModelStore.updateClusterStore(store, providerConfiguration: settings.service.wizard.providerConfiguration,
                                                    accepts: context.workerAcceptsManifest)
        switch context.plan(peer: peer, keeping: keeping, coordinator: !planningScope(scope).isLocalOnly, chosenModes: chosenModes) {
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
            var keys = [ChoiceKey](), families = [String: [ClusterForcedMode: ChoiceKey]]()
            // A running model is stopped (its memory released) before a new one starts, so its memory is no reason here,
            // and the split planned with it taken is not the one that loads (`modeSplit`). Read once, for the whole list.
            let serving = leadership?.serving == true
            let choices = options.map { option -> ClusterOnboardingModelChoice in
                let gigabytes = String(format: "%.1f GB", Double(option.model.totalBytes) / 1e9)
                let modelID = option.model.modelID
                let title = ClusterOnboardingDeployment.title(modelID: modelID, displayNames: names[modelID] == nil
                    ? namesByArtifact[option.model.artifactSHA256].map { [modelID: $0] } ?? [:] : names)
                guard let plan = option.plan else {
                    keys.append((option.model.folder, "", modelID, [], nil, nil))
                    return .init(title: title, lines: [], blocker: option.blocker ?? "Not offered on these Macs.", modelID: modelID,
                                 validated: approved(option.model.artifactSHA256))
                }
                let offer = option.onOtherMac != false ? nil : copyOffer(model: option.model, peer: peer)
                // One line: size, how it is split (the planner's choice) and each Mac's share; no speed
                // (owner, 2026-11-05: the model and mode choice never quote tok/s).
                let line = ClusterOnboardingDeployment.choiceLine(size: gigabytes, mode: plan.mode,
                    shares: planShares(plan.ranks, localName: localName, perspective: true))
                // Recorded and carried by the start for both Macs, so each Mac is named by its hardware.
                let deployment = ClusterOnboardingDeployment.line(model: title, mode: plan.mode, shares: planShares(plan.ranks, localName: localName))
                keys.append((option.model.folder, ClusterSetupState.planKey(option.model, plan), modelID, plan.alone.filter(\.holds).map(\.memberID),
                             deployment, plan))
                for other in option.familyPlans ?? [] {
                    guard let family = Self.keptFamily(other.mode) else { continue }
                    families[option.model.folder, default: [:]][family] = (option.model.folder, ClusterSetupState.planKey(option.model, other),
                        modelID, other.alone.filter(\.holds).map(\.memberID),
                        ClusterOnboardingDeployment.line(model: title, mode: other.mode, shares: planShares(other.ranks, localName: localName)), other)
                }
                let remedy = serving || plan.fitsNow ? nil : Self.fitRemedy(plan, local: here, peer: there)
                // Served for the owner either way. Once chosen: the planner's one-line reason for tensor parallel or
                // a pipeline, and (serving through Darkbloom) whether public traffic may reach it yet. In the list,
                // under the line: why not tensor parallel, for a model that has it and was split otherwise.
                return .init(title: title, lines: [line] + (plan.modeReason.map { [$0] } ?? []) + (plan.speculationNote.map { [$0] } ?? []),
                             blocker: option.blocker, provision: offer, fitRemedy: remedy, modelID: modelID,
                             publicTraffic: context.settings.privateImageQualification
                                ? "Private unqualified image candidate; public traffic is prohibited." : plan.publicTraffic,
                             tensorParallelNote: plan.tensorParallelNote, validated: approved(option.model.artifactSHA256),
                             split: ClusterOnboardingDeployment.splitMarker(plan.mode),
                             modes: plan.modes.map { $0.map { screenMode($0, serving: serving) } },
                             modeAdvice: plan.modes.flatMap { Self.modeAdvice($0, listed: plan, families: option.familyPlans ?? [],
                                 throughDarkbloom: !planningScope(scope).isLocalOnly, serving: serving) })
            }
            // Open choices first (the models this Mac has), then catalog models no Mac has yet, then the blocked ones.
            typealias Listed = (choice: ClusterOnboardingModelChoice, key: ChoiceKey, artifact: ListedArtifact?)
            var ordered = [Listed]()
            let planned = zip(zip(choices, keys), options).map { pair, option -> Listed in (pair.0, pair.1, ListedArtifact(option.model)) }
            ordered += planned.filter { $0.choice.blocker == nil }
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
                    leader: .init(name: here, holding: .missing, disk: ClusterModelStore.diskSpace(at: ClusterModelStoreLocation.defaultDirectory())),
                    members: [.init(name: there, holding: .complete(folder: model.folder), freeBytes: nil)],
                    linkBytesPerSecond: measuredCopyRate, catalogHasIt: false)
                ordered.append((.init(title: ClusterOnboardingDeployment.title(modelID: model.modelID, displayNames: names),
                    lines: ["\(ClusterModelProvisioning.gigabytes(model.totalBytes)) · only on \(thereShort): copied over the cable first"], blocker: nil,
                    provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
                        quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan), fromOtherMac: true, fitsOnDisk: plan.fitsOnDisk), modelID: model.modelID,
                    validated: approved(model.artifactSHA256)),
                    (model.folder, "", model.modelID, [], nil, nil), ListedArtifact(model)))
            }
            for model in catalogModels(catalogAll, peer: peer) where !held.contains(model.aggregateSHA256 ?? "")
                && ClusterModelCopyTrust.servableArtifacts.contains(model.aggregateSHA256 ?? "") {
                catalog[ordered.count] = model
                var offer = downloadChoice(model, peer: peer)
                offer.validated = approved(model.aggregateSHA256)
                ordered.append((offer, ("", "", model.id, [], nil, nil),
                                model.aggregateSHA256.map { ListedArtifact(aggregate: $0, files: nil) }))
            }
            ordered += planned.filter { $0.choice.blocker != nil }
            // The list keeps one line per artifact and name; the copies and downloads above keep their choices.
            let presented = Self.presentedChoices(ordered.map(\.choice), artifacts: ordered.map(\.artifact),
                                                  servable: ClusterModelCopyTrust.servableArtifacts)
            let position = Dictionary(uniqueKeysWithValues: presented.enumerated().map { ($0.element.index, $0.offset) })
            catalog = Dictionary(uniqueKeysWithValues: catalog.compactMap { index, model in position[index].map { ($0, model) } })
            fromPeer = Dictionary(uniqueKeysWithValues: fromPeer.compactMap { index, model in position[index].map { ($0, model) } })
            lock.withLock {
                self.choices = presented.map { ordered[$0.index].key }; self.catalogChoices = catalog; self.peerChoices = fromPeer
                self.familyChoices = families
            }
            return .success(presented.map(\.choice))
        }
    }

    /// Whether the owner approved the model for clusters (`ClusterPublicModels.declared`, by its artifact): the setup
    /// lists only those. Nil, no judgement, in a private image qualification run (its candidate is never public).
    func approved(_ artifactSHA256: String?) -> Bool? {
        guard !context.settings.privateImageQualification else { return nil }
        guard let artifactSHA256 else { return false }
        return ClusterPublicModels.declared.contains {
            ClusterPairServingGrants.qualifyingArtifact(for: artifactSHA256, runtimeModelID: $0.runtimeModelID) == $0.artifactSHA256
        }
    }

    /// An artifact as the model list compares it: the manifest's aggregate digest, and its files digest when reported.
    struct ListedArtifact: Sendable, Equatable {
        var aggregate: String
        var files: String?

        init(aggregate: String, files: String?) { self.aggregate = aggregate; self.files = files }
        init(_ model: ClusterSetupLocalModel) { self.init(aggregate: model.artifactSHA256, files: model.filesSHA256) }

        func same(_ other: ListedArtifact) -> Bool {
            aggregate == other.aggregate && (files == nil || other.files == nil || files == other.files)
        }
    }

    /// One line per artifact and name (2026-10-25: the catalog's GLM-5.3-Flash, cloned in from the product's store with
    /// the catalog's encoding of the manifest, which the cluster worker does not take, was listed as "not supported on a
    /// cluster yet" under the same model offered from the folder whose manifest the worker pins). A choice that cannot
    /// be served is left out when another choice shows the same name for the same artifact and is offered, or cannot be
    /// served either for a reason that is not the copy itself (the first of equals is kept). A model this build serves
    /// on a cluster (`servable`, by aggregate digest) is never called unsupported for a copy the worker did not take.
    /// Returns the kept choices with their indices, in order.
    static func presentedChoices(_ choices: [ClusterOnboardingModelChoice], artifacts: [ListedArtifact?],
                                 servable: Set<String>) -> [(index: Int, choice: ClusterOnboardingModelChoice)] {
        let unsupported = ClusterSetupPlanning.notClusterModel
        func twins(_ first: Int, _ second: Int) -> Bool {
            guard first != second, choices[first].title == choices[second].title,
                  let one = artifacts[first], let other = artifacts[second] else { return false }
            return one.same(other)
        }
        return choices.indices.compactMap { index -> (index: Int, choice: ClusterOnboardingModelChoice)? in
            var choice = choices[index]
            guard let blocker = choice.blocker else { return (index, choice) }
            let others = choices.indices.filter { twins(index, $0) }
            if others.contains(where: { choices[$0].blocker == nil }) { return nil }
            let said = others.contains { other in
                let theirs = choices[other].blocker == unsupported, mine = blocker == unsupported
                return theirs == mine ? other < index : !theirs
            }
            if said { return nil }
            if blocker == unsupported, let artifact = artifacts[index], servable.contains(artifact.aggregate) {
                choice.blocker = ClusterSetupPlanning.copyNotTaken
            }
            return (index, choice)
        }
    }

    /// What frees the memory a plan needs, in plain words, per Mac that is short now (from the planner's fit). `local`
    /// and `peer` name the two Macs as the screen does.
    static func fitRemedy(_ plan: ClusterSetupPlanSummary, local: String, peer: String) -> String? {
        let words = plan.ranks.compactMap { rank -> String? in
            let mac = rank.local ? local : peer
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
        // The plan the start adopts: the listed one, or the one the question showed for the mode chosen (`localAdopt`).
        guard !forwards, leadership?.serving != true, let plan = lock.withLock({ () -> ClusterSetupPlanSummary? in
            guard choices.indices.contains(index) else { return nil }
            let listed = choices[index]
            guard let family = chosenFamilies[listed.title], Self.replansInFamily(family, listedPlanMode: listed.plan?.mode) else {
                return listed.plan
            }
            return familyChoices[listed.folder]?[family]?.plan ?? listed.plan
        }) else { return nil }
        let localProfile = context.snapshot().local.mac.profile
        var peerProfile: ClusterDeviceProfile?
        if case .reached(let report, _) = context.reachPeer() {
            rememberPeerReport(report, memberID: context.peerFacts?.memberID)
            peerProfile = report.mac.profile
        }
        let macs = (local: here, peer: there)
        let words = plan.ranks.compactMap { rank -> String? in
            guard let profile = rank.local ? localProfile : peerProfile else { return nil }
            return Self.remedy(profile.memory.fit(rank.needBytes), mac: rank.local ? macs.local : macs.peer)
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

    /// The copy and download lines name the leading Mac `here` and the other `there` (for the screen that shows them).
    func copyOffer(model: ClusterSetupLocalModel, peer: ClusterSetupReport) -> ClusterOnboardingProvisionOffer {
        let plan = ClusterModelProvisioning.plan(totalBytes: model.totalBytes,
            leader: .init(name: here, holding: .complete(folder: model.folder), freeBytes: nil),
            members: [.init(name: there, holding: holding(model, in: peer), disk: peer.modelStoreDisk)],
            linkBytesPerSecond: measuredCopyRate, catalogHasIt: true)
        return .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: false, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan), fitsOnDisk: plan.fitsOnDisk)
    }

    func downloadChoice(_ model: CatalogModel, peer: ClusterSetupReport) -> ClusterOnboardingModelChoice {
        let bytes = model.totalSizeBytes ?? Int64(model.sizeGb * 1e9)
        let local = ClusterModelStoreLocation.defaultDirectory()
        let plan = ClusterModelProvisioning.plan(totalBytes: bytes,
            leader: .init(name: here, holding: .missing, disk: ClusterModelStore.diskSpace(at: local)),
            members: [.init(name: there, holding: .missing, disk: peer.modelStoreDisk)],
            linkBytesPerSecond: measuredCopyRate, catalogHasIt: true)
        return .init(title: ClusterOnboardingDeployment.title(modelID: model.id, displayNames: [model.id: model.displayName]),
            lines: ["\(ClusterModelProvisioning.gigabytes(bytes)) · not on these Macs: downloaded from Darkbloom's catalog first"],
            blocker: nil, provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan), fitsOnDisk: plan.fitsOnDisk), modelID: model.id)
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

    func provision(_ index: Int, download: Bool, _ progress: @escaping @Sendable (ClusterOnboardingProgress) -> Void) -> Result<[String], ClusterOnboardingFailure> {
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
                return .failure(.init("\(listed) is not offered on these Macs any more; run `\(Self.cli) cluster` again to choose."))
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
                // Its line ("✓ Downloaded …") is the download's own last report.
                folder = try downloadOnThisMac(model, store: store, progress: progress)
            }
            let manifest = store.appendingPathComponent(folder).appendingPathComponent("manifest.json")
            guard let data = ClusterModelStore.readSmall(manifest) else { throw ClusterSetupFailure("this Mac's \(folder) has no readable manifest") }
            let artifact = try ClusterCatalogArtifact.parse(manifest: data)
            if let peer = lock.withLock({ peerReport }),
               peer.models.contains(where: { artifact.sameEntry(modelID: $0.modelID, version: $0.version, aggregate: $0.artifactSHA256)
                   && ($0.filesSHA256 == nil || $0.filesSHA256 == artifact.filesDigest) }) {
                lines.append("\(ClusterOnboardingDriver.done) \(Self.sentence(thereShort)) already has it")
                return .success(lines)
            }
            guard let pairing = try ClusterSetupLinkExchange.pairing() else { throw ClusterSetupFailure("This Mac is not paired.") }
            let selection = try context.linkSelection()
            let reports = ClusterTransferReports(label: "Copying to \(thereShort)", send: progress)
            let publish = publishingBytes(.copying)
            let outcome = try ClusterSetupLinkExchange.copyModel(pairing: pairing, selection: selection, peerAddress: nil, artifact: artifact,
                source: store.appendingPathComponent(folder), folder: folder) { sent, total in
                    reports.report(done: sent, total: total)
                    publish(sent, total)
                }
            if outcome.alreadyThere {
                lines.append("\(ClusterOnboardingDriver.done) \(Self.sentence(thereShort)) already has it")
            } else {
                // Every file matched the catalog manifest's SHA-256 (the copy fails otherwise).
                let rate = outcome.seconds > 0 ? Double(outcome.sentBytes) / outcome.seconds : 0
                if rate > 0 { try? Data(String(format: "%.0f", rate).utf8).write(to: copyRateFile, options: .atomic) }
                lines.append("\(ClusterOnboardingDriver.done) Copied to \(thereShort) (\(ClusterModelProvisioning.gigabytes(outcome.sentBytes)), \(String(format: "%.1f", outcome.seconds)) s)")
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

    /// The other Mac sends a model only it has: asked over the link, it copies it into this Mac's store (this Mac's
    /// cluster service verifies every file); this Mac follows the staged bytes for the progress.
    func receiveFromPeer(_ model: ClusterSetupLocalModel, store: URL, progress: @escaping @Sendable (ClusterOnboardingProgress) -> Void) throws -> String {
        // The other Mac answers once this Mac's service took (or refused) the copy, so a refusal shows at once.
        _ = try command(.init(op: .sendModel, model: model.folder, text: model.artifactSHA256), seconds: 30)
        let sender = there
        let started = Date()
        var lastBytes: Int64 = -1, lastChange = Date()
        let deadline = started.addingTimeInterval(120 + Double(model.totalBytes) / 50e6)
        let staging = store.appendingPathComponent(ClusterModelStore.stagingName(aggregateSHA256: model.artifactSHA256))
        var lastCheck = Date.distantPast
        let reports = ClusterTransferReports(label: "Copying from \(thereShort)", send: progress)
        let publish = publishingBytes(.copying, toLeader: true)
        while Date() < deadline {
            if let data = ClusterModelStore.readSmall(store.appendingPathComponent(model.folder).appendingPathComponent("manifest.json")),
               let artifact = try? ClusterCatalogArtifact.parse(manifest: data),
               artifact.sameEntry(modelID: model.modelID, version: model.version, aggregate: model.artifactSHA256),
               model.filesSHA256 == nil || model.filesSHA256 == artifact.filesDigest {
                // Every file matched the catalog manifest's SHA-256 (this Mac's service verified each one).
                let seconds = Date().timeIntervalSince(started)
                return "\(ClusterOnboardingDriver.done) Copied from \(thereShort) (\(ClusterModelProvisioning.gigabytes(model.totalBytes)), \(String(format: "%.1f", seconds)) s)"
            }
            if Date().timeIntervalSince(lastCheck) >= 1 {
                lastCheck = Date()
                let bytes = Self.stagedBytes(staging)
                if bytes != lastBytes { lastBytes = bytes; lastChange = Date() }
                // Nothing new staged for 90 s: the other Mac stopped sending (its `darkbloom cluster` service says why).
                if Date().timeIntervalSince(lastChange) > 90 {
                    throw ClusterSetupFailure("\(Self.sentence(sender)) stopped sending \(model.modelID) (nothing arrived for 90 s); run `\(Self.cli) cluster` here again (the copy resumes)")
                }
                if bytes > 0 { reports.report(done: bytes, total: model.totalBytes); publish(bytes, model.totalBytes) }
            }
            usleep(250_000)
        }
        throw ClusterSetupFailure("\(model.modelID) did not arrive from \(sender) in time; run `\(Self.cli) cluster` here again (the copy resumes)")
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
    func downloadOnThisMac(_ model: CatalogModel, store: URL, progress: @escaping @Sendable (ClusterOnboardingProgress) -> Void) throws -> String {
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
        let reports = ClusterTransferReports(label: "Downloading", send: progress)
        let publish = publishingBytes(.downloading)
        let verifying = ClusterOnboardingMailbox<Bool>()
        downloader.byteProgress = { done, total in
            publish(done, total)
            guard done >= total else { reports.report(done: done, total: total); return }
            // Every byte is here; the downloader checks each file and the aggregate digest before it publishes.
            if verifying.take().isEmpty {
                progress(.live({ _ in "Checking the download" }, logged: true))
            }
            verifying.post(true)
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
        // Every file matched the catalog manifest (the downloader checked each one before it published).
        progress(.line("\(ClusterOnboardingDriver.done) Downloaded (\(ClusterModelProvisioning.gigabytes(installed.artifact.totalBytes)), \(String(format: "%.1f", Date().timeIntervalSince(started))) s)"))
        return folder
    }

    func adopt(_ index: Int) -> Result<[String], ClusterOnboardingFailure> {
        // The choice travels with its model's id: a leader that restarted since it made the list plans again and finds it.
        let model = lock.withLock { listedChoices.indices.contains(index) ? (listedChoices[index].modelID ?? listedChoices[index].title) : nil }
        // The leader may stop both parts (up to 5 minutes to drain), wait for their memory (`releaseWaitSeconds`), plan
        // again and retry the device lease: the reply can take that long.
        let request = Self.adoptRequest(index: index, model: model, scope: runScope, family: model.flatMap { keptFamily(forModel: $0) })
        return routed(request, seconds: 600, acting: true, local: { localAdopt(index) }) { $0.lines }
    }

    /// `model`: the id of the model the list showed at `index` (a choice forwarded from another Mac). When this Mac's
    /// list is gone (its service restarted) or no longer shows that model there, it plans again and adopts it by id.
    /// `scope`: the way of serving the forwarded choice was listed for; every plan made here follows it. `family`: the
    /// mode chosen on the forwarding Mac's screen; nil keeps the one chosen here (`useMode`).
    func localAdopt(_ index: Int, model: String? = nil, scope: ClusterServingScope? = nil,
                    family requested: ClusterForcedMode? = nil) -> Result<[String], ClusterOnboardingFailure> {
        var index = index
        if let model, lock.withLock({ !choices.indices.contains(index) || choices[index].title != model }) {
            if case .failure(let failure) = localReachMembers({ _ in }) { return .failure(failure) }
            if case .failure(let failure) = localPlanModels(scope: scope) { return .failure(failure) }
            guard let found = lock.withLock({ choices.firstIndex { $0.title == model } }) else {
                return .failure(.init("\(model) is not offered on these Macs any more; run `\(Self.cli) cluster` again to choose."))
            }
            index = found
        }
        guard var peer = lock.withLock({ peerReport }), var choice = lock.withLock({ choices.indices.contains(index) ? choices[index] : nil }) else {
            return .failure(.init("The list of models is out of date; run `\(Self.cli) cluster` again to choose."))
        }
        var lines = [String]()
        // The person chose another mode family than the listed plan's (`useMode`): the plan the question showed for it
        // is adopted, or, while a model serves, it is planned again in that family once the memory is back.
        let family = requested ?? keptFamily(forModel: choice.title)
        let modeDiffers = Self.replansInFamily(family, listedPlanMode: choice.plan?.mode)
        let serving = leadership?.serving == true || (try? store.readRecord().stopDrain) != nil
        let shown = family.flatMap { family in lock.withLock { familyChoices[choice.folder]?[family] } }
        switch Self.adoption(modeDiffers: modeDiffers, serving: serving, shown: shown != nil) {
        case .listed: break
        case .shown: if let shown { choice = shown }
        case .planAgain:
            if serving {
                // A running part holds its Mac's setup and native device lease: a model change drains both Macs first
                // (each part releases its memory), then changes the setup; `serve` starts the new one.
                publishStart(.init(.stopping))
                if case .failure(let failure) = localStop() { return .failure(failure) }
                lines.append("Stopped both Macs' parts to change the model (each released its memory first).")
                guard drained(seconds: 300) else {
                    return .failure(.init(lines + ["A part did not stop within 5 minutes, so the setup was not changed; run `\(Self.cli) cluster` again."]))
                }
            }
            // The list was planned while the parts held their memory, where a tensor-parallel split may not fit "now"
            // and a pipeline is listed in its place (2026-10-29: GLM-5.3-Flash came back as a pipeline at half the
            // speed, serving the pipeline's context instead of its native one). Plan again once that memory is back,
            // as the re-plan after an update does, and adopt the model's new plan. When planning fails, the listed
            // plan stands (a failed plan replaces neither `choices` nor the decisions `context.adopt` reads): it was
            // priced with less memory than there is now.
            if serving { awaitReleased() }
            let replan = localPlanModels(scope: scope, chosenModes: family.map { [choice.title: $0] } ?? [:])
            if modeDiffers, case .failure(let failure) = replan {
                return .failure(.init(lines + ["\(choice.title) could not be planned in the mode chosen: \(failure.lines.joined(separator: " "))"]))
            }
            if case .success(let replanned) = replan {
                // `localPlanModels` set `choices` in the order of the list it returned. Both are read under one lock,
                // and the entry must still name the chosen model: a plan forwarded from the other Mac may replace
                // `choices` meanwhile.
                let picked = lock.withLock { () -> (index: Int, again: ChoiceKey)? in
                    guard let found = ClusterOnboardingUpdate.servableIndex(of: choice.title, folder: choice.folder, in: replanned,
                                                                            folders: choices.map { $0.folder }),
                          choices.indices.contains(found), choices[found].title == choice.title else { return nil }
                    return (found, choices[found])
                }
                guard let picked else {
                    let reason = replanned.first { ($0.modelID ?? $0.title) == choice.title }?.blocker ?? "not found"
                    return .failure(.init(lines + ["\(choice.title) is not offered on these Macs now (\(reason)); run `\(Self.cli) cluster` again to choose."]))
                }
                if picked.again.key != choice.key, let line = replanned[picked.index].lines.first {
                    lines.append((serving ? "Planned again with both Macs' memory given back: " : "Planned in the mode chosen: ") + "\(line).")
                }
                choice = picked.again
                peer = lock.withLock { peerReport } ?? peer
            }
        }
        let macs = (here: hereShort, there: thereShort)
        var result = context.adopt(folder: choice.folder, planKey: choice.key, peer: peer, here: macs.here, there: macs.there)
        // The device lease is released a moment after the part's process ends.
        for _ in 0..<10 where !result.succeeded && result.lines.joined(separator: " ").contains("lease is currently held") {
            sleep(3)
            result = context.adopt(folder: choice.folder, planKey: choice.key, peer: peer, here: macs.here, there: macs.there)
        }
        guard result.succeeded else { return .failure(.init(lines + result.lines)) }
        lock.withLock { chosenTitle = choice.title }
        // The deployment line the screen and status show, from the plan just adopted. An approval note was about the
        // setup this one replaced: the next check of the coordinator's approvals says why this one isn't offered.
        try? store.updateRecord {
            $0.leadership?.deployment = choice.deployment; $0.leadership?.speculationNote = choice.plan?.speculationNote
            $0.approvalNote = nil
        }
        // Which members the planner said hold this model alone: what failover may serve alone (synced by the lease),
        // bound to the plan just saved so a verdict never outlives its plan.
        let plan = context.savedConfiguration().configuration?.selectedPlanSHA256
        try? store.updateRecord { $0.aloneHolders = choice.alone.sorted(); $0.aloneHoldersPlan = plan }
        return .success(lines + result.lines)
    }

    /// After the Test stage passed: registers the pair with the coordinator as a cluster member when the coordinator
    /// serves a cluster approval whose digests are this Mac's own facts (`ClusterApprovalSync`), on the control leader.
    func register() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .register), seconds: 900, acting: true, local: { localRegister() }) { $0.lines }
    }

    /// The leader's half of `register`. A local-only cluster never asks; a coordinator that serves no matching entry
    /// (404, none listed, any failure) changes nothing and stops nothing. Otherwise both parts stop (each save needs
    /// its device journal empty), each Mac checks the entry against its own files and saves it, the other Mac first,
    /// and both parts start again as cluster members.
    func localRegister() -> Result<[String], ClusterOnboardingFailure> {
        defer { clearRegistrationPending() }
        guard leadership?.scope.isLocalOnly != true else { return .success([]) }
        let providerConfiguration = settings.service.wizard.providerConfiguration
        guard let saved = try? ClusterApprovalAttachment.savedSetup(paths: context.paths, providerConfiguration: providerConfiguration),
              let fetched = ClusterApprovalFetch.fetchBlocking(providerConfiguration: providerConfiguration),
              case .save(let approval) = ClusterApprovalSync.decision(saved: saved, fetched: fetched, now: Date().timeIntervalSince1970,
                                                                         facts: ClusterApprovalAttachment.installedFacts) else {
            return .success([])
        }
        if case .failure(let failure) = localStop() { return .failure(failure) }
        guard drained(seconds: 300) else {
            // The services start the parts again by themselves, with the setups as they were.
            try? store.updateRecord { $0.leadership?.serving = true }
            return .failure(.init("A part did not stop within 5 minutes, so the cluster was not registered with the coordinator."))
        }
        let result = ClusterApprovalSync.run(fetched: .approvals([approval]), paths: context.paths,
            providerConfiguration: providerConfiguration, pairingStore: .default(home: context.paths.homeDirectory, environment: context.paths.environment),
            scratch: store.paths.directory, now: Date().timeIntervalSince1970) { request in
            _ = try command(request, seconds: 180)
        }
        if let note = result.note { try? store.updateRecord { $0.approvalNote = note } }
        if case .failure(let failure) = localServe() { return .failure(.init((result.line.map { [$0 + "."] } ?? []) + failure.lines)) }
        return .success(result.line.map { [$0 + "."] } ?? [])
    }

    /// After `localStop`: waits until both Macs say nothing is left running (at most
    /// `ClusterOnboardingUpdate.releaseWaitSeconds`), so the plan made next prices the memory the new parts will have,
    /// not what the stopped ones held.
    func awaitReleased() {
        let releasedBy = Date().addingTimeInterval(ClusterOnboardingUpdate.releaseWaitSeconds)
        while Date() < releasedBy, case .success(let lines) = localVerifyTeardown(), !ClusterOnboardingUpdate.released(lines) {
            Thread.sleep(forTimeInterval: 2)
        }
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
        if command.op == .serve, command.scope?.localAPIBind != nil { command.localToken = try? LocalEndpoint.loadOrCreateClusterToken() }
        return try ClusterSetupLinkExchange.command(pairing: pairing, selection: try context.linkSelection(), peerAddress: nil,
            body: try JSONEncoder().encode(command), seconds: seconds).reply
    }

    func serve() -> Result<[String], ClusterOnboardingFailure> {
        // The person starts the pair from this Mac: a choice of single-Mac serving made here before no longer stands.
        ClusterSoloChoice.clear(in: store.paths.directory)
        markSoloBlocked(false)
        return routed(.init(op: .serve), acting: true, local: { localServe() }) { $0.lines }
    }

    /// The screen's start through Darkbloom, which asks the coordinator after its test whether to offer the pair
    /// (`register`), marks the record with its process until it decides, on the Mac whose status both Macs read. `serve`
    /// alone never marks: `darkbloom start` and `restart` serve without registering, so nothing would clear the mark.
    func markRegistrationPending() {
        let pid = getpid()
        guard !forwards, let started = Self.processStarted(pid) else { return }
        try? store.updateRecord { $0.registrationPending = .init(pid: pid, started: started); Self.clearTestResults(&$0) }
    }

    /// The start's question to the coordinator is answered (or will not be asked).
    func clearRegistrationPending() {
        if (try? store.readRecord())?.registrationPending != nil { try? store.updateRecord { $0.registrationPending = nil } }
    }

    /// The record's pending registration, while the start that set it runs (the same process: its start time matches).
    var registrationPending: Bool {
        let seen = ClusterOnboardingPendingRegistration.look((try? store.readRecord())?.registrationPending, started: Self.processStarted)
        if let gone = seen.clear {
            // That start ended before it asked the coordinator: compare-and-clear, so a new start's mark stays.
            try? store.updateRecord { $0.registrationPending = ClusterOnboardingPendingRegistration.cleared($0.registrationPending, gone: gone) }
        }
        return seen.pending
    }

    /// When the process `pid` started (microseconds since 1970); nil when none runs or it can't be read.
    static func processStarted(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// A failed test ends the start without asking the coordinator: the start that marked itself publishes that outcome
    /// (the status says it until the next start, a passing test or a stop), so the Mac that joined ends with the same ✗
    /// instead of passing a test of its own. A passing test clears an earlier start's failure.
    func settleTest(_ tested: Result<[String], ClusterOnboardingFailure>) {
        // Compare-and-set against the start's mark, its pid and start time: only that start's process publishes.
        let pid = getpid()
        let mine = Self.processStarted(pid).map { ClusterOnboardingPendingRegistration.Mark(pid: pid, started: $0) }
        let record = try? store.readRecord()
        let marked = mine != nil && record?.registrationPending == mine
        guard marked else {
            // Not a start's test (the serving model's test, its Retry, the scope switch's, a re-test): the status shows the
            // latest test too, through the record's normal update, unless a running start's mark is live (it publishes its
            // own outcome, which this never overwrites).
            try? store.updateRecord { record in
                guard !ClusterOnboardingPendingRegistration.look(record.registrationPending, started: Self.processStarted).pending else { return }
                Self.clearTestResults(&record)
                switch tested {
                case .success(let lines): record.startTestPassed = lines.first ?? ""
                case .failure(let failure):
                    let first = failure.lines.first ?? "The test request failed"
                    record.lastTestFailure = first.hasSuffix(".") ? String(first.dropLast()) : first
                }
            }
            return
        }
        switch tested {
        case .success(let lines):
            // The marked start's test passed: its outcome, with the time its screen shows. A local start is over; through
            // Darkbloom the mark stays until the coordinator decides.
            let local = record?.leadership?.scope.isLocalOnly == true
            try? store.updateRecord { record in
                guard record.registrationPending == mine else { return }
                Self.clearTestResults(&record)
                record.startTestPassed = lines.first ?? ""
                if local { record.registrationPending = nil }
            }
        case .failure(let failure):
            let first = failure.lines.first ?? "The test request failed"
            try? store.updateRecord { record in
                guard record.registrationPending == mine else { return }
                record.registrationPending = nil
                Self.clearTestResults(&record)
                record.startTestFailure = first.hasSuffix(".") ? String(first.dropLast()) : first
            }
        }
    }

    func setScope(_ scope: ClusterServingScope) -> Result<[String], ClusterOnboardingFailure> {
        // Long enough for the rank 0 part to stop (it releases its memory first) and start again.
        routed(.init(op: .scope, scope: scope), seconds: Self.scopeRestartSeconds + 30, acting: true, local: { localSetScope(scope) }) { $0.lines }
    }

    static let scopeRestartSeconds: Double = 400

    /// Saves how the cluster serves on this (control leader) Mac and gives the member the same scope. While the
    /// cluster serves, the Mac that runs rank 0 starts its part again that way (its service keys the part by the
    /// scope); this waits until that part started again, so the readiness asked next is the new part's.
    /// What a ready pair's status says of its start and its latest test: the start not over (through Darkbloom it still
    /// asks the coordinator whether to offer the pair; locally its test is not answered yet), a failed test with its note,
    /// or `serving` with the time of the test that passed (the Mac that joined ends with it).
    static func outcomeLines(record: ClusterSetupRecord?, pending: Bool, local: Bool, model: String, serving: String) -> [String] {
        if pending { return [local ? ClusterOnboardingReady.testingLine(model: model) : ClusterOnboardingReady.offerPendingLine(model: model)] }
        if let failure = record?.startTestFailure {
            return [ClusterOnboardingNotServing.statusLine(model: model, reason: failure),
                    local ? ClusterOnboardingReady.localTestFailedNote : ClusterOnboardingReady.testFailedNote]
        }
        if let failure = record?.lastTestFailure {
            return [ClusterOnboardingNotServing.statusLine(model: model, reason: failure), ClusterOnboardingReady.lastTestFailedNote]
        }
        return [serving] + (record?.startTestPassed.map { [ClusterOnboardingReady.startTestPassedLine($0)] } ?? [])
    }

    /// The status of a pair set to serve through Darkbloom whose start is over and that serves on the leading Mac's API:
    /// no cluster approval is attached, so the coordinator can't form it and it earns nothing. It says it isn't serving
    /// through Darkbloom and why (the latest approval note, or a coordinator that can't take a cluster member), where it
    /// answers meanwhile, then the rest of `outcome` (the test's line). Both Macs' windows and `cluster status` read it
    /// (DevNet, 2026-11-04: "✓ Serving … (earning through Darkbloom)" while the coordinator never had the pair).
    static func notOfferedLines(model: String, ready: ClusterOnboardingReady, note: String?, outcome: [String]) -> [String] {
        let why = ready.notice == ClusterLocalServing.notice ? "the coordinator could not be reached or has no cluster support" : note
        return [ClusterOnboardingNotServing.statusLine(model: model, reason: ClusterOnboardingReady.notOfferedReason(why)), ready.meanwhileLine]
            + outcome.dropFirst()
    }

    /// The status of a pair offered for pairing that doesn't serve yet: why, or what it waits for, in one line. The
    /// leading Mac's setup screen adds its next step under its ✗ (`ClusterOnboardingNotServing.remedy`, which names its
    /// Retry). The status carries none: `cluster status` and the other Mac's window read it, and neither has a Retry
    /// (the DevNet traffic run, 2026-11-04).
    static func offeredWaitLines(model: String, reason: String?, wait: String) -> [String] {
        [ClusterOnboardingNotServing.statusLine(model: model, reason: reason ?? wait)]
    }

    /// The record with the pair's new way of serving (`localSetScope`): no earlier test's result holds for it.
    static func savingScope(_ scope: ClusterServingScope, _ record: inout ClusterSetupRecord) {
        record.leadership?.scope = scope
        clearTestResults(&record)
    }

    /// No published test result: the next start or serve, a scope switch and a stop.
    static func clearTestResults(_ record: inout ClusterSetupRecord) {
        record.startTestFailure = nil
        record.startTestPassed = nil
        record.lastTestFailure = nil
    }

    func localSetScope(_ scope: ClusterServingScope) -> Result<[String], ClusterOnboardingFailure> {
        guard let current = leadership else { return .failure(.init("\(Self.sentence(hereShort)) is not paired with a cluster.")) }
        let saved = scope.isLocalOnly ? "Saved on \(here): the cluster serves locally only and never contacts a coordinator."
            : scope.addsLocalAPI ? "Saved on \(here): the cluster serves through Darkbloom, and on its local API with you first "
                + "(Darkbloom pauses while you use it)."
            : "Saved on \(here): the cluster serves through Darkbloom (its leading Mac registers with the coordinator)."
        if current.scope == scope { return .success([saved]) }
        let startsBefore = rankZeroStarts()
        do {
            try store.updateRecord { Self.savingScope(scope, &$0) }
        } catch {
            return .failure(.init("\(Self.sentence(hereShort))'s setup record could not be saved: \(ClusterConsoleText.bounded(String(describing: error), maximum: 200))"))
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
        guard (try? store.readRecord().stopDrain) == nil else {
            return .failure(.init("\(Self.sentence(hereShort)) is still finishing a stop. Run `\(Self.cli) cluster stop` again before serving."))
        }
        let title = lock.withLock { chosenTitle } ?? context.savedConfiguration().configuration?.publicModelID
        do {
            // A new start: an earlier start's failed test is no longer the pair's outcome.
            try store.updateRecord { $0.leadership?.serving = true; if let title { $0.leadership?.modelName = title }; Self.clearTestResults(&$0) }
            // The line of the setup that runs, so the member shows the same one when it leads.
            let deployment = savedDeployment() ?? leadership?.deployment
            try store.updateRecord { $0.leadership?.deployment = deployment }
            _ = try command(.init(op: .serve, model: title, deployment: deployment, scope: leadership?.scope))
        } catch let failure as ClusterSetupFailure {
            return .failure(.init(["\(Self.sentence(there)) was not started yet: \(failure.text)", startsWhenItAnswers]))
        } catch {
            return .failure(.init(["\(Self.sentence(there)) was not started yet: \(error)", startsWhenItAnswers]))
        }
        return .success(["Started \(thereShort)'s part over the cable (its cluster service runs it); \(hereShort)'s service runs its own."])
    }

    var startsWhenItAnswers: String {
        "\(Self.sentence(hereShort))'s cluster service starts \(thereShort)'s part as soon as it answers; run `\(Self.cli) cluster` here to see how it is going."
    }

    /// The Mac that runs rank 0 and the serving API, and its session.
    func session() -> (local: Bool, session: ClusterServiceStatus.Session?, child: ClusterServiceStatus.Child?, error: String?) {
        if context.savedConfiguration().configuration?.role == .leader {
            let live = context.observe(link: false)
            let ranks = max(live.members.count, context.savedConfiguration().configuration?.peers.count ?? 2)
            return (true, .init(observed: live.observed, ready: live.ready, readyRanks: live.readyRanks, ranks: ranks, port: live.port,
                detail: live.detail ?? live.sessionPhase, readyRankList: live.members.filter(\.ready).map(\.rank)), nil, nil)
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
        let began = Date()
        lock.withLock { waitBegan = began }
        let deadline = began.addingTimeInterval(Self.readyWaitSeconds)
        var said: String?, shown: String?
        var seen = [String: Int](), previous: String?
        let viewerRank = context.savedConfiguration().configuration?.localRank
        var polls = 0
        while Date() < deadline {
            // Single-Mac serving on either Mac never ends by itself: the wait ends at once with it named, never a loop of
            // part ends (read every few polls: it asks the other Mac over the cable).
            // Different versions come first: the older Mac must update before anything else can be fixed.
            if polls % Self.soloServingEveryPolls == 0 {
                if let split = versionSplit() { return .failure(split.failure) }
                if let solo = soloServingFailure() { return .failure(solo) }
            }
            polls += 1
            var once: (ready: ClusterOnboardingReady?, line: String, parts: [ClusterOnboardingStartProgress.Part]?)
            if forwards {
                switch forward(.init(op: .readiness), seconds: 30) {
                case .success(let reply): once = (reply.ready, reply.progress ?? "starting", nil)
                case .failure(let failure): once = (nil, failure.lines.joined(separator: " "), nil)
                }
            } else {
                once = readinessOnce()
                // The Mac that joined shows the same parts (`publishStart`).
                if once.ready == nil { publishStart(.init(.loading, parts: once.parts), every: 1) }
            }
            if let ready = once.ready { return .success(ready) }
            if let refused = Self.localNetworkRefusalLines(line: once.line, otherMac: Self.sentence(there), app: ClusterService.appName) {
                return .failure(.init(refused + lastErrors(fallback: nil, own: ownPart(since: began), refusalSaid: true)))
            }
            // Each line once (a part that keeps restarting alternated two lines every 2 s); a part that ends the
            // same way again and again is said and the wait ends: both Macs keep trying by themselves. An end is
            // counted when the line turns to it (a poll that sees the same end again is the same end).
            if once.line != previous { seen[once.line, default: 0] += 1 }
            previous = once.line
            if once.line.contains("part ended"), seen[once.line, default: 0] >= Self.sameEndsBeforeSaying {
                let own = ownPart(since: began)
                return .failure(.init([Self.keepsEndingTitle(once.line, own: own.child, ownWorker: own.worker) + "."]
                    + lastErrors(fallback: nil, own: own)))
            }
            if seen[once.line] == 1, once.line != said { said = once.line }
            // The line, then one row per Mac (`ClusterOnboardingLoadRows`), its countdown left out so a row changes only
            // when that Mac's part does.
            let steady = (once.parts ?? []).map { part -> ClusterOnboardingStartProgress.Part in
                var steady = part
                steady.restartIn = nil
                return steady
            }
            if let said {
                let line = ([said] + ClusterOnboardingStartWords.partRows(steady, viewerRank: viewerRank, width: nil)).joined(separator: "\n")
                if line != shown { progress(line); shown = line }
            }
            usleep(Self.readinessPollMicroseconds)
        }
        return .failure(.init(["The cluster did not report ready within 15 minutes."] + lastErrors(fallback: said)))
    }

    /// Every this many readiness polls (about 2 s), the wait reads single-Mac serving on both Macs (`soloServing`).
    static let soloServingEveryPolls = 4
    /// How long a start waits for the cluster to report ready ("within 15 minutes").
    static let readyWaitSeconds: TimeInterval = 900
    /// The same part end seen this many times stops the wait on screen (the service keeps restarting it).
    static let sameEndsBeforeSaying = 3
    /// Between readiness polls: a ready pair is reported within this (plus one poll, ~0.7 s over the cable), not up
    /// to 2 s later, in a start that now takes about 10 s.
    static let readinessPollMicroseconds: useconds_t = 500_000

    /// This Mac's part, read once, and whether its own worker ended since `since` (`ownWorker`): the ✗ title and the
    /// per-Mac lines are given the same read.
    func ownPart(since: Date) -> (child: ClusterServiceStatus.Child?, worker: OwnWorker) {
        let child = ClusterService.published()?.child
        return (child, ownWorker(child, since: since))
    }

    /// Which Mac's worker ended since `since`, when this Mac's part ended "closed" (`OwnWorker`), from this Mac's
    /// incident log; unknown when this Mac doesn't lead.
    func ownWorker(_ own: ClusterServiceStatus.Child?, since: Date) -> OwnWorker {
        guard own?.lastError == Self.linkClosedError else { return .notSeen }
        guard let configuration = context.savedConfiguration().configuration, configuration.role == .leader else { return .unknown }
        let rank = configuration.localRank
        return Self.ownWorker(inIncidentLog: .forThisInstall(), since: since, rank: rank,
                              otherRanks: configuration.peers.indices.filter { $0 != rank })
    }

    /// Whose worker the `worker_crashed` records this Mac's part made since `since` name (`source` "leader", in `log`:
    /// this install's, `ClusterIncidentLog.forThisInstall`, so another install's records never count). The leader records the other Mac's worker ending with that same source and reason, so only
    /// the message tells (the DevNet run, A-4: the member's kills read "…closed | rank 1 follower said: …", the leader's
    /// own "…closed | <user>-worker-exit-v1 rank=0 termination=signalled(9)"):
    /// - `.ended`: this Mac's rank's own worker exit (`ClusterWorkerOwnerService.workerExitMarker`, whatever its prefix);
    /// - `.notSeen`: what the other Mac's follower said (`DistributedInstalledSession.followerSaid`): B17's words;
    /// - `.unknown`, so neither Mac is blamed: no record says, both do, or the log is missing or can't be read (its
    ///   `loadError`: unreadable, too large, malformed, another schema). A field this build doesn't know is ignored.
    static func ownWorker(inIncidentLog log: ClusterIncidentLog, since: Date, rank: Int, otherRanks: [Int]) -> OwnWorker {
        let feed = log.feed()
        guard feed.loadError == nil, !feed.epoch.isEmpty else { return .unknown }
        let crashes = feed.incidents.filter {
            $0.ts >= since.timeIntervalSince1970 && $0.source == "leader"
                && ($0.reasonCode == "worker_crashed" || $0.guidanceCode == "worker_crashed")
        }.map(\.message)
        let ownExit = ClusterWorkerOwnerService.workerExitMarker + "\(rank) termination="
        let otherSaid = otherRanks.map(DistributedInstalledSession.followerSaid(rank:))
        let here = crashes.contains { $0.contains(ownExit) }
        let there = crashes.contains { message in otherSaid.contains { message.contains($0) } }
        switch (here, there) {
        case (true, false): return .ended
        case (false, true): return .notSeen
        default: return .unknown
        }
    }

    /// The last error each Mac's part reported, one line per Mac, also for parts still running (shown on screen after a
    /// start that did not finish, instead of a log path). `own`: this Mac's part as the caller already read it.
    /// `refusalSaid`: the ✗ already says a Local Network refusal and what to do (`errorLines`).
    func lastErrors(fallback: String?, own snapshot: (child: ClusterServiceStatus.Child?, worker: OwnWorker)? = nil,
                    refusalSaid: Bool = false) -> [String] {
        let other: (child: ClusterServiceStatus.Child?, unreachable: String?, version: String?)
        do {
            let status = try JSONDecoder().decode(ClusterServiceStatus.self, from: try command(.init(op: .status), seconds: 10))
            other = (status.child, nil, status.pairUpdate?.running)
        } catch {
            other = (nil, (error as? ClusterSetupFailure)?.text ?? "\(error)", nil)
        }
        // This start's: since its wait began (the ✗'s diagnostics file too), else no longer ago than a wait lasts.
        let own = snapshot ?? ownPart(since: lock.withLock { waitBegan } ?? Date().addingTimeInterval(-Self.readyWaitSeconds))
        var lines = Self.errorLines(here: Self.sentence(here), there: Self.sentence(there), own: own.child,
                                    other: other.child, otherUnreachable: other.unreachable, ownWorker: own.worker,
                                    refusalSaid: refusalSaid, thisVersion: ProviderCore.version, otherVersion: other.version)
        if let fallback { lines.append("Last progress: \(fallback).") }
        return lines.map { ClusterConsoleText.boundedAtWord(context.clean($0), maximum: 300) }
    }

    /// A part's last error when its link to the other Mac closed (`ClusterLinkControlChannel.closed`): its end follows
    /// the other Mac's side ending (its worker, which that Mac's service restarts without a report) or the cable
    /// dropping, or this Mac's own worker ending (its pipe closes the same way; `OwnWorker`).
    static let linkClosedError = "closed"

    /// Which Mac's worker ended while the start waited, when this Mac's part ended "closed" (`ownWorker`): a part whose
    /// own worker dies ends "closed" too (the worker's pipe), so "closed" alone doesn't say which side ended. `ended`:
    /// this Mac's; `notSeen`: not this Mac's, the other Mac's (B17's words; also when the link didn't close); `unknown`:
    /// neither Mac is named.
    enum OwnWorker: Sendable, Equatable { case ended, notSeen, unknown }

    /// The ✗ title once a part keeps ending the same way (`waitReady`): the ends the live row says, without its progress
    /// word ("starting; "). When this Mac's part ends only because its link closed, the title names the other Mac's side
    /// (the candidate on pair-2, c3 B17: the member's worker was killed three times, and the ✗ blamed the leader, whose
    /// part only lost its link), this Mac when its own worker ended, and neither when that can't be told (`OwnWorker`).
    static func keepsEndingTitle(_ line: String, own: ClusterServiceStatus.Child?, ownWorker: OwnWorker = .notSeen) -> String {
        let title = "A part keeps ending the same way: "
        guard own?.lastError == linkClosedError else { return title + endsClause(line) }
        let end = "(" + (own?.lastEnd.map { $0 + ": " } ?? "") + "closed)"
        switch ownWorker {
        case .ended:
            return title + "this Mac's worker keeps ending, so this Mac's part ends with it \(end) and starts again by itself"
        case .unknown:
            return title + "this Mac's part ends when its link closes \(end) and starts again by itself; "
                + "whether this Mac's worker or the other Mac's side closed it can't be told from here"
        case .notSeen:
            return title + "the link to the other Mac keeps closing, so this Mac's part ends with it \(end) "
                + "and starts again by itself; the other Mac's worker ended or the cable dropped"
        }
    }

    /// The live row from the clause that names an end, so the title reads as a whole sentence: the whole row when its
    /// first part names an end itself ("rank 0 on … ended (…); it starts again by itself; …"), else from the last "; "
    /// before the first "'s part ended", which drops only a progress head ("starting", "1 of 2 parts ready (…; …)",
    /// "waiting for …: <a failure with its own "; ">") and never an opening clause.
    static func endsClause(_ line: String) -> String {
        let head = line.range(of: "; ").map { line[..<$0.lowerBound] } ?? Substring(line)
        guard !head.contains("ended"), let end = line.range(of: "'s part ended"),
              let cut = line.range(of: "; ", options: .backwards, range: line.startIndex..<end.lowerBound) else { return line }
        return String(line[cut.upperBound...])
    }

    /// One line per Mac: the last error each Mac's part reported (`lastErrors`). `refusalSaid`: the Local Network ✗ already
    /// says the refusal and what to do, so a part refused by it is said plainly instead of in its follower's own words
    /// (the pair-2 re-test, R-4); any other ✗ keeps the part's reason (A-3).
    static func errorLines(here: String, there: String, own: ClusterServiceStatus.Child?, other: ClusterServiceStatus.Child?,
                           otherUnreachable: String?, ownWorker: OwnWorker = .notSeen, refusalSaid: Bool = false,
                           thisVersion: String? = nil, otherVersion: String? = nil) -> [String] {
        // The Macs run different versions (one updated alone): that is the cause, with the Mac and the command, and no
        // guess at the link. `otherVersion` is what the other Mac's supervisor publishes (`pairUpdate.running`).
        if let split = ClusterOnboardingVersionSplit.detect(thisVersion: thisVersion, otherVersion: otherVersion,
                                                            other: there.prefix(1).lowercased() + there.dropFirst()) {
            return [split.title + "."] + split.remedies
        }
        func line(_ mac: String, _ child: ClusterServiceStatus.Child?, unreachable: String? = nil) -> String {
            if let unreachable { return "\(mac): did not answer over the cable (\(unreachable))." }
            guard let child else { return "\(mac): no report." }
            if refusalSaid, child.lastError?.hasPrefix(ClusterService.localNetworkReasonPrefix) == true {
                return "\(mac): its part " + (child.running ? "is running and " : "") + "can't reach the local network."
            }
            if let error = child.lastError { return "\(mac): \(error)" + (child.running ? " (its part is still running)." : ".") }
            if let end = child.lastEnd, !child.running { return "\(mac): its part ended (\(end))." }
            return "\(mac): " + (child.running ? "its part is running, no error reported." : "its part is not running.")
        }
        // This Mac's part ended because its link closed: the cause is on the other Mac's side (or the cable) unless this
        // Mac's own worker ended (`OwnWorker`). A member whose service kept its part running and reported no error
        // doesn't report its worker restarting, so it isn't cleared, and the line says what can't be known from here.
        guard own?.lastError == linkClosedError, otherUnreachable == nil else {
            return [line(here, own), line(there, other, unreachable: otherUnreachable)]
        }
        let end = "(\(own?.lastEnd ?? "ended"): closed)"
        // This Mac's own worker ended (its incident log): this Mac is named, and the other Mac keeps its own report.
        if ownWorker == .ended {
            return ["\(here): its worker ended unexpectedly, and its part ended with it \(end).", line(there, other)]
        }
        let ownLine = ownWorker == .unknown
            ? "\(here): its part ended when its link closed \(end); it can't tell whether its own worker or the other Mac's side closed it."
            : "\(here): its part ended because the link to the other Mac closed \(end)."
        guard let other, other.running, other.lastError == nil else { return [ownLine, line(there, other)] }
        return [ownLine, "\(there): its service reports its part running and no error, but it doesn't report its worker "
            + "restarting, so the cause can't be read from here; that Mac's worker log says why."]
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
    /// `perspective`: the line is shown now, so the screen's words name the Macs; a line recorded for both names each
    /// by its hardware.
    func savedDeployment(perspective: Bool = false) -> String? {
        guard case .success(let reference?) = context.savedConfiguration().reference,
              let saved = try? ClusterConfigurationStore(paths: context.paths).load(reference: reference),
              let stages = try? saved.capability.selection(planSHA256: saved.configuration.selectedPlanSHA256).stages
                .sorted(by: { $0.rank < $1.rank }),
              stages.allSatisfy({ saved.configuration.peers.indices.contains($0.rank) }) else { return nil }
        let members = (try? store.readRecord())?.control?.members ?? []
        let names = Dictionary(members.map { ($0.memberID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let labels = perspective ? (local: hereShort, peer: thereShort) : nil
        let shares = stages.map { stage -> ClusterOnboardingDeployment.Share in
            let id = saved.configuration.peers[stage.rank].id
            return .init(name: names[id] ?? id, layers: stage.sourceLayerEnd - stage.sourceLayerStart,
                         label: labels.map { stage.rank == saved.configuration.localRank ? $0.local : $0.peer })
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
        return .init(servedBy: now.local ? here : there, port: port, deployment: savedDeployment(perspective: true) ?? leadership?.deployment,
                     notice: notice, network: byChoice ? (leadership?.scope.reachableFromNetwork ?? false) : nil, split: savedSplit())
    }

    /// How the setup this Mac saved (what runs) splits its model, as the serving line marks it (both Macs save it).
    func savedSplit() -> String? {
        guard case .success(let reference?) = context.savedConfiguration().reference,
              let saved = try? ClusterConfigurationStore(paths: context.paths).load(reference: reference) else { return nil }
        return ClusterOnboardingDeployment.splitMarker(saved.configuration.selectedGenerationMode.rawValue)
    }

    /// One look at the cluster from the control leader: ready (where the serving API listens) or a progress line.
    /// `parts`: each Mac's part while the parts load (the start's per-Mac rows), when the session is observed.
    func readinessOnce() -> (ready: ClusterOnboardingReady?, line: String, parts: [ClusterOnboardingStartProgress.Part]?) {
        let published = ClusterService.published()
        if let control = published?.control, control.mode == "alone" {
            // Only THIS service's solo server counts as ready, never whatever answers on the port.
            switch ClusterService.soloReadiness(published) {
            case .ready: return (.init(servedBy: here, port: ClusterService.soloPort(of: published), deployment: "Serving \(leadership?.modelName ?? "the model") on \(here) alone while \(thereShort) is away"), control.line, nil)
            case .loading: return (nil, control.line + " (loading)", nil)
            case .foreign: return (nil, control.line + " (another program answers on port \(ClusterService.soloPort(of: published)), so \(hereShort)'s solo server cannot serve there)", nil)
            }
        }
        if let updating = published?.updating { return (nil, updating, nil) }
        // Inside the absence grace: not ready, and the line says how long until this Mac serves alone.
        if let control = published?.control, control.mode == "waiting" { return (nil, control.line, nil) }
        if let offered = offeredLine() { let once = offeredReadiness(offered, own: published); return (once.ready, once.line, nil) }
        let now = session()
        var line: String
        if let session = now.session, session.observed {
            if session.ready, let port = session.port {
                return (ready(now, port: port), "ready", nil)
            }
            line = "\(session.readyRanks) of \(session.ranks) parts ready" + (session.detail.map { " (\($0))" } ?? "")
        } else if let child = now.child, let end = child.lastEnd, !child.running, Self.endShown(child) {
            line = "rank 0 on \(there) ended (\(end)\(child.lastError.map { ": " + $0 } ?? "")); it starts again by itself"
        } else if let error = now.error {
            line = "waiting for \(there): \(error)"
        } else {
            line = "starting"
        }
        // This Mac's own part, when it is the one that keeps ending.
        line += Self.endedClause(mac: hereShort, child: ClusterService.published()?.child) ?? ""
        // Members are asked for their own part only when rank 0 is here.
        let member = now.local ? try? JSONDecoder().decode(ClusterServiceStatus.self, from: try command(.init(op: .status), seconds: 10)) : nil
        // macOS keeps the other Mac's follower off the local network: nothing changes until someone allows it (P2-1).
        if Self.otherMacRefused(member?.child),
           Self.refusalIsCurrent(own: ClusterService.published()?.child, now: Date().timeIntervalSince1970) {
            return (nil, Self.localNetworkLine(forwarded: answering), nil)
        }
        line += Self.endedClause(mac: thereShort, child: member?.child) ?? ""
        let parts = now.session.flatMap { session -> [ClusterOnboardingStartProgress.Part]? in
            guard session.observed, let ready = session.readyRankList else { return nil }
            let localRank = context.savedConfiguration().configuration?.localRank
            let layers = shareLayers()
            return (0..<session.ranks).map { rank in
                let child = rank == localRank ? ClusterService.published()?.child : (now.local ? member?.child : now.child)
                return Self.part(rank: rank, ready: ready.contains(rank), child: child, layers: layers[rank])
            }
        }
        return (nil, line, parts)
    }

    /// One Mac's part while the parts load: ready, loading (its process runs), ended (and starts again), or starting.
    static func part(rank: Int, ready: Bool, child: ClusterServiceStatus.Child?, layers: String?) -> ClusterOnboardingStartProgress.Part {
        if ready { return .init(rank: rank, state: .ready, layers: layers) }
        guard let child else { return .init(rank: rank, state: .starting, layers: layers) }
        if child.running { return .init(rank: rank, state: .loading, layers: layers) }
        if let end = child.lastEnd, endShown(child) { return .init(rank: rank, state: .ended, layers: layers, end: end, restartIn: child.restartInSeconds) }
        return .init(rank: rank, state: .starting, layers: layers)
    }

    /// Each rank's share of the model's layers in the saved setup ("47–93"), by rank.
    func shareLayers() -> [Int: String] {
        guard case .success(let reference?) = context.savedConfiguration().reference,
              let saved = try? ClusterConfigurationStore(paths: context.paths).load(reference: reference),
              let stages = try? saved.capability.selection(planSHA256: saved.configuration.selectedPlanSHA256).stages else { return [:] }
        return Dictionary(stages.filter { $0.sourceLayerEnd > $0.sourceLayerStart }
            .map { ($0.rank, "\($0.sourceLayerStart)\u{2013}\($0.sourceLayerEnd - 1)") }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether the other Mac's refusal says how its follower's dials go now: this Mac's part (rank 0, whose session hosts
    /// the listener the follower dials) has run long enough for one more dial to reach it. The follower redials at most
    /// about 1.25 s apart (`ClusterLinkControlClient.connectLoop`: 20 ms doubling to 1 s, plus up to a quarter's jitter)
    /// and logs only a change, so before that, Local Network turned on meanwhile would not show yet.
    ///
    /// `acrossRestarts` (a status read): also between this Mac's parts and early in the next one, when its last part ran
    /// that long. A refused member makes this Mac's part end after its wait for the link (32 s on pair-2) and start again,
    /// so a status read would otherwise say the refusal only in each part's last seconds. The follower didn't get through
    /// to that part, so the refusal stands until the next part's listener has had the same chance; a setting turned on
    /// between parts shows once the follower reaches it (its refusal then clears). A start's own wait keeps the strict
    /// rule: a Retry just after the setting was turned on must not end at once on a refusal not yet tested.
    static func refusalIsCurrent(own: ClusterServiceStatus.Child?, now: Double, acrossRestarts: Bool = false) -> Bool {
        guard let own else { return false }
        if own.running, let started = own.startedAt, now - started >= refusalSettleSeconds { return true }
        return acrossRestarts && (own.lastRunSeconds ?? 0) >= refusalSettleSeconds
    }

    /// How long this Mac's part runs before a refusal counts (`refusalIsCurrent`): its start up to its listener, plus a
    /// dial and its handshake.
    static let refusalSettleSeconds: Double = 20

    /// Whether the other Mac's part reports that macOS keeps it off the local network: its follower's refusal while it
    /// runs and dials. An ended part's refusal is history (a Retry that starts a stopped pair again reads it before that
    /// Mac's new follower has dialled).
    static func otherMacRefused(_ child: ClusterServiceStatus.Child?) -> Bool {
        child?.running == true && child?.lastError?.hasPrefix(ClusterService.localNetworkReasonPrefix) == true
    }

    /// The ✗ when the other Mac can't reach this one over the cable for that reason: why, and what to do there. It can't
    /// clear until someone turns the setting on, so the wait ends at once. `then`: the step once it's on (`cluster status`
    /// names its command instead: `ClusterLocalNetworkAccess.statusWords`).
    static func localNetworkRefusalLines(otherMac: String, app: String, row: String = ClusterOnboardingCommand.localNetworkRow,
                                         then: String = "Then choose Retry here") -> [String] {
        ["The other Mac can't reach this Mac over the cable: macOS keeps \(app) there off the local network",
         "\(otherMac): " + ClusterOnboardingDriver.localNetworkSteps(app: app, row: row, screen: "that Mac's screen")
            + " (on a Mac with no display, through Screen Sharing). \(then)."]
    }

    /// The live row's line once the other Mac's part reports that refusal (`readinessOnce`).
    static let otherMacLocalNetworkLine = "the other Mac can't reach this Mac over the cable (Local Network privacy)"
    /// The same line on the screen of the Mac that forwarded the readiness (`execute`): the refused part is that Mac's.
    static let thisMacLocalNetworkLine = "this Mac can't reach the other Mac over the cable (Local Network privacy)"

    /// `readinessOnce`'s line for a refused member part, worded for the screen that shows it: this Mac's, or the Mac
    /// whose forwarded readiness this Mac answers (`answering`).
    static func localNetworkLine(forwarded: Bool) -> String {
        forwarded ? thisMacLocalNetworkLine : otherMacLocalNetworkLine
    }

    /// `waitReady`'s ✗ for a refusal `line` (`localNetworkLine`): what to do on the Mac it names. Nil for any other line.
    static func localNetworkRefusalLines(line: String, otherMac: String, app: String) -> [String]? {
        switch line {
        case otherMacLocalNetworkLine: return localNetworkRefusalLines(otherMac: otherMac, app: app)
        case thisMacLocalNetworkLine: return ClusterOnboardingDriver.localNetworkBlockedLines(app: app, then: "then choose Retry here")
        default: return nil
        }
    }

    /// "; <mac>'s part ended (<end>: <last error>) and starts again by itself" while that part keeps ending: what the
    /// start's screen adds to its loading line (`readinessOnce`) and `cluster status` gives as its reason (`localStatus`).
    static func endedClause(mac: String, child: ClusterServiceStatus.Child?) -> String? {
        guard let child, !child.running, let end = child.lastEnd, endShown(child) else { return nil }
        return "; \(mac)'s part ended (\(end)\(child.lastError.map { ": " + $0 } ?? "")) and starts again by itself"
    }

    /// Whether a part's end is said in the live rows (`readinessOnce`, `offeredReadiness`) as an end that starts again by
    /// itself, on either Mac: not a clean stop ("stopped", or exit 0 with no reason), which a planned switch makes on both
    /// Macs (the DevNet run, A-10, B18); an exit 0 that says why (a refused dial, A-3) is still said.
    static func endShown(_ child: ClusterServiceStatus.Child) -> Bool {
        guard let end = child.lastEnd else { return false }
        return !(end == "stopped" || (end == "exit 0" && child.lastError == nil))
    }

    /// The offered line when the saved setup carries a current approval and the cluster serves publicly: both Macs
    /// then run the coordinator-formed pair's members (`ClusterService`, `memberArguments`), with no local API.
    func offeredLine() -> String? {
        guard let member = context.savedConfiguration().configuration?.nativeMember,
              ClusterApprovalLifetime.offers(member, scope: leadership?.scope ?? .publicServing, now: Date().timeIntervalSince1970)
        else { return nil }
        return ClusterApprovalLifetime.offeredLine(member)
    }

    /// Ready once both Macs' members are registered with the coordinator (each part's notice says so). `published`: this
    /// Mac's cluster service's status, whose part or relay serves this Mac's own port for the pair's API, which the card
    /// prints once it is up (`ownPairAPIPort`).
    func offeredReadiness(_ offered: String, own published: ClusterServiceStatus?) -> (ready: ClusterOnboardingReady?, line: String) {
        let own = published?.child
        let peer = (try? JSONDecoder().decode(ClusterServiceStatus.self, from: command(.init(op: .status), seconds: 10)))?.child
        func registered(_ child: ClusterServiceStatus.Child?) -> Bool {
            child?.running == true && ClusterLocalServing.registeredOffered(notice: child?.notice)
        }
        if registered(own), registered(peer) {
            let port = leadership?.scope.addsLocalAPI == true ? Self.ownPairAPIPort(published, live: LocalEndpoint.readLiveInfo()) : 0
            return (.init(servedBy: here, port: port, deployment: savedDeployment(perspective: true) ?? leadership?.deployment,
                          offered: offered, split: savedSplit(), relayed: leadership?.scope.answersOnEveryMac == true ? true : nil), "ready")
        }
        var line = "registering both Macs with the coordinator for pairing"
        for (mac, child) in [(hereShort, own), (thereShort, peer)] where child?.running == false {
            if let child, let end = child.lastEnd, Self.endShown(child) {
                line += "; \(mac)'s part ended (\(end)\(child.lastError.map { ": " + $0 } ?? "")) and starts again by itself"
            }
        }
        return (nil, line)
    }

    /// This Mac's own port for the pair's API, for the card: the discovery record its part (rank 0's API) or its cluster
    /// service (the relay) wrote, on every address or loopback, where `http://127.0.0.1:<port>/v1` dials it; 0 while
    /// neither is up, or for an API on one other address.
    static func ownPairAPIPort(_ published: ClusterServiceStatus?, live: LocalEndpoint.Info?) -> Int {
        guard let published, let live, ["0.0.0.0", "127.0.0.1", "localhost"].contains(live.host) else { return 0 }
        let part = published.child.running ? published.child.pid : nil
        guard live.pid == published.servicePID || live.pid == part else { return 0 }
        return Int(live.port)
    }

    /// How long the setup waits for the coordinator to pair both Macs and both to load the model (MiMo's load takes
    /// minutes); a reason the Macs know ends it sooner.
    static let pairServingSeconds: Double = 900
    /// The wait ends on a reason other than a missing login only once it has run this long: a new key's App Attest
    /// authorization lands about a minute after its registration, and the coordinator retries a start that failed.
    static let pairReasonSettleSeconds: Double = 90

    /// A pair offered for pairing: waits until the coordinator paired both Macs, both loaded the model and the pair
    /// answered its first request (rank 0's part says so), or a reason the Macs know held (`pairLook`).
    func pairServing(_ progress: @escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure> {
        var wait = ClusterOnboardingPairWait(started: Date().timeIntervalSince1970, bound: Self.pairServingSeconds,
                                             settle: Self.pairReasonSettleSeconds)
        var said: String?
        while true {
            // A stop from anywhere (`cluster stop` in another window, or on the other Mac) ends the wait at once.
            if pairStopped() { return .failure(.stopped) }
            let look = pairLook()
            if look.serving { return .success([look.test ?? ""]) }
            // A login missing, a model the coordinator's catalog does not list, or an owner-only pair holds until a person acts.
            let holds = look.reason.map { ClusterOnboardingNotServing.isMissingLogin($0) || ClusterLocalServing.pairRefusal(notice: $0) != nil
                || ClusterPublicServingCheck.ownerOnly(notice: $0) != nil } ?? false
            if let reason = wait.look(reason: look.reason, holds: holds, now: Date().timeIntervalSince1970) {
                return .failure(.init(reason))
            }
            if look.progress != said { progress(look.progress); said = look.progress }
            sleep(2)
        }
    }

    /// One look at a pair offered for pairing, from both Macs' reports: whether it serves (rank 0's part runs the pair's
    /// slot and says so, with its first request's time), what it is doing, and why it does not serve when the Macs know
    /// (a Mac without a Darkbloom login, which the coordinator never pairs; a member the coordinator's trust status gives
    /// no App Attest authorization, which pair membership requires; a committed start that stopped).
    func pairLook() -> (serving: Bool, test: String?, progress: String, reason: String?) {
        let own = ClusterService.published()
        let peer = try? JSONDecoder().decode(ClusterServiceStatus.self, from: command(.init(op: .status), seconds: 10))
        let localRankZero = context.savedConfiguration().configuration?.localRank == 0
        let rankZero = (localRankZero ? own : peer)?.child.pair.flatMap(ClusterOnboardingPairReport.state)
        if case .serving(let test)? = rankZero {
            // Paired and answering, but the coordinator sends this pair no public request: not ✓.
            for child in [own?.child, peer?.child] {
                if let reason = ClusterPublicServingCheck.ownerOnly(notice: child?.notice) { return (false, nil, "serving", reason) }
            }
            return (true, test, "serving", nil)
        }
        // The wait, then one row per Mac (`ClusterOnboardingLoadRows`): registered, then loading once the coordinator
        // committed the start (rank 0's part says so for both).
        func row(_ mac: String, _ child: ClusterServiceStatus.Child?) -> String {
            let registered = child?.running == true && ClusterLocalServing.registeredOffered(notice: child?.notice)
            let state = rankZero == .starting ? "loading its share"
                : registered ? "registered; waiting for the coordinator" : "registering with the coordinator"
            return ClusterOnboardingMacName.sentence(mac) + ": " + state
        }
        let progress = (rankZero == .starting ? "the coordinator paired both Macs" : "waiting for the coordinator to pair both Macs")
            + "\n" + row(here, own?.child) + "\n" + row(there, peer?.child)
        let missing = missingLogins(peer: peer)
        if !missing.isEmpty { return (false, nil, progress, ClusterOnboardingNotServing.notLoggedIn(missing)) }
        // Not verified by Apple yet: with when this Mac's key-generation safeguard lets it try again, when it says.
        for (mac, child) in [(here, own?.child), (there, peer?.child)] where child?.appAttest == false {
            return (false, nil, progress,
                    ClusterOnboardingNotServing.notVerified(mac, retryAt: child?.appAttestRetryAt.map { Date(timeIntervalSince1970: $0) }))
        }
        if case .stopped(let why)? = rankZero {
            // Apple verification is named only when a Mac reports it missing (none does here: that returned above).
            return (false, nil, progress, ClusterOnboardingNotServing.words(reason: why, mac: "one of the Macs", anyUnverified: false))
        }
        // The coordinator refuses every pair for a model its catalog does not list, and tells neither Mac.
        for child in [own?.child, peer?.child] {
            if let refusal = ClusterLocalServing.pairRefusal(notice: child?.notice) { return (false, nil, progress, refusal) }
        }
        return (false, nil, progress, nil)
    }

    /// The pair was stopped while a screen waits for it: this Mac's saved start is off (`cluster stop` here, or the
    /// leading Mac's stop that reached it).
    func pairStopped() -> Bool { leadership.map { !$0.serving } ?? false }

    /// The Macs without a Darkbloom login, as this screen names them.
    func missingLogins() -> [String] {
        missingLogins(peer: try? JSONDecoder().decode(ClusterServiceStatus.self, from: command(.init(op: .status), seconds: 10)))
    }

    /// This Mac without a login, and the other Mac when its own status says so (an older build that does not say is
    /// not counted).
    func missingLogins(peer: ClusterServiceStatus?) -> [String] {
        (AuthTokenStore.load() == nil ? [here] : []) + (peer?.loggedIn == false ? [there] : [])
    }

    /// `darkbloom login` in this terminal (the console is suspended): true when this Mac is logged in afterwards.
    func login() -> Bool {
        let process = Process()
        process.executableURL = settings.service.wizard.darkbloomExecutable
        process.arguments = ["login"]
        let childExit = ProcessExitObserver()
        do { try childExit.run(process) } catch { return false }
        childExit.wait()
        return AuthTokenStore.load() != nil
    }

    func testRequest() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .test), seconds: 240, acting: false, local: {
            let tested = localTestRequest()
            settleTest(tested)
            return tested
        }) { $0.lines }
    }

    func localTestRequest() -> Result<[String], ClusterOnboardingFailure> {
        let alone = ClusterService.published()?.control?.mode == "alone"
        // A pair offered for pairing has no local API to send the test request to; one that does not serve says why.
        if !alone, offeredLine() != nil {
            let look = pairLook()
            let wait = look.progress.components(separatedBy: "\n").first ?? look.progress
            return .failure(.init(look.serving ? ClusterOnboardingReady.offeredTestLine
                : ClusterOnboardingNotServing.title(reason: look.reason ?? wait)))
        }
        let text = "Name three colors."
        let answer: ClusterServicePromptAnswer
        if alone {
            // Degraded: this Mac serves alone on its own loopback, once its own solo server holds the port.
            let published = ClusterService.published()
            guard ClusterService.soloReadiness(published) == .ready else {
                return .failure(.init("\(Self.sentence(here)) serves alone, but its solo server is not answering on port \(ClusterService.soloPort(of: published)) yet."))
            }
            answer = ClusterService.prompt(context, text: text, port: ClusterService.soloPort(of: published))
        } else if context.savedConfiguration().configuration?.role == .leader {
            answer = ClusterService.prompt(context, text: text)
        } else {
            do {
                answer = try JSONDecoder().decode(ClusterServicePromptAnswer.self, from: try command(.init(op: .prompt, text: text), seconds: 200))
            } catch {
                return .failure(.init("The test request did not reach \(there): \((error as? ClusterSetupFailure)?.text ?? "\(error)")"))
            }
        }
        if let error = answer.error { return .failure(.init("The test request failed: \(error)")) }
        if answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.init("The test request got an empty answer.")) }
        // One line for the screen: how fast it answered (its first token).
        return .success([answer.firstTokenMilliseconds.map { "in \(String(format: "%.2f", Double($0) / 1000)) s" } ?? ""])
    }

    func status() -> [String] { leaderStatus().lines }

    /// The control leader's status with its setup step (`ClusterControlReply.step`; nil from an older leader).
    func leaderStatus() -> ClusterOnboardingLeaderStatus {
        var forwarded = false
        var look: ClusterOnboardingLeaderStatus
        switch routed(.init(op: .status), seconds: 30, acting: false, forwarding: { forwarded = true },
                      local: { .success(ClusterOnboardingLeaderStatus(lines: localStatus(), step: currentLeaderStep(), start: currentStart())) },
                      remote: { ClusterOnboardingLeaderStatus(lines: $0.lines, step: $0.step, start: $0.start) }) {
        case .success(let value): look = value
        case .failure(let failure): look = ClusterOnboardingLeaderStatus(lines: failure.lines, step: nil)
        }
        // This Mac's own state, when it adds something (a member that just follows already said where commands go).
        if forwarded, let own = ClusterService.published()?.control, own.mode != "following" { look.lines.append("This Mac: " + own.line + ".") }
        return look
    }

    /// Records the setup step of this screen (nil clears it), on the Mac whose status both Macs read, with this process
    /// so the step stops counting once the screen is gone (`ClusterOnboardingLeaderStepMark`).
    func publishStep(_ step: ClusterOnboardingLeaderStep?) {
        let pid = getpid()
        guard !forwards, let started = Self.processStarted(pid) else { return }
        let mark = step.map { step -> ClusterOnboardingLeaderStepMark in
            var step = step
            step.version = step.version ?? ProviderCore.version
            return .init(step: step, pid: pid, started: started, at: Date().timeIntervalSince1970)
        }
        try? store.updateRecord { record in
            record.onboardingStep = mark
            // A screen that moved on (a new start, another model) ends an earlier start's ✗ as the outcome to follow.
            if step != nil, record.startProgress?.progress.phase == .failed { record.startProgress = nil }
        }
    }

    /// The setup step the status publishes, while it counts.
    func currentLeaderStep() -> ClusterOnboardingLeaderStep? {
        (try? store.readRecord())?.onboardingStep?.current(now: Date().timeIntervalSince1970, started: Self.processStarted)
    }

    /// A model id as the screens name it: its catalog name, when the last catalog this Mac read has one.
    func modelTitle(_ modelID: String) -> String {
        let catalog = (ClusterModelStore.readSmall(store.paths.directory.appendingPathComponent("catalog.json"))
            .flatMap { try? JSONDecoder().decode([CatalogModel].self, from: $0) }) ?? []
        return ClusterOnboardingDeployment.title(modelID: modelID,
            displayNames: Dictionary(catalog.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
    }

    func localStatus() -> [String] {
        var lines = [String]()
        // After a Darkbloom update this Mac's service sets the cluster up again by itself; said first while it runs.
        if let updating = ClusterService.publishedLive()?.updating { lines.append(updating) }
        let answering = self.answering
        if let control = ClusterService.published()?.control, ["alone", "cannotServe", "waiting"].contains(control.mode) {
            // Serving alone is said only once this service's own solo server answers, as the setup's wait counts it.
            var line = control.line
            if control.mode == "alone" {
                let published = ClusterService.published()
                switch ClusterService.soloReadiness(published) {
                case .ready: break
                case .loading: line += " (its solo server is still loading)"
                case .foreign: line += " (another program answers on port \(ClusterService.soloPort(of: published)), so its solo server cannot serve there)"
                }
            }
            lines.append((answering ? Self.sentence(hereShort) + ": " : "") + line + ".")
            return lines
        }
        // One line for the screen (the banner above says which Mac leads): what serves and where, or why it does not.
        let model = (leadership?.modelName).map(modelTitle) ?? "the chosen model"
        let now = session()
        if leadership?.serving != true, (try? store.readRecord())?.soloBlockedAt != nil, let solo = soloServingFailure() {
            // The leading Mac's start stopped at the single-Mac block: both Macs say it while single-Mac serving runs.
            lines.append(ClusterOnboardingNotServing.statusLine(model: model, reason: ClusterOnboardingSoloServing.title(solo.soloServing)))
            lines += ClusterOnboardingSoloServing.remedies(solo.soloServing).map(ClusterOnboardingCommand.named)
        } else if leadership?.serving != true {
            lines.append("Stopped\(leadership?.modelName.map { "; last model " + modelTitle($0) } ?? "").")
            if let scope = leadership?.scope, scope.localAPIBind != nil { lines.append("When it starts: " + scope.line + ".") }
        } else if let split = versionSplit() {
            // Different versions never clear by themselves: both windows say it, with the versions and the command.
            lines.append(ClusterOnboardingNotServing.statusLine(model: model, reason: split.reason))
            lines += split.remedies
        } else if let solo = soloServingFailure() {
            // Single-Mac serving blocks the pair and never ends by itself: both windows say it, naming the Mac and process.
            lines.append(ClusterOnboardingNotServing.statusLine(model: model, reason: ClusterOnboardingSoloServing.title(solo.soloServing)))
            lines += ClusterOnboardingSoloServing.remedies(solo.soloServing).map(ClusterOnboardingCommand.named)
        } else if let offered = offeredLine() {
            let ready = offeredReadiness(offered, own: ClusterService.published())
            if let registered = ready.ready {
                // Registered is not serving: the pair serves once the coordinator paired both Macs and both loaded it.
                let look = pairLook()
                if look.serving {
                    lines.append(registered.pairServingLine(model: model) + ".")
                } else {
                    let wait = look.progress.components(separatedBy: "\n").first ?? look.progress
                    lines += Self.offeredWaitLines(model: model, reason: look.reason, wait: wait)
                }
            } else {
                lines.append("\(model): \(ready.line).")
            }
        } else if let session = now.session, session.observed {
            if session.ready {
                let ready = ready(now, port: session.port ?? 0)
                let record = try? store.readRecord()
                let local = leadership?.scope.isLocalOnly == true
                let serving = ready.summary(model: model) + ClusterOnboardingDriver.servesWords(ready: ready) + "."
                let outcome = Self.outcomeLines(record: record, pending: registrationPending, local: local, model: model, serving: serving)
                // A start not over, a failed test, or a pair that serves locally only as asked: that alone.
                lines += outcome.first != serving || local ? outcome
                    : Self.notOfferedLines(model: model, ready: ready, note: record?.approvalNote, outcome: outcome)
            } else {
                lines.append("Loading \(model): \(session.readyRanks) of \(session.ranks) parts ready" + (session.detail.map { " (\($0))" } ?? "")
                    + partsEnded(local: now.local) + ".")
            }
        } else if let error = now.error {
            lines.append("\(Self.sentence(thereShort)) doesn't answer over the cable (\(error)); it rejoins by itself.")
        } else {
            // A load that keeps ending says how (R7-4: "Starting …" alone read as loading with no reason for 12 minutes).
            lines.append("Starting \(model)" + partsEnded(local: now.local) + ".")
        }
        return lines
    }

    /// Each Mac's part that keeps ending while the parts load (`endedClause`): this Mac's, and the other Mac's when rank 0
    /// is here (the other Mac is asked for its part only then, as `readinessOnce` asks it).
    private func partsEnded(local: Bool) -> String {
        let member = local ? try? JSONDecoder().decode(ClusterServiceStatus.self, from: try command(.init(op: .status), seconds: 10)) : nil
        return (Self.endedClause(mac: hereShort, child: ClusterService.published()?.child) ?? "")
            + (Self.endedClause(mac: thereShort, child: member?.child) ?? "")
    }

    func stop() -> Result<[String], ClusterOnboardingFailure> {
        markSoloBlocked(false)
        return routed(.init(op: .stop), seconds: 330, acting: true, local: { localStop() }) { $0.lines }
    }

    func verifyTeardown() -> Result<[String], ClusterOnboardingFailure> {
        routed(.init(op: .verifyTeardown), seconds: 60, acting: false, local: { localVerifyTeardown() }) { $0.lines }
    }

    /// Each Mac's verify-teardown summary: this one's, and the other's over the link, each named as the screen names it.
    func localVerifyTeardown() -> Result<[String], ClusterOnboardingFailure> {
        let macs = (here: Self.sentence(here), there: Self.sentence(there))
        var lines = ClusterService.teardownLines(mac: macs.here)
        do {
            // The other Mac names itself by its hardware.
            lines += try JSONDecoder().decode([String].self, from: try command(.init(op: .teardown), seconds: 30))
                .map { Self.teardownLine($0, mac: macs.there) }
        } catch {
            lines.append("\(macs.there): did not answer (\((error as? ClusterSetupFailure)?.text ?? "\(error)"))")
        }
        return .success(lines)
    }

    /// A teardown summary ("<Mac>: nothing left running") with the Mac named `mac`.
    static func teardownLine(_ line: String, mac: String) -> String {
        guard let colon = line.range(of: ": ") else { return line }
        return mac + line[colon.lowerBound...]
    }

    func localStop() -> Result<[String], ClusterOnboardingFailure> {
        localStop(seconds: 300) { _ = try command(.init(op: .stop)) }
    }

    /// The transport remains separate from local process custody so every
    /// caller (CLI, model switch, or update) uses the same retirement ordering.
    func localStop(seconds: Double, stopPeer: () throws -> Void) -> Result<[String], ClusterOnboardingFailure> {
        let stopID = UUID()
        // Named for the screen that shows the lines (the other Mac's, when it forwarded the stop).
        let mac = Self.sentence(hereShort), other = thereShort
        do {
            try store.updateRecord { record in
                record.stopDrain = .init(id: stopID,
                    keepPeerRunning: record.leadership?.serving == true || record.stopDrain?.keepPeerRunning == true)
                record.leadership?.serving = false
                record.registrationPending = nil
                Self.clearTestResults(&record)
            }
            lock.withLock { partsStoppedAt = Date() }
        } catch {
            return .failure(.init("\(mac) could not save the stop request: \((error as? ClusterSetupFailure)?.text ?? "\(error)")"))
        }
        guard ClusterService.stopLocalPart(in: store.paths.directory, seconds: seconds) else {
            return .failure(.init("\(mac)'s part has not finished releasing its memory, so \(other) was not asked to stop yet. The stop request is saved; run `\(Self.cli) cluster stop` again to check it."))
        }
        do {
            // The service normally clears this after its matching cycle. A
            // missing service can also leave an exact owned part we retired.
            let record = try store.updateRecord {
                if $0.stopDrain?.id == stopID { $0.stopDrain = nil }
            }
            guard record.stopDrain == nil, record.leadership?.serving != true else {
                return .failure(.init("The stop request changed while \(hereShort) drained; \(other) was not asked to stop."))
            }
        } catch {
            return .failure(.init("\(mac) drained but could not finish saving the stop request; \(other) was not asked to stop."))
        }
        do {
            try stopPeer()
        } catch {
            let reason = (error as? ClusterSetupFailure)?.text ?? "\(error)"
            return .failure(.init(["\(mac) stopped serving; \(there) did not answer (\(reason)). \(mac)'s cluster service tells it to stop as soon as it answers again."],
                                  otherMacUnanswered: "\(Self.sentence(there)) did not answer (\(reason))"))
        }
        return .success(["Stopping both Macs. Run `\(Self.cli) cluster` to serve again."])
    }
}
