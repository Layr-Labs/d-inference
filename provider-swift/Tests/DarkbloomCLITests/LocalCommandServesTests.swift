import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// `darkbloom local` serves only you: it starts Only me where nothing serves, and never stops Darkbloom by surprise.
/// Nothing here starts a service, reads this Mac's state or asks a real terminal: the facts and the reader are given.
@Suite("darkbloom local: local only, never stopping Darkbloom by surprise")
struct LocalCommandServesTests {
    private typealias F = LocalFirstStatusFixtures
    private let dead: (Int32) -> Bool = { _ in false }
    private let alive: (Int32) -> Bool = { _ in true }

    @Test("how this Mac serves now: the running provider first, else the loaded job, else a live local API")
    func servingNow() {
        func now(_ running: DaemonState?, alive: (Int32) -> Bool, job: LocalSettings.Mode? = nil, loaded: Bool = false,
                 saved: LocalSettings.Mode? = nil, live: Bool = false) -> Local.ServingNow {
            Local.servingNow(running: running, alive: alive, installedJob: job, jobLoaded: loaded, savedMode: saved,
                             liveLocalAPI: live)
        }
        #expect(now(F.state(connected: false), alive: alive, live: true) == .onlyMe)
        #expect(now(F.state(), alive: alive, job: .local, loaded: true) == .darkbloom,
                "a running provider that serves Darkbloom, without a local API")
        #expect(now(F.state(meFirst: F.open), alive: alive, live: true) == .darkbloom, "Both")
        // Between two runs of its job (a crash, a restart) launchd starts it again: still Darkbloom's.
        for mode in [LocalSettings.Mode.network, .both] {
            #expect(now(F.state(), alive: dead, job: mode, loaded: true) == .darkbloom)
            #expect(now(nil, alive: dead, job: mode, loaded: true, saved: .local) == .darkbloom)
        }
        #expect(now(nil, alive: dead, job: .local, loaded: true) == .onlyMe)
        // `start --local --here` in another terminal: no job, but its API answers.
        #expect(now(nil, alive: dead, live: true) == .onlyMe)
        #expect(now(F.state(), alive: dead) == .nothing)
        #expect(now(nil, alive: dead) == .nothing)
    }

    /// `darkbloom stop` unloads the job and keeps its plist, and `[local]` keeps the choice: such a Mac is Darkbloom's,
    /// stopped. `local` must not take it for a Mac where nothing serves (it would save Only me over Darkbloom).
    @Test("a stopped Mac saved as Darkbloom is Darkbloom's, stopped: its saved choice, else its installed job")
    func stoppedDarkbloom() {
        func now(job: LocalSettings.Mode?, saved: LocalSettings.Mode?, live: Bool = false) -> Local.ServingNow {
            Local.servingNow(running: F.state(), alive: dead, installedJob: job, jobLoaded: false, savedMode: saved,
                             liveLocalAPI: live)
        }
        for mode in [LocalSettings.Mode.network, .both] {
            #expect(now(job: mode, saved: nil) == .darkbloomStopped, "a plist an older build wrote, nothing saved")
            #expect(now(job: nil, saved: mode) == .darkbloomStopped, "saved, no plist")
            #expect(now(job: mode, saved: mode) == .darkbloomStopped)
            #expect(now(job: .local, saved: mode) == .darkbloomStopped, "the saved choice is what `start` serves again")
            #expect(now(job: mode, saved: .local) == .nothing, "saved Only me: starting it again changes no choice")
            #expect(now(job: mode, saved: mode, live: true) == .onlyMe, "Only me answering in a terminal is shown")
        }
        #expect(now(job: .local, saved: nil) == .nothing)
        #expect(now(job: nil, saved: .local) == .nothing)
        #expect(now(job: nil, saved: nil) == .nothing)
        #expect(Local.plan(json: false, paired: false, pairServesLocalOnly: false, serving: .darkbloomStopped)
            == .offerSwitchWhileStopped)
        #expect(Local.plan(json: true, paired: false, pairServesLocalOnly: false, serving: .darkbloomStopped) == .show)
        #expect(Local.stoppedLine == "Darkbloom is stopped on this Mac; `darkbloom start` serves it again.")
        #expect(Local.stoppedSwitchQuestion == "Switch this Mac to local only instead (Darkbloom stays stopped)? [y/N] ")
    }

    /// `Local.run` as wired, in a child process: the reader, how the Mac serves and starting Only me are stand-ins, and
    /// the installed job is a plist in a scratch home. Only a terminal's yes ever starts Only me; without a terminal
    /// nothing is read or asked, and a stopped Darkbloom Mac ends with exit 1 and one line.
    @Test("run: Darkbloom serving or stopped is switched only by a terminal's yes, with the job's models")
    func runSwitchesOnlyOnATerminalsYes() async throws {
        let result = await #expect(
            processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]
        ) {
            endChildAfter(seconds: 60)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-run-\(UUID().uuidString)", isDirectory: true)
            let agents = scratch.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", scratch.path, 1)  // no local.json: no local API answers
            setenv("DARKBLOOM_STATE_FILE", scratch.appendingPathComponent("daemon-state.json").path, 1)
            keepCommandsOffThisMacsCluster()
            let job = LaunchAgent.serviceProgramArguments(
                binaryPath: "/Applications/Darkbloom.app/Contents/MacOS/darkbloom",
                coordinatorURL: "wss://coordinator.invalid/ws/provider", models: ["fixture/model"], configPath: nil,
                localEndpoint: LaunchAgent.LocalEndpointOptions())
            let plist: [String: Any] = ["Label": LaunchAgent.label, "ProgramArguments": job, "RunAtLoad": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: agents.appendingPathComponent("\(LaunchAgent.label).plist"))

            func run(_ serving: Local.ServingNow, terminal: Bool, answer: String?) async throws -> Bool {
                var command = try Local.parse([])
                let prompt = Local.Prompt(isTerminal: terminal, readLine: {
                    FileHandle.standardError.write(Data("<read>\n".utf8))
                    return answer
                })
                do {
                    try await LaunchctlControl.$homeDirectoryForTesting.withValue(scratch) {
                        try await Local.$servingNowForTesting.withValue({ serving }) {
                            try await Local.$promptForTesting.withValue(prompt) {
                                try await Local.$startOnlyMeForTesting.withValue({ models in
                                    FileHandle.standardError.write(Data("<start Only me \(models)>\n".utf8))
                                }) {
                                    try await command.run()
                                }
                            }
                        }
                    }
                    return true
                } catch let code as ExitCode where code == .failure {
                    return false
                }
            }
            var outcomes: [Bool] = []
            for (serving, terminal, answer) in [
                (Local.ServingNow.darkbloom, false, "y"), (.darkbloom, true, ""), (.darkbloom, true, nil),
                (.darkbloom, true, "y"), (.darkbloomStopped, false, "y"), (.darkbloomStopped, true, "n"),
                (.darkbloomStopped, true, "y"),
            ] as [(Local.ServingNow, Bool, String?)] {
                outcomes.append(try await run(serving, terminal: terminal, answer: answer))
            }
            try? FileManager.default.removeItem(at: scratch)
            // No local API answers here, so every run ends with exit 1, the two yeses after starting Only me.
            exit(outcomes == Array(repeating: false, count: 7) ? 0 : 1)
        }
        let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.components(separatedBy: "<start Only me [\"fixture/model\"]>\n").count - 1 == 2,
                "only the two terminal yeses start Only me, with the job's models: \(stderr)")
        #expect(stderr.components(separatedBy: "<read>\n").count - 1 == 5, "never read without a terminal")
        #expect(stdout.components(separatedBy: Local.switchQuestion).count - 1 == 3)
        #expect(stdout.components(separatedBy: Local.stoppedSwitchQuestion).count - 1 == 2)
        #expect(stderr.components(separatedBy: Local.stoppedLine + "\n").count - 1 == 3)
    }

    @Test("what local does: starts Only me where nothing serves, offers to switch where Darkbloom serves, shows otherwise")
    func plan() {
        #expect(Local.plan(json: false, paired: false, pairServesLocalOnly: false, serving: .nothing) == .startOnlyMe)
        #expect(Local.plan(json: false, paired: false, pairServesLocalOnly: false, serving: .onlyMe) == .show)
        #expect(Local.plan(json: false, paired: false, pairServesLocalOnly: false, serving: .darkbloom) == .offerSwitch)
        // --json only reads, as before: a tool that looks for the address never starts or stops anything.
        for serving in [Local.ServingNow.nothing, .onlyMe, .darkbloom] {
            #expect(Local.plan(json: true, paired: false, pairServesLocalOnly: false, serving: serving) == .show)
            #expect(Local.plan(json: true, paired: true, pairServesLocalOnly: false, serving: serving) == .show)
            // A paired Mac: the pair is never touched; `cluster local` serves it locally only.
            #expect(Local.plan(json: false, paired: true, pairServesLocalOnly: false, serving: serving)
                == .pointToClusterLocal)
            #expect(Local.plan(json: false, paired: true, pairServesLocalOnly: true, serving: serving) == .show)
        }
        #expect(Local.pairedLine == "This Mac is in a two-Mac cluster: `darkbloom cluster local` serves the pair on its "
            + "local API only.")
        // --json and a paired Mac never read how this Mac serves alone.
        func unread() -> Local.ServingNow {
            Issue.record("read how this Mac serves")
            return .nothing
        }
        #expect(Local.plan(json: true, paired: false, pairServesLocalOnly: false, serving: unread()) == .show)
        #expect(Local.plan(json: false, paired: true, pairServesLocalOnly: false, serving: unread())
            == .pointToClusterLocal)
    }

    @Test("the switch is asked only in a terminal, and only yes switches")
    func switchQuestion() {
        #expect(Local.switchQuestion == "Switch this Mac to local only (stops serving Darkbloom)? [y/N] ")
        var asked = ""
        #expect(!Local.asksToSwitch(terminal: false, readInput: { Issue.record("read without a terminal"); return "y" },
                                    emit: { asked += $0 }))
        #expect(asked.isEmpty, "without a terminal nothing is asked or printed")
        for (answer, switches) in [("y", true), ("Y", true), ("yes", true), (" Yes ", true), ("", false), ("n", false),
                                   ("no", false), ("1", false), ("sure", false)] {
            var transcript = ""
            #expect(Local.asksToSwitch(terminal: true, readInput: { answer }, emit: { transcript += $0 }) == switches,
                    "\(answer)")
            #expect(transcript == Local.switchQuestion, "\(answer)")
        }
        var ended = ""
        #expect(!Local.asksToSwitch(terminal: true, readInput: { nil }, emit: { ended += $0 }))
        #expect(ended == Local.switchQuestion + "\n", "the end of input keeps Darkbloom serving")
    }

    @Test("where Darkbloom serves without a local API, local says so and how to add one")
    func networkOnlyLines() {
        #expect(Local.networkOnlyLines == [
            "This Mac serves the Darkbloom network, with no local API.",
            "  `darkbloom start --local-endpoint --no-me-first` adds one beside Darkbloom.",
        ])
        #expect(Local.notRunningHint == [
            "Start one with:  darkbloom local                                 (only you, on this Mac)",
            "             or: darkbloom start --local-endpoint --no-me-first  (Darkbloom and you)",
        ])
    }

    @Test("local starts Only me as `start --local` does: in the background, with the models named or the job's")
    func startsOnlyMeInTheBackground() throws {
        #expect(Local.onlyMeStartArguments(models: []) == ["--local"])
        #expect(Local.onlyMeStartArguments(models: ["a/x", "b/y"]) == ["--local", "--model", "a/x", "--model", "b/y"])
        let start = try Start.parse(Local.onlyMeStartArguments(models: ["a/x"]))
        #expect(start.local && !start.here && !start.foreground && start.model == ["a/x"])
        #expect(Start.singleMacServing(mode: .local, here: start.here, foreground: start.foreground) == .onlyMeService)
        #expect(!ProviderAppKitHost.shouldHost(["start"] + Local.onlyMeStartArguments(models: []),
                                               startedByAService: { false }), "it sets the service up and returns")
        // The switch keeps the models Darkbloom served; models named with --model win.
        #expect(Local.switchModels(named: [], installed: ["a/x", "b/y"]) == ["a/x", "b/y"])
        #expect(Local.switchModels(named: ["c/z"], installed: ["a/x"]) == ["c/z"])
        #expect(Local.switchModels(named: [], installed: nil).isEmpty)
    }

    @Test("local takes --model, and --json still only reads")
    func options() throws {
        let local = try #require(try Darkbloom.parseAsRoot(["local", "--model", "a/x", "--model", "b/y"]) as? Local)
        #expect(local.model == ["a/x", "b/y"] && !local.json)
        #expect(try Local.parse(["--json"]).json)
    }
}
