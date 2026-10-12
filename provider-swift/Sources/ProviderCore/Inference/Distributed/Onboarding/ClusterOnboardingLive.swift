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
            stop: { live.stop() })
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

    func ensureService() -> Result<String, ClusterOnboardingFailure> {
        do {
            let started = try ClusterService.ensureRunning(executable: settings.service.wizard.darkbloomExecutable,
                arguments: settings.serviceArguments)
            return .success(started ? "Started this Mac's cluster service: it runs this Mac's part whenever the leader asks."
                : "This Mac's cluster service is running.")
        } catch let failure as ClusterOnboardingFailure {
            return .failure(failure)
        } catch {
            return .failure(.init("\(error)"))
        }
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
                let last = plan.ranks.map(\.rank).max() ?? 0
                var lines = plan.ranks.map { rank in
                    let name = rank.local ? "\(localName) (this Mac)" : peerName
                    return "rank \(rank.rank)\(rank.rank == last ? " (decodes)" : rank.rank == 0 ? " (serving API)" : ""): \(name), layers \(rank.firstLayer)-\(rank.endLayer - 1)"
                }
                let speed = plan.absolute ? "about \(Int(plan.decodeTokensPerSecond.rounded())) tokens/s" : "speed not yet measured on these Macs"
                lines.append("\(gigabytes), \(ClusterOnboardingWords.mode(plan.mode)), \(speed)\(plan.measured ? "" : plan.absolute ? " (estimate)" : "")"
                    + (plan.fitsNow ? "" : "; does not fit now"))
                return .init(title: title, lines: lines, blocker: option.blocker)
            }
            lock.withLock { self.choices = keys }
            return .success(choices)
        }
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
            return .failure(.init("\(peerName) was not started: \(failure.text)"))
        } catch {
            return .failure(.init("\(peerName) was not started: \(error)"))
        }
        return .success(["Started \(peerName)'s part over the cable (its cluster service runs it); this Mac's service runs its own."])
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
                return .failure(.init("The test request did not reach \(peerName): \(error)"))
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
            lines.append(session.ready ? "Serving \(model) from \(now.local ? "this Mac" : peerName) at 127.0.0.1:\(session.port ?? 0) (\(session.readyRanks) of \(session.ranks) parts ready)."
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
            return .failure(.init("This Mac stopped serving; \(peerName) did not answer (\(error)) and stops when it next hears from this Mac."))
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
