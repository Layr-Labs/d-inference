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

    /// Darkbloom's provider block sending requests to `baseURL`, its key read from `keyFile` (`~/` is `home`).
    static func entry(_ baseURL: String?, keyFile: String? = nil) -> DoctorToolSetup.Found {
        .entry(ToolPointer(baseURL: baseURL, keyFile: keyFile.map { path in
            path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
        }))
    }

    static let notSetUp = [tool(.opencode, .notSetUp), tool(.hermes, .notSetUp)]

    /// This Mac's pair as it knows it by itself; `role` nil before the pair has chosen how it serves.
    static func pair(role: ClusterPairSummary.Role?, localOnly: Bool = false, both: Bool = false,
                     started: Bool = false) -> ClusterPairSummary {
        var pair = ClusterPairSummary(paired: true)
        pair.role = role
        pair.otherMacName = "Apple M3 Ultra, 256 GB"
        pair.localOnly = localOnly
        pair.started = started
        if localOnly || both {
            pair.localAPI = ClusterPairLocalAPI(runsRankZero: role == .leader, listening: nil, meFirst: nil)
        }
        return pair
    }

    static func config(_ local: LocalSettings?) -> ProviderConfig {
        ProviderConfig(provider: ProviderSettings(name: "doctor-fixture"), local: local)
    }

    /// `live`'s reads, none of them this Mac's: `live` the only local API, no key file, single-Mac serving, not in a
    /// terminal, no service, no tools, this Mac named Studio, and an API that answers.
    static func stubbedReads(live: LocalEndpoint.Info? = nil) -> DoctorLocalAPI.Reads {
        var reads = DoctorLocalAPI.Reads()
        reads.liveInfo = { live }
        reads.keyFile = { _ in nil }
        reads.soloState = { $0 }
        reads.terminalOnlyMe = { _ in false }
        reads.serviceInstalled = { false }
        reads.tools = { [] }
        reads.localHostName = { "Studio" }
        reads.nextFreePort = { _ in nil }
        reads.answers = { _ in true }
        return reads
    }

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

    /// A stopped background service keeps its job: `restart` starts it again as saved, without `start`'s questions.
    @Test func aStoppedServiceStartsAgainAsSaved() throws {
        var facts = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .local, port: 8001))
        facts.serviceInstalled = true
        let address = try #require(find("address", in: section(facts).diagnostics))
        #expect(address.level == .warn)
        #expect(address.message == "http://127.0.0.1:8001/v1 — not running")
        #expect(address.fix == "`\(Self.cli) restart` starts it again as saved")
        // Before a start has chosen a port, `start` chooses one.
        var first = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .both))
        first.serviceInstalled = true
        let firstAddress = try #require(find("address", in: section(first).diagnostics))
        #expect(firstAddress.message == "not running; the first start chooses its port")
        #expect(firstAddress.fix == "`\(Self.cli) start`")
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

    /// The fixes of the two lines that start a running local API again (its port doesn't answer; no key file holds its
    /// key).
    private func startAgainFixes(_ facts: DoctorLocalAPI.Facts) -> [String?] {
        var unanswered = facts
        unanswered.answers = false
        var keyless = facts
        keyless.answers = true
        keyless.keyFile = nil
        return [find("address", in: section(unanswered).diagnostics)?.fix,
                find("key file", in: section(keyless).diagnostics)?.fix]
    }

    /// A local API starts again as it serves now, never another way: `restart` serves the saved choice, so it is the
    /// fix only while that is what runs, and never beside Only me in a terminal, which it doesn't stop.
    @Test func aLocalAPIStartsAgainAsItServesNow() {
        let cli = Self.cli
        let onlyMe = Self.state(connected: false)
        let meFirst = Self.state(meFirst: Self.meFirst)
        let shared = Self.state()
        func serving(_ state: DaemonState, saved: LocalSettings.Mode?, terminal: Bool = false, alone: Bool = false,
                     pair: ClusterPairSummary = .notPaired) -> DoctorLocalAPI.Facts {
            var facts = DoctorLocalAPI.Facts(saved: saved.map { LocalSettings(mode: $0, port: 8001) }, running: state,
                                             live: Self.endpoint(), keyFile: Self.keyFile, pair: pair)
            facts.terminalOnlyMe = terminal
            facts.servingAlone = alone
            return facts
        }
        func twice(_ fix: String) -> [String?] { [fix, fix] }

        // The background service serving the saved choice, or, with none saved, as installed.
        let restart = twice("`\(cli) restart`")
        #expect(startAgainFixes(serving(onlyMe, saved: .local)) == restart)
        #expect(startAgainFixes(serving(meFirst, saved: .both)) == restart)
        #expect(startAgainFixes(serving(onlyMe, saved: nil)) == restart)
        // Only me in a terminal saved no choice: `restart` would serve the saved one (here the Darkbloom network).
        let here = twice("press Ctrl-C in its window, then `\(cli) start --local --here`")
        #expect(startAgainFixes(serving(onlyMe, saved: .network, terminal: true)) == here)
        #expect(startAgainFixes(serving(onlyMe, saved: nil, terminal: true)) == here)
        // A service serving another way than the saved choice: `start` with the flag of the way it serves.
        #expect(startAgainFixes(serving(onlyMe, saved: .both)) == twice("`\(cli) start --local`"))
        #expect(startAgainFixes(serving(meFirst, saved: .local)) == twice("`\(cli) start --me-first`"))
        let sharedFix = twice("`\(cli) start --local-endpoint --no-me-first`")
        #expect(startAgainFixes(serving(shared, saved: .network)) == sharedFix)
        // A paired Mac serving alone says `--solo`; the pair's own API restarts with the pair.
        let networkPair = Self.pair(role: .leader)
        let soloHere = twice("press Ctrl-C in its window, then `\(cli) start --solo --local --here`")
        #expect(startAgainFixes(serving(onlyMe, saved: .local, terminal: true, alone: true, pair: networkPair)) == soloHere)
        let soloRestart = twice("`\(cli) restart --solo`")
        #expect(startAgainFixes(serving(meFirst, saved: .both, alone: true, pair: networkPair)) == soloRestart)
        let soloStart = twice("`\(cli) start --solo --me-first`")
        #expect(startAgainFixes(serving(meFirst, saved: .local, alone: true, pair: networkPair)) == soloStart)
        let bothPair = Self.pair(role: .leader, both: true, started: true)
        #expect(startAgainFixes(serving(meFirst, saved: .local, pair: bothPair)) == restart)
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

    /// A failed bind is named by the address that failed, with no port saved or another one.
    @Test func aFailedBindNamesTheAddressThatFailed() throws {
        let failure = DaemonState.LocalAPIFailure(host: "127.0.0.1", port: 8000, portInUse: true)
        for saved in [nil, LocalSettings(mode: .both, port: 8001)] {
            var facts = DoctorLocalAPI.Facts(saved: saved, running: Self.state(meFirst: Self.meFirst, failure: failure))
            facts.nextFreePort = { _ in 8002 }
            let address = try #require(find("address", in: section(facts).diagnostics))
            #expect(address.level == .fail)
            #expect(address.message == "http://127.0.0.1:8000/v1 isn't up")
            #expect(address.fix == "port 8000 is in use (`\(Self.cli) start --port 8002`)")
        }
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
                                   tools: [Self.tool(.opencode, Self.entry("http://127.0.0.1:8001/v1",
                                                                           keyFile: "~/.darkbloom/local_token")),
                                           Self.tool(.hermes, .notSetUp)]))
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
            Self.tool(.opencode, Self.entry("http://localhost:8001/v1", keyFile: "~/.darkbloom/local_token")),
            Self.tool(.hermes, Self.entry("http://127.0.0.1:8000/v1", keyFile: Self.keyFile.path)),
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
                                     tools: [Self.tool(.opencode, Self.entry("http://127.0.0.1:8001/v1",
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

    /// Darkbloom's provider block without an address sends nowhere: the tool's own command writes it again.
    @Test func aToolBlockWithoutAnAddressNamesTheToolsCommand() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001),
                                   tools: [Self.tool(.hermes, Self.entry(nil, keyFile: Self.keyFile.path))]))
        let hermes = try #require(find("Hermes", in: doctor.diagnostics))
        #expect(hermes.level == .warn)
        #expect(hermes.message == "Darkbloom's provider in ~/.hermes/config.yaml has no address")
        #expect(hermes.fix == "`\(Self.cli) --hermes`")
        // Without a local API there is nothing to point it at.
        let network = section(.init(saved: LocalSettings(mode: .network),
                                    tools: [Self.tool(.hermes, Self.entry(nil))]))
        #expect(find("Hermes", in: network.diagnostics) == nil)
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
        // Saved Only me, while a provider serving the Darkbloom network still runs (one started before the choice
        // changed): the network checks apply.
        let network = section(.init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state()))
        #expect(network.mode == .network)
        #expect(!network.onlyMe)
        #expect(find("mode", in: network.diagnostics)?.message == "Darkbloom network — this Mac serves Darkbloom and earns "
            + "while it runs (serving now; your saved choice, Only me, serves at the next `\(Self.cli) start`)")
        // Nothing saved, the Only-me server runs (`start --local --here`).
        let onlyMe = section(.init(saved: nil, running: Self.state(connected: false), live: Self.endpoint(), answers: true,
                                   keyFile: Self.keyFile))
        #expect(onlyMe.onlyMe)
        #expect(find("mode", in: onlyMe.diagnostics)?.message
            == "Only me, on this Mac — Darkbloom never contacts this Mac (serving now)")
    }

    /// Only me's server reports itself from its first load, long before its local API listens: it is Only me, starting,
    /// and the network's checks don't apply while it loads.
    @Test func onlyMeLoadingItsModelsIsOnlyMeStarting() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state(connected: false),
                                   keyFile: Self.keyFile, tools: Self.notSetUp))
        #expect(doctor.runningMode == .local)
        #expect(doctor.onlyMe)
        #expect(!doctor.runsNetworkChecks(coordinatorOverride: nil))
        let lines = doctor.diagnostics
        #expect(find("mode", in: lines)?.message == "Only me, on this Mac — Darkbloom never contacts this Mac (starting)")
        #expect(find("darkbloom network", in: lines) != nil)
        let address = try #require(find("address", in: lines))
        #expect(address.level == .info)
        #expect(address.message == "http://127.0.0.1:8001/v1 — starting: it opens once its models are loaded")
        #expect(address.fix == nil)
        #expect(find("key file", in: lines)?.level == .pass)
        // Another choice saved: Only me is what loads now.
        let savedNetwork = section(.init(saved: LocalSettings(mode: .network), running: Self.state(connected: false)))
        #expect(savedNetwork.onlyMe)
        let starting = "Only me, on this Mac — Darkbloom never contacts this Mac (starting; your saved choice, Darkbloom "
            + "network, serves at the next `\(Self.cli) start`)"
        #expect(find("mode", in: savedNetwork.diagnostics)?.message == starting)
        // A network provider waiting for its schedule's window writes a coordinator and no capabilities: the network.
        var waiting = Self.state(connected: false)
        waiting.coordinatorUrl = "wss://coordinator.example/ws/provider"
        let scheduled = section(.init(saved: LocalSettings(mode: .network), running: waiting))
        #expect(scheduled.runningMode == .network)
        #expect(!scheduled.onlyMe)
    }

    @Test func aPairSaysWhereItsAPIRuns() throws {
        let leader = section(.init(saved: LocalSettings(mode: .local), live: Self.endpoint(), answers: true,
                                   keyFile: Self.keyFile, pair: Self.pair(role: .leader, localOnly: true, started: true)))
        #expect(leader.onlyMe)
        #expect(find("mode", in: leader.diagnostics)?.message
            == "Only me (this pair) — Darkbloom never contacts these Macs; the pair's API runs on this Mac")
        #expect(find("darkbloom network", in: leader.diagnostics)?.message.contains("`\(Self.cli) cluster` changes how "
            + "the pair serves") == true)

        let both = Self.pair(role: .member, both: true, started: true)
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

        let networkLines = section(.init(saved: nil, pair: Self.pair(role: .leader), tools: Self.notSetUp)).diagnostics
        #expect(find("mode", in: networkLines)?.message == "Darkbloom network (this pair) — no local API")
        #expect(find("address", in: networkLines) == nil && find("OpenCode", in: networkLines) == nil)
    }

    /// A pair that hasn't chosen how it serves (no leadership record yet) is neither the network nor Only me.
    @Test func aPairThatHasntChosenHowToServeSaysSo() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .local, port: 8001), pair: Self.pair(role: nil)))
        #expect(!doctor.onlyMe)
        let mode = try #require(find("mode", in: doctor.diagnostics))
        #expect(mode.message == "this Mac is paired, but how the pair serves isn't chosen yet")
        #expect(mode.fix == "`\(Self.cli) cluster` sets it up")
    }

    /// On a pair serving the Darkbloom network, a tool still pointing at a local API is told how the pair changes.
    @Test func aToolLeftPointingHereOnANetworkPairNamesCluster() throws {
        let doctor = section(.init(saved: nil, pair: Self.pair(role: .leader, started: true),
                                   tools: [Self.tool(.opencode, Self.entry("http://127.0.0.1:8001/v1"))]))
        let openCode = try #require(find("OpenCode", in: doctor.diagnostics))
        #expect(openCode.level == .warn)
        #expect(openCode.message == "points at http://127.0.0.1:8001/v1, but this Mac serves no local API "
            + "(~/.config/opencode/opencode.jsonc)")
        #expect(openCode.fix == "`\(Self.cli) cluster` changes how the pair serves")
    }

    /// A paired Mac serving alone (`start --solo`) is described by what serves, not by its pair: the way, the network's
    /// checks, its address, and commands with `--solo`.
    @Test func aPairedMacServingAloneIsDescribedByWhatServes() throws {
        let cli = Self.cli
        func alone(_ facts: DoctorLocalAPI.Facts) -> DoctorLocalAPI {
            var facts = facts
            facts.servingAlone = true
            return section(facts)
        }
        // Only me alone, its pair set to the Darkbloom network: the network's checks don't apply.
        let onlyMe = alone(.init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state(connected: false),
                                 live: Self.endpoint(), answers: true, keyFile: Self.keyFile,
                                 pair: Self.pair(role: .leader)))
        #expect(onlyMe.onlyMe)
        #expect(!onlyMe.runsNetworkChecks(coordinatorOverride: nil))
        let lines = onlyMe.diagnostics
        #expect(find("mode", in: lines)?.message
            == "Only me, on this Mac — Darkbloom never contacts this Mac (this Mac serves alone, not the pair)")
        let change = "`\(cli) start --solo --choose` changes how this Mac serves alone"
        #expect(find("darkbloom network", in: lines)?.message.hasSuffix(change) == true)
        #expect(find("address", in: lines)?.message == "http://127.0.0.1:8001/v1 — up on port 8001")
        // Only me alone, still loading.
        let loading = alone(.init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state(connected: false),
                                  pair: Self.pair(role: .leader)))
        #expect(find("mode", in: loading.diagnostics)?.message
            == "Only me, on this Mac — Darkbloom never contacts this Mac (starting; this Mac serves alone, not the pair)")

        // The Darkbloom network alone, its pair set to Only me: the network's checks run.
        let network = alone(.init(saved: LocalSettings(mode: .network), running: Self.state(),
                                  pair: Self.pair(role: .leader, localOnly: true, started: true)))
        #expect(!network.onlyMe)
        #expect(network.runsNetworkChecks(coordinatorOverride: nil))
        let networkLines = network.diagnostics
        let networkMode = "Darkbloom network — this Mac serves Darkbloom and earns while it runs (this Mac serves alone, "
            + "not the pair)"
        #expect(find("mode", in: networkLines)?.message == networkMode)
        #expect(find("darkbloom network", in: networkLines) == nil && find("address", in: networkLines) == nil)

        // Both alone, its local API's port in use, whichever way its pair is set: the failure, and `--solo`.
        let failed = Self.state(meFirst: Self.meFirst, failure: .init(host: "127.0.0.1", port: 8001, portInUse: true))
        for paired in [Self.pair(role: .leader), Self.pair(role: .leader, both: true)] {
            var facts = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .both, port: 8001), running: failed, pair: paired)
            facts.nextFreePort = { $0 == 8001 ? 8002 : nil }
            let both = alone(facts)
            #expect(both.mode == .both)
            let address = try #require(find("address", in: both.diagnostics))
            #expect(address.level == .fail)
            #expect(address.message == "http://127.0.0.1:8001/v1 isn't up")
            #expect(address.fix == "port 8001 is in use (`\(cli) start --solo --port 8002`)")
        }
    }

    /// While the pair serves, its way decides whether the network's checks apply, not this Mac's own saved choice.
    @Test func whileThePairServesItsWayDecidesOnlyMe() {
        let localPair = section(.init(saved: LocalSettings(mode: .network), live: Self.endpoint(), answers: true,
                                      pair: Self.pair(role: .leader, localOnly: true, started: true)))
        #expect(localPair.onlyMe)
        #expect(!localPair.runsNetworkChecks(coordinatorOverride: nil))
        let networkPair = section(.init(saved: LocalSettings(mode: .local, port: 8001),
                                        pair: Self.pair(role: .leader, started: true)))
        #expect(!networkPair.onlyMe)
        #expect(networkPair.runsNetworkChecks(coordinatorOverride: nil))
    }

    /// A paired Mac's saved port is single-Mac serving's, not the pair's API's: tools aren't judged by it.
    @Test func aPairedMacsSavedPortIsNotThePairsAddress() throws {
        let doctor = section(.init(saved: LocalSettings(mode: .both, port: 8001),
                                   pair: Self.pair(role: .leader, both: true, started: true),
                                   tools: [Self.tool(.opencode, Self.entry("http://127.0.0.1:8001/v1",
                                                                           keyFile: "~/.darkbloom/local_token"))]))
        #expect(doctor.address == nil)
        let lines = doctor.diagnostics
        #expect(find("address", in: lines)?.message == "not listening yet: it starts with this Mac's part of the pair")
        let openCode = try #require(find("OpenCode", in: lines))
        #expect(openCode.level == .info)
        #expect(openCode.message == "points at http://127.0.0.1:8001/v1 (~/.config/opencode/opencode.jsonc)")
    }

    @Test func noLineEverHoldsTheKeyOrASpeed() {
        var terminal = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .network), running: Self.state(connected: false),
                                            live: Self.endpoint(), answers: false, keyFile: nil)
        terminal.terminalOnlyMe = true
        let failed = Self.state(meFirst: Self.meFirst, failure: .init(host: "127.0.0.1", port: 8001, portInUse: true))
        var alone = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .both, port: 8001), running: failed,
                                         pair: Self.pair(role: .leader))
        alone.servingAlone = true
        let states: [DoctorLocalAPI.Facts] = [
            .init(saved: LocalSettings(mode: .both, port: 8001), running: Self.state(meFirst: Self.meFirst),
                  live: Self.endpoint(), answers: false, keyFile: nil,
                  tools: [Self.tool(.opencode, Self.entry("http://127.0.0.1:8009/v1"))]),
            .init(saved: LocalSettings(mode: .local, port: 8001), running: Self.state(connected: false), keyFile: Self.keyFile),
            .init(saved: nil, live: Self.endpoint(), answers: true, keyFile: Self.keyFile,
                  pair: Self.pair(role: .leader, localOnly: true, started: true)),
            terminal, alone,
        ]
        for facts in states {
            let text = section(facts).diagnostics.map { "\($0.name) \($0.message) \($0.fix ?? "")" }.joined(separator: "\n")
            #expect(!text.contains(Self.secret) && !text.contains("dk-local-"))
            #expect(!text.contains("tok/s") && !text.lowercased().contains("tokens per second"))
        }
    }

    /// A key written into a tool's own config (pasted by hand, or by another tool) is never read, so no line shows it:
    /// only the file a key is read from is kept.
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
        let withoutKeyFile = DoctorToolSetup.Found.entry(ToolPointer(baseURL: "http://127.0.0.1:8001/v1", keyFile: nil))
        #expect(tools.map(\.found) == [withoutKeyFile, withoutKeyFile])
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

    /// The tools are read as `start` reads them (`ToolAddress.readPointer`): the files `--opencode` / `--hermes` write,
    /// and why a file that is there can't be read.
    @Test func theToolsAreReadFromTheFilesStartWrites() throws {
        let directory = try TemporaryDirectory("doctor-tools")
        let home = directory.file("home")
        let keyFile = try directory.write(ToolIntegrationFixtures.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
        let environment = ToolIntegrationEnvironment(home: home, variables: [:])
        let provider = ToolIntegrationFixtures.provider
        #expect(DoctorToolSetup.read(environment, provider: provider).map(\.found) == [.notSetUp, .notSetUp])

        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)
        for tool in IntegrationTool.allCases {
            _ = try ToolIntegration.configure(tool, endpoint: endpoint, models: ToolIntegrationFixtures.models,
                                              provider: provider, environment: environment)
        }
        let read = DoctorToolSetup.read(environment, provider: provider)
        try #require(read.map(\.tool) == [.opencode, .hermes])
        for setup in read {
            guard case .entry(let pointer) = setup.found else {
                Issue.record("expected Darkbloom's provider in \(setup.tool), got \(setup.found)")
                continue
            }
            #expect(pointer.baseURL == "http://127.0.0.1:8123/v1")
            #expect(pointer.keyFile?.standardizedFileURL.path == keyFile.standardizedFileURL.path)
        }

        // Another provider's block isn't Darkbloom's; a file that can't be read says why.
        _ = try directory.write("{ \"providers\": { \"ollama\": { \"settings\": {} } } }\n",
                                to: "home/.config/opencode/opencode.jsonc")
        _ = try directory.write("model:\n\tdefault: x\n", to: "home/.hermes/config.yaml")
        let others = DoctorToolSetup.read(environment, provider: provider)
        try #require(others.count == 2)
        #expect(others[0].found == .notSetUp)
        guard case .unreadable(let why) = others[1].found else {
            Issue.record("expected an unreadable Hermes config, got \(others[1].found)")
            return
        }
        #expect(why.contains("tabs"))
        _ = try directory.write("{ \"providers\": ", to: "home/.config/opencode/opencode.jsonc")
        let malformed = DoctorToolSetup.read(environment, provider: provider).first?.found
        #expect(malformed == .unreadable("it isn't valid JSON (line 1)"))
        // Larger than any tool config: refused unread, as `start` refuses it.
        let large = "{}" + String(repeating: " ", count: ToolConfigWriter.maximumFileBytes)
        _ = try directory.write(large, to: "home/.config/opencode/opencode.jsonc")
        let tooLarge = DoctorToolSetup.read(environment, provider: provider).first?.found
        #expect(tooLarge == .unreadable("it is larger than 4 MiB"))
    }

    /// `start`'s notice (`ToolAddress`) and `doctor` judge a tool's config one way: `localhost` is this Mac, another
    /// file holding the same key is the same key, and a `key_cmd` without a full path names no key file. Neither finds
    /// anything wrong here, and no line holds the key.
    @Test func startAndDoctorJudgeAToolAlike() throws {
        let directory = try TemporaryDirectory("doctor-tools-alike")
        let home = directory.file("home")
        let key = ToolIntegrationFixtures.freshToken()
        let keyFile = try directory.write(key, to: "home/.darkbloom/local_token", mode: 0o600)
        _ = try directory.write(key, to: "home/.darkbloom/other_token", mode: 0o600)
        let provider = ToolIntegrationFixtures.provider
        _ = try directory.write("""
            { "providers": { "\(provider.id)": { "settings": { "baseURL": "http://localhost:8001/v1", \
            "apiKey": "{file:~/.darkbloom/other_token}" } } } }

            """, to: "home/.config/opencode/opencode.jsonc")
        _ = try directory.write("""
            providers:
              \(provider.id):
                api: http://127.0.0.1:8001/v1
                key_cmd: /bin/cat local_token

            """, to: "home/.hermes/config.yaml")
        let environment = ToolIntegrationEnvironment(home: home, variables: [:])
        var facts = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .both, port: 8001),
                                         running: Self.state(meFirst: Self.meFirst), live: Self.endpoint(), answers: true,
                                         keyFile: keyFile, tools: DoctorToolSetup.read(environment, provider: provider))
        facts.home = home
        let lines = DoctorLocalAPI(facts: facts).diagnostics
        #expect(find("OpenCode", in: lines)?.message == "points here (~/.config/opencode/opencode.jsonc)")
        #expect(find("Hermes", in: lines)?.message == "points here (~/.hermes/config.yaml)")
        let misses = ToolAddress.misses(baseURL: Self.endpoint().baseURL, keyFile: keyFile, environment: environment,
                                        provider: provider)
        #expect(misses.isEmpty)
        let text = lines.map { "\($0.message) \($0.fix ?? "")" }.joined(separator: "\n")
        #expect(!text.contains(key))
    }

    /// An API listening on every address answers to this Mac's `.local` name too, as `start` counts it.
    @Test func thisMacsLocalNameIsHereForAnAPIOnEveryAddress() {
        var facts = DoctorLocalAPI.Facts(saved: LocalSettings(mode: .both, port: 8001, bind: "0.0.0.0"),
                                         running: Self.state(meFirst: Self.meFirst), live: Self.endpoint(host: "0.0.0.0"),
                                         answers: true, keyFile: Self.keyFile,
                                         tools: [Self.tool(.opencode, Self.entry("http://Studio.local:8001/v1"))])
        facts.thisMac = ToolAddress.thisMacsNames(listeningOn: "0.0.0.0", localHostName: { "Studio" })
        #expect(find("OpenCode", in: section(facts).diagnostics)?.message
            == "points here (~/.config/opencode/opencode.jsonc)")
    }

    /// The key file is the running API's (on its port), else the saved port's.
    @Test func liveTakesTheRunningAPIsKeyFileFirst() async {
        let config = Self.config(LocalSettings(mode: .both, port: 8001))
        var asked: [Int] = []
        var reads = Self.stubbedReads(live: Self.endpoint(port: 8002))
        reads.keyFile = { port in
            asked.append(port)
            return URL(fileURLWithPath: "/keys/\(port)")
        }
        let running = await DoctorLocalAPI.live(config: config, daemonState: Self.state(meFirst: Self.meFirst),
                                                daemonRunning: true, pair: .notPaired, reads: reads)
        #expect(running.facts.keyFile?.path == "/keys/8002")
        #expect(running.facts.answers == true)
        reads.liveInfo = { nil }
        let stopped = await DoctorLocalAPI.live(config: config, daemonState: nil, daemonRunning: false,
                                                pair: .notPaired, reads: reads)
        #expect(stopped.facts.keyFile?.path == "/keys/8001")
        #expect(stopped.facts.answers == nil)
        #expect(asked == [8002, 8001])
    }

    /// `live` tells single-Mac serving on a paired Mac from the pair's part, and Only me in a terminal from its
    /// background service; it says whether the service is installed, and which names this Mac's API answers to.
    @Test func liveTellsWhatServesHere() async {
        let config = Self.config(LocalSettings(mode: .local, port: 8001))
        let onlyMe = Self.state(connected: false)
        var reads = Self.stubbedReads()
        reads.terminalOnlyMe = { _ in true }
        // Single-Mac serving (`start --solo`) on a paired Mac: it serves alone, here Only me in its terminal.
        let alone = await DoctorLocalAPI.live(config: config, daemonState: onlyMe, daemonRunning: true,
                                              pair: Self.pair(role: .leader), reads: reads)
        #expect(alone.facts.servingAlone)
        #expect(alone.facts.terminalOnlyMe)
        // The pair's part wrote the state: the pair serves.
        reads.soloState = { _ in nil }
        let part = await DoctorLocalAPI.live(config: config, daemonState: onlyMe, daemonRunning: true,
                                             pair: Self.pair(role: .leader), reads: reads)
        #expect(!part.facts.servingAlone)
        #expect(!part.facts.terminalOnlyMe)
        // A single Mac never serves "alone"; nothing running, or the network, is never Only me in a terminal.
        reads.soloState = { $0 }
        let single = await DoctorLocalAPI.live(config: config, daemonState: onlyMe, daemonRunning: true,
                                               pair: .notPaired, reads: reads)
        #expect(!single.facts.servingAlone)
        #expect(single.facts.terminalOnlyMe)
        let stopped = await DoctorLocalAPI.live(config: config, daemonState: onlyMe, daemonRunning: false,
                                                pair: .notPaired, reads: reads)
        #expect(!stopped.facts.terminalOnlyMe)
        let network = await DoctorLocalAPI.live(config: config, daemonState: Self.state(), daemonRunning: true,
                                                pair: .notPaired, reads: reads)
        #expect(!network.facts.terminalOnlyMe)
        #expect(!network.facts.serviceInstalled)
        #expect(network.facts.thisMac == ToolAddress.loopbackNames)
        // The service installed, and an API on every address, which answers to this Mac's `.local` name too.
        reads.serviceInstalled = { true }
        reads.liveInfo = { Self.endpoint(host: "0.0.0.0") }
        let everywhere = await DoctorLocalAPI.live(config: config, daemonState: onlyMe, daemonRunning: true,
                                                   pair: .notPaired, reads: reads)
        #expect(everywhere.facts.serviceInstalled)
        #expect(everywhere.facts.thisMac == ToolAddress.loopbackNames.union(["studio.local"]))
        let saved = await DoctorLocalAPI.live(config: Self.config(LocalSettings(mode: .local, port: 8001, bind: "0.0.0.0")),
                                              daemonState: nil, daemonRunning: false, pair: .notPaired,
                                              reads: Self.stubbedReads())
        #expect(saved.facts.thisMac.contains("studio.local"))
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

    /// `--coordinator <url>` names a coordinator to check: on a Mac set to Only me too, the network's checks run.
    @Test func doctorWithACoordinatorRunsTheNetworkChecksOnOnlyMe() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let local = sandbox.root.appendingPathComponent("local", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", local.path, 1)
            var text = try String(contentsOf: sandbox.config, encoding: .utf8)
            text += "\n[local]\nmode = \"local\"\nport = 8011\n"
            try text.write(to: sandbox.config, atomically: true, encoding: .utf8)
            CoordinatorStub.install(["/health": .json(503, "unavailable")])
            _ = try await runFailingCLICommand(Doctor.self, ["doctor", "--config", sandbox.config.path,
                                                             "--coordinator", CLICommandSandbox.coordinatorURL])
            let health = CoordinatorStub.requests.filter { $0.url?.path == "/health" }
            #expect(!health.isEmpty)
            #expect(health.allSatisfy { $0.url?.host == "coordinator.invalid" })
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("mode — Only me, on this Mac — Darkbloom never contacts this Mac (saved)"))
        #expect(output.contains("account link:"))
        #expect(output.contains("coordinator health: https://coordinator.invalid"))
        #expect(!output.contains("not needed (Only me)"))
    }
}

extension DoctorLocalAPI {
    /// The section as `doctor` prints it without `--coordinator`.
    var diagnostics: [Diagnostic] { lines(networkChecks: runsNetworkChecks(coordinatorOverride: nil)) }
}
