import Foundation
import Darwin

/// The owner's simpler onboarding (2026-11-11, after onboarding a user to clustering on 0.10.11): the other Mac's command
/// set apart and stressed; `darkbloom cluster` serves Both (Darkbloom keeps serving while the owner uses the pair's local
/// API) with no serving question; tensor parallel or pipeline chosen for the person (`darkbloom cluster local` keeps the
/// question, the choice tagged Recommended); one standout ✓ line and one hint at the end, the card in `darkbloom status`;
/// "Press Enter to exit" on an interactive terminal only.
extension OnboardingChecks {
    static func simplerOnboardingChecks() {
        theOtherMacsCommandIsSetApart()
        tensorParallelUnlessItCantOrIsMeasuredSlower()
        theFirstSetupServesBothWithNoQuestionsAndEndsOnOneLine()
        clusterLocalTagsTheRecommendedModeAndEndsWithItsAPI()
        aLocalPairServesBothWhenClusterRuns()
        withoutALoginTheHintNamesClusterLocal()
        theJoiningMacEndsTheSameWay()
        anInteractiveTerminalWaitsForEnter()
        // The review of #2007 (2026-11-11): each of these failed, or let a mutant live, on b40ccc33dc.
        aCancelledRunLeavesLocalAsItWas()
        theServingOfferedPairEndsOnTheSameLine()
        aServingNetworkPairSwitchesAtOnceAndSavesFirst()
        aStoppedPairKeepsTheModeItLastServedIn()
        ciNeverWaitsForEnter()
        theScreenLockIsReleasedBeforeTheWait()
        noTensorParallelTakesThePlannersFirstThatCanRun()
    }

    /// Gemma 4 26B on these Macs: both modes, neither measured yet.
    static let twoModes = [
        ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["15.6 GB · pipeline · this Mac 6 layers / the other Mac 24 layers"],
            blocker: nil, modelID: "gemma-4-26b-qat-4bit", validated: true, split: "pipeline",
            modes: [.init(mode: "pipeline_v1", split: "this Mac 6 layers / the other Mac 24 layers", measuredTokensPerSecond: nil,
                          concurrentRequests: 1, contextTokens: 65_536, promptTokens: 32_768),
                    .init(mode: "tensor_parallel_v1", split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: nil,
                          concurrentRequests: 8, contextTokens: 262_144)])]

    static let servingGemma = "Serving Gemma 4 26B on both Macs"

    /// The first Mac's last line while it waits: blank lines around it, and in a colour terminal bold with the command in
    /// the brand's colour; `darkbloom cluster local` names its own command.
    static func theOtherMacsCommandIsSetApart() {
        typealias P = ClusterOnboardingPairing
        expect(P.otherMacLine == "\u{2192} Now run `darkbloom cluster` on the other Mac", "callout: \(P.otherMacLine)")
        expect(P.otherMacCallout(localOnly: true) == "\u{2192} Now run `darkbloom cluster local` on the other Mac", "callout: local")
        var local = P(localOnly: true)
        expect(local.handle(.waitingAsLeader) == [P.otherMacCallout(localOnly: true)], "callout: the local pairing says its command")
        expect(local.working?.contains("`darkbloom cluster local` there") == true, "callout: the live line too")

        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor("\n\n  " + P.otherMacLine + "\n\n"), "callout: plain, set apart by blank lines: \(run.text)")
        run.type("q")
        _ = run.finish()

        let colour = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")),
                                 environment: colourTerminal)
        expect(colour.waitFor("  \u{1B}[1m\u{2192} Now run \u{1B}["), "callout: colour, bold: \(colour.text.suffix(400))")
        expect(colour.waitFor("`darkbloom cluster`\u{1B}[39m on the other Mac\u{1B}[0m"), "callout: colour, the command coloured")
        colour.type("q")
        _ = colour.finish()
    }

    static func tensorParallelUnlessItCantOrIsMeasuredSlower() {
        typealias M = ClusterOnboardingMode
        let tp = "tensor_parallel_v1", pp = "pipeline_v1"
        func pick(_ modes: [M], darkbloom: Bool = true, serving: Bool = false) -> String? {
            M.automaticIndex(modes, throughDarkbloom: darkbloom, serving: serving).map { modes[$0].mode }
        }
        // Not measured yet (or the link not measured): tensor parallel, whatever the planner's order.
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: nil), M(mode: tp, split: nil, measuredTokensPerSecond: nil)]) == tp,
               "auto: not measured: tensor parallel")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: 64), M(mode: tp, split: nil, measuredTokensPerSecond: nil)]) == tp,
               "auto: tensor parallel not measured: still tensor parallel")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: 64), M(mode: tp, split: nil, measuredTokensPerSecond: 111)]) == tp,
               "auto: measured faster")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: 104), M(mode: tp, split: nil, measuredTokensPerSecond: 100)]) == tp,
               "auto: within 5 % counts as the same speed")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: 120), M(mode: tp, split: nil, measuredTokensPerSecond: 100)]) == pp,
               "auto: measured slower here: pipeline")
        // Can't run: no tensor-parallel plan, or it doesn't fit now while the pipeline does.
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: nil)]) == pp, "auto: pipeline only")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: nil, fitsNow: true),
                     M(mode: tp, split: nil, measuredTokensPerSecond: nil, fitsNow: false)]) == pp, "auto: tensor parallel doesn't fit now")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: nil, fitsNow: true),
                     M(mode: tp, split: nil, measuredTokensPerSecond: nil, fitsNow: false)], serving: true) == tp,
               "auto: a model serving frees its memory first, so fitting now doesn't decide")
        expect(pick([M(mode: pp, split: nil, measuredTokensPerSecond: nil, fitsNow: false),
                     M(mode: tp, split: nil, measuredTokensPerSecond: nil, fitsNow: false)]) == tp, "auto: nothing fits: tensor parallel")
        // Through Darkbloom, a mode Darkbloom serves publicly; locally, that doesn't count.
        let unserved = [M(mode: pp, split: nil, measuredTokensPerSecond: nil, publicTraffic: true),
                        M(mode: tp, split: nil, measuredTokensPerSecond: nil, publicTraffic: false)]
        expect(pick(unserved) == pp && pick(unserved, darkbloom: false) == tp, "auto: public traffic counts through Darkbloom only")
        expect(M.automaticIndex([], throughDarkbloom: true, serving: false) == nil, "auto: no modes")
        // The cluster-local question's line: the tag, no recommendation sentence, no speed.
        let line = ClusterOnboardingDriver.modeLine(twoModes[0].modes![1], recommended: true)
        expect(line == "Tensor parallel · Recommended · serves up to 8 requests at once · context 262,144 tokens", "auto: the tagged line: \(line)")
    }

    /// `darkbloom cluster` from scratch: pairing, then the list (no mode in it), the start in tensor parallel with no
    /// question, Both saved, and one ✓ line with one hint; no card.
    static func theFirstSetupServesBothWithNoQuestionsAndEndsOnOneLine() {
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                              choices: twoModes)
        made.servesBoth = { true }
        made.saveServingChoice = { choice in recorder.note("saveServingChoice \(choice.rawValue)"); return .success([]) }
        made.useMode = { index, mode in recorder.note("useMode \(index) \(mode)") }
        let run = TerminalRun(made)
        expect(run.waitFor("  Code 123 456. " + codeQuestion + "\n  1) Yes\n  2) No\n  " + prompt(2)), "first: the pairing first")
        run.type("y")
        expect(run.waitFor("  1) Gemma 4 26B · 15.6 GB\n"), "first: the list, no mode in its line: \(run.text)")
        run.type("\r")
        expect(run.finish() == 0, "first: exit 0")
        let text = run.text
        expect(!text.contains("How should this pair serve?") && !text.contains("How should both Macs split"), "first: no questions")
        expect(recorder.all.contains("useMode 0 tensor_parallel_v1"), "first: tensor parallel: \(recorder.all)")
        expect(recorder.all.contains("setScope both 0.0.0.0") && recorder.all.contains("saveServingChoice both"), "first: Both saved: \(recorder.all)")
        expect(text.contains(block("\u{2713}", servingGemma, []) + "  " + ClusterOnboardingDriver.statusHint + "\n"),
               "first: the ✓ alone in its block, then the hint: \(text)")
        expect(!text.contains("Logs:") && !text.contains("Stop both Macs") && !text.contains("Test response"), "first: no card")
        expect(!text.contains(ClusterOnboardingDriver.exitLine), "first: a plain transcript never waits for Enter")
        transcript("simpler-first-setup", text, keys: run.keys)
    }

    /// `darkbloom cluster local`: the mode question stays, both modes listed, the tag on tensor parallel, preselected;
    /// the ✓ line names the local API.
    static func clusterLocalTagsTheRecommendedModeAndEndsWithItsAPI() {
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                              choices: twoModes, readyResult: .success(.init(servedBy: "this Mac", port: 8000, split: "tensor parallel")))
        made.useMode = { index, mode in recorder.note("useMode \(index) \(mode)") }
        let run = TerminalRun(made, request: .init(scope: .localOnly(bind: "0.0.0.0")))
        expect(run.waitFor("  \u{2192} Now run `darkbloom cluster local` on the other Mac\n"), "local: the callout names cluster local")
        run.type("y")
        expect(run.waitFor("  " + prompt(1)), "local: the list")
        run.type("\r")
        expect(run.waitFor("  How should both Macs split Gemma 4 26B?\n"
            + "  1) Pipeline · serves one request at a time · context 65,536 tokens, prompts up to 32,768\n"
            + "  2) Tensor parallel · Recommended · serves up to 8 requests at once · context 262,144 tokens\n"
            + "  " + prompt(2, enter: 2)), "local: both modes, the tag, preselected: \(run.text)")
        expect(!run.text.contains("Recommended for "), "local: no recommendation sentence")
        run.type("\r")
        expect(run.finish() == 0, "local: exit 0")
        expect(recorder.all.contains("useMode 0 tensor_parallel_v1"), "local: Enter took tensor parallel: \(recorder.all)")
        expect(run.text.contains(block("\u{2713}", servingGemma + ", on your local API at http://localhost:8000", [])),
               "local: the ✓ line names the API: \(run.text)")
        transcript("simpler-cluster-local", run.text, keys: run.keys)
    }

    /// A pair saved as Only me: `darkbloom cluster` serves it Both, said in one line, through the switch's own start; the
    /// list has no "Change how the pair serves".
    static func aLocalPairServesBothWhenClusterRuns() {
        let recorder = Recorder()
        var resume = gemmaStopped
        resume.scope = .localOnly(bind: "0.0.0.0")
        var made = operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([]), choices: twoModes)
        made.servesBoth = { true }
        made.saveServingChoice = { choice in recorder.note("saveServingChoice \(choice.rawValue)"); return .success([]) }
        let run = TerminalRun(made)
        expect(run.waitFor("  " + ClusterOnboardingDriver.switchToBothLine(from: .localOnly(bind: "0.0.0.0")) + "\n"),
               "only me: one line says it now serves Both: \(run.text)")
        expect(run.waitFor("  1) Gemma 4 26B · 15.6 GB · last used\n  2) " + ClusterOnboardingDriver.startOverItem + "\n  " + prompt(2)),
               "only me: the list, the model and Start over only: \(run.text)")
        expect(!run.text.contains("Change how the pair serves") && !run.text.contains("Switch to"), "only me: no serving line")
        run.type("\r")
        expect(run.finish() == 0, "only me: exit 0")
        expect(recorder.all.contains("setScope both 0.0.0.0"), "only me: saved Both: \(recorder.all)")
        expect(run.text.contains(block("\u{2713}", servingGemma, [])), "only me: the ✓ line: \(run.text)")
    }

    /// No login: Log in or Cancel, and the one line that names `darkbloom cluster local`; never "Serve locally only".
    static func withoutALoginTheHintNamesClusterLocal() {
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                              choices: twoModes, missingLogins: [ClusterOnboardingMacName.this], loginSucceeds: false)
        made.servesBoth = { true }
        let run = TerminalRun(made)
        expect(run.waitFor(codeQuestion), "login: the code")
        run.type("y")
        expect(run.waitFor("  " + prompt(1)), "login: the list")
        run.type("\r")
        expect(run.waitFor("  " + ClusterOnboardingDriver.localPairHint + "\n  1) Log in on this Mac\n  2) Cancel\n"),
               "login: the hint, then Log in or Cancel: \(run.text)")
        run.type("2")
        expect(run.finish() == 0, "login: Cancel changes nothing")
        expect(!run.text.contains("Serve locally only"), "login: no local choice")
        expect(ClusterOnboardingDriver.notServingItems == ["Retry", "Change model", "Diagnostics"], "not serving: no local choice")
    }

    /// The joining Mac ends with the leading Mac's ✓ line and the same hint; never "You can close this window.".
    static func theJoiningMacEndsTheSameWay() {
        for (status, title) in [
            (["Serving Gemma 4 26B through Darkbloom on both Macs (tensor parallel).", "Test response in 0.61 s (the leading Mac's test)"], servingGemma),
            (["Serving Gemma 4 26B (tensor parallel) at http://localhost:8000 (local only).", "Test response in 0.61 s (the leading Mac's test)"],
             servingGemma + ", on your local API at http://localhost:8000"),
        ] {
            expect(ClusterOnboardingReady.endingTitle(inStatusLine: status[0]) == title, "joined: \(status[0]) → \(title)")
        }
        expect(ClusterOnboardingReady.endingTitle(inStatusLine: "Serving M at http://localhost:8001 on the other Mac (local only).")
               == "Serving M on both Macs, on your local API at http://localhost:8001 on the other Mac", "joined: the API on the other Mac")
        expect(ClusterOnboardingReady.endingTitle(inStatusLine: "Stopped.") == nil, "joined: not a serving line")
        let recorder = Recorder()
        let served = ["Serving Gemma 4 26B through Darkbloom on both Macs (tensor parallel).", "Test response in 0.61 s (the leading Mac's test)"]
        let run = TerminalRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: "Apple M3 Ultra, 256 GB"),
                                         statusLines: served, followSeconds: 5))
        expect(run.waitFor(codeQuestion), "joined: the code")
        run.type("y")
        expect(run.finish(seconds: 20) == 0, "joined: exit 0")
        expect(run.text.contains(block("\u{2713}", servingGemma, []) + "  " + ClusterOnboardingDriver.statusHint + "\n"),
               "joined: the same ✓ and hint: \(run.text)")
        expect(!run.text.contains("You can close this window"), "joined: no close-window line")
        transcript("simpler-joined", run.text, keys: run.keys)
    }

    /// Only an interactive (colour) terminal waits after the ✓: "Press Enter to exit.", and Enter ends it.
    static func anInteractiveTerminalWaitsForEnter() {
        let recorder = Recorder()
        var made = operations(recorder, resume: gemmaStopped, pairEvents: [], pairResult: .failed([]), choices: twoModes)
        made.servesBoth = { true }
        let run = TerminalRun(made, environment: colourTerminal, pressesEnterToExit: false)
        expect(run.waitFor(arrowHint), "enter: the list")
        run.type("\r")
        expect(run.waitFor(ClusterOnboardingDriver.exitLine), "enter: the line: \(run.text.suffix(600))")
        usleep(300_000)
        expect(run.code == nil, "enter: still waiting")
        run.type("\r")
        expect(run.finish() == 0, "enter: Enter exits")
        expect(run.text.contains("\u{1B}[1;32m\u{2713} " + servingGemma + "\u{1B}[0m"), "enter: the ✓ line bold green")
    }

    /// Records `saveServingChoice` as the live operations' `[local]` write, with the line it says.
    static func savesBoth(_ made: inout ClusterOnboardingOperations, _ recorder: Recorder, said: [String] = []) {
        made.servesBoth = { true }
        made.saveServingChoice = { choice in recorder.note("saveServingChoice \(choice.rawValue)"); return .success(said) }
    }

    /// MF1: `[local]` is written only once the pair switches or starts; a run that changes nothing (Cancel at the login
    /// check, q at the list) leaves it as it was, and says "Nothing changed." truthfully.
    static func aCancelledRunLeavesLocalAsItWas() {
        var onlyMe = gemmaStopped
        onlyMe.scope = .localOnly(bind: "0.0.0.0")
        let recorder = Recorder()
        var made = operations(recorder, resume: onlyMe, pairEvents: [], pairResult: .failed([]), choices: twoModes,
                              missingLogins: [ClusterOnboardingMacName.this], loginSucceeds: false)
        savesBoth(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  " + prompt(2)), "cancel: the list"); run.type("\r")
        expect(run.waitFor("  1) Log in on this Mac\n  2) Cancel\n"), "cancel: the login check: \(run.text)"); run.type("2")
        expect(run.finish() == 0 && run.text.hasSuffix("Nothing changed.\n"), "cancel: nothing changed: \(run.text)")
        expect(!recorder.all.contains { $0.hasPrefix("saveServingChoice") || $0.hasPrefix("setScope") }, "cancel: [local] untouched: \(recorder.all)")

        let quit = Recorder()
        var left = operations(quit, resume: onlyMe, pairEvents: [], pairResult: .failed([]), choices: twoModes)
        savesBoth(&left, quit)
        let q = TerminalRun(left)
        expect(q.waitFor("  " + prompt(2)), "q: the list"); q.type("q")
        _ = q.finish()
        expect(!quit.all.contains { $0.hasPrefix("saveServingChoice") }, "q: [local] untouched: \(quit.all)")
        // A start saves it once it goes ahead: after the adopt, before the parts start (they read it).
        let started = Recorder()
        var start = operations(started, resume: onlyMe, pairEvents: [], pairResult: .failed([]), choices: twoModes)
        savesBoth(&start, started)
        let go = TerminalRun(start)
        expect(go.waitFor("  " + prompt(2)), "start: the list"); go.type("\r")
        expect(go.finish() == 0, "start: served")
        let calls = started.all
        let order = ["adopt 0", "saveServingChoice both", "serve"].map { calls.firstIndex(of: $0) }
        expect(!order.contains(nil) && order == order.sorted { ($0 ?? 0) < ($1 ?? 0) }, "start: saved after the adopt, before the start: \(calls)")
    }

    /// MF2: Enter on the model a pair Darkbloom has serves (no local test from this Mac) ends on the same ✓ line, the hint
    /// and the wait, and saves Both then, saying the pause ends at the pair's next start.
    static func theServingOfferedPairEndsOnTheSameLine() {
        var both = qwenServing
        both.scope = .publicServingWithLocalAPI(bind: "0.0.0.0")
        let recorder = Recorder()
        let next = "Darkbloom keeps serving while you use the pair's local API from the pair's next start."
        var made = operations(recorder, resume: both, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
                              testResult: .failure(.init([ClusterOnboardingReady.offeredTestLine])),
                              statusLines: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."])
        savesBoth(&made, recorder, said: [next])
        let run = TerminalRun(made)
        expect(run.waitFor("  1) Qwen 3.8 27B · 16.3 GB · serving now\n"), "offered re-run: the list: \(run.text)"); run.type("\r")
        expect(run.finish() == 0, "offered re-run: exit 0")
        expect(run.text.hasSuffix("  " + next + "\n" + ending("Serving Qwen 3.8 27B on both Macs")) && !run.text.contains("Already serving")
               && !run.text.contains("  darkbloom stop     Stop both Macs"), "offered re-run: the pause line, then the ✓ line and the hint: \(run.text)")
        expect(recorder.all.contains("saveServingChoice both") && !recorder.all.contains { $0.hasPrefix("adopt") || $0.hasPrefix("setScope") },
               "offered re-run: saved, nothing reloaded: \(recorder.all)")
    }

    /// m6: a serving pair saved for the Darkbloom network alone switches to Both at once, said in one line; `[local]` is
    /// saved before the leading part starts again (it reads it then).
    static func aServingNetworkPairSwitchesAtOnceAndSavesFirst() {
        let recorder = Recorder()
        var made = operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
                              readyResult: .success(qwenOffered))
        savesBoth(&made, recorder)
        let run = TerminalRun(made)
        expect(run.finish() == 0, "network to Both: exit 0, no key: \(run.text)")
        expect(run.text.contains("  " + ClusterOnboardingDriver.switchToBothLine(from: .publicServing) + "\n")
               && !run.text.contains("  1) Qwen"), "network to Both: one line, no list: \(run.text)")
        let calls = recorder.all
        let saved = calls.firstIndex(of: "saveServingChoice both"), switched = calls.firstIndex(of: "setScope both 0.0.0.0")
        expect(saved != nil && switched != nil && saved! < switched!, "network to Both: saved, then switched: \(calls)")
        expect(run.text.hasSuffix(ending("Serving Qwen 3.8 27B on both Macs")), "network to Both: the ✓ ending: \(run.text)")
    }

    /// m8 / the owner's decision: a stopped pair started again from the screen keeps the mode it last served in (no
    /// pipeline → tensor parallel flip); the rule picks for other models.
    static func aStoppedPairKeepsTheModeItLastServedIn() {
        var piped = gemmaStopped
        piped.servingMode = "pipeline_v1"
        piped.scope = .publicServingWithLocalAPI(bind: "0.0.0.0")
        let recorder = Recorder()
        var made = operations(recorder, resume: piped, pairEvents: [], pairResult: .failed([]), choices: twoModes,
                              statusLines: ["Stopped; last model Gemma 4 26B."])
        savesBoth(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  1) Gemma 4 26B · 15.6 GB · last used\n"), "stopped: the list: \(run.text)"); run.type("\r")
        expect(run.finish() == 0, "stopped: started")
        expect(recorder.all.contains("useMode 0 pipeline_v1") && !recorder.all.contains("useMode 0 tensor_parallel_v1"),
               "stopped: the mode it last served in: \(recorder.all)")
    }

    /// m1: `CI` set means no person at the terminal, colour or not: the run ends without waiting.
    static func ciNeverWaitsForEnter() {
        var made = operations(Recorder(), resume: gemmaStopped, pairEvents: [], pairResult: .failed([]), choices: twoModes)
        made.servesBoth = { true }
        let run = TerminalRun(made, environment: colourTerminal.merging(["CI": "true"]) { $1 }, pressesEnterToExit: false)
        expect(run.waitFor(arrowHint), "CI: the list"); run.type("\r")
        expect(run.finish() == 0 && !run.text.contains(ClusterOnboardingDriver.exitLine), "CI: no wait: \(run.text.suffix(300))")
    }

    /// SF2: the screen's lock is let go before "Press Enter to exit." waits, so another window's command isn't refused.
    static func theScreenLockIsReleasedBeforeTheWait() {
        var primary: Int32 = -1, secondary: Int32 = -1
        var window = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        precondition(openpty(&primary, &secondary, nil, nil, &window) == 0)
        defer { close(primary); close(secondary) }
        let released = Recorder()
        let done = DispatchSemaphore(value: 0)
        let terminal = secondary
        Thread.detachNewThread {
            let console = ClusterOnboardingTerminal(input: terminal, output: terminal, environment: colourTerminal)
            console.beforeExitWait = { released.note("released") }
            console.waitForExit()
            console.restore()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while released.all.isEmpty, Date() < deadline { usleep(10_000) }
        expect(released.all == ["released"] && done.wait(timeout: .now() + 0.3) == .timedOut, "lock: released while it waits")
        _ = Darwin.write(primary, "\r", 1)
        expect(done.wait(timeout: .now() + 5) == .success, "lock: Enter ends the wait")
    }

    /// m3: with no tensor-parallel mode that can run, the planner's first mode that can (docs say the same).
    static func noTensorParallelTakesThePlannersFirstThatCanRun() {
        typealias M = ClusterOnboardingMode
        let modes = [M(mode: "pipeline_v1", split: nil, measuredTokensPerSecond: nil, fitsNow: false),
                     M(mode: "pipeline_mtp_v1", split: nil, measuredTokensPerSecond: nil, fitsNow: true)]
        expect(M.automaticIndex(modes, throughDarkbloom: true, serving: false) == 1, "no TP: the first that fits")
    }
}
