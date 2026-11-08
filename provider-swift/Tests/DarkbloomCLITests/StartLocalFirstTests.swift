import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// A terminal that answers from a script, then ends; it records what it was asked, what was printed, every look at
/// the Keychain and every port probed. Nothing here binds a port or opens the Keychain.
final class ScriptedTerminal: @unchecked Sendable {
    var answers: [String]
    var reads = 0
    var output = ""
    var keyLookups = 0
    var livePortLookups = 0
    var installedPortLookups = 0
    var probed: [UInt16] = []

    init(_ answers: [String] = []) { self.answers = answers }

    /// `ownLivePort` is this install's running local API's port, `installedPort` the one its installed LaunchAgent's
    /// job serves on.
    func environment(terminal: Bool, keySaved: Bool = false, busy: Set<UInt16> = [],
                     ownLivePort: UInt16? = nil, installedPort: UInt16? = nil) -> ServingEnvironment {
        ServingEnvironment(
            terminal: terminal,
            readInput: { self.reads += 1; return self.answers.isEmpty ? nil : self.answers.removeFirst() },
            emit: { self.output += $0 },
            accountKeySaved: { self.keyLookups += 1; return keySaved },
            ownLivePort: { self.livePortLookups += 1; return ownLivePort },
            installedPort: { self.installedPortLookups += 1; return installedPort },
            isFree: { self.probed.append($0); return !busy.contains($0) })
    }

    /// `Start.resolveServing` with this terminal, then `saveServingChoice`, as a start that goes ahead does.
    func resolve(_ start: Start, terminal: Bool, keySaved: Bool = false, busy: Set<UInt16> = [],
                 ownLivePort: UInt16? = nil, installedPort: UInt16? = nil) throws -> StartServing? {
        let serving = try start.resolveServing(environment: environment(terminal: terminal, keySaved: keySaved,
                                                                        busy: busy, ownLivePort: ownLivePort,
                                                                        installedPort: installedPort))
        if let serving { try start.saveServingChoice(serving) }
        return serving
    }
}

/// A `provider.toml` in its own temp folder; nil `toml` leaves the file absent.
struct TempConfig {
    let directory: URL
    let path: URL

    init(_ toml: String?) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("l4-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("provider.toml")
        if let toml { try toml.write(to: path, atomically: true, encoding: .utf8) }
    }

    var bytes: Data? { try? Data(contentsOf: path) }
    var local: LocalSettings? { (try? ConfigManager.load(from: path))?.local }
    func start(_ arguments: [String]) throws -> Start { try Start.parse(arguments + ["--config", path.path]) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private let plainConfig = """
    [provider]
    name = "l4-fixture"
    """

/// The build's default local port, and the first a new local API takes from it (8000 is never chosen).
private let defaultPort = BuildEnvironment.current.defaultLocalPort
private let firstNewPort: UInt16 = defaultPort == 8000 ? 8001 : defaultPort

/// The LaunchAgent's argv for these local API options.
private func launchAgentArguments(_ endpoint: LaunchAgent.LocalEndpointOptions) -> [String] {
    LaunchAgent.serviceProgramArguments(binaryPath: "/Applications/Darkbloom.app/Contents/MacOS/darkbloom",
                                        coordinatorURL: "wss://coordinator.invalid/ws/provider",
                                        models: ["fixture/model"], configPath: nil, localEndpoint: endpoint)
}

@Suite("Start: how this Mac serves (the start question, flags and [local])", .serialized)
struct StartLocalFirstTests {
    // MARK: - The question, rendered

    @Test("the question names the three choices in plain words, with Both, me first pre-selected")
    func questionText() {
        #expect(ServingQuestion.modeLines(idleMinutes: 2) == [
            "How should this Mac serve?",
            "  1. Only me, on this Mac      Darkbloom never contacts this Mac. Your tools use this Mac's own API.",
            "  2. Darkbloom network         This Mac serves Darkbloom and earns while it runs.",
            "  3. Both, me first            This Mac serves Darkbloom while you aren't using it. When you use it,",
            "                               Darkbloom traffic pauses until you've been idle for 2 minutes.",
        ])
        #expect(ServingQuestion.modeLines(idleMinutes: 1).last
            == "                               Darkbloom traffic pauses until you've been idle for 1 minute.")
        #expect(ServingQuestion.routeLines == [
            "When this Mac can't take one of your requests:",
            "  1. Only this Mac",
            "  2. Only my Macs (free)",
            "  3. My Macs first (the network answers when they can't; billed to your balance)",
        ])
        #expect(ServingQuestion.prompt(preselected: 3) == "Choose 1, 2 or 3 [3]: ")
    }

    @Test("an interactive first start asks, with Both, me first pre-selected; Enter takes it and saves it")
    func interactiveFirstStartAsks() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let terminal = ScriptedTerminal([""])
        let serving = try #require(try terminal.resolve(try config.start([]), terminal: true))
        let question = ServingQuestion.modeLines(idleMinutes: 2).map { $0 + "\n" }.joined()
        #expect(terminal.output.hasPrefix(question + "Choose 1, 2 or 3 [3]: "))
        #expect(serving.mode == .both && serving.source == .question && serving.meFirst)
        #expect(config.local?.mode == .both)
    }

    @Test("each answer is saved in [local], with a port for a new local API", arguments: [
        ("1", LocalSettings.Mode.local), ("2", .network), ("3", .both), ("", .both), (" 3 ", .both),
    ])
    func answerIsSaved(answer: String, mode: LocalSettings.Mode) throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let terminal = ScriptedTerminal([answer])
        let serving = try #require(try terminal.resolve(try config.start([]), terminal: true))
        #expect(serving.mode == mode && serving.source == .question)
        let saved = try #require(config.local)
        #expect(saved.mode == mode)
        #expect(saved.port == (mode == .network ? nil : firstNewPort))
        #expect(saved.route == nil && saved.meFirst == nil && saved.meFirstIdleMinutes == nil)
        #expect(serving.port == (mode == .network ? defaultPort : firstNewPort))
        // The rest of the file is kept.
        #expect(try ConfigManager.load(from: config.path).provider.name == "l4-fixture")
    }

    @Test("with an account key saved, the route follow-up asks once more and saves the answer")
    func routeFollowUpWithAKey() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let terminal = ScriptedTerminal(["3", "3"])
        let serving = try #require(try terminal.resolve(try config.start([]), terminal: true, keySaved: true))
        #expect(terminal.output.contains(ServingQuestion.routeLines.map { $0 + "\n" }.joined() + "Choose 1, 2 or 3 [2]: "))
        #expect(serving.route == .myMacsFirst && serving.accountKeySaved == true)
        #expect(config.local?.route == .myMacsFirst && config.local?.mode == .both)

        let onlyMe = try TempConfig(plainConfig)
        defer { onlyMe.remove() }
        let enter = ScriptedTerminal(["1", ""])
        #expect(try enter.resolve(try onlyMe.start([]), terminal: true, keySaved: true)?.route == .myMacs)
        #expect(onlyMe.local?.route == .myMacs && onlyMe.local?.mode == .local)
    }

    @Test("without an account key there is no follow-up, and nothing routes off this Mac")
    func noFollowUpWithoutAKey() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let terminal = ScriptedTerminal(["3"])
        let serving = try #require(try terminal.resolve(try config.start([]), terminal: true, keySaved: false))
        #expect(terminal.reads == 1 && terminal.keyLookups == 1)
        #expect(!terminal.output.contains("When this Mac can't take"))
        #expect(serving.route == nil && serving.accountKeySaved == false)
        #expect(config.local?.route == nil)
        // The network answer never looks at the Keychain.
        let network = ScriptedTerminal(["2"])
        _ = try network.resolve(try config.start(["--choose"]), terminal: true, keySaved: true)
        #expect(network.keyLookups == 0 && network.reads == 1)
    }

    @Test("--route with the question skips the follow-up and is saved")
    func routeFlagSkipsTheFollowUp() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let terminal = ScriptedTerminal(["3"])
        let serving = try #require(try terminal.resolve(try config.start(["--route", "this-mac"]), terminal: true,
                                                        keySaved: true))
        #expect(terminal.reads == 1 && serving.route == .thisMac)
        #expect(config.local == LocalSettings(mode: .both, route: .thisMac, port: firstNewPort))
    }

    @Test("the end of input, or three answers that aren't 1, 2 or 3, cancel with nothing saved")
    func cancelSavesNothing() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let before = config.bytes
        let ended = ScriptedTerminal([])
        #expect(try ended.resolve(try config.start([]), terminal: true) == nil)
        let wrong = ScriptedTerminal(["4", "both", "0"])
        #expect(try wrong.resolve(try config.start([]), terminal: true) == nil)
        #expect(wrong.output.components(separatedBy: "Please enter 1, 2 or 3.\n").count == 3)
        let followUpEnded = ScriptedTerminal(["3"])
        #expect(try followUpEnded.resolve(try config.start([]), terminal: true, keySaved: true) == nil)
        #expect(config.bytes == before)
        #expect(ServingQuestion.cancelled == "Cancelled: nothing was saved or started.")
    }

    @Test("the answer is saved only once the start goes ahead, and an answer the start refuses is never saved")
    func answerSavedOnlyWhenTheStartGoesAhead() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let before = config.bytes
        let terminal = ScriptedTerminal(["3"]).environment(terminal: true)
        let start = try config.start([])
        let serving = try #require(try start.resolveServing(environment: terminal))
        #expect(config.bytes == before)
        try start.saveServingChoice(serving)
        #expect(config.local == LocalSettings(mode: .both, port: firstNewPort))

        let fresh = try TempConfig(plainConfig)
        defer { fresh.remove() }
        for (arguments, refusal) in [
            (["--schedule"], "--schedule configures a background provider; \"Only me, on this Mac\" does not use "
                + "availability windows. Nothing was saved."),
            (["--autopilot"], "Autopilot requires a network provider. Nothing was saved."),
        ] {
            do {
                _ = try ScriptedTerminal(["1"]).resolve(try fresh.start(arguments), terminal: true)
                Issue.record("\(arguments) with Only me must be refused")
            } catch let error as ValidationError {
                #expect(error.message == refusal)
            }
        }
        #expect(fresh.local == nil)
    }

    // MARK: - Without a terminal: never asks; today's behaviour without a saved choice

    @Test("a non-TTY start without [local] is today's: no question, no listener, no Keychain, no port, nothing saved",
          arguments: [[String](), ["--model", "fixture/model"], ["--all", "--idle-timeout", "30"]])
    func nonTerminalStartKeepsToday(arguments: [String]) throws {
        for toml in [plainConfig, nil] {
            let config = try TempConfig(toml)
            defer { config.remove() }
            let before = config.bytes
            let terminal = ScriptedTerminal(["3"])
            let serving = try #require(try terminal.resolve(try config.start(arguments), terminal: false,
                                                            keySaved: true))
            #expect(serving.mode == .network && serving.source == .today)
            #expect(serving.change.isEmpty && serving.portNote == nil && serving.accountKeySaved == nil)
            #expect(terminal.reads == 0 && terminal.output.isEmpty)
            #expect(terminal.keyLookups == 0 && terminal.livePortLookups == 0 && terminal.probed.isEmpty)
            #expect(terminal.installedPortLookups == 0, "nor its LaunchAgent's port")
            #expect(config.bytes == before, "the config is left as it was (absent stays absent)")
            // The LaunchAgent's argv is today's, byte for byte, and the summary adds nothing.
            #expect(launchAgentArguments(serving.launchAgentEndpoint)
                == launchAgentArguments(LaunchAgent.LocalEndpointOptions()))
            #expect(serving.summaryLines.isEmpty)
            // The served process opens no local API: no listener and no key file, so no owner pause either.
            var tokenAsked = false
            let endpoint = try Start.unifiedLocalEndpoint(
                serving: serving, config: ProviderConfig(provider: ProviderSettings(name: "l4")),
                coordinatorURL: "wss://coordinator.invalid/ws/provider",
                loadToken: { tokenAsked = true; return "dk-local-fixture" })
            #expect(endpoint == nil && !tokenAsked)
            #expect(!LocalSettings().meFirstEnabled(in: serving.mode))
        }
    }

    @Test("a saved choice applies without a terminal too, and is never asked again")
    func savedChoiceApplies() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"both\"\nport = 8003\n")
        defer { config.remove() }
        let before = config.bytes
        for terminal in [true, false] {
            let script = ScriptedTerminal(["1"])
            let serving = try #require(try script.resolve(try config.start([]), terminal: terminal))
            #expect(serving.mode == .both && serving.source == .saved && serving.port == 8003 && serving.meFirst)
            #expect(script.reads == 0 && script.probed.isEmpty && serving.change.isEmpty)
            #expect(launchAgentArguments(serving.launchAgentEndpoint)
                == launchAgentArguments(.init(enabled: true, port: 8003, bind: "127.0.0.1", noAuth: false)))
        }
        #expect(config.bytes == before)
    }

    /// The desktop app's network Start is `start --model <id> --config <path>` (`DesktopBackend.arguments`), run
    /// without a terminal, and it waits for the command to end. "Only me" serves in the terminal that starts it, so
    /// without one it must not become a server that never returns, after stopping the running provider (review RV1).
    @Test("without a terminal, a saved Only me is refused in one line, before anything stops or starts")
    func nonTerminalSavedOnlyMeIsRefused() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"local\"\nport = 8001\n")
        defer { config.remove() }
        let before = config.bytes
        var action = DesktopAction(id: UUID().uuidString, action: "start")
        action.models = ["fixture/model"]
        let argv = try DesktopBackend.arguments(for: action, configPath: config.path.path, localActive: false)
        #expect(argv == ["start", "--model", "fixture/model", "--config", config.path.path], "the app names no mode")
        let script = ScriptedTerminal(["1"])
        do {
            _ = try script.resolve(try Start.parse(Array(argv.dropFirst())), terminal: false)
            Issue.record("a saved Only me without a terminal must be refused")
        } catch let error as ValidationError {
            #expect(error.message == "This Mac is set to Only me, which serves in a terminal. Run `darkbloom start` in "
                + "one, or name how to serve: --local, --network or --me-first.")
        }
        #expect(script.reads == 0 && script.keyLookups == 0 && script.livePortLookups == 0 && script.probed.isEmpty)
        #expect(config.bytes == before)
        // In a terminal the saved choice serves Only me, and without one a mode flag decides as before.
        #expect(try script.resolve(try config.start([]), terminal: true)?.mode == .local)
        #expect(try script.resolve(try config.start(["--network"]), terminal: false)?.mode == .network)
        #expect(try script.resolve(try config.start(["--local"]), terminal: false)?.mode == .local)
    }

    /// The LaunchAgent's `--foreground` child runs at every launch: its argv says how it serves.
    @Test("the --foreground service never saves, probes a port or asks the Keychain")
    func foregroundServiceTouchesNothing() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"network\"\nme_first = false\n")
        defer { config.remove() }
        let before = config.bytes
        for arguments in [["--foreground", "--local-endpoint", "--port", "8003"], ["--foreground", "--me-first"]] {
            let script = ScriptedTerminal(["1"])
            let serving = try #require(try script.resolve(try config.start(arguments), terminal: false, keySaved: true))
            #expect(serving.mode == .both && serving.change.isEmpty && serving.portNote == nil, "\(arguments)")
            #expect(serving.accountKeySaved == nil && script.keyLookups == 0, "\(arguments)")
            #expect(script.reads == 0 && script.livePortLookups == 0 && script.probed.isEmpty, "\(arguments)")
        }
        #expect(config.bytes == before)
    }

    @Test("an Only me start that runLocalStandalone refuses (no model it can serve) saves nothing")
    func refusedOnlyMeSavesNothing() async throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let before = config.bytes
        let start = try config.start([])
        let terminal = ScriptedTerminal(["1"]).environment(terminal: true)
        let serving = try #require(try start.resolveServing(environment: terminal))
        #expect(serving.mode == .local && serving.change.mode == .local)
        let snapshot = RuntimeSnapshot(configPath: config.path, configFileExists: true,
                                       config: ProviderConfig(provider: ProviderSettings(name: "l4-fixture")),
                                       hardware: nil, hardwareError: nil, models: [])
        await #expect(throws: ExitCode.self) {
            try await start.runLocalStandalone(
                snapshot: snapshot, config: snapshot.config, runtimeCapabilities: [],
                bootSecuritySnapshot: BootSecuritySnapshot(macOSMajorVersion: 26, sip: .enabled), serving: serving)
        }
        #expect(config.bytes == before, "a refused start saves nothing")
    }

    // MARK: - --choose

    @Test("--choose asks again, pre-selecting the saved choice, and saves the new answer")
    func chooseAsksAgain() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"network\"\n")
        defer { config.remove() }
        let keep = ScriptedTerminal([""])
        #expect(try keep.resolve(try config.start(["--choose"]), terminal: true)?.mode == .network)
        #expect(keep.output.contains("Choose 1, 2 or 3 [2]: "))
        let change = ScriptedTerminal(["3"])
        let serving = try #require(try change.resolve(try config.start(["--choose"]), terminal: true))
        #expect(serving.mode == .both && serving.source == .question)
        #expect(config.local == LocalSettings(mode: .both, port: firstNewPort))
    }

    @Test("--choose without a terminal is refused, and nothing is saved")
    func chooseNeedsATerminal() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        do {
            _ = try ScriptedTerminal(["3"]).resolve(try config.start(["--choose"]), terminal: false)
            Issue.record("--choose without a terminal must be refused")
        } catch let error as ValidationError {
            #expect(error.message == "`--choose` asks in a terminal. Without one, name how this Mac serves: --local, "
                + "--network or --me-first.")
        }
        #expect(config.local == nil)
    }

    // MARK: - Old flags keep their old meaning

    @Test("--local and --local-endpoint keep their modes and LaunchAgent argv and ask nothing; they save only this Mac's port")
    func oldFlagsKeepTheirModes() throws {
        for terminal in [false, true] {
            let config = try TempConfig(plainConfig)
            defer { config.remove() }
            let script = ScriptedTerminal(["1"])
            let local = try #require(try script.resolve(try config.start(["--local"]), terminal: terminal))
            #expect(local.mode == .local && local.source == .flag(.local) && local.port == firstNewPort)
            #expect(local.bind == "127.0.0.1" && local.accountKeySaved == nil)
            #expect(local.change == LocalSettingsChange(port: firstNewPort), "the port, chosen once, and no mode")
            #expect(local.portNote == LocalAPIPort.note(chosen: firstNewPort, start: defaultPort))

            let unified = try #require(try script.resolve(try config.start(["--local-endpoint"]), terminal: terminal))
            #expect(unified.mode == .both && unified.meFirst && unified.port == firstNewPort && unified.change.isEmpty)
            #expect(launchAgentArguments(unified.launchAgentEndpoint)
                == launchAgentArguments(.init(enabled: true, port: firstNewPort, bind: "127.0.0.1", noAuth: false)))
            #expect(script.reads == 0 && script.probed == [firstNewPort], "probed once, for the one choice")

            let custom = try #require(try script.resolve(
                try config.start(["--local-endpoint", "--port", "9001", "--bind", "0.0.0.0", "--no-auth"]),
                terminal: terminal))
            #expect(launchAgentArguments(custom.launchAgentEndpoint)
                == launchAgentArguments(.init(enabled: true, port: 9001, bind: "0.0.0.0", noAuth: true)))
            #expect(config.local == LocalSettings(port: 9001), "a named port is saved; a flag's mode never is")
        }
    }

    @Test("--local-endpoint --no-me-first is today's shared unified mode, and the choice is saved")
    func localEndpointWithoutMeFirst() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let serving = try #require(try ScriptedTerminal().resolve(
            try config.start(["--local-endpoint", "--no-me-first"]), terminal: false))
        #expect(serving.mode == .both && !serving.meFirst && serving.port == firstNewPort)
        #expect(launchAgentArguments(serving.launchAgentEndpoint)
            == launchAgentArguments(.init(enabled: true, port: firstNewPort, bind: "127.0.0.1", noAuth: false)))
        #expect(config.local == LocalSettings(meFirst: false, port: firstNewPort))
        // Me first again: --me-first undoes it, without saving a mode.
        let again = try #require(try ScriptedTerminal().resolve(try config.start(["--me-first"]), terminal: false))
        #expect(again.meFirst && again.change.meFirst == true && again.change.mode == nil)
        #expect(config.local == LocalSettings(meFirst: true, port: firstNewPort))
    }

    @Test("--local-endpoint --no-auth with a saved route keeps your requests on this Mac, and start, status and local say so")
    func noAuthKeepsRequestsOnThisMac() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nroute = \"my-macs-first\"\n")
        defer { config.remove() }
        let terminal = ScriptedTerminal()
        let serving = try #require(try terminal.resolve(try config.start(["--local-endpoint", "--no-auth"]),
                                                        terminal: false, keySaved: true))
        #expect(serving.mode == .both && serving.noAuth && serving.route == .myMacsFirst)
        #expect(terminal.keyLookups == 0, "without a local key the account key plays no part")
        // The local API gets no key, so its router keeps every request on this Mac, whatever the saved route
        // (`LocalRouterConfig.localKeyRequired`, set from the endpoint's key; LocalRouterTests covers the router).
        var served = ProviderConfig(provider: ProviderSettings(name: "l4"))
        served.local = config.local
        let endpoint = try #require(try Start.unifiedLocalEndpoint(
            serving: serving, config: served, coordinatorURL: "wss://coordinator.invalid/ws/provider",
            loadToken: { Issue.record("--no-auth reads no token"); return "dk-local-fixture" }))
        #expect(endpoint.authToken == nil && endpoint.router?.settings.route == .myMacsFirst)
        #expect(serving.summaryLines.suffix(2) == [
            "  Local:   http://127.0.0.1:\(firstNewPort)/v1 — your requests: this Mac only",
            "           (no API key: --no-auth, so requests stay on this Mac)",
        ])
        // status and local read the running provider: the same, and the Keychain isn't asked.
        let keyless = LocalFirstStatusFixtures.endpoint(apiKey: "")
        let state = LocalFirstStatusFixtures.state(meFirst: LocalFirstStatusFixtures.open)
        let noKeychain: () -> Bool = { Issue.record("Keychain read"); return true }
        #expect(Status.servingLines(state: state, liveEndpoint: keyless, route: .myMacsFirst, accountKeySaved: noKeychain,
                                    now: LocalFirstStatusFixtures.now) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
            "Your requests: this Mac only · no local key (--no-auth), so nothing is passed on",
        ])
        // `local` says "requests: this Mac only" under the API key line for a keyless server; it adds no second one.
        #expect(Local.servingLines(info: keyless, state: state, route: .myMacsFirst, accountKeySaved: noKeychain)
            == ["  serving:  Both, me first — Darkbloom pauses while you use this Mac, back after 2 idle minutes"])
    }

    @Test("the settings flags are saved as --idle-timeout is; a flag's mode is not")
    func settingsFlagsAreSaved() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let serving = try #require(try ScriptedTerminal().resolve(
            try config.start(["--local-endpoint", "--me-first-idle", "5", "--route", "my-macs-first"]),
            terminal: false, keySaved: true))
        #expect(serving.meFirstIdleMinutes == 5 && serving.route == .myMacsFirst && serving.accountKeySaved == true)
        #expect(config.local == LocalSettings(meFirstIdleMinutes: 5, route: .myMacsFirst, port: firstNewPort))
    }

    @Test("--me-first without a terminal serves Both on a new port it saves, and saves no mode")
    func meFirstFlagWithoutATerminal() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let script = ScriptedTerminal()
        let serving = try #require(try script.resolve(try config.start(["--me-first"]), terminal: false))
        #expect(serving.mode == .both && serving.source == .flag(.meFirst) && serving.meFirst)
        #expect(serving.port == firstNewPort && !script.probed.contains(8000))
        #expect(config.local == LocalSettings(port: firstNewPort))
        #expect(serving.portNote == LocalAPIPort.note(chosen: firstNewPort, start: defaultPort))
    }

    @Test("the serving process's me first follows the mode it serves, not a saved choice its flags overrode")
    func servedModeDecidesMeFirst() {
        let both = StartServing(mode: .both, source: .flag(.meFirst), meFirst: true, meFirstIdleMinutes: 5,
                                route: nil, accountKeySaved: nil, port: 8001, bind: "127.0.0.1", noAuth: false)
        var config = ProviderConfig(provider: ProviderSettings(name: "l4"))
        config.local = LocalSettings(mode: .network, meFirstIdleMinutes: 5)
        // L2 reads `[local] mode` first: a saved "network" would keep me first off beside --local-endpoint.
        #expect(config.local?.meFirstIdle(local: false, localEndpoint: true) == nil)
        let served = both.servedConfig(config)
        #expect(served.local == LocalSettings(mode: .both, meFirstIdleMinutes: 5))
        #expect(served.local?.meFirstIdle(local: false, localEndpoint: true) == .seconds(300))
        // A saved me_first = false still turns it off; no [local] and a matching mode stay as they are.
        config.local = LocalSettings(mode: .local, meFirst: false)
        #expect(both.servedConfig(config).local?.meFirstIdle(local: false, localEndpoint: true) == nil)
        config.local = nil
        #expect(both.servedConfig(config) == config)
        config.local = LocalSettings(mode: .both, port: 8001)
        #expect(both.servedConfig(config) == config)
    }

    // MARK: - Flag exclusivity

    @Test("--local with --me-first is refused, before anything runs")
    func localAndMeFirstRefused() {
        do {
            _ = try Start.parse(["--local", "--me-first"])
            Issue.record("--local --me-first must be refused")
        } catch {
            #expect(Start.message(for: error) == "`--local` and `--me-first` choose different ways to serve. Use one: "
                + "--local (only you, on this Mac), --network (the Darkbloom network) or --me-first (both, you first).")
        }
    }

    @Test("contradicting flags are refused at parse", arguments: [
        ["--network", "--me-first"], ["--local", "--network"], ["--network", "--local-endpoint"],
        ["--me-first", "--no-me-first"], ["--choose", "--network"], ["--choose", "--local-endpoint"],
        ["--no-me-first", "--local"], ["--me-first-idle", "5", "--network"], ["--me-first-idle", "5", "--no-me-first"],
        ["--me-first-idle", "0"], ["--me-first-idle", "121"], ["--network", "--port", "9000"],
        ["--network", "--route", "my-macs"], ["--network", "--no-auth"], ["--route", "everywhere"],
        ["--foreground", "--choose"], ["--foreground", "--route", "my-macs"], ["--foreground", "--no-me-first"],
        ["--cluster-member", "--network"], ["--cluster-member", "--route", "my-macs"],
    ])
    func contradictionsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try Start.parse(arguments) }
    }

    @Test("compatible flags parse", arguments: [
        ["--me-first", "--local-endpoint"], ["--local", "--local-endpoint"], ["--local-endpoint", "--no-me-first"],
        ["--me-first", "--me-first-idle", "120", "--route", "my-macs-first", "--port", "8123"], ["--choose"],
        ["--network"], ["--route", "this-mac"], ["--me-first-idle", "1"], ["--foreground", "--me-first"],
        ["--local", "--route", "my-macs", "--port", "8000"],
    ])
    func compatibleFlagsParse(arguments: [String]) throws {
        _ = try Start.parse(arguments)
    }

    @Test("refusals name the flags in plain words")
    func refusalWords() {
        #expect(refusal(["--me-first-idle", "0"])
            == "--me-first-idle must be a whole number of minutes from 1 to 120, not 0.")
        #expect(refusal(["--network", "--port", "9000"])
            == "`--network` serves no local API, so `--port` doesn't apply. Drop it, or choose --me-first or --local.")
        #expect(refusal(["--choose", "--network"])
            == "`--choose` asks how this Mac serves, so it can't be used with `--network`. Use one.")
        #expect(refusal(["--no-me-first", "--local"])
            == "`--no-me-first` applies when this Mac serves Darkbloom and you (--me-first); it doesn't apply with `--local`.")
        #expect(refusal(["--route", "everywhere"])?.contains(
            "--route must be this-mac (only this Mac), my-macs (your other Macs, free) or my-macs-first (then the "
                + "Darkbloom network, billed), not \"everywhere\".") == true)
    }

    // MARK: - On a paired Mac

    @Test("the new flags are single-Mac options, so a paired Mac needs --solo")
    func newFlagsAreSingleMacOptions() throws {
        #expect(try Start.parse(["--network"]).singleMacOptions == ["--network"])
        #expect(try Start.parse(["--me-first", "--me-first-idle", "5", "--route", "my-macs", "--port", "8000"])
            .singleMacOptions == ["--me-first", "--me-first-idle", "--route", "--port"])
        #expect(try Start.parse(["--local-endpoint", "--no-me-first"]).singleMacOptions
            == ["--local-endpoint", "--no-me-first"])
        #expect(try Start.parse(["--choose"]).singleMacOptions == ["--choose"])
        #expect(try Start.parse([]).singleMacOptions.isEmpty)
    }

    // MARK: - The port of a new local API

    @Test("a new local API never takes 8000 or 47420–47423, and never probes them")
    func portPickerSkipsReservedPorts() {
        // The owner's rule on every build: 8000 and production's pair ports, plus this build's own pair ports; under
        // production's identity exactly those five, as before.
        #expect(LocalAPIPort.neverChosen.isSuperset(of: [8000, 47_420, 47_421, 47_422, 47_423]))
        let cable = ClusterCablePorts.current
        #expect(LocalAPIPort.neverChosen.isSuperset(of: [cable.linkControl, cable.pairing, cable.exchange, cable.control]))
        #expect(BuildEnvironment.current != .prod || LocalAPIPort.neverChosen == [8000, 47_420, 47_421, 47_422, 47_423])
        #expect(ClusterLocalServing.pairPortsWords == "47420–47423")
        var probed: [UInt16] = []
        #expect(LocalAPIPort.pick(from: 8000, ownLivePort: nil, isFree: { probed.append($0); return true }) == 8001)
        #expect(probed == [8001])
        probed = []
        #expect(LocalAPIPort.pick(from: 47_419, ownLivePort: nil, isFree: { probed.append($0); return $0 != 47_419 })
            == 47_424)
        #expect(probed == [47_419, 47_424])
        #expect(LocalAPIPort.pick(from: 8000, ownLivePort: 8000, isFree: { _ in true }) == 8001,
                "not even this install's own")
    }

    @Test("a busy port is skipped, this install's own running API is kept, and none free is said plainly")
    func portPickerBusyAndOwn() throws {
        #expect(LocalAPIPort.pick(from: 8001, ownLivePort: nil, isFree: { ![8001, 8002].contains($0) }) == 8003)
        #expect(LocalAPIPort.pick(from: 8001, ownLivePort: 8001, isFree: { _ in false }) == 8001)
        #expect(LocalAPIPort.pick(from: 8001, ownLivePort: nil, isFree: { _ in false }) == nil)
        #expect(LocalAPIPort.pick(from: 65_530, ownLivePort: nil, isFree: { $0 == 65_535 }) == 65_535)
        #expect(LocalAPIPort.noneFree(from: 8001) == "No free port for this Mac's API from 8001 to 8021 (8000 and "
            + "47420–47423 are never chosen). Free one, or name one with --port <n>.")

        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        do {
            _ = try ScriptedTerminal(["3"]).resolve(try config.start([]), terminal: true,
                                                    busy: Set((defaultPort...defaultPort + 20).map { $0 }))
            Issue.record("no free port must refuse the start")
        } catch let error as ValidationError {
            #expect(error.message == LocalAPIPort.noneFree(from: defaultPort))
        }
        #expect(config.local == nil, "nothing is saved")
    }

    @Test("the question keeps a saved port, even 8000 or a busy one, and an explicit --port is honoured and saved")
    func questionKeepsTheSavedPort() throws {
        let cases: [(saved: UInt16, busy: Set<UInt16>)] = [(8000, []), (8005, [8005]), (8005, [])]
        for (saved, busy) in cases {
            let config = try TempConfig(plainConfig + "\n\n[local]\nport = \(saved)\n")
            defer { config.remove() }
            let before = config.bytes
            let script = ScriptedTerminal(["3"])
            let kept = try #require(try script.resolve(try config.start(["--choose"]), terminal: true, busy: busy))
            #expect(kept.port == saved && kept.portNote == nil && kept.change.port == nil, "\(saved)")
            #expect(script.probed.isEmpty && config.local == LocalSettings(mode: .both, port: saved), "\(saved)")
            #expect(config.bytes != before, "the answer is saved")
        }

        let explicit = try TempConfig(plainConfig)
        defer { explicit.remove() }
        let asked = try #require(try ScriptedTerminal(["3"]).resolve(try explicit.start(["--port", "8000"]),
                                                                    terminal: true))
        #expect(asked.port == 8000 && explicit.local?.port == 8000, "an explicit --port is honoured and saved")
        #expect(asked.portNote == "Local API port: 8000 (saved).")
        #expect(LocalAPIPort.note(chosen: 8002, start: 8002) == "Local API port: 8002 (saved).")
        #expect(LocalAPIPort.note(chosen: 8001, start: 8000) == "Local API port: 8001 (saved; 8000 is left for other apps).")
        #expect(LocalAPIPort.note(chosen: 8006, start: 8005) == "Local API port: 8006 (saved; 8005 is in use).")
    }

    // MARK: - The start's summary

    @Test("the summary says how this Mac serves, its address and where your requests go; never the key")
    func summaryLines() {
        func serving(_ mode: LocalSettings.Mode, meFirst: Bool = true, key: Bool? = false, route: LocalSettings.Route? = nil,
                     source: ServingModeSource = .question, noAuth: Bool = false) -> StartServing {
            StartServing(mode: mode, source: source, meFirst: meFirst, meFirstIdleMinutes: 2, route: route,
                         accountKeySaved: key, port: 8001, bind: "127.0.0.1", noAuth: noAuth)
        }
        #expect(serving(.both, key: true).summaryLines == [
            "  Serving: Both, me first — Darkbloom pauses while you use this Mac, back after 2 idle minutes",
            "  Local:   http://127.0.0.1:8001/v1 — your requests: this Mac first, then your other Macs (free)",
            "           (`darkbloom local` shows the key)",
        ])
        #expect(serving(.both, meFirst: false, key: false).summaryLines == [
            "  Serving: Both — Darkbloom keeps serving while you use this Mac (me first is off)",
            "  Local:   http://127.0.0.1:8001/v1 — your requests: this Mac only",
            "           (`darkbloom local` shows the key; `darkbloom route key` adds your other Macs)",
        ])
        #expect(serving(.both, key: true, route: .myMacsFirst).summaryLines.suffix(2) == [
            "  Local:   http://127.0.0.1:8001/v1 — your requests: this Mac first, then your other Macs (free), then the "
                + "Darkbloom network (billed)",
            "           (`darkbloom local` shows the key)",
        ])
        // Without a local key nothing is passed on, whatever the route and the account key.
        #expect(serving(.both, key: true, route: .myMacsFirst, noAuth: true).summaryLines.suffix(2) == [
            "  Local:   http://127.0.0.1:8001/v1 — your requests: this Mac only",
            "           (no API key: --no-auth, so requests stay on this Mac)",
        ])
        #expect(serving(.network, key: nil, source: .flag(.network)).summaryLines == [
            "  Serving: Darkbloom network — this Mac serves Darkbloom and earns while it runs",
        ])
        #expect(serving(.network, key: nil, source: .today).summaryLines.isEmpty)
        #expect(LocalFirstWords.serving(mode: .local, meFirst: false, idleMinutes: 2)
            == "Only me, on this Mac — Darkbloom never contacts this Mac")
        #expect(LocalFirstWords.serving(mode: .both, meFirst: true, idleMinutes: 1)
            == "Both, me first — Darkbloom pauses while you use this Mac, back after 1 idle minute")
    }

    /// In a log or a pipe (`start … > log 2>&1`) stdout is block-buffered, and a start that serves never exits, so
    /// its banner, "Listening on" and the tool lines would sit in the buffer. The start line-buffers it first.
    @Test("start line-buffers stdout first: in a log or a pipe, each line shows while start still runs")
    func startLineBuffersStandardOutput() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            setvbuf(stdout, nil, _IOFBF, 1 << 16)
            // Refused at once (two ways to serve), after the start's first step.
            var start = try Start.parse(["--foreground", "--local", "--local-endpoint"])
            do {
                try await start.run()
                exit(2)
            } catch {}
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0, dup2(ends[1], STDOUT_FILENO) == STDOUT_FILENO else { exit(3) }
            print("Listening on 127.0.0.1:8002")
            var log = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
            exit(poll(&log, 1, 2_000) == 1 ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        guard let result else { return }
        let refusal = String(decoding: result.standardErrorContent, as: UTF8.self)
        #expect(refusal.contains("--local and --local-endpoint are mutually exclusive"))
    }

    // MARK: - No speeds, anywhere

    @Test("no line of the question, the summary, status or local names a speed")
    func noSpeedAnywhere() throws {
        var lines = ServingQuestion.modeLines(idleMinutes: 1) + ServingQuestion.modeLines(idleMinutes: 120)
            + ServingQuestion.routeLines
            + [ServingQuestion.prompt(preselected: 3), ServingQuestion.retry, ServingQuestion.cancelled,
               LocalAPIPort.note(chosen: 8001, start: 8000), LocalAPIPort.note(chosen: 8003, start: 8001),
               LocalAPIPort.note(named: 8007, saved: nil), LocalAPIPort.note(named: 8007, saved: 8005),
               LocalAPIPort.note(kept: 8000), LocalAPIPort.noneFree(from: 8001),
               Start.localServerBindFailure(bind: "127.0.0.1", port: 8001, nextFree: 8002),
               Start.localServerBindFailure(bind: "127.0.0.1", port: 8001, nextFree: nil),
               Start.localServerBindFailure(bind: "127.0.0.1", port: 8001, nextFree: 8002, paired: true),
               Start.localServerBindFailure(bind: "127.0.0.1", port: 8001, nextFree: nil, paired: true)]
        for mode in LocalSettings.Mode.allCases {
            for meFirst in [true, false] {
                for key in [true, false] {
                    for route in [nil] + LocalSettings.Route.allCases {
                        lines += StartServing(mode: mode, source: .question, meFirst: meFirst, meFirstIdleMinutes: 2,
                                              route: route, accountKeySaved: key, port: 8001, bind: "0.0.0.0",
                                              noAuth: !key).summaryLines
                        lines.append(Status.requestsLine(route: route, accountKeySaved: key))
                    }
                }
            }
        }
        for arguments in [["--local", "--me-first"], ["--network", "--port", "1"], ["--choose", "--network"],
                          ["--no-me-first", "--network"], ["--me-first-idle", "0"], ["--foreground", "--route", "my-macs"]] {
            lines.append(refusal(arguments) ?? "")
        }
        lines += LocalFirstStatusFixtures.everyLine()
        let text = lines.joined(separator: "\n")
        for said in ["How should this Mac serve?", "When this Mac can't take", "  Serving: Both, me first",
                     "Serving: you first", "Your requests:", "  serving:  ", "Local API port: "] {
            #expect(text.contains(said), "the check covers \(said)")
        }
        #expect(!text.contains("tok/s"))
        #expect(!text.lowercased().contains("tokens per second"))
        #expect(text.range(of: #"[0-9][0-9.,]*\s*[A-Za-z]*/s\b"#, options: .regularExpression) == nil,
                "a number per second: \(text)")
    }
}

/// The refusal a set of flags gets, as the person sees it; nil when they parse.
private func refusal(_ arguments: [String]) -> String? {
    do {
        _ = try Start.parse(arguments)
        return nil
    } catch {
        return Start.message(for: error)
    }
}
