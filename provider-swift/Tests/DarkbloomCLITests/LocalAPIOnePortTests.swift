import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// One port and one key per Mac: every single-Mac way to start a local API takes `[local] port`, chosen once (the
/// first free from 8001, never 8000 or 47420–47423) and saved, so the address the tools were given never moves. A saved
/// port, or a named `--port`, wins. Nothing here binds a port: the scripted terminal's `isFree` stands in for the probe.
@Suite("One port and one key per Mac", .serialized)
struct LocalAPIOnePortTests {
    static let plain = "[provider]\nname = \"one-port\"\n"
    static let defaultPort = BuildEnvironment.current.defaultLocalPort
    /// The first port a choice takes: 8001 under production's identity, which never chooses 8000.
    static let first: UInt16 = defaultPort == 8000 ? 8001 : defaultPort

    /// A single-Mac way to start a local API: its arguments, the terminal's answers (none: no terminal), and the
    /// `[local]` lines it starts from.
    struct Path: Sendable, CustomTestStringConvertible {
        let name: String
        let arguments: [String]
        let answers: [String]?
        var local = ""
        var testDescription: String { name }
        var terminal: Bool { answers != nil }
    }

    static let paths = [
        Path(name: "the question: Both, me first", arguments: [], answers: ["3"]),
        Path(name: "the question: Only me", arguments: [], answers: ["1"]),
        Path(name: "a saved Both", arguments: [], answers: nil, local: "mode = \"both\"\n"),
        Path(name: "a saved Only me, in a terminal", arguments: [], answers: [], local: "mode = \"local\"\n"),
        Path(name: "--me-first", arguments: ["--me-first"], answers: nil),
        Path(name: "--local", arguments: ["--local"], answers: nil),
        Path(name: "--local-endpoint", arguments: ["--local-endpoint"], answers: nil),
        Path(name: "the app's Start with a local API", arguments: LocalAPIOnePortTests.appStart, answers: nil),
    ]

    /// The desktop app's Start with its local API (`DesktopBackend.arguments`), without `start` and `--config`.
    static var appStart: [String] {
        var action = DesktopAction(id: UUID().uuidString, action: "start")
        action.models = ["fixture/model"]
        action.endpoint = true
        let argv = (try? DesktopBackend.arguments(for: action, configPath: nil, localActive: false)) ?? []
        return Array(argv.dropFirst())
    }

    private func makeConfig(_ path: Path, port: UInt16? = nil) throws -> TempConfig {
        let lines = path.local + (port.map { "port = \($0)\n" } ?? "")
        return try TempConfig(Self.plain + (lines.isEmpty ? "" : "\n[local]\n" + lines))
    }

    @Test("every single-Mac path takes this Mac's port: the first free from 8001, chosen once and saved",
          arguments: paths)
    func everyPathTakesThisMacsPort(_ path: Path) throws {
        let config = try makeConfig(path)
        defer { config.remove() }
        let script = ScriptedTerminal(path.answers ?? [])
        let serving = try #require(try script.resolve(try config.start(path.arguments), terminal: path.terminal))
        #expect(serving.port == Self.first && config.local?.port == Self.first)
        #expect(serving.portNote == LocalAPIPort.note(chosen: Self.first, start: Self.defaultPort))
        #expect(!script.probed.contains(8000) && !script.probed.contains { (47_420...47_423).contains($0) })
        // The address the tools are given (`local.json` names it once the API listens, with this Mac's key file).
        #expect(serving.baseURL == "http://127.0.0.1:\(Self.first)/v1")

        // Chosen once: every later start keeps it, without a probe or a word: the question again, and each flag.
        let later: [(arguments: [String], answers: [String]?)] = [(["--choose"], ["3"]), (["--me-first"], nil),
            (["--local"], nil), (["--local-endpoint"], nil), (Self.appStart, nil)]
        for (arguments, answers) in later {
            let again = ScriptedTerminal(answers ?? [])
            let kept = try #require(try again.resolve(try config.start(arguments), terminal: answers != nil),
                                    "\(arguments)")
            #expect(kept.port == Self.first && kept.change.port == nil && kept.portNote == nil, "\(arguments)")
            #expect(again.probed.isEmpty, "\(arguments)")
        }
    }

    @Test("a saved port wins on every path, also while another program holds it, and nothing is probed",
          arguments: paths)
    func savedPortWins(_ path: Path) throws {
        let config = try makeConfig(path, port: 8005)
        defer { config.remove() }
        let script = ScriptedTerminal(path.answers ?? [])
        let serving = try #require(try script.resolve(try config.start(path.arguments), terminal: path.terminal,
                                                      busy: [8005]))
        #expect(serving.port == 8005 && serving.change.port == nil && serving.portNote == nil)
        #expect(script.probed.isEmpty && config.local?.port == 8005)
    }

    @Test("a named --port wins and is saved, naming the port it replaces; launchd's child saves nothing")
    func namedPortWins() throws {
        let fresh = try TempConfig(Self.plain)
        defer { fresh.remove() }
        let named = try #require(try ScriptedTerminal().resolve(try fresh.start(["--local", "--port", "8007"]),
                                                                terminal: false))
        #expect(named.port == 8007 && fresh.local == LocalSettings(mode: .local, port: 8007))
        #expect(named.portNote == "Local API port: 8007 (saved).")

        let saved = try TempConfig(Self.plain + "\n[local]\nport = 8005\n")
        defer { saved.remove() }
        let moved = try #require(try ScriptedTerminal().resolve(try saved.start(["--me-first", "--port", "8007"]),
                                                                terminal: false))
        #expect(moved.port == 8007 && saved.local == LocalSettings(mode: .both, port: 8007))
        #expect(moved.portNote == "Local API port: 8007 (saved, instead of 8005: tools set up for 8005 need "
            + "`darkbloom start --opencode` or `--hermes` again).")

        let before = saved.bytes
        let child = try #require(try ScriptedTerminal().resolve(
            try saved.start(["--foreground", "--local-endpoint", "--port", "8009"]), terminal: false))
        #expect(child.port == 8009 && child.change.isEmpty && child.portNote == nil && saved.bytes == before)
    }

    @Test("the app's local mode serves on this Mac's port, chosen and saved before it starts; its child saves nothing")
    func appLocalModeTakesThisMacsPort() throws {
        let config = try TempConfig(Self.plain)
        defer { config.remove() }
        var probed: [UInt16] = []
        let api = try Desktop.StartLocal.localAPI(configPath: config.path.path, ownLivePort: { nil },
                                                   isFree: { probed.append($0); return true })
        #expect(api.choice.port == Self.first && config.local?.port == Self.first && !probed.contains(8000))
        #expect(api.choice.note == LocalAPIPort.note(chosen: Self.first, start: Self.defaultPort))

        let binary = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
        let argv = LaunchAgent.localProgramArguments(binaryPath: binary, models: ["fixture/model"],
                                                     configPath: config.path, port: api.choice.port, bind: api.bind,
                                                     noAuth: false)
        #expect(argv == [binary, "start", "--foreground", "--local", "--port", "\(Self.first)", "--bind", "127.0.0.1",
                         "--model", "fixture/model", "--config", config.path.standardizedFileURL.path])

        // launchd's child serves Only me on that port, and asks, probes and saves nothing; its banner, which goes to
        // the log, shows no key.
        let before = config.bytes
        let script = ScriptedTerminal(["3"])
        let start = try Start.parse(Array(argv.dropFirst(2)))
        let child = try #require(try script.resolve(start, terminal: false))
        #expect(child.mode == .local && child.port == Self.first && child.bind == "127.0.0.1" && child.change.isEmpty)
        #expect(script.reads == 0 && script.probed.isEmpty && config.bytes == before)
        #expect(!start.bannerShowsKey(child))

        // Saved: the same port again, nothing probed or written.
        let again = try Desktop.StartLocal.localAPI(configPath: config.path.path, ownLivePort: { nil },
                                                     isFree: { _ in Issue.record("probed"); return true })
        #expect(again.choice.port == Self.first && again.choice.note == nil && config.bytes == before)
    }

    /// The app's local mode on 0.10.10 and earlier wrote a job that runs `start --local --model <id>` without
    /// --foreground, and the cluster service's solo part runs `start --local --port 8000`. After an update both run with
    /// this build: they must serve exactly as before, never choosing or saving a port.
    @Test("an older app's local job, or the cluster service's solo part, serves as the --foreground service")
    func serviceChildrenServeAsBefore() throws {
        #expect(Start.isServiceChild(local: true, foreground: false, distributed: false, startedByAService: { true }))
        #expect(!Start.isServiceChild(local: true, foreground: false, distributed: false, startedByAService: { false }))
        #expect(!Start.isServiceChild(local: false, foreground: false, distributed: false, startedByAService: {
            Issue.record("asked for a start without --local"); return true
        }))
        #expect(!Start.isServiceChild(local: true, foreground: false, distributed: true, startedByAService: { true }))

        let children: [(toml: String?, arguments: [String])] = [
            (Self.plain, ["--local", "--model", "fixture/model"]),
            (nil, ["--local", "--model", "fixture/model"]),
            (Self.plain + "\n[local]\nport = 8001\n", ["--local", "--model", "fixture/model", "--port", "8000"]),
        ]
        for (toml, arguments) in children {
            let config = try TempConfig(toml)
            defer { config.remove() }
            let before = config.bytes
            var start = try config.start(arguments)
            start.foreground = Start.isServiceChild(local: start.local, foreground: start.foreground,
                                                    distributed: start.distributed, startedByAService: { true })
            let script = ScriptedTerminal()
            let child = try #require(try script.resolve(start, terminal: false))
            #expect(child.mode == .local && child.change.isEmpty, "\(arguments)")
            #expect(child.port == (arguments.contains("--port") ? 8000 : Self.defaultPort), "\(arguments)")
            #expect(script.probed.isEmpty && script.livePortLookups == 0 && config.bytes == before, "\(arguments)")
        }
    }

    @Test("Only me in a terminal that can't listen names the port and the next step")
    func onlyMeBindFailureLine() {
        #expect(Start.localServerBindFailure(bind: "127.0.0.1", port: 8001, nextFree: 8002)
            == "This Mac's local API couldn't listen on 127.0.0.1:8001: another program may use port 8001. Free it, or "
                + "run `darkbloom start --port 8002`.")
        #expect(Start.localServerBindFailure(bind: "127.0.0.1", port: 8001, nextFree: nil)
            == "This Mac's local API couldn't listen on 127.0.0.1:8001: another program may use port 8001. Free it, or "
                + "name another with `darkbloom start --port <n>`.")
    }

    // `darkbloom local` reads the process-wide DARKBLOOM_LOCAL_DIR and DARKBLOOM_STATE_FILE, so it runs in a child
    // process that alone points them at a temp folder.
    @Test("local, beside a Both provider whose local API couldn't listen, says why instead of \"no local server\"")
    func localCommandSaysWhy() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-not-up-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
            let stateFile = directory.appendingPathComponent("daemon-state.json")
            setenv("DARKBLOOM_STATE_FILE", stateFile.path, 1)
            DaemonStateFile.write(LocalFirstStatusFixtures.state(pid: getpid(), meFirst: LocalFirstStatusFixtures.open,
                                                                 localAPIFailure: LocalFirstStatusFixtures.portInUse),
                                  to: stateFile)
            var command = try Local.parse([])
            do {
                try await command.run()
            } catch let code as ExitCode where code == .failure {
                try? FileManager.default.removeItem(at: directory)
                exit(0)
            }
            exit(1)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.hasPrefix("The local API isn't up: port 8001 is in use ("), "\(stderr)")
        #expect(!stderr.contains("No local server running."), "\(stderr)")
    }
}
