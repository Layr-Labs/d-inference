import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// Stands in for this Mac's Keychain and ports while a start decides how it serves, and records every look at the
/// Keychain and every port probed. Nothing here binds a port or opens the Keychain. (No start asks how it serves: the
/// name is from when it also answered that question.)
final class ScriptedTerminal: @unchecked Sendable {
    var keyLookups = 0
    var livePortLookups = 0
    var installedPortLookups = 0
    var probed: [UInt16] = []

    /// `ownLivePort` is this install's running local API's port, `installedPort` the one its installed LaunchAgent's
    /// job serves on.
    func environment(keySaved: Bool = false, busy: Set<UInt16> = [], ownLivePort: UInt16? = nil,
                     installedPort: UInt16? = nil) -> ServingEnvironment {
        ServingEnvironment(
            accountKeySaved: { self.keyLookups += 1; return keySaved },
            ownLivePort: { self.livePortLookups += 1; return ownLivePort },
            installedPort: { self.installedPortLookups += 1; return installedPort },
            isFree: { self.probed.append($0); return !busy.contains($0) })
    }

    /// `Start.resolveServing` with this stand-in, then `saveServingChoice`, as a start that goes ahead does.
    func resolve(_ start: Start, keySaved: Bool = false, busy: Set<UInt16> = [], ownLivePort: UInt16? = nil,
                 installedPort: UInt16? = nil) throws -> StartServing {
        let serving = try start.resolveServing(environment: environment(keySaved: keySaved, busy: busy,
                                                                        ownLivePort: ownLivePort,
                                                                        installedPort: installedPort))
        try start.saveServingChoice(serving)
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
    // MARK: - No question: Both, Darkbloom never paused, unless a flag or a saved choice says otherwise

    /// The owner's default (2026-11-11): a start that no mode flag and no saved choice decide serves Darkbloom and this
    /// Mac's local API, and Darkbloom keeps serving while the owner uses it (`me_first = false`). Nothing is asked, in a
    /// terminal or not, and the default is saved as this Mac's choice, so restart, update and later builds keep it.
    @Test("a first start asks nothing and serves Both with Darkbloom never paused; the choice is saved")
    func firstStartServesBothNeverPaused() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let script = ScriptedTerminal()
        let serving = try script.resolve(try config.start([]))
        #expect(serving.mode == .both && serving.source == .default && !serving.meFirst)
        #expect(serving.port == firstNewPort && serving.hasLocalAPI && script.probed == [firstNewPort])
        #expect(config.local == LocalSettings(mode: .both, meFirst: false, port: firstNewPort))
        #expect(serving.change == LocalSettingsChange(mode: .both, port: firstNewPort, meFirst: false))
        #expect(launchAgentArguments(serving.launchAgentEndpoint)
            == launchAgentArguments(.init(enabled: true, port: firstNewPort, bind: "127.0.0.1", noAuth: false)))
        #expect(serving.defaultLine == "Serving Darkbloom and your local API at http://127.0.0.1:\(firstNewPort)/v1 "
            + "(`darkbloom local` for local only).")
        #expect(serving.summaryLines.first
            == "  Serving: Both — Darkbloom keeps serving while you use this Mac (me first is off)")
        // The rest of the file is kept.
        #expect(try ConfigManager.load(from: config.path).provider.name == "l4-fixture")
    }

    /// The --foreground child reads `[local]`: the saved `me_first = false` keeps Darkbloom serving there too.
    @Test("the service the default installs keeps Darkbloom serving while you use this Mac")
    func defaultServiceNeverPauses() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        _ = try ScriptedTerminal().resolve(try config.start([]))
        let saved = try #require(config.local)
        #expect(saved.meFirstIdle(local: false, localEndpoint: true) == nil, "no pause in the served process")
        let child = try ScriptedTerminal().resolve(
            try config.start(["--foreground", "--local-endpoint", "--port", "\(firstNewPort)"]))
        #expect(child.mode == .both && !child.meFirst && child.change.isEmpty)
    }

    @Test("with an account key saved, your requests go to your Macs (free) when this Mac can't take them; no route asked")
    func defaultRouteIsOnlyMyMacs() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let script = ScriptedTerminal()
        let serving = try script.resolve(try config.start([]), keySaved: true)
        #expect(serving.accountKeySaved == true && serving.route == nil && script.keyLookups == 1)
        #expect(LocalSettings(route: serving.route).resolvedRoute(accountKeySaved: true) == .myMacs)
        #expect(serving.summaryLines.suffix(2) == [
            "  Local:   http://127.0.0.1:\(firstNewPort)/v1 — your requests: this Mac first, then your other Macs (free)",
            "           (`darkbloom local` shows the key)",
        ])
        #expect(config.local?.route == nil, "no route is saved: it follows the account key")
        // Without a key, nothing routes off this Mac.
        let keyless = try TempConfig(plainConfig)
        defer { keyless.remove() }
        let alone = try ScriptedTerminal().resolve(try keyless.start([]), keySaved: false)
        #expect(LocalFirstWords.requests(route: alone.route, accountKeySaved: false) == "this Mac only")
    }

    /// Owner's rule: a saved choice is never changed silently. Only a Mac with no saved mode takes the default.
    @Test("a saved choice is served as saved, its pause included, and nothing is written")
    func savedChoicesAreKept() throws {
        let cases: [(local: String, mode: LocalSettings.Mode, meFirst: Bool)] = [
            ("mode = \"both\"\n", .both, true),
            ("mode = \"both\"\nme_first = false\n", .both, false),
            ("mode = \"network\"\n", .network, false),
            ("mode = \"local\"\n", .local, false),
        ]
        for (local, mode, meFirst) in cases {
            let config = try TempConfig(plainConfig + "\n\n[local]\n" + local + "port = 8003\n")
            defer { config.remove() }
            let before = config.bytes
            let serving = try ScriptedTerminal().resolve(try config.start([]))
            #expect(serving.mode == mode && serving.source == .saved && serving.meFirst == meFirst, "\(local)")
            #expect(serving.change.isEmpty && serving.defaultLine == nil && config.bytes == before, "\(local)")
        }
        // A saved pause without a saved mode (written by hand, or by an earlier pair) is kept: Both, me first.
        let pause = try TempConfig(plainConfig + "\n\n[local]\nme_first = true\nport = 8003\n")
        defer { pause.remove() }
        let paused = try ScriptedTerminal().resolve(try pause.start([]))
        #expect(paused.mode == .both && paused.source == .default && paused.meFirst)
        #expect(pause.local == LocalSettings(mode: .both, meFirst: true, port: 8003))
    }

    @Test("the mode flags keep working: --me-first pauses, --me-first-idle keeps the pause, --no-me-first doesn't")
    func modeFlagsKeepWorking() throws {
        func fresh(_ arguments: [String]) throws -> (StartServing, LocalSettings?) {
            let config = try TempConfig(plainConfig)
            defer { config.remove() }
            let serving = try ScriptedTerminal().resolve(try config.start(arguments))
            return (serving, config.local)
        }
        let (meFirst, meFirstSaved) = try fresh(["--me-first"])
        #expect(meFirst.mode == .both && meFirst.meFirst && meFirstSaved == LocalSettings(mode: .both, port: firstNewPort))
        let (idle, idleSaved) = try fresh(["--me-first-idle", "5"])
        #expect(idle.mode == .both && idle.source == .default && idle.meFirst && idle.meFirstIdleMinutes == 5)
        #expect(idleSaved == LocalSettings(mode: .both, meFirstIdleMinutes: 5, port: firstNewPort))
        let (noPause, noPauseSaved) = try fresh(["--no-me-first"])
        #expect(noPause.mode == .both && !noPause.meFirst)
        #expect(noPauseSaved == LocalSettings(mode: .both, meFirst: false, port: firstNewPort))
        let (network, networkSaved) = try fresh(["--network"])
        #expect(network.mode == .network && networkSaved == LocalSettings(mode: .network) && network.defaultLine == nil)
        let (local, localSaved) = try fresh(["--local"])
        #expect(local.mode == .local && localSaved == LocalSettings(mode: .local, port: firstNewPort))
        let (endpoint, endpointSaved) = try fresh(["--local-endpoint"])
        #expect(endpoint.meFirst && endpointSaved == LocalSettings(mode: .both, port: firstNewPort),
                "--local-endpoint keeps its meaning: Both, me first unless --no-me-first")
    }

    @Test("the default is saved only once the start goes ahead, and a start it refuses saves nothing")
    func defaultSavedOnlyWhenTheStartGoesAhead() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let before = config.bytes
        let start = try config.start([])
        let serving = try start.resolveServing(environment: ScriptedTerminal().environment())
        #expect(serving.source == .default)
        #expect(config.bytes == before)
        try start.saveServingChoice(serving)
        #expect(config.local == LocalSettings(mode: .both, meFirst: false, port: firstNewPort))

        // A saved Only me and a flag only it refuses: refused before anything is saved.
        let onlyMe = try TempConfig(plainConfig + "\n\n[local]\nmode = \"local\"\n")
        defer { onlyMe.remove() }
        let kept = onlyMe.bytes
        for (arguments, refusal) in [
            (["--schedule"], "--schedule configures a background provider; \"Only me, on this Mac\" does not use "
                + "availability windows. Nothing was saved."),
            (["--autopilot"], "Autopilot requires a network provider. Nothing was saved."),
        ] {
            do {
                _ = try ScriptedTerminal().resolve(try onlyMe.start(arguments))
                Issue.record("\(arguments) with a saved Only me must be refused")
            } catch let error as ValidationError {
                #expect(error.message == refusal)
            }
        }
        #expect(onlyMe.bytes == kept)
    }

    // MARK: - Without a terminal

    /// A script's or an agent's start names no mode, and nor does the desktop app's Start without its local API
    /// (`DesktopBackend.arguments` adds `--local-endpoint` only with it): on a Mac with no saved choice they take the
    /// default, as a start in a terminal does.
    @Test("a start without a terminal, the desktop app's included, takes the default where nothing is saved",
          arguments: [["--model", "fixture/model"], ["--all", "--idle-timeout", "30"]])
    func nonTerminalStartTakesTheDefault(arguments: [String]) throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let script = ScriptedTerminal()
        let serving = try script.resolve(try config.start(arguments), keySaved: true)
        #expect(serving.mode == .both && serving.source == .default && !serving.meFirst)
        #expect(config.local == LocalSettings(mode: .both, meFirst: false, port: firstNewPort))
    }

    /// launchd's `--foreground` child without a mode flag (a job an older build wrote) serves as its argv says: the
    /// Darkbloom network, with no local API, no Keychain look-up, no port probe and nothing written, whatever `[local]`
    /// saved (a saved Both or Only me must not open a local port at login).
    @Test("the --foreground child without a mode flag is today's Darkbloom network, and touches nothing")
    func foregroundChildWithoutAModeFlagKeepsToday() throws {
        for toml in [plainConfig, nil, plainConfig + "\n\n[local]\nmode = \"both\"\n",
                     plainConfig + "\n\n[local]\nmode = \"local\"\n"] {
            let config = try TempConfig(toml)
            defer { config.remove() }
            let before = config.bytes
            let script = ScriptedTerminal()
            let serving = try script.resolve(try config.start(["--foreground", "--model", "fixture/model"]), keySaved: true)
            #expect(serving.mode == .network && serving.source == .today, "\(toml ?? "no file")")
            #expect(serving.change.isEmpty && serving.portNote == nil && serving.accountKeySaved == nil)
            #expect(serving.defaultLine == nil && serving.summaryLines.isEmpty)
            #expect(script.keyLookups == 0 && script.livePortLookups == 0 && script.probed.isEmpty)
            #expect(script.installedPortLookups == 0)
            #expect(config.bytes == before, "the config is left as it was (absent stays absent)")
            #expect(launchAgentArguments(serving.launchAgentEndpoint)
                == launchAgentArguments(LaunchAgent.LocalEndpointOptions()))
            var tokenAsked = false
            let endpoint = try Start.unifiedLocalEndpoint(
                serving: serving, config: ProviderConfig(provider: ProviderSettings(name: "l4")),
                settingsFile: URL(fileURLWithPath: "/tmp/start-local-first/provider.toml"),
                coordinatorURL: "wss://coordinator.invalid/ws/provider",
                loadToken: { tokenAsked = true; return "dk-local-fixture" })
            #expect(endpoint == nil && !tokenAsked)
        }
    }

    @Test("a saved choice applies, and probes no port")
    func savedChoiceApplies() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"both\"\nport = 8003\n")
        defer { config.remove() }
        let before = config.bytes
        let script = ScriptedTerminal()
        let serving = try script.resolve(try config.start([]))
        #expect(serving.mode == .both && serving.source == .saved && serving.port == 8003 && serving.meFirst)
        #expect(script.probed.isEmpty && serving.change.isEmpty)
        #expect(launchAgentArguments(serving.launchAgentEndpoint)
            == launchAgentArguments(.init(enabled: true, port: 8003, bind: "127.0.0.1", noAuth: false)))
        #expect(config.bytes == before)
    }

    /// The desktop app's network Start is `start --model <id> --config <path>` (`DesktopBackend.arguments`), run
    /// without a terminal, and it waits for the command to end. A saved Only me serves in the background, as the other
    /// two choices do, so that start installs or restarts its service and returns: nothing is refused, and nothing
    /// waits on a terminal.
    @Test("without a terminal, a saved Only me serves in the background: no refusal, nothing asked")
    func nonTerminalSavedOnlyMeServes() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"local\"\nport = 8001\n")
        defer { config.remove() }
        let before = config.bytes
        var action = DesktopAction(id: UUID().uuidString, action: "start")
        action.models = ["fixture/model"]
        let argv = try DesktopBackend.arguments(for: action, configPath: config.path.path, localActive: false)
        #expect(argv == ["start", "--model", "fixture/model", "--config", config.path.path], "the app names no mode")
        let script = ScriptedTerminal()
        let start = try Start.parse(Array(argv.dropFirst()))
        let serving = try script.resolve(start)
        #expect(serving.mode == .local && serving.source == .saved && serving.port == 8001 && serving.change.isEmpty)
        #expect(Start.singleMacServing(mode: serving.mode, here: start.here, foreground: start.foreground) == .onlyMeService,
                "the background service")
        #expect(script.livePortLookups == 0 && script.probed.isEmpty)
        #expect(script.keyLookups == 1, "whether an account key is saved, for the requests line; never the key")
        #expect(config.bytes == before)
        // A mode flag decides over the saved choice.
        #expect(try script.resolve(try config.start([])).mode == .local)
        #expect(try script.resolve(try config.start(["--network"])).mode == .network)
        #expect(try script.resolve(try config.start(["--local"])).mode == .local)
    }

    /// The LaunchAgent's `--foreground` child runs at every launch: its argv says how it serves.
    @Test("the --foreground service never saves, probes a port or asks the Keychain")
    func foregroundServiceTouchesNothing() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"network\"\nme_first = false\n")
        defer { config.remove() }
        let before = config.bytes
        for arguments in [["--foreground", "--local-endpoint", "--port", "8003"], ["--foreground", "--me-first"]] {
            let script = ScriptedTerminal()
            let serving = try script.resolve(try config.start(arguments), keySaved: true)
            #expect(serving.mode == .both && serving.change.isEmpty && serving.portNote == nil, "\(arguments)")
            #expect(serving.accountKeySaved == nil && script.keyLookups == 0, "\(arguments)")
            #expect(script.livePortLookups == 0 && script.probed.isEmpty, "\(arguments)")
        }
        #expect(config.bytes == before)
    }

    @Test("an Only me start that runLocalStandalone refuses (no model it can serve) saves nothing")
    func refusedOnlyMeSavesNothing() async throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let before = config.bytes
        let start = try config.start(["--local"])
        let serving = try start.resolveServing(environment: ScriptedTerminal().environment())
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

    /// `--choose` asked the question again. No start asks now: it is kept so scripts that pass it still run, and says so.
    @Test("--choose asks nothing and changes nothing: one line says how to choose instead")
    func chooseIsANoOp() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nmode = \"network\"\n")
        defer { config.remove() }
        let before = config.bytes
        let serving = try ScriptedTerminal().resolve(try config.start(["--choose"]))
        #expect(serving.mode == .network && serving.source == .saved && serving.change.isEmpty)
        #expect(config.bytes == before)
        let named = try ScriptedTerminal().resolve(try config.start(["--choose", "--me-first"]))
        #expect(named.mode == .both && named.meFirst, "a mode flag beside it decides, as without it")
        #expect(Start.chooseNote == "`--choose` no longer asks: name how this Mac serves with --local, --network or "
            + "--me-first, or run `darkbloom local` for local only.")
    }

    // MARK: - Old flags keep their old meaning

    @Test("--local and --local-endpoint keep their modes and LaunchAgent argv and ask nothing; they save their mode and this Mac's port")
    func oldFlagsKeepTheirModes() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let script = ScriptedTerminal()
        let local = try script.resolve(try config.start(["--local"]))
        #expect(local.mode == .local && local.source == .flag(.local) && local.port == firstNewPort)
        #expect(local.bind == "127.0.0.1" && local.accountKeySaved == false, "where requests go: whether a key is saved")
        #expect(local.change == LocalSettingsChange(mode: .local, port: firstNewPort), "the mode and the port")
        #expect(local.portNote == LocalAPIPort.note(chosen: firstNewPort, start: defaultPort))

        let unified = try script.resolve(try config.start(["--local-endpoint"]))
        #expect(unified.mode == .both && unified.meFirst && unified.port == firstNewPort)
        #expect(unified.change == LocalSettingsChange(mode: .both), "the new mode; the port is saved already")
        #expect(launchAgentArguments(unified.launchAgentEndpoint)
            == launchAgentArguments(.init(enabled: true, port: firstNewPort, bind: "127.0.0.1", noAuth: false)))
        #expect(script.probed == [firstNewPort], "probed once, for the one choice")

        let custom = try script.resolve(
            try config.start(["--local-endpoint", "--port", "9001", "--bind", "0.0.0.0", "--no-auth"]))
        #expect(launchAgentArguments(custom.launchAgentEndpoint)
            == launchAgentArguments(.init(enabled: true, port: 9001, bind: "0.0.0.0", noAuth: true)))
        #expect(config.local == LocalSettings(mode: .both, port: 9001), "a named port is saved, as is the mode")
    }

    @Test("--local-endpoint --no-me-first is today's shared unified mode, and the choice is saved")
    func localEndpointWithoutMeFirst() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let serving = try ScriptedTerminal().resolve(
            try config.start(["--local-endpoint", "--no-me-first"]))
        #expect(serving.mode == .both && !serving.meFirst && serving.port == firstNewPort)
        #expect(launchAgentArguments(serving.launchAgentEndpoint)
            == launchAgentArguments(.init(enabled: true, port: firstNewPort, bind: "127.0.0.1", noAuth: false)))
        #expect(config.local == LocalSettings(mode: .both, meFirst: false, port: firstNewPort))
        // Me first again: --me-first undoes it; Both is saved already.
        let again = try ScriptedTerminal().resolve(try config.start(["--me-first"]))
        #expect(again.meFirst && again.change.meFirst == true && again.change.mode == nil)
        #expect(config.local == LocalSettings(mode: .both, meFirst: true, port: firstNewPort))
    }

    @Test("--local-endpoint --no-auth with a saved route keeps your requests on this Mac, and start, status and local say so")
    func noAuthKeepsRequestsOnThisMac() throws {
        let config = try TempConfig(plainConfig + "\n\n[local]\nroute = \"my-macs-first\"\n")
        defer { config.remove() }
        let terminal = ScriptedTerminal()
        let serving = try terminal.resolve(try config.start(["--local-endpoint", "--no-auth"]), keySaved: true)
        #expect(serving.mode == .both && serving.noAuth && serving.route == .myMacsFirst)
        #expect(terminal.keyLookups == 0, "without a local key the account key plays no part")
        // The local API gets no key, so its router keeps every request on this Mac, whatever the saved route
        // (`LocalRouterConfig.localKeyRequired`, set from the endpoint's key; LocalRouterTests covers the router).
        var served = ProviderConfig(provider: ProviderSettings(name: "l4"))
        served.local = config.local
        let endpoint = try #require(try Start.unifiedLocalEndpoint(
            serving: serving, config: served, settingsFile: URL(fileURLWithPath: "/tmp/start-local-first/provider.toml"),
            coordinatorURL: "wss://coordinator.invalid/ws/provider",
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

    @Test("the settings flags are saved as --idle-timeout is, and so is a flag's mode")
    func settingsFlagsAreSaved() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let serving = try ScriptedTerminal().resolve(
            try config.start(["--local-endpoint", "--me-first-idle", "5", "--route", "my-macs-first"]), keySaved: true)
        #expect(serving.meFirstIdleMinutes == 5 && serving.route == .myMacsFirst && serving.accountKeySaved == true)
        #expect(config.local == LocalSettings(mode: .both, meFirstIdleMinutes: 5, route: .myMacsFirst,
                                              port: firstNewPort))
    }

    @Test("--me-first without a terminal serves Both on a new port, and saves both")
    func meFirstFlagWithoutATerminal() throws {
        let config = try TempConfig(plainConfig)
        defer { config.remove() }
        let script = ScriptedTerminal()
        let serving = try script.resolve(try config.start(["--me-first"]))
        #expect(serving.mode == .both && serving.source == .flag(.meFirst) && serving.meFirst)
        #expect(serving.port == firstNewPort && !script.probed.contains(8000))
        #expect(config.local == LocalSettings(mode: .both, port: firstNewPort))
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
        ["--me-first", "--no-me-first"], ["--no-me-first", "--local"], ["--me-first-idle", "5", "--network"],
        ["--me-first-idle", "5", "--no-me-first"],
        ["--me-first-idle", "0"], ["--me-first-idle", "121"], ["--network", "--port", "9000"],
        ["--network", "--route", "my-macs"], ["--network", "--no-auth"], ["--route", "everywhere"],
        ["--foreground", "--route", "my-macs"], ["--foreground", "--no-me-first"],
        ["--cluster-member", "--network"], ["--cluster-member", "--route", "my-macs"],
    ])
    func contradictionsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try Start.parse(arguments) }
    }

    @Test("compatible flags parse", arguments: [
        ["--me-first", "--local-endpoint"], ["--local", "--local-endpoint"], ["--local-endpoint", "--no-me-first"],
        ["--me-first", "--me-first-idle", "120", "--route", "my-macs-first", "--port", "8123"], ["--choose"],
        ["--network"], ["--route", "this-mac"], ["--me-first-idle", "1"], ["--foreground", "--me-first"],
        ["--local", "--route", "my-macs", "--port", "8000"], ["--choose", "--network"], ["--choose", "--local-endpoint"],
        ["--foreground", "--choose"],
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
            _ = try ScriptedTerminal().resolve(try config.start([]),
                                               busy: Set((defaultPort...defaultPort + 20).map { $0 }))
            Issue.record("no free port must refuse the start")
        } catch let error as ValidationError {
            #expect(error.message == LocalAPIPort.noneFree(from: defaultPort))
        }
        #expect(config.local == nil, "nothing is saved")
    }

    @Test("the default keeps a saved port, even 8000 or a busy one, and an explicit --port is honoured and saved")
    func defaultKeepsTheSavedPort() throws {
        let cases: [(saved: UInt16, busy: Set<UInt16>)] = [(8000, []), (8005, [8005]), (8005, [])]
        for (saved, busy) in cases {
            let config = try TempConfig(plainConfig + "\n\n[local]\nport = \(saved)\n")
            defer { config.remove() }
            let script = ScriptedTerminal()
            let kept = try script.resolve(try config.start([]), busy: busy)
            #expect(kept.port == saved && kept.portNote == nil && kept.change.port == nil, "\(saved)")
            #expect(script.probed.isEmpty, "\(saved)")
            #expect(config.local == LocalSettings(mode: .both, meFirst: false, port: saved), "\(saved): the default is saved")
        }

        let explicit = try TempConfig(plainConfig)
        defer { explicit.remove() }
        let named = try ScriptedTerminal().resolve(try explicit.start(["--port", "8000"]))
        #expect(named.port == 8000 && explicit.local?.port == 8000, "an explicit --port is honoured and saved")
        #expect(named.portNote == "Local API port: 8000 (saved).")
        #expect(LocalAPIPort.note(chosen: 8002, start: 8002) == "Local API port: 8002 (saved).")
        #expect(LocalAPIPort.note(chosen: 8001, start: 8000) == "Local API port: 8001 (saved; 8000 is left for other apps).")
        #expect(LocalAPIPort.note(chosen: 8006, start: 8005) == "Local API port: 8006 (saved; 8005 is in use).")
    }

    // MARK: - The start's summary

    @Test("the summary says how this Mac serves, its address and where your requests go; never the key")
    func summaryLines() {
        func serving(_ mode: LocalSettings.Mode, meFirst: Bool = true, key: Bool? = false, route: LocalSettings.Route? = nil,
                     source: ServingModeSource = .default, noAuth: Bool = false) -> StartServing {
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

    @Test("no line of the default, the summary, status or local names a speed")
    func noSpeedAnywhere() throws {
        var lines = Local.networkOnlyLines + Local.notRunningHint
            + [Local.switchQuestion, Local.pairedLine, Start.chooseNote,
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
                        let serving = StartServing(mode: mode, source: .default, meFirst: meFirst,
                                                   meFirstIdleMinutes: 2, route: route, accountKeySaved: key,
                                                   port: 8001, bind: "0.0.0.0", noAuth: !key)
                        lines += serving.summaryLines + [serving.defaultLine].compactMap { $0 }
                        lines.append(Status.requestsLine(route: route, accountKeySaved: key))
                    }
                }
            }
        }
        for arguments in [["--local", "--me-first"], ["--network", "--port", "1"],
                          ["--no-me-first", "--network"], ["--me-first-idle", "0"], ["--foreground", "--route", "my-macs"]] {
            lines.append(refusal(arguments) ?? "")
        }
        lines += LocalFirstStatusFixtures.everyLine()
        let text = lines.joined(separator: "\n")
        for said in ["Switch this Mac to local only", "Serving Darkbloom and your local API at", "  Serving: Both, me first",
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
