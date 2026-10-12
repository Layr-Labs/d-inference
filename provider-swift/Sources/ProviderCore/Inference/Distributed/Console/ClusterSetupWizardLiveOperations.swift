import Foundation
import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote

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
        return ClusterSetupOperations(
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
            observeSession: {
                let status = blockingWizard { await ClusterDiagnostics.status(providerConfiguration: configuration) }.cleaned(clean)
                let link = ClusterLinkReadinessProbe.inspectLocalLink()
                return .init(status: status, localWiredBytes: ClusterOrphanWiredGuard.wiredBytes().map { Int(clamping: $0) },
                    localPhysicalBytes: Int(clamping: ProcessInfo.processInfo.physicalMemory), linkState: link.state.rawValue)
            },
            launchSession: { events in
                try ClusterConsoleSessionProcess.start(.init(executable: settings.darkbloomExecutable, arguments: settings.sessionArguments),
                    events: events)
            },
            sendPrompt: { text, maxTokens, events in context.prompt(text: text, maxTokens: maxTokens, events: events) })
    }
}

/// What the live operations share: paths, the record, and the last plans,
/// so that adopting a plan saves exactly the one that was on screen.
private final class LiveContext: @unchecked Sendable {
    let paths: ClusterUserPaths
    let store: ClusterSetupStore
    let settings: ClusterSetupOperations.LiveSettings
    let clean: ClusterConsoleFreeText
    private let lock = NSLock()
    private var decisions: [String: ClusterSetupPlanning.Decision] = [:]

    init(paths: ClusterUserPaths, store: ClusterSetupStore, settings: ClusterSetupOperations.LiveSettings, clean: ClusterConsoleFreeText) {
        self.paths = paths; self.store = store; self.settings = settings; self.clean = clean
    }

    var configuration: URL { settings.providerConfiguration }

    // MARK: - Reading

    /// The pair this wizard plans from: the one given now, else the one remembered.
    func pairInput() -> (pair: ClusterSetupRecord.Pair?, description: ClusterPairDescription?, error: String?) {
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
            localMemberID: input.pair?.memberID, overrides: overrides, journal: doctor.deviceJournal).cleaned(clean)
    }

    /// The pinned route to the other Mac and where its installation is.
    func route() throws -> (ssh: ClusterSSHConfiguration, peer: (worker: String, models: String)) {
        let saved = savedConfiguration().configuration
        if let saved, saved.role == .leader {
            let peer = saved.peers[1 - saved.localRank]
            return (try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                knownHostsFile: URL(fileURLWithPath: saved.trust.knownHostsFile), identityFile: URL(fileURLWithPath: saved.trust.identityFile),
                installedDarkbloom: peer.ownerExecutable), (peer.workerExecutable, peer.modelDirectory))
        }
        let input = pairInput()
        guard let description = input.description, let memberID = input.pair?.memberID,
              let local = description.members.first(where: { $0.id == memberID }),
              let peer = description.members.first(where: { $0.id != memberID }) else {
            throw ClusterSetupFailure(input.error ?? "this Mac has no pinned route to the other one: it follows, or it was given no pair description")
        }
        return (try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
            knownHostsFile: URL(fileURLWithPath: local.trust.knownHostsFile), identityFile: URL(fileURLWithPath: local.trust.identityFile),
            installedDarkbloom: peer.ownerExecutable), (peer.workerExecutable, peer.modelDirectory))
    }

    func reachPeer() -> ClusterSetupPeerResult {
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
        do { models = try ClusterSetupModelFolders.list(parent: parent) } catch {
            return .failed("the model folders could not be listed: \(clean(ClusterConsoleText.bounded(error)))")
        }
        let readings = models.map { model -> ClusterSetupPlanning.ModelReading in
            let directory = parent.appendingPathComponent(model.folder)
            let layoutArguments = ["layout", "--model-dir", directory.path, "--json"]
            let layout: Result<ClusterModelLayout, ClusterSetupFailure>
            do {
                layout = .success(try ClusterModelLayout.decode(DistributedCapabilityProbe.run(executable: tool, arguments: layoutArguments,
                    deadline: deadline(), maximumOutputBytes: ClusterModelLayout.maximumEncodedBytes)))
            } catch {
                layout = .failure(ClusterSetupFailure(toolError(executable: tool, arguments: layoutArguments, fallback: error)))
            }
            let worker = URL(fileURLWithPath: local.workerExecutable)
            let describe = ["--describe-runtime", "--config", directory.appendingPathComponent("config.json").path,
                            "--manifest", directory.appendingPathComponent("manifest.json").path,
                            "--expected-executable-sha256", local.runtimeBinarySHA256]
            let capability: Result<(record: ClusterRuntimeCapability, data: Data, sha256: String), ClusterSetupFailure>
            do {
                let data = try DistributedCapabilityProbe.run(executable: worker, arguments: describe, deadline: deadline())
                capability = .success((try ClusterCapabilityRecord.decode(data, writtenBy: "the worker"), data, ClusterConfigurationCodec.sha256(data)))
            } catch {
                capability = .failure(ClusterSetupFailure(toolError(executable: worker, arguments: describe, fallback: error)))
            }
            let manifest = (try? ClusterConfigurationFiles.read(directory.appendingPathComponent("manifest.json"), maximum: 1024 * 1024)) ?? Data()
            return .init(model: model, layout: layout, capability: capability, tokenizerFiles: ClusterSetupPlanning.tokenizerFiles(manifest: manifest))
        }
        let decided = ClusterSetupPlanning.decide(readings: readings, description: description, localMemberID: memberID,
            localProfile: localProfile, peerProfile: peerProfile, peerModels: peer.models, measurements: measurements())
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
            return .init(succeeded: false, lines: ["The plan changed since it was shown, so nothing was saved. Look at it again and press enter."])
        }
        let input = pairInput()
        guard let memberID = input.pair?.memberID, let localData = setup.configurations[memberID],
              let peerID = setup.configurations.keys.first(where: { $0 != memberID }), let peerData = setup.configurations[peerID] else {
            return .init(succeeded: false, lines: ["The plan did not give both Macs a setup."])
        }
        do {
            // The setups and the record are kept where the wizard keeps its own files, owner-only.
            let directory = store.paths.directory.appendingPathComponent("plan-" + ClusterConsoleText.timestamp().replacingOccurrences(of: ":", with: ""), isDirectory: true)
            _ = try ClusterConfigurationFiles.directory(store.paths.directory, create: true, privateMode: true)
            guard mkdir(directory.path, 0o700) == 0 else { throw ClusterSetupFailure("cannot create \(directory.lastPathComponent) (errno \(errno))") }
            let files = [("\(memberID).setup.json", localData), ("\(peerID).setup.json", peerData), ("capability.json", capability.data)]
            for (name, data) in files {
                try ClusterConfigurationFiles.update(directory.appendingPathComponent(name), maximum: ClusterRuntimeCapabilityCodec.maximumBytes) { _ in data }
            }
            let saved = try ClusterConfigurationStore(paths: paths).configure(configurationInput: directory.appendingPathComponent("\(memberID).setup.json"),
                capabilityInput: directory.appendingPathComponent("capability.json"), capabilitySHA256: capability.sha256,
                providerConfiguration: configuration)
            var lines = ["Saved this Mac's setup \(saved.configurationSHA256.prefix(12)): \(decision.option.model.modelID), cut after \(plan.cut) layers, \(plan.mode); this Mac leads."]
            // The other Mac gets its own setup in its inbox; it approves it there.
            let route = try route()
            let command = try route.ssh.sendSetup()
            let delivery = try JSONEncoder().encode(ClusterSetupStore.Delivery(configuration: peerData, capability: capability.data,
                capabilitySHA256: capability.sha256))
            let outcome = try ClusterSetupChild.run(executable: command.executable, arguments: command.arguments, environment: command.environment,
                input: delivery, seconds: ClusterSetupOperations.peerSeconds, maximumOutputBytes: 4096)
            guard outcome.status == 0 else {
                lines.append("Could not send \(peerID) its setup: \(ClusterSetupChild.sshFailure(outcome)). Press enter on step 4 again to resend it.")
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

    func prompt(text: String, maxTokens: Int, events: @escaping @Sendable (ClusterSetupPromptEvent) -> Void) {
        let status = blockingWizard { await ClusterDiagnostics.status(providerConfiguration: self.configuration) }
        guard let port = status.live?.boundPort else { return events(.failed("the leader's status names no listener")) }
        guard let model = savedConfiguration().configuration?.publicModelID else { return events(.failed("no saved setup names the model")) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = LocalEndpoint.readToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // Greedy and without a thinking phase, so the few tokens asked for are the answer itself.
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": text]], "max_tokens": maxTokens,
                                   "stream": true, "temperature": 0, "stream_options": ["include_usage": true], "enable_thinking": false]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let prepared = request
        blockingWizard {
            let started = DispatchTime.now().uptimeNanoseconds
            var first: UInt64?, chunks = 0, usage: Int?, finish: String?
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
                    if let content = chunk.content, !content.isEmpty {
                        if first == nil { first = DispatchTime.now().uptimeNanoseconds }
                        chunks += 1
                        events(.text(content))
                    }
                    if let reason = chunk.finishReason { finish = reason }
                    if let tokens = chunk.completionTokens { usage = tokens }
                    if chunk.done { break }
                }
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
private func blockingWizard<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) -> Value {
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
