import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// Only me as a background service (R1, R3, R15), the picker for Only me (R2), and the saved choice as the one thing the
/// background service serves (G2). Nothing here runs launchctl, binds a port or opens the Keychain.
@Suite("Only me in the background, and the saved choice", .serialized)
struct OnlyMeServiceTests {
    static let plain = "[provider]\nname = \"only-me\"\n"
    static let first: UInt16 = BuildEnvironment.current.defaultLocalPort == 8000 ? 8001
        : BuildEnvironment.current.defaultLocalPort

    // MARK: - Where Only me serves

    @Test("Only me serves in the background unless --here asks for this terminal; launchd's child serves itself")
    func whereOnlyMeServes() throws {
        #expect(!Start.servesOnlyMeHere(here: false, foreground: false), "the question, a saved Only me, --local")
        #expect(Start.servesOnlyMeHere(here: true, foreground: false), "--local --here")
        #expect(Start.servesOnlyMeHere(here: false, foreground: true), "launchd's --foreground child")
        #expect(try Start.parse(["--local", "--here"]).here)
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

    /// J-12 of the journey test: `start --local` stopped Darkbloom serving without a word.
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

    // MARK: - The saved choice (G2)

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

    /// J-11 of the journey test: with `[local] mode = "network"`, `start --me-first` served Both, and after `restart`
    /// the Mac still served Both while the config said network.
    @Test("start --me-first, then restart: the config and the service both say Both; an older job is brought back to the saved choice")
    func meFirstThenRestart() throws {
        let config = try TempConfig(Self.plain + "\n[local]\nmode = \"network\"\nport = 8003\n")
        defer { config.remove() }
        _ = try #require(try ScriptedTerminal().resolve(try config.start(["--me-first"]), terminal: false))
        #expect(config.local?.mode == .both)

        let both = try #require(LaunchAgent.ServingJob(arguments: Self.job(.both)))
        var asked: [(LocalSettings.Mode, UInt16, String)] = []
        let kept = try SavedChoiceService.align(configPath: config.path.path, job: both, thisMacPort: { 8003 },
                                                rewrite: { mode, port, bind, _ in
                                                    asked.append((mode, port, bind)); return false
                                                })
        #expect(kept == SavedChoiceService.Alignment(mode: .both, line: nil))
        #expect(asked.count == 1 && asked[0].0 == .both && asked[0].1 == 8003 && asked[0].2 == "127.0.0.1")

        // The journey's state, from an older build: saved network, the job serves Both. Restart serves network.
        let older = try TempConfig(Self.plain + "\n[local]\nmode = \"network\"\nport = 8003\n")
        defer { older.remove() }
        let rewritten = try SavedChoiceService.align(configPath: older.path.path, job: both, thisMacPort: { 8003 },
                                                     rewrite: { _, _, _, _ in true })
        #expect(rewritten == SavedChoiceService.Alignment(
            mode: .network, line: "Restarting as saved: Darkbloom network (the service was set up for Both, me first)."))

        // No saved choice (an upgraded Mac): restarted as installed, nothing rewritten.
        let upgraded = try TempConfig(Self.plain)
        defer { upgraded.remove() }
        let asInstalled = try SavedChoiceService.align(configPath: upgraded.path.path, job: both, rewrite: { _, _, _, _ in
            Issue.record("rewrote a job with no saved choice"); return true
        })
        #expect(asInstalled == SavedChoiceService.Alignment(mode: .both, line: nil))
    }

    @Test("the installed job is rewritten to the saved choice, with the same models, keeping its other keys")
    func installedJobRewrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("only-me-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("io.darkbloom.provider.plist")
        func write(_ arguments: [String]) throws {
            let contents: [String: Any] = ["Label": "io.darkbloom.provider", "ProgramArguments": arguments,
                                           "RunAtLoad": true, "EnvironmentVariables": ["DARKBLOOM_PREFIX_CACHE": "0"]]
            try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: plist)
        }
        func read() throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
                as? [String: Any])
        }
        let coordinator = "wss://coordinator.invalid/ws/provider"

        try write(Self.job(.both))
        #expect(try LaunchAgent.rewriteInstalledJob(serving: .network, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist))
        #expect(try read()["ProgramArguments"] as? [String] == Self.job(.network))
        #expect((try read()["EnvironmentVariables"] as? [String: String]) == ["DARKBLOOM_PREFIX_CACHE": "0"])
        #expect(try !LaunchAgent.rewriteInstalledJob(serving: .network, port: 8003, bind: "127.0.0.1",
                                                     coordinatorURL: coordinator, at: plist), "already so")

        #expect(try LaunchAgent.rewriteInstalledJob(serving: .local, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist))
        #expect(try read()["ProgramArguments"] as? [String] == Self.job(.local))
        #expect(try LaunchAgent.rewriteInstalledJob(serving: .both, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist))
        #expect(try read()["ProgramArguments"] as? [String] == Self.job(.both))

        // An older app's local job (`start --local` without --foreground) becomes launchd's --foreground Only me.
        try write(["/Applications/Darkbloom.app/Contents/MacOS/darkbloom", "start", "--local", "--model", "fixture/model"])
        #expect(try LaunchAgent.rewriteInstalledJob(serving: .local, port: 8003, bind: "127.0.0.1",
                                                    coordinatorURL: coordinator, at: plist))
        #expect(try read()["ProgramArguments"] as? [String] == Self.job(.local))

        // A cluster member's job is the pair's: never rewritten.
        let member = ["/Applications/Darkbloom.app/Contents/MacOS/darkbloom", "start", "--foreground", "--cluster-member",
                      "--supervise", "--coordinator-url", coordinator]
        try write(member)
        #expect(try !LaunchAgent.rewriteInstalledJob(serving: .local, port: 8003, bind: "127.0.0.1",
                                                     coordinatorURL: coordinator, at: plist))
        #expect(try read()["ProgramArguments"] as? [String] == member)
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

    /// #1896's review: an updated Mac's local API on 8000 keeps 8000. Only me's job takes this Mac's one port as every
    /// start resolves it: the saved one, else the one its local API already uses (here a Both job on 8000), saved.
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
        let both = try #require(LaunchAgent.ServingJob(arguments: Self.job(.network)
            + ["--local-endpoint", "--port", "8000", "--bind", "127.0.0.1"]))
        var asked: (mode: LocalSettings.Mode, port: UInt16)?
        let aligned = try SavedChoiceService.align(configPath: config.path.path, job: both,
                                                   rewrite: { mode, port, _, _ in asked = (mode, port); return true })
        #expect(asked?.mode == .local && asked?.port == 8000 && aligned.mode == .local)
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
}
