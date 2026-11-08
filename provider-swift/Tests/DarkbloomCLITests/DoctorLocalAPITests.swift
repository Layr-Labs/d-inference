import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom doctor`'s Local API section (UX audit R17): the way this Mac serves, its local API's address, whether it
/// answers and on which port, whether its key file is there (never the key), and whether OpenCode and Hermes point at
/// it, each problem with the next command. On a Mac set to Only me, the Darkbloom network's checks don't apply.
@Suite("doctor: Local API")
struct DoctorLocalAPITests {
    static var cli: String { BuildEnvironment.current.cliName }
    static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    static let keyFile = home.appendingPathComponent(".darkbloom/local_token")
    static let secret = "dk-local-DoctorFixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    /// A coordinator-connected provider writes its capabilities; the Only-me server writes none.
    static func state(pid: Int32 = 4_242, connected: Bool = true, meFirst: MeFirstSnapshot? = nil,
                      failure: DaemonState.LocalAPIFailure? = nil) -> DaemonState {
        DaemonState(pid: pid, version: "test", writtenAt: 0, startedAt: 0, runtimeCapabilities: connected ? [] : nil,
                    meFirst: meFirst, localAPIFailure: failure)
    }

    static func endpoint(pid: Int32 = 4_242, port: UInt16 = 8001, apiKey: String = secret,
                         host: String = "127.0.0.1") -> LocalEndpoint.Info {
        LocalEndpoint.Info(host: host, port: port, apiKey: apiKey, version: "test", pid: pid, updatedAt: "now")
    }

    static let meFirst = MeFirstSnapshot(idleMs: 120_000, paused: false)

    static func tool(_ tool: IntegrationTool, _ found: DoctorToolSetup.Found) -> DoctorToolSetup {
        let file = tool == .opencode ? ".config/opencode/opencode.jsonc" : ".hermes/config.yaml"
        return DoctorToolSetup(tool: tool, file: home.appendingPathComponent(file), found: found)
    }

    static let notSetUp = [tool(.opencode, .noFile), tool(.hermes, .noEntry)]

    private func section(_ facts: DoctorLocalAPI.Facts) -> DoctorLocalAPI {
        var facts = facts
        facts.home = Self.home
        return DoctorLocalAPI(facts: facts)
    }

    private func find(_ name: String, in diagnostics: [Diagnostic]) -> Diagnostic? {
        diagnostics.first { $0.name == name }
    }

    @Test func aMacSetToOnlyMeSaysTheNetworkChecksAreNotNeeded() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001), tools: Self.notSetUp))
        #expect(doctor.onlyMe)
        let lines = doctor.diagnostics
        #expect(lines.allSatisfy { $0.section == .localAPI })
        #expect(find("mode", in: lines)?.message == "Only me, on this Mac — Darkbloom never contacts this Mac (saved)")
        let network = try #require(find("darkbloom network", in: lines))
        #expect(network.level == .info)
        #expect(network.message.hasPrefix("not needed (Only me): the account, trust, App Attest and coordinator checks are skipped"))
        #expect(network.message.contains("`\(Self.cli) start --choose`"))
        let address = try #require(find("address", in: lines))
        #expect(address.level == .warn)
        #expect(address.message == "http://127.0.0.1:8001/v1 — not running")
        #expect(address.fix == "`\(Self.cli) start`")
        #expect(find("OpenCode", in: lines)?.message == "not set up (`\(Self.cli) --opencode` sets it up)")
        #expect(find("Hermes", in: lines)?.message == "not set up (`\(Self.cli) --hermes` sets it up)")
    }

    @Test func networkChecksRunAnywayDropTheNotNeededLine() {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001)))
        #expect(doctor.lines(networkChecks: false).contains { $0.name == "darkbloom network" })
        #expect(!doctor.lines(networkChecks: true).contains { $0.name == "darkbloom network" })
        #expect(DoctorLocalAPI.networkNotNeeded.status == .info)
        #expect(DoctorLocalAPI.networkNotNeeded.detail.hasPrefix("not needed (Only me)"))
        // `--coordinator <url>` runs them anyway; a Mac that serves Darkbloom always runs them.
        #expect(!doctor.runsNetworkChecks(coordinatorOverride: nil))
        #expect(doctor.runsNetworkChecks(coordinatorOverride: "https://coordinator.example"))
        #expect(section(.init(saved: LocalSettings(mode: .both, port: 8001))).runsNetworkChecks(coordinatorOverride: nil))
    }

    @Test func bothWithItsLocalAPIUpSaysTheAddressPortAndKeyFile() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001),
                                   running: Self.state(meFirst: Self.meFirst), live: Self.endpoint(), answers: true,
                                   keyFile: Self.keyFile, tools: Self.notSetUp))
        #expect(!doctor.onlyMe)
        let lines = doctor.diagnostics
        #expect(find("mode", in: lines)?.message
            == "Both, me first — Darkbloom pauses while you use this Mac, back after 2 idle minutes (serving now)")
        #expect(find("darkbloom network", in: lines) == nil)
        let address = try #require(find("address", in: lines))
        #expect(address.level == .pass)
        #expect(address.message == "http://127.0.0.1:8001/v1 — up on port 8001")
        let key = try #require(find("key file", in: lines))
        #expect(key.level == .pass)
        #expect(key.message == "~/.darkbloom/local_token (`\(Self.cli) local` shows the key)")
    }

    @Test func aLocalAPIWhosePortDoesntAnswerFailsWithRestart() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                                   live: Self.endpoint(), answers: false, keyFile: Self.keyFile))
        let address = try #require(find("address", in: doctor.diagnostics))
        #expect(address.level == .fail)
        #expect(address.message == "http://127.0.0.1:8001/v1 — its server runs, but port 8001 doesn't answer")
        #expect(address.fix == "`\(Self.cli) restart`")
    }

    @Test func aPortInUseNamesTheNextFreePort() throws {
        var facts = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .both, port: 8001),
                                         running: Self.state(meFirst: Self.meFirst,
                                                             failure: .init(host: "127.0.0.1", port: 8001, portInUse: true)))
        facts.nextFreePort = { $0 == 8001 ? 8002 : nil }
        let doctor = section(facts)
        #expect(doctor.mode == .both)
        let address = try #require(find("address", in: doctor.diagnostics))
        #expect(address.level == .fail)
        #expect(address.message == "http://127.0.0.1:8001/v1 isn't up")
        #expect(address.fix == "port 8001 is in use (`\(Self.cli) start --port 8002`)")
    }

    @Test func aRunningKeyedAPIWithoutItsKeyFileFails() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state(connected: false),
                                   live: Self.endpoint(), answers: true, keyFile: nil))
        #expect(doctor.onlyMe)
        let key = try #require(find("key file", in: doctor.diagnostics))
        #expect(key.level == .fail)
        #expect(key.message == "no key file holds the running API's key, so tools that read it are refused")
        #expect(key.fix == "`\(Self.cli) restart`")
    }

    @Test func anAPIWithoutAKeySaysSo() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                                   live: Self.endpoint(apiKey: ""), answers: true, keyFile: Self.keyFile))
        let key = try #require(find("key file", in: doctor.diagnostics))
        #expect(key.level == .info)
        #expect(key.message.hasPrefix("none: this API takes no key (--no-auth)"))
    }

    @Test func darkbloomNetworkHasNoLocalAPIAndFlagsAToolLeftPointingHere() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .network),
                                   tools: [Self.tool(.opencode, .entry(address: "http://127.0.0.1:8001/v1",
                                                                       keyFile: "~/.darkbloom/local_token")),
                                           Self.tool(.hermes, .noFile)]))
        #expect(!doctor.onlyMe)
        let lines = doctor.diagnostics
        #expect(find("mode", in: lines)?.message == "Darkbloom network — this Mac serves Darkbloom and earns while it runs (saved)")
        #expect(find("address", in: lines) == nil && find("key file", in: lines) == nil && find("Hermes", in: lines) == nil)
        let openCode = try #require(find("OpenCode", in: lines))
        #expect(openCode.level == .warn)
        #expect(openCode.message.hasPrefix("points at http://127.0.0.1:8001/v1, but this Mac serves no local API"))
        #expect(openCode.fix?.contains("`\(Self.cli) start --choose`") == true)
    }

    @Test func toolsPointingHereElsewhereOrAtAnotherKeyFile() throws {
        let tools = [
            Self.tool(.opencode, .entry(address: "http://localhost:8001/v1", keyFile: "~/.darkbloom/local_token")),
            Self.tool(.hermes, .entry(address: "http://127.0.0.1:8000/v1", keyFile: Self.keyFile.path)),
        ]
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                                   live: Self.endpoint(), answers: true, keyFile: Self.keyFile, tools: tools))
        let lines = doctor.diagnostics
        let openCode = try #require(find("OpenCode", in: lines))
        #expect(openCode.level == .pass)
        #expect(openCode.message == "points here (~/.config/opencode/opencode.jsonc)")
        let hermes = try #require(find("Hermes", in: lines))
        #expect(hermes.level == .warn)
        #expect(hermes.message == "points at http://127.0.0.1:8000/v1, not this Mac's local API (http://127.0.0.1:8001/v1) "
            + "(~/.hermes/config.yaml)")
        #expect(hermes.fix == "`\(Self.cli) --hermes`")

        let otherKey = section(.init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                                     live: Self.endpoint(), answers: true, keyFile: Self.keyFile,
                                     tools: [Self.tool(.opencode, .entry(address: "http://127.0.0.1:8001/v1",
                                                                         keyFile: "~/.darkbloom/cluster_local_token"))]))
        let stale = try #require(find("OpenCode", in: otherKey.diagnostics))
        #expect(stale.level == .warn)
        #expect(stale.message.hasPrefix("points here, but reads its key from ~/.darkbloom/cluster_local_token, not "
            + "~/.darkbloom/local_token"))
        #expect(stale.fix == "`\(Self.cli) --opencode`")
    }

    @Test func aToolConfigThatCantBeReadIsAWarning() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001),
                                   tools: [Self.tool(.opencode, .unreadable("it isn't valid JSON (line 3)"))]))
        let openCode = try #require(find("OpenCode", in: doctor.diagnostics))
        #expect(openCode.level == .warn)
        #expect(openCode.message == "can't read ~/.config/opencode/opencode.jsonc: it isn't valid JSON (line 3)")
    }

    /// A pairing record that can't be read may hide a pair that serves Darkbloom: even with `[local] mode = "local"`
    /// the network's checks run, and the mode line says how to check the pairing.
    @Test func aPairingRecordThatCantBeReadNeverSkipsTheNetworkChecks() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001),
                                   pair: ClusterPairSummary(paired: true, state: .pairingUnreadable)))
        #expect(!doctor.onlyMe)
        #expect(doctor.runsNetworkChecks(coordinatorOverride: nil))
        let lines = doctor.diagnostics
        let mode = try #require(find("mode", in: lines))
        #expect(mode.message == "this Mac's pairing record couldn't be read, so how it serves is unknown")
        #expect(mode.fix == "`\(Self.cli) cluster` on this Mac checks it")
        #expect(find("darkbloom network", in: lines) == nil)
    }

    @Test func aMacThatHasntChosenYetIsToldHow() throws {
        let doctor = section(.init(saved: nil))
        #expect(!doctor.onlyMe)
        let lines = doctor.diagnostics
        #expect(lines.count == 1)
        #expect(lines.first?.message.hasPrefix("not chosen yet: `\(Self.cli) start` asks how this Mac serves") == true)
    }

    @Test func theRunningProviderDecidesWhatServesNow() throws {
        // Saved Only me, but a provider started with --network serves now: the network checks apply.
        let network = section(.init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state()))
        #expect(network.mode == .network)
        #expect(!network.onlyMe)
        #expect(find("mode", in: network.diagnostics)?.message == "Darkbloom network — this Mac serves Darkbloom and earns "
            + "while it runs (serving now; your saved choice, Only me, serves at the next `\(Self.cli) start`)")
        // Nothing saved, the Only-me server runs (`start --local`).
        let onlyMe = section(.init(saved: nil, running: Self.state(connected: false), live: Self.endpoint(), answers: true,
                                   keyFile: Self.keyFile))
        #expect(onlyMe.onlyMe)
        #expect(find("mode", in: onlyMe.diagnostics)?.message
            == "Only me, on this Mac — Darkbloom never contacts this Mac (serving now)")
    }

    @Test func aPairSaysWhereItsAPIRuns() throws {
        var localOnly = ClusterPairSummary(paired: true)
        localOnly.role = .leader
        localOnly.localOnly = true
        localOnly.started = true
        let leader = section(.init(saved: LocalSettings(mode: .local), live: Self.endpoint(), answers: true,
                                   keyFile: Self.keyFile, pair: localOnly))
        #expect(leader.onlyMe)
        #expect(find("mode", in: leader.diagnostics)?.message
            == "Only me (this pair) — Darkbloom never contacts these Macs; the pair's API runs on this Mac")
        #expect(find("darkbloom network", in: leader.diagnostics)?.message.contains("`\(Self.cli) cluster` changes how "
            + "the pair serves") == true)

        var both = ClusterPairSummary(paired: true)
        both.role = .member
        both.otherMacName = "Apple M3 Ultra, 256 GB"
        both.started = true
        both.localAPI = ClusterPairLocalAPI(runsRankZero: false, listening: nil, meFirst: nil)
        let member = section(.init(saved: nil, pair: both, tools: Self.notSetUp))
        #expect(!member.onlyMe)
        let address = try #require(find("address", in: member.diagnostics))
        #expect(address.level == .info)
        #expect(address.message == "on the other Mac (Apple M3 Ultra, 256 GB), which runs the pair's API: "
            + "`\(Self.cli) local` there shows its address and key")
        #expect(find("key file", in: member.diagnostics) == nil)

        var stopped = both
        stopped.started = false
        let stoppedAddress = try #require(find("address", in: section(.init(saved: nil, pair: stopped)).diagnostics))
        #expect(stoppedAddress.level == .warn)
        #expect(stoppedAddress.fix == "`\(Self.cli) start` starts the pair")

        var network = ClusterPairSummary(paired: true)
        network.role = .leader
        let networkLines = section(.init(saved: nil, pair: network, tools: Self.notSetUp)).diagnostics
        #expect(find("mode", in: networkLines)?.message == "Darkbloom network (this pair) — no local API")
        #expect(find("address", in: networkLines) == nil && find("OpenCode", in: networkLines) == nil)
    }

    @Test func noLineEverHoldsTheKeyOrASpeed() {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                                   live: Self.endpoint(), answers: false, keyFile: nil,
                                   tools: [Self.tool(.opencode, .entry(address: "http://127.0.0.1:8009/v1", keyFile: nil))]))
        let text = doctor.diagnostics.map { "\($0.name) \($0.message) \($0.fix ?? "")" }.joined(separator: "\n")
        #expect(!text.contains(Self.secret) && !text.contains("dk-local-"))
        #expect(!text.contains("tok/s") && !text.lowercased().contains("tokens per second"))
    }

    /// A key written into a tool's own config (pasted by hand, or by another tool) is never read, so no line shows it:
    /// only the key file's path is kept.
    @Test func aKeyWrittenIntoAToolsConfigIsNeverShown() throws {
        let directory = try TemporaryDirectory("doctor-tool-keys")
        let home = directory.file("home")
        let provider = ToolIntegrationFixtures.provider
        _ = try directory.write("""
            { "providers": { "\(provider.id)": { "settings": { "baseURL": "http://127.0.0.1:8001/v1", \
            "apiKey": "\(Self.secret)" } } } }

            """, to: "home/.config/opencode/opencode.jsonc")
        _ = try directory.write("""
            providers:
              \(provider.id):
                api: http://127.0.0.1:8001/v1
                api_key: \(Self.secret)
                key_cmd: /bin/echo \(Self.secret)

            """, to: "home/.hermes/config.yaml")
        let tools = DoctorToolSetup.read(ToolIntegrationEnvironment(home: home, variables: [:]), provider: provider)
        #expect(tools.map(\.found) == [.entry(address: "http://127.0.0.1:8001/v1", keyFile: nil),
                                       .entry(address: "http://127.0.0.1:8001/v1", keyFile: nil)])
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                                   live: Self.endpoint(), answers: true, keyFile: Self.keyFile, tools: tools))
        let text = doctor.diagnostics.map { "\($0.name) \($0.message) \($0.fix ?? "")" }.joined(separator: "\n")
        #expect(text.contains("OpenCode points here") && text.contains("Hermes points here"))
        #expect(!text.contains(Self.secret) && !text.contains("dk-local-"))
    }

    /// `GET /health` goes to the address `local.json` names (on loopback for an any-address bind), and only a 200 means
    /// the API answers.
    @Test func theLocalAPIIsAskedAtItsOwnAddress() async {
        await #expect(processExitsWith: .success) {
            CoordinatorStub.install(["/health": .json(200, "{}")])
            for (host, port) in [("0.0.0.0", 8011), ("::", 8012), ("::1", 8013), ("192.168.1.5", 8014)] as [(String, UInt16)] {
                #expect(await DoctorLocalAPI.answers(DoctorLocalAPITests.endpoint(port: port, host: host)), "\(host)")
            }
            #expect(CoordinatorStub.requests.map { $0.url?.absoluteString } == [
                "http://127.0.0.1:8011/health", "http://127.0.0.1:8012/health", "http://[::1]:8013/health",
                "http://192.168.1.5:8014/health",
            ])
            CoordinatorStub.install(["/health": .json(503, "{}")])
            #expect(await !DoctorLocalAPI.answers(DoctorLocalAPITests.endpoint(port: 8011, host: "0.0.0.0")))
        }
    }

    /// Without the network's checks the operator diagnosis drops exactly the Darkbloom network's lines (attestation
    /// key, App Attest, attestation readiness, trust, coordinator traffic, billing) and keeps the rest as they are.
    @Test func theOperatorDiagnosisOnOnlyMeKeepsEverythingButTheNetwork() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.makeModel("acme/Warm-4bit")
            try sandbox.makeModel("acme/Cold-4bit")
            ModelScanner.configureCacheDirectory(sandbox.cache.path)
            CoordinatorStub.install([
                "/v1/releases/latest": .init(status: 200, body: CLICommandSandbox.releaseJSON(version: "99.0.0")),
            ])
            let now = Date().timeIntervalSince1970
            var state = try CLICommandSandbox.runningState(
                now: now,
                trust: .init(trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
                             receivedAt: now - 30,
                             authorization: ProviderAuthorizationStatus(
                                appAttestAvailable: true, path: "none", reason: "app_attest_keychain_error",
                                sessionID: "session", machineID: "")),
                currentModel: "acme/Warm-4bit", warmModels: ["acme/Warm-4bit"],
                advertisedModels: ["acme/Cold-4bit", "acme/Warm-4bit"],
                stats: .init(requestsServed: 3, tokensGenerated: 40, usageGaps: 1),
                capacity: .init(totalMemoryGb: 128, gpuMemoryActiveGb: 4, loadUsableGb: 100, loadHeadroomGb: 2,
                                freeForLoadGb: 90))
            state.coordinatorConnection = .init(connected: true, since: now - 1_200, connections: 1)
            sandbox.writeState(state)
            let snapshot = try sandbox.snapshot(hardware: CLICommandSandbox.hardware)

            let everything = await DoctorRunner.buildOperatorDiagnosis(
                snapshot: snapshot, coordinatorURL: CLICommandSandbox.coordinatorURL)
            let onlyMe = await DoctorRunner.buildOperatorDiagnosis(
                snapshot: snapshot, coordinatorURL: CLICommandSandbox.coordinatorURL, networkChecks: false)

            let networkSections: [DiagnosticSection] = [.attestationKey, .appAttest, .attestationReadiness, .trust, .billing]
            func isNetwork(_ line: Diagnostic) -> Bool {
                networkSections.contains(line.section) || line.name == "coordinator traffic"
            }
            for name in ["active se key", "coordinator traffic", "usage reporting"] {
                #expect(everything.contains { $0.name == name }, "\(name)")
            }
            #expect(everything.contains { $0.section == .trust })
            #expect(!onlyMe.contains(where: isNetwork))
            #expect(onlyMe == everything.filter { !isNetwork($0) })
            for name in ["serving concurrency", "model fits in RAM", "daemon connected"] {
                #expect(onlyMe.contains { $0.name == name }, "\(name)")
            }
            #expect(onlyMe.contains { $0.section == .version })
        }
    }

    @Test func theLocalAPISectionComesFirstInTheReport() {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001)))
        let report = DiagnosticReportRenderer.render(doctor.diagnostics + [
            Diagnostic(section: .runtime, name: "daemon", level: .pass, message: "up"),
        ])
        let localAPI = report.range(of: "LOCAL API")
        let runtime = report.range(of: DiagnosticSection.runtime.title)
        #expect(localAPI != nil && runtime != nil)
        if let localAPI, let runtime { #expect(localAPI.lowerBound < runtime.lowerBound) }
    }

    @Test func theToolsAreReadFromTheFilesStartWrites() throws {
        let directory = try TemporaryDirectory("doctor-tools")
        let home = directory.file("home")
        let keyFile = try directory.write(ToolIntegrationFixtures.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
        let environment = ToolIntegrationEnvironment(home: home, variables: [:])
        let provider = ToolIntegrationFixtures.provider
        #expect(DoctorToolSetup.read(environment, provider: provider).map(\.found) == [.noFile, .noFile])

        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)
        for tool in IntegrationTool.allCases {
            _ = try ToolIntegration.configure(tool, endpoint: endpoint, models: ToolIntegrationFixtures.models,
                                              provider: provider, environment: environment)
        }
        let read = DoctorToolSetup.read(environment, provider: provider)
        try #require(read.map(\.tool) == [.opencode, .hermes])
        #expect(read[0].found == .entry(address: "http://127.0.0.1:8123/v1", keyFile: "~/.darkbloom/local_token"))
        #expect(read[1].found == .entry(address: "http://127.0.0.1:8123/v1", keyFile: keyFile.path))
        #expect(DoctorToolSetup.expanded("~/.darkbloom/local_token", home: home) == keyFile.path)

        // Another provider's block isn't Darkbloom's; a file that isn't JSON says why.
        _ = try directory.write("{ \"providers\": { \"ollama\": { \"settings\": {} } } }\n",
                                to: "home/.config/opencode/opencode.jsonc")
        _ = try directory.write("model:\n\tdefault: x\n", to: "home/.hermes/config.yaml")
        let others = DoctorToolSetup.read(environment, provider: provider)
        try #require(others.count == 2)
        #expect(others[0].found == .noEntry)
        guard case .unreadable(let why) = others[1].found else {
            Issue.record("expected an unreadable Hermes config, got \(others[1].found)")
            return
        }
        #expect(why.contains("tabs"))
        _ = try directory.write("{ \"providers\": ", to: "home/.config/opencode/opencode.jsonc")
        #expect(DoctorToolSetup.read(environment, provider: provider).first?.found == .unreadable("it isn't valid JSON (line 1)"))
    }

    @Test func addressesOnThisMacCompareByPortAndPath() {
        #expect(DoctorToolSetup.sameAddress("http://localhost:8001/v1", "http://127.0.0.1:8001/v1"))
        #expect(DoctorToolSetup.sameAddress("http://127.0.0.1:8001/v1/", "http://127.0.0.1:8001/v1"))
        #expect(DoctorToolSetup.sameAddress("http://[::1]:8001/v1", "http://127.0.0.1:8001/v1"))
        #expect(!DoctorToolSetup.sameAddress("http://127.0.0.1:8000/v1", "http://127.0.0.1:8001/v1"))
        #expect(!DoctorToolSetup.sameAddress("http://studio.local:8001/v1", "http://127.0.0.1:8001/v1"))
    }

    /// The whole command on a Mac set to Only me: the Local API section first, and none of the network checks.
    @Test func doctorOnAMacSetToOnlyMeSkipsTheNetworkChecks() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let local = sandbox.root.appendingPathComponent("local", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", local.path, 1)
            var text = try String(contentsOf: sandbox.config, encoding: .utf8)
            text += "\n[local]\nmode = \"local\"\nport = 8011\n"
            try text.write(to: sandbox.config, atomically: true, encoding: .utf8)
            // The sandbox has no GPU, so `metal gpu` fails the run; the report is what this test reads.
            _ = try await runFailingCLICommand(Doctor.self, ["doctor", "--config", sandbox.config.path])
            #expect(!CoordinatorStub.requests.contains { $0.url?.path == "/v1/providers/attestation" })
            #expect(!CoordinatorStub.requests.contains { $0.url?.path == "/health" })
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("LOCAL API"))
        #expect(output.contains("mode — Only me, on this Mac — Darkbloom never contacts this Mac (saved)"))
        #expect(output.contains("darkbloom network — not needed (Only me)"))
        #expect(output.contains("address — http://127.0.0.1:8011/v1 — not running"))
        #expect(output.contains("darkbloom network: not needed (Only me)"))
        for networkCheck in ["account link:", "mdm enrollment:", "coordinator health:", "COORDINATOR TRUST", "active se key"] {
            #expect(!output.contains(networkCheck), "\(networkCheck)")
        }
    }
}

extension DoctorLocalAPI {
    /// The section as `doctor` prints it without `--coordinator`.
    var diagnostics: [Diagnostic] { lines(networkChecks: runsNetworkChecks(coordinatorOverride: nil)) }
}
