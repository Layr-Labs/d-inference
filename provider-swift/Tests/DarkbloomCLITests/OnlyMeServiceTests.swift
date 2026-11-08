import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// Only me as a background service (at login, with the watchdog and updates; `restart` and `update` restart it), its
/// model picker, and the saved choice as the one thing the background service serves. Nothing here runs launchctl,
/// binds a port or opens the Keychain.
@Suite("Only me in the background, and the saved choice", .serialized)
struct OnlyMeServiceTests {
    static let plain = "[provider]\nname = \"only-me\"\n"
    static let first: UInt16 = BuildEnvironment.current.defaultLocalPort == 8000 ? 8001
        : BuildEnvironment.current.defaultLocalPort

    // MARK: - Where Only me serves

    /// `start` serves by this rule (`singleMacServing`): a terminal `start --local` that served in its terminal, or
    /// launchd's child that set a service up, would never serve in the background, or never serve at all.
    @Test("Only me serves in the background unless --here asks for this terminal; launchd's child serves itself")
    func whereOnlyMeServes() throws {
        #expect(Start.singleMacServing(mode: .local, here: false, foreground: false) == .onlyMeService,
                "the question, a saved Only me, --local")
        #expect(Start.singleMacServing(mode: .local, here: true, foreground: false) == .onlyMeHere, "--local --here")
        #expect(Start.singleMacServing(mode: .local, here: false, foreground: true) == .onlyMeHere,
                "launchd's --foreground child")
        for mode in [LocalSettings.Mode.network, .both] {
            #expect(Start.singleMacServing(mode: mode, here: false, foreground: false) == .service, "\(mode)")
            #expect(Start.singleMacServing(mode: mode, here: false, foreground: true) == .foreground, "\(mode)'s child")
        }
        #expect(try Start.parse(["--local", "--here"]).here)
        #expect(try Start.parse(["--foreground", "--local"]).foreground)
        #expect(try Start.parse(["--local", "--here"]).singleMacOptions == ["--local", "--here"])
    }

    /// AppKit's host holds Ctrl-C for a serving process's drain: only a start that serves in this process gets it, so
    /// Ctrl-C still ends Only me's background setup at the picker or a download, as it ends any other start.
    @Test("only a start that serves in this process runs under AppKit; Only me's background setup doesn't")
    func appKitHostsOnlyServingProcesses() {
        let never: () -> Bool = { false }
        #expect(ProviderAppKitHost.shouldHost(["start", "--foreground", "--local"], startedByAService: never))
        #expect(ProviderAppKitHost.shouldHost(["start", "--local", "--here"], startedByAService: never))
        #expect(ProviderAppKitHost.shouldHost(["start", "--local", "--distributed"], startedByAService: never))
        #expect(ProviderAppKitHost.shouldHost(["start", "--local", "--model", "m"], startedByAService: { true }),
                "an older app job, or the cluster service's solo part")
        #expect(!ProviderAppKitHost.shouldHost(["start", "--local"], startedByAService: never))
        #expect(!ProviderAppKitHost.shouldHost(["start"], startedByAService: never))
        #expect(!ProviderAppKitHost.shouldHost(["local", "--json"], startedByAService: never))
    }

    @Test("--here is refused without --local, and with --foreground")
    func hereRefusals() {
        for (arguments, words) in [
            (["--here"], "`--here` serves Only me in this terminal: use it with --local (`darkbloom start --local --here`)."),
            (["--me-first", "--here"],
             "`--here` serves Only me in this terminal: use it with --local (`darkbloom start --local --here`)."),
            (["--foreground", "--local", "--here"], "`--here` serves in a terminal; the --foreground service is launchd's."),
        ] {
            do {
                _ = try Start.parse(arguments)
                Issue.record("\(arguments) must be refused")
            } catch {
                #expect(Start.message(for: error) == words, "\(arguments)")
            }
        }
    }

    /// The picker downloads the models picked that aren't on this Mac yet; `start` scanned the Mac before it ran.
    @Test("a model the picker just downloaded is the one Only me serves")
    func pickedDownloadIsServed() async throws {
        let start = try Start.parse(["--local"])
        let config = ProviderConfig(provider: ProviderSettings(name: "only-me"))
        let fresh = ModelInfo(id: "fresh/gemma", modelType: "gemma4", sizeBytes: 1, estimatedMemoryGb: 1)
        func snapshot(_ models: [ModelInfo]) -> RuntimeSnapshot {
            RuntimeSnapshot(configPath: URL(fileURLWithPath: "/nonexistent/provider.toml"), configFileExists: false,
                            config: config, hardware: nil, hardwareError: nil, models: models)
        }
        var scans = 0
        let served = try await start.onlyMeModels(
            snapshot: snapshot([]), config: config, coordinatorURL: "wss://coordinator.invalid/ws/provider",
            runtimeCapabilities: [], terminal: true, select: { ["fresh/gemma"] },
            scan: { scans += 1; return [fresh] })
        #expect(served == ["fresh/gemma"] && scans == 1, "scanned once more, after the download")
        // Every model picked was on this Mac already: no second scan.
        scans = 0
        let already = try await start.onlyMeModels(
            snapshot: snapshot([fresh]), config: config, coordinatorURL: "wss://coordinator.invalid/ws/provider",
            runtimeCapabilities: [], terminal: true, select: { ["fresh/gemma"] },
            scan: { scans += 1; return [fresh] })
        #expect(already == ["fresh/gemma"] && scans == 0)
    }

    /// A script or the app's Start waits for `start` to end: without a terminal nothing is asked, not even the model.
    @Test("without a terminal, Only me takes the last selection still on this Mac, else every model it serves")
    func modelsWithoutATerminal() {
        let onThisMac = ["gemma-4-26b-qat-4bit", "qwen-35b-4bit"]
        #expect(Start.onlyMeModelsWithoutAsking(lastSelection: ["qwen-35b-4bit", "gone/model"], onThisMac: onThisMac)
            == ["qwen-35b-4bit"])
        #expect(Start.onlyMeModelsWithoutAsking(lastSelection: [], onThisMac: onThisMac) == onThisMac)
        #expect(Start.onlyMeModelsWithoutAsking(lastSelection: ["gone/model"], onThisMac: onThisMac) == onThisMac)
        #expect(Start.onlyMeModelsWithoutAsking(lastSelection: ["gone/model"], onThisMac: []).isEmpty,
                "a Mac without a model: the start then names the commands that get one")
    }

    /// Before, `start --local` stopped Darkbloom serving without a word.
    @Test("Only me says that Darkbloom network serving stops; nothing to say when it didn't serve the network")
    func onlyMeSaysWhatStops() {
        let network = DaemonState(pid: 77, version: "t", writtenAt: 0, startedAt: 0, runtimeCapabilities: [])
        #expect(Start.onlyMeReplacesLine(network, alive: { _ in true }) == "Darkbloom network serving stops: this Mac "
            + "serves only you from now on (`darkbloom start --me-first` serves Darkbloom and you).")
        #expect(Start.onlyMeReplacesLine(network, alive: { _ in false }) == nil)
        let onlyMe = DaemonState(pid: 77, version: "t", writtenAt: 0, startedAt: 0)
        #expect(Start.onlyMeReplacesLine(onlyMe, alive: { _ in true }) == nil)
        #expect(Start.onlyMeReplacesLine(nil) == nil)
    }

    // MARK: - The saved choice

    @Test("a mode flag is saved, so the service, restart and update serve it; --local --here and launchd's child save no mode")
    func modeFlagsAreSaved() throws {
        let cases: [(arguments: [String], saved: LocalSettings.Mode?)] = [
            (["--me-first"], .both), (["--local-endpoint"], .both), (["--local"], .local), (["--network"], .network),
            (["--local", "--here"], nil), (["--foreground", "--local-endpoint", "--port", "8003"], nil),
        ]
        for (arguments, saved) in cases {
            let config = try TempConfig(Self.plain + "\n[local]\nmode = \"network\"\nport = 8003\n")
            defer { config.remove() }
            let serving = try #require(try ScriptedTerminal().resolve(try config.start(arguments), terminal: false))
            #expect(config.local?.mode == (saved ?? .network), "\(arguments)")
            #expect(serving.change.mode == (saved == .network ? nil : saved), "\(arguments)")
        }
    }

    /// Before, with `[local] mode = "network"`, `start --me-first` served Both, and after `restart` the Mac still served
    /// Both while the config said network.
    @Test("start --me-first, then restart: the config and the service both say Both; an older job is brought back to the saved choice")
    func meFirstThenRestart() throws {
        let config = try TempConfig(Self.plain + "\n[local]\nmode = \"network\"\nport = 8003\n")
        defer { config.remove() }
        _ = try #require(try ScriptedTerminal().resolve(try config.start(["--me-first"]), terminal: false))
        #expect(config.local?.mode == .both)

        // The job serves Both on 8003, at 127.0.0.1, as saved: it restarts as it is.
        let job = try JobPlist(Self.job(.both))
        defer { job.remove() }
        let installed = job.bytes
        let kept = try SavedChoiceService.align(configPath: config.path.path, plist: job.path, thisMacPort: { _ in 8003 })
        #expect(kept == SavedChoiceService.Alignment(mode: .both, line: nil))
        #expect(job.bytes == installed, "nothing rewritten")

        // An older build's state: saved network, the job serves Both. Restart serves network, and asks for no port.
        let older = try TempConfig(Self.plain + "\n[local]\nmode = \"network\"\nport = 8003\n")
        defer { older.remove() }
        let rewritten = try SavedChoiceService.align(configPath: older.path.path, plist: job.path, thisMacPort: { _ in
            Issue.record("chose a port for the Darkbloom network"); return 8003
        })
        #expect(rewritten == SavedChoiceService.Alignment(
            mode: .network, line: "Restarting as saved: Darkbloom network (the service was set up for Both, me first)."))
        #expect(job.arguments == Self.job(.network))

        // No saved choice (an updated Mac): its job restarts byte for byte as installed, even an argument a rewrite
        // would drop (the `--idle-timeout` plists before v0.8.14 carried), and no port is chosen.
        try job.write(Self.job(.both) + ["--idle-timeout", "60"])
        let updatedMac = job.bytes
        let upgraded = try TempConfig(Self.plain)
        defer { upgraded.remove() }
        let asInstalled = try SavedChoiceService.align(configPath: upgraded.path.path, plist: job.path, thisMacPort: { _ in
            Issue.record("chose a port with no saved choice"); return 8003
        })
        #expect(asInstalled == SavedChoiceService.Alignment(mode: .both, line: nil))
        #expect(job.bytes == updatedMac, "nothing rewritten")
    }

    @Test("the installed job is rewritten to the saved choice, with the same models, keeping its other keys")
    func installedJobRewrite() throws {
        let plist = try JobPlist(Self.job(.both))
        defer { plist.remove() }
        let coordinator = "wss://coordinator.invalid/ws/provider"

        #expect(try LaunchAgent.rewriteInstalledJob(serving: .network, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist.path))
        #expect(plist.arguments == Self.job(.network))
        #expect((plist.contents?["EnvironmentVariables"] as? [String: String]) == ["DARKBLOOM_PREFIX_CACHE": "0"])
        #expect(try !LaunchAgent.rewriteInstalledJob(serving: .network, port: 8003, bind: "127.0.0.1",
                                                     coordinatorURL: coordinator, at: plist.path), "already so")

        #expect(try LaunchAgent.rewriteInstalledJob(serving: .local, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist.path))
        #expect(plist.arguments == Self.job(.local))
        #expect(try LaunchAgent.rewriteInstalledJob(serving: .both, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist.path))
        #expect(plist.arguments == Self.job(.both))

        // An older app's local job (`start --local` without --foreground) becomes launchd's --foreground Only me.
        try plist.write(["/Applications/Darkbloom.app/Contents/MacOS/darkbloom", "start", "--local", "--model",
                         "fixture/model"])
        #expect(try LaunchAgent.rewriteInstalledJob(serving: .local, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist.path))
        #expect(plist.arguments == Self.job(.local))

        // A cluster member's job is the pair's: never rewritten.
        let member = ["/Applications/Darkbloom.app/Contents/MacOS/darkbloom", "start", "--foreground", "--cluster-member",
                      "--supervise", "--coordinator-url", coordinator]
        try plist.write(member)
        #expect(try !LaunchAgent.rewriteInstalledJob(serving: .local, port: 8003, bind: "127.0.0.1",
                                                     coordinatorURL: coordinator, at: plist.path))
        #expect(plist.arguments == member)
    }

    /// A job's argv as `start` writes it, for each way of serving.
    static func job(_ mode: LocalSettings.Mode) -> [String] {
        let binary = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
        switch mode {
        case .local:
            return [binary, "start", "--foreground", "--local", "--port", "8003", "--bind", "127.0.0.1", "--model",
                    "fixture/model"]
        case .network:
            return [binary, "start", "--foreground", "--coordinator-url", "wss://coordinator.invalid/ws/provider",
                    "--model", "fixture/model"]
        case .both:
            return job(.network) + ["--local-endpoint", "--port", "8003", "--bind", "127.0.0.1"]
        }
    }

    /// An updated Mac's local API on 8000 keeps 8000. Only me's job takes this Mac's one port as every start resolves
    /// it: the saved one, else the one its local API already uses (here a Both job on 8000), saved.
    @Test("Only me's job serves on this Mac's port: an existing 8000 stays 8000, saved, and restart keeps it")
    func onlyMeKeepsThisMacsPort() throws {
        let config = try TempConfig(Self.plain)
        defer { config.remove() }
        let serving = try #require(try ScriptedTerminal().resolve(try config.start(["--local"]), terminal: false,
                                                                  installedPort: 8000))
        #expect(serving.port == 8000 && config.local?.port == 8000 && config.local?.mode == .local)
        #expect(serving.portNote == LocalAPIPort.note(kept: 8000))
        let argv = LaunchAgent.localProgramArguments(binaryPath: "/Applications/Darkbloom.app/Contents/MacOS/darkbloom",
                                                     models: ["fixture/model"], configPath: nil, port: serving.port,
                                                     bind: serving.bind, noAuth: false)
        #expect(argv.firstIndex(of: "--port").map { argv[$0 + 1] } == "8000")

        // `restart` with that job still serving Both, me first on 8000: it becomes Only me, on 8000.
        let job = try JobPlist(Self.job(.network) + ["--local-endpoint", "--port", "8000", "--bind", "127.0.0.1"])
        defer { job.remove() }
        let aligned = try SavedChoiceService.align(configPath: config.path.path, plist: job.path)
        #expect(aligned == SavedChoiceService.Alignment(
            mode: .local, line: "Restarting as saved: Only me (the service was set up for Both, me first)."))
        #expect(job.arguments == argv, "Only me's job, on 8000")
    }

    /// The port tools point at is this Mac's saved one: a job an earlier start left on another port comes back on it.
    @Test("restart brings a job left on another port back on this Mac's saved port")
    func restartTakesThisMacsPort() throws {
        let config = try TempConfig(Self.plain + "\n[local]\nmode = \"both\"\nport = 8005\n")
        defer { config.remove() }
        let job = try JobPlist(Self.job(.both))
        defer { job.remove() }
        let aligned = try SavedChoiceService.align(configPath: config.path.path, plist: job.path)
        #expect(aligned == SavedChoiceService.Alignment(mode: .both, line: nil))
        #expect(job.arguments == Self.job(.network) + ["--local-endpoint", "--port", "8005", "--bind", "127.0.0.1"])
    }

    /// The job `launchOnlyMeService` installs (`installOnlyMeJob`, through `LaunchAgent.installLocalAndStart` into a
    /// temporary home, launchctl answered here): this Mac's one port as the start resolved it, its address, its key
    /// setting and the models.
    @Test("Only me's job as installed: a fresh Mac's first port, an updated Mac's 8000, its address, --no-auth, the models")
    func onlyMeJobAsInstalled() throws {
        for (installed, port) in [(UInt16?.none, Self.first), (UInt16?(8000), UInt16(8000))] {
            let config = try TempConfig(Self.plain)
            defer { config.remove() }
            let serving = try #require(try ScriptedTerminal().resolve(
                try config.start(["--local", "--bind", "100.64.0.5", "--no-auth"]), terminal: false,
                installedPort: installed))
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("only-me-home-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            let job = try LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
                try LaunchctlControl.$runnerForTesting.withValue({ arguments in
                    // Not loaded yet; enable, bootstrap and kickstart succeed.
                    LaunchctlControl.Output(status: arguments.first == "print" ? 1 : 0, stdout: "", stderr: "")
                }) {
                    try Start.installOnlyMeJob(models: ["fixture/a", "fixture/b"], configPath: config.path,
                                               serving: serving)
                    return LaunchAgent.installedServingJob()
                }
            }
            let which = installed == nil ? "a fresh Mac" : "an updated Mac"
            #expect(job?.mode == .local && job?.port == port, "\(which): \(String(describing: job))")
            #expect(job?.bind == "100.64.0.5" && job?.noAuth == true, "\(which)")
            #expect(job?.models == ["fixture/a", "fixture/b"], "\(which)")
            #expect(job?.configPath == config.path.standardizedFileURL.path, "\(which)")
        }
    }

    /// A rewrite keeps how the job serves its local API: its own address (a tailnet or LAN `--bind`, with none in
    /// `[local]`) and `--no-auth`, from Only me to Both, me first and back.
    @Test("restart's rewrite keeps the job's own address and --no-auth, to Both, me first and to Only me")
    func rewriteKeepsAddressAndNoAuth() throws {
        let binary = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
        let onlyMe = [binary, "start", "--foreground", "--local", "--port", "8003", "--bind", "100.64.0.5", "--no-auth",
                      "--model", "fixture/model"]
        let both = Self.job(.network) + ["--local-endpoint", "--port", "8003", "--bind", "100.64.0.5", "--no-auth"]
        for (saved, installed, rewritten) in [(LocalSettings.Mode.both, onlyMe, both), (.local, both, onlyMe)] {
            // Only me's job names no coordinator: a rewrite to Both, me first takes the config's.
            let config = try TempConfig(Self.plain + "\n[coordinator]\nurl = \"wss://coordinator.invalid/ws/provider\"\n"
                + "\n[local]\nmode = \"\(saved.rawValue)\"\nport = 8003\n")
            defer { config.remove() }
            let job = try JobPlist(installed)
            defer { job.remove() }
            let aligned = try SavedChoiceService.align(configPath: config.path.path, plist: job.path,
                                                       thisMacPort: { _ in 8003 })
            #expect(aligned.mode == saved && aligned.line != nil, "\(saved)")
            let served = LaunchAgent.installedServingJob(at: job.path)
            #expect(served?.bind == "100.64.0.5", "\(saved): the job's own address")
            #expect(served?.noAuth == true, "\(saved): --no-auth")
            #expect(job.arguments == rewritten, "\(saved)")
        }
    }

    // MARK: - Restart and update

    @Test("restart never stops Only me in a terminal, and says how to get the background service back")
    func restartLeavesATerminalSessionAlone() {
        let terminal = DaemonState(pid: 4_242, processIdentity: ProcessIdentity(pid: 4_242, startTimeMicros: 1),
                                   version: "t", writtenAt: 0, startedAt: 0)
        let service = ProcessIdentity(pid: 4_243, startTimeMicros: 1)
        #expect(Restart.terminalOnlyMe(terminal, launchJob: service, alive: { _ in true }))
        #expect(Restart.terminalOnlyMe(terminal, launchJob: nil, alive: { _ in true }))
        #expect(!Restart.terminalOnlyMe(terminal, launchJob: terminal.processIdentity, alive: { _ in true }),
                "launchd's Only me service restarts")
        #expect(!Restart.terminalOnlyMe(terminal, launchJob: service, alive: { _ in false }))
        var network = terminal
        network.runtimeCapabilities = []
        #expect(!Restart.terminalOnlyMe(network, launchJob: service, alive: { _ in true }))
        #expect(Restart.terminalOnlyMeLines == [
            "Only me serves in a terminal now (`darkbloom start --local --here`), and restart never stops it.",
            "Press Ctrl-C there, then `darkbloom restart` starts the background service again.",
        ])
        #expect(Update.nothingRestartedLine(version: "0.10.12", terminalOnlyMe: true)
            == "Only me serves in a terminal now (`darkbloom start --local --here`): press Ctrl-C there, then "
                + "`darkbloom start` serves v0.10.12 in the background.")
        #expect(Update.nothingRestartedLine(version: "0.10.12", terminalOnlyMe: false)
            == "Nothing serves in the background now; your next `darkbloom start` serves v0.10.12.")
    }

    /// Only me never contacts Darkbloom: waiting for its authorization would time out on every restart and update.
    @Test("restart and update wait for Only me's local API, and for fresh authorization otherwise")
    func restartWaitsAsTheServiceServes() async {
        let look = DarkbloomCommandLook(mode: .plain, output: { _ in }, pause: { _ in })
        let modes: [(LocalSettings.Mode?, String)] = [
            (.local, "this Mac's local API didn't answer within 0s"),
            (.both, "fresh authorization was not confirmed within 0s"),
            (.network, "fresh authorization was not confirmed within 0s"),
            (nil, "fresh authorization was not confirmed within 0s"),
        ]
        for (mode, words) in modes {
            // Nothing restarted here, so each wait ends at once, with its own words.
            do {
                try await ServiceDrain.waitForRestartedService(serving: mode, previous: nil, timeout: 0, look: look)
                Issue.record("\(String(describing: mode)): the wait must time out")
            } catch let error as ValidationError {
                #expect(error.message.contains(words), "\(String(describing: mode)): \(error.message)")
            } catch {
                Issue.record("\(String(describing: mode)): \(error)")
            }
        }
    }

    @Test("a restarted Only me is ready once a new process serves its local API, never on authorization")
    func onlyMeRestartReadiness() {
        let previous = ProcessIdentity(pid: 10, startTimeMicros: 1)
        let restarted = ProcessIdentity(pid: 11, startTimeMicros: 2)
        let now = 1_000.0
        let state = DaemonState(pid: 11, processIdentity: restarted, version: "t", writtenAt: now, startedAt: now)
        let info = LocalEndpoint.Info(host: "127.0.0.1", port: 8001, apiKey: "k", version: "t", pid: 11, updatedAt: "")
        #expect(ServiceDrain.localRestartReady(state: state, info: info, previous: previous, now: now, isCurrent: { _ in true }))
        #expect(!ServiceDrain.localRestartReady(state: state, info: info, previous: restarted, now: now,
                                                isCurrent: { _ in true }), "the same process")
        var other = info
        other.pid = 12
        #expect(!ServiceDrain.localRestartReady(state: state, info: other, previous: previous, now: now,
                                                isCurrent: { _ in true }), "another process's API")
        #expect(!ServiceDrain.localRestartReady(state: state, info: info, previous: previous, now: now + 600,
                                                isCurrent: { _ in true }), "a stale state")
    }

    // MARK: - Lines

    @Test("Only me's background summary names the address, the memory, and what keeps it running; no key")
    func serviceSummary() {
        let serving = StartServing(mode: .local, source: .question, meFirst: false, meFirstIdleMinutes: 2, route: nil,
                                   accountKeySaved: false, port: 8001, bind: "127.0.0.1", noAuth: false)
        let lines = Start.onlyMeServiceSummary(models: ["gemma-4-26b-qat-4bit"], idleMinutes: 60, serving: serving,
                                               autoRestart: true, autoUpdate: true)
        #expect(lines.first == "Only me serves in the background: it starts at login, restarts after a crash and updates "
            + "itself.")
        #expect(lines.contains("    gemma-4-26b-qat-4bit"))
        #expect(lines.contains("  Serving: Only me, on this Mac — Darkbloom never contacts this Mac"))
        #expect(lines.contains { $0.hasPrefix("  Local:   http://127.0.0.1:8001/v1") })
        #expect(!lines.joined().contains("dk-"))
        #expect(Start.onlyMeServiceSummary(models: [], idleMinutes: 0, serving: serving, autoRestart: false,
                                           autoUpdate: false).first == "Only me serves in the background: it starts at login.")
    }

    @Test("a Mac with no model to serve names the commands that get one")
    func noModelDeadEnd() {
        #expect(Start.noModelToServe == "No model to serve yet. See them: `darkbloom models catalog`. Get one: "
            + "`darkbloom models download <id>`, then `darkbloom start`.")
        let models = [ModelInfo(id: "served/gemma", modelType: "gemma4", sizeBytes: 1, estimatedMemoryGb: 1),
                      ModelInfo(id: "old/model", modelType: "llama_old", sizeBytes: 1, estimatedMemoryGb: 1)]
        let (servable, skipped) = Start.locallyServable(models, mtpMode: .auto)
        #expect(servable.map(\.id) == ["served/gemma"])
        #expect(skipped == ["Skipping old/model: model_type 'llama_old' has no engine-v2 adapter (v0.7.5 serves "
            + "everything through engine v2)"])
    }

    @Test("--here says what it stops, and on the way out what serves now")
    func hereLines() {
        let network = DaemonState(pid: 77, version: "t", writtenAt: 0, startedAt: 0, runtimeCapabilities: [])
        #expect(Start.hereStopsLine(network, alive: { _ in true })
            == "Darkbloom network serving stops while this runs; it starts again with `darkbloom start`.")
        let onlyMe = DaemonState(pid: 77, version: "t", writtenAt: 0, startedAt: 0)
        #expect(Start.hereStopsLine(onlyMe, alive: { _ in true })
            == "Only me's background service stops while this runs; it starts again with `darkbloom start`.")
        #expect(Start.hereStopsLine(network, alive: { _ in false }) == nil)
        #expect(Start.hereStopsLine(nil) == nil)
        #expect(Start.hereEndedLine(saved: .network) == "Only me in this terminal stopped; nothing serves on this Mac "
            + "now. `darkbloom start` serves it again as saved: Darkbloom network.")
        #expect(Start.hereEndedLine(saved: nil) == "Only me in this terminal stopped; nothing serves on this Mac now. "
            + "`darkbloom start` serves it again.")
    }

    @Test("no line of Only me's background start, restart or update names a speed or holds a key")
    func noSpeedAndNoKey() {
        let network = DaemonState(pid: 77, version: "t", writtenAt: 0, startedAt: 0, runtimeCapabilities: [])
        let onlyMe = DaemonState(pid: 77, version: "t", writtenAt: 0, startedAt: 0)
        var lines = Restart.terminalOnlyMeLines + [
            Start.noModelToServe, Start.catalogUnreachableOnlyMe(["gemma-4-26b-qat-4bit"]),
            Start.hereEndedLine(saved: .both), Update.nothingRestartedLine(version: "0.10.12", terminalOnlyMe: true),
            Update.nothingRestartedLine(version: "0.10.12", terminalOnlyMe: false),
        ]
        lines += [Start.onlyMeReplacesLine(network, alive: { _ in true }), Start.hereStopsLine(network, alive: { _ in true }),
                  Start.hereStopsLine(onlyMe, alive: { _ in true })].compactMap { $0 }
        for key in [true, false] {
            let serving = StartServing(mode: .local, source: .question, meFirst: false, meFirstIdleMinutes: 2,
                                       route: .myMacsFirst, accountKeySaved: key, port: 8001, bind: "127.0.0.1",
                                       noAuth: false)
            // The log's path is the one line that isn't words.
            lines += Start.onlyMeServiceSummary(models: ["gemma-4-26b-qat-4bit"], idleMinutes: 60, serving: serving,
                                                autoRestart: true, autoUpdate: true).filter { !$0.hasPrefix("  Logs:") }
        }
        let text = lines.joined(separator: "\n")
        #expect(!text.contains("tok/s") && !text.lowercased().contains("tokens per second"))
        #expect(text.range(of: #"[0-9][0-9.,]*\s*[A-Za-z]*/s\b"#, options: .regularExpression) == nil,
                "a number per second: \(text)")
        #expect(!text.contains("dk-") && !text.contains("OPENAI_API_KEY") && !text.contains("API key:"), "\(text)")
    }
}

/// A provider job's plist in its own temp folder, as `start` writes one, with a key a rewrite keeps.
struct JobPlist {
    let directory: URL
    let path: URL

    init(_ arguments: [String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("only-me-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("io.darkbloom.provider.plist")
        try write(arguments)
    }

    func write(_ arguments: [String]) throws {
        let contents: [String: Any] = ["Label": "io.darkbloom.provider", "ProgramArguments": arguments,
                                       "RunAtLoad": true, "EnvironmentVariables": ["DARKBLOOM_PREFIX_CACHE": "0"]]
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: path)
    }

    var bytes: Data? { try? Data(contentsOf: path) }
    var contents: [String: Any]? {
        bytes.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }
    var arguments: [String]? { contents?["ProgramArguments"] as? [String] }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
