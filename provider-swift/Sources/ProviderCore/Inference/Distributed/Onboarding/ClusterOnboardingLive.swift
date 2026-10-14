import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

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
            provision: { index, download, progress in live.provision(index, download: download, progress) })
    }
}

private final class OnboardingLive: @unchecked Sendable {
    let context: LiveContext
    let store: ClusterSetupStore
    let settings: ClusterOnboardingOperations.LiveSettings
    private let lock = NSLock()
    private var respond: (@Sendable (Bool) -> Void)?
    private var pendingAnswer: Bool?
    private var peerReport: ClusterSetupReport?
    private var choices: [(folder: String, key: String, title: String)] = []
    /// Choices that are catalog models no Mac has yet (by choice index).
    private var catalogChoices: [Int: CatalogModel] = [:]
    /// Choices that only the other Mac has (by choice index): it sends them here first.
    private var peerChoices: [Int: ClusterSetupLocalModel] = [:]
    private var chosenTitle: String?

    init(context: LiveContext, store: ClusterSetupStore, settings: ClusterOnboardingOperations.LiveSettings) {
        self.context = context; self.store = store; self.settings = settings
    }

    var leadership: ClusterOnboardingLeadership? { (try? store.readRecord())?.leadership }
    var peerName: String { leadership?.peerName ?? "the other Mac" }

    func resume() -> ClusterOnboardingResume {
        guard let leadership, let role = ClusterOnboardingRole(rawValue: leadership.role),
              let pairing = try? ClusterSetupLinkExchange.pairing(), pairing.peerPin == leadership.peerPin else { return .init() }
        return .init(role: role, peerName: leadership.peerName, serving: leadership.serving, modelName: leadership.modelName)
    }

    // MARK: - Checks and the one approval

    func checkLink(_ say: @escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult {
        var flow = ClusterLinkSetupFlow(mayPrompt: true)
        var step = flow.begin()
        var last: ClusterLinkReadinessReport?
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
                guard code == 0, flow.linkState == .ready else { return .init(ready: false, exitCode: max(code, 1)) }
                // A port isolated as link setup v2 leaves it but with no record (an administrator ran the commands
                // by hand): recorded now, with no prompt and no change, so `cluster link --remove` can restore it.
                if let ready = last?.devices.first(where: { $0.portActive && $0.verdict == .ready }), ready.isolation?.isolated == true {
                    let adopted = ClusterLinkRepair.fix(device: ready.device, mode: .durable, dryRun: false)
                    if !adopted.adopted.isEmpty { say("Recorded this Mac's link setup (no change made), so `darkbloom cluster link --remove` can restore the earlier one.") }
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

    /// Installs this Mac's cluster service as its login agent (it starts at login and after a restart of
    /// this Mac, and its supervisor restarts it with backoff), idempotently. Where launchd cannot take the
    /// job, the service still starts for this session, and the screen says it will not come back by itself.
    func ensureService() -> Result<String, ClusterOnboardingFailure> {
        let executable = settings.service.wizard.darkbloomExecutable
        let arguments = settings.serviceArguments
        let options = Array(arguments.starts(with: ["cluster", "service"]) ? arguments.dropFirst(2) : arguments[...])
        // A login agent this build's launchd job runs could not reach the other Mac (no one-time Local Network
        // approval for an ad-hoc build or one outside the signed app): keep the service in this session instead.
        let identity = ClusterMemberPermissionIdentity.current(executablePath: ClusterService.resolvedExecutable(executable))
        if let refusal = identity.launchdLinkRefusal {
            return sessionService(executable: executable, arguments: arguments,
                                  reason: refusal + "; install the signed Darkbloom release for a service that starts at login")
        }
        do {
            switch try ClusterService.installAtLogin(executable: executable, serviceOptions: options) {
            case .installed, .replaced:
                return .success("Started this Mac's cluster service: it runs this Mac's part whenever the leader asks, "
                    + "and starts again by itself at login and after a restart of this Mac.")
            case .restarted:
                return .success("Restarted this Mac's cluster service (it starts again by itself at login).")
            case .unchanged:
                return .success("This Mac's cluster service is running (it starts again by itself at login).")
            }
        } catch let agentError {
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

    static func reason(_ error: Error) -> String {
        (error as? ClusterOnboardingFailure)?.lines.joined(separator: " ") ?? "\(error)"
    }

    // MARK: - The leader

    func reachMembers(_ say: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure> {
        let deadline = Date().addingTimeInterval(120)
        var lastReason: String?
        var reached: (ClusterSetupReport, Double)?
        while reached == nil {
            switch context.reachPeer() {
            case .reached(let report, let seconds): reached = (report, seconds)
            case .failed(let reason):
                if reason != lastReason { say("Waiting for \(peerName)'s cluster service: \(reason)"); lastReason = reason }
                guard Date() < deadline else {
                    return .failure(.init("\(peerName) did not answer over the cable within 2 minutes: \(reason)"))
                }
                sleep(3)
            }
        }
        let (peer, seconds) = reached!
        lock.withLock { peerReport = peer }
        say("\(peerName) answered over the cable in \(String(format: "%.1f", seconds)) s.")
        let local = context.snapshot().local
        func machine(_ report: ClusterSetupReport, name: String, leads: Bool) -> ClusterOnboardingMachine {
            .init(name: name, memoryGB: report.mac.physicalMemoryBytes >> 30, gpuCores: report.mac.profile?.gpuCores, leads: leads,
                models: report.models.count)
        }
        return .success([machine(local, name: ClusterPairingProvider.displayName(chipName: local.mac.chip), leads: true),
                         machine(peer, name: peerName, leads: false)])
    }

    func planModels() -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure> {
        guard let peer = lock.withLock({ peerReport }) else { return .failure(.init("The other Mac has not answered yet.")) }
        // The models single-Mac Darkbloom installed on this Mac are cluster models too (cloned in: no new blocks).
        let store = URL(fileURLWithPath: context.modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path)
        for installed in ClusterProductModelStore.installed() {
            _ = try? ClusterProductModelStore.cloneIntoClusterStore(installed, store: store, providerConfiguration: settings.service.wizard.providerConfiguration)
        }
        switch context.plan(peer: peer) {
        case .failed(let reason): return .failure(.init("Planning failed: \(reason)"))
        case .ready(let options):
            let localName = ClusterPairingProvider.displayName(chipName: context.snapshot().local.mac.chip)
            var keys = [(folder: String, key: String, title: String)]()
            let choices = options.map { option -> ClusterOnboardingModelChoice in
                let gigabytes = String(format: "%.1f GB", Double(option.model.totalBytes) / 1e9)
                let title = option.model.modelID
                guard let plan = option.plan else {
                    keys.append((option.model.folder, "", title))
                    return .init(title: title, lines: [], blocker: option.blocker ?? "no plan")
                }
                keys.append((option.model.folder, ClusterSetupState.planKey(option.model, plan), title))
                let offer = option.onOtherMac != false ? nil : copyOffer(model: option.model, peer: peer, localName: localName)
                let last = plan.ranks.map(\.rank).max() ?? 0
                var lines = plan.ranks.map { rank in
                    let name = rank.local ? "\(localName) (this Mac)" : peerName
                    return "rank \(rank.rank)\(rank.rank == last ? " (decodes)" : rank.rank == 0 ? " (serving API)" : ""): \(name), layers \(rank.firstLayer)-\(rank.endLayer - 1)"
                }
                let speed = plan.absolute ? "about \(Int(plan.decodeTokensPerSecond.rounded())) tokens/s" : "speed not yet measured on these Macs"
                lines.append("\(gigabytes), \(ClusterOnboardingWords.mode(plan.mode)), \(speed)\(plan.measured ? "" : plan.absolute ? " (estimate)" : "")"
                    + (plan.fitsNow ? "" : "; does not fit now"))
                return .init(title: title, lines: lines, blocker: option.blocker, provision: offer)
            }
            // Open choices first (the models this Mac has), then catalog models no Mac has yet, then the blocked ones.
            var ordered = [(ClusterOnboardingModelChoice, (folder: String, key: String, title: String))]()
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
                ordered.append((.init(title: model.modelID, lines: ["on \(peerName) only: planned once it is on this Mac too"], blocker: nil,
                    provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
                        quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan))),
                    (model.folder, "", model.modelID)))
            }
            for model in catalogModels(peer: peer) where !held.contains(model.aggregateSHA256 ?? "")
                && ClusterModelCopyTrust.servableArtifacts.contains(model.aggregateSHA256 ?? "") {
                catalog[ordered.count] = model
                ordered.append((downloadChoice(model, peer: peer, localName: localName), ("", "", model.id)))
            }
            ordered += pairs.filter { $0.0.blocker != nil }
            lock.withLock { self.choices = ordered.map(\.1); self.catalogChoices = catalog; self.peerChoices = fromPeer }
            return .success(ordered.map(\.0))
        }
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
        return .init(title: model.id, lines: ["not on these Macs yet: \(ClusterModelProvisioning.gigabytes(bytes)) from Darkbloom's catalog; planned once it is on this Mac"],
            blocker: nil, provision: .init(lines: ClusterModelProvisioning.lines(plan), downloadAlternative: false, leaderDownloads: true, blocker: plan.blocker,
            quickSeconds: ClusterModelProvisioning.quickCopySeconds(plan)))
    }

    /// The catalog models this Mac could fetch for the cluster (a verified manifest, small enough for both Macs'
    /// memory together); empty when the catalog does not answer within a few seconds.
    func catalogModels(peer: ClusterSetupReport) -> [CatalogModel] {
        guard let config = try? ConfigManager.load(from: settings.service.wizard.providerConfiguration) else { return [] }
        let client = ModelCatalogClient(coordinatorURL: config.coordinator.url)
        let box = ClusterOnboardingMailbox<[CatalogModel]>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.post((try? await client.fetchCatalog(typeFilter: "text")) ?? []); done.signal() }
        guard done.wait(timeout: .now() + 6) == .success, let models = box.take().first else { return [] }
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
        let catalog = (try? ConfigManager.load(from: settings.service.wizard.providerConfiguration)).map { ModelCatalogClient(coordinatorURL: $0.coordinator.url) }
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
        guard let peer = lock.withLock({ peerReport }), let choice = lock.withLock({ choices.indices.contains(index) ? choices[index] : nil }) else {
            return .failure(.init("Nothing to adopt: plan again."))
        }
        let result = context.adopt(folder: choice.folder, planKey: choice.key, peer: peer)
        guard result.succeeded else { return .failure(.init(result.lines)) }
        lock.withLock { chosenTitle = choice.title }
        return .success(result.lines)
    }

    func command(_ command: ClusterServiceCommand, seconds: Double = 30) throws -> Data {
        guard let pairing = try ClusterSetupLinkExchange.pairing() else { throw ClusterOnboardingFailure("This Mac is not paired.") }
        return try ClusterSetupLinkExchange.command(pairing: pairing, selection: try context.linkSelection(), peerAddress: nil,
            body: try JSONEncoder().encode(command), seconds: seconds).reply
    }

    func serve() -> Result<[String], ClusterOnboardingFailure> {
        let title = lock.withLock { chosenTitle }
        do {
            try store.updateRecord { $0.leadership?.serving = true; if let title { $0.leadership?.modelName = title } }
            _ = try command(.init(op: .serve, model: title))
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
            let now = session()
            var line: String
            if let session = now.session, session.observed {
                if session.ready, let port = session.port {
                    return .success(.init(servedBy: now.local ? "this Mac" : peerName, port: port))
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
            if line != said { progress(line); said = line }
            sleep(2)
        }
        return .failure(.init("The cluster did not report ready within 15 minutes (last: \(said ?? "nothing")); see ~/.darkbloom/cluster-setup/rank.log on each Mac."))
    }

    func testRequest() -> Result<[String], ClusterOnboardingFailure> {
        let text = "Name three colors."
        let answer: ClusterServicePromptAnswer
        if context.savedConfiguration().configuration?.role == .leader {
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
        var lines = [String]()
        let model = leadership?.modelName ?? "the chosen model"
        let now = session()
        if let session = now.session, session.observed {
            lines.append(session.ready ? ClusterOnboardingReady(servedBy: now.local ? "this Mac" : peerName, port: session.port ?? 0).servingLine(model: model)
                + " (\(session.readyRanks) of \(session.ranks) parts ready)."
                : "\(model): \(session.readyRanks) of \(session.ranks) parts ready" + (session.detail.map { " (\($0))" } ?? "") + ".")
        } else if let error = now.error {
            lines.append("\(peerName) does not answer over the cable now (\(error)); it rejoins by itself when it is back.")
        } else {
            lines.append("\(model) is starting (both Macs keep trying by themselves).")
        }
        lines.append("Member: \(peerName). This Mac leads.")
        return lines
    }

    func stop() -> Result<[String], ClusterOnboardingFailure> {
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

enum ClusterOnboardingWords {
    static func mode(_ raw: String) -> String {
        switch raw {
        case "pipeline_v1": return "pipeline (each Mac runs its layers of every token)"
        case "pipeline_compact_decode_v1": return "pipeline with compact decode"
        case "phase_split_v1": return "prompt split, then one Mac decodes"
        case "phase_split_mtp_v1": return "prompt split, then one Mac decodes with MTP"
        default: return raw
        }
    }
}
