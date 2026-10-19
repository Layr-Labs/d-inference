import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// The wizard's operations as the installed command runs them. Each one is
/// the function behind an existing `darkbloom cluster` subcommand, a
/// read-only look at the same files and tools, or the wizard's own record.
extension ClusterSetupOperations {
    public struct LiveSettings: Sendable {
        public let providerConfiguration: URL
        /// This executable, to start `start --local --distributed` with.
        public let darkbloomExecutable: URL
        public let sessionArguments: [String]
        /// The pair description given on the command line, if any; otherwise the one the record remembers.
        public let pair: ClusterSetupRecord.Pair?
        /// The link fix previews only.
        public let dryRun: Bool
        public let version: String
        /// What a follower whose setup reaches it over the link runs to serve
        /// its rank (`darkbloom cluster link-follower`).
        public var followerSessionArguments: [String] = []
        /// This Mac's worker for the guided flow; nil takes the installed one
        /// (`ClusterBundledHelpers`: `Darkbloom.app/Contents/Helpers` in a
        /// release, `worker/` beside a development build).
        public var workerExecutable: String?
        /// The folder holding this Mac's model folders, given once; nil takes the one remembered.
        public var modelsDirectory: String?
        /// The leader-first onboarding: the planner (under the model's pair-serving grant) decides which Mac
        /// runs rank 0 and which decodes, and a member's cluster service applies the setup it is sent.
        public var derivedPlacement = false
        /// The open wizard answers the other Mac's wizard over the link. Off where this Mac's cluster
        /// service answers instead (the onboarding, the service itself): one answering process per Mac.
        public var answersOverLink = true
        /// In-memory selection from the private local CLI; never a serving grant.
        public var privateMiMoImageQualification = false
        public var privateGLMImageQualification = false
        public var privateImageQualification: Bool { privateMiMoImageQualification || privateGLMImageQualification }

        public init(providerConfiguration: URL, darkbloomExecutable: URL, sessionArguments: [String],
                    pair: ClusterSetupRecord.Pair?, dryRun: Bool, version: String) {
            self.providerConfiguration = providerConfiguration; self.darkbloomExecutable = darkbloomExecutable
            self.sessionArguments = sessionArguments; self.pair = pair; self.dryRun = dryRun; self.version = version
        }
    }

    /// Seconds an SSH question to the other Mac may take.
    static let peerSeconds = 30.0

    public static func live(_ settings: LiveSettings) throws -> ClusterSetupOperations {
        let paths = try ClusterUserPaths()
        let store = ClusterSetupStore(paths: .init(paths: paths))
        let configuration = settings.providerConfiguration
        let clean = ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path)
        let context = LiveContext(paths: paths, store: store, settings: settings, clean: clean)
        var operations = ClusterSetupOperations(
            snapshot: { context.snapshot() },
            reachPeer: { context.reachPeer() },
            planModels: { peer in context.plan(peer: peer) },
            fixLink: { dryRun in
                // A wizard opened with --dry-run never applies, whatever it is asked.
                let preview = dryRun || settings.dryRun
                let result = ClusterLinkRepair.fix(device: nil, mode: .durable, dryRun: preview)
                return .init(dryRun: preview, succeeded: result.outcome.exitCode == 0, outcome: result.outcome.code,
                    lines: result.summaryLines.map { clean($0) }, commands: result.plannedCommands)
            },
            recordConfirmation: { code, cluster in
                do {
                    try store.updateRecord { $0.add(.init(code: code, clusterID: cluster, at: ClusterConsoleText.timestamp())) }
                    return .init(succeeded: true, lines: ["Recorded that both screens showed \(code.prefix(3)) \(code.suffix(3))."])
                } catch { return .failure(error) }
            },
            adoptPlan: { folder, key, peer in context.adopt(folder: folder, planKey: key, peer: peer) },
            approveInbox: { expected in
                guard let candidate = store.inboxCandidate else {
                    return .init(succeeded: false, lines: ["The inbox is empty now; the leader can send the setup again from its step 4."])
                }
                do {
                    let result = ClusterConsoleObserver.approve(candidate, expectedSHA256: expected,
                        holdingIn: try ClusterConsoleInstanceLock.userTemporaryDirectory()) { reviewed in
                            try ClusterConfigurationStore(paths: paths).configure(configurationInput: reviewed.configurationInput,
                                capabilityInput: reviewed.capabilityInput, capabilitySHA256: candidate.capabilitySHA256,
                                providerConfiguration: configuration)
                        }
                    if result.succeeded { store.clearInbox() }
                    return result
                } catch { return .failure(error) }
            },
            recordCheck: { pass in
                do {
                    try store.updateRecord { $0.add(pass) }
                    return .init(succeeded: true, lines: ["Recorded the check on setup \(pass.configurationSHA256.prefix(12))."])
                } catch { return .failure(error) }
            },
            observeSession: { context.observe() },
            launchSession: { events in
                // A follower reached over the link serves its rank itself; a leader starts the session.
                let arguments = context.followsOverLink() ? settings.followerSessionArguments : settings.sessionArguments
                return try ClusterConsoleSessionProcess.start(.init(executable: settings.darkbloomExecutable, arguments: arguments),
                    events: events)
            },
            sendPrompt: { text, maxTokens, events in context.prompt(text: text, maxTokens: maxTokens, events: events) })
        let pairing = ClusterSetupLinkPairingRunner()
        operations.pairOverLink = { connect, events in pairing.run(connect: connect, events: events) }
        operations.answerLinkCode = { accept in pairing.answer(accept) }
        return operations
    }
}

/// The wizard's step 3 running `darkbloom cluster pair`'s ceremony: the same
/// identity, attestation, store and link channel, with the screen in place of
/// the terminal prompt. One ceremony at a time; the person's answer is handed
/// to the ceremony that asked.
final class ClusterSetupLinkPairingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var respond: (@Sendable (Bool) -> Void)?
    private var pendingAnswer: Bool?

    func run(connect: String?, events: @escaping @Sendable (ClusterSetupLinkPairingEvent) -> Void) {
        let store = ClusterPairingStore.default()
        let identity: any ClusterPairingIdentity
        do { identity = try ClusterPairingProvider.identity() } catch {
            events(.finished(succeeded: false, lines: ["Not paired: \(error)"])); return
        }
        var request = ClusterPairCommandRequest()
        request.connect = connect
        let peer = connect.flatMap(ClusterLinkIPv4Address.init)
        let interface: String
        do { interface = try ClusterPairCommandLine.resolveInterface(request, peer: peer) } catch {
            events(.finished(succeeded: false, lines: ["Not paired: \(error)"])); return
        }
        let chipName = (try? HardwareDetector.detect().chipName) ?? "Mac"
        let participant = ClusterPairingProvider.participant(identity: identity, chipName: chipName, interface: interface, store: store, clusterID: nil)
        var options = ClusterLinkPairing.Options(role: peer == nil ? .listener : .connector, interface: interface, peerAddress: peer)
        // No address: find the other Mac on the cable, or wait there for it (it finds this one).
        if peer == nil { options.discovery = .find }
        let callbacks = ClusterLinkPairing.Callbacks(progress: { progress in
            switch progress {
            case .searching(let name):
                events(.waiting("Looking for the other Mac on \(name)\u{2026}"))
            case .listening(let name, let port):
                let address = (try? ClusterLinkInterfaceAdmission.select(interface: name, localAddress: nil, peerAddress: nil,
                    policy: .thunderboltOnly, inspector: ClusterLinkSystemInterfaceInspector()))?.local.address.dottedDecimal
                let other = "on the other Mac press l: it finds this Mac by itself" + (address.map { " (or press c and type \($0)"
                    + (port == ClusterLinkPairing.defaultPort ? "" : ", port \(port)") + ")" } ?? "")
                events(.waiting("Waiting on \(name) for the other Mac, up to 10 minutes: \(other)."))
            case .dialing: events(.waiting("Dialing the other Mac over the link\u{2026}"))
            case .connected: events(.waiting("Connected over the link; exchanging keys\u{2026}"))
            case .refused(let reason): events(.waiting("Link connection refused (\(reason)); still trying\u{2026}"))
            case .storing: events(.waiting("Storing the pins and the roster (owner-only files)\u{2026}"))
            }
        }, askConfirmation: { [self] code, peerInfo, respond in
            let early: Bool? = lock.withLock {
                self.respond = respond
                defer { pendingAnswer = nil }
                return pendingAnswer
            }
            events(.code(code, peer: ClusterPairingTerminal.describe(peerInfo)))
            if let early { answer(early) }
        }, peerDecided: { accepted in events(.peerDecided(accepted)) })
        let result = ClusterLinkPairing.run(options: options, participant: participant, hooks: ClusterPairingProvider.hooks,
            store: store, callbacks: callbacks)
        lock.withLock { respond = nil; pendingAnswer = nil }
        let lines = ClusterPairingTerminal.summary(result)
        if case .success = result { events(.finished(succeeded: true, lines: lines)) } else { events(.finished(succeeded: false, lines: lines)) }
    }

    func answer(_ accept: Bool) {
        let current: (@Sendable (Bool) -> Void)? = lock.withLock {
            defer { respond = nil }
            if respond == nil { pendingAnswer = accept }
            return respond
        }
        current?(accept)
    }
}

/// What the live operations share: paths, the record, and the last plans,
/// so that adopting a plan saves exactly the one that was on screen.
final class LiveContext: @unchecked Sendable {
    let paths: ClusterUserPaths
    let store: ClusterSetupStore
    let settings: ClusterSetupOperations.LiveSettings
    let clean: ClusterConsoleFreeText
    private let lock = NSLock()
    private var decisions: [String: ClusterSetupPlanning.Decision] = [:]
    /// The other Mac as it last answered over the paired link (S17), with the address it answered from.
    private var linkPeer: (answer: ClusterSetupLinkAnswer, address: ClusterLinkIPv4Address)?
    /// Answers the other Mac's wizard while this one is open (both Macs run one).
    private var responder: ClusterSetupLinkExchange.Responder?
    private var responderStarting = false
    private var workerDigest: (key: String, digest: String)?

    init(paths: ClusterUserPaths, store: ClusterSetupStore, settings: ClusterSetupOperations.LiveSettings, clean: ClusterConsoleFreeText) {
        self.paths = paths; self.store = store; self.settings = settings; self.clean = clean
    }

    deinit { responder?.stop() }

    /// The other Mac's facts as it last answered over the paired link (its worker digest among them).
    var peerFacts: ClusterSetupMemberFacts? { lock.withLock { linkPeer?.answer.facts } }

    // MARK: - The paired link (no SSH, no typed address)

    /// The cable's interface and this Mac's address on it, as pairing picks them
    /// (Darkbloom's own 10.219 service address once link setup v2 ran).
    func linkSelection() throws -> ClusterLinkInterfaceSelection { try Self.defaultLinkSelection() }

    /// The cable's interface on this Mac, admitted for the paired link.
    static func defaultLinkSelection() throws -> ClusterLinkInterfaceSelection {
        let interface: String
        do { interface = try ClusterPairCommandLine.resolveInterface(ClusterPairCommandRequest(), peer: nil) } catch {
            throw ClusterSetupFailure("The cable is not ready yet. Run `darkbloom cluster` again. (\(error))")
        }
        do {
            return try ClusterLinkInterfaceAdmission.select(interface: interface, localAddress: nil, peerAddress: nil,
                policy: .thunderboltOnly, inspector: ClusterLinkSystemInterfaceInspector())
        } catch {
            throw ClusterSetupFailure("the cable's interface \(interface) was not admitted: \(error)")
        }
    }

    /// The pairing the guided flow uses, unless the developer harness gave an
    /// SSH pair description, or a saved setup reaches its peer over SSH.
    func linkPairing() -> ClusterSetupLinkExchange.Pairing? {
        guard settings.pair == nil else { return nil }
        if let saved = savedConfiguration().configuration, saved.linkControl == nil { return nil }
        return try? ClusterSetupLinkExchange.pairing()
    }

    /// This Mac's saved setup is a follower reached over the link.
    func followsOverLink() -> Bool {
        guard let saved = savedConfiguration().configuration else { return false }
        return saved.role == .follower && saved.linkControl != nil
    }

    /// The folder holding this Mac's model folders: given now, else remembered, else the saved setup's.
    func modelsDirectory() -> String? {
        if let given = settings.modelsDirectory { return given }
        if let remembered = (try? store.readRecord())?.modelsDirectory { return remembered }
        if let saved = savedConfiguration().configuration {
            return URL(fileURLWithPath: saved.peers[saved.localRank].modelDirectory).deletingLastPathComponent().path
        }
        // No folder given, remembered or saved: the cluster's own model store beside the product's models.
        let store = ClusterModelStoreLocation.defaultDirectory()
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return store.path
    }

    /// Where this Mac's installation is and its address on the cable, for the other Mac's plan.
    func localFacts(pairing: ClusterSetupLinkExchange.Pairing, selection: ClusterLinkInterfaceSelection) throws -> ClusterSetupMemberFacts {
        let worker = settings.workerExecutable
            ?? savedConfiguration().configuration.map { $0.peers[$0.localRank].workerExecutable }
            ?? ClusterBundledHelpers.defaultWorker(darkbloomExecutable: settings.darkbloomExecutable).path
        guard FileManager.default.isExecutableFile(atPath: worker) else {
            throw ClusterSetupFailure(ClusterBundledHelpers.missingWorkerReason(darkbloomExecutable: settings.darkbloomExecutable))
        }
        // Always a folder: given, remembered, saved, or the cluster's own model store.
        let models = modelsDirectory() ?? ClusterModelStoreLocation.defaultDirectory().path
        let folders = (try? ClusterSetupModelFolders.list(parent: URL(fileURLWithPath: models))) ?? []
        let modelDirectory = URL(fileURLWithPath: models).appendingPathComponent(folders.first?.folder ?? "models").path
        let link = ClusterLinkReadinessProbe.inspectLocalLink(isolation: false)
        let active = link.devices.filter(\.portActive)
        guard let device = (active.first { $0.verdict == .ready } ?? active.first)?.device else {
            throw ClusterSetupFailure("No cable port is active on this Mac: check the Thunderbolt cable, then run `darkbloom cluster` again.")
        }
        return ClusterSetupMemberFacts(memberID: pairing.localMemberID, linkAddress: selection.local.address.dottedDecimal,
            user: NSUserName(), ownerExecutable: Self.ownerExecutable(settings.darkbloomExecutable), workerExecutable: worker,
            modelDirectory: modelDirectory, runtimeBinarySHA256: try workerSHA256(worker),
            jacclDevice: device, linkSecretFile: pairing.secretFile)
    }

    /// Whether this Mac's cluster worker describes the model in `folder` with `manifest` (its runtime description:
    /// configuration and manifest only, no model load, a second at most).
    func workerAcceptsManifest(_ manifest: Data, folder: URL) -> Bool {
        let worker = settings.workerExecutable
            ?? ClusterBundledHelpers.defaultWorker(darkbloomExecutable: settings.darkbloomExecutable).path
        guard let digest = try? workerSHA256(worker), let directory = try? ClusterConsoleInstanceLock.userTemporaryDirectory() else { return false }
        let file = directory.appendingPathComponent("manifest-check-\(getpid())-\(UInt32.random(in: 0 ... .max)).json")
        guard (try? manifest.write(to: file, options: [.atomic])) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        return (try? DistributedCapabilityProbe.run(executable: URL(fileURLWithPath: worker), arguments: ["--describe-runtime",
            "--config", folder.appendingPathComponent("config.json").path, "--manifest", file.path,
            "--expected-executable-sha256", digest], deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000_000)) != nil
    }

    /// The worker's digest, read again only when its size or change time moved (each refresh asks).
    func workerSHA256(_ path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { throw ClusterSetupFailure("this Mac's cluster worker cannot be read") }
        let key = "\(path)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ino)"
        if let cached = lock.withLock({ workerDigest }), cached.key == key { return cached.digest }
        // A worker is tens of megabytes: hashed in chunks, not read through the setup files' small bound.
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ClusterSetupFailure("this Mac's cluster worker cannot be read") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.withLock { workerDigest = (key, digest) }
        return digest
    }

    /// The installed owner a setup names: this executable. DEBUG builds only:
    /// a harness that runs each Mac in a task-owned home names its wrapper
    /// (which sets that home) with `DARKBLOOM_DEBUG_OWNER_EXECUTABLE`.
    static func ownerExecutable(_ executable: URL) -> String {
        #if DEBUG
        if let wrapper = ProcessInfo.processInfo.environment["DARKBLOOM_DEBUG_OWNER_EXECUTABLE"], wrapper.hasPrefix("/") { return wrapper }
        #endif
        return ClusterSetupMemberFacts.installedOwnerPath(executable)
    }

    /// Starts answering the other Mac's wizard once this Mac has paired; a
    /// failure is retried at the next refresh.
    func ensureResponder() {
        guard settings.answersOverLink, let pairing = linkPairing() else { return }
        let begin: Bool = lock.withLock {
            guard responder == nil, !responderStarting else { return false }
            responderStarting = true
            return true
        }
        guard begin else { return }
        defer { lock.withLock { responderStarting = false } }
        guard let selection = try? linkSelection() else { return }
        let store = self.store
        guard let started = try? ClusterSetupLinkExchange.Responder(pairing: pairing, selection: selection, answer: { [weak self] in
            guard let self else { throw ClusterSetupFailure("the wizard is closing") }
            return ClusterSetupLinkAnswer(report: self.report(input: self.pairInput(), saved: self.savedConfiguration(),
                inbox: ClusterSetupLocalReader.inbox(self.store)), facts: try self.localFacts(pairing: pairing, selection: selection))
        }, receive: { data in try store.receive(data) }) else { return }
        do { try started.start() } catch { return }
        lock.withLock { responder = started }
    }

    /// The pair description the guided flow plans from: both members from the
    /// pairing and their own facts, reached over the link control channel.
    func linkDescription(pairing: ClusterSetupLinkExchange.Pairing) -> (pair: ClusterSetupRecord.Pair?, description: ClusterPairDescription?, error: String?) {
        let pair = ClusterSetupRecord.Pair(description: "", capability: "", capabilitySHA256: "", memberID: pairing.localMemberID)
        let local: ClusterSetupMemberFacts
        do {
            local = try localFacts(pairing: pairing, selection: try linkSelection())
        } catch let failure as ClusterSetupFailure {
            return (pair, nil, failure.text)
        } catch {
            return (pair, nil, clean(ClusterConsoleText.bounded(error)))
        }
        // Before the other Mac answered, it stands in with this Mac's facts under its own ID: labels only, never planned from.
        let peer = lock.withLock { linkPeer?.answer.facts }.flatMap { $0.memberID == pairing.peerMemberID ? $0 : nil }
            ?? ClusterSetupMemberFacts(memberID: pairing.peerMemberID, linkAddress: local.linkAddress, user: local.user,
                ownerExecutable: local.ownerExecutable, workerExecutable: local.workerExecutable, modelDirectory: local.modelDirectory,
                runtimeBinarySHA256: local.runtimeBinarySHA256, jacclDevice: local.jacclDevice, linkSecretFile: local.linkSecretFile)
        func member(_ facts: ClusterSetupMemberFacts) -> ClusterPairDescription.Member {
            .init(id: facts.memberID, host: facts.linkAddress, port: 22, user: facts.user, ownerExecutable: facts.ownerExecutable,
                workerExecutable: facts.workerExecutable, modelDirectory: facts.modelDirectory, runtimeBinarySHA256: facts.runtimeBinarySHA256,
                jacclDevice: facts.jacclDevice, linkAddress: facts.linkAddress, trust: nil, linkSecretFile: facts.linkSecretFile)
        }
        // The request limits are derived per model by the planner (zero asks for that); the ports are
        // chosen on this Mac, which leads the plans it makes (ClusterSetupPorts).
        let ports = ClusterSetupPorts.choose(linkAddress: local.linkAddress)
        let description = ClusterPairDescription(schema: ClusterPairDescription.schemaName, clusterID: pairing.clusterID,
            publicModelID: "-", capabilitySHA256: String(repeating: "0", count: 64), chunkTokens: 0, requestTimeoutSeconds: 0,
            coordinatorPort: Int(ports.coordinator), members: [member(local), member(peer)], tokenizerFiles: [],
            linkControl: .init(port: Int(ports.linkControl), linkEpoch: pairing.linkEpoch,
                               edgeID: pairing.edgeID))
        return (pair, description, nil)
    }

    var configuration: URL { settings.providerConfiguration }

    /// The local session leader's status, with this Mac's memory and link beside it.
    func observe(link: Bool = true) -> ClusterSetupLive {
        let status = blockingWizard { await ClusterDiagnostics.status(providerConfiguration: self.configuration) }.cleaned(clean)
        let state = link ? ClusterLinkReadinessProbe.inspectLocalLink().state.rawValue : nil
        return .init(status: status, localWiredBytes: ClusterOrphanWiredGuard.wiredBytes().map { Int(clamping: $0) },
            localPhysicalBytes: Int(clamping: ProcessInfo.processInfo.physicalMemory), linkState: state)
    }

    // MARK: - Reading

    /// The pair this wizard plans from: the one given now, else the one remembered.
    func pairInput() -> (pair: ClusterSetupRecord.Pair?, description: ClusterPairDescription?, error: String?) {
        // The guided flow: paired over the link, no SSH pair description.
        if let pairing = linkPairing() { return linkDescription(pairing: pairing) }
        let pair = settings.pair ?? (try? store.readRecord())?.pair
        guard let pair else { return (nil, nil, nil) }
        do {
            let data = try ClusterConfigurationFiles.read(URL(fileURLWithPath: pair.description), maximum: ClusterPairDescription.maximumBytes)
            let description = try ClusterPairDescription.decode(data)
            guard description.members.contains(where: { $0.id == pair.memberID }) else {
                return (pair, nil, "this Mac's member ID, \(pair.memberID), is not in the pair description")
            }
            return (pair, description, nil)
        } catch {
            return (pair, nil, clean(ClusterConsoleText.bounded(error)))
        }
    }

    func savedConfiguration() -> (reference: Result<ClusterConfigurationReference?, Error>, configuration: ClusterConfiguration?) {
        let reference = Result { try ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: configuration) }
        guard case .success(let value?) = reference else { return (reference, nil) }
        return (reference, try? ClusterConfigurationStore(paths: paths).load(reference: value).configuration)
    }

    func snapshot() -> ClusterSetupSnapshot {
        if let given = settings.modelsDirectory {
            _ = try? store.updateRecord { $0.modelsDirectory = given }
        }
        ensureResponder()
        let input = pairInput()
        let saved = savedConfiguration()
        let inbox = ClusterSetupLocalReader.inbox(store)
        let report = self.report(input: input, saved: saved, inbox: inbox)
        var record = ClusterSetupRecord(), recordError: String?
        do { record = try store.readRecord() } catch { recordError = clean(ClusterConsoleText.bounded(error)) }
        return .init(local: report, pair: ClusterSetupLocalReader.pair(saved: saved.configuration, inbox: inbox.configuration,
            description: input.description, localMemberID: input.pair?.memberID), pairError: input.error, record: record, recordError: recordError)
    }

    /// This Mac's report: what the wizard shows here and what the other Mac's wizard asks for.
    func report(input: (pair: ClusterSetupRecord.Pair?, description: ClusterPairDescription?, error: String?),
                saved: (reference: Result<ClusterConfigurationReference?, Error>, configuration: ClusterConfiguration?),
                inbox: (summary: ClusterSetupSetupSummary?, configuration: ClusterConfiguration?, error: String?),
                overrides: ClusterSetupLocalReader.Installation = .init()) -> ClusterSetupReport {
        let link = ClusterLinkReadinessProbe.inspectLocalLink()
        if settings.derivedPlacement, let store = modelsDirectory() {
            // `darkbloom cluster` needs no model folder: the models single-Mac Darkbloom installed are cloned into the
            // cluster's store (no new blocks), so both the leader and its members list them by digest. Only the
            // artifacts a pair may serve, as the onboarding clones: any other activated folder stays out of the store.
            for installed in ClusterProductModelStore.installed()
            where ClusterModelCopyTrust.servableArtifacts.contains(installed.artifact.aggregateSHA256) {
                _ = try? ClusterProductModelStore.cloneIntoClusterStore(installed, store: URL(fileURLWithPath: store), providerConfiguration: configuration,
                                                                        accepts: workerAcceptsManifest)
            }
        }
        let doctor = blockingWizard { await ClusterDiagnostics.doctor(providerConfiguration: self.configuration, localLink: link) }
        let savedSetup: ClusterConsoleSavedSetup
        switch saved.reference {
        case .success(let value):
            savedSetup = .read(reference: value, paths: paths, deadline: DispatchTime.now().uptimeNanoseconds + ClusterConsoleObserver.installedCheckNanoseconds)
        case .failure(let error):
            savedSetup = .init(state: .unreadable, error: ClusterConsoleText.bounded(error), configurationSHA256: nil, pairing: nil, model: nil, installed: nil)
        }
        return ClusterSetupLocalReader.report(link: link, doctor: doctor.checks.map(ClusterSetupCheck.init), version: settings.version,
            saved: savedSetup, savedConfiguration: saved.configuration, inbox: inbox, description: input.description,
            localMemberID: input.pair?.memberID, overrides: overrides, journal: doctor.deviceJournal,
            fallbackModelStore: modelsDirectory().map { URL(fileURLWithPath: $0) }).cleaned(clean)
    }

    /// The pinned route to the other Mac and where its installation is.
    func route() throws -> (ssh: ClusterSSHConfiguration, peer: (worker: String, models: String)) {
        let saved = savedConfiguration().configuration
        if let saved, saved.role == .leader {
            guard let trust = saved.trust else {
                throw ClusterSetupFailure("this setup reaches the other Mac over the link control channel; it has no SSH route")
            }
            let peer = saved.peers[1 - saved.localRank]
            return (try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                knownHostsFile: URL(fileURLWithPath: trust.knownHostsFile), identityFile: URL(fileURLWithPath: trust.identityFile),
                installedDarkbloom: peer.ownerExecutable), (peer.workerExecutable, peer.modelDirectory))
        }
        let input = pairInput()
        guard let description = input.description, let memberID = input.pair?.memberID,
              let local = description.members.first(where: { $0.id == memberID }),
              let peer = description.members.first(where: { $0.id != memberID }) else {
            throw ClusterSetupFailure(input.error ?? "this Mac has no pinned route to the other one: it follows, or it was given no pair description")
        }
        guard let trust = local.trust else {
            throw ClusterSetupFailure("this pair is reached over the paired link, not SSH")
        }
        return (try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
            knownHostsFile: URL(fileURLWithPath: trust.knownHostsFile), identityFile: URL(fileURLWithPath: trust.identityFile),
            installedDarkbloom: peer.ownerExecutable), (peer.workerExecutable, peer.modelDirectory))
    }

    func reachPeer() -> ClusterSetupPeerResult {
        if let pairing = linkPairing() {
            do {
                let started = DispatchTime.now().uptimeNanoseconds
                let reached = try ClusterSetupLinkExchange.ask(pairing: pairing, selection: try linkSelection(),
                    seconds: ClusterSetupOperations.peerSeconds)
                lock.withLock { linkPeer = (reached.answer, reached.peerAddress) }
                return .reached(reached.answer.report.cleaned(clean), seconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
            } catch let failure as ClusterSetupFailure {
                return .failed(failure.text)
            } catch {
                return .failed(clean(ClusterConsoleText.bounded(error)))
            }
        }
        do {
            let route = try route()
            let command = try route.ssh.setupReport(workerExecutable: route.peer.worker, modelDirectory: route.peer.models)
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = try ClusterSetupChild.run(executable: command.executable, arguments: command.arguments,
                environment: command.environment, seconds: ClusterSetupOperations.peerSeconds, maximumOutputBytes: ClusterSetupReport.maximumEncodedBytes)
            guard outcome.status == 0 else { return .failed(ClusterSetupChild.sshFailure(outcome)) }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            return .reached(try ClusterSetupReport.decode(outcome.output), seconds: seconds)
        } catch let failure as ClusterSetupFailure {
            return .failed(failure.text)
        } catch is ClusterSetupChild.TimedOut {
            return .failed("the other Mac did not answer within \(Int(ClusterSetupOperations.peerSeconds)) s")
        } catch {
            return .failed(clean(ClusterConsoleText.bounded(error)))
        }
    }

    // MARK: - Planning

    func plan(peer: ClusterSetupReport) -> ClusterSetupPlansResult {
        let input = pairInput()
        guard let description = input.description, let memberID = input.pair?.memberID,
              let local = description.members.first(where: { $0.id == memberID }) else {
            return .failed(input.error ?? "this Mac has no pair description to plan from")
        }
        if linkPairing() != nil, lock.withLock({ linkPeer }) == nil {
            return .failed("The other Mac is not answering. Make sure it is on, then run `darkbloom cluster` again.")
        }
        guard let peerProfile = peer.mac.profile else {
            return .failed("the other Mac's plan tool did not answer (\(peer.mac.profileError ?? "not installed")), so its memory is not known")
        }
        let tool = URL(fileURLWithPath: local.workerExecutable).deletingLastPathComponent().appendingPathComponent(ClusterPlacementFlow.toolName)
        let deadline = { DispatchTime.now().uptimeNanoseconds + 15_000_000_000 }
        let localProfile: ClusterDeviceProfile
        do {
            localProfile = try ClusterDeviceProfile.decode(DistributedCapabilityProbe.run(executable: tool, arguments: ["device", "--json", "--index"],
                deadline: deadline(), maximumOutputBytes: ClusterDeviceProfile.maximumEncodedBytes))
        } catch {
            return .failed("this Mac's plan tool did not answer: \(clean(ClusterConsoleText.bounded(error)))")
        }
        let parent = URL(fileURLWithPath: local.modelDirectory).deletingLastPathComponent()
        let models: [ClusterSetupLocalModel]
        do {
            // One row per catalog entry: two folders of the same entry (a catalog download beside a copy) are one
            // model to the person choosing, and the setup's own folder is the one kept.
            let current = URL(fileURLWithPath: local.modelDirectory).lastPathComponent
            let folders = try ClusterSetupModelFolders.list(parent: parent).sorted { ($0.folder == current ? 0 : 1) < ($1.folder == current ? 0 : 1) }
            models = folders.reduce(into: [ClusterSetupLocalModel]()) { kept, model in
                if !kept.contains(where: { $0.sameEntry(model) }) { kept.append(model) }
            }.sorted { $0.folder < $1.folder }
        } catch {
            return .failed("the model folders could not be listed: \(clean(ClusterConsoleText.bounded(error)))")
        }
        let readings = models.filter {
            settings.privateGLMImageQualification ? ClusterGLMOnboardingSelection.accepts($0)
                : ClusterMiMoOnboardingSelection.accepts($0, qualifying: settings.privateMiMoImageQualification)
        }.map { model -> ClusterSetupPlanning.ModelReading in
            let directory = parent.appendingPathComponent(model.folder)
            let probes = settings.privateGLMImageQualification
                ? ClusterGLMOnboardingSelection.probeArguments(directory: directory, expectedWorkerSHA256: local.runtimeBinarySHA256)
                : ClusterMiMoOnboardingSelection.probeArguments(directory: directory,
                expectedWorkerSHA256: local.runtimeBinarySHA256, qualifying: settings.privateMiMoImageQualification)
            let layoutArguments = probes.layout
            let layout: Result<ClusterModelLayout, ClusterSetupFailure>
            do {
                layout = .success(try ClusterModelLayout.decode(DistributedCapabilityProbe.run(executable: tool, arguments: layoutArguments,
                    deadline: deadline(), maximumOutputBytes: ClusterModelLayout.maximumEncodedBytes)))
            } catch {
                layout = .failure(ClusterSetupFailure(toolError(executable: tool, arguments: layoutArguments, fallback: error)))
            }
            let worker = URL(fileURLWithPath: local.workerExecutable)
            let describe = probes.capability
            let capability: Result<(record: ClusterRuntimeCapability, data: Data, sha256: String), ClusterSetupFailure>
            do {
                let data = try DistributedCapabilityProbe.run(executable: worker, arguments: describe, deadline: deadline())
                let record = try ClusterCapabilityRecord.decode(data, writtenBy: "the worker")
                if settings.privateGLMImageQualification { try ClusterGLMOnboardingSelection.requireCandidate(record) }
                else { try ClusterMiMoOnboardingSelection.requireCandidate(record, qualifying: settings.privateMiMoImageQualification) }
                capability = .success((record, data, ClusterConfigurationCodec.sha256(data)))
            } catch {
                capability = .failure(ClusterSetupFailure(toolError(executable: worker, arguments: describe, fallback: error)))
            }
            let manifest = ClusterSetupModelFolders.readManifest(directory.appendingPathComponent("manifest.json")) ?? Data()
            return .init(model: model, layout: layout, capability: capability, tokenizerFiles: ClusterSetupPlanning.tokenizerFiles(manifest: manifest))
        }
        // The profiles are kept for the serving leader's per-request route; the speed
        // records of requests this pair served join the measurements (the next plan).
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let peerID = description.members.first(where: { $0.id != memberID })?.id {
            ClusterMemberProfiles.record([memberID: localProfile, peerID: peerProfile], homeDirectory: home)
        }
        let decided = ClusterSetupPlanning.decide(readings: readings, description: description, localMemberID: memberID,
            localProfile: localProfile, peerProfile: peerProfile, peerModels: peer.models, measurements: measurements(),
            leader: settings.derivedPlacement ? .some(nil) : .none, served: ClusterServedSpeedHistory.entries(homeDirectory: home) + (peer.served ?? []),
            link: description.members.count == 2
                ? ClusterLinkProbeHistory.costs(homeDirectory: home, members: description.members.map(\.id)) ?? .unmeasured : .unmeasured,
            peerMayReceive: settings.derivedPlacement && !settings.privateImageQualification)
        lock.withLock { decisions = Dictionary(decided.map { ($0.option.model.folder, $0) }, uniquingKeysWith: { a, _ in a }) }
        // Models that can be chosen first, each group by size.
        let options = decided.map(\.option)
        let open = options.filter { $0.blocker == nil }.sorted { $0.model.totalBytes < $1.model.totalBytes }
        let blocked = options.filter { $0.blocker != nil }.sorted { $0.model.totalBytes < $1.model.totalBytes }
        return .ready(open + blocked)
    }

    /// A tool's own error line, for a model it refused: the first line it wrote on standard error.
    func toolError(executable: URL, arguments: [String], fallback: Error) -> String {
        if let outcome = try? ClusterSetupChild.run(executable: executable, arguments: arguments, seconds: 15, maximumOutputBytes: 1 << 20),
           outcome.status != 0, let line = outcome.errorText.split(whereSeparator: \.isNewline).first {
            return clean(ClusterConsoleText.bounded(String(line), maximum: 160))
        }
        return clean(ClusterConsoleText.bounded(String(describing: fallback), maximum: 160))
    }

    /// Speed measurements kept beside the wizard's record, by the placement work's own format.
    func measurements() -> [ClusterSpeedMeasurement] {
        let directory = store.paths.directory.appendingPathComponent("speed", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = try? ClusterConfigurationFiles.read(directory.appendingPathComponent(name), maximum: 65_536),
                  let value = try? JSONDecoder().decode(ClusterSpeedMeasurement.self, from: data), (try? value.validate()) != nil else { return nil }
            return value
        }
    }

    // MARK: - Adopting a plan

    func adopt(folder: String, planKey: String, peer: ClusterSetupReport) -> ClusterConsoleActionResult {
        guard let decision = lock.withLock({ decisions[folder] }), let plan = decision.option.plan,
              ClusterSetupState.planKey(decision.option.model, plan) == planKey,
              let setup = decision.setup, let capability = decision.capability else {
            return .init(succeeded: false, lines: ["The plan changed. Choose the model again; nothing was saved."])
        }
        let input = pairInput()
        guard let memberID = input.pair?.memberID, let localData = setup.configurations[memberID],
              let peerID = setup.configurations.keys.first(where: { $0 != memberID }), let peerData = setup.configurations[peerID] else {
            return .init(succeeded: false, lines: ["The plan did not give both Macs a setup."])
        }
        do {
            // Recheck the exact described capability before any setup is saved or sent.
            let record = try ClusterCapabilityRecord.decode(capability.data, writtenBy: "the worker")
            if settings.privateGLMImageQualification { try ClusterGLMOnboardingSelection.requireCandidate(record) }
                else { try ClusterMiMoOnboardingSelection.requireCandidate(record, qualifying: settings.privateMiMoImageQualification) }
            // The setups and the record are kept where the wizard keeps its own files, owner-only.
            let directory = store.paths.directory.appendingPathComponent("plan-" + ClusterConsoleText.timestamp().replacingOccurrences(of: ":", with: ""), isDirectory: true)
            try ClusterConfigurationFiles.ensureDirectory(store.paths.directory, create: true, privateMode: true)
            guard mkdir(directory.path, 0o700) == 0 else { throw ClusterSetupFailure("cannot create \(directory.lastPathComponent) (errno \(errno))") }
            let files = [("\(memberID).setup.json", localData), ("\(peerID).setup.json", peerData), ("capability.json", capability.data)]
            for (name, data) in files {
                try ClusterConfigurationFiles.update(directory.appendingPathComponent(name), maximum: ClusterRuntimeCapabilityCodec.maximumBytes) { _ in data }
            }
            let saved = try ClusterConfigurationStore(paths: paths).configure(configurationInput: directory.appendingPathComponent("\(memberID).setup.json"),
                capabilityInput: directory.appendingPathComponent("capability.json"), capabilitySHA256: capability.sha256,
                providerConfiguration: configuration)
            let localRank = plan.ranks.first { $0.local }?.rank ?? 0
            let part = localRank == 0 ? "this Mac runs rank 0 and the serving API" : "this Mac runs rank \(localRank)"
            // The onboarding shows the deployment in one plain line once it serves; the six-step wizard keeps its detail.
            var lines = settings.derivedPlacement ? ["Saved this Mac's setup for \(decision.option.model.modelID)."]
                : ["Saved this Mac's setup \(saved.configurationSHA256.prefix(12)): \(decision.option.model.modelID), cut after \(plan.cut) layers, \(plan.mode); \(part)."]
            if let pairing = linkPairing() {
                // Over the paired link: the other Mac's open wizard puts it in its inbox.
                let delivery = try JSONEncoder().encode(ClusterSetupStore.Delivery(configuration: peerData, capability: capability.data,
                    capabilitySHA256: capability.sha256))
                // Sent again by itself (3 tries, a few seconds apart) before anything is asked of the person.
                var digest: String?
                var lastFailure: ClusterSetupFailure?
                for attempt in 0..<3 where digest == nil {
                    if attempt > 0 { lines.append("Could not send the setup to the other Mac. Retrying."); sleep(3) }
                    do {
                        digest = try ClusterSetupLinkExchange.deliver(pairing: pairing, selection: try linkSelection(),
                            peerAddress: lock.withLock { linkPeer?.address }, delivery: delivery, seconds: ClusterSetupOperations.peerSeconds)
                    } catch let failure as ClusterSetupFailure { lastFailure = failure }
                }
                guard let delivered = digest else {
                    lines.append("Could not send the setup to the other Mac (\(lastFailure?.text ?? "no answer")). Make sure it is on, then run `darkbloom cluster` again.")
                    return .init(succeeded: false, lines: lines)
                }
                try store.updateRecord {
                    $0.add(.init(clusterID: setupClusterID(peerData) ?? "", memberID: peerID,
                        configurationSHA256: ClusterConfigurationSyntax.hash(delivered) ? delivered : "", at: ClusterConsoleText.timestamp()))
                }
                lines.append(settings.derivedPlacement
                    ? "Sent the setup to the other Mac over the cable; its cluster service applied it."
                    : "Sent the other Mac its setup over the paired link: on that Mac, press a, then y, in `darkbloom cluster`.")
                return .init(succeeded: true, lines: lines)
            }
            // The other Mac gets its own setup in its inbox; it approves it there.
            let route = try route()
            let command = try route.ssh.sendSetup()
            let delivery = try JSONEncoder().encode(ClusterSetupStore.Delivery(configuration: peerData, capability: capability.data,
                capabilitySHA256: capability.sha256))
            let outcome = try ClusterSetupChild.run(executable: command.executable, arguments: command.arguments, environment: command.environment,
                input: delivery, seconds: ClusterSetupOperations.peerSeconds, maximumOutputBytes: 4096)
            guard outcome.status == 0 else {
                lines.append("Could not send the setup to \(peerID) (\(ClusterSetupChild.sshFailure(outcome))). Run `darkbloom cluster` again to resend it.")
                return .init(succeeded: false, lines: lines)
            }
            let digest = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try store.updateRecord {
                $0.add(.init(clusterID: setupClusterID(peerData) ?? "", memberID: peerID,
                    configurationSHA256: ClusterConfigurationSyntax.hash(digest) ? digest : "", at: ClusterConsoleText.timestamp()))
            }
            lines.append("Sent \(peerID) its setup: on \(peerID), run `darkbloom cluster` and press a, then y.")
            return .init(succeeded: true, lines: lines)
        } catch let failure as ClusterSetupFailure {
            return .init(succeeded: false, lines: [failure.text])
        } catch {
            return .failure(error)
        }
    }

    private func setupClusterID(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["clusterID"] as? String
    }

    // MARK: - Test prompt

    func prompt(text: String, maxTokens: Int, port given: Int? = nil, events: @escaping @Sendable (ClusterSetupPromptEvent) -> Void) {
        // `given`: a server whose port is known (degraded serving alone); otherwise the cluster session's own listener.
        let port: Int
        if let given { port = given } else {
            let status = blockingWizard { await ClusterDiagnostics.status(providerConfiguration: self.configuration) }
            guard let bound = status.live?.boundPort else { return events(.failed("the leader's status names no listener")) }
            port = Int(bound)
        }
        guard let model = savedConfiguration().configuration?.publicModelID else { return events(.failed("no saved setup names the model")) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = LocalEndpoint.token(forPort: port) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // Keep the generic probe free of family-specific thinking controls.
        // Reasoning-only output is handled below when the token budget ends.
        let body = ClusterSetupProbeRequest.body(model: model, text: text, maxTokens: maxTokens)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let prepared = request
        blockingWizard {
            let started = DispatchTime.now().uptimeNanoseconds
            var first: UInt64?, chunks = 0, usage: Int?, finish: String?, answered = false
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: prepared)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    var detail = ""
                    for try await line in bytes.lines { detail += line; if detail.count > 300 { break } }
                    events(.failed("the local API answered \((response as? HTTPURLResponse)?.statusCode ?? 0): \(ClusterConsoleText.bounded(detail, maximum: 200))"))
                    return
                }
                for try await line in bytes.lines {
                    guard let chunk = ClusterSetupStream.parse(line) else { continue }
                    if let error = chunk.error { events(.failed(error)); return }
                    // A thinking model's first tokens are its reasoning: they count for the first token.
                    if chunk.reasoning, first == nil { first = DispatchTime.now().uptimeNanoseconds }
                    if let content = chunk.content, !content.isEmpty {
                        if first == nil { first = DispatchTime.now().uptimeNanoseconds }
                        chunks += 1; answered = true
                        events(.text(content))
                    }
                    if let reason = chunk.finishReason { finish = reason }
                    if let tokens = chunk.completionTokens { usage = tokens }
                    if chunk.done { break }
                }
                // Reasoning models may spend the test's few tokens entirely on thinking.
                if !answered, first != nil { events(.text("(still thinking when the test's \(maxTokens) tokens ran out)")) }
                let end = DispatchTime.now().uptimeNanoseconds
                let tokens = usage ?? chunks
                let rate: Double? = first.flatMap { f in tokens > 1 && end > f ? Double(tokens - 1) / (Double(end - f) / 1e9) : nil }
                events(.finished(.init(completionTokens: tokens, firstTokenMilliseconds: first.map { Int(($0 - started) / 1_000_000) },
                    tokensPerSecond: rate, finishReason: finish)))
            } catch {
                events(.failed(ClusterConsoleText.bounded(error.localizedDescription, maximum: 200)))
            }
        }
    }
}

/// `darkbloom cluster report --json`: this Mac's own report, for the other
/// Mac's wizard. `workerExecutable` and `modelDirectory` say where this Mac's
/// installation is when it has no setup yet; a saved setup wins over them.
public enum ClusterSetupReporting {
    public static func report(providerConfiguration: URL, version: String, workerExecutable: String?,
                              modelDirectory: String?) throws -> ClusterSetupReport {
        let paths = try ClusterUserPaths()
        let context = LiveContext(paths: paths, store: ClusterSetupStore(paths: .init(paths: paths)),
            settings: .init(providerConfiguration: providerConfiguration, darkbloomExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                sessionArguments: [], pair: nil, dryRun: true, version: version),
            clean: ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path))
        var overrides = ClusterSetupLocalReader.Installation()
        overrides.workerExecutable = workerExecutable
        overrides.modelDirectory = modelDirectory
        return context.report(input: context.pairInput(), saved: context.savedConfiguration(),
            inbox: ClusterSetupLocalReader.inbox(context.store), overrides: overrides)
    }
}

/// Runs an asynchronous operation to completion from a thread outside the
/// cooperative pool (the wizard's work queue). The calling thread waits.
@discardableResult
func blockingWizard<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) -> Value {
    let box = WizardBlockingResult<Value>(), finished = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await operation()
        finished.signal()
    }
    finished.wait()
    return box.value!
}

private final class WizardBlockingResult<Value: Sendable>: @unchecked Sendable {
    var value: Value?
}
