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
        #expect(Local.servingNow(running: F.state(connected: false), alive: alive, loadedJob: nil, liveLocalAPI: true)
            == .onlyMe)
        #expect(Local.servingNow(running: F.state(), alive: alive, loadedJob: .local, liveLocalAPI: false) == .darkbloom,
                "a running provider that serves Darkbloom, without a local API")
        #expect(Local.servingNow(running: F.state(meFirst: F.open), alive: alive, loadedJob: nil, liveLocalAPI: true)
            == .darkbloom, "Both")
        // Between two runs of its job (a crash, a restart) launchd starts it again: still Darkbloom's.
        for mode in [LocalSettings.Mode.network, .both] {
            #expect(Local.servingNow(running: F.state(), alive: dead, loadedJob: mode, liveLocalAPI: false) == .darkbloom)
            #expect(Local.servingNow(running: nil, alive: dead, loadedJob: mode, liveLocalAPI: false) == .darkbloom)
        }
        #expect(Local.servingNow(running: nil, alive: dead, loadedJob: .local, liveLocalAPI: false) == .onlyMe)
        // `start --local --here` in another terminal: no job, but its API answers.
        #expect(Local.servingNow(running: nil, alive: dead, loadedJob: nil, liveLocalAPI: true) == .onlyMe)
        #expect(Local.servingNow(running: F.state(), alive: dead, loadedJob: nil, liveLocalAPI: false) == .nothing)
        #expect(Local.servingNow(running: nil, alive: dead, loadedJob: nil, liveLocalAPI: false) == .nothing)
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
            "Start one with:  darkbloom local                                (only you, on this Mac)",
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
