import Foundation
import Darwin

/// Model-free checks of the leader-first onboarding (`darkbloom cluster`):
/// the discovery and pairing state machine, and the whole flow on a real
/// pseudo-terminal for both sides with scripted operations, word for word
/// and key for key. Built with plain swiftc by run.sh; no provider, no
/// network, no model.
@main enum OnboardingChecks {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures = [String]()

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition { passed += 1 } else { failures.append("line \(line): \(message())") }
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(300); defer { alarm(0) }
        // A run over pipes that ended closes its end; a late key is then an error, never the end of the checks.
        signal(SIGPIPE, SIG_IGN)
        privateMiMoSelectionRefusesBeforeAnyActionOnMemberOrUnpairedMac()
        terminalPresentationFallbacks()
        colourSetupDrawsTheMarkAndKeepsTheTranscript()
        narrowOrPlainLocaleColourKeepsPlainLines()
        narrowColourWindowKeepsOneRowLines()
        failedTestDoesNotClaimSetupSuccess()
        modelPresentationPreservesEveryFamilyAndBlocker()
        pairingStateMachine()
        leaderFromScratch()
        leaderWaitsForThePartsAfterTheRegistration()
        forcedModeNoticeOnTheSetupScreen()
        memberFromScratch()
        bothWaitingAtOnce()
        cancelWhileWaiting()
        declinedCode()
        linkNotReady()
        memberAgain()
        resumedMacsOpenWithTheMark()
        leaderAgainServing()
        leaderPairedNotServing()
        noModelOffered()
        servingLineNamesTheMac()
        leaderKeepsMembersInStep()
        leaderCopiesAMissingModelOverTheCable()
        leaderChoosesTheCatalogInstead()
        leaderDownloadsAModelNoMacHas()
        downloadProgressStaysOnOneLine()
        copyDeclined()
        copyBlockedByDisk()
        copyInterrupted()
        // Finish 2026-10-13 night: failing first on c35897c36.
        shortCopyIsAListLikeAnyOther()
        shortCopyStopsFromItsList()
        // One-command fixes 2026-10-14: failing first on 265648289.
        deploymentWords()
        cableLinesStreamBeforeTheApproval()
        twoCablesAreAskedOnScreen()
        fittingChoicesComeFirst()
        fitRecheckedBeforeTheStart()
        timeoutOffersADiagnosticsFile()
        restartLineAtTheEnd()
        restartWords()
        updateNoticed()
        // F9 + F16 (round 6b, 2026-10-14): failing first on 33da00709.
        stoppedLeaderOffersTeardown()
        modelTitlesAreCatalogNames()
        deploymentTravelsWithTheStart()
        // `darkbloom cluster local` (2026-10-15): failing first on 69ba75be7.
        localFromScratch()
        localOnAStoppedLeader()
        localSwitchesAServingCluster()
        localAgainShowsTheMenu()
        menuKeysSwitchTheScope()
        localNamesTheModel()
        memberJoinsWithLocal()
        servingScopeValues()
        sameTitleShowsTheID()
        // Tensor parallel made visible (2026-10-24).
        tensorParallelNotesOnTheModelLine()
        // Two identical Macs named apart, and the plain presentations of those lines (2026-10-25).
        identicalMacsAreToldApart()
        plainPresentationsKeepTheNewLines()
        // The 2026-11-02 onboarding review: lists, permissions asked at stated moments, a read-only member, approved
        // models only, sudo instead of a script, and the window's fate said on both Macs.
        arrowKeysTakeAMenuItem()
        onlyApprovedModelsAreListed()
        memberLocalPointsToTheLeader()
        localNetworkAskedAtStatedMoments()
        cablePortSetUpWithSudoWhereNoPromptShows()
        codeListEndsWhenThePairingDoes()
        developmentBuildKeepsTheWindowsOpen()
        // The audit of that change: keys during waits, q, SSH, a probe that tells nothing, a slow Allow on the other
        // Mac, and how the pair serves.
        arrowKeysDoNotStopAWait()
        qCancelsAListBeforeALetter()
        sshSessionsAreToldWhereThePromptIs()
        serviceThatCannotTellStillGetsTheAsk()
        otherMacThatDidNotAnswerOffersTryAgain()
        startSaysHowThePairServes()
        // The two-Mac test on two M5 Ultras and the final review: which physical Mac plays which part, a model copied
        // from the other Mac, a model that does not fit now, and the window's line.
        eachMacNamesItselfBesideItsPart()
        modelOnTheOtherMacIsCopiedNotDownloaded()
        modelThatDoesNotFitSaysSoOnce()
        // 2026-11-03, the owner's second pair and an end user's: "Serving" and "Done" while nothing was loaded.
        offeredPairThatTheCoordinatorRefusesSaysWhy()
        failedRestartAfterTheRegistrationIsNotDone()
        missingLoginIsSaidBeforeTheStart()
        offeredPairServesOnceLoaded()
        pairReportsAndReasonsInPlainWords()
        // The end user's call (Dylan, 2026-11-03): a clear outcome, a sense of time, the reason with its time.
        startSaysItTakesAWhileAndShowsEachMac()
        theOutcomeIsItsOwnBlock()
        appleVerificationSaysWhenItRetries()
        memberSeesTheOutcomeOrWhereToLook()
        print("onboarding checks: \(passed) passed, \(failures.count) failed")
        for failure in failures { print("FAIL " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - State machine

    static func terminalPresentationFallbacks() {
        let color = ["TERM": "xterm-256color"]
        expect(ClusterOnboardingTerminal.supportsColor(inputIsTerminal: true, outputIsTerminal: true,
            environment: color), "interactive terminal can emphasize headings")
        for flags in [(false, true), (true, false), (false, false)] {
            expect(!ClusterOnboardingTerminal.supportsColor(inputIsTerminal: flags.0, outputIsTerminal: flags.1,
                environment: color), "redirected input or output stays plain")
        }
        for environment in [[String: String](), ["TERM": "dumb"], ["TERM": ""],
                            ["TERM": "xterm", "NO_COLOR": ""], ["TERM": "xterm", "CLICOLOR": "0"]] {
            expect(!ClusterOnboardingTerminal.supportsColor(inputIsTerminal: true, outputIsTerminal: true,
                environment: environment), "plain terminal preference is respected")
        }
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { expect(false, "input pipe"); return }
        defer { for fd in input { Darwin.close(fd) } }
        guard pipe(&output) == 0 else { expect(false, "output pipe"); return }
        defer { for fd in output { Darwin.close(fd) } }
        let terminal = ClusterOnboardingTerminal(input: input[0], output: output[1], environment: color)
        terminal.heading("Choose a model")
        // A list too long for one key: typed digits, with a backspace, then enter.
        let options = (1...13).map { "Model \($0)" }
        let keys = Array("12\u{08}3\n".utf8)
        _ = keys.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        expect(terminal.choose(options, selected: 0) == 12, "plain input keeps line editing semantics")
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(output[0], &buffer, buffer.count)
        let text = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
        let listed = options.enumerated().map { "  \($0.offset + 1)) \($0.element)\n" }.joined()
        expect(text == "\nChoose a model\n" + listed + "  Choose 1-13: \n",
            "pipe output has no colors, backspaces or echoed input: \(text)")
    }

    /// The coloured setup on a UTF-8 terminal: the Darkbloom mark beside the
    /// setup's name, a meter on each stage, choices as lists moved with the
    /// arrows (as `darkbloom start` picks models) that fold to the chosen line,
    /// and live lines that the next said line replaces. Every stage and line
    /// still reads in order; the mark blooms (cursor up) only when animation is
    /// allowed, and nothing clears the screen.
    static func colourSetupDrawsTheMarkAndKeepsTheTranscript() {
        for animated in [false, true] {
            let recorder = Recorder()
            var environment = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
            if !animated { environment["DARKBLOOM_NO_ANIMATION"] = "1" }
            let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
                pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")), environment: environment)
            expect(run.waitFor(codeQuestion), "colour: the code question")
            expect(run.waitFor(arrowHint), "colour: the answers as a list moved with the arrows")
            run.type("y")
            expect(run.waitFor(arrowHint, count: 2), "colour: the model list")
            run.type("\r")
            let code = run.finish()
            expect(code == 0, "colour: exit 0, got \(String(describing: code))")
            let screen = visible(run.text)
            expect(ClusterOnboardingBrand.rows().allSatisfy { row in screen.contains { $0.contains(row) } }, "colour: the whole mark")
            expect(screen.contains { $0.contains("Darkbloom") } && !screen.contains { $0.contains("Two Macs, one model") },
                "colour: the name beside the mark, nothing more")
            let rows = stages.compactMap { stage in screen.firstIndex { $0.contains(stage) } }
            expect(rows.count == stages.count && rows == rows.sorted(), "colour: stages in order")
            for (index, stage) in stages.enumerated() {
                let meter = String(repeating: "\u{25CF}", count: index + 1) + String(repeating: "\u{25CB}", count: 3 - index)
                expect(screen.contains { $0.contains(stage) && $0.contains(meter) }, "colour: \(stage) carries its meter")
            }
            // A taken choice folds to its one line: the ▸ and the option, the list and its hint erased.
            expect(screen.contains("  \u{25B8} Yes") && screen.contains("  \u{25B8} Qwen3.8-27B-4bit-mtp · 16.3 GB · pipeline"),
                "colour: each choice folds to the chosen line")
            expect(run.text.contains("\u{1B}[3A\r\u{1B}[J"), "colour: the list is erased in place once chosen")
            expect(screen.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)"),
                "colour: the outcome reads plainly")
            for live in ["Checking the cable", "Reading both Macs over the cable", "Planning each model for both Macs",
                         "Loading Qwen3.8-27B-4bit-mtp on both Macs", "Sending a test request"] {
                expect(!screen.contains { $0.contains(live + "\u{2026}") }, "colour: the live line \(live) is replaced, never left behind")
            }
            expect(run.text.contains("\u{1B}[\(ClusterOnboardingBrand.height)A") == animated, "colour: the mark blooms only when animating")
            expect(!run.text.contains("\u{1B}[2J") && !run.text.contains("\u{1B}[H"), "colour: no screen clearing")
            expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0",
                "serve", "waitReady", "testRequest", "register"], "colour: operations in order: \(recorder.all)")
        }
        // The mark and the meter themselves.
        expect(ClusterOnboardingBrand.rows() == ["\u{2588}\u{2588}\u{2588}\u{2588}  \u{2580}\u{2580}\u{2588}\u{2588}  \u{2588}\u{2588}",
            "\u{2588}\u{2588}\u{2588}\u{2588}    \u{2588}\u{2588}\u{2588}\u{2588}  ", "\u{2588}\u{2588}\u{2588}\u{2588}  \u{2588}\u{2588}      ",
            "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}  "], "the favicon's pixel d")
        expect(Set(ClusterOnboardingBrand.bloom.map { $0.row * 7 + $0.column }).count == ClusterOnboardingBrand.bloom.count
            && ClusterOnboardingBrand.bloom.allSatisfy { Array(ClusterOnboardingBrand.pixels[$0.row])[$0.column] == "#" }
            && ClusterOnboardingBrand.bloom.count == ClusterOnboardingBrand.pixels.joined().filter { $0 == "#" }.count,
            "the bloom draws every pixel once")
        expect(ClusterOnboardingBrand.rows(revealed: 0).allSatisfy { $0.allSatisfy { $0 == " " } }, "an unopened bloom is blank")
        expect(ClusterOnboardingBrand.meter("2/4 Pair") == "\u{25CF}\u{25CF}\u{25CB}\u{25CB}"
            && ClusterOnboardingBrand.meter("2 / 4  Pair") == "\u{25CF}\u{25CF}\u{25CB}\u{25CB}"
            && ClusterOnboardingBrand.meter("Test") == nil && ClusterOnboardingBrand.meter("6/5 x") == nil
            && ClusterOnboardingBrand.meter("6 / 5  x") == nil, "the step meter")
        expect(!ClusterOnboardingBrand.drawsBlocks(["LANG": "C"]) && ClusterOnboardingBrand.drawsBlocks(["LC_ALL": "en_US.UTF-8"]),
            "blocks only where the locale is UTF-8")
        expect(ClusterOnboardingBrand.colour(["COLORTERM": "truecolor"]) == "38;2;20;86;255" && ClusterOnboardingBrand.colour([:]) == "38;5;27",
            "the brand blue")
    }

    /// Colour on a terminal too narrow for the mark (an SSH window, a split
    /// pane), or a locale without UTF-8: the coloured headings, no mark, no
    /// meter and no live line, every line in order; choices are still lists
    /// moved with the arrows (ASCII words where the locale has no arrows), each
    /// row cut to the window so a redraw never meets a wrapped row.
    static func narrowOrPlainLocaleColourKeepsPlainLines() {
        // 30 columns cannot hold the keys' long hint: the short one, so the list's rows each take one row of the window.
        for (label, environment, columns, hint) in [
            ("narrow", ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"], UInt16(30), "up/down, enter, q"),
            ("ascii locale", ["TERM": "xterm-256color", "LANG": "C"], UInt16(132), "up/down move, enter select, q cancel"),
        ] {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
                pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")), environment: environment, columns: columns)
            expect(run.waitFor(codeQuestion), "\(label): the code question")
            expect(run.waitFor(hint), "\(label): the list's keys in words")
            run.type("y")
            expect(run.waitFor(hint, count: 2), "\(label): the model list")
            let hints = visible(run.text).filter { $0.contains(hint) }
            expect(!hints.isEmpty && hints.allSatisfy { $0.count < Int(columns) }, "\(label): the keys' hint fits its row, so none stays behind: \(hints)")
            run.type("\r")
            let code = run.finish()
            expect(code == 0, "\(label): exit 0, got \(String(describing: code))")
            let screen = visible(run.text)
            expect(!run.text.contains("\u{2588}") && !run.text.contains("\u{2580}") && !run.text.contains("\u{25CF}") && !run.text.contains("\u{25B8}"),
                "\(label): no mark, no meter, no block glyphs")
            expect(!run.text.contains("\u{1B}[\(ClusterOnboardingBrand.height)A") && !run.text.contains("\u{1B}[K"),
                "\(label): no bloom and no live line")
            expect(run.text.contains("\u{1B}[1;36m"), "\(label): the headings keep their colour")
            expect(screen.allSatisfy { $0.count <= Int(columns) || !$0.hasPrefix("  > ") }, "\(label): the list's rows fit the window")
            let rows = stages.compactMap { stage in screen.firstIndex { $0.contains(stage) } }
            expect(rows.count == stages.count && rows == rows.sorted(), "\(label): stages in order")
            expect(Array(recorder.all.suffix(2)) == ["testRequest", "register"], "\(label): the setup ran to its test: \(recorder.all)")
        }
    }

    /// A narrow colour window (45 columns) keeps the meter and live lines, and
    /// the mark where its row fits (the setup's opening is the name alone); and
    /// a live line wider than the window is cut to one row, so the line that
    /// replaces it erases all of it.
    static func narrowColourWindowKeepsOneRowLines() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
            pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")),
            environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"], columns: 45)
        expect(run.waitFor(codeQuestion), "45 columns: the code question")
        expect(run.waitFor(arrowHint), "45 columns: the answers")
        run.type("y")
        expect(run.waitFor(arrowHint, count: 2), "45 columns: the model list")
        run.type("\r")
        let code = run.finish()
        expect(code == 0, "45 columns: exit 0, got \(String(describing: code))")
        let screen = visible(run.text)
        // The setup's opening is the name alone (2026-11-03), so the mark fits beside it at 45 columns too.
        expect(run.text.contains("\u{2588}"), "45 columns: the short opening fits beside the mark")
        expect(screen.contains { $0.contains("1/4 Connect") && $0.contains("\u{25CF}\u{25CB}\u{25CB}\u{25CB}") },
            "45 columns: headings keep the meter")
        let wide = screen.filter { $0.contains("\u{25B8}") && $0.count > 45 }
        expect(wide.isEmpty, "45 columns: the list's rows fit the window: \(wide)")
        expect(Array(recorder.all.suffix(2)) == ["testRequest", "register"], "45 columns: the setup ran to its test: \(recorder.all)")
        // A live line wider than a 44-column window, drawn directly.
        var primary: Int32 = -1, secondary: Int32 = -1
        var window = winsize(ws_row: 24, ws_col: 44, ws_xpixel: 0, ws_ypixel: 0)
        precondition(openpty(&primary, &secondary, nil, nil, &window) == 0)
        _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
        let console = ClusterOnboardingTerminal(input: secondary, output: secondary,
            environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"])
        console.working("Loading Gemma 4 26B (gemma-4-26b-qat-4bit) on both Macs")
        console.settle()
        console.restore()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(primary, &bytes, bytes.count)
        let drawn = String(decoding: bytes.prefix(max(0, count)), as: UTF8.self)
        let rows = drawn.components(separatedBy: "\r")
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        expect(!rows.isEmpty && rows.allSatisfy { $0.count <= 43 }, "44 columns: the live line stays on one row: \(rows)")
        expect(rows.contains { $0.contains("Loading Gemma 4 26B") && $0.hasSuffix("\u{2026}") },
            "44 columns: the cut line keeps its start and its ellipsis: \(rows)")
        close(primary); close(secondary)
    }

    /// What a person reads: escapes removed and each row as it was last written.
    static func visible(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { line in
            // Every CSI sequence, the cursor's own (`ESC [ ? 25 l`) included.
            let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            return plain.components(separatedBy: "\r").last ?? plain
        }
    }

    static func failedTestDoesNotClaimSetupSuccess() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder,
            resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            pairEvents: [], pairResult: .failed([]), testResult: .failure(.init(["Test response timed out."]))))
        expect(run.waitFor(prompt(2)), "failed test: choose model")
        run.type("\r")
        expect(run.finish() == 1, "failed test returns failure")
        expect(run.text.hasSuffix("Setup saved, but the test failed. Run `darkbloom cluster` to test again.\n"),
               "failure is explicit and ends with its next action")
        expect(!run.text.contains("Done."), "failed response never reports setup success")
        expect(recorder.all.suffix(3) == ["serve", "waitReady", "testRequest"], "readiness and actual test still run")
    }

    static func modelPresentationPreservesEveryFamilyAndBlocker() {
        let recorder = Recorder()
        let choices: [ClusterOnboardingModelChoice] = [
            .init(title: "MiMo", lines: ["Fits these Macs"], blocker: nil),
            .init(title: "GLM", lines: [], blocker: "Not qualified for this cluster"),
        ]
        let run = TerminalRun(operations(recorder,
            resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            pairEvents: [], pairResult: .failed([]), choices: choices))
        expect(run.waitFor(prompt(1)), "every family uses the same list")
        expect(run.text.contains("  1) MiMo · Fits these Macs\n"), "offered MiMo remains selectable")
        expect(!run.text.contains("GLM"), "a model that cannot be served here is not listed")
        run.type("q")
        expect(run.finish() == 0, "q cancels the choice")
        expect(run.text.contains("Nothing changed."), "cancelled: said")
        expect(!recorder.all.contains("adopt 0") && !recorder.all.contains("serve"), "presentation does not bypass start checks")
    }

    static func pairingStateMachine() {
        var machine = ClusterOnboardingPairing()
        expect(machine.role == nil, "no role before the pairing moves")
        expect(machine.handle(.searching).isEmpty && machine.working == "Looking for the other Mac on the cable",
               "searching: a live line, no said line")
        let wait = machine.handle(.waitingAsLeader)
        expect(machine.role == .leader && machine.phase == .waiting, "listening makes this Mac the leader-to-be")
        expect(wait == ["Run `darkbloom cluster` on the other Mac."], "the action is the one line, word for word: \(wait)")
        expect(machine.working?.contains("run `darkbloom cluster` there") == true && machine.working?.contains("q cancels") == true,
               "the live line repeats the action while it waits, and names the cancel key")
        expect(machine.handle(.waitingAsLeader).isEmpty, "the wait is announced once (idempotent)")
        expect(machine.handle(.connected).isEmpty, "connected: nothing said")
        let code = machine.handle(.code("123456", peer: ["Apple M5 Ultra, 256 GB", "macOS 27.0.1"]))
        expect(machine.asking == "123 456", "the code waits for an answer")
        expect(code == ["Code 123 456. Same on the other Mac?"], "the code and its question, one line: \(code)")
        expect(ClusterOnboardingPairing.codeAnswers == ["Yes", "No"], "the two answers")
        expect(machine.answered(true) == [ClusterOnboardingPairing.otherMacAnswerLine] && machine.working == "Waiting for the other Mac to confirm the code",
               "answer yes: the other Mac's turn, said, and the wait is live")
        expect(machine.answered(true).isEmpty, "a second answer answers nothing")
        var first = ClusterOnboardingPairing()
        _ = first.handle(.code("123456", peer: ["Apple M5 Ultra, 256 GB"]))
        expect(first.handle(.peerDecided(true)).isEmpty, "the other Mac's confirmation: no line")
        expect(first.answered(true).isEmpty, "the other Mac answered first: nothing more to do there")
        var declined = ClusterOnboardingPairing()
        _ = declined.handle(.code("123456", peer: []))
        expect(declined.handle(.peerDecided(false)) == ["The other Mac declined the code."], "the other Mac declined: said")
        expect(machine.finished(.paired(role: .leader, peerName: "Apple M5 Ultra, 256 GB")).last
            == "\u{2713} Paired. This Mac leads.", "leader's paired line")

        var joiner = ClusterOnboardingPairing()
        _ = joiner.handle(.searching)
        expect(joiner.handle(.joining).isEmpty && joiner.working == "Exchanging keys with the other Mac", "a waiting leader is found: live only")
        expect(joiner.role == .member, "dialing a waiting Mac makes this one a member")
        expect(joiner.finished(.paired(role: .member, peerName: "Apple M3 Ultra, 256 GB")).last
            == "\u{2713} Paired. The other Mac leads.", "member's paired line, word for word")

        var tie = ClusterOnboardingPairing()
        _ = tie.handle(.waitingAsLeader)
        expect(tie.handle(.joining).isEmpty, "a tie: the paired line says which Mac leads")
        expect(tie.role == .member, "the Mac that yields joins")

        var declining = ClusterOnboardingPairing()
        _ = declining.handle(.code("123456", peer: []))
        expect(declining.answered(false) == ["Declined: nothing paired."], "answer no")

        var failed = ClusterOnboardingPairing()
        expect(failed.finished(.failed(["The code was declined."])) == ["Not paired.", "The code was declined.",
            "Run `darkbloom cluster` again."], "a failed pairing says how to retry")
        expect(ClusterOnboardingPairing.spaced("654321") == "654 321", "code spacing")

        // A typed answer: enter, a number, or a letter only one option starts with.
        typealias C = ClusterOnboardingChoice
        let answers = ClusterOnboardingPairing.codeAnswers
        expect(C.match("", options: answers, selected: 0) == 0 && C.match("2", options: answers, selected: 0) == 1
            && C.match("y", options: answers, selected: 0) == 0 && C.match("N", options: answers, selected: 0) == 1
            && C.match("3", options: answers, selected: 0) == nil && C.match("x", options: answers, selected: 0) == nil,
            "typed answers")
        expect(C.match("c", options: ["Change model", "Check memory is freed"], selected: 0) == nil,
            "a letter two options start with picks neither")
    }

    // MARK: - Pseudo-terminal flows

    static let leaderHardware = [ClusterOnboardingMachine(name: "Apple M5 Ultra, 256 GB", memoryGB: 256, gpuCores: 80, leads: true, models: 2),
                                 ClusterOnboardingMachine(name: "Apple M3 Ultra, 256 GB", memoryGB: 256, gpuCores: 80, leads: false, models: 2)]

    /// The models approved for clusters (`ClusterPublicModels.declared`), planned with this Mac, which leads, at rank 0;
    /// a model these chips may not serve is not listed.
    static let choices = [
        ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"], blocker: nil,
                                     validated: true, split: "pipeline"),
        ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel · this Mac 50% / the other Mac 50%"], blocker: nil,
                                     validated: true, split: "tensor parallel"),
        ClusterOnboardingModelChoice(title: "gpt-oss-20b", lines: [], blocker: "not granted for this pair of chips")]

    /// A copy's live report, logged for a transcript, then the line for the record.
    static let copyReports: [ClusterOnboardingProgress] = [
        .live({ _ in "Copying to the other Mac: 8.2 of 16.3 GB, 2.40 GB/s, about 1 s left" }, logged: true)]

    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls = [String]()
        var answers = [Bool]()
        var adopted: Int?
        func note(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    static func operations(_ recorder: Recorder, resume: ClusterOnboardingResume = .init(), linkReady: Bool = true,
                           pairEvents: [ClusterOnboardingPairEvent], pairResult: ClusterOnboardingPairResult,
                           choices: [ClusterOnboardingModelChoice] = choices,
                           replanned: [ClusterOnboardingModelChoice]? = nil,
                           provisionResult: Result<[String], ClusterOnboardingFailure> = .success(["\u{2713} Copied to the other Mac (16.3 GB, 6.9 s)"]),
                           provisionReports: [ClusterOnboardingProgress] = copyReports,
                           provisionReportPause: useconds_t = 30_000,
                           linkPorts: [String] = [],
                           approvalGate: DispatchSemaphore? = nil,
                           recheck: String? = nil,
                           afterRestart: String? = nil,
                           developerNotice: String? = nil,
                           testResult: Result<[String], ClusterOnboardingFailure> = .success(["in 0.61 s"]),
                           machines: [ClusterOnboardingMachine] = leaderHardware,
                           registerResult: Result<[String], ClusterOnboardingFailure> = .success([]),
                           localNetwork: @escaping @Sendable (ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork = { _ in .allowed },
                           linkScript: String? = nil,
                           sudoSucceeds: Bool = true,
                           outlivesWindow: Bool = true,
                           remote: Bool = false,
                           commandApp: String = "Terminal",
                           thisMacName: String? = nil,
                           reachFailures: Int = 0,
                           readyResult: Result<ClusterOnboardingReady, ClusterOnboardingFailure> = .success(.init(servedBy: "this Mac", port: 8000,
                               deployment: "Serving Qwen3.8-27B-4bit-mtp across both Macs: pipeline, this Mac 32 layers / the other Mac 32 layers",
                               split: "pipeline")),
                           readyResults: [Result<ClusterOnboardingReady, ClusterOnboardingFailure>]? = nil,
                           pairServingResults: [Result<[String], ClusterOnboardingFailure>] = [.failure(.init("not asked in this check"))],
                           missingLogins: [String] = [],
                           loginSucceeds: Bool = true,
                           readyReports: [String] = ["1 of 2 parts ready", "2 of 2 parts ready"],
                           readyReportPause: useconds_t = 50_000,
                           statusLines: [String]? = nil) -> ClusterOnboardingOperations {
        let answered = DispatchSemaphore(value: 0)
        let chosenPort = Recorder()
        // The n-th wait for the parts answers `readyResults[n]` (the last one again after it), else `readyResult`.
        @Sendable func ready(_ call: Int) -> Result<ClusterOnboardingReady, ClusterOnboardingFailure> {
            guard let readyResults, !readyResults.isEmpty else { return readyResult }
            return readyResults[min(call, readyResults.count - 1)]
        }
        let loggedOut = Recorder()
        for mac in missingLogins { loggedOut.note(mac) }
        return ClusterOnboardingOperations(
            resume: { resume },
            checkLink: { say in
                recorder.note("checkLink")
                if let approvalGate {
                    // The approval line must be on screen while the macOS prompt is up (checkLink still running).
                    say("Darkbloom needs network access for the cluster cable: approve the macOS prompt (once per Mac).")
                    _ = approvalGate.wait(timeout: .now() + 5)
                }
                if let linkScript, !recorder.all.contains("runAsAdministrator") {
                    say("Cable found.")
                    return .init(ready: false, exitCode: 1, manualScript: linkScript)
                }
                if linkPorts.count > 1, chosenPort.all.isEmpty {
                    say("Cable found on \(linkPorts.count) ports.")
                    return .init(ready: false, exitCode: 1, ports: linkPorts)
                }
                say("Cable found.")
                if linkReady {
                    say("Cable ready.")
                    say("Run `darkbloom cluster` on the other Mac too.")
                } else {
                    say("The cable is not ready: RDMA is off on this Mac.")
                }
                return .init(ready: linkReady, exitCode: linkReady ? 0 : 1)
            },
            pair: { events in
                recorder.note("pair")
                var asked = false
                for event in pairEvents {
                    events(event)
                    if case .code = event { asked = true; _ = answered.wait(timeout: .now() + 10) }
                    usleep(20_000)
                }
                _ = asked
                if case .failed = pairResult { return pairResult }
                recorder.lock.lock(); let last = recorder.answers.last; recorder.lock.unlock()
                if asked, last == false { return .failed(["The code was declined on this Mac."]) }
                return pairResult
            },
            answerCode: { accept in
                recorder.lock.lock(); recorder.answers.append(accept); recorder.lock.unlock()
                recorder.note("answer \(accept ? "y" : "n")"); answered.signal()
            },
            ensureService: { recorder.note("ensureService"); return .success(()) },
            reachMembers: {
                recorder.note("reachMembers")
                if recorder.all.filter({ $0 == "reachMembers" }).count <= reachFailures {
                    return .failure(.init("The other Mac did not answer over the cable."))
                }
                return .success(machines)
            },
            planModels: {
                recorder.note("planModels")
                let again = recorder.all.filter { $0 == "planModels" }.count > 1
                return .success(again ? (replanned ?? choices) : choices)
            },
            adopt: { index in recorder.note("adopt \(index)"); return .success(["Saved this Mac's setup.", "Sent the setup to the other Mac over the cable; its cluster service applied it."]) },
            serve: { recorder.note("serve"); return .success(["Started the other Mac's part over the cable (its cluster service runs it); this Mac's service runs its own."]) },
            waitReady: { progress in
                let call = recorder.all.filter { $0 == "waitReady" }.count
                recorder.note("waitReady")
                for report in readyReports { progress(report); usleep(readyReportPause) }
                return ready(call)
            },
            testRequest: { recorder.note("testRequest"); return testResult },
            // Rank 0, which serves the API, is the Mac that leads: this Mac on the leader, the other Mac on a member.
            status: { recorder.note("status"); if let statusLines { return statusLines }; return resume.role == .member
                ? ["Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)."]
                : ["Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 (earning through Darkbloom)."] },
            stop: { recorder.note("stop"); return .success(["Stopping both Macs. Run `darkbloom cluster` to serve again."]) },
            provision: { index, download, progress in
                recorder.note("provision \(index) \(download ? "download" : "copy")")
                for report in provisionReports {
                    progress(report)
                    usleep(provisionReportPause)
                }
                return provisionResult
            },
            verifyTeardown: { recorder.note("verifyTeardown")
                return .success(["This Mac: nothing left running", "The other Mac (Apple M3 Ultra, 256 GB): nothing left running"]) },
            useLinkPort: { port in chosenPort.note(port); recorder.note("useLinkPort \(port)") },
            recheckFit: { index in recorder.note("recheckFit \(index)"); return recheck },
            afterRestart: { afterRestart },
            saveDiagnostics: { recorder.note("saveDiagnostics"); return .success(["Saved a diagnostics file (no keys, addresses or names in it): darkbloom-cluster-diagnostics.json in your home folder."]) },
            developerNotice: { developerNotice },
            setScope: { scope in
                recorder.note(scope.bind.map { "setScope local \($0)" } ?? "setScope public")
                return .success([scope.isLocalOnly ? "Saved: this cluster serves locally only." : "Saved: this cluster serves through Darkbloom."])
            },
            register: { recorder.note("register"); return registerResult },
            localNetwork: { subject in localNetwork(subject) },
            commandApp: { commandApp },
            runAsAdministrator: { script in recorder.note("runAsAdministrator"); return sudoSucceeds && script == linkScript },
            serviceOutlivesWindow: { outlivesWindow },
            remote: { remote },
            thisMacName: { thisMacName },
            pairServing: { progress in
                let call = recorder.all.filter { $0 == "pairServing" }.count
                recorder.note("pairServing")
                progress("waiting for the coordinator to pair both Macs"); usleep(30_000)
                progress("the coordinator paired them: loading the model on both Macs"); usleep(30_000)
                return pairServingResults[min(call, pairServingResults.count - 1)]
            },
            missingLogins: { loggedOut.all },
            login: {
                recorder.note("login")
                guard loginSucceeds else { return false }
                loggedOut.lock.withLock { loggedOut.calls.removeAll { $0 == ClusterOnboardingMacName.this } }
                return true
            })
    }

    static func privateMiMoSelectionRefusesBeforeAnyActionOnMemberOrUnpairedMac() {
        let request = ClusterOnboardingRequest(scope: .localOnly(bind: "127.0.0.1"),
            model: ClusterOnboardingRequest.privateMiMoModelID, privateMiMoImageQualification: true)
        for role in [Optional<ClusterOnboardingRole>.none, .member] {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, resume: .init(role: role), pairEvents: [], pairResult: .failed([])), request: request)
            expect(run.finish() == 1, "private qualification refuses an unpaired/member Mac")
            expect(recorder.all.isEmpty, "no pair/service/plan/adopt/start action occurs on refusal")
            expect(run.text.contains("already paired current control leader"), "refusal names the supported route")
        }
        var invalid = request; invalid.scope = .publicServing
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader), pairEvents: [], pairResult: .failed([])), request: invalid)
        expect(run.finish() == 1 && recorder.all.isEmpty, "public scope cannot trigger private setup actions")
        // The real driver still reaches normal planning on the supported leader, and stops at the start's own fit
        // check: no synthetic Ready or model success.
        let leaderRecorder = Recorder()
        let choice = ClusterOnboardingModelChoice(title: "MiMo private PNG", lines: ["private qualification"], blocker: nil,
            modelID: ClusterOnboardingRequest.privateMiMoModelID)
        let leader = TerminalRun(operations(leaderRecorder, resume: .init(role: .leader), pairEvents: [], pairResult: .failed([]),
            choices: [choice], recheck: "Quit apps first."), request: request)
        expect(leader.finish() == 1, "qualification stops at the start's fit check here")
        expect(leader.text.contains("MiMo private PNG doesn't fit in free memory now: Quit apps first."), "leader reaches the start")
        expect(leaderRecorder.all.contains("planModels"), "leader uses normal planning")
        expect(!leaderRecorder.all.contains("adopt 0") && !leaderRecorder.all.contains("serve"), "a stopped draft creates no saved plan or Ready")
    }

    /// One driver run on a pseudo-terminal: the keys are typed only once the text before them is on screen.
    final class TerminalRun: @unchecked Sendable {
        let master: Int32
        let slave: Int32
        private let lock = NSLock()
        private var captured = [UInt8]()
        private var exitCode: Int32?
        private(set) var keys = 0
        let done = DispatchSemaphore(value: 0)

        init(_ operations: ClusterOnboardingOperations, request: ClusterOnboardingRequest = .init(),
             environment: [String: String] = ["NO_COLOR": "1"], columns: UInt16 = 132) {
            var primary: Int32 = -1, secondary: Int32 = -1
            var window = winsize(ws_row: 50, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            precondition(openpty(&primary, &secondary, nil, nil, &window) == 0)
            master = primary; slave = secondary
            _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
            let reader = primary
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&descriptor, 1, 20) >= 0 else { return }
                    let count = Darwin.read(reader, &buffer, buffer.count)
                    if count > 0 { lock.lock(); captured.append(contentsOf: buffer.prefix(count)); lock.unlock() }
                    if lock.withLock({ exitCode != nil }) && count <= 0 { return }
                }
            }
            let slaveFD = secondary
            Thread.detachNewThread { [self] in
                let console = ClusterOnboardingTerminal(input: slaveFD, output: slaveFD, environment: environment)
                let code = ClusterOnboardingDriver.run(operations, console: console, request: request)
                console.restore()
                usleep(100_000)
                lock.lock(); exitCode = code; lock.unlock()
                done.signal()
            }
        }

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: captured, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n") }
        var code: Int32? { lock.lock(); defer { lock.unlock() }; return exitCode }

        func waitFor(_ needle: String, seconds: Double = 10, count: Int = 1) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            func seen() -> Bool { text.components(separatedBy: needle).count - 1 >= count }
            while Date() < deadline { if seen() { return true }; usleep(10_000) }
            return seen()
        }

        func type(_ keys: String) {
            self.keys += keys.count
            let bytes = Array(keys.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        }

        func finish(seconds: Double = 10) -> Int32? {
            _ = done.wait(timeout: .now() + seconds)
            return code
        }
    }

    /// One driver run with its input and output redirected to pipes (no terminal at all): the plain transcript.
    final class PipeRun: @unchecked Sendable {
        private let lock = NSLock()
        private var captured = [UInt8]()
        private var exitCode: Int32?
        private let keys: Int32
        let done = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)

        init(_ operations: ClusterOnboardingOperations, request: ClusterOnboardingRequest = .init(), environment: [String: String]) {
            var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
            precondition(pipe(&input) == 0 && pipe(&output) == 0)
            keys = input[1]
            let reader = output[0], writer = output[1], source = input[0]
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(reader, &buffer, buffer.count)
                    guard count > 0 else { break }
                    lock.withLock { captured.append(contentsOf: buffer.prefix(count)) }
                }
                Darwin.close(reader)
                drained.signal()
            }
            Thread.detachNewThread { [self] in
                let console = ClusterOnboardingTerminal(input: source, output: writer, environment: environment)
                let code = ClusterOnboardingDriver.run(operations, console: console, request: request)
                console.restore()
                Darwin.close(writer)
                Darwin.close(source)
                lock.withLock { exitCode = code }
                done.signal()
            }
        }

        deinit { Darwin.close(keys) }

        var text: String { lock.withLock { String(decoding: captured, as: UTF8.self) } }

        func waitFor(_ needle: String, seconds: Double = 10, count: Int = 1) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            func seen() -> Bool { text.components(separatedBy: needle).count - 1 >= count }
            while Date() < deadline { if seen() { return true }; usleep(10_000) }
            return seen()
        }

        func type(_ keys: String) {
            let bytes = Array(keys.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(self.keys, $0.baseAddress, $0.count) }
        }

        /// The exit status once the run ended and every byte it wrote was read.
        func finish(seconds: Double = 10) -> Int32? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            _ = drained.wait(timeout: .now() + seconds)
            return lock.withLock { exitCode }
        }
    }

    static func leaderFromScratch() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
            pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor("  Run `darkbloom cluster` on the other Mac.\n"), "leader: the one thing to do on the other Mac, on its own line")
        expect(run.waitFor("  Code 123 456. " + codeQuestion + "\n  1) Yes\n  2) No\n  " + prompt(2)), "leader: the code, its question and its answers")
        run.type("y")
        expect(run.waitFor("  " + prompt(2), count: 2), "leader: the model list")
        let listed = run.text
        expect(!listed.contains("This Mac: Apple"), "leader: no line of both Macs' hardware")
        expect(listed.contains("  1) Qwen3.8-27B-4bit-mtp · 16.3 GB · pipeline\n  2) Z.ai: GLM-5.3-Flash · 181.8 GB · tensor parallel\n"),
               "leader: one short line per model, with how it is split: \(listed)")
        expect(!listed.contains("rank 1 (decodes)"), "leader: the rest of a model's lines is not said")
        expect(!listed.contains("gpt-oss-20b"), "leader: a model these Macs cannot serve is not listed")
        run.type("\r")
        let code = run.finish()
        expect(code == 0, "leader: exit 0, got \(String(describing: code))")
        let text = run.text
        for line in [
            "  \(prompt(2))Yes",
            "  " + ClusterOnboardingPairing.otherMacAnswerLine,
            "  \u{2713} Paired. This Mac leads.",
            "  \(prompt(2))Qwen3.8-27B-4bit-mtp",
            "\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
            "  API at http://localhost:8000 on this Mac",
            "  Test response in 0.61 s",
            "  " + ClusterOnboardingDriver.startNotice,
        ] {
            expect(text.contains(line + "\n"), "leader: \(line)")
        }
        // What is done, then the one thing to do next: the last line.
        expect(text.hasSuffix("Done. You can close both windows.\n" + ClusterOnboardingDriver.againLine + "\n"), "leader: the last lines: \(text)")
        expect(!text.contains("Setup sent") && !text.contains("confirmed the code") && !text.contains("Cable found"),
               "leader: no line repeats what another says")
        expect(!text.contains("127.0.0.1"), "leader: no bare loopback address")
        expect(!text.contains("Run `darkbloom cluster` on the other Mac too."), "leader: the link flow's own ending is not repeated")
        expect(!text.contains("press n to stop") && !text.contains("Options:"), "leader: no countdown and no options paragraph after the choice")
        let positions = stages.compactMap { text.range(of: $0)?.lowerBound }
        expect(positions.count == stages.count && positions == positions.sorted(), "setup stages stay in order")
        expect(!text.contains("\u{1B}"), "NO_COLOR transcript has no terminal escapes")
        // The 2026-11-03 call asked for the Start step's notice and an unmistakable outcome block: four lines more.
        expect(visible(text).filter { !$0.isEmpty }.count <= 25, "leader: a short screen: \(visible(text).filter { !$0.isEmpty }.count) lines")
        // 2026-11-03 (owner, from the customer's review): "less is better". The setup's screen keeps to a word budget.
        expect(words(text) <= leaderWordBudget, "leader: at most \(leaderWordBudget) words, got \(words(text))")
        expect(run.keys == 2, "leader: two keys (y, enter), got \(run.keys)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0", "serve",
            "waitReady", "testRequest", "register"], "leader: operations in order: \(recorder.all)")
        expect(!text.lowercased().contains("ssh") && !text.contains("10.219"), "leader: no SSH and no address on screen")
        transcript("leader-from-scratch", text, keys: run.keys)
    }

    /// After the Test stage: a coordinator that serves no approval stops nothing and the setup ends at once; a
    /// registration that stopped the parts, whether it was refused or registered, waits until they serve again
    /// before the screen says Done.
    static func leaderWaitsForThePartsAfterTheRegistration() {
        let cases: [(String, Result<[String], ClusterOnboardingFailure>, String)] = [
            ("refused", .failure(.init("Not offered for pairing: the other Mac refused the cluster approval: the approval's metallib_sha256 differ from this Mac's installation.")),
             "Starting both Macs' parts again…"),
            ("registered", .success([ClusterOnboardingReady.registeredNotice + ": approval devnet/0.10.4-dev.1/Qwen3.5-9B/s1, until 2026-11-12T00:00:00Z."]),
             "Starting both Macs' parts again as cluster members…"),
        ]
        for (label, result, restart) in cases {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
                pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), registerResult: result))
            expect(run.waitFor(codeQuestion), "\(label): the code question")
            run.type("y")
            expect(run.waitFor(prompt(2), count: 2), "\(label): the model choice")
            run.type("\r")
            _ = run.finish()
            let text = run.text
            expect(text.contains(restart), "\(label): the restart line: \(text)")
            // The restarted parts are awaited and tested again: the serving line is about the parts that run now.
            expect(Array(recorder.all.suffix(4)) == ["testRequest", "register", "waitReady", "testRequest"],
                   "\(label): the parts are awaited after the registration: \(recorder.all)")
            let done = text.range(of: "Done.")?.lowerBound, restarted = text.range(of: restart)?.lowerBound
            expect(done != nil && restarted != nil && restarted! < done!, "\(label): Done comes after the parts serve again")
        }
    }

    /// DEVELOPER ONLY (`DARKBLOOM_CLUSTER_FORCE_MODE` in a debug build): a forced mode is said loudly, in one line, on
    /// the setup screen right under the model step's heading; without the setting the screen has no such line.
    static func forcedModeNoticeOnTheSetupScreen() {
        let notice = "Developer setting: tensor parallel forced (DARKBLOOM_CLUSTER_FORCE_MODE=tensor_parallel_v1; debug build only)."
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
            pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), developerNotice: notice))
        expect(run.waitFor(codeQuestion), "forced mode: the code question")
        run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "forced mode: the model choice")
        let text = run.text
        expect(text.contains("\n3/4 Model\n" + notice + "\n"), "forced mode: the notice in one line right under the heading")
        expect(text.components(separatedBy: "Developer setting:").count == 2, "forced mode: said once")
        run.type("\r")
        _ = run.finish()
        transcript("leader-forced-mode", run.text, keys: run.keys)
        let plain = Recorder()
        let other = TerminalRun(operations(plain, pairEvents: leaderEvents,
            pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(other.waitFor(codeQuestion), "no setting: the code question")
        other.type("y")
        expect(other.waitFor(prompt(2), count: 2), "no setting: the model choice")
        expect(!other.text.contains("Developer setting"), "no setting: no developer line on the setup screen")
        other.type("\r")
        _ = other.finish()
    }

    /// The serving API listens on loopback on the Mac that runs rank 0: the line says when that is the other Mac, and
    /// at its end how the pair serves (local only, asked for or a coordinator without cluster support; else earning).
    static func servingLineNamesTheMac() {
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000).summary(model: "Qwen3.5-9B")
            == "Serving Qwen3.5-9B at http://localhost:8000", "serving here")
        expect(ClusterOnboardingReady(servedBy: "the other Mac (Apple M3 Ultra, 256 GB)", port: 8100).summary(model: "Qwen3.5-9B")
            == "Serving Qwen3.5-9B at http://localhost:8100 on the other Mac", "serving there: that Mac said")
        let D = ClusterOnboardingDriver.self
        let notice = "Serving locally on this Mac's API; public serving needs a coordinator with cluster support"
        expect(D.servesWords(scope: .publicServing, ready: .init(servedBy: "this Mac", port: 8000, notice: notice)) == " (local only)",
               "serves: a coordinator without cluster support serves locally")
        expect(D.servesWords(scope: .publicServing, ready: .init(servedBy: "this Mac", port: 8000)) == " (earning through Darkbloom)",
               "serves: through Darkbloom")
        expect(D.servesWords(scope: .publicServing, ready: .init(servedBy: "this Mac", port: 8000,
            notice: ClusterOnboardingReady.registeredNotice + " for m")) == " (earning through Darkbloom)", "serves: registered as a cluster member")
        expect(D.servesWords(scope: .localOnly(bind: "0.0.0.0"), ready: .init(servedBy: "this Mac", port: 8000)) == " (local only)",
               "serves: local only, asked for")
        expect(D.servesWords(scope: .publicServing, ready: .init(servedBy: "this Mac", port: 8000, offered: "offered")) == "",
               "serves: offered for pairing says it itself")
    }

    /// The leader's cluster service keeps each member on the leader's serving state (serve or stop, and the model),
    /// so a member that missed a start or a stop (asleep, restarting, cable out) follows once it answers again.
    static func leaderKeepsMembersInStep() {
        typealias Sync = ClusterOnboardingSync
        expect(Sync.action(leaderServing: true, leaderModel: "9B", memberServing: nil, memberModel: nil) == .none,
            "sync: a member that does not answer is asked again later, nothing sent now")
        expect(Sync.action(leaderServing: true, leaderModel: "9B", memberServing: false, memberModel: nil) == .serve("9B"),
            "sync: a member that missed the start is started")
        expect(Sync.action(leaderServing: true, leaderModel: "27B", memberServing: true, memberModel: "9B") == .serve("27B"),
            "sync: a member on another model is told the leader's")
        expect(Sync.action(leaderServing: true, leaderModel: "9B", memberServing: true, memberModel: "9B") == .none,
            "sync: a member in step is left alone")
        expect(Sync.action(leaderServing: false, leaderModel: "9B", memberServing: true, memberModel: "9B") == .stop,
            "sync: a member that missed the stop is stopped")
        expect(Sync.action(leaderServing: false, leaderModel: nil, memberServing: false, memberModel: nil) == .none,
            "sync: nothing serving, nothing sent (a leader that has not chosen a model yet)")
        expect(Sync.dueEverySeconds > 0 && Sync.dueEverySeconds <= 30, "sync: checked often enough that a member follows within half a minute")
    }

    static func memberFromScratch() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        expect(run.waitFor(codeQuestion), "member: the code question")
        run.type("y")
        let code = run.finish()
        expect(code == 0, "member: exit 0")
        let text = run.text
        expect(text.contains("  \u{2713} Paired. The other Mac leads.\n"), "member: who leads, word for word")
        expect(text.hasSuffix(ClusterOnboardingDriver.joinedLine + " " + ClusterOnboardingDriver.closeWindowLine + "\n"),
               "member: where to continue and whether the window may close, last: \(text)")
        expect(!text.contains("Run `darkbloom cluster` on the other Mac."), "member: never told to run anything on another Mac")
        expect(!text.contains("Found the other Mac"), "member: finding the leader stays on the live line")
        expect(!text.contains("cluster local"), "member: no `local` line for a plain join")
        expect(visible(text).filter { !$0.isEmpty }.count <= 12, "member: a short screen: \(visible(text).filter { !$0.isEmpty }.count) lines")
        expect(words(text) <= memberWordBudget, "member: at most \(memberWordBudget) words, got \(words(text))")
        expect(run.keys == 1, "member: one key (y)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService"], "member: operations \(recorder.all)")
        transcript("member-from-scratch", text, keys: run.keys)
    }

    static func bothWaitingAtOnce() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .waitingAsLeader, .joining, .code("111222", peer: ["Apple M3 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor("Code 111 222"), "tie: code shown"); run.type("y")
        expect(run.finish() == 0, "tie: joins and ends")
        expect(run.text.contains("Paired. The other Mac leads."), "tie: follows the leader")
    }

    static func cancelWhileWaiting() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .waitingAsLeader, .note("still waiting"), .note("still waiting"),
            .note("still waiting"), .note("still waiting"), .note("still waiting"), .note("still waiting"), .note("still waiting")] + Array(repeating: .note(""), count: 200),
            pairResult: .failed(["expired"])))
        expect(run.waitFor("Run `darkbloom cluster` on the other Mac."), "cancel: the wait is on screen")
        run.type("q")
        expect(run.finish() == 130, "cancel: q ends with 130")
        expect(run.text.contains("Cancelled: nothing paired."), "cancel: says nothing was paired")
    }

    static func declinedCode() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "x")))
        expect(run.waitFor(codeQuestion), "declined: code shown"); run.type("n")
        expect(run.finish() == 1, "declined: exit 1")
        expect(run.text.contains("  " + prompt(2) + "No\n"), "declined: the answer on the prompt's line")
        expect(run.text.contains("Declined: nothing paired."), "declined: said")
        expect(run.text.contains("Run `darkbloom cluster` again.\n"), "declined: how to retry")
        expect(!recorder.all.contains("ensureService"), "declined: no service started")
    }

    static func linkNotReady() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, linkReady: false, pairEvents: [], pairResult: .failed([])))
        expect(run.finish() == 1, "link not ready: stops")
        expect(run.text.contains("Cable not ready. Fix the step above, then run `darkbloom cluster` again."), "link not ready: said")
        expect(!run.text.contains("cluster link"), "link not ready: no developer command named")
        expect(recorder.all == ["checkLink"], "link not ready: nothing else ran")
    }

    /// A member is not sent elsewhere: its commands run on the derived control leader (forwarded by the live operations).
    static func memberResume(serving: Bool = true) -> ClusterOnboardingResume {
        var resume = ClusterOnboardingResume(role: .member, peerName: "Apple M3 Ultra, 256 GB", serving: serving, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.leaderName = "Apple M3 Ultra, 256 GB"
        resume.leaderReason = "rank 0 of the adopted plan: requests enter there and the coordinator registers it as the head"
        resume.term = 2
        return resume
    }

    /// 2026-11-02: "why does the member have the choices to change model, test, describe". A member's screen is the
    /// cluster as it is and where to manage it: no list, no key, nothing run but its own service and the status.
    static func memberAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([])))
        expect(run.finish() == 0, "member again: ends by itself")
        let text = run.text
        expect(text.contains("This Mac follows the other Mac\n"), "member again: who leads, in the opening")
        expect(!text.contains("derived") && !text.contains("term ") && !text.contains("rank 0"), "member again: no leadership jargon")
        expect(text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)\n"),
               "member again: the status as the outcome, with how it is split")
        expect(text.hasSuffix(ClusterOnboardingDriver.memberNothingLine + "\n"), "member again: where to manage the cluster, last: \(text)")
        expect(!text.contains("Change model") && !text.contains("Choose 1-"), "member again: no menu")
        expect(recorder.all == ["ensureService", "status"], "member again: its service and the status only: \(recorder.all)")
        expect(run.keys == 0, "member again: no key")
        transcript("member-again", text, keys: run.keys)
    }

    /// `darkbloom cluster` run again on a Mac already in a cluster (the leader or a member) opens with the same
    /// Darkbloom mark as the setup and the part this Mac plays, before anything else is said: the mark and the
    /// name on a colour UTF-8 terminal, the two heading lines in a plain transcript.
    static func resumedMacsOpenWithTheMark() {
        let D = ClusterOnboardingDriver.self
        let resumes: [(String, ClusterOnboardingResume, String)] = [
            ("member", memberResume(), "This Mac follows the other Mac"),
            ("leader", .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"), D.leaderSubtitle),
        ]
        for (label, resume, subtitle) in resumes {
            for colour in [true, false] {
                let recorder = Recorder()
                let environment = colour ? ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"]
                                         : ["NO_COLOR": "1"]
                let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([])),
                                      environment: environment)
                if label == "leader" {
                    expect(run.waitFor(colour ? arrowHint : prompt(6)), "\(label) again (\(colour ? "colour" : "plain")): the menu")
                    run.type("q")
                }
                expect(run.finish() == 0, "\(label) again (\(colour ? "colour" : "plain")): leaves")
                let screen = visible(run.text)
                // Beside the mark the name wraps a word per row ("Darkbloom", then "cluster"); plain text keeps one line.
                let name = colour ? String(D.title.split(separator: " ")[0]) : D.title
                guard let title = screen.firstIndex(where: { $0.contains(name) }),
                      let opening = screen.firstIndex(where: { $0.contains(subtitle) }) else {
                    expect(false, "\(label) again (\(colour ? "colour" : "plain")): the title and the opening line: \(screen)")
                    continue
                }
                expect(title <= opening, "\(label) again (\(colour ? "colour" : "plain")): the name and the part this Mac plays open the screen")
                if colour {
                    expect(ClusterOnboardingBrand.rows().allSatisfy { row in screen.contains { $0.contains(row) } },
                           "\(label) again (colour): the whole mark")
                } else {
                    expect(!run.text.contains("\u{1B}["), "\(label) again (plain): no escape sequences")
                }
                expect(!recorder.all.contains("pair"), "\(label) again: no pairing: \(recorder.all)")
            }
        }
    }

    /// The leader's `darkbloom cluster`: the status, then a list (2026-11-02: "a selectable interface ... like the
    /// normal Darkbloom models"), the first item taken with enter.
    static func leaderAgainServing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(6)), "leader again: the menu")
        let menu = run.text
        expect(menu.contains("  1) Test\n  2) Change model\n  3) Serve locally\n  4) Stop\n  5) Check memory is freed\n  6) Quit\n"),
               "leader again: every choice, one short line each: \(menu)")
        run.type("\r")
        expect(run.finish() == 0, "leader again: test request")
        expect(run.text.contains("  \u{2713} Test response in 0.61 s\n"), "leader again: the answer")
        expect(recorder.all == ["ensureService", "status", "testRequest"], "leader again: no pairing, no plan: \(recorder.all)")
        transcript("leader-again", run.text, keys: run.keys)
    }

    static func leaderPairedNotServing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "leader resumed before a model was chosen: goes to the choice")
        run.type("2")
        expect(run.finish() == 0, "leader resumed: the second model chosen by number, at once")
        expect(recorder.all.contains("adopt 1") && !recorder.all.contains("adopt 0"), "leader resumed: the second model: \(recorder.all)")
    }

    static func noModelOffered() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: [ClusterOnboardingModelChoice(title: "big", lines: [], blocker: "too large for this pair")]))
        expect(run.finish() == 1, "no model: exit 1")
        expect(run.text.contains("No approved model can run on these Macs now.\n  big: too large for this pair\n"),
               "no model: said, with why: \(run.text)")
    }

    // MARK: - Provisioning: no manual model downloads

    static let copyOffer = ClusterOnboardingProvisionOffer(
        lines: ["The other Mac (Apple M3 Ultra, 256 GB): copy from this Mac over the Thunderbolt cable (16.3 GB, about 7 s)"],
        downloadAlternative: true, leaderDownloads: false)

    static let copyChoices = [
        ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"], blocker: nil, provision: copyOffer),
        ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel · this Mac 50% / the other Mac 50%"], blocker: nil)]

    static func leaderCopiesAMissingModelOverTheCable() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices))
        expect(run.waitFor(prompt(2)), "copy: the choice")
        expect(!run.text.contains("needs: "), "copy: the list stays one line per model")
        run.type("\r")
        expect(run.waitFor("  1) Copy to the other Mac\n  2) Download\n  3) Cancel\n  " + prompt(3)), "copy: the cable first, as a list that says what moves")
        expect(!run.text.contains("is not on every Mac yet") && run.text.contains("  1) Qwen3.8-27B-4bit-mtp · 16.3 GB · copy\n"),
               "copy: the model's line says a copy is needed, nothing more: \(run.text)")
        run.type("\r")
        expect(run.waitFor("  Copying to the other Mac: 8.2 of 16.3 GB, 2.40 GB/s, about 1 s left"), "copy: progress on the leader")
        expect(run.waitFor("  \u{2713} Copied to the other Mac (16.3 GB, 6.9 s)\n"), "copy: done, verified")
        expect(run.finish() == 0, "copy: served")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "provision 0 copy", "recheckFit 0", "adopt 0", "serve", "waitReady", "testRequest",
                                "register"], "copy: copied before the setup is synced: \(recorder.all)")
        expect(run.keys == 2, "copy: enter (model), enter (copy); got \(run.keys)")
        expect(!run.text.lowercased().contains("ssh") && !run.text.contains("--model-dir"), "copy: no SSH, no model folder to type")
        transcript("leader-copies-missing-model", run.text, keys: run.keys)
    }

    static func leaderChoosesTheCatalogInstead() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices))
        expect(run.waitFor(prompt(2)), "catalog: the choice"); run.type("\r")
        expect(run.waitFor("  2) Download\n"), "catalog: the alternative is offered"); run.type("2")
        expect(run.finish() == 0, "catalog: served after the download")
        expect(recorder.all.contains("provision 0 download") && recorder.all.contains("adopt 0"), "catalog: downloaded, then adopted: \(recorder.all)")
    }

    static func leaderDownloadsAModelNoMacHas() {
        let recorder = Recorder()
        let offer = ClusterOnboardingProvisionOffer(lines: ["This Mac: download from Darkbloom's catalog (16.3 GB)",
            "The other Mac (Apple M3 Ultra, 256 GB): copy from this Mac over the Thunderbolt cable (16.3 GB)"],
            downloadAlternative: false, leaderDownloads: true)
        let before = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · not on these Macs: downloaded from Darkbloom's catalog first"],
                                                   blocker: nil, provision: offer)]
        let after = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers", "rank 1 (decodes): Apple M5 Ultra, 256 GB (this Mac), layers 32-63"], blocker: nil)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: before, replanned: after))
        expect(run.waitFor(prompt(1)), "download: a catalog model is offered"); run.type("\r")
        expect(run.text.contains("  1) Qwen3.8-27B-4bit-mtp · 16.3 GB · download\n"), "download: the model's line says it is downloaded first")
        expect(run.waitFor("  1) Download\n  2) Cancel\n"), "download: one choice"); run.type("\r")
        expect(run.finish() == 0, "download: served")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "provision 0 copy", "planModels", "recheckFit 0", "adopt 0", "serve", "waitReady",
                                "testRequest", "register"], "download: downloaded, planned again, then adopted: \(recorder.all)")
        transcript("leader-downloads-model", run.text, keys: run.keys)
    }

    /// A download's reports from 0% to 100%, every 25 points logged, then its line for the record; `widths` notes
    /// the width each report was laid out for.
    static func downloadReports(widths: Recorder) -> [ClusterOnboardingProgress] {
        (0...100).map { percent in
            .live({ width in
                widths.note(width.map(String.init) ?? "plain")
                return "Downloading  \(percent)%  \(String(format: "%.1f", 0.163 * Double(percent)))/16.3 GB"
            }, logged: percent % 25 == 0)
        } + [.line("\u{2713} Downloaded (16.3 GB, 130.2 s)")]
    }

    /// A download reports four times a second for minutes. A live terminal redraws its reports on one row, laid out
    /// for the live line's room, and the line for the record takes that row; a transcript keeps the logged reports
    /// only. Neither adds a line per report.
    static func downloadProgressStaysOnOneLine() {
        let offer = ClusterOnboardingProvisionOffer(lines: ["This Mac: download from Darkbloom's catalog (16.3 GB)"],
            downloadAlternative: false, leaderDownloads: true)
        let before = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · not on these Macs: downloaded from Darkbloom's catalog first"],
                                                   blocker: nil, provision: offer)]
        let after = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"], blocker: nil)]
        for colour in [true, false] {
            let label = colour ? "live download" : "plain download"
            let widths = Recorder()
            let environment = colour ? ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"] : ["NO_COLOR": "1"]
            let run = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
                pairResult: .failed([]), choices: before, replanned: after, provisionReports: downloadReports(widths: widths),
                provisionReportPause: 2_000),
                environment: environment, columns: 100)
            expect(run.waitFor(colour ? arrowHint : prompt(1)), "\(label): the choice"); run.type("\r")
            expect(run.waitFor(colour ? arrowHint : prompt(2), count: colour ? 2 : 1), "\(label): get it"); run.type("\r")
            expect(run.finish() == 0, "\(label): served after the download")
            let rows = run.text.components(separatedBy: "\n").filter { $0.contains("Downloading  ") }
            let screen = visible(run.text)
            expect(screen.contains("  \u{2713} Downloaded (16.3 GB, 130.2 s)"), "\(label): the line for the record")
            if colour {
                expect(rows.count == 1, "\(label): every report on one row, got \(rows.count) rows")
                expect(!screen.contains { $0.contains("Downloading  ") }, "\(label): the line for the record took the live row")
                expect(!widths.all.isEmpty && Set(widths.all) == ["94"], "\(label): laid out for the live line's room: \(Set(widths.all))")
            } else {
                expect(rows.map { $0.split(separator: " ").first { $0.hasSuffix("%") }.map(String.init) } == ["0%", "25%", "50%", "75%", "100%"],
                    "\(label): only the logged reports, each on its own line: \(rows)")
                expect(widths.all == Array(repeating: "plain", count: 5), "\(label): plain lines, no width: \(widths.all)")
                expect(!run.text.contains("\u{1B}[K"), "\(label): nothing redrawn")
            }
            transcript(colour ? "leader-download-live-progress" : "leader-download-plain-progress", run.text, keys: run.keys)
        }
    }

    static func copyDeclined() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices))
        expect(run.waitFor(prompt(2)), "declined copy: choice"); run.type("\r")
        expect(run.waitFor("3) Cancel"), "declined copy: offer"); run.type("3")
        expect(run.finish() == 0, "declined copy: exit 0")
        expect(run.text.hasSuffix("Nothing changed.\n"), "declined copy: said")
        expect(!recorder.all.contains { $0.hasPrefix("provision") || $0.hasPrefix("adopt") }, "declined copy: nothing moved or adopted")
    }

    static func copyBlockedByDisk() {
        let recorder = Recorder()
        let blocked = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: [], blocker: nil, provision: .init(lines: ["The other Mac (Apple M3 Ultra, 256 GB): copy from this Mac over the Thunderbolt cable (6.1 GB) — cannot start: the other Mac (Apple M3 Ultra, 256 GB) has 3.0 GB free; the model needs 16.3 GB and 2.1 GB to spare"],
            downloadAlternative: true, leaderDownloads: false, blocker: "the other Mac (Apple M3 Ultra, 256 GB) has 3.0 GB free; the model needs 16.3 GB and 2.1 GB to spare"))]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: blocked))
        expect(run.waitFor(prompt(1)), "disk: choice"); run.type("\r")
        expect(run.finish() == 1, "disk: exit 1")
        expect(run.text.contains("Can't start Qwen3.8-27B-4bit-mtp: the other Mac (Apple M3 Ultra, 256 GB) has 3.0 GB free; the model needs 16.3 GB and 2.1 GB to spare. Free space, then run `darkbloom cluster` again."),
            "disk: the free-disk refusal in words")
        expect(!recorder.all.contains { $0.hasPrefix("provision") }, "disk: nothing started")
    }

    static func copyInterrupted() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices, provisionResult: .failure(.init("The copy to the other Mac (Apple M3 Ultra, 256 GB) stopped at 2.0 of 16.3 GB: the cable connection ended."))))
        expect(run.waitFor(prompt(2)), "interrupted: choice"); run.type("\r")
        expect(run.waitFor("3) Cancel"), "interrupted: offer"); run.type("\r")
        expect(run.finish() == 1, "interrupted: exit 1")
        expect(run.text.contains("Run `darkbloom cluster` again to resume."), "interrupted: resumes next time")
        expect(!recorder.all.contains("adopt 0"), "interrupted: no setup synced for a model a Mac lacks")
    }

    // MARK: - A short copy is a list like any other (2026-11-02: no key to press to do something)

    static let quickOffer = ClusterOnboardingProvisionOffer(
        lines: ["The other Mac (Apple M3 Ultra, 256 GB): copy from this Mac over the Thunderbolt cable (16.3 GB, about 7 s)"],
        downloadAlternative: true, leaderDownloads: false, quickSeconds: 6.9)

    /// A copy predicted under 30 s (from the copy rate measured on these Macs) is the list's first item, its time on
    /// it, so enter takes it: no countdown, nothing that starts by itself, no letter keys.
    static func shortCopyIsAListLikeAnyOther() {
        let recorder = Recorder()
        let choices = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"], blocker: nil, provision: quickOffer)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor(prompt(1)), "short copy: the choice"); run.type("\r")
        expect(run.waitFor("  1) Copy to the other Mac (about 7 s)\n  2) Download\n  3) Cancel\n  " + prompt(3)),
               "short copy: the copy first in the list, its time on it")
        usleep(300_000)
        expect(!recorder.all.contains { $0.hasPrefix("provision") }, "short copy: nothing starts by itself: \(recorder.all)")
        run.type("\r")
        expect(run.finish() == 0, "short copy: served")
        expect(!run.text.contains("press n") && !run.text.contains("d to download") && !run.text.contains("in the next 3 s"), "short copy: no keys to learn")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "provision 0 copy", "recheckFit 0", "adopt 0", "serve", "waitReady", "testRequest",
                                "register"], "short copy: copied before the setup is synced: \(recorder.all)")
        expect(run.keys == 2, "short copy: enter (model), enter (copy); got \(run.keys)")
        transcript("leader-short-copy-not-asked", run.text, keys: run.keys)
    }

    /// The list's last item stops there, and so does q.
    static func shortCopyStopsFromItsList() {
        for (label, key) in [("cancel", "3"), ("q", "q")] {
            let recorder = Recorder()
            let choices = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: [], blocker: nil, provision: quickOffer)]
            let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
                choices: choices))
            expect(run.waitFor(prompt(1)), "short copy, \(label): choice"); run.type("\r")
            expect(run.waitFor(prompt(3)), "short copy, \(label): the list"); run.type(key)
            expect(run.finish() == 0, "short copy, \(label): exit 0")
            expect(run.text.hasSuffix("Nothing changed.\n"), "short copy, \(label): said")
            expect(!recorder.all.contains { $0.hasPrefix("provision") || $0.hasPrefix("adopt") }, "short copy, \(label): nothing moved: \(recorder.all)")
        }
    }

    // MARK: - One-command fixes (2026-10-14)

    static func deploymentWords() {
        typealias D = ClusterOnboardingDeployment
        expect(D.shortName("Apple M5 Ultra, 256 GB") == "M5 Ultra", "short name: chip only")
        let pipeline = [D.Share(name: "Apple M3 Ultra, 256 GB", layers: 40), D.Share(name: "Apple M5 Ultra, 256 GB", layers: 24)]
        expect(D.line(model: "Qwen3.8-27B", mode: "pipeline_v1", shares: pipeline)
            == "Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers", "pipeline line: \(D.line(model: "Qwen3.8-27B", mode: "pipeline_v1", shares: pipeline))")
        expect(D.line(model: "Qwen3.8-27B", mode: "pipeline_compact_decode_v1", shares: pipeline).contains(": pipeline, "), "compact decode is pipeline")
        let tp = [D.Share(name: "Apple M3 Ultra, 256 GB", layers: nil, weightsBytes: 6_000), D.Share(name: "Apple M5 Ultra, 256 GB", layers: nil, weightsBytes: 4_000)]
        expect(D.line(model: "Qwen3.8-27B", mode: "tensor_parallel_v1", shares: tp)
            == "Serving Qwen3.8-27B across both Macs: tensor parallel, M3 Ultra 60% / M5 Ultra 40%", "TP line, automatic from the plan's mode")
        expect(D.line(model: "Qwen3.8-27B", mode: "pipeline_prefill_tensor_decode_v1", shares: tp)
            == "Serving Qwen3.8-27B across both Macs: pipeline prefill, tensor parallel decode, M3 Ultra 60% / M5 Ultra 40%", "the hybrid in words")
        let same = [D.Share(name: "Apple M2 Max, 64 GB", layers: 16), D.Share(name: "Apple M2 Max, 96 GB", layers: 16)]
        expect(D.sharesWords(mode: "pipeline_v1", shares: same) == "Apple M2 Max, 64 GB 16 layers / Apple M2 Max, 96 GB 16 layers", "two Macs of one kind: full names")
        let three = pipeline + [D.Share(name: "Apple M4 Pro, 48 GB", layers: 8)]
        expect(D.line(model: "m", mode: "pipeline_v1", shares: three).hasPrefix("Serving m across 3 Macs: pipeline, "), "three Macs")
        expect(D.modeWords("something_new_v2") == "split across the Macs", "an unknown mode is never shown raw")
        expect(D.modeWords("phase_split_mtp_v1") == "prompt split, then one Mac decodes", "phase split in words, never claimed as an opt-in")
        expect(D.modeWords("pipeline_mtp_v1") == "pipeline with speculative decoding", "the pipeline's speculative rounds in words")
        // The marker the owner kept (2026-11-03): tensor parallel or pipeline, whatever the pipeline's framing.
        for (mode, marker) in [("tensor_parallel_v1", "tensor parallel"), ("pipeline_v1", "pipeline"), ("pipeline_compact_decode_v1", "pipeline"),
                               ("pipeline_mtp_v1", "pipeline"), ("phase_split_v1", "prompt split, then one Mac decodes"),
                               ("pipeline_prefill_tensor_decode_v1", "pipeline prefill, tensor parallel decode")] {
            expect(D.splitMarker(mode) == marker, "split marker: \(mode) -> \(String(describing: D.splitMarker(mode)))")
        }
        expect(D.splitMarker("something_new_v2") == nil, "split marker: an unknown mode is not marked")
        expect(D.choiceLine(size: "6.1 GB", mode: "pipeline_v1", shares: pipeline, speed: "about 90 tokens/s")
            == "6.1 GB · pipeline · M3 Ultra 40 layers / M5 Ultra 24 layers · about 90 tokens/s", "choice line: one line, no ranks")
    }

    /// The approval line is on screen while checkLink still runs (the macOS prompt is up then), not after it returns.
    static func cableLinesStreamBeforeTheApproval() {
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), approvalGate: gate))
        expect(run.waitFor("approve the macOS prompt (once per Mac).", seconds: 3), "cable: the approval line shows while the prompt is up")
        gate.signal()
        expect(run.waitFor(codeQuestion), "cable: then pairing"); run.type("y")
        expect(run.finish() == 0, "cable: member done")
        expect(!run.text.contains("Cable found") && run.text.contains("  \u{2713} Cable ready\n"), "cable: one done line")
    }

    static func twoCablesAreAskedOnScreen() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), linkPorts: ["en5", "en6"]))
        expect(run.waitFor("  Which cable goes to the other Mac?\n  1) en5\n  2) en6\n  " + prompt(2)), "two cables: asked as a list")
        run.type("2")
        expect(run.waitFor(codeQuestion), "two cables: pairing goes on"); run.type("y")
        expect(run.finish() == 0, "two cables: done")
        expect(recorder.all.prefix(3) == ["checkLink", "useLinkPort en6", "checkLink"], "two cables: the chosen port is set up: \(recorder.all)")
        expect(!run.text.contains("cluster link") && !run.text.contains("--device"), "two cables: no developer command")
        transcript("two-cables", run.text, keys: run.keys)
    }

    static func fittingChoicesComeFirst() {
        let recorder = Recorder()
        let choices = [
            ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel · M3 Ultra 50% / M5 Ultra 50%"], blocker: nil,
                fitRemedy: "Quit apps on the other Mac (Apple M3 Ultra, 256 GB) first."),
            ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · M3 Ultra 32 layers / M5 Ultra 32 layers"], blocker: nil)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor(prompt(2)), "fit: the choice")
        expect(run.text.contains("  1) Qwen3.8-27B-4bit-mtp · 16.3 GB\n  2) Z.ai: GLM-5.3-Flash · 181.8 GB · does not fit now\n"),
               "fit: the one that fits is 1, the one that does not is marked on its line: \(run.text)")
        run.type("\r")
        expect(run.finish() == 0, "fit: served")
        expect(recorder.all.contains("adopt 1") && !recorder.all.contains("adopt 0"), "fit: enter chose the fitting model: \(recorder.all)")
    }

    static func fitRecheckedBeforeTheStart() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            recheck: "Restart the other Mac (Apple M3 Ultra, 256 GB) to free memory."))
        expect(run.waitFor(prompt(2)), "recheck: choice"); run.type("\r")
        expect(run.finish() == 1, "recheck: stops at once")
        expect(run.text.contains("Qwen3.8-27B-4bit-mtp doesn't fit in free memory now: Restart the other Mac (Apple M3 Ultra, 256 GB) to free memory.\nNothing changed.\n"),
               "recheck: the remedy, then that nothing changed")
        expect(!recorder.all.contains { $0.hasPrefix("adopt") || $0 == "serve" || $0 == "waitReady" }, "recheck: nothing adopted or started: \(recorder.all)")
    }

    static func timeoutOffersADiagnosticsFile() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            readyResult: .failure(.init(["The cluster did not report ready within 15 minutes.", "The other Mac (Apple M3 Ultra, 256 GB): its part ended: out of memory.",
                                         "This Mac: loading layers 16-31."]))))
        expect(run.waitFor(prompt(2)), "timeout: choice"); run.type("\r")
        // A start that did not finish stays open with the choices; Diagnostics is one of them.
        expect(run.waitFor(notServingChoices), "timeout: the choices, diagnostics among them: \(run.text)")
        run.type("4")
        expect(run.waitFor(notServingChoices, count: 2), "timeout: the choices again after the file")
        run.type("q")
        expect(run.finish() == 1, "timeout: exit 1")
        expect(run.text.contains("\u{2717} Not serving: The cluster did not report ready within 15 minutes.\n"), "timeout: why, first")
        expect(!run.text.contains("Done."), "timeout: never Done")
        expect(run.text.contains("The other Mac (Apple M3 Ultra, 256 GB): its part ended: out of memory."), "timeout: each Mac's last error on screen")
        expect(run.text.contains("Saved a diagnostics file"), "timeout: the file is saved")
        expect(!run.text.contains("rank.log"), "timeout: no log path")
        expect(recorder.all.contains("saveDiagnostics"), "timeout: saved through the operation")
    }

    static func restartLineAtTheEnd() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            afterRestart: "After a restart, this Mac serves again once someone logs in."))
        expect(run.waitFor(prompt(2)), "restart line: choice"); run.type("\r")
        expect(run.finish() == 0, "restart line: served")
        expect(run.text.contains("After a restart, this Mac serves again once someone logs in.\nDone. "),
            "restart line: what happens after a restart, from the service's real state, before Done")
    }

    /// What happens after a restart, from the Mac's own settings (A9): never a promise a FileVault Mac cannot keep.
    static func restartWords() {
        typealias R = ClusterOnboardingRestart
        expect(R.line(mac: "this Mac", autoLogin: true, fileVault: false) == "After a restart, this Mac serves again by itself.", "restart: auto-login on")
        expect(R.line(mac: "this Mac", autoLogin: false, fileVault: true) == "After a restart, this Mac serves again once someone logs in.",
               "restart: FileVault on")
        expect(R.line(mac: "this Mac", autoLogin: false, fileVault: false)
            == "After a restart, this Mac serves again once someone logs in (or turn on automatic login).", "restart: auto-login off, the plain remedy")
        expect(R.line(mac: "this Mac", autoLogin: false, fileVault: nil).contains("once someone logs in"), "restart: FileVault unknown, no promise")
        for line in [R.line(mac: "x", autoLogin: false, fileVault: true), R.line(mac: "x", autoLogin: false, fileVault: false)] {
            expect(!line.contains("by itself"), "restart: no 'by itself' promise without auto-login: \(line)")
        }
    }

    /// The control leader notices a Darkbloom update (A4): a changed worker digest on either Mac; an unknown one is no reason.
    static func updateNoticed() {
        typealias U = ClusterOnboardingUpdate
        let pinned = ["mac-a": "aaaa", "mac-b": "bbbb"]
        expect(U.changed(pinned: pinned, current: ["mac-a": "aaaa", "mac-b": "bbbb"]).isEmpty, "update: nothing changed")
        expect(U.changed(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": "bbbb"]) == ["mac-a"], "update: this Mac updated")
        expect(U.changed(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": "b2b2"]) == ["mac-a", "mac-b"], "update: both updated")
        expect(U.changed(pinned: pinned, current: ["mac-a": "aaaa", "mac-b": nil]).isEmpty, "update: a Mac that did not answer is no reason")
        expect(U.changed(pinned: pinned, current: [:]).isEmpty, "update: nothing known, nothing re-planned")
        // The pair's coordinated update restarts both Macs seconds apart: plan again once both answer with one build.
        expect(U.oneBuild(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": "a2a2"]), "update: both run the new build: plan again")
        expect(!U.oneBuild(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": "bbbb"]), "update: the other Mac still runs the old build: wait")
        expect(!U.oneBuild(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": nil]), "update: the other Mac has not answered yet: wait")
        expect(!U.oneBuild(pinned: pinned, current: ["mac-a": "a2a2"]), "update: the other Mac not asked: wait")
        expect(!U.oneBuild(pinned: [:], current: [:]), "update: no setup, nothing to plan")
        expect(U.statusLine == "Updating the cluster setup after a Darkbloom update.", "update: the status line")
        expect(U.checkEverySeconds <= 60 && U.retryAfterFailureSeconds >= 300, "update: noticed within a minute, a failure not retried in a loop")
        // The re-plan waits for both Macs' memory: every Mac's summary, and both of them.
        expect(U.released(["Mac A: nothing left running", "Mac B: nothing left running"]), "update: both released")
        expect(!U.released(["Mac A: nothing left running", "Mac B: still running: this Mac's part of the model is still running"]),
               "update: one Mac still holds its part")
        expect(!U.released(["Mac A: nothing left running", "Mac B: did not answer (timeout)"]), "update: a Mac that did not answer")
        expect(!U.released(["Mac A: nothing left running"]), "update: one Mac's summary is not both")
        expect(U.releaseWaitSeconds >= 93, "update: the wait covers a part's forced exit")
        // The other Mac's memory prices the plan only from a report taken after the parts stopped (2026-10-22: the
        // report taken before the stop still counted its tensor-parallel part, and a pipeline was chosen).
        let stoppedAt = Date(timeIntervalSince1970: 1_000)
        expect(!U.reportPricesPlan(reportedAt: stoppedAt.addingTimeInterval(-22), partsStoppedAt: stoppedAt),
               "update: a report taken before the stop is asked again")
        expect(!U.reportPricesPlan(reportedAt: nil, partsStoppedAt: stoppedAt), "update: no report after a stop is asked for")
        expect(U.reportPricesPlan(reportedAt: stoppedAt.addingTimeInterval(40), partsStoppedAt: stoppedAt),
               "update: a report taken after the stop prices the plan")
        expect(U.reportPricesPlan(reportedAt: stoppedAt, partsStoppedAt: nil), "update: without a stop, the report taken before the list prices it")
        // A list planned again after the parts stopped (an update, or a model change of a serving cluster) is searched
        // by the model's id, not the earlier list's index (2026-10-29: `darkbloom cluster local` on a serving pair
        // adopted the pipeline listed while its tensor-parallel part still held the memory).
        let copy = ClusterOnboardingProvisionOffer(lines: ["copy over the cable"], downloadAlternative: false, leaderDownloads: false)
        let replanned = [
            ClusterOnboardingModelChoice(title: "Qwen 3.5 9B", lines: [], blocker: nil, provision: copy, modelID: "Qwen3.5-9B"),
            ClusterOnboardingModelChoice(title: "PrismML Bonsai 2 27B", lines: [], blocker: "does not fit", modelID: "bonsai-2-27b"),
            ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel"], blocker: nil,
                                         modelID: "glm-5.3-flash"),
            ClusterOnboardingModelChoice(title: "local-folder", lines: [], blocker: nil),
        ]
        expect(U.servableIndex(of: "glm-5.3-flash", in: replanned) == 2, "re-plan: the model found by its id where the new list put it")
        expect(U.servableIndex(of: "Z.ai: GLM-5.3-Flash", in: replanned) == nil, "re-plan: a catalog name is not the model's id")
        expect(U.servableIndex(of: "local-folder", in: replanned) == 3, "re-plan: a choice without an id is found by its title")
        expect(U.servableIndex(of: "bonsai-2-27b", in: replanned) == nil, "re-plan: a blocked model cannot start")
        expect(U.servableIndex(of: "Qwen3.5-9B", in: replanned) == nil, "re-plan: a model to copy first cannot start as listed")
        expect(U.servableIndex(of: "gone", in: replanned) == nil, "re-plan: a model no longer listed")
        let both = replanned + [ClusterOnboardingModelChoice(title: "Qwen 3.5 9B", lines: ["6.1 GB · pipeline"], blocker: nil, modelID: "Qwen3.5-9B")]
        expect(U.servableIndex(of: "Qwen3.5-9B", in: both) == 4, "re-plan: an entry of the model that can start is found past one to copy first")
        let twoFolders = [
            ClusterOnboardingModelChoice(title: "GLM-5.3-Flash", lines: ["tensor parallel"], blocker: nil, modelID: "glm-5.3-flash"),
            ClusterOnboardingModelChoice(title: "GLM-5.3-Flash", lines: ["tensor parallel"], blocker: nil, modelID: "glm-5.3-flash"),
        ]
        expect(U.servableIndex(of: "glm-5.3-flash", folder: "/models/b", in: twoFolders, folders: ["/models/a", "/models/b"]) == 1,
               "re-plan: of two folders with one model id, the chosen folder's entry")
        expect(U.servableIndex(of: "glm-5.3-flash", folder: "/models/gone", in: twoFolders, folders: ["/models/a", "/models/b"]) == 0,
               "re-plan: the chosen folder is gone, so the model's first entry that can start")
        expect(U.servableIndex(of: "Qwen3.5-9B", folder: "/models/q", in: both, folders: ["", "", "", "", "/models/q"]) == 4,
               "re-plan: the chosen folder's entry, found past one to copy first")
        expect(U.servableIndex(of: "Qwen3.5-9B", folder: "/models/copy", in: both, folders: ["/models/copy", "", "", "", "/models/q"]) == 4,
               "re-plan: the chosen folder's entry needs a copy first, so the entry that can start")
    }

    /// The exact text and key count of a flow, for the evidence.
    static func transcript(_ name: String, _ text: String, keys: Int) {
        guard let directory = ProcessInfo.processInfo.environment["ONBOARDING_TRANSCRIPTS"] else { return }
        try? (text + "\n[keys typed: \(keys)]\n").write(toFile: directory + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }

    /// F9: a leader whose model was stopped gets the menu (choose a model, or check the memory), not straight to the
    /// model chooser, so checking that both Macs released their memory is reachable after the stop.
    static func stoppedLeaderOffersTeardown() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("  1) Choose a model\n  2) Serve locally\n  3) Check memory is freed\n  4) Quit\n"),
               "stopped leader: the menu")
        run.type("3")
        expect(run.finish() == 0, "stopped leader: teardown checked")
        expect(run.text.contains("  This Mac: nothing left running"), "stopped leader: each Mac's summary")
        expect(recorder.all == ["ensureService", "status", "verifyTeardown"], "stopped leader: status then teardown, no planning: \(recorder.all)")
    }

    /// F16: a model is shown by its catalog display name; its id only when the catalog has no name for it.
    static func modelTitlesAreCatalogNames() {
        typealias D = ClusterOnboardingDeployment
        let names = ["mimo-v2.6-flash-mopd": "MiMo V2.6 Flash", "EigenLabs/Qwen3.8-27B-4bit-mtp": "Qwen3.8 27B", "blank": "  "]
        expect(D.title(modelID: "mimo-v2.6-flash-mopd", displayNames: names) == "MiMo V2.6 Flash", "MiMo by name")
        expect(D.title(modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", displayNames: names) == "Qwen3.8 27B", "27B by name")
        expect(D.title(modelID: "Qwen3.5-9B", displayNames: names) == "Qwen3.5-9B", "no catalog name: the id")
        expect(D.title(modelID: "blank", displayNames: names) == "blank", "an empty name is never shown")
        expect(D.title(modelID: "m", displayNames: ["m": "Model\u{1B}[2J"]) == "m", "a name with terminal control characters is never shown")
        expect(D.title(modelID: "m", displayNames: ["m": String(repeating: "x", count: 200)]) == "m", "an overlong name is never shown")
    }

    /// F16: the deployment line (mode and each Mac's layers) is what any Mac that answers shows, including a member that
    /// leads later (MiMo's rank 0 was the M5 Ultra): the start carries it, and a start for another model never keeps the
    /// previous model's line.
    static func deploymentTravelsWithTheStart() {
        typealias D = ClusterOnboardingDeployment
        let line = "Serving MiMo V2.6 Flash across both Macs: pipeline, M5 Ultra 40 layers / M3 Ultra 8 layers"
        expect(D.recorded(afterStartOf: "mimo-v2.6-flash-mopd", deployment: line, recorded: nil) == line, "the leader's line is recorded")
        expect(D.recorded(afterStartOf: "mimo-v2.6-flash-mopd", deployment: nil, recorded: "Serving Qwen3.5-9B across both Macs: pipeline") == nil,
               "a start without a line (an older leader) drops the old model's line")
        expect(D.recorded(afterStartOf: nil, deployment: nil, recorded: line) == line, "a start naming no model changes nothing")
        expect(D.recorded(afterStartOf: "m", deployment: "Serving m\u{1B}]0;x\u{7}", recorded: line) == nil, "a line with control characters is not recorded")
    }

    // MARK: - `darkbloom cluster local` (owner 2026-10-15): failing first on 69ba75be7 (no scope, no request).

    static let localRequest = ClusterOnboardingRequest(scope: .localOnly(bind: ClusterServingScope.localOnlyDefaultBind))

    static let localReady = ClusterOnboardingReady(servedBy: "this Mac", port: 8000,
        deployment: "Serving Qwen3.8-27B-4bit-mtp across both Macs: pipeline, M4 Max 32 layers / M4 Max 32 layers",
        notice: "Serving locally only on this Mac's API: no coordinator, no public traffic", network: true)

    /// From scratch with `darkbloom cluster local`: the same pairing and choice, the screen says the cluster serves
    /// locally only, and the scope is saved after the adopt and before the start.
    static func localFromScratch() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents,
            pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), readyResult: .success(localReady)), request: localRequest)
        expect(run.waitFor(codeQuestion), "local from scratch: the same pairing")
        run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "local from scratch: the same choice")
        run.type("\r")
        expect(run.finish() == 0, "local from scratch: exit 0")
        let text = run.text
        expect(text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp on this Mac's local API only\n  " + localReady.apiLine + "\n"),
               "local from scratch: the outcome, the network and local only on it: \(text)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0",
            "setScope local 0.0.0.0", "serve", "waitReady", "testRequest"], "local from scratch: scope saved after the adopt, before the start: \(recorder.all)")
        expect(run.keys == 2, "local from scratch: the same two keys (y, enter), got \(run.keys)")
        transcript("local-from-scratch", text, keys: run.keys)
    }

    /// `darkbloom cluster local` on a paired leader that is not serving: straight to the choice (the command asks to serve).
    static func localOnAStoppedLeader() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)), request: localRequest)
        expect(run.waitFor(prompt(2)), "local, stopped leader: goes to the choice")
        run.type("2")
        expect(run.finish() == 0, "local, stopped leader: exit 0")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "recheckFit 1", "adopt 1", "setScope local 0.0.0.0", "serve", "waitReady", "testRequest"],
               "local, stopped leader: no menu, scope then start: \(recorder.all)")
    }

    /// `darkbloom cluster local` while the cluster serves through Darkbloom: switched at once (no menu, no key), and the
    /// screen waits for the leading part to serve again.
    static func localSwitchesAServingCluster() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)), request: localRequest)
        expect(run.finish() == 0, "local switch: exit 0")
        let text = run.text
        expect(text.contains(ClusterServingScope.localOnly(bind: "0.0.0.0").line + ".\n"), "local switch: how it serves now")
        expect(text.contains("  \u{2713} Serving Qwen3.8-27B-4bit-mtp at http://localhost:8000 and on the network (local only)\n"),
               "local switch: ready again, local only")
        expect(recorder.all == ["ensureService", "setScope local 0.0.0.0", "waitReady"], "local switch: \(recorder.all)")
        expect(run.keys == 0, "local switch: no key")
    }

    /// `darkbloom cluster local` when it already serves locally only: the ordinary menu, whose scope item switches back.
    static func localAgainShowsTheMenu() {
        let recorder = Recorder()
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "0.0.0.0")
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([])), request: localRequest)
        expect(run.waitFor("  3) Serve through Darkbloom\n"), "local again: the menu offers the other way")
        run.type("q")
        expect(run.finish() == 0, "local again: q leaves it")
        expect(recorder.all == ["ensureService", "status"], "local again: nothing changed: \(recorder.all)")
    }

    /// Plain `darkbloom cluster`: the scope item switches a serving cluster to local only and back; each waits for it
    /// to serve. Stopped, it saves the scope for the next start.
    static func menuKeysSwitchTheScope() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)))
        expect(run.waitFor("  3) Serve locally\n"), "menu: local only is offered")
        run.type("3")
        expect(run.finish() == 0, "menu local: exit 0")
        expect(recorder.all == ["ensureService", "status", "setScope local 0.0.0.0", "waitReady"], "menu local: \(recorder.all)")

        let back = Recorder()
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "0.0.0.0")
        let again = TerminalRun(operations(back, resume: resume, pairEvents: [], pairResult: .failed([])))
        expect(again.waitFor("  3) Serve through Darkbloom\n"), "menu: through Darkbloom is offered when local only")
        again.type("3")
        expect(again.finish() == 0, "menu public: exit 0")
        expect(back.all == ["ensureService", "status", "setScope public", "waitReady"], "menu public: \(back.all)")
        expect(again.text.contains(ClusterServingScope.publicServing.line + ".\n"), "menu public: said")

        let stopped = Recorder()
        let idle = TerminalRun(operations(stopped, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])))
        expect(idle.waitFor("  2) Serve locally\n"), "menu, stopped: local only is offered")
        idle.type("2")
        expect(idle.finish() == 0, "menu local, stopped: exit 0")
        expect(stopped.all == ["ensureService", "status", "setScope local 0.0.0.0"], "menu local, stopped: saved, nothing started: \(stopped.all)")
        expect(idle.text.contains("Takes effect at the next start."), "menu local, stopped: when it applies")
    }

    /// `darkbloom cluster local <model>`: the named model (id or title, any case) is chosen without the list.
    static func localNamesTheModel() {
        let recorder = Recorder()
        var request = localRequest
        request.model = "qwen3.8-27b-4bit-MTP"
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)), request: request)
        expect(run.finish() == 0, "named model: exit 0")
        expect(!run.text.contains("Choose 1-"), "named model: no list")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0", "setScope local 0.0.0.0", "serve", "waitReady", "testRequest"],
               "named model: adopt (which stops the old one) before the scope: \(recorder.all)")

        let blocked = Recorder()
        request.model = "gpt-oss-20b"
        let refused = TerminalRun(operations(blocked, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])), request: request)
        expect(refused.finish() == 1, "named blocked model: exit 1")
        expect(refused.text.contains("gpt-oss-20b can't run on these Macs: not granted for this pair of chips.\n"), "named blocked model: why")
        expect(blocked.all == ["ensureService", "reachMembers", "planModels"], "named blocked model: nothing adopted: \(blocked.all)")

        let unknown = Recorder()
        request.model = "no-such-model"
        let asked = TerminalRun(operations(unknown, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])), request: request)
        expect(asked.waitFor("No model on the list is named no-such-model.\n"), "unknown model: said")
        expect(asked.waitFor(prompt(2)), "unknown model: the list asks")
        asked.type("\r")
        expect(asked.finish() == 0, "unknown model: the first choice served after enter")
        expect(unknown.all.contains("adopt 0"), "unknown model: the typed choice is adopted: \(unknown.all)")
    }

    /// A Mac that joins with `darkbloom cluster local` (a model named too) stops once paired, as a plain join does:
    /// the Mac that leads chooses the model and how the cluster serves, and the screen says to run the command there.
    /// 2026-10-25: the joining Mac showed its own model list while the leading Mac showed the same list.
    static func memberJoinsWithLocal() {
        var named = localRequest
        named.model = "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp"
        for request in [localRequest, named] {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, pairEvents: memberEvents,
                pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")), request: request)
            let label = request.model == nil ? "member local" : "member local with a model"
            expect(run.waitFor(codeQuestion), "\(label): the code question")
            run.type("y")
            expect(run.finish() == 0, "\(label): exit 0 once paired")
            let text = run.text
            expect(text.hasSuffix(ClusterOnboardingDriver.joinedLocalContinueLine + " " + ClusterOnboardingDriver.closeWindowLine + "\n"),
                   "\(label): one line for the other Mac, `local` in it, last: \(text)")
            expect(!text.contains(ClusterOnboardingDriver.joinedLine) && !text.contains(ClusterOnboardingDriver.joinedLocalLine),
                   "\(label): no second instruction for the other Mac")
            expect(!text.contains("3/4") && !text.contains("Choose a model") && !text.contains("Change model"),
                "\(label): no model list and no menu on the Mac that joined")
            expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService"], "\(label): nothing after its service: \(recorder.all)")
            expect(run.keys == 1, "\(label): one key (y), got \(run.keys)")
            transcript(request.model == nil ? "member-joins-with-local" : "member-joins-with-local-model", text, keys: run.keys)
        }
        expect(ClusterOnboardingDriver.joinedLocalLine.contains("on the other Mac"), "member local: the line says where to run it")
    }

    /// Two Macs of one kind (2026-10-25: both "Apple M5 Ultra, 256 GB", and the API line named the Mac the screen was not
    /// on by the name both share): every line that names a Mac says which one, "this Mac" or "the other Mac", and the
    /// hardware name only ever comes with it. Never a host or computer name.
    static func identicalMacsAreToldApart() {
        typealias N = ClusterOnboardingMacName
        expect(N.other(named: "Apple M5 Ultra, 256 GB") == "the other Mac (Apple M5 Ultra, 256 GB)", "names: the other Mac with its hardware")
        expect(N.other(named: nil) == "the other Mac" && N.other(named: "  ") == "the other Mac", "names: no name, the other Mac")
        expect(N.other(named: "Mac\u{1B}[2J") == "the other Mac", "names: a name with control characters is not shown")
        expect(N.other(named: "the other Mac") == "the other Mac", "names: a fallback name is not wrapped twice")
        expect(N.other(named: String(repeating: "x", count: 97)) == "the other Mac", "names: an overlong name is not shown")
        expect(N.sentence("the other Mac (Apple M5 Ultra, 256 GB)") == "The other Mac (Apple M5 Ultra, 256 GB)" && N.sentence(N.this) == "This Mac",
            "names: at the start of a sentence")
        let hardware = ["mac-a": "Apple M5 Ultra, 256 GB", "mac-b": "Apple M5 Ultra, 256 GB"]
        expect(N.names(hardware, viewerID: "mac-a") == ["mac-a": "this Mac", "mac-b": "the other Mac (Apple M5 Ultra, 256 GB)"],
            "names: a pair from one Mac")
        expect(N.names(hardware, viewerID: "mac-b") == ["mac-a": "the other Mac (Apple M5 Ultra, 256 GB)", "mac-b": "this Mac"],
            "names: the same pair from the other Mac (a forwarded answer is worded for the Mac that asked)")
        let three = ["mac-a": "Apple M5 Ultra, 256 GB", "mac-b": "Apple M5 Ultra, 256 GB", "mac-c": "Apple M4 Max, 128 GB"]
        expect(N.names(three, viewerID: "mac-a") == three, "names: among three Macs none is 'the other'")

        typealias D = ClusterOnboardingDeployment
        let tp = [D.Share(name: "Apple M5 Ultra, 256 GB", layers: 78, weightsBytes: 91, label: N.other),
                  D.Share(name: "Apple M5 Ultra, 256 GB", layers: 78, weightsBytes: 91, label: N.this)]
        expect(D.line(model: "Z.ai: GLM-5.3-Flash", mode: "tensor_parallel_v1", shares: tp)
            == "Serving Z.ai: GLM-5.3-Flash across both Macs: tensor parallel, the other Mac 50% / this Mac 50%", "shares: in the screen's words")
        expect(D.choiceLine(size: "181.8 GB", mode: "tensor_parallel_v1", shares: tp, speed: nil) == "181.8 GB · tensor parallel · the other Mac 50% / this Mac 50%",
            "shares: the model's line in the screen's words")
        let pipeline = [D.Share(name: "Apple M3 Ultra, 256 GB", layers: 40, label: N.this), D.Share(name: "Apple M5 Ultra, 256 GB", layers: 24, label: N.other)]
        expect(D.sharesWords(mode: "pipeline_v1", shares: pipeline) == "this Mac 40 layers / the other Mac 24 layers", "shares: pipeline in the screen's words")
        let partial = [D.Share(name: "Apple M3 Ultra, 256 GB", layers: 40, label: N.this), D.Share(name: "Apple M5 Ultra, 256 GB", layers: 24)]
        expect(D.sharesWords(mode: "pipeline_v1", shares: partial) == "M3 Ultra 40 layers / M5 Ultra 24 layers", "shares: some words missing, the chips")
        expect(D.sharesWords(mode: "tensor_parallel_v1", shares: tp.map { D.Share(name: $0.name, layers: nil, weightsBytes: $0.weightsBytes) })
            == "Apple M5 Ultra, 256 GB 50% / Apple M5 Ultra, 256 GB 50%", "shares: a line recorded for both Macs names them by hardware")

        let recorder = Recorder()
        let run = TerminalRun(identicalOperations(recorder))
        expect(run.waitFor(codeQuestion), "identical: the code question")
        run.type("y")
        expect(run.waitFor(prompt(1)), "identical: the model choice")
        run.type("\r")
        expect(run.finish() == 0, "identical: exit 0")
        let text = run.text
        for line in [
            "  \u{2713} Paired. This Mac leads.",
            "  1) Z.ai: GLM-5.3-Flash · 181.8 GB",
            "\u{2713} Serving Z.ai: GLM-5.3-Flash on this Mac's local API only",
        ] {
            expect(text.contains(line + "\n"), "identical: \(line)")
        }
        // The hardware name both Macs share never stands alone.
        for line in visible(text) where line.contains("Apple M5 Ultra, 256 GB") {
            let lower = line.lowercased()
            expect(lower.contains("this mac") || lower.contains("the other mac"), "identical: the line says which Mac: \(line)")
        }
        transcript("leader-identical-macs", text, keys: run.keys)
    }

    /// Two identical Macs as the live operations name them on the leading Mac (ONB-B47's screen, serving locally only),
    /// with rank 0 and so the API on this Mac, which leads.
    static func identicalOperations(_ recorder: Recorder) -> ClusterOnboardingOperations {
        let mac = "Apple M5 Ultra, 256 GB"
        let identical = [ClusterOnboardingMachine(name: mac, memoryGB: 256, gpuCores: 80, leads: true, models: 2),
                         ClusterOnboardingMachine(name: mac, memoryGB: 256, gpuCores: 80, leads: false, models: 2)]
        let glm = ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel · this Mac 50% / the other Mac 50%",
            "Tensor parallel: the model fits, so both Macs share every layer of every token."], blocker: nil,
            modelID: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp", validated: true)
        return operations(recorder, pairEvents: [.searching, .waitingAsLeader, .connected,
            .code("123456", peer: [mac, "Mac17,15, macOS 27.0.1; SIP on, Secure Boot full, sealed system volume"]), .peerDecided(true)],
            pairResult: .paired(role: .leader, peerName: mac), choices: [glm], machines: identical,
            readyResult: .success(.init(servedBy: ClusterOnboardingMacName.this, port: 8000,
                deployment: "Serving Z.ai: GLM-5.3-Flash across both Macs: tensor parallel, this Mac 50% / the other Mac 50%",
                notice: "Serving locally only on this Mac's API: no coordinator, no public traffic", network: false)))
    }

    /// The new lines under every plain presentation: NO_COLOR, TERM=dumb and redirected input and output print the same
    /// plain transcript, byte for byte; a colour window too narrow for the mark and meter (30 columns) says every line
    /// of it but the choices' (a list moved with the arrows there), in order. No terminal escape in a plain transcript,
    /// and no credential, host name, address or SSH in any of them.
    static func plainPresentationsKeepTheNewLines() {
        struct Flow { let name: String; let operations: (Recorder) -> ClusterOnboardingOperations; let request: ClusterOnboardingRequest; let keys: [(String, String)] }
        let flows = [
            Flow(name: "identical Macs", operations: identicalOperations, request: .init(),
                 keys: [(codeQuestion, "y"), ("3/4 Model", "\r")]),
            Flow(name: "member with local", operations: { recorder in operations(recorder, pairEvents: memberEvents,
                    pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")) },
                 request: localRequest, keys: [(codeQuestion, "y")]),
        ]
        for flow in flows {
            var plain = [String: String]()
            for (presentation, environment) in [("NO_COLOR", ["NO_COLOR": "1", "TERM": "xterm-256color"]), ("TERM=dumb", ["TERM": "dumb"])] {
                let run = TerminalRun(flow.operations(Recorder()), request: flow.request, environment: environment)
                for (needle, key) in flow.keys { expect(run.waitFor(needle), "\(flow.name), \(presentation): \(needle)"); usleep(50_000); run.type(key) }
                expect(run.finish() == 0, "\(flow.name), \(presentation): exit 0")
                plain[presentation] = run.text
            }
            let piped = PipeRun(flow.operations(Recorder()), request: flow.request, environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"])
            for (needle, key) in flow.keys { expect(piped.waitFor(needle), "\(flow.name), pipes: \(needle)"); usleep(50_000); piped.type(key) }
            expect(piped.finish() == 0, "\(flow.name), pipes: exit 0")
            plain["pipes"] = piped.text
            let narrow = TerminalRun(flow.operations(Recorder()), request: flow.request,
                                     environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"], columns: 30)
            for (needle, key) in flow.keys { expect(narrow.waitFor(needle), "\(flow.name), 30 columns: \(needle)"); usleep(50_000); narrow.type(key) }
            expect(narrow.finish() == 0, "\(flow.name), 30 columns: exit 0")
            let reference = plain["NO_COLOR"] ?? ""
            expect(!reference.isEmpty && plain.values.allSatisfy { $0 == reference }, "\(flow.name): one plain transcript, byte for byte: \(plain.keys.sorted())")
            // The narrow window's lines are the plain transcript's, in order, but for the choices.
            let said = visible(reference).filter { !$0.isEmpty && !$0.contains("Choose 1-") && $0.range(of: #"^  \d\) "#, options: .regularExpression) == nil }
            var lines = visible(narrow.text)[...]
            let missing = said.first { line in
                guard let at = lines.firstIndex(of: line) else { return true }
                lines = lines[(at + 1)...]
                return false
            }
            expect(missing == nil, "\(flow.name), 30 columns: every said line of the plain transcript, in order; missing \(missing ?? "")")
            for (presentation, text) in plain.merging(["30 columns": visible(narrow.text).joined(separator: "\n")], uniquingKeysWith: { first, _ in first }) {
                if presentation != "30 columns" { expect(!text.contains("\u{1B}"), "\(flow.name), \(presentation): no terminal escape") }
                let lower = text.lowercased()
                // "password" is said where macOS asks for it; never a password itself ("password=", "password:").
                expect(!lower.contains("ssh") && !lower.contains(".local") && !lower.contains("bearer")
                    && !lower.contains("password=") && !lower.contains("password:")
                    && text.range(of: #"[0-9A-Fa-f]{32,}"#, options: .regularExpression) == nil
                    && text.range(of: #"\b\d{1,3}(\.\d{1,3}){3}\b"#, options: .regularExpression) == nil,
                    "\(flow.name), \(presentation): no credential, host name, address or SSH")
            }
        }
    }

    /// Two models with the same display name (the catalog's Gemma and the QAT build on the Macs): each line names its id.
    static func sameTitleShowsTheID() {
        let recorder = Recorder()
        let twins = [
            ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["15.6 GB · pipeline · M4 Max 3 layers / M5 Max 27 layers",
                "Pipeline: this model has no tensor-parallel plan."], blocker: nil, modelID: "gemma-4-26b-qat-4bit",
                publicTraffic: "qualified for public traffic in pipeline mode"),
            ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["28.0 GB · not on these Macs: downloaded from Darkbloom's catalog first"],
                blocker: nil, modelID: "gemma-4-26b")]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
            choices: twins), request: localRequest)
        expect(run.waitFor(prompt(2)), "twins: the list")
        expect(run.text.contains("  1) Gemma 4 26B (gemma-4-26b-qat-4bit) · 15.6 GB\n  2) Gemma 4 26B (gemma-4-26b) · 28.0 GB\n"),
               "twins: each names its id: \(run.text)")
        run.type("\r")
        expect(run.finish() == 0, "twins: served")
        expect(!run.text.contains("qualified for public traffic") && !run.text.contains("Pipeline: this model has no tensor-parallel plan."),
               "twins: the list's line is what is said about a model")
    }

    /// The model's one line is its name and size (2026-11-03: less is better), with "copy" or "download" when it has
    /// to reach a Mac first; how it is split and why not tensor parallel are the planner's, not said. An older Mac's
    /// choice still decodes.
    static func tensorParallelNotesOnTheModelLine() {
        typealias C = ClusterOnboardingModelChoice
        for note in ["tensor parallel: slower here", "tensor parallel: does not fit now", "tensor parallel: \u{1B}[2J", ""] {
            expect(C(title: "m", lines: ["6.1 GB · pipeline · M3 Ultra 16 layers / M5 Max 16 layers"], blocker: nil,
                     tensorParallelNote: note).listLine(sameTitleElsewhere: false) == "m · 6.1 GB", "model line: name and size, no note: \(note)")
        }
        expect(C(title: "m", lines: [], blocker: nil).listLine(sameTitleElsewhere: false) == "m", "model line: no size known, the name")
        expect(C(title: "m", lines: ["6.1 GB"], blocker: nil, modelID: "org/m").listLine(sameTitleElsewhere: true) == "m (org/m) · 6.1 GB",
               "model line: a shared title says its id")
        let copy = ClusterOnboardingProvisionOffer(lines: [], downloadAlternative: true, leaderDownloads: false)
        let download = ClusterOnboardingProvisionOffer(lines: [], downloadAlternative: false, leaderDownloads: true)
        let fromPeer = ClusterOnboardingProvisionOffer(lines: [], downloadAlternative: false, leaderDownloads: true, fromOtherMac: true)
        expect(C(title: "m", lines: ["6.1 GB"], blocker: nil, provision: copy).listLine(sameTitleElsewhere: false) == "m · 6.1 GB · copy"
            && C(title: "m", lines: ["6.1 GB · not on these Macs: downloaded from Darkbloom's catalog first"], blocker: nil, provision: download)
                .listLine(sameTitleElsewhere: false) == "m · 6.1 GB · download"
            && C(title: "m", lines: ["6.1 GB"], blocker: nil, provision: fromPeer).listLine(sameTitleElsewhere: false) == "m · 6.1 GB · copy",
            "model line: what has to move first")
        expect(C(title: "m", lines: ["6.1 GB · tensor parallel · this Mac 50% / the other Mac 50%"], blocker: nil, split: "tensor parallel")
                .listLine(sameTitleElsewhere: false) == "m · 6.1 GB · tensor parallel"
            && C(title: "m", lines: ["6.1 GB"], blocker: nil, provision: copy, split: "pipeline").listLine(sameTitleElsewhere: false)
                == "m · 6.1 GB · pipeline · copy", "model line: the split's marker after the size, before what has to move")
        for unsafe in ["pipeline\u{1B}[2J", "", String(repeating: "x", count: 49)] {
            expect(C(title: "m", lines: ["6.1 GB"], blocker: nil, split: unsafe).listLine(sameTitleElsewhere: false) == "m · 6.1 GB",
                   "model line: a marker that is not a few plain words is left out")
        }
        let older = try? JSONDecoder().decode(C.self, from: Data(#"{"title":"m","lines":["a"]}"#.utf8))
        expect(older != nil && older?.tensorParallelNote == nil && older?.validated == nil && older?.split == nil,
               "model line: an older Mac's choice decodes")
        let listed = [
            C(title: "Qwen3.5-9B", lines: ["6.1 GB · pipeline · M3 Ultra 16 layers / M5 Max 16 layers · about 92 tokens/s",
                "Pipeline: tensor parallel is predicted slower for requests of 1024 prompt and 256 answer tokens."], blocker: nil,
                tensorParallelNote: "tensor parallel: slower here"),
            C(title: "Bonsai 27B", lines: ["7.2 GB · pipeline · M3 Ultra 4 layers / M5 Max 60 layers"], blocker: nil,
                fitRemedy: "Quit apps on the other Mac (Apple M5 Max, 128 GB) first.", tensorParallelNote: "tensor parallel: does not fit now")]
        let run = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [],
            pairResult: .failed([]), choices: listed), columns: 40)
        expect(run.waitFor(prompt(2)), "model line: the list")
        expect(run.text.contains("  1) Qwen3.5-9B · 6.1 GB\n  2) Bonsai 27B · 7.2 GB · does not fit now\n"),
               "model line: name and size, a model that does not fit now said once: \(run.text)")
        expect(!run.text.contains("tensor parallel") && !run.text.contains("layers"), "model line: no split, no planner reasons")
        run.type("\r")
        expect(run.finish() == 0, "model line: served")
    }

    /// The scope's values: from the record, the bind addresses it takes, what reaches the network, and its line.
    static func servingScopeValues() {
        typealias S = ClusterServingScope
        expect(S(localOnly: nil, bind: nil) == .publicServing, "scope: an older record is public")
        expect(S(localOnly: false, bind: "::") == .publicServing, "scope: public ignores a bind")
        expect(S(localOnly: true, bind: nil) == .localOnly(bind: "0.0.0.0"), "scope: local only listens everywhere by default")
        expect(S(localOnly: true, bind: "::1") == .localOnly(bind: "::1"), "scope: a chosen bind is kept")
        expect(S(localOnly: true, bind: "0.0.0.0 --no-auth") == .localOnly(bind: "127.0.0.1"), "scope: a saved address the API does not take falls back to loopback")
        expect(S.carried(localOnly: nil, bind: "::") == nil, "carried: none")
        expect(S.carried(localOnly: false, bind: nil) == .publicServing, "carried: public")
        expect(S.carried(localOnly: true, bind: nil) == .localOnly(bind: "0.0.0.0"), "carried: local only, every interface")
        expect(S.carried(localOnly: true, bind: "my-mac.local") == nil, "carried: an address the API does not take is refused")
        for good in ["0.0.0.0", "127.0.0.1", "::", "::1", "localhost", "2001:db8::10"] { expect(S.isValidBind(good), "bind accepted: \(good)") }
        for bad in ["", "my-mac.local", "0.0.0.0 ", "0.0.0.0;x", "256.1.1.1", "tailnet", String(repeating: "1", count: 80)] {
            expect(!S.isValidBind(bad), "bind refused: \(bad)")
        }
        expect(S.localOnly(bind: "0.0.0.0").reachableFromNetwork, "0.0.0.0 reaches the network")
        expect(S.localOnly(bind: "2001:db8::10").reachableFromNetwork, "an address reaches its network")
        for loopback in ["127.0.0.1", "::1", "localhost"] { expect(!S.localOnly(bind: loopback).reachableFromNetwork, "loopback stays on this Mac: \(loopback)") }
        expect(!S.publicServing.reachableFromNetwork && S.publicServing.bind == nil, "public: no local-only bind")
        expect(S.localOnly(bind: "127.0.0.1").line == "Local only, on this Mac only (127.0.0.1); API key: `darkbloom local`", "line: loopback")
        expect(S.localOnly(bind: "2001:db8::10").line == "Local only, at 2001:db8::10; API key: `darkbloom local`", "line: an address")

        typealias Sync = ClusterOnboardingSync
        expect(Sync.action(leaderServing: true, leaderModel: "m", memberServing: true, memberModel: "m", leaderLocalOnly: true, memberLocalOnly: false)
               == .serve("m"), "sync: a member that missed the scope is sent the start again")
        expect(Sync.action(leaderServing: true, leaderModel: "m", memberServing: true, memberModel: "m", leaderLocalOnly: true, memberLocalOnly: true)
               == .none, "sync: the same scope is left alone")
        expect(Sync.action(leaderServing: true, leaderModel: "m", memberServing: true, memberModel: "m", leaderLocalOnly: true, memberLocalOnly: nil)
               == .none, "sync: an older member (no scope reported) is compared by model only")

        let here = ClusterOnboardingReady(servedBy: "this Mac", port: 8000, network: true)
        expect(here.summary(model: "m") == "Serving m at http://localhost:8000 and on the network", "ready: network, this Mac")
        let there = ClusterOnboardingReady(servedBy: "the other Mac (Apple M4 Max, 128 GB)", port: 8000, network: true)
        expect(there.summary(model: "m") == "Serving m at http://localhost:8000 on the other Mac and on the network", "ready: network, that Mac")
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000).summary(model: "m") == "Serving m at http://localhost:8000", "ready: loopback unchanged")
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000, split: "tensor parallel").summary(model: "m")
               == "Serving m (tensor parallel) at http://localhost:8000", "ready: the split's marker after the model")
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 0, offered: "offered for pairing", split: "pipeline").summary(model: "m")
               == "Serving m (pipeline): offered for pairing", "ready: offered, the marker too")
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000, split: "x\u{7}").summary(model: "m") == "Serving m at http://localhost:8000",
               "ready: a marker with control characters is left out")
        let older = try? JSONDecoder().decode(ClusterOnboardingReady.self, from: Data(#"{"servedBy":"this Mac","port":8000}"#.utf8))
        expect(older?.network == nil && older?.split == nil, "ready: an older Mac's answer decodes without the network and split fields")
    }

    /// The four steps, in order.
    static let stages = ["1/4 Connect", "2/4 Pair", "3/4 Model", "4/4 Start"]

    /// The words a person reads on a screen (escapes and redraws removed), as `wc -w` counts them.
    static func words(_ text: String) -> Int {
        visible(text).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The from-scratch screens' word budgets (2026-11-03: about 70% fewer words than the 2026-11-02 screens, 293 and
    /// 148): a line that grows them back fails here.
    /// 2026-11-03 call (Dylan): the Start step's notice and an unmistakable outcome block on the leader, and where the
    /// other Mac's window shows the outcome; both budgets grew by that much.
    static let leaderWordBudget = 125
    static let memberWordBudget = 70

    static let codeQuestion = ClusterOnboardingPairing.codeQuestion

    /// Local Network access while macOS's prompt is up: refused for each of `subjects` until it was probed `refusals`
    /// times, then allowed (the person clicked Allow); any other subject is allowed at once.
    static func refusedThenAllowed(_ refusals: Int, _ subjects: [ClusterOnboardingLocalNetworkSubject] = [.thisCommand])
        -> @Sendable (ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork {
        let probes = Recorder()
        return { subject in
            guard subjects.contains(subject) else { return .allowed }
            probes.note("\(subject)")
            return probes.all.filter { $0 == "\(subject)" }.count > refusals ? .allowed : .blocked
        }
    }

    /// An arrow pressed while the setup waits (here for Allow) is no key: only q or a lone escape stops a wait.
    static func arrowKeysDoNotStopAWait() {
        let run = TerminalRun(operations(Recorder(), pairEvents: [], pairResult: .failed([]), localNetwork: refusedThenAllowed(3)))
        expect(run.waitFor("Click Allow"), "arrow in a wait: the prompt line")
        run.type("\u{1B}[A")
        run.type("\u{1B}[B")
        expect(run.waitFor("  \u{2713} Allowed\n"), "arrow in a wait: still waiting, then allowed")
        _ = run.finish()
        expect(!run.text.contains("still off"), "arrow in a wait: not stopped: \(run.text)")
    }

    /// q cancels a list even where an option starts with q (2026-11-02: q took "Qwen3.8 27B").
    static func qCancelsAListBeforeALetter() {
        let qwen = [ClusterOnboardingModelChoice(title: "Qwen3.8 27B", lines: ["16.3 GB · tensor parallel"], blocker: nil, validated: true),
                    ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel"], blocker: nil, validated: true)]
        for (label, environment) in [("plain", ["NO_COLOR": "1"]), ("colour", ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"])] {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
                pairResult: .failed([]), choices: qwen), environment: environment)
            expect(run.waitFor("Qwen3.8 27B"), "q, \(label): the list")
            run.type("q")
            expect(run.finish() == 0, "q, \(label): exit 0")
            expect(run.text.hasSuffix("Nothing changed.\n"), "q, \(label): cancelled")
            expect(!recorder.all.contains { $0.hasPrefix("adopt") || $0.hasPrefix("recheckFit") }, "q, \(label): nothing chosen: \(recorder.all)")
        }
    }

    /// Over SSH the prompts are on the Mac's own screen: the lines say so, and name the program macOS shows.
    static func sshSessionsAreToldWhereThePromptIs() {
        let run = TerminalRun(operations(Recorder(), pairEvents: [], pairResult: .failed([]), localNetwork: refusedThenAllowed(2), remote: true,
            commandApp: "sshd-keygen-wrapper"))
        expect(run.waitFor("  " + ClusterOnboardingDriver.approvalsLine(remote: true) + "\n"), "SSH: the approvals, where each is answered")
        expect(run.waitFor("  Click Allow on the Local Network prompt for sshd-keygen-wrapper on this Mac's screen (Screen Sharing if headless).\n"),
               "SSH: the prompt is on the Mac's screen, and the program macOS names")
        expect(run.waitFor("for sshd-keygen-wrapper on this Mac's screen (Screen Sharing if headless).\n  \u{2713} Allowed\n"), "SSH: allowed")
        _ = run.finish()
    }

    /// A service that does not report its probe (an older build) still gets the prompt's line, as an "if".
    static func serviceThatCannotTellStillGetsTheAsk() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"),
            localNetwork: { $0 == .service ? .unknown : .allowed }))
        expect(run.waitFor(codeQuestion), "unknown: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 0, "unknown: the member's setup ends")
        expect(run.text.contains("  " + ClusterOnboardingDriver.localNetworkMaybeLine("Darkbloom") + " " + ClusterOnboardingDriver.otherMacAllowLine + "\n"),
               "unknown: the prompt's line as an if: \(run.text)")
        expect(run.text.contains(ClusterOnboardingDriver.joinedLine), "unknown: nothing to wait for")
    }

    /// The leader reads both Macs once paired; the other Mac's service may still wait for its Allow: a list to try
    /// again instead of an end.
    static func otherMacThatDidNotAnswerOffersTryAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), reachFailures: 1))
        expect(run.waitFor("The other Mac did not answer over the cable.\n"), "try again: what happened")
        expect(run.waitFor("1) Try again\n  2) Cancel\n"), "try again: the list")
        run.type("\r")
        expect(run.waitFor(prompt(2), count: 2), "try again: then the model list")
        run.type("\r")
        expect(run.finish() == 0, "try again: served")
        expect(recorder.all.filter { $0 == "reachMembers" }.count == 2, "try again: read twice: \(recorder.all)")
    }

    /// The serving line says how the pair serves: earning through Darkbloom, or local only. Only a private image
    /// candidate says at the choice that it takes no public traffic (2026-11-03: less is better).
    static func startSaysHowThePairServes() {
        let qualified = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"],
            blocker: nil, publicTraffic: "qualified for public traffic in pipeline mode", validated: true)]
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), choices: qualified))
        expect(run.waitFor(prompt(1)), "serves: the list"); run.type("\r")
        expect(run.finish() == 0, "serves: exit 0")
        let text = run.text
        expect(!text.contains("public traffic in pipeline mode"), "serves: no public-traffic line at the choice: \(text)")
        expect(text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)\n"),
               "serves: through Darkbloom, in the outcome: \(text)")
        let local = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), choices: qualified, readyResult: .success(localReady)), request: localRequest)
        expect(local.waitFor(prompt(1)), "serves locally: the list"); local.type("\r")
        expect(local.finish() == 0, "serves locally: exit 0")
        expect(!local.text.contains("public traffic in pipeline mode") && !local.text.contains("earning"),
               "serves locally: no public-traffic line, no earning: \(local.text)")
        expect(local.text.contains("local API only\n"), "serves locally: said in the outcome: \(local.text)")
    }

    /// The list's keys on a colour UTF-8 terminal.
    static let arrowHint = "\u{2191}\u{2193} move \u{00B7} enter select \u{00B7} q cancel"

    /// A plain transcript's choice prompt (enter takes the first option).
    static func prompt(_ count: Int) -> String { "Choose 1-\(count): " }

    /// The leader's pairing: nobody waits on the cable, the other Mac joins, both confirm the code.
    static let leaderEvents: [ClusterOnboardingPairEvent] = [.searching, .waitingAsLeader, .connected,
        .code("123456", peer: ["Apple M3 Ultra, 256 GB"]), .peerDecided(true)]

    static let memberEvents: [ClusterOnboardingPairEvent] = [.searching, .joining, .connected,
        .code("123456", peer: ["Apple M5 Ultra, 256 GB"]), .peerDecided(true)]

    /// A development build's service lives only as long as its window: both screens say to keep it open.
    static func developmentBuildKeepsTheWindowsOpen() {
        let member = Recorder()
        let joined = TerminalRun(operations(member, pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), outlivesWindow: false))
        expect(joined.waitFor(codeQuestion), "dev member: the code question"); joined.type("y")
        expect(joined.finish() == 0, "dev member: exit 0")
        expect(joined.text.contains(ClusterOnboardingDriver.joinedLine + " " + ClusterOnboardingDriver.keepWindowLine + "\n"), "dev member: keep the window open")
        let leader = Recorder()
        let led = TerminalRun(operations(leader, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), outlivesWindow: false))
        expect(led.waitFor(prompt(2)), "dev leader: the list"); led.type("\r")
        expect(led.finish() == 0, "dev leader: exit 0")
        expect(led.text.contains("Done. Keep both windows open.\n"), "dev leader: keep both windows open")
    }

    /// The code's list ends by itself when the pairing does meanwhile (the other Mac declined): no answer is waited for.
    static func codeListEndsWhenThePairingDoes() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .failed(["The other Mac declined the code."])))
        expect(run.waitFor(codeQuestion), "ended: the code shown")
        expect(run.finish(seconds: 15) == 1, "ended: exit 1 with no key")
        expect(run.text.contains("The other Mac declined the code.") && run.text.contains("Run `darkbloom cluster` again.\n"),
               "ended: the pairing's own reason")
        expect(run.keys == 0, "ended: no key typed")
    }

    /// 2026-11-02: macOS could not show its password window (an SSH session), and the setup said to run a script by
    /// hand. Now the same commands run with sudo right there, and the setup goes on; only a failed sudo names the script.
    static func cablePortSetUpWithSudoWhereNoPromptShows() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), linkScript: "~/.darkbloom/cluster-device/link-fix.sh"))
        expect(run.waitFor("  Type this Mac's password to set up the cable port.\n"), "sudo: said before sudo asks")
        expect(run.waitFor(codeQuestion), "sudo: then the cable is ready and pairing goes on"); run.type("y")
        expect(run.finish() == 0, "sudo: member done")
        expect(recorder.all.prefix(3) == ["checkLink", "runAsAdministrator", "checkLink"], "sudo: the script, then the cable again: \(recorder.all)")
        expect(!run.text.contains("sudo sh"), "sudo: no script to run by hand")
        transcript("cable-port-with-sudo", run.text, keys: run.keys)

        let failed = Recorder()
        let refused = TerminalRun(operations(failed, pairEvents: [], pairResult: .failed([]),
            linkScript: "~/.darkbloom/cluster-device/link-fix.sh", sudoSucceeds: false))
        expect(refused.finish() == 1, "sudo failed: stops")
        expect(refused.text.hasSuffix("Cable port not set up. Run `darkbloom cluster` again.\n") && !refused.text.contains("link-fix.sh"),
               "sudo failed: what to do, no script to run by hand")
        expect(!failed.all.contains("pair"), "sudo failed: no pairing")
    }

    /// 2026-11-02: macOS's Local Network prompts came out of sync, on the other Mac's turn. This command's is asked in
    /// Connect and Darkbloom's right after pairing, each with what to click, and the setup waits for the answer.
    static func localNetworkAskedAtStatedMoments() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), localNetwork: refusedThenAllowed(2, [.thisCommand, .service])))
        expect(run.waitFor("  Click Allow on the Local Network prompt for Terminal.\n"), "local network: this command's prompt, in Connect")
        expect(run.waitFor("prompt for Terminal.\n  \u{2713} Allowed\n"), "local network: allowed, then pairing")
        expect(run.waitFor(codeQuestion), "local network: the code"); run.type("y")
        expect(run.waitFor("  Click Allow on the Local Network prompt for Darkbloom. " + ClusterOnboardingDriver.otherMacAllowLine + "\n"),
               "local network: Darkbloom's, once paired, the other Mac's said too")
        expect(run.finish(seconds: 20) == 0, "local network: member done")
        let text = run.text
        let order = ["1/4 Connect", "prompt for Terminal.\n  \u{2713} Allowed", "2/4 Pair", "Paired.",
                     "the other Mac too.\n  \u{2713} Allowed", "Done here"].compactMap { text.range(of: $0)?.lowerBound }
        expect(order.count == 6 && order == order.sorted(), "local network: asked in order, each before the next step: \(text)")
        transcript("member-local-network-prompts", text, keys: run.keys)

        // Refused and left so: q stops with where to turn it on.
        let blocked = TerminalRun(operations(Recorder(), pairEvents: [], pairResult: .failed([]), localNetwork: { _ in .blocked }))
        expect(blocked.waitFor("Click Allow"), "refused: the prompt line")
        blocked.type("q")
        expect(blocked.finish() == 1, "refused: stops")
        expect(blocked.text.hasSuffix("Turn it on in System Settings → Privacy & Security → Local Network, then run `darkbloom cluster` again.\n"),
               "refused: where to turn it on, last")
    }

    /// `darkbloom cluster local` on a member: it takes effect on the Mac that leads, so the screen says so and nothing runs.
    static func memberLocalPointsToTheLeader() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([])), request: localRequest)
        expect(run.finish() == 1, "member local: exit 1")
        expect(run.text.hasSuffix(ClusterOnboardingDriver.joinedLocalLine + "\n"), "member local: where to run it")
        expect(recorder.all == ["ensureService", "status"], "member local: nothing changed: \(recorder.all)")
    }

    /// The leader's list moved with the arrows: ↓ twice then enter takes the third item, the list folds to it.
    static func arrowKeysTakeAMenuItem() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)),
            environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"])
        expect(run.waitFor(arrowHint), "arrows: the list")
        run.type("\u{1B}[B")
        expect(run.waitFor("\u{25B8}\u{1B}[0m \u{1B}[1mChange model", seconds: 5), "arrows: ↓ moves the ▸ to the second item")
        run.type("\u{1B}[B")
        expect(run.waitFor("\u{25B8}\u{1B}[0m \u{1B}[1mServe locally", seconds: 5), "arrows: and to the third")
        run.type("\r")
        expect(run.finish() == 0, "arrows: exit 0")
        expect(visible(run.text).contains("  \u{25B8} Serve locally"), "arrows: the list folds to the item taken")
        expect(recorder.all == ["ensureService", "status", "setScope local 0.0.0.0", "waitReady"], "arrows: the third item ran: \(recorder.all)")
        transcript("leader-again-arrows", run.text, keys: run.keys)
    }

    /// 2026-11-02: "only allow ones that are allowed to cluster serve and validated". A model the owner has not
    /// approved for clusters is not listed, and is refused by name; a list with none approved says so.
    static func onlyApprovedModelsAreListed() {
        typealias C = ClusterOnboardingModelChoice
        let mixed = [
            C(title: "Qwen 3.5 9B", lines: ["6.1 GB · pipeline"], blocker: nil, modelID: "Qwen3.5-9B", validated: false),
            C(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel"], blocker: nil, modelID: "glm-5.3-flash", validated: true),
            C(title: "Qwen3.8 27B", lines: ["16.3 GB · tensor parallel"], blocker: nil, modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", validated: true),
            C(title: "Gemma 4 26B", lines: [], blocker: "too large for this pair", modelID: "gemma-4-26b", validated: false)]
        expect(mixed.map(\.listed) == [false, true, true, false], "approved: listed only when approved and servable")
        expect(C(title: "m", lines: [], blocker: nil).listed, "approved: an older leader's choice (no word) is listed")
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: mixed))
        expect(run.waitFor(prompt(2)), "approved: the list of two")
        let text = run.text
        expect(text.contains("  1) Z.ai: GLM-5.3-Flash · 181.8 GB\n  2) Qwen3.8 27B · 16.3 GB\n"),
               "approved: only the approved models: \(text)")
        expect(!text.contains("Qwen 3.5 9B") && !text.contains("Gemma"), "approved: nothing else, not even as not offered")
        run.type("2")
        expect(run.finish() == 0, "approved: served")
        expect(recorder.all.contains("adopt 2"), "approved: the list's second line is choice 2: \(recorder.all)")

        var named = localRequest
        named.model = "Qwen3.5-9B"
        let refused = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "glm-5.3-flash"),
            pairEvents: [], pairResult: .failed([]), choices: mixed), request: named)
        expect(refused.finish() == 1, "approved: a named unapproved model is refused")
        expect(refused.text.contains("Qwen 3.5 9B is not approved for clusters yet.\n"), "approved: why")

        let none = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: [mixed[0], mixed[3]]))
        expect(none.finish() == 1, "approved: none approved stops")
        expect(none.text.contains("No approved model can run on these Macs now.\n"), "approved: said")
        expect(!none.text.contains("Qwen 3.5 9B"), "approved: an unapproved model is not named among the reasons")
    }

    /// Two identical Macs read the same hardware ("Apple M5 Ultra, 256 GB"), so each says which physical Mac it is,
    /// by the name System Settings gives it, beside the part it plays: on its own screen only, and only a name that
    /// can be said plainly.
    static func eachMacNamesItselfBesideItsPart() {
        let D = ClusterOnboardingDriver.self
        expect(D.shownName("  Studio A ") == "Studio A", "names: trimmed")
        expect(D.shownName(nil) == nil && D.shownName(" ") == nil, "names: none given")
        expect(D.shownName("Studio\u{1B}[2J") == nil, "names: a control character is never said")
        expect(D.shownName(String(repeating: "x", count: 41)) == nil, "names: at most 40 characters")
        expect(D.leaderSubtitle(named: "Studio A") == "This Mac (Studio A) leads", "names: the leader's opening")
        expect(D.leaderSubtitle(named: nil) == D.leaderSubtitle, "names: unknown, unchanged")
        expect(D.followerSubtitle(named: "Studio B") == "This Mac (Studio B) follows the other Mac", "names: the member's opening")
        var leads = ClusterOnboardingPairing()
        expect(leads.finished(.paired(role: .leader, peerName: "Apple M5 Ultra, 256 GB"), named: "Studio A").last
            == "\u{2713} Paired. This Mac (Studio A) leads.", "names: the leader's paired line")
        var follows = ClusterOnboardingPairing()
        expect(follows.finished(.paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), named: "Studio B").last
            == "\u{2713} Paired. The other Mac leads.", "names: the member's paired line")

        let mac = "Apple M5 Ultra, 256 GB"
        let paired = TerminalRun(operations(Recorder(), pairEvents: [.searching, .waitingAsLeader, .connected, .code("123456", peer: [mac]),
            .peerDecided(true)], pairResult: .paired(role: .leader, peerName: mac), machines: [
                ClusterOnboardingMachine(name: mac, memoryGB: 256, gpuCores: 80, leads: true, models: 2),
                ClusterOnboardingMachine(name: mac, memoryGB: 256, gpuCores: 80, leads: false, models: 2)], thisMacName: "Studio A"))
        expect(paired.waitFor(codeQuestion), "names: the code question"); paired.type("y")
        expect(paired.waitFor(prompt(2), count: 2), "names: the model list"); paired.type("\r")
        expect(paired.finish() == 0, "names: served")
        expect(paired.text.contains("  \u{2713} Paired. This Mac (Studio A) leads.\n"),
               "names: identical Macs, this one named where it says it leads")
        for (label, resume, name, opening) in [
            ("leader", ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
             "Studio A", "This Mac (Studio A) leads"),
            ("member", memberResume(), "Studio B", "This Mac (Studio B) follows the other Mac"),
            ("unsayable", ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
             "Studio\u{07}", D.leaderSubtitle)] {
            let run = TerminalRun(operations(Recorder(), resume: resume, pairEvents: [], pairResult: .failed([]), thisMacName: name))
            if resume.role == .leader { expect(run.waitFor(prompt(6)), "names (\(label) again): the menu"); run.type("q") }
            expect(run.finish() == 0, "names (\(label) again): leaves")
            expect(visible(run.text).contains { $0.contains(opening) }, "names (\(label) again): opens with \(opening): \(visible(run.text).prefix(4))")
            expect(!run.text.contains("\u{07}"), "names (\(label) again): nothing unsayable on screen")
        }
    }

    /// A model only the other Mac has is copied to this Mac over the cable, then planned here: its list item says a
    /// copy, never a download, and how long a short one takes; a catalog model still says it is downloaded first
    /// (`leaderDownloadsAModelNoMacHas`).
    static func modelOnTheOtherMacIsCopiedNotDownloaded() {
        let recorder = Recorder()
        let offer = ClusterOnboardingProvisionOffer(lines: ["This Mac: copy from the other Mac (Apple M3 Ultra, 256 GB) over the Thunderbolt cable (16.3 GB, about 7 s)"],
            downloadAlternative: false, leaderDownloads: true, quickSeconds: 6.9, fromOtherMac: true)
        let before = [ClusterOnboardingModelChoice(title: "Qwen3.8 27B", lines: ["16.3 GB · only on the other Mac: copied over the cable first"], blocker: nil,
                                                   provision: offer, validated: true)]
        let after = [ClusterOnboardingModelChoice(title: "Qwen3.8 27B", lines: ["16.3 GB · tensor parallel · this Mac 50% / the other Mac 50%"], blocker: nil,
                                                  validated: true)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: before, replanned: after))
        expect(run.waitFor(prompt(1)), "from the other Mac: offered"); run.type("\r")
        expect(run.text.contains("  1) Qwen3.8 27B · 16.3 GB · copy\n"), "from the other Mac: its line says a copy")
        expect(run.waitFor("  1) Copy from the other Mac (about 7 s)\n  2) Cancel\n"), "from the other Mac: a copy, with its time: \(run.text)")
        expect(!run.text.lowercased().contains("download"), "from the other Mac: no download is mentioned")
        run.type("\r")
        expect(run.finish() == 0, "from the other Mac: served")
        expect(recorder.all.contains("provision 0 copy") && recorder.all.filter { $0 == "planModels" }.count == 2,
               "from the other Mac: copied, then planned here: \(recorder.all)")
    }

    /// A model that does not fit now says so once, at the end of its line (the planner's tensor-parallel note, which
    /// may say the same, is not said at all).
    static func modelThatDoesNotFitSaysSoOnce() {
        typealias C = ClusterOnboardingModelChoice
        let choices = [
            C(title: "Qwen3.8 27B", lines: ["16.3 GB · tensor parallel"], blocker: nil, validated: true),
            C(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · pipeline"], blocker: nil, fitRemedy: "quit the apps holding 20 GB first",
              tensorParallelNote: "tensor parallel: does not fit now", validated: true),
            C(title: "Gemma 4 31B", lines: ["58.2 GB · pipeline"], blocker: nil, fitRemedy: "quit the apps holding 4 GB first",
              tensorParallelNote: "tensor parallel: slower here", validated: true)]
        let run = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor(prompt(3)), "fit: the list")
        let text = run.text
        expect(text.contains("  1) Qwen3.8 27B · 16.3 GB\n  2) Z.ai: GLM-5.3-Flash · 181.8 GB · does not fit now\n"
            + "  3) Gemma 4 31B · 58.2 GB · does not fit now\n"), "fit: said once on each line that does not fit: \(text)")
        expect(!text.contains("does not fit now · does not fit now") && !text.contains("tensor parallel:"), "fit: never twice, no notes")
        run.type("1")
        expect(run.finish() == 0, "fit: the model that fits is served")
    }

    // MARK: - A pair the coordinator forms serves only once loaded (2026-11-03)

    /// Both Macs' members registered with the coordinator: offered for pairing, nothing loaded yet.
    static let offeredReady = ClusterOnboardingReady(servedBy: "this Mac", port: 0,
        deployment: "Serving Qwen3.8-27B-4bit-mtp across both Macs: pipeline, this Mac 32 layers / the other Mac 32 layers",
        offered: ClusterOnboardingReady.registeredNotice + ": approval release/0.10.7/EigenLabs/Qwen3.8-27B-4bit-mtp/s1, until 2027-02-01T22:53:02Z",
        split: "pipeline")

    static let registeredLine = ClusterOnboardingReady.registeredNotice
        + ": approval release/0.10.7/EigenLabs/Qwen3.8-27B-4bit-mtp/s1, until 2027-02-01T22:53:02Z."

    /// The coordinator's refusal of the owner's pair (`liveness:private_text` on rank 0), as the screen words it.
    static let notVerified = ClusterOnboardingNotServing.notVerified("the other Mac (Apple M3 Ultra, 256 GB)")

    static let notServingChoices = "  1) Retry\n  2) Change model\n  3) Serve locally only\n  4) Diagnostics\n"

    /// (a) 2026-11-03, the owner's M3 Ultra + M5 Max and an end user's 2x M4 Max: a pair offered for pairing said
    /// "Serving" and "Done" while the coordinator refused it and nothing was loaded. Now the screen says why, in one
    /// line, and stays open with the choices; leaving it never claims success.
    static func offeredPairThatTheCoordinatorRefusesSaysWhy() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyResult: .success(offeredReady), pairServingResults: [.failure(.init(notVerified))]))
        expect(run.waitFor(prompt(2)), "refused: the list"); run.type("\r")
        expect(run.waitFor(notServingChoices), "refused: the choices: \(run.text)")
        let shown = run.text
        expect(shown.contains("\u{2717} Not serving: " + notVerified + ".\n"), "refused: why, in one line: \(shown)")
        expect(!shown.contains("\u{2713} Serving") && !shown.contains("Done.") && !shown.contains(ClusterOnboardingReady.offeredTestLine),
               "refused: no Serving, no Done, no test claimed: \(shown)")
        run.type("4")
        expect(run.waitFor("Saved a diagnostics file"), "refused: Diagnostics saves the file")
        expect(run.waitFor(notServingChoices, count: 2), "refused: the choices again after the file")
        run.type("q")
        let code = run.finish()
        expect(code == 1, "refused: leaving is not success, got \(String(describing: code))")
        let text = run.text
        expect(!text.contains("\u{2713} Serving") && !text.contains("Done."), "refused: never Serving or Done: \(text)")
        expect(text.hasSuffix("Not serving yet. Both Macs keep trying by themselves; run `darkbloom cluster` to check.\n"),
               "refused: the last line says it does not serve: \(text)")
        expect(recorder.all.contains("pairServing") && !recorder.all.contains("testRequest"),
               "refused: the pair's own serving is awaited (no local API to test): \(recorder.all)")
        transcript("offered-pair-refused", text, keys: run.keys)

        // Retry, once the coordinator paired them meanwhile: served, then Done.
        let retried = Recorder()
        let again = TerminalRun(operations(retried, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyResult: .success(offeredReady),
            pairServingResults: [.failure(.init(notVerified)), .success(["in 0.84 s"])]))
        expect(again.waitFor(prompt(2)), "retry: the list"); again.type("\r")
        expect(again.waitFor(notServingChoices), "retry: the choices"); again.type("1")
        expect(again.finish() == 0, "retry: served")
        expect(again.text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)\n")
            && again.text.contains("Done."), "retry: Serving and Done only after the pair served: \(again.text)")
        expect(retried.all.filter { $0 == "pairServing" }.count == 2, "retry: waited again: \(retried.all)")
    }

    /// (b) The registration after the Test stage restarts both parts as cluster members; a restart that does not
    /// come back is said with its reason and the choices, and the screen never says Done.
    static func failedRestartAfterTheRegistrationIsNotDone() {
        let recorder = Recorder()
        let ended = "A part keeps ending the same way: rank 0 on the other Mac ended (exit 1); it starts again by itself."
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), registerResult: .success([registeredLine]),
            readyResults: [.success(.init(servedBy: "this Mac", port: 8000, split: "pipeline")), .failure(.init([ended]))]))
        expect(run.waitFor(prompt(2)), "restart: the list"); run.type("\r")
        expect(run.waitFor("Starting both Macs' parts again as cluster members…"), "restart: the restart line")
        _ = run.waitFor(notServingChoices, seconds: 5)
        run.type("q")
        let code = run.finish()
        let text = run.text
        expect(code == 1, "restart: a failed restart is not success, got \(String(describing: code))")
        expect(!text.contains("Done."), "restart: never Done: \(text)")
        expect(text.contains("\u{2717} Not serving: " + ended + "\n"), "restart: why: \(text)")
        expect(text.contains(notServingChoices), "restart: the choices: \(text)")
        expect(Array(recorder.all.prefix { $0 != "register" }.suffix(2)) == ["waitReady", "testRequest"]
            && recorder.all.filter { $0 == "waitReady" }.count == 2, "restart: tested, registered, then the parts awaited: \(recorder.all)")
        transcript("restart-after-registration-fails", text, keys: run.keys)
    }

    /// (c) Serving through Darkbloom needs both Macs logged in: a Mac without a login is named before the Start step
    /// starts anything, with `darkbloom login` or local-only serving offered.
    static func missingLoginIsSaidBeforeTheStart() {
        let both = [ClusterOnboardingMacName.this, ClusterOnboardingMacName.other(named: "Apple M3 Ultra, 256 GB")]
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), missingLogins: both))
        expect(run.waitFor(prompt(2)), "login: the list"); run.type("\r")
        expect(run.waitFor("  1) Log in on this Mac\n  2) Serve locally only\n  3) Cancel\n"), "login: the choices: \(run.text)")
        let shown = run.text
        let said = shown.range(of: ClusterOnboardingNotServing.notLoggedIn(both) + ".")
        expect(said != nil, "login: which Macs, in one line: \(shown)")
        let start = shown.range(of: "4/4 Start")
        expect(said != nil && (start == nil || said!.lowerBound < start!.lowerBound), "login: before the Start step: \(shown)")
        expect(!recorder.all.contains { $0.hasPrefix("adopt") || $0 == "serve" }, "login: nothing started yet: \(recorder.all)")
        run.type("3")
        expect(run.finish() == 0, "login: cancel")
        expect(run.text.hasSuffix("Nothing changed.\n"), "login: nothing changed: \(run.text)")

        // Log in here: the other Mac still has none, so its own `darkbloom login` is asked for; then local only.
        let switched = Recorder()
        let local = TerminalRun(operations(switched, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyResult: .success(localReady), missingLogins: both))
        expect(local.waitFor(prompt(2)), "login, local: the list"); local.type("\r")
        expect(local.waitFor("  1) Log in on this Mac\n"), "login, local: the choices"); local.type("1")
        expect(local.waitFor("Run `darkbloom login` on the other Mac, then Check again.\n"), "login, local: the other Mac's turn: \(local.text)")
        expect(local.waitFor("  1) Check again\n  2) Serve locally only\n  3) Cancel\n"), "login, local: check again")
        local.type("2")
        expect(local.finish() == 0, "login, local: served locally")
        expect(switched.all.contains("login") && switched.all.contains("setScope local 0.0.0.0"),
               "login, local: logged in here, then local only saved: \(switched.all)")
        let setScope = switched.all.firstIndex(of: "setScope local 0.0.0.0"), serve = switched.all.firstIndex(of: "serve")
        expect(setScope != nil && serve != nil && setScope! < serve!, "login, local: saved before the start: \(switched.all)")
        expect(local.text.contains("local API only\n") && local.text.contains("Done."), "login, local: serving locally: \(local.text)")
        expect(!switched.all.contains("register"), "login, local: no registration with a coordinator: \(switched.all)")
    }

    /// (d) Offered for pairing, then the coordinator committed the pair, both Macs loaded it and it answered its first
    /// request: Serving and Done, as before, now said only then.
    static func offeredPairServesOnceLoaded() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyResult: .success(offeredReady), pairServingResults: [.success(["in 0.84 s"])]))
        expect(run.waitFor(prompt(2)), "served: the list"); run.type("\r")
        let code = run.finish()
        expect(code == 0, "served: exit 0, got \(String(describing: code))")
        let text = run.text
        expect(text.contains("  Test response in 0.84 s\n"), "served: the pair's first request: \(text)")
        expect(text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)\n"), "served: the line: \(text)")
        expect(text.hasSuffix("Done. You can close both windows.\n" + ClusterOnboardingDriver.againLine + "\n"), "served: Done: \(text)")
        expect(Array(recorder.all.suffix(3)) == ["serve", "waitReady", "pairServing"], "served: loaded before it is said: \(recorder.all)")
        transcript("offered-pair-served", text, keys: run.keys)
    }

    /// The pair's progress lines a coordinator-paired part writes, and the plain words of the reasons the Macs know.
    static func pairReportsAndReasonsInPlainWords() {
        typealias R = ClusterOnboardingPairReport
        let log = "darkbloom 0.10.7 (registered cluster member; solo inference disabled)\n" + offeredLogLine + "\n"
            + R.startingLine + "\n" + R.servingLine(warmupSeconds: 0.8412) + "\n"
        expect(R.latest(inLog: log) == .serving(test: "in 0.84 s"), "report: serving with the first request's time")
        expect(R.latest(inLog: log + R.stoppedLine("memory_gate_refused") + "\n") == .stopped("memory_gate_refused"), "report: stopped")
        expect(R.latest(inLog: "no pair line\n") == nil, "report: none")
        expect(R.state("serving") == .serving(test: nil) && R.state("starting") == .starting && R.state("other") == nil, "report: states")
        expect(R.state(R.text(.serving(test: "in 0.84 s"))) == .serving(test: "in 0.84 s"), "report: the status's text reads back")
        typealias N = ClusterOnboardingNotServing
        let other = "the other Mac (Apple M3 Ultra, 256 GB)"
        for reason in ["liveness:trust_floor", "member rank 0 provider p: liveness:private_text", "app_attest_required (app_attest:lease)"] {
            expect(N.words(reason: reason, mac: other) == N.notVerified(other),
                   "words: \(reason)")
        }
        expect(N.words(reason: "memory_gate_refused", mac: other) == "The other Mac (Apple M3 Ultra, 256 GB) lacks free memory for its share", "words: memory")
        expect(N.words(reason: "x\u{1B}[2J", mac: other) == "The coordinator didn't accept the pair (no reason given)", "words: never control characters")
        expect(N.notLoggedIn(["this Mac"]) == "This Mac isn't logged in to Darkbloom, so the coordinator won't pair it", "words: one Mac")
        expect(N.remedy(forReason: notVerified)?.contains("Retry") == true && N.remedy(forReason: "anything") == nil, "remedy")
    }

    static let offeredLogLine = "Notice: " + ClusterOnboardingReady.registeredNotice + " with an installed cluster approval"

    // MARK: - The end user's call (Dylan, 2026-11-03): a clear outcome, a sense of time, the reason with its time

    /// The outcome block as a plain transcript shows it.
    static func block(_ mark: String, _ title: String, _ lines: [String]) -> String {
        "\n" + ClusterOnboardingDriver.resultRule + "\n" + mark + " " + title + "\n" + lines.map { "  " + $0 + "\n" }.joined()
            + ClusterOnboardingDriver.resultRule + "\n"
    }

    static let colourTerminal = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"]

    /// Dylan's M4 pair: the leader's App Attest key was cut 0.7 s into Apple's attestation, and its key-generation
    /// safeguard cleared at about 00:34 UTC.
    static let appleRetry = ISO8601DateFormatter().date(from: "2026-11-04T00:34:00Z")!
    static let notVerifiedTimed = ClusterOnboardingNotServing.notVerified("the other Mac (Apple M4 Max, 128 GB)", retryAt: appleRetry,
                                                                          timeZone: TimeZone(identifier: "UTC")!)

    /// (e) Step 4 says it takes a while, then shows one live row per Mac with the time since loading began.
    static func startSaysItTakesAWhileAndShowsEachMac() {
        let run = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "notice: the list"); run.type("\r")
        expect(run.finish() == 0, "notice: served")
        expect(run.text.contains("4/4 Start\n  " + ClusterOnboardingDriver.startNotice + "\n"), "notice: under the Start heading: \(run.text)")

        let live = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyReports: ["1 of 2 parts ready\nThis Mac: ready\nThe other Mac (Apple M3 Ultra, 256 GB): loading its share"],
            readyReportPause: 900_000), environment: colourTerminal)
        expect(live.waitFor(arrowHint), "rows: the list"); live.type("\r")
        expect(live.waitFor("The other Mac (Apple M3 Ultra, 256 GB): loading its share \u{00B7} "), "rows: the other Mac's row with its time")
        expect(live.text.contains("This Mac: ready \u{00B7} "), "rows: this Mac's row with its time")
        _ = live.finish()
        let rowsShown = live.text.components(separatedBy: "\n").filter { $0.contains("loading its share") || $0.contains("This Mac: ready") }
        expect(!rowsShown.isEmpty && !rowsShown.contains { $0.contains("%") || $0.contains("\u{2588}") }, "rows: no bar or percent without a real fraction")

        var clock = ClusterOnboardingLoadRows(started: Date(timeIntervalSince1970: 0))
        let first = clock.rows("Loading m on both Macs", report: "1 of 2 parts ready\nThis Mac: ready\nThe other Mac: loading its share",
                               now: Date(timeIntervalSince1970: 48))
        expect(first == ["Loading m on both Macs (1 of 2 parts ready) \u{00B7} 48 s", "This Mac: ready \u{00B7} 48 s",
                         "The other Mac: loading its share \u{00B7} 48 s"], "clock: \(first)")
        let later = clock.rows("Loading m on both Macs", report: "2 of 2 parts ready\nThis Mac: ready\nThe other Mac: ready",
                               now: Date(timeIntervalSince1970: 75))
        expect(later == ["Loading m on both Macs (2 of 2 parts ready) \u{00B7} 1 min 15 s", "This Mac: ready \u{00B7} 48 s",
                         "The other Mac: ready \u{00B7} 1 min 15 s"], "clock: a Mac's time stops once it is ready: \(later)")
    }

    /// (f) The outcome is its own block: ✓ with what serves and how it was checked, or ✗ with why and the next step.
    static func theOutcomeIsItsOwnBlock() {
        let leader = ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB")
        let run = TerminalRun(operations(Recorder(), resume: leader, pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "block: the list"); run.type("\r")
        expect(run.finish() == 0, "block: served")
        expect(run.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
            ["API at http://localhost:8000 on this Mac", "Test response in 0.61 s"]) + "Done. You can close both windows.\n"),
               "block: through Darkbloom, then Done: \(run.text)")
        transcript("outcome-through-darkbloom", run.text, keys: run.keys)

        let local = TerminalRun(operations(Recorder(), resume: leader, pairEvents: [], pairResult: .failed([]),
            readyResult: .success(localReady)), request: localRequest)
        expect(local.waitFor(prompt(2)), "block, local: the list"); local.type("\r")
        expect(local.finish() == 0, "block, local: served")
        expect(local.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp on this Mac's local API only",
            [localReady.apiLine, "Test response in 0.61 s"])), "block, local: \(local.text)")
        transcript("outcome-local-only", local.text, keys: local.keys)

        let offered = TerminalRun(operations(Recorder(), resume: leader, pairEvents: [], pairResult: .failed([]),
            readyResult: .success(offeredReady), pairServingResults: [.success(["in 0.84 s"])]))
        expect(offered.waitFor(prompt(2)), "block, offered: the list"); offered.type("\r")
        expect(offered.finish() == 0, "block, offered: served")
        expect(offered.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
            [ClusterOnboardingReady.offeredAPILine, "Test response in 0.84 s"])), "block, offered: \(offered.text)")

        let refused = TerminalRun(operations(Recorder(), resume: leader, pairEvents: [], pairResult: .failed([]),
            readyResult: .success(offeredReady), pairServingResults: [.failure(.init(notVerifiedTimed))]))
        expect(refused.waitFor(prompt(2)), "block, refused: the list"); refused.type("\r")
        expect(refused.waitFor(notServingChoices), "block, refused: the choices"); refused.type("q")
        expect(refused.finish() == 1, "block, refused: exit 1")
        expect(refused.text.contains(block("\u{2717}", "Not serving: " + notVerifiedTimed + ".",
            [ClusterOnboardingNotServing.remedy(forReason: notVerifiedTimed) ?? "-"]) + notServingChoices), "block, refused: \(refused.text)")
        transcript("outcome-not-serving-app-attest", refused.text, keys: refused.keys)
    }

    /// (g) Not verified by Apple yet: when Darkbloom retries by itself (the local key-generation safeguard), and to
    /// leave both Macs alone until then; "within minutes" when the time is unknown.
    static func appleVerificationSaysWhenItRetries() {
        expect(notVerifiedTimed == "The other Mac (Apple M4 Max, 128 GB) isn't verified by Apple yet; Darkbloom retries by itself at about 00:34. "
            + "Don't restart either Mac until then", "apple: with the time: \(notVerifiedTimed)")
        expect(ClusterOnboardingNotServing.notVerified("this Mac") == "This Mac isn't verified by Apple yet; Darkbloom retries by itself within minutes. "
            + "Don't restart either Mac until then", "apple: without a time")
        expect(ClusterOnboardingNotServing.words(reason: "liveness:private_text", mac: "this Mac") == ClusterOnboardingNotServing.notVerified("this Mac"),
               "apple: the coordinator's words map to the same line")
    }

    /// (h) The other Mac's window: where to see the outcome once it joined, and the outcome itself when it can know it.
    static func memberSeesTheOutcomeOrWhereToLook() {
        expect(ClusterOnboardingDriver.joinedLine.contains("its screen shows whether the cluster serves"), "member: where to look: \(ClusterOnboardingDriver.joinedLine)")
        let serving = TerminalRun(operations(Recorder(), resume: .init(role: .member, peerName: "Apple M5 Ultra, 256 GB", serving: true),
            pairEvents: [], pairResult: .failed([]), statusLines: ["Serving Qwen3.8-27B-4bit-mtp (pipeline) through Darkbloom on both Macs."]))
        expect(serving.finish() == 0, "member: served")
        expect(serving.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp (pipeline) through Darkbloom on both Macs", [])),
               "member: the outcome block: \(serving.text)")
        let notServing = TerminalRun(operations(Recorder(), resume: .init(role: .member, peerName: "Apple M5 Ultra, 256 GB", serving: true),
            pairEvents: [], pairResult: .failed([]), statusLines: ["Qwen3.8-27B-4bit-mtp is not serving yet: " + notVerifiedTimed + ".",
                ClusterOnboardingNotServing.remedy(forReason: notVerifiedTimed) ?? "-"]))
        _ = notServing.finish()
        expect(notServing.text.contains(block("\u{2717}", "Not serving: " + notVerifiedTimed + ".",
            [ClusterOnboardingNotServing.remedy(forReason: notVerifiedTimed) ?? "-"])), "member: the not-serving block: \(notServing.text)")
    }
}
