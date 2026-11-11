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
}
