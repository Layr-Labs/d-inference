import Foundation
import Darwin

/// A pair served through Darkbloom gets the single-Mac start's three choices (local-first L5b): Only me (this pair,
/// local), Darkbloom network, or Both, me first, where the pair's leader also runs its local API and Darkbloom pauses
/// while the owner uses it. Asked in a terminal by plain `darkbloom cluster` only: in the first setup, Both preselected
/// (or the saved answer), and from the set-up pair's list, the way it serves now preselected. The answer is saved
/// (`[local] mode`) with the scope, once the start goes ahead. No line quotes a speed.
extension OnboardingChecks {
    static func bothMeFirstChecks() {
        theFirstSetupAsksHowThePairServesWithBothPreselected()
        eachAnswerServesThePairThatWay()
        aSavedAnswerIsPreselectedWithItsIdleMinutes()
        leavingTheQuestionChangesNothing()
        withoutTheQuestionTheFirstSetupIsTodays()
        theListOffersTheSameThreeChoices()
        theWayItServesNowChangesNothing()
        aPairServingBothSwitchesToLocalOnly()
        aLocalPairSwitchesToBothFromAPlanMadeForDarkbloom()
        theLoginChecksServeLocallyOnlySavesNoAnswer()
        aPairServingBothSwitchesToTheDarkbloomNetwork()
        quittingAtTheListAfterAnsweringSavesNothing()
        quittingTheListsQuestionChangesNothing()
        theOtherMacsCardNamesItsOwnAPI()
    }

    /// The other Mac's screen (its own `darkbloom cluster`, which the leading Mac answers): with the pair's API on every
    /// address, that Mac answers on its own port too (its relay), so its card names its own API, as the leading Mac's
    /// does: its address once this Mac's port is up, else where to find it. With the API kept on the leading Mac
    /// (loopback or one address), the card points there, as before.
    static func theOtherMacsCardNamesItsOwnAPI() {
        let there = ClusterOnboardingMacName.other(named: "Apple M5 Ultra, 256 GB")
        let everyAddress = ClusterServingScope.publicServingWithLocalAPI(bind: "0.0.0.0")
        expect(everyAddress.answersOnEveryMac && ClusterServingScope.localOnly(bind: "0.0.0.0").answersOnEveryMac,
               "every address: every Mac answers")
        for bind in ["127.0.0.1", "::1", "192.168.1.5"] {
            expect(!ClusterServingScope.publicServingWithLocalAPI(bind: bind).answersOnEveryMac, "\(bind): the leading Mac only")
        }
        expect(!ClusterServingScope.publicServing.answersOnEveryMac, "Darkbloom network: no API anywhere")
        let relayed = ClusterOnboardingReady(servedBy: there, port: 0, offered: "offered for pairing", relayed: true)
        expect(relayed.outcome(model: "m", scope: everyAddress, test: "in 0.61 s").lines == [bothAPILineHere, "Test response in 0.61 s"],
               "relayed: the other Mac's card names its own API: \(relayed.outcome(model: "m", scope: everyAddress, test: "in 0.61 s").lines)")
        let kept = ClusterOnboardingReady(servedBy: there, port: 0, offered: "offered for pairing")
        expect(kept.bothAPILine == "Local API: on \(there), you first (Darkbloom pauses while you use it; `darkbloom local` there "
               + "shows its address and key)", "kept on the leading Mac: \(kept.bothAPILine)")
        let leading = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.this, port: 0, offered: "offered for pairing", relayed: true)
        expect(leading.bothAPILine == bothAPILineHere, "the leading Mac's card, its API not up yet: \(leading.bothAPILine)")
        // Each Mac's card prints its own address once its port is up: rank 0's API, or the other Mac's relay.
        for (servedBy, port) in [(ClusterOnboardingMacName.this, 8002), (there, 8001), (there, 8000)] {
            let up = ClusterOnboardingReady(servedBy: servedBy, port: port, offered: "offered for pairing", relayed: true)
            expect(up.bothAPILine == bothAPILine(port: port), "\(servedBy) on \(port): \(up.bothAPILine)")
        }
        expect(bothAPILine(port: 8001) == "Local API: http://127.0.0.1:8001/v1 on this Mac, you first (Darkbloom pauses "
               + "while you use it; `darkbloom local` shows the key)", "the address, never the key")
        let keptUp = ClusterOnboardingReady(servedBy: there, port: 8003, offered: "offered for pairing")
        expect(keptUp.bothAPILine == kept.bothAPILine, "kept on the leading Mac: no address of this Mac's: \(keptUp.bothAPILine)")
    }

    /// Plain `darkbloom cluster` in a terminal: the question is asked, and its answer saved, as the live operations do.
    static func asking(_ made: inout ClusterOnboardingOperations, _ recorder: Recorder,
                       saved: ClusterServingChoice? = nil, idleMinutes: Int = 2) {
        made.servingChoice = { recorder.note("servingChoice"); return .init(saved: saved, idleMinutes: idleMinutes) }
        made.saveServingChoice = { choice in recorder.note("saveServingChoice \(choice.rawValue)"); return .success([]) }
    }

    /// The question as a transcript shows it, with the answer Enter takes (1, 2 or 3).
    static func servingQuestion(enter: Int, idle: String = "2 minutes") -> String {
        "  How should this pair serve?\n"
            + "  The pair's pause, route and account key are the leading Mac's: its [local] and `darkbloom route key`.\n"
            + "  1) Only me (this pair, local) · Darkbloom never contacts these Macs. Your tools use the leading Mac's API.\n"
            + "  2) Darkbloom network · The pair serves Darkbloom and earns while it runs.\n"
            + "  3) Both, me first · The pair serves Darkbloom while you aren't using it. When you use its API, Darkbloom "
            + "pauses until you've been idle for \(idle).\n"
            + "  " + (enter == 1 ? prompt(3) : prompt(3, enter: enter))
    }

    /// The card's line on a Mac whose own port for the pair's API isn't up yet.
    static let bothAPILineHere = "Local API: on this Mac, you first (Darkbloom pauses while you use it; `darkbloom local` shows its address "
        + "and key once this Mac's port is up)"

    /// The card's line on a Mac whose own port for the pair's API is up (`port`).
    static func bothAPILine(port: Int) -> String {
        "Local API: http://127.0.0.1:\(port)/v1 on this Mac, you first (Darkbloom pauses while you use it; `darkbloom local` shows the key)"
    }
    static let bothServes = "  Serves:  through Darkbloom, and on its local API with you first\n"

    /// Owner rule: no speed in any choice or line.
    static func expectNoSpeed(_ text: String, _ what: String) {
        expect(!text.contains("tok/s") && !text.lowercased().contains("tokens per second"), "\(what): no speed: \(text)")
        expect(text.range(of: #"[0-9][0-9.,]*\s*[A-Za-z]*/s\b"#, options: .regularExpression) == nil, "\(what): no number per second")
    }

    static func theFirstSetupAsksHowThePairServesWithBothPreselected() {
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  Code 123 456. " + codeQuestion + "\n  1) Yes\n  2) No\n  " + prompt(2)), "both: the pairing first")
        run.type("y")
        expect(run.waitFor(servingQuestion(enter: 3)), "both: after pairing, the three choices with Both, me first preselected: \(run.text)")
        run.type("\r")
        expect(run.waitFor("  " + prompt(2), count: 2), "both: then the model list")
        run.type("\r")
        expect(run.finish() == 0, "both: exit 0")
        let text = run.text
        expect(text.contains("  " + prompt(3, enter: 3) + "Both, me first\n"), "both: Enter took Both, me first: \(text)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "servingChoice", "reachMembers", "planModels", "recheckFit 0",
                                "adopt 0", "setScope both 0.0.0.0", "saveServingChoice both", "serve", "waitReady", "testRequest", "register",
                                "waitReady", "pairServing"],
               "both: asked once, planned for Darkbloom, the answer saved with the scope after the adopt: \(recorder.all)")
        expect(text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
                                   [bothAPILine(port: 8000), "Test response in 0.61 s"])), "both: the outcome says where the pair's API is: \(text)")
        expect(!text.contains(ClusterOnboardingReady.offeredAPILine), "both: never 'No local API'")
        expect(text.contains(bothServes), "both: the card")
        expectNoSpeed(text, "both")
        expect(run.keys == 3, "both: three keys (y, enter, enter), got \(run.keys)")
        transcript("both-from-scratch", text, keys: run.keys)
    }

    static func eachAnswerServesThePairThatWay() {
        // Only me: `darkbloom cluster local`'s way, with no login check and no registration.
        let local = Recorder()
        var onlyMe = operations(local, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                                readyResult: .success(localReady))
        asking(&onlyMe, local)
        let first = TerminalRun(onlyMe)
        expect(first.waitFor("  " + prompt(2)), "only me: the pairing"); first.type("y")
        expect(first.waitFor(servingQuestion(enter: 3)), "only me: the question"); first.type("1")
        expect(first.waitFor("  " + prompt(2), count: 2), "only me: the list"); first.type("\r")
        expect(first.finish() == 0, "only me: exit 0")
        expect(local.all == ["checkLink", "pair", "answer y", "ensureService", "servingChoice", "reachMembers", "planModels", "recheckFit 0",
                             "adopt 0", "setScope local 0.0.0.0", "saveServingChoice local", "serve", "waitReady", "testRequest"],
               "only me: planned and served locally only, saved: \(local.all)")
        expect(first.text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp on this Mac's local API only\n"), "only me: the outcome")

        // Darkbloom network: today's pair, its scope and answer saved.
        let network = Recorder()
        var darkbloom = operations(network, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
        asking(&darkbloom, network)
        let second = TerminalRun(darkbloom)
        expect(second.waitFor("  " + prompt(2)), "network: the pairing"); second.type("y")
        expect(second.waitFor(servingQuestion(enter: 3)), "network: the question"); second.type("2")
        expect(second.waitFor("  " + prompt(2), count: 2), "network: the list"); second.type("\r")
        expect(second.finish() == 0, "network: exit 0")
        expect(network.all == ["checkLink", "pair", "answer y", "ensureService", "servingChoice", "reachMembers", "planModels", "recheckFit 0",
                               "adopt 0", "setScope public", "saveServingChoice network", "serve", "waitReady", "testRequest", "register",
                               "waitReady", "pairServing"], "network: \(network.all)")
        expect(second.text.contains("  " + ClusterOnboardingReady.offeredAPILine + "\n") && second.text.contains("  Serves:  through Darkbloom\n"),
               "network: no local API, as today: \(second.text)")
        expectNoSpeed(first.text + second.text, "each answer")
    }

    static func aSavedAnswerIsPreselectedWithItsIdleMinutes() {
        for (saved, enter) in [(ClusterServingChoice.onlyMe, 1), (.network, 2), (.bothMeFirst, 3)] {
            let recorder = Recorder()
            var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
            asking(&made, recorder, saved: saved, idleMinutes: 5)
            let run = TerminalRun(made)
            expect(run.waitFor("  " + prompt(2)), "saved \(saved): the pairing"); run.type("y")
            expect(run.waitFor(servingQuestion(enter: enter, idle: "5 minutes")), "saved \(saved): preselected, with its idle minutes: \(run.text)")
            run.type("q")
            _ = run.finish()
        }
    }

    static func leavingTheQuestionChangesNothing() {
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  " + prompt(2)), "left: the pairing"); run.type("y")
        expect(run.waitFor(servingQuestion(enter: 3)), "left: the question"); run.type("q")
        expect(run.finish() == 0, "left: exit 0")
        expect(run.text.contains("Nothing changed.\n"), "left: says so")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "servingChoice", "reachMembers"],
               "left: nothing planned, saved or started: \(recorder.all)")
    }

    /// Operations that don't ask (`servingChoice` nil, as every other caller of the driver): the first setup is today's.
    static func withoutTheQuestionTheFirstSetupIsTodays() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor("  " + prompt(2)), "today: the pairing"); run.type("y")
        expect(run.waitFor("  " + prompt(2), count: 2), "today: straight to the list"); run.type("\r")
        expect(run.finish() == 0, "today: exit 0")
        expect(!run.text.contains("How should this pair serve?") && !recorder.all.contains { $0.hasPrefix("setScope") || $0.hasPrefix("saveServingChoice") },
               "today: no question, no scope saved: \(recorder.all)")
    }

    static func servingLeader(_ scope: ClusterServingScope = .publicServing) -> ClusterOnboardingResume {
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = scope
        return resume
    }

    static func theListOffersTheSameThreeChoices() {
        let recorder = Recorder()
        var made = operations(recorder, resume: servingLeader(), pairEvents: [], pairResult: .failed([]), readyResult: .success(offeredReady))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Change how the pair serves (now: Darkbloom network)\n  4) Start over (unpair and set up again)\n"),
               "list: one line for the three choices, under the models: \(run.text)")
        run.type("3")
        expect(run.waitFor(servingQuestion(enter: 2)), "list: the same question, the way it serves now preselected: \(run.text)")
        run.type("3")
        expect(run.finish() == 0, "list: exit 0")
        let text = run.text
        expect(text.contains("  Switching to Both, me first: the leading Mac's part starts again with the pair's local API.\n"),
               "list: what the switch does: \(text)")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "servingChoice", "setScope both 0.0.0.0",
                                "saveServingChoice both", "waitReady", "pairServing"],
               "list: no new plan (both serve through Darkbloom), the scope and the answer saved, then the pair awaited: \(recorder.all)")
        expect(text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
                                   [bothAPILine(port: 8000), "Test response in 0.61 s"])), "list: the outcome: \(text)")
        expectNoSpeed(text, "list")
        transcript("both-from-the-list", text, keys: run.keys)
    }

    static func theWayItServesNowChangesNothing() {
        let recorder = Recorder()
        var made = operations(recorder, resume: servingLeader(.publicServingWithLocalAPI(bind: "0.0.0.0")), pairEvents: [], pairResult: .failed([]))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Change how the pair serves (now: Both, me first)\n"), "same: the line names how it serves: \(run.text)")
        run.type("3")
        expect(run.waitFor(servingQuestion(enter: 3)), "same: Both preselected")
        run.type("3")
        expect(run.finish() == 0, "same: exit 0")
        expect(run.text.contains("Nothing changed: the pair already serves that way.\n"), "same: says so: \(run.text)")
        expect(!recorder.all.contains { $0.hasPrefix("setScope") || $0.hasPrefix("saveServingChoice") }, "same: nothing saved: \(recorder.all)")
    }

    static func aPairServingBothSwitchesToLocalOnly() {
        let recorder = Recorder()
        var made = operations(recorder, resume: servingLeader(.publicServingWithLocalAPI(bind: "0.0.0.0")), pairEvents: [], pairResult: .failed([]),
                              readyResult: .success(localReady))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Change how the pair serves (now: Both, me first)\n"), "both to local: the line")
        run.type("3")
        expect(run.waitFor(servingQuestion(enter: 3)), "both to local: the question")
        run.type("1")
        expect(run.finish() == 0, "both to local: exit 0")
        expect(run.text.contains("  Switching to local only: the leading Mac's part starts again that way.\n"), "both to local: what it does")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "servingChoice", "setScope local 0.0.0.0",
                                "saveServingChoice local", "waitReady", "testRequest"], "both to local: \(recorder.all)")
    }

    /// A pair serving locally only that switches to Both plans its model again for Darkbloom, as the switch to the
    /// Darkbloom network does; the answer is saved with the scope, after the adopt.
    static func aLocalPairSwitchesToBothFromAPlanMadeForDarkbloom() {
        let recorder = Recorder()
        var made = operations(recorder, resume: servingLeader(.localOnly(bind: "0.0.0.0")), pairEvents: [], pairResult: .failed([]))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Change how the pair serves (now: only me, local)\n"), "local to both: the line")
        run.type("3")
        expect(run.waitFor(servingQuestion(enter: 1)), "local to both: Only me preselected")
        run.type("3")
        expect(run.finish() == 0, "local to both: exit 0")
        expect(run.text.contains("  " + ClusterOnboardingDriver.switchingToDarkbloomLine + "\n"), "local to both: planned again for Darkbloom")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "servingChoice", "reachMembers", "planModels",
                                "recheckFit 0", "adopt 0", "setScope both 0.0.0.0", "saveServingChoice both", "serve", "waitReady",
                                "testRequest", "register", "waitReady", "pairServing"], "local to both: \(recorder.all)")
    }

    /// The first setup: Both answered, a Mac without a login, and "Serve locally only" at the login check. The pair
    /// serves locally only, and no answer is saved: the person never chose Only me, which `[local] mode` would then
    /// preselect and a single-Mac start would read (review N1).
    static func theLoginChecksServeLocallyOnlySavesNoAnswer() {
        let both = [ClusterOnboardingMacName.this, ClusterOnboardingMacName.other(named: "Apple M3 Ultra, 256 GB")]
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                              readyResult: .success(localReady), missingLogins: both)
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  " + prompt(2)), "login fallback: the pairing"); run.type("y")
        expect(run.waitFor(servingQuestion(enter: 3)), "login fallback: the question"); run.type("\r")
        expect(run.waitFor("  " + prompt(2), count: 2), "login fallback: the list"); run.type("\r")
        expect(run.waitFor("  1) Log in on this Mac\n  2) Serve locally only\n  3) Cancel\n"), "login fallback: the login check: \(run.text)")
        run.type("2")
        expect(run.finish() == 0, "login fallback: exit 0")
        expect(recorder.all.contains("setScope local 0.0.0.0"), "login fallback: the pair serves locally only: \(recorder.all)")
        expect(!recorder.all.contains { $0.hasPrefix("saveServingChoice") }, "login fallback: no answer saved: \(recorder.all)")
    }

    // The review's flows (#1884, N6), which the checks above leave out.

    /// Both → Darkbloom network from the set-up pair's list: the plan stays, only the leading part starts again, the
    /// scope and the answer are saved, and the outcome says there is no local API.
    static func aPairServingBothSwitchesToTheDarkbloomNetwork() {
        let recorder = Recorder()
        var made = operations(recorder, resume: servingLeader(.publicServingWithLocalAPI(bind: "0.0.0.0")), pairEvents: [],
                              pairResult: .failed([]), readyResult: .success(offeredReady))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Change how the pair serves (now: Both, me first)\n"), "both to network: the line: \(run.text)")
        run.type("3")
        expect(run.waitFor(servingQuestion(enter: 3)), "both to network: Both preselected: \(run.text)")
        run.type("2")
        expect(run.finish() == 0, "both to network: exit 0")
        let text = run.text
        expect(text.contains("  Switching to the Darkbloom network: the leading Mac's part starts again without its local API.\n"),
               "both to network: what the switch does: \(text)")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "servingChoice", "setScope public",
                                "saveServingChoice network", "waitReady", "pairServing"], "both to network: \(recorder.all)")
        expect(text.contains("  " + ClusterOnboardingReady.offeredAPILine + "\n") && !text.contains(bothAPILineHere)
               && !text.contains(bothAPILine(port: 8000)),
               "both to network: no local API line: \(text)")
        expectNoSpeed(text, "both to network")
        transcript("both-to-network", text, keys: run.keys)
    }

    /// The first setup: Both answered, then q at the model list. Nothing is planned for a start, saved or started.
    static func quittingAtTheListAfterAnsweringSavesNothing() {
        let recorder = Recorder()
        var made = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  " + prompt(2)), "q at the list: the pairing"); run.type("y")
        expect(run.waitFor(servingQuestion(enter: 3)), "q at the list: the question"); run.type("\r")
        expect(run.waitFor("  " + prompt(2), count: 2), "q at the list: the list"); run.type("q")
        _ = run.finish()
        expect(!recorder.all.contains { $0.hasPrefix("setScope") || $0.hasPrefix("saveServingChoice") || $0.hasPrefix("adopt") || $0 == "serve" },
               "q at the list: nothing saved or started: \(recorder.all)")
    }

    /// The set-up pair's "Change how the pair serves", left with q: nothing is switched or saved.
    static func quittingTheListsQuestionChangesNothing() {
        let recorder = Recorder()
        var made = operations(recorder, resume: servingLeader(.publicServingWithLocalAPI(bind: "0.0.0.0")), pairEvents: [],
                              pairResult: .failed([]))
        asking(&made, recorder)
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Change how the pair serves (now: Both, me first)\n"), "q at the list's question: the line")
        run.type("3")
        expect(run.waitFor(servingQuestion(enter: 3)), "q at the list's question: the question"); run.type("q")
        expect(run.finish() == 0, "q at the list's question: exit 0")
        expect(run.text.contains("Nothing changed.\n"), "q at the list's question: says so: \(run.text)")
        expect(!recorder.all.contains { $0.hasPrefix("setScope") || $0.hasPrefix("saveServingChoice") || $0.hasPrefix("adopt") || $0 == "serve" },
               "q at the list's question: nothing switched or saved: \(recorder.all)")
    }
}
