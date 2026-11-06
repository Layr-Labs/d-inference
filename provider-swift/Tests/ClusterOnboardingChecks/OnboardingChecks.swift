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
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(600); defer { alarm(0) }
        // A run over pipes that ended closes its end; a late key is then an error, never the end of the checks.
        signal(SIGPIPE, SIG_IGN)
        aFinishedRunLeavesNothingReadingItsTerminal()
        privateMiMoSelectionRefusesBeforeAnyActionOnMemberOrUnpairedMac()
        terminalPresentationFallbacks()
        // The start's progress on both Macs (2026-11-04).
        startProgressFieldsAndComponents()
        leaderShowsEachMacsPartFitted()
        theJoinedMacShowsTheStartsProgress()
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
        // The owner, 2026-11-05: each Mac's part by the mark.
        roleHeaderChecks()
        // The owner, 2026-11-05: "all captured in one, instead of keep dropping down a million lines in the CLI".
        stepFoldChecks()
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
        // Pair 2, 2026-11-03: MiMo's 172.9 GB download was offered on an M3 Ultra with 54.1 GB free.
        modelWithoutRoomOnDiskIsMarked()
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
        memberWaitsForLeaderSetupAfterUpdate()
        // F9 + F16 (round 6b, 2026-10-14): failing first on 33da00709.
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
        // P2-11 (pair-2, 2026-11-04): the card said "on both Macs" from this Mac's service alone.
        theLoginLineNamesTheMacThatDoesNot()
        // The audit of that change: keys during waits, q, SSH, a probe that tells nothing, a slow Allow on the other
        // Mac, and how the pair serves.
        arrowKeysDoNotStopAWait()
        qCancelsAListBeforeALetter()
        sshSessionsAreToldWhereThePromptIs()
        bothMacsSayScreenSharingFirst()
        otherMacPromptNamesItsScreen()
        sshSaysBeforeTryingWhereToRun()
        serviceThatCannotTellStillGetsTheAsk()
        otherMacThatDidNotAnswerOffersTryAgain()
        startSaysHowThePairServes()
        // The two-Mac test on two M5 Ultras and the final review: which physical Mac plays which part, a model copied
        // from the other Mac, a model that does not fit now, and the window's line.
        eachMacNamesItselfBesideItsPart()
        modelOnTheOtherMacIsCopiedNotDownloaded()
        modelThatDoesNotFitSaysSoOnce()
        // Already paired Macs whose pairing cannot be used (2026-11-03): failing first on 0f99ddb18.
        keyChangedLeaderPairsAgain()
        keyChangedMemberPairsAgain()
        keyChangedQuitChangesNothing()
        memberWhoseLeaderIsSilentPairsAgain()
        leaderWhoseMemberIsSilentOffersStartOver()
        answeringOtherMacKeepsTheScreens()
        failedUnpairStopsBeforePairing()
        // The owner's second pair and an end user's live session (2026-11-03): failing first on 9f9ddf1ed.
        reachWaitSaysWhyAndOffersStartOver()
        cableStepContinuesToTheNextStep()
        memberNamesItsLeaderAndTheNextStep()
        startOverIsAlwaysOfferedWithOneConfirmation()
        // 2026-11-03, the owner's second pair and an end user's: "Serving" and "Done" while nothing was loaded.
        offeredPairThatTheCoordinatorRefusesSaysWhy()
        failedRestartAfterTheRegistrationIsNotDone()
        missingLoginIsSaidBeforeTheStart()
        theDevNetAppNamesItsOwnCommand()
        aDevNetLiveRowNamingACommandStillFitsTheWindow()
        aLoginCheckThatTurnsLocalAdoptsTheLocalPlan()
        offeredPairServesOnceLoaded()
        pairReportsAndReasonsInPlainWords()
        // The end user's call (Dylan, 2026-11-03): a clear outcome, a sense of time, the reason with its time.
        startSaysItTakesAWhileAndShowsEachMac()
        theOutcomeIsItsOwnBlock()
        appleVerificationSaysWhenItRetries()
        memberSeesTheOutcomeOrWhereToLook()
        // A set-up pair works like `darkbloom start` (owner, 2026-11-04): failing first on c8a6b5a49.
        leaderScreenIsTheModelList()
        memberScreenSaysWhoLeadsAndWhatToRun()
        switchAsksOnceThenEndsLikeStart()
        qAtTheListChangesNothing()
        aModeChangeOfTheServingModelIsAskedAsOne()
        aSetUpPairWithNoModelToListOffersStartOver()
        aPairThatDoesNotServeIsNeitherMarkedNorTestedTwice()
        theServingMarkerFollowsOnlyASettledServingLine()
        theServingModelsTestNeverMarksAStart()
        pairingSaysWhatToCheckWhenTheOtherMacIsNotFound()
        // R-3 (the pair-2 re-test, 2026-11-04): the hint's firewall line named production's app in the DevNet app.
        pairingLinesNameTheApp()
        // R-8 (the round-3 re-test): a stopped DevNet pair's status named `darkbloom local`.
        theServingLinesNameThisBuildsCommand()
        alreadyServingTestsAgainOrSaysWhyNot()
        aDeadPendingStartIsClearedOnlyWhileStillRecorded()
        modeChoiceOffersBothWithTheFastestMeasuredFirst()
        modeQuestionRecommendsOneForTheseMacs()
        // R6-2 (M5 Ultra pair, DevNet branch.81): each mode's line was cut at 120 columns, and a wider window never redrew it.
        modeLinesFitTheWindowAsItIsNow()
        // DevNet .118, pair-2 (2026-11-06): right after the update the question said "Pipeline, faster here" for Gemma,
        // from predictions, though these Macs had served its tensor parallel faster with every earlier build.
        modeAdviceFollowsTheseMacsMeasurementsAfterAnUpdate()
        theListAndTheDefaultFollowTheRecommendation()
        // DevNet .118, pair-2 (2026-11-06): the list still quoted each mode's tok/s.
        modelListMarksTheCurrentModelAndQuotesNoSpeed()
        firstRunSaysWhatWillBeAsked()
        stoppedPairPreselectsTheLastModel()
        switchToDarkbloomChecksLoginsFirst()
        // The refactor pass's finding: the menu's switch to Darkbloom claimed ✓ for a registered pair.
        menuSwitchToDarkbloomWaitsForThePair()
        // The DevNet traffic run (2026-11-04): the switch to Darkbloom kept the local plan, the pair was never offered,
        // and both windows said ✓. Failing first on 447b230367.
        switchToDarkbloomPlansTheModelAgain()
        aPairThatIsNotOfferedEndsWithWhyNot()
        theServingModelChosenAgainWhenNotOfferedIsPlannedAgain()
        theJoinedMacEndsWithTheLeadersNotOffered()
        aStartTheCoordinatorDidNotTakeNeverEndsWithATick()
        // UX audit P3 (2026-11-04): silence is not a broken pairing. Failing first on a91d5d51d7.
        silenceIsNotABrokenPairing()
        // The seam the stack's merge left: Change model after ✗ keeps a Mac paired before this run's choices. Failing
        // first on 1ec3a927ce.
        changeModelAfterNotServingKeepsTheChoices()
        // The owner's O8 and A1 (2026-11-04): the Mac that joined follows the start; the registration reads as offered.
        // Failing first on c8a6b5a494.
        joinedMacFollowsTheStartToServing()
        aLateOfferNeverGivesTheJoinedMacAnEarlyTick()
        joinedMacFollowsTheStartToNotServing()
        joinedMacLeavesOrStopsFollowingSaying()
        registrationIsSaidAsOfferedNotAccepted()
        // Validator D on PR #1778: both windows end alike, only the start that registers marks itself, the pending check
        // is no ✓, each stage of the start has its own bound. Failing first on a148285f70.
        aFailedStartTestEndsTheJoinedMacTheSame()
        theJoiningMacMirrorsALocalStartsFailedTest()
        theJoiningMacSaysWhenItsServiceIsKeptOffTheLocalNetwork()
        theJoiningMacShowsTheLeadersStateWhileItWaits()
        retryStartsAStoppedPairAndQLeavesTheWait()
        theJoiningMacMirrorsTheLeadersPass()
        onlyTheStartThatRegistersMarksItself()
        thePendingCheckIsNoTickOnAnyScreen()
        eachStageOfTheStartHasItsOwnBound()
        // A user's report (2026-11-04): "an infinite loop of waiting for the other Mac, Apple M5 Max 128 GB".
        followWaitChecks()
        // 0.10.9 DevNet, pair-2 (f2): the joining Mac's last word is the leading Mac's outcome.
        followFinalOutcomeChecks()
        // R7-1 (DevNet branch.87): the registration's hand-off is no ✗ on the joining Mac.
        noFalseCrossChecks()
        // A 0.10.8 user's leader screen: its loading line repeated end to end in a narrow window.
        liveLineChecks()
        // 0.10.8, 2026-11-04: one Mac of a pair updated alone; its part ended every 38 s and no screen named the versions.
        versionSplitChecks()
        // DevNet pair-2, 2026-11-05: the coordinator's wait blamed Apple, couldn't be left, and the joining Mac didn't follow.
        waitHonestChecks()
        // 0.10.8, 2026-11-04: single-Mac serving held the provider instance lock on both Macs of a pair; the start looped
        // "this Mac's part ended (… another update operation owns the lock (pid 9523, provider-instance)) and starts again
        // by itself", the other Mac read "no error reported", and the guidance was `darkbloom stop`, which stops the pair.
        soloServingOnBothMacsIsSaidBeforeAnythingStarts()
        soloServingIsLeftWithNothingStarted()
        soloServingFoundWhileWaitingIsNeverRetried()
        soloServingNamesTheDevNetCommand()
        // 0.10.9 DevNet, pair-2 (f1): the leader showed the block, the joining Mac said "registering with the coordinator"
        // for minutes while its own part waited for its single-Mac provider (process 68099).
        soloServingOnTheJoiningMacIsSaidOnBothScreens()
        theJoiningMacFollowsTheStartOnceSingleMacServingStops()
        // 0.10.9 DevNet build C (R8-1): the joining Mac opened on a stopped pair while its own single-Mac provider blocked
        // the leader's start, and said "Stopped … Close" with no ✗.
        theJoiningMacOnAStoppedPairSaysTheBlock()
        stoppedLocalPairSwitchedToDarkbloomKeepsItsMode()
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
            // The bloom climbs the mark's height and draws it again (a folded step climbs too, then erases).
            expect(run.text.contains("\u{1B}[\(ClusterOnboardingBrand.height)A  \u{1B}[") == animated, "colour: the mark blooms only when animating")
            expect(!run.text.contains("\u{1B}[2J") && !run.text.contains("\u{1B}[H"), "colour: no screen clearing")
            expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0",
                "serve", "waitReady", "testRequest", "register", "waitReady", "pairServing"], "colour: operations in order: \(recorder.all)")
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
            expect(Array(recorder.all.suffix(4)) == ["testRequest", "register", "waitReady", "pairServing"], "\(label): the setup ran to its test: \(recorder.all)")
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
        expect(Array(recorder.all.suffix(4)) == ["testRequest", "register", "waitReady", "pairServing"], "45 columns: the setup ran to its test: \(recorder.all)")
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
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression) }
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
        expect(run.text.hasSuffix("Setup saved, but the test failed. To test again, run `darkbloom cluster` and choose Qwen3.8-27B-4bit-mtp: "
            + "it sends one test request.\n"), "failure is explicit and ends with its next action, which tests: \(run.text)")
        expect(!run.text.contains(startedLogs), "failed response never reports setup success")
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
        /// How often the other Mac was asked whether it answers (kept apart, so the flows' call lists stay as they were).
        var probes = 0
        func note(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        /// The next scripted answer of the other Mac (the last one repeats; none scripted: it answers).
        func probe(_ answers: [Bool]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            probes += 1
            return answers.isEmpty ? true : answers[min(probes, answers.count) - 1]
        }
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
                           registerResult: Result<[String], ClusterOnboardingFailure> = .success([registeredLine]),
                           localNetwork: @escaping @Sendable (ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork = { _ in .allowed },
                           linkScript: String? = nil,
                           sudoSucceeds: Bool = true,
                           outlivesWindow: Bool = true,
                           remote: Bool = false,
                           commandApp: String = "Terminal",
                           thisMacName: String? = nil,
                           otherMacAnswers: [Bool] = [],
                           statusLines: [String]? = nil,
                           unpairResult: Result<[String], ClusterOnboardingFailure> = .success(["\u{2713} Unpaired this Mac."]),
                           reachFailures: Int = 0,
                           reachWaiting: [String] = [],
                           reachFailure: [String] = ["The other Mac did not answer over the cable."],
                           reachAnswers: [Bool] = [],
                           readyResult: Result<ClusterOnboardingReady, ClusterOnboardingFailure> = .success(.init(servedBy: "this Mac", port: 8000,
                               deployment: "Serving Qwen3.8-27B-4bit-mtp across both Macs: pipeline, this Mac 32 layers / the other Mac 32 layers",
                               split: "pipeline")),
                           readyResults: [Result<ClusterOnboardingReady, ClusterOnboardingFailure>]? = nil,
                           pairServingResults: [Result<[String], ClusterOnboardingFailure>] = [.success(["in 0.61 s"])],
                           missingLogins: [String] = [],
                           loginSucceeds: Bool = true,
                           readyReports: [String] = ["1 of 2 parts ready", "2 of 2 parts ready"],
                           readyReportPause: useconds_t = 50_000,
                           statusSequence: [[String]]? = nil,
                           followSeconds: Double = 900,
                           pairHintSeconds: Double = 900,
                           pairWait: Double = 0,
                           planFailure: [String]? = nil) -> ClusterOnboardingOperations {
        let answered = DispatchSemaphore(value: 0)
        let chosenPort = Recorder()
        // The n-th wait for the parts answers `readyResults[n]` (the last one again after it), else `readyResult`.
        @Sendable func ready(_ call: Int) -> Result<ClusterOnboardingReady, ClusterOnboardingFailure> {
            guard let readyResults, !readyResults.isEmpty else { return readyResult }
            return readyResults[min(call, readyResults.count - 1)]
        }
        let loggedOut = Recorder()
        for mac in missingLogins { loggedOut.note(mac) }
        // The coordinator serves this pair an approval (the default): the start registers it, and the pair is awaited.
        let registered: Bool
        if case .success(let lines) = registerResult { registered = lines.first?.hasPrefix(ClusterOnboardingReady.registeredNotice) == true }
        else { registered = false }
        // The n-th status answers `statusSequence[n]` (the last one again after it), else `statusLines` or the default.
        let looked = Recorder()
        var made = ClusterOnboardingOperations(
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
                for (index, event) in pairEvents.enumerated() {
                    events(event)
                    if case .code = event { asked = true; _ = answered.wait(timeout: .now() + 10) }
                    usleep(20_000)
                    // The other Mac not found yet: the pairing waits this long after it began listening.
                    if index == 1, pairWait > 0 { usleep(useconds_t(pairWait * 1_000_000)) }
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
            reachMembers: { waiting in
                recorder.note("reachMembers")
                // The n-th reading answers when `reachAnswers[n]` says so (the last one repeats); none scripted: the
                // first `reachFailures` fail.
                let call = recorder.all.filter { $0 == "reachMembers" }.count
                if reachAnswers.isEmpty ? call <= reachFailures : !reachAnswers[min(call, reachAnswers.count) - 1] {
                    for line in reachWaiting { waiting(line); usleep(20_000) }
                    return .failure(.init(reachFailure))
                }
                return .success(machines)
            },
            planModels: {
                recorder.note("planModels")
                if let planFailure { return .failure(.init(planFailure)) }
                let again = recorder.all.filter { $0 == "planModels" }.count > 1
                return .success(again ? (replanned ?? choices) : choices)
            },
            adopt: { index in recorder.note("adopt \(index)"); return .success(["Saved this Mac's setup.", "Sent the setup to the other Mac over the cable; its cluster service applied it."]) },
            serve: { recorder.note("serve"); return .success(["Started the other Mac's part over the cable (its cluster service runs it); this Mac's service runs its own."]) },
            waitReady: { progress in
                let call = recorder.all.filter { $0 == "waitReady" }.count
                let afterRegistration = registered && recorder.all.contains("register")
                recorder.note("waitReady")
                for report in readyReports { progress(report); usleep(readyReportPause) }
                // Once registered, both parts start again as the pair's members: offered for pairing.
                guard afterRegistration, case .success(var value) = ready(call), value.offered == nil else { return ready(call) }
                value.offered = registeredLine
                return .success(value)
            },
            testRequest: { recorder.note("testRequest"); return testResult },
            // Rank 0, which serves the API, is the Mac that leads: this Mac on the leader, the other Mac on a member.
            status: { recorder.note("status")
                if let statusSequence, !statusSequence.isEmpty {
                    looked.note("status")
                    return statusSequence[min(looked.all.count, statusSequence.count) - 1]
                }
                return statusLines ?? (resume.role == .member
                ? ["Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)."]
                : ["Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 (earning through Darkbloom)."]) },
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
            otherMacAnswers: { recorder.probe(otherMacAnswers) },
            unpair: { recorder.note("unpair"); return unpairResult },
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
            },
            useMode: { index, mode in recorder.note("useMode \(index) \(mode)") })
        // The Mac that joined follows the start at a check's pace.
        made.followTiming = .init(seconds: followSeconds, pollSeconds: 0.02)
        made.pairHintSeconds = pairHintSeconds
        return made
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
        /// Left once the reader read its last byte and will never use its descriptor again. The terminal closes only
        /// after that: a reader still polling a closed number reads the next run's terminal once `openpty` reuses the
        /// number, and takes that run's first lines (its title) or, on its blocking slave end, its keys (q).
        let reading = DispatchGroup()

        init(_ operations: ClusterOnboardingOperations, request: ClusterOnboardingRequest = .init(),
             environment: [String: String] = ["NO_COLOR": "1"], columns: UInt16 = 132, rows: UInt16 = 50, logFile: URL? = nil) {
            var primary: Int32 = -1, secondary: Int32 = -1
            var window = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            precondition(openpty(&primary, &secondary, nil, nil, &window) == 0)
            master = primary; slave = secondary
            _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
            let reader = primary
            reading.enter()
            Thread.detachNewThread { [self] in
                defer { reading.leave() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    // The end is checked before the poll: a run that had ended by then wrote every byte already, so an
                    // empty read after it is the end of the text, never a byte still on its way.
                    let ended = code != nil
                    var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&descriptor, 1, 20) >= 0 else { return }
                    let count = Darwin.read(reader, &buffer, buffer.count)
                    if count > 0 { lock.withLock { captured.append(contentsOf: buffer.prefix(count)) } }
                    if ended && count <= 0 { return }
                }
            }
            let slaveFD = secondary
            Thread.detachNewThread { [self] in
                let console = ClusterOnboardingTerminal(input: slaveFD, output: slaveFD, environment: environment, logFile: logFile)
                let code = ClusterOnboardingDriver.run(operations, console: console, request: request)
                console.restore()
                usleep(100_000)
                lock.lock(); exitCode = code; lock.unlock()
                done.signal()
            }
        }

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: captured, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n") }
        var code: Int32? { lock.lock(); defer { lock.unlock() }; return exitCode }

        // Both threads hold the run until they end, so the pseudo-terminal is free by then: a whole run of the checks
        // otherwise keeps one per flow, and the Mac's limit is shared with every other terminal.
        // `release()` may have closed them already: never twice, or a later run's terminal, reusing the numbers, closes.
        deinit { closeTerminal() }

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

        /// The exit status once the run ended and every byte it wrote was read (nil while it still runs).
        func finish(seconds: Double = 10) -> Int32? {
            _ = done.wait(timeout: .now() + seconds)
            guard let code else { return nil }
            reading.wait()
            return code
        }

        /// Closes both ends once the run ended and its reader stopped, so a long list of checks never runs out of
        /// pseudo-terminals and no reader outlives its terminal.
        func release() {
            guard code != nil else { return }
            reading.wait()
            closeTerminal()
        }

        private var closed = false
        private func closeTerminal() {
            guard lock.withLock({ defer { closed = true }; return !closed }) else { return }
            Darwin.close(master); Darwin.close(slave)
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

    /// The harness itself (runs 42057277814 and 42082393871, 2026-11-05): a run's reader stopped up to a poll after the
    /// run's end, so `release` closed the terminal under it, the next run's `openpty` got the same numbers, and the old
    /// reader took that run's title ("role, before pairing") or its q ("coordinator q"). The reader now stops before
    /// `finish` returns, and so before `release` closes anything.
    static func aFinishedRunLeavesNothingReadingItsTerminal() {
        let run = TerminalRun(operations(Recorder(), pairEvents: memberEvents, pairResult: .failed(["Cancelled: nothing paired."])))
        expect(run.finish(seconds: 20) != nil, "harness: the run ended")
        expect(run.reading.wait(timeout: .now()) == .success, "harness: finish returns once the reader read the last byte and stopped")
        let ended = run.text
        run.release()
        expect(run.text == ended, "harness: no byte arrives after finish: \(run.text.dropFirst(ended.count))")
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
            "  Allow macOS permissions.",
            "  \(prompt(2))Yes",
            "  " + ClusterOnboardingPairing.otherMacAnswerLine,
            "  \u{2713} Paired. This Mac leads.",
            "  \(prompt(2))Qwen3.8-27B-4bit-mtp",
            "\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
            "  " + ClusterOnboardingReady.offeredAPILine,
            "  Test response in 0.61 s",
            "  " + ClusterOnboardingDriver.startNotice,
        ] {
            expect(text.contains(line + "\n"), "leader: \(line)")
        }
        // What is done, then the one thing to do next: the last line.
        expect(text.contains(startedLogs) && text.hasSuffix(commandLines), "leader: the card, then the commands: \(text)")
        expect(!text.contains("Setup sent") && !text.contains("confirmed the code") && !text.contains("Cable found"),
               "leader: no line repeats what another says")
        expect(!text.contains("127.0.0.1"), "leader: no bare loopback address")
        expect(!text.contains("Run `darkbloom cluster` on the other Mac too."), "leader: the link flow's own ending is not repeated")
        expect(!text.contains("press n to stop") && !text.contains("Options:"), "leader: no countdown and no options paragraph after the choice")
        let positions = stages.compactMap { text.range(of: $0)?.lowerBound }
        expect(positions.count == stages.count && positions == positions.sorted(), "setup stages stay in order")
        expect(!text.contains("\u{1B}"), "NO_COLOR transcript has no terminal escapes")
        expect(visible(text).filter { !$0.isEmpty }.count <= leaderLineBudget,
               "leader: a short screen: \(visible(text).filter { !$0.isEmpty }.count) lines")
        // 2026-11-03 (owner, from the customer's review): "less is better". The setup's screen keeps to a word budget.
        expect(words(text) <= leaderWordBudget, "leader: at most \(leaderWordBudget) words, got \(words(text))")
        expect(run.keys == 2, "leader: two keys (y, enter), got \(run.keys)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0", "serve",
            "waitReady", "testRequest", "register", "waitReady", "pairServing"], "leader: operations in order: \(recorder.all)")
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
            // The restarted parts are awaited: registered, until the coordinator has the pair; refused, tested again, and
            // then not offered, which never ends with ✓ (the refactor pass's B1).
            let after = label == "registered" ? "pairServing" : "testRequest"
            expect(Array(recorder.all.suffix(4)) == ["testRequest", "register", "waitReady", after],
                   "\(label): the parts are awaited after the registration: \(recorder.all)")
            let done = text.range(of: startedLogs)?.lowerBound, restarted = text.range(of: restart)?.lowerBound
            if label == "registered" {
                expect(done != nil && restarted != nil && restarted! < done!, "\(label): Done comes after the parts serve again")
            } else {
                expect(done == nil && !text.contains("\u{2713} Serving") && text.contains("\u{2717} Not serving: not offered to Darkbloom ("),
                       "\(label): not offered, never ✓: \(text)")
            }
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
    /// at its end how the pair serves. A pair on that API is never offered, so it is local only whatever its scope (the
    /// DevNet traffic run, 2026-11-04: "earning through Darkbloom" followed the scope while the coordinator never had it).
    static func servingLineNamesTheMac() {
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000).summary(model: "Qwen3.5-9B")
            == "Serving Qwen3.5-9B at http://localhost:8000", "serving here")
        expect(ClusterOnboardingReady(servedBy: "the other Mac (Apple M3 Ultra, 256 GB)", port: 8100).summary(model: "Qwen3.5-9B")
            == "Serving Qwen3.5-9B at http://localhost:8100 on the other Mac", "serving there: that Mac said")
        let D = ClusterOnboardingDriver.self
        let notice = "Serving locally on this Mac's API; public serving needs a coordinator with cluster support"
        expect(D.servesWords(ready: .init(servedBy: "this Mac", port: 8000, notice: notice)) == " (local only)",
               "serves: a coordinator without cluster support serves locally")
        expect(D.servesWords(ready: .init(servedBy: "this Mac", port: 8000)) == " (local only)",
               "serves: the leader's API, never earning through Darkbloom")
        expect(D.servesWords(ready: .init(servedBy: "this Mac", port: 8000,
            notice: ClusterOnboardingReady.registeredNotice + " for m")) == " (local only)", "serves: a control-only member is not offered")
        expect(D.servesWords(ready: .init(servedBy: "this Mac", port: 8000, offered: "offered")) == "",
               "serves: offered for pairing says it itself")
        expect(!ClusterOnboardingDriver.servesWords(ready: .init(servedBy: "this Mac", port: 8000)).contains("earning"),
               "serves: no line earns without the coordinator having the pair")
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
        expect(text.contains("  Allow macOS permissions.\n"), "member: the approvals, word for word")
        // It follows the start (O8): what it waits for, the outcome, and whether the window may close, last.
        expect(text.contains("  " + ClusterOnboardingDriver.waitingForStartLine("Apple M5 Ultra, 256 GB") + "\n")
            && text.hasSuffix("  Test response in 0.61 s\n" + ClusterOnboardingDriver.resultRule + "\n" + ClusterOnboardingDriver.closeWindowLine + "\n"),
               "member: what it waits for, the outcome, and whether the window may close, last: \(text)")
        expect(!text.contains("Run `darkbloom cluster` on the other Mac."), "member: never told to run anything on another Mac")
        expect(!text.contains("Found the other Mac"), "member: finding the leader stays on the live line")
        expect(!text.contains("cluster local"), "member: no `local` line for a plain join")
        expect(visible(text).filter { !$0.isEmpty }.count <= memberLineBudget, "member: a short screen: \(visible(text).filter { !$0.isEmpty }.count) lines")
        expect(words(text) <= memberWordBudget, "member: at most \(memberWordBudget) words, got \(words(text))")
        expect(run.keys == 1, "member: one key (y)")
        expect(Array(recorder.all.prefix(4)) == ["checkLink", "pair", "answer y", "ensureService"]
            && recorder.all.dropFirst(4).allSatisfy { $0 == "status" || $0 == "testRequest" }, "member: operations \(recorder.all)")
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
    /// cluster as it is, the Mac it follows and the one thing to do there (2026-11-03, an end user: "Nothing to do here"
    /// did not say which Mac or what to type); its only choice is to start over (`startOverIsAlwaysOffered`), and enter
    /// leaves.
    static func memberAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "member again: Close or Start over")
        run.type("\r")
        expect(run.finish() == 0, "member again: enter leaves")
        let text = run.text
        expect(text.contains("This Mac follows \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) leads \u{00B7} cable ready\n"), "member again: who leads, in the opening")
        expect(!text.contains("derived") && !text.contains("term ") && !text.contains("rank 0"), "member again: no leadership jargon")
        expect(text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)\n"),
               "member again: the status as the outcome, with how it is split")
        expect(text.contains("\n" + ClusterOnboardingDriver.memberLeaderLine("Apple M3 Ultra, 256 GB") + "\n  1) Close\n  2) "
            + ClusterOnboardingDriver.startOverItem + "\n"), "member again: the Mac it follows, what to run there, then Close or Start over: \(text)")
        expect(!text.contains("Nothing to do here"), "member again: never the bare line")
        expect(!text.contains("Change model") && !text.contains("Choose a model"), "member again: no model choices")
        expect(recorder.all == ["ensureService", "status"], "member again: its service and the status only: \(recorder.all)")
        expect(run.keys == 1, "member again: one key (enter leaves)")
        transcript("member-again", text, keys: run.keys)
    }

    /// `darkbloom cluster` run again on a Mac already in a cluster (the leader or a member) opens with the same
    /// Darkbloom mark as the setup and the part this Mac plays, before anything else is said: the mark and the
    /// name on a colour UTF-8 terminal, the two heading lines in a plain transcript.
    static func resumedMacsOpenWithTheMark() {
        let D = ClusterOnboardingDriver.self
        let resumes: [(String, ClusterOnboardingResume, String)] = [
            ("member", memberResume(), "This Mac follows \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) leads"),
            ("leader", .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"), D.leaderSubtitle),
        ]
        for (label, resume, subtitle) in resumes {
            for colour in [true, false] {
                let recorder = Recorder()
                let environment = colour ? ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"]
                                         : ["NO_COLOR": "1"]
                let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([])),
                                      environment: environment)
                expect(run.waitFor(colour ? arrowHint : label == "leader" ? prompt(4) : prompt(2)), "\(label) again (\(colour ? "colour" : "plain")): the list")
                run.type("q")
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

    /// The leader's `darkbloom cluster`: the status, then the pair's models (2026-11-02: "a selectable interface ... like
    /// the normal Darkbloom models"), the serving one marked and taken with enter; q changes nothing.
    static func leaderAgainServing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(4)), "leader again: the list")
        expect(run.text.contains("  1) Qwen3.8-27B-4bit-mtp · 16.3 GB · pipeline · serving now\n"), "leader again: the serving model first, marked: \(run.text)")
        run.type("q")
        expect(run.finish() == 0, "leader again: q leaves")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "status"], "leader again: nothing changed: \(recorder.all)")
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
                                "register", "waitReady", "pairServing"], "copy: copied before the setup is synced: \(recorder.all)")
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
                                "testRequest", "register", "waitReady", "pairServing"], "download: downloaded, planned again, then adopted: \(recorder.all)")
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

    /// A model a Mac has no room for on disk now (only the space free now counts, not what macOS could purge) is
    /// listed after the ones that fit, its line saying so; chosen anyway, it says why and nothing is downloaded.
    static func modelWithoutRoomOnDiskIsMarked() {
        let recorder = Recorder()
        let short = "this Mac has 54.1 GB free; the model needs 172.9 GB and 2.1 GB to spare. macOS could free up to 202.5 GB more "
            + "(purgeable files such as local snapshots), but Darkbloom doesn't count on it"
        let choices = [
            ClusterOnboardingModelChoice(title: "Xiaomi: MiMo-V2.6-Flash", lines: ["172.9 GB · not on these Macs: downloaded from Darkbloom's catalog first"],
                blocker: nil, provision: .init(lines: ["This Mac: download from Darkbloom's catalog (172.9 GB) — cannot start: " + short],
                    downloadAlternative: false, leaderDownloads: true, blocker: short, fitsOnDisk: false), validated: true),
            ClusterOnboardingModelChoice(title: "Qwen 3.8 27B", lines: ["16.3 GB · tensor parallel"], blocker: nil, validated: true, split: "tensor parallel"),
            ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["15.6 GB · pipeline"], blocker: nil,
                fitRemedy: "Quit apps on the other Mac (Apple M5 Max, 128 GB) first.", validated: true, split: "pipeline")]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor(prompt(3)), "disk: the list")
        expect(run.text.contains("  1) Qwen 3.8 27B · 16.3 GB · tensor parallel\n  2) Gemma 4 26B · 15.6 GB · pipeline · does not fit now\n"
            + "  3) Xiaomi: MiMo-V2.6-Flash · 172.9 GB · download · not enough free disk\n"),
               "disk: the model without room comes last, its line says so: \(run.text)")
        run.type("3")
        expect(run.finish() == 1, "disk: exit 1")
        expect(run.text.contains("Can't start Xiaomi: MiMo-V2.6-Flash: " + short + ". Free space, then run `darkbloom cluster` again.\n"),
               "disk: why, with what macOS could purge: \(run.text)")
        expect(!run.text.contains("1) Download") && !recorder.all.contains { $0.hasPrefix("provision") || $0.hasPrefix("adopt") },
               "disk: no download offered or started: \(recorder.all)")
        transcript("leader-model-without-room-on-disk", run.text, keys: run.keys)

        // The same on a set-up pair's screen: the model serving now first, the one without room last with its marker,
        // then the scope line and Start over; chosen, it is refused before the switch question and nothing stops.
        var serving = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Max, 128 GB", serving: true, modelName: "Qwen 3.8 27B")
        serving.modelTitle = "Qwen 3.8 27B"
        let pairRecorder = Recorder()
        let pair = TerminalRun(operations(pairRecorder, resume: serving, pairEvents: [], pairResult: .failed([]), choices: choices))
        expect(pair.waitFor(prompt(5)), "disk, set-up pair: the list")
        expect(pair.text.contains("  1) Qwen 3.8 27B · 16.3 GB · tensor parallel · serving now\n  2) Gemma 4 26B · 15.6 GB · pipeline · does not fit now\n"
            + "  3) Xiaomi: MiMo-V2.6-Flash · 172.9 GB · download · not enough free disk\n  4) Switch to local only (this Mac's API, no Darkbloom traffic)\n"
            + "  5) Start over (unpair and set up again)\n"), "disk, set-up pair: last among the models, its line says so: \(pair.text)")
        pair.type("3")
        expect(pair.finish() == 1, "disk, set-up pair: exit 1")
        expect(pair.text.contains("Can't start Xiaomi: MiMo-V2.6-Flash: " + short + ". Free space, then run `darkbloom cluster` again.\n")
            && !pair.text.contains(ClusterOnboardingDriver.switchAnswers[0]), "disk, set-up pair: refused before the switch question: \(pair.text)")
        expect(!pairRecorder.all.contains { $0.hasPrefix("provision") || $0.hasPrefix("adopt") || $0 == "stop" },
               "disk, set-up pair: nothing downloaded or stopped: \(pairRecorder.all)")
        transcript("leader-pair-model-without-room-on-disk", pair.text, keys: pair.keys)
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
                                "register", "waitReady", "pairServing"], "short copy: copied before the setup is synced: \(recorder.all)")
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
        expect(D.choiceLine(size: "6.1 GB", mode: "pipeline_v1", shares: pipeline)
            == "6.1 GB · pipeline · M3 Ultra 40 layers / M5 Ultra 24 layers", "choice line: one line, no ranks, no speed")
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
        expect(!run.text.contains(startedLogs), "timeout: never Done")
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
        expect(run.text.contains("  Starts by itself at login on both Macs.\n  After a restart, this Mac serves again once someone logs in.\n"),
            "restart line: what happens after a restart, from the service's real state, in the card")
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

    /// R5-4 (M5 Ultra pair, 0.10.7 → 0.10.8): after the update the member started its part from the old setup six
    /// times ("Installed input identity or SHA-256 differs") until the leader synced the new one. A member whose
    /// worker is no longer the build its saved setup pins waits for the leader's setup instead, and says so; the
    /// leader, waiting for both Macs to run one build, asks again within seconds rather than a minute.
    static func memberWaitsForLeaderSetupAfterUpdate() {
        typealias U = ClusterOnboardingUpdate
        expect(U.memberWaitsForLeaderSetup(pinned: "aaaa", installed: "a2a2"), "member: the update changed this Mac's worker: wait")
        expect(!U.memberWaitsForLeaderSetup(pinned: "aaaa", installed: "aaaa"), "member: the setup pins this worker: start")
        expect(!U.memberWaitsForLeaderSetup(pinned: "aaaa", installed: nil),
               "member: an unreadable worker is no update; the part's own strict check says why it cannot start")
        expect(U.memberWaitLine(version: "0.10.9")
            == "this Mac runs Darkbloom v0.10.9, but its saved setup is for an earlier build: waiting for the other Mac's setup for v0.10.9 (the old setup is not started)",
            "member: the wait in plain words")
        expect(U.recheckWhileWaitingSeconds <= 5, "leader: both Macs on one build is checked again within seconds")
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
        expect(text.contains("  Switching to local only: the leading Mac's part starts again that way.\n")
            && !text.contains(ClusterServingScope.localOnly(bind: "0.0.0.0").line + ".\n"), "local switch: what it does, not the result before the outcome")
        // The same truth as the start: tested, then the outcome block.
        expect(text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp on this Mac's local API only", [localReady.apiLine, "Test response in 0.61 s"])),
               "local switch: ready again, local only: \(text)")
        expect(recorder.all == ["ensureService", "setScope local 0.0.0.0", "waitReady", "testRequest"], "local switch: \(recorder.all)")
        expect(run.keys == 0, "local switch: no key")
    }

    /// `darkbloom cluster local` when it already serves locally only: the ordinary list, whose scope line switches back.
    static func localAgainShowsTheMenu() {
        let recorder = Recorder()
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "0.0.0.0")
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([])), request: localRequest)
        expect(run.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "local again: the list offers the other way")
        run.type("q")
        expect(run.finish() == 0, "local again: q leaves it")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "status"], "local again: nothing changed: \(recorder.all)")
    }

    /// Plain `darkbloom cluster`: the list's scope line switches a serving cluster to local only and back; each waits for
    /// it to serve. Stopped, it saves the scope and starts the last model that way.
    static func menuKeysSwitchTheScope() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)))
        expect(run.waitFor("  3) Switch to local only (this Mac's API, no Darkbloom traffic)\n"), "menu: local only is offered")
        run.type("3")
        expect(run.finish() == 0, "menu local: exit 0")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "setScope local 0.0.0.0", "waitReady", "testRequest"], "menu local: \(recorder.all)")

        let back = Recorder()
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "0.0.0.0")
        let again = TerminalRun(operations(back, resume: resume, pairEvents: [], pairResult: .failed([])))
        expect(again.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "menu: through Darkbloom is offered when local only")
        again.type("3")
        expect(again.finish() == 0, "menu public: exit 0")
        // Planned again for Darkbloom and adopted, the scope saved after the adopt, then the start and its registration.
        expect(back.all == ["ensureService", "status", "reachMembers", "planModels", "reachMembers", "planModels", "recheckFit 0", "adopt 0",
                            "setScope public", "serve", "waitReady", "testRequest", "register", "waitReady", "pairServing"], "menu public: \(back.all)")
        expect(again.text.contains("\u{2713} Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)\n"), "menu public: the outcome")
        expect(!again.text.contains(ClusterServingScope.publicServing.line + ".\n")
            && again.text.contains("  " + ClusterOnboardingDriver.switchingToDarkbloomLine + "\n")
            && !again.text.contains("the leading Mac's part starts again that way"),
               "menu public: what it does, never the result before the outcome: \(again.text)")

        let stopped = Recorder()
        let idle = TerminalRun(operations(stopped, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([])))
        expect(idle.waitFor("  3) Switch to local only (this Mac's API, no Darkbloom traffic)\n"), "menu, stopped: local only is offered")
        idle.type("3")
        expect(idle.finish() == 0, "menu local, stopped: exit 0")
        expect(Array(stopped.all.prefix(5)) == ["ensureService", "status", "reachMembers", "planModels", "setScope local 0.0.0.0"]
            && stopped.all.contains("adopt 0") && stopped.all.contains("serve"), "menu local, stopped: saved, then the last model started: \(stopped.all)")
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
            expect(text.contains("\n" + ClusterOnboardingDriver.joinedLocalLine + "\n  " + ClusterOnboardingDriver.waitingForStartLine("Apple M5 Ultra, 256 GB") + "\n")
                && text.hasSuffix(ClusterOnboardingDriver.closeWindowLine + "\n"),
                   "\(label): one line for the other Mac, `local` in it, then the start followed: \(text)")
            expect(text.components(separatedBy: ClusterOnboardingDriver.joinedLocalLine).count == 2, "\(label): no second instruction for the other Mac")
            expect(!text.contains("3/4") && !text.contains("Choose a model") && !text.contains("Change model"),
                "\(label): no model list and no menu on the Mac that joined")
            expect(Array(recorder.all.prefix(4)) == ["checkLink", "pair", "answer y", "ensureService"]
                && !recorder.all.contains { $0.hasPrefix("adopt") || $0 == "serve" || $0.hasPrefix("setScope") },
                   "\(label): nothing started from the Mac that joined: \(recorder.all)")
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
        expect(D.choiceLine(size: "181.8 GB", mode: "tensor_parallel_v1", shares: tp) == "181.8 GB · tensor parallel · the other Mac 50% / this Mac 50%",
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
            "\u{2713} Serving Z.ai: GLM-5.3-Flash through Darkbloom on both Macs",
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
        // Registered is not serving: the summary of an offered ready never says Serving (`pairServingLine` does, once it serves).
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 0, offered: "offered for pairing", split: "pipeline").summary(model: "m")
               == "m (pipeline): offered for pairing", "ready: offered, the marker too, not Serving")
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

    /// The from-scratch screens' budgets (2026-11-03: about 70% fewer words than the 2026-11-02 screens, 293 and 148):
    /// a line that grows them back fails here. The 2026-11-03 call (Dylan) added the Start step's notice and the outcome
    /// block on the leader (21 to 25 lines, 100 to 125 words) and, on the member, where the other Mac's window shows
    /// the outcome (60 to 70 words). The 2026-11-04 brief added the fresh setup's opening on both Macs (what will be
    /// asked and how long it takes: two lines, 54 words): 27 lines and 180 words on the leader, 14 lines and 125 on the
    /// member. The owner's direction (2026-11-04, "make it similar to how normal darkbloom works") ends the leader's
    /// setup as `darkbloom start` does, with the pair's card and commands instead of "Done": 34 lines and 225 words.
    // A start through Darkbloom ends once the coordinator has the pair: the offered line and the restart add two lines
    // and 25 words. The owner's request (2026-11-04, "it should tell you that you need Screen Sharing access to go
    // through the approval prompts") adds 10 more words to the opening on the leader.
    static let leaderLineBudget = 36
    static let leaderWordBudget = 260
    /// The Mac that joined follows the start (O8): its waiting line and the outcome block are part of its screen.
    static let memberLineBudget = 20
    static let memberWordBudget = 150

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
        expect(run.waitFor(prompt(2)), "SSH: asked first whether to go on here"); run.type("2\r")
        expect(run.waitFor("  Allow macOS permissions here and on this Mac's screen (Screen Sharing if headless).\n"),
               "SSH: the approvals, where each is answered")
        expect(run.waitFor("  Click Allow on the Local Network prompt for sshd-keygen-wrapper on this Mac's screen (Screen Sharing if headless).\n"),
               "SSH: the prompt is on the Mac's screen, and the program macOS names")
        expect(run.waitFor("for sshd-keygen-wrapper on this Mac's screen (Screen Sharing if headless).\n  \u{2713} Allowed\n"), "SSH: allowed")
        _ = run.finish()
    }

    /// 2026-11-04 (owner): "When you run `darkbloom cluster` it should tell you that you need Screen Sharing access to go
    /// through the approval prompts." Both Macs say it in the opening, before 1/4, at 80 and 40 columns.
    static func bothMacsSayScreenSharingFirst() {
        typealias D = ClusterOnboardingDriver
        let opening = D.firstRunLines(localOnly: false).joined(separator: " ")
        expect(opening.contains("each Mac's own screen") && opening.contains("open Screen Sharing to it first")
            && opening.contains("password for the cable port") && opening.contains("Allow for Local Network")
            && opening.contains("Yes to the pairing code"), "screens: one list, with Screen Sharing: \(opening)")
        expect(!opening.contains("You'll be asked for this Mac's password"), "screens: the old list is gone, not doubled")
        for columns: UInt16 in [80, 40] {
            for (label, role, events) in [("leader", ClusterOnboardingRole.leader, leaderEvents), ("member", .member, memberEvents)] {
                let run = TerminalRun(operations(Recorder(), pairEvents: events, pairResult: .paired(role: role, peerName: "Apple M3 Ultra, 256 GB")),
                                      columns: columns)
                expect(run.waitFor(codeQuestion), "screens, \(label) at \(columns): the code"); run.type("y")
                if role == .leader { expect(run.waitFor(prompt(2), count: 2), "screens, leader at \(columns): the list"); run.type("\r") }
                _ = run.finish(seconds: 30)
                let text = run.text
                let before = text.components(separatedBy: "1/4 Connect").first ?? ""
                expect(before.contains("  " + D.firstRunLines(localOnly: false)[1] + "\n"),
                       "screens, \(label) at \(columns): Screen Sharing before 1/4: \(before)")
                expect(!text.contains(D.noPromptOverSSHLines()[0]), "screens, \(label) at \(columns): no SSH warning off SSH")
                transcript("screens-\(label)-\(columns)", text, keys: run.keys)
            }
        }
    }

    /// The first prompt on the other Mac (its cluster service's Local Network) names that Mac and the way in to it.
    static func otherMacPromptNamesItsScreen() {
        typealias D = ClusterOnboardingDriver
        expect(D.otherMacAllowLine("Apple M5 Ultra, 256 GB")
               == "Approve it on the other Mac's screen too (Apple M5 Ultra, 256 GB); use Screen Sharing if it has no display.",
               "other Mac: named: \(D.otherMacAllowLine("Apple M5 Ultra, 256 GB"))")
        expect(D.otherMacAllowLine(nil) == "Approve it on the other Mac's screen too; use Screen Sharing if it has no display.",
               "other Mac: unnamed")
        for (label, role, events) in [("member", ClusterOnboardingRole.member, memberEvents), ("leader", .leader, leaderEvents)] {
            let run = TerminalRun(operations(Recorder(), pairEvents: events, pairResult: .paired(role: role, peerName: "Apple M5 Ultra, 256 GB"),
                localNetwork: refusedThenAllowed(2, [.service])), columns: 80)
            expect(run.waitFor(codeQuestion), "other Mac, \(label): the code"); run.type("y")
            expect(run.waitFor("  " + D.localNetworkLine("Darkbloom") + " " + D.otherMacAllowLine("Apple M5 Ultra, 256 GB") + "\n", seconds: 20),
                   "other Mac, \(label): its screen, by name: \(run.text)")
            if role == .leader { expect(run.waitFor(prompt(2), count: 2), "other Mac, leader: the list"); run.type("\r") }
            _ = run.finish(seconds: 30)
            transcript("other-mac-\(label)", run.text, keys: run.keys)
        }
    }

    /// Over SSH with no desktop macOS cannot show its approval prompt: said before 1/4 at 80 and 40 columns, with where
    /// to run it instead; Quit (the default) ends with ✗ and that step, before anything is tried.
    static func sshSaysBeforeTryingWhereToRun() {
        typealias D = ClusterOnboardingDriver
        expect(D.noPromptOverSSHLines() == ["macOS can't show its approval prompt over SSH.",
                                            "Run `darkbloom cluster` in Terminal on this Mac's own screen, or through Screen Sharing."],
               "SSH: the words: \(D.noPromptOverSSHLines())")
        for columns: UInt16 in [80, 40] {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, pairEvents: [], pairResult: .failed([]), remote: true, commandApp: "sshd-keygen-wrapper"),
                                  columns: columns)
            expect(run.waitFor(prompt(2)), "SSH at \(columns): the choice"); run.type("\r")
            expect(run.finish() == 1, "SSH at \(columns): Quit ends with status 1")
            let text = run.text
            expect(text.contains(D.noPromptOverSSHLines().map { "  " + $0 + "\n" }.joined()), "SSH at \(columns): said: \(text)")
            expect(!text.contains("1/4 Connect") && !recorder.all.contains("checkLink"), "SSH at \(columns): nothing tried: \(recorder.all)")
            expect(text.hasSuffix(D.failed + " Nothing changed. " + D.noPromptOverSSHLines()[1] + "\n"), "SSH at \(columns): ✗ and the next step: \(text)")
            transcript("ssh-quit-\(columns)", text, keys: run.keys)
        }
    }

    /// A service that does not report its probe (an older build) still gets the prompt's line, as an "if".
    static func serviceThatCannotTellStillGetsTheAsk() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"),
            localNetwork: { $0 == .service ? .unknown : .allowed }))
        expect(run.waitFor(codeQuestion), "unknown: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 0, "unknown: the member's setup ends")
        expect(run.text.contains("  " + ClusterOnboardingDriver.localNetworkMaybeLine("Darkbloom") + " " + ClusterOnboardingDriver.otherMacAllowLine("Apple M5 Ultra, 256 GB") + "\n"),
               "unknown: the prompt's line as an if: \(run.text)")
        expect(run.text.contains(ClusterOnboardingDriver.waitingForStartLine("Apple M5 Ultra, 256 GB")), "unknown: nothing to wait for here")
    }

    /// The leader reads both Macs once paired; the other Mac's service may still wait for its Allow: a list to try
    /// again instead of an end (just paired, so no Pair again here; a Mac paired earlier offers it, see
    /// `reachWaitSaysWhyAndOffersPairAgain`).
    static func otherMacThatDidNotAnswerOffersTryAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            reachFailures: 1))
        expect(run.waitFor(codeQuestion), "try again: paired first"); run.type("y")
        expect(run.waitFor("The other Mac did not answer over the cable.\n"), "try again: what happened")
        expect(run.waitFor("1) Try again\n  2) Cancel\n"), "try again: the list")
        run.type("\r")
        expect(run.waitFor(prompt(2), count: 3), "try again: then the model list")
        run.type("\r")
        expect(run.finish() == 0, "try again: served")
        expect(recorder.all.filter { $0 == "reachMembers" }.count == 2, "try again: read twice: \(recorder.all)")
        expect(!run.text.contains(ClusterOnboardingDriver.pairAgainItem), "try again: just paired, no Pair again")
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

    /// The same where enter takes another option than the first (the member's list, a confirmation's No).
    static func prompt(_ count: Int, enter: Int) -> String { "Choose 1-\(count) (enter = \(enter)): " }

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
        expect(joined.text.hasSuffix(ClusterOnboardingDriver.resultRule + "\n" + ClusterOnboardingDriver.keepWindowLine + "\n"), "dev member: keep the window open")
        let leader = Recorder()
        var developmentLeader = operations(leader, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), outlivesWindow: false)
        // The other Mac runs the same build: its service doesn't start at login either (P2-11).
        developmentLeader.otherMacStartsAtLogin = { false }
        let led = TerminalRun(developmentLeader)
        expect(led.waitFor(prompt(2)), "dev leader: the list"); led.type("\r")
        expect(led.finish() == 0, "dev leader: exit 0")
        expect(led.text.contains("  Keep both windows open: this build's cluster service stops with them.\n"), "dev leader: keep both windows open")
    }

    /// The card's login line (P2-11): "on both Macs" only when this Mac's service outlives its window and the other Mac's
    /// status says its service starts at login; otherwise it names the Mac whose service doesn't, or says the other Mac
    /// doesn't say (an older build, or no answer). Pair-2's member, started from its window, reported false.
    static func theLoginLineNamesTheMacThatDoesNot() {
        let cases: [(outlives: Bool, other: Bool?, line: String)] = [
            (true, true, "Starts by itself at login on both Macs."),
            (true, false, "Starts by itself at login on this Mac, not on the other Mac."),
            (true, nil, "Starts by itself at login on this Mac; the other Mac doesn't say whether it does."),
            (false, true, "Keep this window open: this Mac's cluster service stops with it. On the other Mac it starts by itself at login."),
            (false, false, "Keep both windows open: this build's cluster service stops with them."),
            (false, nil, "Keep this window open: this Mac's cluster service stops with it. The other Mac doesn't say whether its service "
                + "starts at login."),
        ]
        for (outlives, other, line) in cases {
            let name = "login line (this Mac \(outlives), the other Mac \(other.map { "\($0)" } ?? "nil"))"
            let recorder = Recorder()
            var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
                                  pairResult: .failed([]), outlivesWindow: outlives)
            made.otherMacStartsAtLogin = { other }
            let run = TerminalRun(made)
            expect(run.waitFor(prompt(2)), "\(name): the list"); run.type("\r")
            expect(run.finish() == 0, "\(name): served")
            expect(run.text.contains("\n  " + line + "\n"), "\(name): the card says \(line)")
            expect(outlives && other == true || !run.text.contains("at login on both Macs"), "\(name): never at login on both Macs")
        }
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
        expect(run.waitFor("  Click Allow on the Local Network prompt for Darkbloom. " + ClusterOnboardingDriver.otherMacAllowLine("Apple M5 Ultra, 256 GB") + "\n"),
               "local network: Darkbloom's, once paired, the other Mac's said too")
        expect(run.finish(seconds: 20) == 0, "local network: member done")
        let text = run.text
        let order = ["1/4 Connect", "prompt for Terminal.\n  \u{2713} Allowed", "2/4 Pair", "Paired.",
                     "if it has no display.\n  \u{2713} Allowed", "Waiting for"].compactMap { text.range(of: $0)?.lowerBound }
        expect(order.count == 6 && order == order.sorted(), "local network: asked in order, each before the next step: \(text)")
        transcript("member-local-network-prompts", text, keys: run.keys)

        // Refused and left so: q stops with where to turn it on.
        let blocked = TerminalRun(operations(Recorder(), pairEvents: [], pairResult: .failed([]), localNetwork: { _ in .blocked }))
        expect(blocked.waitFor("Click Allow"), "refused: the prompt line")
        blocked.type("q")
        expect(blocked.finish() == 1, "refused: stops")
        expect(blocked.text.hasSuffix("(on a Mac with no display, through Screen Sharing), then run `darkbloom cluster` again.\n")
               && blocked.text.contains("On this Mac: System Settings → Privacy & Security → Local Network → turn on “"),
               "refused: where to turn it on, plainly, last")
    }

    /// `darkbloom cluster local` on a member: it takes effect on the Mac that leads, so the screen says so and nothing runs.
    static func memberLocalPointsToTheLeader() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([])), request: localRequest)
        expect(run.finish() == 1, "member local: exit 1")
        expect(run.text.hasSuffix(ClusterOnboardingDriver.joinedLocalLine + "\n"), "member local: where to run it")
        expect(recorder.all == ["ensureService", "status"], "member local: nothing changed: \(recorder.all)")
    }

    /// The leader's list moved with the arrows: ↓ twice then enter takes the third line (the scope), the list folds to it.
    static func arrowKeysTakeAMenuItem() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)),
            environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", "DARKBLOOM_NO_ANIMATION": "1"])
        expect(run.waitFor(arrowHint), "arrows: the list")
        run.type("\u{1B}[B")
        expect(run.waitFor("\u{25B8}\u{1B}[0m \u{1B}[1mZ.ai: GLM-5.3-Flash", seconds: 5), "arrows: ↓ moves the ▸ to the second line")
        run.type("\u{1B}[B")
        expect(run.waitFor("\u{25B8}\u{1B}[0m \u{1B}[1mSwitch to local only", seconds: 5), "arrows: and on to the third")
        run.type("\r")
        expect(run.finish() == 0, "arrows: exit 0")
        expect(visible(run.text).contains { $0.hasPrefix("  \u{25B8} Switch to local only") }, "arrows: the list folds to the line taken")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "setScope local 0.0.0.0", "waitReady", "testRequest"],
               "arrows: the third line ran: \(recorder.all)")
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
            ("member", memberResume(), "Studio B", "This Mac (Studio B) follows \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) leads"),
            ("unsayable", ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
             "Studio\u{07}", D.leaderSubtitle)] {
            let run = TerminalRun(operations(Recorder(), resume: resume, pairEvents: [], pairResult: .failed([]), thisMacName: name))
            expect(run.waitFor(resume.role == .leader ? prompt(4) : prompt(2)), "names (\(label) again): the list"); run.type("q")
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

    // MARK: - Already paired Macs whose pairing cannot be used (2026-11-03)

    /// The leader's status as Mac A's screen showed it on 2026-11-03 21:26Z, while its pairing was the production app's
    /// and its part looped "This Mac's Secure Enclave key is not the one it paired with; pair again".
    static let stoppedLocalStatus = ["Stopped; last model EigenLabs/Qwen3.8-27B-4bit-mtp.",
                                     "When it starts: Local only, on this Mac only (127.0.0.1); API key: `darkbloom local`."]

    /// S1: the pairing was made with another Secure Enclave key (the other app's, or the one before a reinstall). The
    /// leader's screen says so in one sentence and offers Pair again, which unpairs this Mac and runs the ordinary
    /// pairing, code on both screens, then the model choice; the usual menu (which served nothing) is not shown.
    static func keyChangedLeaderPairsAgain() {
        let recorder = Recorder()
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false,
                                             modelName: "EigenLabs/Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "127.0.0.1")
        resume.pairingProblem = .keyChanged
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: leaderEvents,
            pairResult: .paired(role: .leader, peerName: "Apple M5 Ultra, 256 GB"), statusLines: stoppedLocalStatus))
        expect(run.waitFor(prompt(2)), "key changed (leader): a list")
        let asked = run.text
        expect(asked.contains("This Mac leads\n  " + ClusterOnboardingPairingProblem.keyChanged.line + "\n\n  1) "
            + ClusterOnboardingDriver.pairAgainItem + "\n  2) Quit\n"), "key changed (leader): why, then Pair again or Quit: \(asked)")
        expect(!asked.contains("Choose a model") && !asked.contains("Check memory is freed"), "key changed (leader): not the usual menu")
        run.type("\r")
        expect(run.waitFor(codeQuestion), "key changed (leader): the ordinary pairing follows")
        run.type("y")
        expect(run.waitFor(prompt(2), count: 3), "key changed (leader): then the model list")
        run.type("\r")
        expect(run.finish() == 0, "key changed (leader): served")
        let text = run.text
        for line in ["  \u{2713} Unpaired this Mac.\n  " + ClusterOnboardingDriver.otherMacPairAgainLine + "\n",
                     "\n1/4 Connect\n", "  Run `darkbloom cluster` on the other Mac.\n", "  \u{2713} Paired. This Mac leads.\n"] {
            expect(text.contains(line), "key changed (leader): \(line)")
        }
        expect(text.components(separatedBy: ClusterOnboardingDriver.title).count == 2, "key changed (leader): one opening")
        expect(recorder.all == ["unpair", "checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0",
            "adopt 0", "serve", "waitReady", "testRequest", "register", "waitReady", "pairServing"], "key changed (leader): unpair, then pair and serve: \(recorder.all)")
        transcript("leader-key-changed-pairs-again", text, keys: run.keys)
    }

    /// S1 on the Mac that follows: the same sentence and Pair again instead of its usual screen; it then joins the
    /// other Mac's pairing as a Mac with no pairing does.
    static func keyChangedMemberPairsAgain() {
        let recorder = Recorder()
        var resume = memberResume()
        resume.pairingProblem = .keyChanged
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        expect(run.waitFor(prompt(2)), "key changed (member): a list")
        expect(run.text.contains("This Mac follows the other Mac\n  " + ClusterOnboardingPairingProblem.keyChanged.line + "\n"),
               "key changed (member): why, under the opening: \(run.text)")
        run.type("\r")
        expect(run.waitFor(codeQuestion), "key changed (member): the ordinary pairing follows")
        run.type("y")
        expect(run.finish() == 0, "key changed (member): joined")
        let text = run.text
        expect(!text.contains("Nothing to do here"), "key changed (member): never Nothing to do here")
        expect(text.contains("  \u{2713} Paired. The other Mac leads.\n")
            && text.contains("  " + ClusterOnboardingDriver.waitingForStartLine("Apple M5 Ultra, 256 GB") + "\n")
            && text.hasSuffix(ClusterOnboardingDriver.closeWindowLine + "\n"),
               "key changed (member): joined, and the start followed: \(text)")
        expect(Array(recorder.all.prefix(5)) == ["unpair", "checkLink", "pair", "answer y", "ensureService"], "key changed (member): \(recorder.all)")
        transcript("member-key-changed-pairs-again", text, keys: run.keys)
    }

    /// Quit leaves everything as it was: nothing unpaired, no service started.
    static func keyChangedQuitChangesNothing() {
        let recorder = Recorder()
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.pairingProblem = .keyChanged
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "key changed, quit: the list")
        run.type("2")
        expect(run.finish() == 0, "key changed, quit: exit 0")
        expect(recorder.all.isEmpty, "key changed, quit: nothing ran: \(recorder.all)")
    }

    /// S2 on the Mac that follows: the leader does not answer over the cable with this pairing (2026-11-03: one Mac
    /// of a pair showed its opening and "Nothing to do here" while the other waited at Pair). The member names the
    /// other Mac, its likely reasons and what to run there, and offers Try again, Start over or Quit (UX audit P3:
    /// silence is no broken pairing, so Start over asks first); Start over unpairs it and joins the waiting Mac; Try
    /// again asks again.
    static func memberWhoseLeaderIsSilentPairsAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), otherMacAnswers: [false]))
        expect(run.waitFor(prompt(3)), "silent leader: a list")
        let asked = run.text
        expect(asked.contains("This Mac follows \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) leads\n  " + silentLine("Apple M3 Ultra, 256 GB")
            + "\n\n  1) Try again\n  2) " + ClusterOnboardingDriver.startOverItem + "\n  3) Quit\n"), "silent leader: why, then the three choices: \(asked)")
        run.type("2")
        expect(run.waitFor(ClusterOnboardingDriver.startOverQuestion), "silent leader: Start over asks first")
        run.type("y")
        expect(run.waitFor(codeQuestion), "silent leader: the ordinary pairing follows")
        run.type("y")
        expect(run.finish() == 0, "silent leader: joined")
        let text = run.text
        expect(!text.contains("Nothing to do here"), "silent leader: never Nothing to do here")
        expect(text.contains("  \u{2713} Paired. The other Mac leads.\n"), "silent leader: paired again")
        expect(Array(recorder.all.prefix(6)) == ["ensureService", "unpair", "checkLink", "pair", "answer y", "ensureService"]
            && recorder.all.dropFirst(6).allSatisfy { $0 == "status" || $0 == "testRequest" }, "silent leader: then the start followed: \(recorder.all)")
        transcript("member-silent-leader-pairs-again", text, keys: run.keys)

        // The leader was only asleep: Try again asks once more, then the screen is the member's usual one.
        let again = Recorder()
        let woke = TerminalRun(operations(again, resume: memberResume(), pairEvents: [], pairResult: .failed([]), otherMacAnswers: [false, true]))
        expect(woke.waitFor(prompt(3)), "silent leader, try again: the list")
        woke.type("1")
        expect(woke.waitFor(prompt(2)), "silent leader, try again: then the usual screen")
        woke.type("\r")
        expect(woke.finish() == 0, "silent leader, try again: enter leaves")
        expect(woke.text.contains(ClusterOnboardingDriver.memberLeaderLine("Apple M3 Ultra, 256 GB") + "\n"), "silent leader, try again: the usual screen: \(woke.text)")
        expect(again.all == ["ensureService", "status"] && again.probes == 2, "silent leader, try again: asked twice, nothing unpaired: \(again.all)")
    }

    /// S2 on the Mac that leads: its other Mac does not answer over the cable. The screen names that Mac, its likely
    /// reasons and what to run there, and offers Try again, Start over (which asks first) or Quit (UX audit P3), also
    /// for a leader that never chose a model (which otherwise goes straight to the list and waits two minutes for the
    /// other Mac).
    static func leaderWhoseMemberIsSilentOffersStartOver() {
        let recorder = Recorder()
        var stopped = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: false, modelName: "EigenLabs/Qwen3.8-27B-4bit-mtp")
        stopped.scope = .localOnly(bind: "127.0.0.1")
        let run = TerminalRun(operations(recorder, resume: stopped, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M5 Max, 128 GB"),
            otherMacAnswers: [false], statusLines: stoppedLocalStatus))
        expect(run.waitFor(prompt(3)), "silent member: the choices")
        let menu = run.text
        expect(menu.contains("  " + stoppedLocalStatus[1] + "\n  " + silentLine("Apple M5 Ultra, 256 GB") + "\n\n  1) Try again\n  2) "
            + ClusterOnboardingDriver.startOverItem + "\n  3) Quit\n"), "silent member: the status, why, then Try again, Start over or Quit: \(menu)")
        run.type("2")
        expect(run.waitFor(ClusterOnboardingDriver.startOverQuestion), "silent member: Start over asks first")
        run.type("y")
        expect(run.waitFor(codeQuestion), "silent member: the ordinary pairing follows")
        run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "silent member: then the model list")
        run.type("\r")
        expect(run.finish() == 0, "silent member: served")
        expect(Array(recorder.all.prefix(4)) == ["ensureService", "status", "unpair", "checkLink"], "silent member: unpaired, then paired: \(recorder.all)")
        expect(recorder.probes == 1, "silent member: asked once (never right after pairing)")
        transcript("leader-silent-member-pairs-again", run.text, keys: run.keys)

        // A leader that never chose a model: the menu too, not two minutes of "Reading both Macs".
        let unchosen = Recorder()
        let fresh = TerminalRun(operations(unchosen, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), otherMacAnswers: [false]))
        expect(fresh.waitFor(prompt(3)), "silent member, no model yet: the choices")
        expect(fresh.text.contains("\n  1) Try again\n  2) " + ClusterOnboardingDriver.startOverItem + "\n  3) Quit\n"),
               "silent member, no model yet: Start over: \(fresh.text)")
        fresh.type("3")
        expect(fresh.finish() == 0, "silent member, no model yet: quit")
        expect(!unchosen.all.contains("reachMembers") && !unchosen.all.contains("unpair"), "silent member, no model yet: nothing read or unpaired: \(unchosen.all)")
    }

    /// A pair whose other Mac answers keeps its usual screens: the member's status and the Mac it follows, the leader's
    /// menu without Pair again; each asks the other Mac once, and a cable on a port that is not set up is the one
    /// thing said (the other Mac cannot answer there, which is no reason to pair again).
    static func answeringOtherMacKeepsTheScreens() {
        let member = Recorder()
        let followed = TerminalRun(operations(member, resume: memberResume(), pairEvents: [], pairResult: .failed([])))
        expect(followed.waitFor(prompt(2)), "answers (member): its list")
        followed.type("\r")
        expect(followed.finish() == 0 && followed.text.contains(ClusterOnboardingDriver.memberLeaderLine("Apple M3 Ultra, 256 GB")), "answers (member): as before")
        expect(member.probes == 1 && !followed.text.contains("  1) " + ClusterOnboardingDriver.pairAgainItem), "answers (member): asked once, no Pair again")
        let leader = Recorder()
        let led = TerminalRun(operations(leader, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true,
            modelName: "Qwen3.8-27B-4bit-mtp"), pairEvents: [], pairResult: .failed([])))
        expect(led.waitFor(prompt(4)), "answers (leader): the usual list")
        expect(!led.text.contains(") " + ClusterOnboardingDriver.pairAgainItem + "\n") && leader.probes == 1, "answers (leader): no Pair again, asked once")
        led.type("q")
        _ = led.finish()
        var moved = memberResume()
        moved.unsetCablePort = "Thunderbolt 1 (en1)"
        let port = Recorder()
        let cable = TerminalRun(operations(port, resume: moved, pairEvents: [], pairResult: .failed([]), otherMacAnswers: [false]))
        expect(cable.waitFor(prompt(2)), "unset port: its list")
        expect(!cable.text.contains(ClusterOnboardingDriver.pairAgainItem) && port.probes == 0, "unset port: no Pair again, nothing asked: \(cable.text)")
        cable.type("2")
        _ = cable.finish()
    }

    // MARK: - The owner's second pair and an end user's live session (2026-11-03)

    /// S4 (pair 2, G2: "3/4 Model hangs forever with an unreachable partner", 0% CPU, no child, no log, no message): a
    /// Mac paired earlier whose other Mac stops answering after the menu says each reason it keeps waiting, then the
    /// plain failure, then Try again, Start over (which asks first: UX audit P3) or Quit.
    static func reachWaitSaysWhyAndOffersStartOver() {
        let waiting = "Waiting for the other Mac's cluster service: the other Mac's cluster service did not answer on the cable"
        let failed = ["The other Mac (Apple M3 Ultra, 256 GB) did not answer over the cable within 2 minutes: the other Mac's cluster service did not answer on the cable"]
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false,
            modelName: "Qwen3.8-27B-4bit-mtp"), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            reachFailures: 1, reachWaiting: [waiting, waiting], reachFailure: failed))
        expect(run.waitFor(prompt(3)), "reach: a list once the wait ends")
        let asked = run.text
        expect(asked.contains("\nModel\n  " + waiting + "\n" + failed[0] + "\n  1) Try again\n  2) " + ClusterOnboardingDriver.startOverItem
            + "\n  3) Quit\n"), "reach: the reason it waits (once), the plain failure, then the three choices: \(asked)")
        expect(!asked.contains(") " + ClusterOnboardingDriver.pairAgainItem + "\n"), "reach: never Pair again")
        run.type("2")
        expect(run.waitFor(ClusterOnboardingDriver.startOverQuestion), "reach: Start over asks first")
        run.type("y")
        expect(run.waitFor(codeQuestion), "reach: Start over pairs")
        run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "reach: then the model list")
        run.type("\r")
        expect(run.finish() == 0, "reach: served")
        expect(Array(recorder.all.prefix(5)) == ["ensureService", "status", "reachMembers", "unpair", "checkLink"], "reach: \(recorder.all)")
        transcript("leader-reach-wait-pairs-again", run.text, keys: run.keys)

        // Quit ends with the one thing to do, nothing changed.
        let quit = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false,
            modelName: "Qwen3.8-27B-4bit-mtp"), pairEvents: [], pairResult: .failed([]), reachFailures: 9, reachFailure: failed))
        expect(quit.waitFor(prompt(3)), "reach, quit: the list"); quit.type("3")
        expect(quit.finish() == 1, "reach, quit: exit 1")
        expect(quit.text.hasSuffix("Nothing changed. Run `darkbloom cluster` again when the other Mac is on.\n"), "reach, quit: what to do: \(quit.text)")
    }

    /// End user, 2026-11-03 (a): `darkbloom cluster` on a paired Mac whose cable port had been removed set the port up
    /// ("Cable port set up. The Macs reconnect by themselves.") and ended ("there's no intuition what to do now"). The
    /// same run now goes on to the Mac's screen: the member's next step, the leader's list.
    static func cableStepContinuesToTheNextStep() {
        var moved = memberResume()
        moved.unsetCablePort = "Thunderbolt 3 (en2)"
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: moved, pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "cable (member): its list")
        run.type("\r")
        expect(run.waitFor(prompt(2), count: 2), "cable (member): the run goes on to the next step")
        run.type("\r")
        expect(run.finish() == 0, "cable (member): enter leaves")
        let text = run.text
        // The status is the member's outcome block (`showOutcome`).
        let order = ["The cable is on Thunderbolt 3 (en2), which isn't set up.", "\u{2713} Cable port set up. The Macs reconnect by themselves.",
                     "\u{2713} Serving Qwen3.8-27B-4bit-mtp", ClusterOnboardingDriver.memberLeaderLine("Apple M3 Ultra, 256 GB")].compactMap { text.range(of: $0)?.lowerBound }
        expect(order.count == 4 && order == order.sorted(), "cable (member): the port, then the status and the next step: \(text)")
        expect(recorder.all == ["ensureService", "checkLink", "status"] && recorder.probes == 1,
               "cable (member): set up, then asked the other Mac: \(recorder.all), \(recorder.probes)")
        transcript("member-cable-then-next-step", text, keys: run.keys)

        var stopped = ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false, modelName: "Qwen3.8-27B-4bit-mtp")
        stopped.unsetCablePort = "Thunderbolt 3 (en2)"
        let leader = Recorder()
        let led = TerminalRun(operations(leader, resume: stopped, pairEvents: [], pairResult: .failed([])))
        expect(led.waitFor(prompt(2)), "cable (leader): the port first")
        led.type("1")
        expect(led.waitFor(prompt(4)), "cable (leader): then the list")
        led.type("q")
        expect(led.finish() == 0, "cable (leader): quit")
        expect(led.text.contains("\u{2713} Cable port set up. The Macs reconnect by themselves.\n"), "cable (leader): set up")
        expect(leader.all == ["ensureService", "status", "checkLink", "reachMembers", "planModels", "status"], "cable (leader): \(leader.all)")
    }

    /// End user, 2026-11-03 (b): on the Mac that follows, "Nothing to do here, manage it on the other Mac" said neither
    /// which Mac nor what to type. It names the Mac it follows (the name pairing showed) and the command to run there.
    static func memberNamesItsLeaderAndTheNextStep() {
        expect(ClusterOnboardingDriver.memberLeaderLine("Apple M3 Ultra, 256 GB") == "To change the model, run `darkbloom cluster` or `darkbloom start` "
            + "on the other Mac (Apple M3 Ultra, 256 GB). `darkbloom stop` here stops both Macs.", "member line: word for word")
        expect(ClusterOnboardingDriver.memberLeaderLine(nil) == "To change the model, run `darkbloom cluster` or `darkbloom start` on the other Mac. "
            + "`darkbloom stop` here stops both Macs.", "member line: no name known")
        var unnamed = memberResume()
        unnamed.leaderName = nil
        unnamed.peerName = "Apple M5 Max, 128 GB"
        let run = TerminalRun(operations(Recorder(), resume: unnamed, pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor(prompt(2)), "member line: the list"); run.type("\r")
        expect(run.finish() == 0, "member line: leaves")
        expect(run.text.contains(ClusterOnboardingDriver.memberLeaderLine("Apple M5 Max, 128 GB") + "\n"),
               "member line: without a leader's name, the paired Mac's: \(run.text)")
    }

    /// End user, 2026-11-03 (c): starting from scratch took wiping the config by hand. Every paired Mac whose pairing
    /// works offers Start over with one confirmation, No by default: the leader under its models,
    /// the member as its one choice. It unpairs as Pair again does, then pairs. A fresh setup is unchanged.
    static func startOverIsAlwaysOfferedWithOneConfirmation() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: memberEvents,
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        expect(run.waitFor(prompt(2)), "start over (member): the list")
        run.type("2")
        expect(run.waitFor("  " + ClusterOnboardingDriver.startOverQuestion + "\n  1) " + ClusterOnboardingDriver.startOverAnswers[0]
            + "\n  2) No\n"), "start over (member): one confirmation: \(run.text)")
        run.type("y")
        expect(run.waitFor(codeQuestion), "start over (member): the ordinary pairing")
        run.type("y")
        expect(run.finish() == 0, "start over (member): joined")
        expect(Array(recorder.all.prefix(7)) == ["ensureService", "status", "unpair", "checkLink", "pair", "answer y", "ensureService"]
            && recorder.all.dropFirst(7).allSatisfy { $0 == "status" || $0 == "testRequest" }, "start over (member): then the start followed: \(recorder.all)")
        transcript("member-start-over", run.text, keys: run.keys)

        // Enter at the confirmation is No: nothing unpaired.
        let kept = Recorder()
        let no = TerminalRun(operations(kept, resume: memberResume(), pairEvents: [], pairResult: .failed([])))
        expect(no.waitFor(prompt(2)), "start over, no: the list"); no.type("2")
        expect(no.waitFor(ClusterOnboardingDriver.startOverAnswers[0]), "start over, no: asked"); no.type("\r")
        expect(no.finish() == 0, "start over, no: exit 0")
        expect(no.text.hasSuffix("Nothing changed.\n") && !kept.all.contains("unpair"), "start over, no: nothing changed: \(no.text)")

        // The leader: before Quit in its list, the same confirmation, then the pairing and the model.
        let leader = Recorder()
        let led = TerminalRun(operations(leader, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true,
            modelName: "Qwen3.8-27B-4bit-mtp"), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(led.waitFor(prompt(4)), "start over (leader): the list"); led.type("4")
        expect(led.waitFor(ClusterOnboardingDriver.startOverQuestion), "start over (leader): asked"); led.type("y")
        expect(led.waitFor(codeQuestion), "start over (leader): pairs"); led.type("y")
        expect(led.waitFor(prompt(2), count: 2), "start over (leader): then the model list"); led.type("\r")
        expect(led.finish() == 0, "start over (leader): served")
        expect(Array(leader.all.prefix(6)) == ["ensureService", "status", "reachMembers", "planModels", "unpair", "checkLink"], "start over (leader): \(leader.all)")

        // A Mac whose pairing cannot be used is offered Pair again instead (no second item, no confirmation).
        var changed = memberResume()
        changed.pairingProblem = .keyChanged
        let broken = TerminalRun(operations(Recorder(), resume: changed, pairEvents: [], pairResult: .failed([])))
        expect(broken.waitFor(prompt(2)), "start over, broken pairing: Pair again's list"); broken.type("2")
        _ = broken.finish()
        expect(!broken.text.contains(ClusterOnboardingDriver.startOverItem), "start over, broken pairing: not offered twice")
        // A fresh setup has no pairing to start over from.
        let fresh = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(fresh.waitFor(codeQuestion), "start over, fresh: pairing as before"); fresh.type("y")
        expect(fresh.waitFor(prompt(2), count: 2), "start over, fresh: the model list"); fresh.type("\r")
        _ = fresh.finish()
        expect(!fresh.text.contains(ClusterOnboardingDriver.startOverItem), "start over, fresh: not offered")
    }

    /// An unpairing that fails says why and starts no pairing.
    static func failedUnpairStopsBeforePairing() {
        let recorder = Recorder()
        var resume = memberResume()
        resume.pairingProblem = .keyChanged
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([]),
            unpairResult: .failure(.init("The pairing store could not be written."))))
        expect(run.waitFor(prompt(2)), "failed unpair: the list")
        run.type("\r")
        expect(run.finish() == 1, "failed unpair: exit 1")
        expect(run.text.contains("The pairing store could not be written.\n"), "failed unpair: why")
        expect(recorder.all == ["unpair"], "failed unpair: no pairing: \(recorder.all)")
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

    // MARK: - Single-Mac serving blocks the pair

    static let soloBoth = [ClusterOnboardingSoloServing(mac: "this Mac", pid: 9523),
                           ClusterOnboardingSoloServing(mac: "the other Mac (Apple M4 Max, 128 GB)", pid: 2282)]
    static let soloBothTitle = "\u{2717} The pair can't start: a single-Mac Darkbloom provider (process 9523) is serving on this Mac and "
        + "a single-Mac Darkbloom provider (process 2282) is serving on the other Mac (Apple M4 Max, 128 GB), and the pair can't "
        + "share a Mac with it."

    /// The scripted held lock: single-Mac serving on `serving` until `stopSoloServing` runs, then none.
    static func soloOperations(_ recorder: Recorder, serving: [ClusterOnboardingSoloServing], stopWorks: Bool = true,
                               readyResults: [Result<ClusterOnboardingReady, ClusterOnboardingFailure>]? = nil) -> ClusterOnboardingOperations {
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M4 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
                              readyResults: readyResults)
        made.soloServing = {
            recorder.note("soloServing")
            return stopWorks && recorder.all.contains("stopSoloServing") ? [] : serving
        }
        made.stopSoloServing = {
            recorder.note("stopSoloServing")
            return stopWorks ? .success(["\u{2713} Stopped single-Mac serving on this Mac.", "\u{2713} Stopped single-Mac serving on the other Mac."])
                : .failure(.init("The other Mac did not answer over the cable."))
        }
        return made
    }

    static let p2Max = ClusterOnboardingSoloServing(mac: "the other Mac (Apple M5 Max, 128 GB)", pid: 68099)
    /// The leading Mac's status line while the joining Mac's single-Mac provider blocks the pair (its `localStatus`).
    static let leaderBlockedStatus = [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: ClusterOnboardingSoloServing.title([p2Max]))]
        + ClusterOnboardingSoloServing.remedies([p2Max])
    static let joiningBlockTitle = "\u{2717} The pair can't start: a single-Mac Darkbloom provider (process 68099) is serving on this Mac, "
        + "and the pair can't share a Mac with it."

    /// The joining Mac, its single-Mac provider seen by its own probe for `blockedLooks` looks (all of them when nil).
    static func joiningSolo(_ recorder: Recorder, statusSequence: [[String]], blockedLooks: Int? = nil) -> TerminalRun {
        var made = operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName),
                              pairServingResults: [.failure(.init("Waiting for the coordinator to pair both Macs."))],
                              statusSequence: statusSequence, followSeconds: 900)
        let looks = Recorder()
        made.soloServing = {
            looks.note("look")
            let seen = looks.all.count
            return blockedLooks.map { seen > $0 } == true ? [] : [.init(mac: "this Mac", pid: 68099)]
        }
        return TerminalRun(made)
    }

    static func soloServingOnTheJoiningMacIsSaidOnBothScreens() {
        // The leading Mac: the block, named for the other Mac, with the stop offered.
        let leading = TerminalRun(soloOperations(Recorder(), serving: [p2Max]))
        expect(leading.waitFor(prompt(2)), "f1 leader: choice"); leading.type("\r")
        expect(leading.waitFor("  2) Leave\n"), "f1 leader: the offer: \(leading.text)"); leading.type("2")
        expect(leading.finish() == 1, "f1 leader: exit 1")
        expect(leading.text.contains("\u{2717} The pair can't start: a single-Mac Darkbloom provider (process 68099) is serving on the other "
               + "Mac (Apple M5 Max, 128 GB), and the pair can't share a Mac with it.\n"), "f1 leader: the ✗: \(leading.text)")
        // The joining Mac: the same ✗, naming its own provider, never a wait for the coordinator.
        let recorder = Recorder()
        let run = joiningSolo(recorder, statusSequence: [["Stopped."], ["Starting Qwen 3.8 27B."], leaderBlockedStatus])
        expect(run.waitFor(codeQuestion), "f1 joining: the code"); run.type("y")
        expect(run.waitFor(ClusterOnboardingSoloServing.leaderOffersLine(leaderName)), "f1 joining: the block: \(run.text)")
        usleep(400_000)
        run.type("q")
        expect(run.finish(seconds: 20) == 0, "f1 joining: q leaves")
        let text = run.text
        expect(text.contains(joiningBlockTitle + "\n"), "f1 joining: the ✗ names this Mac's provider: \(text)")
        expect(text.contains("On this Mac: run `darkbloom stop --solo` to stop single-Mac serving there."), "f1 joining: the command")
        expect(text.contains("Or choose \"Stop single-Mac serving … and start the pair\" on the other Mac (Apple M5 Ultra, 256 GB)"),
               "f1 joining: the leader offers the stop")
        expect(!text.contains("Offered to Darkbloom") && !text.contains("registering with the coordinator")
               && !recorder.all.contains("pairServing"), "f1 joining: never a wait for the coordinator: \(recorder.all)")
        expect(text.components(separatedBy: joiningBlockTitle).count == 2, "f1 joining: said once")
        expect(ClusterOnboardingDriver.followed(leaderBlockedStatus) == .soloBlocked, "f1: the leader's block line is the block, not an offer")
        transcript("member-solo-block", text, keys: run.keys)
    }

    static func theJoiningMacFollowsTheStartOnceSingleMacServingStops() {
        let recorder = Recorder()
        let run = joiningSolo(recorder, statusSequence: [["Stopped."]] + Array(repeating: leaderBlockedStatus, count: 3)
                                  + [["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [localServingLine, leadersTestLine]], blockedLooks: 3)
        expect(run.waitFor(codeQuestion), "f1 cleared: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 0, "f1 cleared: served once it stopped: \(run.text)")
        let text = run.text
        expect(text.contains(joiningBlockTitle) && text.contains("  " + ClusterOnboardingSoloServing.followClearedLine + "\n")
               && text.contains("\u{2713} Serving Qwen 3.8 27B"), "f1 cleared: the block, then the start, then ✓: \(text)")
    }

    /// Build C (P2): a stopped pair serving locally, switched to Darkbloom from the list's scope line, starts its last model
    /// in the mode it served in (tensor parallel), never the planner's recommendation (pipeline).
    static func stoppedLocalPairSwitchedToDarkbloomKeepsItsMode() {
        var resume = gemmaStopped
        resume.scope = .localOnly(bind: "0.0.0.0")
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            statusLines: ["Stopped; last model Gemma 4 26B."]))
        expect(run.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "P2: the scope line: \(run.text)"); run.type("3")
        _ = run.finish(seconds: 30)
        let modes = recorder.all.filter { $0.hasPrefix("useMode") }
        expect(modes == ["useMode 1 tensor_parallel_v1"], "P2: the mode it served in: \(recorder.all)")
    }

    static func theJoiningMacOnAStoppedPairSaysTheBlock() {
        let recorder = Recorder()
        var made = operations(recorder, resume: memberResume(serving: false), pairEvents: [], pairResult: .failed([]),
                              statusLines: ["Stopped; last model Gemma 4 26B."])
        made.soloServing = { recorder.note("soloServing"); return [.init(mac: "this Mac", pid: 29049)] }
        let run = TerminalRun(made)
        expect(run.finish() == 1, "R8-1 joining: not a quiet Close: \(run.text)")
        let text = run.text
        expect(text.contains("\u{2717} The pair can't start: a single-Mac Darkbloom provider (process 29049) is serving on this Mac, and the "
               + "pair can't share a Mac with it.\n"), "R8-1 joining: the same ✗ as the leader's, naming this Mac: \(text)")
        expect(text.contains("On this Mac: run `darkbloom stop --solo` to stop single-Mac serving there.")
               && text.contains(ClusterOnboardingSoloServing.leaderOffersLine("Apple M3 Ultra, 256 GB")), "R8-1 joining: what to run, and the leader's offer")
        expect(!text.contains(ClusterOnboardingDriver.memberRunsByItselfLine) && !text.contains("  1) Close\n"), "R8-1 joining: never \"Stopped … Close\"")
        // Nothing blocks: the screen it always showed.
        let plain = Recorder()
        var unblocked = operations(plain, resume: memberResume(serving: false), pairEvents: [], pairResult: .failed([]),
                                   statusLines: ["Stopped; last model Gemma 4 26B."])
        unblocked.soloServing = { [] }
        let quiet = TerminalRun(unblocked)
        expect(quiet.waitFor(prompt(2)), "R8-1 unblocked: Close or Start over"); quiet.type("\r")
        expect(quiet.finish() == 0 && quiet.text.contains(ClusterOnboardingDriver.memberRunsByItselfLine), "R8-1 unblocked: as before")
    }

    static func soloServingOnBothMacsIsSaidBeforeAnythingStarts() {
        let recorder = Recorder()
        let run = TerminalRun(soloOperations(recorder, serving: soloBoth))
        expect(run.waitFor(prompt(2)), "solo both: choice"); run.type("\r")
        expect(run.waitFor("  1) Stop single-Mac serving on both Macs and start the pair\n  2) Leave\n"), "solo both: the offer: \(run.text)")
        expect(!recorder.all.contains("serve"), "solo both: nothing started before the person chose: \(recorder.all)")
        run.type("1")
        expect(run.finish() == 0, "solo both: served once stopped: \(run.text)")
        expect(run.text.contains(soloBothTitle + "\n"), "solo both: one ✗ naming both Macs and processes: \(run.text)")
        expect(run.text.contains("On this Mac: run `darkbloom stop --solo` to stop single-Mac serving there."), "solo both: this Mac's command")
        expect(run.text.contains("On the other Mac (Apple M4 Max, 128 GB): run `darkbloom stop --solo` to stop single-Mac serving there."),
               "solo both: the other Mac's command")
        expect(!run.text.contains("update operation") && !run.text.contains("no error reported"), "solo both: never the wrong owner or 'no error'")
        expect(!run.text.contains("Retry") && !run.text.contains("starts again by itself"), "solo both: never a retry loop")
        let calls = recorder.all
        expect(calls.firstIndex(of: "stopSoloServing").map { stop in calls.firstIndex(of: "serve").map { $0 > stop } ?? false } ?? false,
               "solo both: stopped first, then started: \(calls)")
    }

    static func soloServingIsLeftWithNothingStarted() {
        let recorder = Recorder()
        let run = TerminalRun(soloOperations(recorder, serving: [soloBoth[1]]))
        expect(run.waitFor(prompt(2)), "solo leave: choice"); run.type("\r")
        expect(run.waitFor("  1) Stop single-Mac serving on the other Mac (Apple M4 Max, 128 GB) and start the pair\n  2) Leave\n"),
               "solo leave: the offer names the one Mac: \(run.text)")
        run.type("2")
        expect(run.finish() == 1, "solo leave: exit 1")
        expect(run.text.contains("The pair was not started. Run `darkbloom stop --solo` on each Mac named, then `darkbloom start`."),
               "solo leave: the last line: \(run.text)")
        expect(!recorder.all.contains("serve") && !recorder.all.contains("stopSoloServing") && !recorder.all.contains("waitReady"),
               "solo leave: nothing started or stopped without consent: \(recorder.all)")
        // A stop that fails starts nothing either.
        let failing = Recorder()
        let again = TerminalRun(soloOperations(failing, serving: [soloBoth[1]], stopWorks: false))
        expect(again.waitFor(prompt(2)), "solo stop fails: choice"); again.type("\r")
        expect(again.waitFor("  2) Leave\n"), "solo stop fails: the offer"); again.type("1")
        expect(again.finish() == 1, "solo stop fails: exit 1")
        expect(again.text.contains("The other Mac did not answer over the cable.") && !failing.all.contains("serve"),
               "solo stop fails: why, and nothing started: \(failing.all)")
    }

    static func soloServingFoundWhileWaitingIsNeverRetried() {
        let recorder = Recorder()
        let ready = ClusterOnboardingReady(servedBy: "this Mac", port: 8000,
            deployment: "Serving Gemma 4 26B across both Macs: tensor parallel", split: "tensor parallel")
        let run = TerminalRun(soloOperations(recorder, serving: [],
            readyResults: [.failure(.soloServing([soloBoth[1]])), .success(ready)]))
        expect(run.waitFor(prompt(2)), "solo wait: choice"); run.type("\r")
        expect(run.waitFor("  2) Leave\n"), "solo wait: the offer, not Retry: \(run.text)")
        run.type("1")
        expect(run.finish() == 0, "solo wait: served once stopped: \(run.text)")
        expect(run.text.contains("\u{2717} The pair can't start: a single-Mac Darkbloom provider (process 2282) is serving on the other Mac "
               + "(Apple M4 Max, 128 GB), and the pair can't share a Mac with it.\n"), "solo wait: the other Mac's reason, named: \(run.text)")
        expect(!run.text.contains(notServingChoices) && !run.text.contains("no error reported"), "solo wait: no Retry, no 'no error'")
        expect(recorder.all.filter { $0 == "serve" }.count == 2 && recorder.all.contains("stopSoloServing"),
               "solo wait: stopped, then started again once: \(recorder.all)")
    }

    static func soloServingNamesTheDevNetCommand() {
        ClusterOnboardingCommand.use("darkbloom-dev")
        defer { ClusterOnboardingCommand.use("darkbloom") }
        let run = TerminalRun(soloOperations(Recorder(), serving: [soloBoth[0]]))
        expect(run.waitFor(prompt(2)), "solo dev: choice"); run.type("\r")
        expect(run.waitFor("  2) Leave\n"), "solo dev: the offer"); run.type("2")
        expect(run.finish() == 1, "solo dev: exit 1")
        expect(run.text.contains("On this Mac: run `darkbloom-dev stop --solo`") && run.text.contains("then `darkbloom-dev start`.")
               && !run.text.contains("`darkbloom stop"), "solo dev: the DevNet app's command: \(run.text)")
    }

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
        expect(!shown.contains("\u{2713} Serving") && !shown.contains(startedLogs) && !shown.contains(ClusterOnboardingReady.offeredTestLine),
               "refused: no Serving, no Done, no test claimed: \(shown)")
        run.type("4")
        expect(run.waitFor("Saved a diagnostics file"), "refused: Diagnostics saves the file")
        expect(run.waitFor(notServingChoices, count: 2), "refused: the choices again after the file")
        run.type("q")
        let code = run.finish()
        expect(code == 1, "refused: leaving is not success, got \(String(describing: code))")
        let text = run.text
        expect(!text.contains("\u{2713} Serving") && !text.contains(startedLogs), "refused: never Serving or Done: \(text)")
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
            && again.text.contains(startedLogs), "retry: Serving and Done only after the pair served: \(again.text)")
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
        expect(!text.contains(startedLogs), "restart: never Done: \(text)")
        expect(text.contains("\u{2717} Not serving: " + ended + "\n"), "restart: why: \(text)")
        expect(text.contains(notServingChoices), "restart: the choices: \(text)")
        expect(Array(recorder.all.prefix { $0 != "register" }.suffix(2)) == ["waitReady", "testRequest"]
            && recorder.all.filter { $0 == "waitReady" }.count == 2, "restart: tested, registered, then the parts awaited: \(recorder.all)")
        transcript("restart-after-registration-fails", text, keys: run.keys)
    }

    /// The 0.10.8 candidate on pair-2 (c3, B14): "Serve locally only" at the first setup's login check started the plan
    /// made for serving through Darkbloom, so Qwen tensor parallel ran without its assistant (15.7 tok/s against 36–39
    /// with its local plan). The list is planned for the scope the start names; a login check that turns it local plans
    /// again for local and adopts that model from the new plan, before anything starts.
    static func aLoginCheckThatTurnsLocalAdoptsTheLocalPlan() {
        let both = [ClusterOnboardingMacName.this, ClusterOnboardingMacName.other(named: "Apple M3 Ultra, 256 GB")]
        let recorder = Recorder()
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), choices: switchChoices, replanned: [switchChoices[1], switchChoices[0]],
            readyResult: .success(localReady), missingLogins: both)
        made.planScope = { recorder.note("planScope " + ($0.isLocalOnly ? "local" : "public")) }
        let run = TerminalRun(made)
        expect(run.waitFor(prompt(2)), "B14: the list"); run.type("\r")
        expect(run.waitFor("  1) Log in on this Mac\n  2) Serve locally only\n  3) Cancel\n"), "B14: the login check"); run.type("2")
        _ = run.finish()
        let calls = recorder.all
        func at(_ call: String) -> Int { calls.firstIndex(of: call) ?? Int.max }
        let plans = calls.indices.filter { calls[$0] == "planModels" }
        expect(plans.count == 2 && at("planScope local") < plans[1] && plans[1] < at("adopt 1") && !calls.contains("adopt 0")
               && calls.contains { $0.hasPrefix("setScope") }, "B14: planned again for local, and that plan's Qwen adopted: \(calls)")
        transcript("leader-login-check-local-plans-again", run.text, keys: run.keys)
    }

    /// The 0.10.8 candidate on pair-2 (c3, B13): the DevNet app's cluster screens told the person to run `darkbloom …`,
    /// which on a Mac with both apps is the production command. Every command the screens print names the running
    /// identity's command.
    /// The refactor pass on the c3 fix (DevNet only): the command rename ran after a live row was fitted to the window, so a
    /// fitted row naming a command grew 4 columns and wrapped, leaving a stale row. Rows are named, then fitted.
    static func aDevNetLiveRowNamingACommandStillFitsTheWindow() {
        ClusterOnboardingCommand.use("darkbloom-dev")
        defer { ClusterOnboardingCommand.use("darkbloom") }
        let report = "1 of 2 parts ready\nThe other Mac: run `darkbloom cluster` again there once it answers"
        let run = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyReports: [report], readyReportPause: 900_000), environment: colourTerminal, columns: 45)
        expect(run.waitFor(arrowHint), "dev row: the list"); run.type("\r")
        expect(run.waitFor("darkbloom-dev"), "dev row: drawn")
        _ = run.finish()
        let dim = run.text.components(separatedBy: "\u{1B}[2m").dropFirst().compactMap { $0.components(separatedBy: "\u{1B}[0m").first }
        // A row with its time keeps the time and shortens the text before it (`ClusterOnboardingBrand.liveText`).
        let named = dim.filter { $0.contains("`darkbloom") }
        expect(!named.isEmpty && named.allSatisfy { $0.replacingOccurrences(of: "\u{2026}", with: "").count <= 45 - 6 },
               "dev row: named, then fitted to its room: \(named)")
    }

    /// The pair-2 re-test of the DevNet build (round 3, R-8): a stopped local-only pair's status said "When it starts: Local
    /// only, on this Mac's networks; API key: `darkbloom local`." in the DevNet app, whose command is `darkbloom-dev local`.
    /// These lines reach `cluster status` as they are, never through the console's rename, so they name the running
    /// identity's command themselves: the scope's line, the API line of a pair the other Mac serves, and the missing-login
    /// remedy. Production's text is unchanged.
    static func theServingLinesNameThisBuildsCommand() {
        let scope = ClusterServingScope.localOnly(bind: ClusterServingScope.localOnlyDefaultBind)
        let ready = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.other(named: "Apple M3 Ultra, 256 GB"), port: 8000,
                                           network: true)
        let login = ClusterOnboardingNotServing.notLoggedIn([ClusterOnboardingMacName.this])
        expect(scope.line == "Local only, on this Mac's networks; API key: `darkbloom local`"
               && ready.apiLine.hasSuffix("; this Mac answers too (`darkbloom local` shows its address)")
               && ClusterOnboardingNotServing.remedy(forReason: login) == "Run `darkbloom login` on each Mac named, then Retry; or serve locally only.",
               "R-8: production's command, as before: \(scope.line) / \(ready.apiLine)")
        ClusterOnboardingCommand.use("darkbloom-dev")
        defer { ClusterOnboardingCommand.use("darkbloom") }
        expect(scope.line == "Local only, on this Mac's networks; API key: `darkbloom-dev local`", "R-8: the DevNet app's line: \(scope.line)")
        expect(ready.apiLine.hasSuffix("; this Mac answers too (`darkbloom-dev local` shows its address)"), "R-8: \(ready.apiLine)")
        expect(ClusterOnboardingNotServing.remedy(forReason: login) == "Run `darkbloom-dev login` on each Mac named, then Retry; or serve "
               + "locally only.", "R-8: the remedy")
    }

    static func theDevNetAppNamesItsOwnCommand() {
        ClusterOnboardingCommand.use("darkbloom-dev")
        defer { ClusterOnboardingCommand.use("darkbloom") }
        let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor(codeQuestion), "dev: the code"); run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "dev: the list"); run.type("\r")
        expect(run.finish() == 0, "dev: served")
        let text = run.text
        expect(text.contains("  darkbloom-dev stop     Stop both Macs\n") && text.contains("`darkbloom-dev cluster`")
               && !text.contains("`darkbloom ") && !text.contains("  darkbloom stop"), "dev: its own command everywhere: \(text)")
        transcript("leader-devnet-commands", text, keys: run.keys)
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
        expect(local.text.contains("local API only\n") && local.text.contains(startedLogs), "login, local: serving locally: \(local.text)")
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
        expect(text.contains(startedLogs) && text.hasSuffix(commandLines), "served: the card: \(text)")
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
        expect(N.isMissingLogin(N.notLoggedIn(["this Mac"])) && !N.isMissingLogin(notVerified), "words: a missing login is told apart")
        let status = N.statusLine(model: "m", reason: "r")
        expect(status == "m is not serving yet: r." && N.reason(inStatusLine: status) == "r" && N.reason(inStatusLine: "Serving m.") == nil,
               "status line: the other Mac reads the reason back: \(status)")
        expect(N.title(reason: "r") == "Not serving: r.", "the outcome's title")
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
            [ClusterOnboardingReady.offeredAPILine, "Test response in 0.61 s"]) + "  Model:   "),
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

    /// (i) The refactor pass's finding, and the end user's session 2 (he pressed p on the status screen; it said
    /// Serving and nothing loaded): "Serve through Darkbloom" from the leader's menu printed "✓ Serving …: Registered
    /// with the coordinator…" for a pair that was only registered. It now waits for the pair as the start does.
    static func menuSwitchToDarkbloomWaitsForThePair() {
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M4 Max, 128 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "0.0.0.0")
        let recorder = Recorder()
        let refused = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([]),
            readyResult: .success(offeredReady), pairServingResults: [.failure(.init(notVerifiedTimed))]))
        let toDarkbloom = "  3) Switch to serving through Darkbloom (both Macs logged in)\n"
        expect(refused.waitFor(toDarkbloom), "menu, offered: the list's scope line"); refused.type("3")
        _ = refused.waitFor(notServingChoices, seconds: 5)
        refused.type("q")
        let code = refused.finish()
        let text = refused.text
        expect(code == 1, "menu, offered: not serving is not success, got \(String(describing: code))")
        // After the choice (the screen opens with the status block of the pair as it served before the switch).
        let switched = text.range(of: prompt(4)).map { String(text[$0.upperBound...]) } ?? text
        expect(!switched.contains("\u{2713} Serving") && !switched.contains(": " + ClusterOnboardingReady.registeredNotice),
               "menu, offered: never ✓ for a pair that is only registered: \(text)")
        expect(text.contains(block("\u{2717}", "Not serving: " + notVerifiedTimed + ".",
            [ClusterOnboardingNotServing.remedy(forReason: notVerifiedTimed) ?? "-"]) + notServingChoices), "menu, offered: why and the choices: \(text)")
        expect(recorder.all.contains("pairServing"), "menu, offered: the pair is awaited: \(recorder.all)")
        transcript("menu-switch-offered-refused", text, keys: refused.keys)

        let served = TerminalRun(operations(Recorder(), resume: resume, pairEvents: [], pairResult: .failed([]),
            readyResult: .success(offeredReady), pairServingResults: [.success(["in 0.84 s"])]))
        expect(served.waitFor(toDarkbloom), "menu, served: the list's scope line"); served.type("3")
        expect(served.finish() == 0, "menu, served: exit 0")
        expect(served.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
            [ClusterOnboardingReady.offeredAPILine, "Test response in 0.84 s"])), "menu, served: the outcome block: \(served.text)")
    }

    // MARK: - The DevNet traffic run (2026-11-04): the switch to Darkbloom kept the local plan, and both windows said ✓

    /// Qwen 3.8 27B on the leader's API in tensor parallel, as a pair that isn't offered serves.
    static let qwenOnTheLeadersAPI = ClusterOnboardingReady(servedBy: "this Mac", port: 8001, split: "tensor parallel")
    /// Both Macs' members registered with the coordinator for Qwen 3.8 27B in tensor parallel.
    static let qwenOffered = ClusterOnboardingReady(servedBy: "this Mac", port: 0, offered: registeredLine, split: "tensor parallel")
    /// The leading Mac's status of a pair set to serve through Darkbloom that isn't offered (`OnboardingLive.notOfferedLines`).
    static let notOfferedReason = "not offered to Darkbloom (this Mac's check refused it: Unequal tensor-parallel shares serve local clusters only)"
    static let notOfferedStatus = ["Qwen 3.8 27B is not serving yet: " + notOfferedReason + ".",
                                   "Meanwhile it answers only on the local API at http://localhost:8001 (no Darkbloom traffic).",
                                   "Test response in 0.23 s (the leading Mac's test)"]

    /// The switch plans the serving model for Darkbloom (equal shares, no speculative assistant), adopts that plan before
    /// anything stops, saves the scope after the adopt, starts both Macs and asks the coordinator, as a start does. It
    /// says ✓ only once the coordinator has the pair. Before: the leading part started again with the local plan, nothing
    /// asked the coordinator, and the screen said ✓ with a local API.
    static func switchToDarkbloomPlansTheModelAgain() {
        var local = qwenServing
        local.scope = .localOnly(bind: "0.0.0.0")
        let recorder = Recorder()
        var made = operations(recorder, resume: local, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            registerResult: .success([registeredLine]), readyResults: [.success(qwenOnTheLeadersAPI), .success(qwenOffered)],
            pairServingResults: [.success(["in 0.60 s"])])
        made.planScope = { recorder.note($0.isLocalOnly ? "planScope local" : "planScope public") }
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "switch plans: the scope line"); run.type("3")
        expect(run.finish() == 0, "switch plans: served")
        let calls = recorder.all
        let order = ["planScope public", "adopt 0", "setScope public", "serve", "testRequest", "register", "pairServing"].map { calls.firstIndex(of: $0) }
        expect(!order.contains(nil) && order == order.sorted { ($0 ?? 0) < ($1 ?? 0) },
               "switch plans: planned for Darkbloom, adopted, saved, started, registered, then awaited: \(calls)")
        expect(calls.filter { $0.hasPrefix("useMode") } == ["useMode 0 tensor_parallel_v1"], "switch plans: the mode it served in: \(calls)")
        let text = run.text
        expect(text.contains("  Switching to serving through Darkbloom: both Macs load the model again from a plan made for Darkbloom.\n")
            && !text.contains("the leading Mac's part starts again that way"), "switch plans: what it does: \(text)")
        expect(text.contains("  " + ClusterOnboardingReady.offeredLine(model: "Qwen 3.8 27B") + "\n"), "switch plans: offered: \(text)")
        expect(text.contains(block("\u{2713}", "Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)",
            [ClusterOnboardingReady.offeredAPILine, "Test response in 0.60 s"])), "switch plans: ✓ once the coordinator has the pair: \(text)")
        transcript("switch-to-darkbloom-plans-again", text, keys: run.keys)
    }

    /// A start set to serve through Darkbloom whose pair isn't offered (the coordinator serves no approval, or the check
    /// refused it) serves on the leader's API only: it ends with the leading Mac's status, ✗ and why, never ✓.
    static func aPairThatIsNotOfferedEndsWithWhyNot() {
        var local = qwenServing
        local.scope = .localOnly(bind: "0.0.0.0")
        let recorder = Recorder()
        var made = operations(recorder, resume: local, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            registerResult: .success(["Not offered for pairing: this Mac's check refused it: Unequal tensor-parallel shares serve local clusters only."]),
            readyResult: .success(qwenOnTheLeadersAPI))
        made.notOfferedStatus = { ClusterOnboardingReady.notOfferedLines(inStatus: notOfferedStatus) }
        let run = TerminalRun(made)
        expect(run.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "not offered: the scope line"); run.type("3")
        expect(run.waitFor(notServingChoices), "not offered: the choices: \(run.text)"); run.type("q")
        expect(run.finish() == 1, "not offered: not success")
        let text = run.text
        let switched = text.range(of: prompt(4)).map { String(text[$0.upperBound...]) } ?? text
        expect(!switched.contains("\u{2713}") && !switched.contains("through Darkbloom on both Macs") && !switched.contains("earning"),
               "not offered: never ✓ or Serving through Darkbloom: \(text)")
        expect(text.contains(block("\u{2717}", "Not serving: " + notOfferedReason + ".", Array(notOfferedStatus.dropFirst())) + notServingChoices),
               "not offered: why, where it answers meanwhile, and the choices: \(text)")
        expect(ClusterOnboardingReady.notOfferedLines(inStatus: ["Serving Qwen 3.8 27B through Darkbloom on both Macs."]) == nil
            && ClusterOnboardingReady.notOfferedLines(inStatus: [ClusterOnboardingNotServing.statusLine(model: "m", reason: notVerified)]) == nil,
               "not offered: only its own reason reads as not offered")
        expect(ClusterOnboardingReady.notOfferedReason(nil) == "not offered to Darkbloom (no cluster approval is attached to its setup)"
            && ClusterOnboardingReady.notOfferedReason("Not offered for pairing: the approval expired.") == "not offered to Darkbloom (the approval expired)",
               "not offered: the reason, with the approval note's why")
        transcript("switch-to-darkbloom-not-offered", text, keys: run.keys)
    }

    /// The same run: the serving model chosen again on a pair whose status says it isn't offered said "✓ Already
    /// serving" from a test on the local API and planned nothing. It asks once, then starts again from a plan for Darkbloom.
    static func theServingModelChosenAgainWhenNotOfferedIsPlannedAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
                                         statusLines: notOfferedStatus))
        expect(run.waitFor(prompt(4)), "chosen again: the list: \(run.text)"); run.type("\r")
        expect(run.waitFor("  Start Qwen 3.8 27B again from a plan made for Darkbloom? It stops serving on both Macs while it loads again "
            + "(a few minutes for a large model).\n  1) Yes, switch\n  2) No\n"), "chosen again: asked once: \(run.text)")
        run.type("1")
        expect(run.finish() == 0, "chosen again: started")
        let calls = recorder.all
        expect(!calls.prefix { $0 != "adopt 0" }.contains("testRequest") && calls.contains("adopt 0") && calls.contains("register"),
               "chosen again: planned, adopted and registered, not tested first: \(calls)")
        expect(!run.text.contains("Already serving"), "chosen again: never ✓ Already serving: \(run.text)")
    }

    /// The refactor pass's B1: when the leading Mac's status right after the start doesn't say "not offered", a start
    /// through Darkbloom that the coordinator never took (no approval) still ends with ✗: only the coordinator having the
    /// pair (`awaitPairServing`) is a ✓. A start the coordinator takes ends with ✓, as every default start here does.
    static func aStartTheCoordinatorDidNotTakeNeverEndsWithATick() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
                                         pairResult: .failed([]), registerResult: .success([])))
        expect(run.waitFor(prompt(2)), "no proof: the list: \(run.text)"); run.type("\r")
        expect(run.waitFor(notServingChoices), "no proof: the choices: \(run.text)"); run.type("q")
        expect(run.finish() == 1, "no proof: not success")
        expect(!run.text.contains("\u{2713} Serving") && !recorder.all.contains("pairServing"), "no proof: never ✓: \(run.text)")
        expect(run.text.contains(block("\u{2717}", "Not serving: not offered to Darkbloom (no cluster approval is attached to its setup).",
            ["Meanwhile it answers only on the local API at http://localhost:8000 (no Darkbloom traffic).", "Test response in 0.61 s"])
            + notServingChoices), "no proof: why, where it answers, the choices: \(run.text)")
        let taken = Recorder()
        let served = TerminalRun(operations(taken, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
                                            pairResult: .failed([])))
        expect(served.waitFor(prompt(2)), "taken: the list"); served.type("\r")
        expect(served.finish() == 0, "taken: served: \(served.text)")
        expect(served.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
            [ClusterOnboardingReady.offeredAPILine, "Test response in 0.61 s"])) && taken.all.contains("pairServing"),
               "taken: ✓ once the coordinator has the pair: \(served.text)")
    }

    /// The Mac that joined ends with the leader's ✗ when its start ends not offered: never "Offered to Darkbloom" and a
    /// wait for a coordinator that doesn't have the pair.
    static func theJoinedMacEndsWithTheLeadersNotOffered() {
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], notOfferedStatus])
        expect(run.waitFor(codeQuestion), "joined, not offered: the code"); run.type("y")
        expect(run.finish() == 1, "joined, not offered: not success")
        let text = run.text
        expect(!text.contains(ClusterOnboardingReady.offeredLine(model: "Qwen 3.8 27B")) && !recorder.all.contains("pairServing"),
               "joined, not offered: never offered, nothing awaited: \(text)")
        expect(text.hasSuffix(block("\u{2717}", "Not serving: " + notOfferedReason + ".", Array(notOfferedStatus.dropFirst()))
            + ClusterOnboardingDriver.retryOnLeaderLine(leaderName) + "\n"), "joined, not offered: the leader's ✗, then where to act: \(text)")
    }

    /// (h) The other Mac's window: where to see the outcome once it joined, and the outcome itself when it can know it.
    static func memberSeesTheOutcomeOrWhereToLook() {
        // The status lines as the leader's status writes them (`OnboardingLive.localStatus`).
        let serving = TerminalRun(operations(Recorder(), resume: .init(role: .member, peerName: "Apple M5 Ultra, 256 GB", serving: true),
            pairEvents: [], pairResult: .failed([]), statusLines: [offeredReady.pairServingLine(model: "Qwen3.8-27B-4bit-mtp") + "."]))
        // Under the block, the member's list (`memberAgain`): enter leaves.
        expect(serving.waitFor(prompt(2)), "member: the list under the outcome"); serving.type("\r")
        expect(serving.finish() == 0, "member: served")
        expect(serving.text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)", [])),
               "member: the outcome block: \(serving.text)")
        let notServing = TerminalRun(operations(Recorder(), resume: .init(role: .member, peerName: "Apple M5 Ultra, 256 GB", serving: true),
            pairEvents: [], pairResult: .failed([]),
            statusLines: [ClusterOnboardingNotServing.statusLine(model: "Qwen3.8-27B-4bit-mtp", reason: notVerifiedTimed),
                          ClusterOnboardingNotServing.remedy(forReason: notVerifiedTimed) ?? "-"]))
        expect(notServing.waitFor(prompt(2)), "member, not serving: the list under the outcome"); notServing.type("\r")
        _ = notServing.finish()
        expect(notServing.text.contains(block("\u{2717}", "Not serving: " + notVerifiedTimed + ".",
            [ClusterOnboardingNotServing.remedy(forReason: notVerifiedTimed) ?? "-"])), "member: the not-serving block: \(notServing.text)")
    }

    // MARK: - A set-up pair works like `darkbloom start` (owner, 2026-11-04: "make it similar to how normal darkbloom works")

    /// Qwen 3.8 27B serving through Darkbloom, in tensor parallel.
    static let qwenServing: ClusterOnboardingResume = {
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "EigenLabs/Qwen3.8-27B-4bit-mtp")
        resume.modelTitle = "Qwen 3.8 27B"
        resume.servingMode = "tensor_parallel_v1"
        return resume
    }()

    /// Gemma 4 26B on these Macs: a pipeline measured at 46 tok/s, tensor parallel not measured yet.
    static let switchChoices = [
        ClusterOnboardingModelChoice(title: "Qwen 3.8 27B", lines: ["16.3 GB · tensor parallel · this Mac 50% / the other Mac 50%"], blocker: nil,
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", validated: true, split: "tensor parallel",
            modes: [.init(mode: "tensor_parallel_v1", split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: 41.2)]),
        ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["15.6 GB · pipeline · this Mac 6 layers / the other Mac 24 layers"], blocker: nil,
            modelID: "gemma-4-26b-qat-4bit", validated: true, split: "pipeline",
            modes: [.init(mode: "tensor_parallel_v1", split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: nil),
                    .init(mode: "pipeline_v1", split: "this Mac 6 layers / the other Mac 24 layers", measuredTokensPerSecond: 46.0)])]

    /// The started card's log line: only a start that served ends with it (right under the ✓ block).
    static let startedLogs = "  Logs:    ~/.darkbloom/cluster-setup/service.log\n"

    /// The commands every ending gives, as `darkbloom start` does.
    static let commandLines = "  darkbloom stop     Stop both Macs\n  darkbloom restart  Restart with the current model\n  darkbloom status   Check status\n"

    /// The status block of the harness's serving pair.
    static let servingBlock = block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 (earning through Darkbloom)", [])

    /// The list as Qwen serves through Darkbloom: each model's modes, the measured one first, with no speed.
    static let qwenList = "  1) Qwen 3.8 27B · 16.3 GB · tensor parallel · serving now\n"
        + "  2) Gemma 4 26B · 15.6 GB · pipeline or tensor parallel\n"
        + "  3) Switch to local only (this Mac's API, no Darkbloom traffic)\n  4) Start over (unpair and set up again)\n"

    /// The leading Mac of a set-up pair: the opening and the status, then the pair's models with the serving one marked
    /// and preselected, a scope line and Start over; no menu. Enter on the serving model changes nothing and ends with
    /// the status and the commands.
    static func leaderScreenIsTheModelList() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices, thisMacName: "Studio A"))
        expect(run.waitFor(prompt(4)), "pair screen: the list")
        let shown = run.text
        expect(shown.contains("Darkbloom cluster \u{00B7} Leading Mac\nThis Mac (Studio A) leads \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) follows \u{00B7} cable ready\n"),
               "pair screen: the opening: \(shown)")
        expect(shown.contains(servingBlock + "\nModel\n" + qwenList + "  " + prompt(4)), "pair screen: the status, then the models, the serving one preselected: \(shown)")
        expect(!shown.contains("Test a response") && !shown.contains("Stop serving") && !shown.contains("Check memory is freed") && !shown.contains("How it works"),
               "pair screen: no menu items: \(shown)")
        run.type("\r")
        expect(run.finish() == 0, "already serving: exit 0")
        let text = run.text
        expect(text.hasSuffix(block("\u{2713}", "Already serving Qwen 3.8 27B; test response in 0.61 s", [])
            + "  Model:   Qwen 3.8 27B \u{00B7} tensor parallel\n  Macs:    This Mac (Studio A) leads \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) follows\n"
            + "  Serves:  through Darkbloom\n" + startedLogs + "  Starts by itself at login on both Macs.\n\n" + commandLines),
               "already serving: one test, its result in the block, then the details and the commands: \(text)")
        expect(recorder.all.filter { $0 == "testRequest" }.count == 1 && !recorder.all.contains { $0.hasPrefix("adopt") || $0 == "serve" || $0 == "stop" },
               "already serving: one test request, nothing started or stopped: \(recorder.all)")
        transcript("leader-already-serving", text, keys: run.keys)
    }

    /// The serving model chosen again tests it ("run `darkbloom cluster` to test again" leads here): a failed test is the
    /// start's ✗ block with its choices; a pair served only through Darkbloom has no local API here, said plainly.
    static func alreadyServingTestsAgainOrSaysWhyNot() {
        let failing = Recorder()
        let fail = TerminalRun(operations(failing, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            testResult: .failure(.init(["Test response timed out."]))))
        expect(fail.waitFor(prompt(4)), "test again, fail: the list"); fail.type("\r")
        expect(fail.waitFor(notServingChoices), "test again, fail: the choices"); fail.type("q")
        expect(fail.finish() == 1, "test again, fail: exit 1")
        expect(fail.text.contains(block("\u{2717}", "Not serving: Test response timed out.", []) + notServingChoices)
            && !fail.text.contains("Already serving") && failing.all.filter { $0 == "testRequest" }.count == 1,
               "test again, fail: the ✗ block and its choices after one test: \(fail.text)")
        transcript("leader-already-serving-test-fails", fail.text, keys: fail.keys)

        let offered = Recorder()
        let pair = TerminalRun(operations(offered, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            testResult: .failure(.init([ClusterOnboardingReady.offeredTestLine]))))
        expect(pair.waitFor(prompt(4)), "test again, no local API: the list"); pair.type("\r")
        expect(pair.finish() == 0, "test again, no local API: exit 0")
        expect(pair.text.contains("Already serving Qwen 3.8 27B through Darkbloom; this Mac has no local API to send a test from.\n")
            && pair.text.hasSuffix(servingBlock + "\n" + commandLines) && !pair.text.contains("\u{2717}"),
               "test again, no local API: said plainly, then the pair's status and the commands: \(pair.text)")
        transcript("leader-already-serving-no-local-api", pair.text, keys: pair.keys)
    }

    /// A start that died before it asked Darkbloom leaves its mark in the record: the status clears it once its process
    /// is gone, and only while the record still holds that mark (a new start's is never wiped). The mark is the pid and
    /// when its process started, so a pid the system gave to another process never counts, even before the clear.
    static func aDeadPendingStartIsClearedOnlyWhileStillRecorded() {
        typealias P = ClusterOnboardingPendingRegistration
        let start = P.Mark(pid: 4242, started: 1_762_000_000_000_001)
        let dead = P.look(start, started: { _ in nil })
        expect(!dead.pending && dead.clear == start, "pending mark: a dead start's mark is not pending and is cleared")
        let running = P.look(start, started: { $0 == 4242 ? 1_762_000_000_000_001 : nil })
        expect(running.pending && running.clear == nil, "pending mark: the running start stays pending")
        let reused = P.look(start, started: { $0 == 4242 ? 1_762_000_900_000_000 : nil })
        expect(!reused.pending && reused.clear == start, "pending mark: its pid, reused by a later process, is not pending and is cleared")
        let unknown = P.look(P.Mark(pid: 4242, started: nil), started: { _ in 1_762_000_000_000_001 })
        expect(!unknown.pending, "pending mark: a pid without its start time never counts")
        let none = P.look(nil, started: { _ in 1 })
        expect(!none.pending && none.clear == nil, "pending mark: none recorded")
        let newer = P.Mark(pid: 5151, started: 1_762_000_500_000_000)
        expect(P.cleared(start, gone: start) == nil, "pending mark: cleared while the record still holds it")
        expect(P.cleared(newer, gone: start) == newer, "pending mark: a new start's mark is kept")
        expect(P.cleared(P.Mark(pid: 4242, started: 1_762_000_900_000_000), gone: start) != nil, "pending mark: the same pid of a newer start is kept")
        expect(P.cleared(nil, gone: start) == nil, "pending mark: nothing to clear")
    }

    /// The candidate on pair 2 (2026-11-04, B2): a Mac whose firewall dropped the discovery probe left both Macs at
    /// "2/4 Pair" with no hint. After a short wait without finding the other Mac, the screen says what to check and the
    /// direct route, once, and keeps waiting; the pairing then goes on as usual.
    static func pairingSaysWhatToCheckWhenTheOtherMacIsNotFound() {
        typealias P = ClusterOnboardingPairing
        let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            pairHintSeconds: 0.3, pairWait: 1.5))
        expect(run.waitFor(codeQuestion, seconds: 20), "not found: the pairing goes on"); run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "not found: then the model list"); run.type("\r")
        expect(run.finish() == 0, "not found: served")
        let text = run.text
        let hint = "  " + P.otherMacNotFoundLines.joined(separator: "\n  ") + "\n"
        expect(P.otherMacNotFoundLines.joined(separator: " ").contains("System Settings → Network → Firewall")
            && P.otherMacNotFoundLines.joined(separator: " ").contains("darkbloom cluster pair --connect <that address>")
            && P.otherMacNotFoundLines.joined(separator: " ").contains("darkbloom cluster pair --listen"), "not found: what to check, word for word")
        let order = [P.otherMacLine, hint, "Code 123 456"].compactMap { text.range(of: $0)?.lowerBound }
        expect(order.count == 3 && order == order.sorted(), "not found: said while waiting, before the code: \(text)")
        expect(text.components(separatedBy: P.otherMacNotFoundLines[0]).count == 2, "not found: said once")
        transcript("leader-pairing-not-found-hint", text, keys: run.keys)
        // Found at once: nothing extra.
        let quick = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            pairHintSeconds: 30))
        expect(quick.waitFor(codeQuestion), "found: the code"); quick.type("y")
        expect(quick.waitFor(prompt(2), count: 2), "found: the list"); quick.type("\r")
        _ = quick.finish()
        expect(!quick.text.contains(P.otherMacNotFoundLines[0]), "found: no hint")
    }

    /// R-3 (the pair-2 re-test): the hint's firewall line said "Darkbloom" in the DevNet app, whose firewall entry is its own
    /// name. It, and the line that asks to pair again after a reinstall, name the app as the Local Network lines do.
    static func pairingLinesNameTheApp() {
        ClusterOnboardingCommand.useApp("Darkbloom Dev")
        defer { ClusterOnboardingCommand.useApp("Darkbloom") }
        let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
            pairHintSeconds: 0.3, pairWait: 1.5))
        expect(run.waitFor(codeQuestion, seconds: 20), "app name: the pairing goes on"); run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "app name: the list"); run.type("\r")
        expect(run.finish() == 0, "app name: served")
        expect(run.text.contains("  · macOS's firewall lets Darkbloom Dev in on both Macs (System Settings → Network → Firewall);\n"),
               "app name: the firewall line names the app: \(run.text)")
        expect(!run.text.contains("lets Darkbloom in"), "app name: never production's app")
        expect(ClusterOnboardingPairingProblem.keyChanged.line
            .contains("(Darkbloom Dev was reinstalled, or this Mac moved between the Darkbloom and DevNet apps)"),
               "app name: the line that asks to pair again names the app that was reinstalled")
    }

    /// Validator D's m1 meets m9: the list says "serving now" only beside a settled serving line, the one shown as ✓. A
    /// start still checking with Darkbloom (its line now, and an older leader's "Serving … (checking …)") and a
    /// published failed test read "last used", with no ✓.
    static func theServingMarkerFollowsOnlyASettledServingLine() {
        let olderLeader = "Serving Qwen3.8-27B-4bit-mtp at http://localhost:8000 (" + ClusterOnboardingReady.offerPendingWords + ")"
        let failed = [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "the test request timed out"),
                      ClusterOnboardingReady.testFailedNote]
        for (name, lines) in [("pending", [offerPendingLine]), ("older leader's pending", [olderLeader]), ("failed test", failed)] {
            let run = TerminalRun(operations(Recorder(), resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
                statusLines: lines))
            expect(run.waitFor(prompt(4)), "\(name): the list")
            expect(run.text.contains("  1) Qwen 3.8 27B · 16.3 GB · tensor parallel · last used\n")
                   && !run.text.contains("serving now") && !run.text.contains("\u{2713}"), "\(name): last used, no ✓: \(run.text)")
            run.type("q")
            _ = run.finish()
            if name == "older leader's pending" { transcript("leader-pending-older-leader-last-used", run.text, keys: run.keys) }
        }
    }

    /// Validator D's M3 meets rounds 5 and 6: Enter on the serving model (its test) and that test's Retry never mark a
    /// pending registration, so their failure is never published as a start's outcome; a mode switch is a start and
    /// marks once, from `finishStart`, local only or through Darkbloom (round 8: every screen start publishes its outcome).
    static func theServingModelsTestNeverMarksAStart() {
        let tested = Recorder()
        var test = operations(tested, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            testResult: .failure(.init(["Not serving: waiting for the coordinator to pair both Macs."])))
        test.markRegistrationPending = { tested.note("markRegistrationPending") }
        let run = TerminalRun(test)
        expect(run.waitFor(prompt(4)), "no mark: the list"); run.type("\r")
        expect(run.waitFor(notServingChoices), "no mark: the test failed"); run.type("1")
        expect(run.finish() == 1, "no mark: the Retry ends")
        expect(tested.all.contains("testRequest") && tested.all.contains("waitReady") && !tested.all.contains("markRegistrationPending"),
               "no mark: the test and its Retry: \(tested.all)")
        var piped = qwenServing
        piped.servingMode = "pipeline_v1"
        let switched = Recorder()
        var mode = operations(switched, resume: piped, pairEvents: [], pairResult: .failed([]), choices: switchChoices)
        mode.markRegistrationPending = { switched.note("markRegistrationPending") }
        let change = TerminalRun(mode)
        expect(change.waitFor(prompt(4)), "mode switch: the list"); change.type("\r")
        expect(change.waitFor("  1) Yes, switch\n  2) No\n"), "mode switch: asked"); change.type("1")
        _ = change.finish()
        let marks = switched.all.filter { $0 == "markRegistrationPending" }.count
        expect(switched.all.contains("adopt 0") && marks == 1, "mode switch: one mark, a start's: \(switched.all)")
        var localPiped = piped
        localPiped.scope = .localOnly(bind: "0.0.0.0")
        let local = Recorder()
        var localMode = operations(local, resume: localPiped, pairEvents: [], pairResult: .failed([]), choices: switchChoices)
        localMode.markRegistrationPending = { local.note("markRegistrationPending") }
        let localChange = TerminalRun(localMode)
        expect(localChange.waitFor(prompt(4)), "local mode switch: the list"); localChange.type("\r")
        expect(localChange.waitFor("  1) Yes, switch\n  2) No\n"), "local mode switch: asked"); localChange.type("1")
        _ = localChange.finish()
        expect(local.all.filter { $0 == "markRegistrationPending" }.count == 1, "local start: marks once, to publish its outcome: \(local.all)")
    }

    /// Validator D's m3: the serving model, listed in another mode (planned while the parts held memory), read as a
    /// switch to "another" model. The same model in another mode is a mode change, said as one.
    static func aModeChangeOfTheServingModelIsAskedAsOne() {
        var piped = qwenServing
        piped.servingMode = "pipeline_v1"
        let kept = Recorder()
        let run = TerminalRun(operations(kept, resume: piped, pairEvents: [], pairResult: .failed([]), choices: switchChoices))
        expect(run.waitFor(prompt(4)), "mode change: the list"); run.type("\r")
        expect(run.text.contains("  1) Qwen 3.8 27B · 16.3 GB · tensor parallel · serving now in pipeline\n"),
               "mode change: the list names the mode it serves in: \(run.text)")
        expect(run.waitFor("  Switch Qwen 3.8 27B from pipeline to tensor parallel? It stops serving on both Macs while it loads again "
            + "(a few minutes for a large model).\n  1) Yes, switch\n  2) No\n"), "mode change: asked as one: \(run.text)")
        run.type("\r")
        expect(run.finish() == 0 && run.text.hasSuffix("Nothing changed: Qwen 3.8 27B keeps serving.\n") && !kept.all.contains("adopt 0"),
               "mode change, no: nothing changed: \(run.text)")
        transcript("leader-mode-change-question", run.text, keys: run.keys)
        // The other mode picked at the mode question, for a model that runs both ways here: the same question.
        var gemma = qwenServing
        gemma.modelName = "gemma-4-26b-qat-4bit"
        gemma.modelTitle = "Gemma 4 26B"
        let picked = Recorder()
        let other = TerminalRun(operations(picked, resume: gemma, pairEvents: [], pairResult: .failed([]), choices: switchChoices))
        expect(other.waitFor(prompt(4, enter: 2)), "mode picked: the list, Gemma preselected: \(other.text)")
        expect(other.text.contains(" · pipeline or tensor parallel · serving now\n"),
               "mode picked: serving now, its mode listed: \(other.text)")
        other.type("\r")
        expect(other.waitFor("  " + ClusterOnboardingDriver.modeQuestion(model: "Gemma 4 26B") + "\n"), "mode picked: how to split it")
        other.type("2")
        expect(other.waitFor("  Switch Gemma 4 26B from tensor parallel to pipeline? It stops serving on both Macs while it loads again "
            + "(a few minutes for a large model).\n  1) Yes, switch\n  2) No\n"), "mode picked: asked as a mode change: \(other.text)")
        other.type("\r")
        expect(other.finish() == 0 && other.text.hasSuffix("Nothing changed: Gemma 4 26B keeps serving.\n")
               && !picked.all.contains { $0.hasPrefix("adopt") }, "mode picked, no: nothing changed: \(other.text)")
        transcript("leader-mode-change-picked", other.text, keys: other.keys)
    }

    /// Validator D's m4: a set-up pair whose list is empty (no model can run here) still offers Start over and Quit,
    /// after the reason, as the old menu always did.
    static func aSetUpPairWithNoModelToListOffersStartOver() {
        let blocked = [ClusterOnboardingModelChoice(title: "GLM", lines: [], blocker: "too large for this pair", modelID: "glm-5.3-flash", validated: true)]
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: blocked))
        expect(run.waitFor("  1) " + ClusterOnboardingDriver.startOverItem + "\n  2) Quit\n  " + prompt(2, enter: 2)), "no model: Start over or Quit: \(run.text)")
        expect(run.text.contains("No approved model can run on these Macs now.\n  GLM: too large for this pair\n"), "no model: the reason first: \(run.text)")
        run.type("\r")
        expect(run.finish() == 1 && !recorder.all.contains("unpair"), "no model: Quit changes nothing: \(recorder.all)")
        transcript("leader-no-model-start-over", run.text, keys: run.keys)
        // Planning that fails: its reason, then the same two choices; 1 reaches Start over's confirmation.
        let failing = Recorder()
        let failed = TerminalRun(operations(failing, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            planFailure: ["Planning failed (the other Mac's memory report is missing)."]))
        expect(failed.waitFor("  1) " + ClusterOnboardingDriver.startOverItem + "\n  2) Quit\n  " + prompt(2, enter: 2)),
               "planning failed: Start over or Quit: \(failed.text)")
        expect(failed.text.contains("Planning failed (the other Mac's memory report is missing).\n"), "planning failed: the reason first: \(failed.text)")
        failed.type("1")
        expect(failed.waitFor("  " + ClusterOnboardingDriver.startOverQuestion + "\n  1) Yes, start over\n  2) No\n"),
               "planning failed: 1 reaches Start over's confirmation: \(failed.text)")
        failed.type("\r")
        expect(failed.finish() == 0 && failed.text.contains("Nothing changed.\n") && !failing.all.contains("unpair"),
               "planning failed: No at the confirmation changes nothing: \(failed.text)")
        transcript("leader-planning-failed-start-over", failed.text, keys: failed.keys)
    }

    /// Validator D's m9: a pair whose status says it doesn't serve isn't listed "serving now"; a failed test of the
    /// serving model says "Not serving" once; its Retry waits for the pair as the start's Retry does.
    static func aPairThatDoesNotServeIsNeitherMarkedNorTestedTwice() {
        let waiting = [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "waiting for the coordinator to pair both Macs")]
        let marked = TerminalRun(operations(Recorder(), resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            statusLines: waiting))
        expect(marked.waitFor(prompt(4)), "not serving: the list")
        expect(marked.text.contains("  1) Qwen 3.8 27B · 16.3 GB · tensor parallel · last used\n") && !marked.text.contains("serving now"),
               "not serving: last used, never serving now: \(marked.text)")
        marked.type("q")
        _ = marked.finish()
        transcript("leader-not-serving-last-used", marked.text, keys: marked.keys)

        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            testResult: .failure(.init(["Not serving: waiting for the coordinator to pair both Macs."]))))
        expect(run.waitFor(prompt(4)), "test once: the list"); run.type("\r")
        expect(run.waitFor(notServingChoices), "test once: the choices")
        expect(run.text.contains("\u{2717} Not serving: waiting for the coordinator to pair both Macs.\n") && !run.text.contains("Not serving: Not serving"),
               "test once: one title: \(run.text)")
        run.type("1")
        expect(run.finish() == 1, "retry: ends after its wait and test")
        let tested = recorder.all.firstIndex(of: "testRequest"), waited = recorder.all.lastIndex(of: "waitReady")
        expect(tested != nil && waited != nil && waited! > tested!, "retry: waits for the pair as the start's Retry does: \(recorder.all)")
        transcript("leader-serving-test-fails-retry-waits", run.text, keys: run.keys)
    }

    /// q (or Esc) at the list changes nothing: the status block again and the commands; exit 0.
    static func qAtTheListChangesNothing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices))
        expect(run.waitFor(prompt(4)), "q: the list"); run.type("q")
        expect(run.finish() == 0, "q: exit 0")
        expect(run.text.contains("Nothing changed.\n") && run.text.hasSuffix(servingBlock + "\n" + commandLines), "q: the status, then the commands: \(run.text)")
        expect(!recorder.all.contains { $0.hasPrefix("adopt") || $0 == "serve" }, "q: nothing run: \(recorder.all)")
        transcript("leader-q", run.text, keys: run.keys)
    }

    /// The Mac that follows (Dylan: "Nothing to do here, manage it on the other Mac"): who leads, the same status
    /// block, that its part runs by itself, the command to run on the leading Mac and that `darkbloom stop` here stops
    /// both Macs; enter closes, Start over one choice away.
    static func memberScreenSaysWhoLeadsAndWhatToRun() {
        typealias D = ClusterOnboardingDriver
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([]), thisMacName: "Studio B"))
        expect(run.waitFor(prompt(2)), "member screen: the prompt")
        run.type("\r")
        expect(run.finish() == 0, "member screen: enter closes")
        let text = run.text
        expect(text.contains("This Mac (Studio B) follows \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) leads \u{00B7} cable ready\n"),
               "member screen: both Macs and the cable in the opening: \(text)")
        expect(text.contains(block("\u{2713}", "Serving Qwen3.8-27B-4bit-mtp (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)", [])
            + "  " + D.memberRunsByItselfLine + "\n"), "member screen: the block, then that its part runs by itself: \(text)")
        expect(D.memberLeaderLine("Apple M3 Ultra, 256 GB") == "To change the model, run `darkbloom cluster` or `darkbloom start` on the other Mac "
            + "(Apple M3 Ultra, 256 GB). `darkbloom stop` here stops both Macs.", "member screen: the next step, word for word")
        expect(text.contains("\n" + D.memberLeaderLine("Apple M3 Ultra, 256 GB") + "\n  1) Close\n  2) Start over (unpair and set up again)\n"),
               "member screen: the next step, then Close or Start over: \(text)")
        expect(recorder.all == ["ensureService", "status"], "member screen: nothing run: \(recorder.all)")
        transcript("member-screen", text, keys: run.keys)
    }

    /// Another model on a serving pair: the mode question (the fastest measured first), one confirmation (No by
    /// default), the stop, then the ending like `darkbloom start`'s: the model in its mode and split, the Macs, where
    /// requests go, the log, and the commands; no "Done", no setup steps.
    static func switchAsksOnceThenEndsLikeStart() {
        typealias D = ClusterOnboardingDriver
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices))
        expect(run.waitFor(prompt(4)), "switch: the list"); run.type("2")
        expect(run.waitFor(D.modeQuestion(model: "Gemma 4 26B")), "switch: the mode question"); run.type("\r")
        let confirm = D.switchQuestion(to: "Gemma 4 26B", from: "Qwen 3.8 27B")
        expect(run.waitFor("  " + confirm + "\n  1) " + D.switchAnswers[0] + "\n  2) No\n  " + prompt(2, enter: 2)), "switch: one confirmation, No by default: \(run.text)")
        run.type("y")
        expect(run.finish() == 0, "switch: served")
        let text = run.text
        let order = ["\nStart\n", "  \u{2713} " + D.stoppedLine("Qwen 3.8 27B"), "\u{2713} Serving Gemma 4 26B", "  Model:   Gemma"]
            .compactMap { text.range(of: $0)?.lowerBound }
        expect(order.count == 4 && order == order.sorted(), "switch: the stop, the block, then the card: \(text)")
        expect(text.contains(ClusterOnboardingDriver.resultRule + "\n  Model:   Gemma 4 26B \u{00B7} pipeline (this Mac 32 layers / the other Mac 32 layers)\n"
            + "  Macs:    This Mac leads \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) follows\n  Serves:  through Darkbloom\n"
            + "  Logs:    ~/.darkbloom/cluster-setup/service.log\n  Starts by itself at login on both Macs.\n\n" + commandLines),
               "switch: the card, like darkbloom start's: \(text)")
        expect(text.hasSuffix(commandLines) && !text.contains("Done.") && !text.contains("3/4 Model") && !text.contains("4/4 Start"),
               "switch: back to the shell: \(text)")
        let adopted = recorder.all.firstIndex(of: "adopt 1"), mode = recorder.all.firstIndex(of: "useMode 1 pipeline_v1")
        expect(adopted != nil && mode != nil && mode! < adopted!, "switch: the mode chosen before the setup is sent: \(recorder.all)")
        transcript("leader-switch", text, keys: run.keys)

        let kept = Recorder()
        let no = TerminalRun(operations(kept, resume: qwenServing, pairEvents: [], pairResult: .failed([]), choices: switchChoices))
        expect(no.waitFor(prompt(4)), "switch, no: the list"); no.type("2")
        expect(no.waitFor(D.modeQuestion(model: "Gemma 4 26B")), "switch, no: the mode"); no.type("\r")
        expect(no.waitFor(D.switchAnswers[0]), "switch, no: asked"); no.type("\r")
        expect(no.finish() == 0 && no.text.hasSuffix("Nothing changed: Qwen 3.8 27B keeps serving.\n") && !kept.all.contains("adopt 1"), "switch, no: \(no.text)")
    }

    /// The owner's rulings (2026-11-04): tensor parallel and pipeline both offered, the fastest measured on this pair
    /// first, the other one keypress away, each said plainly with each Mac's share (uneven on mixed Macs).
    static func modeChoiceOffersBothWithTheFastestMeasuredFirst() {
        typealias D = ClusterOnboardingDriver
        typealias M = ClusterOnboardingMode
        let gemma = switchChoices[1].modes!
        expect(M.defaultIndex(gemma) == 1, "modes: the measured pipeline is the default")
        expect(M.defaultIndex([M(mode: "tensor_parallel_v1", split: nil, measuredTokensPerSecond: nil), M(mode: "pipeline_v1", split: nil, measuredTokensPerSecond: nil)]) == 0,
               "modes: none measured, the planner's first")
        expect(M.defaultIndex([M(mode: "tensor_parallel_v1", split: nil, measuredTokensPerSecond: 88), M(mode: "pipeline_v1", split: nil, measuredTokensPerSecond: 48)]) == 0,
               "modes: the fastest measured")
        expect(D.modeLine(gemma[1]) == D.menuLine("Pipeline", "each Mac runs its share of the layers (this Mac 6 layers / the other Mac 24 layers)"),
               "modes: pipeline in plain words: \(D.modeLine(gemma[1]))")
        expect(D.modeLine(gemma[0]) == D.menuLine("Tensor parallel", "both Macs work on every layer, each holding a share of it (this Mac 50% / the other Mac 50%)"),
               "modes: tensor parallel in plain words: \(D.modeLine(gemma[0]))")
        expect(D.modeLine(M(mode: "pipeline_mtp_v1", split: "this Mac 24 layers / the other Mac 24 layers", measuredTokensPerSecond: 59))
            == D.menuLine("Speculative pipeline", "a pipeline that drafts several tokens and checks them together (this Mac 24 layers / the other Mac 24 layers)"),
               "modes: MiMo's speculative pipeline")
        // R4-15 (the M5 Ultra pair's DevNet run): GLM's pipeline took one request at a time and Darkbloom turned the rest
        // away at capacity, while its tensor parallel took 8 at once, 2.6x faster each. Each mode says how many it takes.
        let glmPipeline = D.modeLine(M(mode: "pipeline_v1", split: "this Mac 44 layers / the other Mac 1 layer", measuredTokensPerSecond: 41,
                                       concurrentRequests: 1))
        expect(glmPipeline == D.menuLine("Pipeline", "each Mac runs its share of the layers (this Mac 44 layers / the other Mac 1 layer) "
                   + "· serves one request at a time"), "modes: a pipeline that takes one request at a time says so: \(glmPipeline)")
        let glmTensor = D.modeLine(M(mode: "tensor_parallel_v1", split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: 106,
                                     concurrentRequests: 8))
        expect(glmTensor == D.menuLine("Tensor parallel", "both Macs work on every layer, each holding a share of it (this Mac 50% / the "
                   + "other Mac 50%) · serves up to 8 requests at once"), "modes: how many at once: \(glmTensor)")
        // The owner (2026-11-05): "it should not show tok/s". The rows never quote a speed, measured or not.
        for line in [glmPipeline, glmTensor, D.modeLine(gemma[0]), D.modeLine(gemma[1]), D.modeLine(gemma[1], recommended: true, room: 60)] {
            expect(!line.contains("tok/s") && !line.contains("measured"), "modes: no speed in a mode's row: \(line)")
        }
        // The screen, on a stopped pair: another model's question offers both, the measured one by default.
        let recorder = Recorder()
        var stopped = qwenServing
        stopped.serving = false
        let run = TerminalRun(operations(recorder, resume: stopped, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            statusLines: ["Stopped; last model Qwen 3.8 27B."]))
        expect(run.waitFor(prompt(4)), "mode screen: the list"); run.type("2")
        expect(run.waitFor("  " + D.modeQuestion(model: "Gemma 4 26B") + "\n  1) " + D.modeLine(gemma[0]) + "\n  2) " + D.modeLine(gemma[1]) + "\n  " + prompt(2, enter: 2)),
               "mode screen: both, the measured one by default: \(run.text)")
        run.type("1")
        expect(run.finish() == 0, "mode screen: served")
        expect(recorder.all.contains("useMode 1 tensor_parallel_v1") && !run.text.contains(D.switchAnswers[0]),
               "mode screen: tensor parallel chosen; nothing served, so nothing to confirm: \(recorder.all)")
        transcript("leader-mode-choice", run.text, keys: run.keys)
    }

    /// The owner (2026-11-04): "it also does not suggest which one to select for the hardware like it should." The
    /// question marks exactly one mode "recommended for these Macs", with why (faster, serves more at once, or the only
    /// one that fits), from what the plans know; or none, and why. The leading Mac makes it, so both Macs' screens show
    /// the same, and the cursor starts on it.
    static func modeQuestionRecommendsOneForTheseMacs() {
        typealias D = ClusterOnboardingDriver
        typealias A = ClusterOnboardingModeAdvice
        let tp = "tensor_parallel_v1", pp = "pipeline_v1"
        // GLM-5.3-Flash on two M5 Ultras (DevNet, 2026-11-04): tensor parallel 105.6 tok/s and 8 at once, pipeline 40.8 and one.
        let glm = [A.Option(mode: tp, planned: true, fitsNow: true, measuredTokensPerSecond: 105.6, concurrentRequests: 8, publicTraffic: true),
                   A.Option(mode: pp, planned: true, fitsNow: true, measuredTokensPerSecond: 40.8, concurrentRequests: 1, publicTraffic: true)]
        let measured = A.advise(glm, throughDarkbloom: true, serving: false)
        expect(measured == A(mode: tp, reason: "faster here and serves up to 8 requests at once"),
               "advice: GLM on two M5 Ultras, measured: \(String(describing: measured))")
        let fresh = glm.map { var option = $0; option.measuredTokensPerSecond = nil; return option }
        expect(A.advise(fresh, throughDarkbloom: true, serving: false)
               == A(mode: tp, reason: "serves up to 8 requests at once; no speed is known for these Macs yet"), "advice: nothing measured yet, lanes decide")
        let predicted = fresh.enumerated().map { var option = $1; option.predictedTokensPerSecond = $0 == 0 ? 92 : 38; return option }
        expect(A.advise(predicted, throughDarkbloom: true, serving: false)?.reason == "faster here and serves up to 8 requests at once",
               "advice: the planner's prediction when nothing is measured, never quoted")
        // The owner (2026-11-05): "it should not show tok/s". Pair-2's Gemma said "faster here (about 56 against 52
        // tokens/s, predicted)"; the speeds still rank the modes, the words never quote them.
        let gemmaPair2 = [A.Option(mode: tp, planned: true, fitsNow: true, predictedTokensPerSecond: 52, concurrentRequests: 1, publicTraffic: true),
                          A.Option(mode: pp, planned: true, fitsNow: true, predictedTokensPerSecond: 56, concurrentRequests: 1, publicTraffic: true)]
        let pair2 = A.advise(gemmaPair2, throughDarkbloom: true, serving: false)
        expect(pair2 == A(mode: pp, reason: "faster here"), "advice: no figures in the reason: \(String(describing: pair2))")
        expect(pair2?.plainLine(model: "Gemma 4 26B") == "Recommended for Gemma 4 26B on these two Macs: Pipeline, faster here.",
               "advice: the plain line: \(String(describing: pair2?.plainLine(model: "Gemma 4 26B")))")
        // Through Darkbloom the mode that takes more at once, as fast: said so, with no figures.
        let asFast = [A.Option(mode: pp, planned: true, fitsNow: true, measuredTokensPerSecond: 58, concurrentRequests: 1, publicTraffic: true),
                      A.Option(mode: tp, planned: true, fitsNow: true, measuredTokensPerSecond: 58, concurrentRequests: 8, publicTraffic: true)]
        let asFastAdvice = A.advise(asFast, throughDarkbloom: true, serving: false)
        expect(asFastAdvice == A(mode: tp, reason: "serves up to 8 requests at once and is as fast here"),
               "advice: more at once and as fast, no figures: \(String(describing: asFastAdvice))")
        // A measurement on these Macs outranks a prediction (owner, 2026-11-05: "use measurements when present"). Two M5
        // Ultras, build D (2026-11-05 07:24Z): Gemma tensor parallel served 111 tok/s while the pipeline had not served yet;
        // the planner predicted that pipeline at 152 (it then served 64), so comparing predictions recommended it.
        let gemmaM5U = [A.Option(mode: tp, planned: true, fitsNow: true, measuredTokensPerSecond: 111, predictedTokensPerSecond: 133,
                                 concurrentRequests: 1, publicTraffic: true),
                        A.Option(mode: pp, planned: true, fitsNow: true, predictedTokensPerSecond: 152, concurrentRequests: 1, publicTraffic: true)]
        let gemmaM5UAdvice = A.advise(gemmaM5U, throughDarkbloom: true, serving: false)
        expect(gemmaM5UAdvice == A(mode: tp, reason: "the only one measured on these Macs so far"),
               "advice: a measured mode outranks a predicted one: \(String(describing: gemmaM5UAdvice))")
        // MiMo on the same pair: tensor parallel measured 55, the speculative pipeline (one at a time too) not yet.
        let mimoM5U = [A.Option(mode: "pipeline_mtp_v1", planned: true, fitsNow: true, predictedTokensPerSecond: 90, concurrentRequests: 1,
                                publicTraffic: true),
                       A.Option(mode: tp, planned: true, fitsNow: true, measuredTokensPerSecond: 55, predictedTokensPerSecond: 60,
                                concurrentRequests: 1, publicTraffic: true)]
        expect(A.advise(mimoM5U, throughDarkbloom: true, serving: false)?.mode == tp, "advice: MiMo's measured tensor parallel")
        // Several measured, one not: the fastest measured, said so.
        let three = [A.Option(mode: tp, planned: true, fitsNow: true, measuredTokensPerSecond: 40, concurrentRequests: 1, publicTraffic: true),
                     A.Option(mode: pp, planned: true, fitsNow: true, measuredTokensPerSecond: 60, concurrentRequests: 1, publicTraffic: true),
                     A.Option(mode: "pipeline_mtp_v1", planned: true, fitsNow: true, predictedTokensPerSecond: 200, concurrentRequests: 1,
                              publicTraffic: true)]
        expect(A.advise(three, throughDarkbloom: false, serving: false) == A(mode: pp, reason: "the fastest measured on these Macs so far"),
               "advice: the fastest measured of several")
        // Through Darkbloom a mode that serves more at once still wins without a speed (R4-15), measured or not.
        let lanesFirst = [A.Option(mode: tp, planned: true, fitsNow: true, predictedTokensPerSecond: 90, concurrentRequests: 8, publicTraffic: true),
                          A.Option(mode: pp, planned: true, fitsNow: true, measuredTokensPerSecond: 41, concurrentRequests: 1, publicTraffic: true)]
        expect(A.advise(lanesFirst, throughDarkbloom: true, serving: false)
               == A(mode: tp, reason: "serves up to 8 requests at once; the others take fewer, and Darkbloom turns the rest away"),
               "advice: more at once still wins through Darkbloom")
        expect(gemmaM5UAdvice?.plainLine(model: "Gemma 4 26B", width: 80) == "Recommended for Gemma 4 26B on these two Macs: Tensor parallel, measured here.",
               "advice: the short reason: \(String(describing: gemmaM5UAdvice?.plainLine(model: "Gemma 4 26B", width: 80)))")
        for advice in [measured, A.advise(predicted, throughDarkbloom: true, serving: false), pair2, asFastAdvice] {
            let line = advice?.plainLine(model: "Gemma 4 26B") ?? ""
            expect(!line.isEmpty && !line.contains("tok") && !line.contains("against") && !line.contains("(measured)") && !line.contains("predicted)"),
                   "advice: no speed quoted: \(line)")
        }
        // A memory-tight pair (an M3 Ultra and an M5 Max 128 GB): tensor parallel doesn't fit now.
        let tight = [A.Option(mode: tp, planned: true, fitsNow: false, concurrentRequests: 8, publicTraffic: true),
                     A.Option(mode: pp, planned: true, fitsNow: true, concurrentRequests: 1, publicTraffic: true)]
        expect(A.advise(tight, throughDarkbloom: true, serving: false) == A(mode: pp, reason: "the only one that fits these Macs now"), "advice: the only one that fits")
        let neither = tight.map { var option = $0; option.fitsNow = false; return option }
        expect(A.advise(neither, throughDarkbloom: true, serving: false) == A(mode: nil, reason: "none of them fits in these Macs' free memory now"),
               "advice: nothing fits, none recommended")
        expect(A.advise(neither, throughDarkbloom: true, serving: true)?.mode == tp, "advice: while a model serves its memory is freed first, so fitting now does not decide")
        let unknown = [A.Option(mode: tp, planned: true, fitsNow: true), A.Option(mode: pp, planned: true, fitsNow: true)]
        expect(A.advise(unknown, throughDarkbloom: false, serving: false) == A(mode: nil, reason: "no speed is measured or predicted for these Macs yet"),
               "advice: no evidence, no guess")
        let unplanned = [A.Option(mode: tp, planned: false, fitsNow: false), A.Option(mode: pp, planned: false, fitsNow: false)]
        expect(A.advise(unplanned, throughDarkbloom: false, serving: false)?.mode == nil, "advice: nothing planned")
        // Locally a clearly faster pipeline wins; through Darkbloom the mode that takes more at once does.
        let fastPipe = [A.Option(mode: tp, planned: true, fitsNow: true, measuredTokensPerSecond: 30, concurrentRequests: 8, publicTraffic: true),
                        A.Option(mode: pp, planned: true, fitsNow: true, measuredTokensPerSecond: 46, concurrentRequests: 1, publicTraffic: true)]
        expect(A.advise(fastPipe, throughDarkbloom: false, serving: false)?.mode == pp, "advice: locally, the faster")
        expect(A.advise(fastPipe, throughDarkbloom: true, serving: false)
               == A(mode: tp, reason: "serves up to 8 requests at once; the others take fewer, and Darkbloom turns the rest away"),
               "advice: through Darkbloom, more at once")
        let privatePipe = fastPipe.map { var option = $0; option.publicTraffic = $0.mode == pp ? false : true; return option }
        expect(A.advise(privatePipe, throughDarkbloom: true, serving: false) == A(mode: tp, reason: "the only one Darkbloom serves publicly on these Macs"),
               "advice: what Darkbloom serves publicly")
        expect(A.advise([glm[0]], throughDarkbloom: true, serving: false) == nil, "advice: one mode, no question")
        // The screens: the leading Mac's and the other Mac's (its list comes from the leading Mac, worded for it).
        func choice(_ here: String, _ there: String) -> ClusterOnboardingModelChoice {
            ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel · \(here) 50% / \(there) 50%"], blocker: nil,
                modelID: "glm-5.3-flash", validated: true, split: "tensor parallel",
                modes: [.init(mode: tp, split: "\(here) 50% / \(there) 50%", measuredTokensPerSecond: 105.6, concurrentRequests: 8),
                        .init(mode: pp, split: "\(here) 44 layers / \(there) 1 layer", measuredTokensPerSecond: 40.8, concurrentRequests: 1)],
                modeAdvice: measured)
        }
        var stopped = qwenServing
        stopped.serving = false
        // The first line under the question names the model, the mode apart; too wide for the window, the reason is
        // shortened, then left out, never the model's or the mode's name.
        let glmTitle = "Z.ai: GLM-5.3-Flash"
        let full = "Recommended for Z.ai: GLM-5.3-Flash on these two Macs: Tensor parallel, faster here and serves up to 8 requests at once."
        expect(measured?.plainLine(model: glmTitle) == full, "line: the model and the mode named")
        expect(measured?.plainLine(model: glmTitle, width: 110)
               == "Recommended for Z.ai: GLM-5.3-Flash on these two Macs: Tensor parallel, faster, up to 8 at once.", "line: a shorter reason")
        expect(measured?.plainLine(model: glmTitle, width: 40) == "Recommended for Z.ai: GLM-5.3-Flash on these two Macs: Tensor parallel.",
               "line: 40 columns: no reason, every name whole")
        expect(measured?.line(model: glmTitle).mode == "Tensor parallel", "line: the mode apart, to stress it")
        expect(A(mode: nil, reason: "no speed is measured or predicted for these Macs yet").plainLine(model: "Gemma 4 26B", width: 60)
               == "No recommendation for Gemma 4 26B on these two Macs: no speed known yet.", "line: none, shortened")
        expect(A.advise(tight, throughDarkbloom: true, serving: false)?.plainLine(model: "Gemma 4 26B", width: 120)
               == "Recommended for Gemma 4 26B on these two Macs: Pipeline, the only one that fits these Macs now.", "line: the only one that fits")
        var screens: [String] = []
        for (label, glmChoice) in [("leading Mac", choice("this Mac", "the other Mac")), ("other Mac", choice("the other Mac", "this Mac"))] {
            let recorder = Recorder()
            let run = TerminalRun(operations(recorder, resume: stopped, pairEvents: [], pairResult: .failed([]), choices: [switchChoices[0], glmChoice],
                statusLines: ["Stopped; last model Qwen 3.8 27B."]), columns: 200)
            expect(run.waitFor(prompt(4)), "recommended, \(label): the list"); run.type("2")
            let modes = glmChoice.modes!
            let question = "  " + D.modeQuestion(model: glmTitle) + "\n  " + full + "\n  1) " + D.modeLine(modes[0], recommended: true)
                + "\n  2) " + D.modeLine(modes[1]) + "\n  " + prompt(2)
            expect(run.waitFor(question), "recommended, \(label): marked, said and preselected: \(run.text)")
            run.type("\r")
            expect(run.finish() == 0 && recorder.all.contains("useMode 1 \(tp)"), "recommended, \(label): enter takes it: \(recorder.all)")
            screens.append(run.text)
            transcript("mode-recommended-\(label == "leading Mac" ? "leader" : "other")", run.text, keys: run.keys)
        }
        expect(D.modeLine(choice("this Mac", "the other Mac").modes![0], recommended: true).hasSuffix(" · recommended for these Macs"), "recommended: the marker")
        expect(screens.count == 2 && screens.allSatisfy { $0.contains("\n  " + full + "\n") }, "recommended: the same words on both Macs")
        // A colour terminal stresses the mode, as it does the outcome's title; a 40-column window keeps every name.
        let colour = TerminalRun(operations(Recorder(), resume: stopped, pairEvents: [], pairResult: .failed([]),
            choices: [switchChoices[0], choice("this Mac", "the other Mac")], statusLines: ["Stopped; last model Qwen 3.8 27B."]),
            environment: ["TERM": "xterm-256color"], columns: 40)
        expect(colour.waitFor("Qwen 3.8 27B"), "colour: the list")
        colour.type("2")
        expect(colour.waitFor("  Recommended for Z.ai: GLM-5.3-Flash on these two Macs: \u{1B}[1mTensor parallel\u{1B}[0m."),
               "colour, 40 columns: the mode in bold, the reason left out: \(colour.text.suffix(800))")
        colour.type("q")
        _ = colour.finish()
        // None recommended: said, nothing marked, and the cursor where it was (the fastest measured, else the planner's).
        var unsure = choice("this Mac", "the other Mac")
        unsure.modeAdvice = A(mode: nil, reason: "no speed is measured or predicted for these Macs yet")
        unsure.modes = unsure.modes!.map { var mode = $0; mode.measuredTokensPerSecond = nil; mode.concurrentRequests = 1; return mode }
        let run = TerminalRun(operations(Recorder(), resume: stopped, pairEvents: [], pairResult: .failed([]), choices: [switchChoices[0], unsure],
            statusLines: ["Stopped; last model Qwen 3.8 27B."]))
        expect(run.waitFor(prompt(4)), "no recommendation: the list"); run.type("2")
        expect(run.waitFor("  No recommendation for Z.ai: GLM-5.3-Flash on these two Macs: no speed is measured or predicted for these Macs yet.\n  1) " + D.modeLine(unsure.modes![0])
            + "\n  2) " + D.modeLine(unsure.modes![1]) + "\n  " + prompt(2)), "no recommendation: why, nothing marked: \(run.text)")
        run.type("q")
        _ = run.finish()
        transcript("mode-no-recommendation", run.text, keys: run.keys)
    }

    /// Pair-2 (an M3 Ultra and an M5 Max) on DevNet .118 (2026-11-06, capture A at 08:57Z, Qwen serving): Gemma had served
    /// nothing with the new build, so the question compared the planner's predictions and said "Pipeline, faster here",
    /// though these Macs had served its tensor parallel faster with every earlier build (pipeline 57.2 tok/s on .92;
    /// tensor parallel 61.3 on .92 and 84 on .110). Until this build has served one of the modes, what these Macs served
    /// with an earlier build ranks them; a prediction comes only after that. No mode, model or chip is preferred.
    static func modeAdviceFollowsTheseMacsMeasurementsAfterAnUpdate() {
        typealias A = ClusterOnboardingModeAdvice
        let tp = "tensor_parallel_v1", pp = "pipeline_v1"
        // Capture A: both planned, one request at a time, served publicly; the planner predicts the pipeline faster; an
        // earlier build served tensor parallel through Darkbloom.
        let afterUpdate = [
            A.Option(mode: pp, planned: true, fitsNow: true, predictedTokensPerSecond: 56, concurrentRequests: 1, publicTraffic: true),
            A.Option(mode: tp, planned: true, fitsNow: true, earlierMeasuredTokensPerSecond: 84, predictedTokensPerSecond: 52,
                     concurrentRequests: 1, publicTraffic: true)]
        let advice = A.advise(afterUpdate, throughDarkbloom: true, serving: true)
        expect(advice == A(mode: tp, reason: "the only one measured on these Macs so far"),
               "after an update: the mode these Macs measured with an earlier build, not the predicted one: \(String(describing: advice))")
        expect(advice?.plainLine(model: "Gemma 4 26B")
               == "Recommended for Gemma 4 26B on these two Macs: Tensor parallel, the only one measured on these Macs so far.",
               "after an update: the line: \(String(describing: advice?.plainLine(model: "Gemma 4 26B")))")
        // Both served with earlier builds: the faster as these Macs measured it, whichever mode that is.
        func earlier(_ options: [A.Option], tensorParallel: Double?, pipeline: Double?) -> [A.Option] {
            options.map { option in
                var option = option
                option.earlierMeasuredTokensPerSecond = option.mode == tp ? tensorParallel : pipeline
                return option
            }
        }
        let both = A.advise(earlier(afterUpdate, tensorParallel: 84, pipeline: 57.2), throughDarkbloom: true, serving: true)
        expect(both == A(mode: tp, reason: "faster here"), "both measured with earlier builds: the faster: \(String(describing: both))")
        let pipelineFaster = A.advise(earlier(afterUpdate, tensorParallel: 57.2, pipeline: 84), throughDarkbloom: true, serving: true)
        expect(pipelineFaster == A(mode: pp, reason: "faster here"), "measured the other way round: the pipeline: \(String(describing: pipelineFaster))")
        let asFast = A.advise(earlier(afterUpdate, tensorParallel: 84, pipeline: 82), throughDarkbloom: true, serving: true)
        expect(asFast == A(mode: nil, reason: "they are about as fast on these Macs (measured) and serve as many requests at once"),
               "measured within 5 %: none, as for this build's measurements: \(String(describing: asFast))")
        // Capture B (09:38Z): tensor parallel has served with this build. This build's measurements decide; an earlier
        // build's figure, even a faster one, waits until that mode serves with this build too.
        var servedNow = earlier(afterUpdate, tensorParallel: 84, pipeline: 120)
        servedNow[1].measuredTokensPerSecond = 96.4
        expect(A.advise(servedNow, throughDarkbloom: true, serving: true) == A(mode: tp, reason: "the only one measured on these Macs so far"),
               "this build measured: its measurement decides")
        // Nothing measured on these Macs with any build: the planner's prediction, as before.
        let fresh = earlier(afterUpdate, tensorParallel: nil, pipeline: nil)
        expect(A.advise(fresh, throughDarkbloom: true, serving: true) == A(mode: pp, reason: "faster here"), "nothing measured: the prediction")
        // Through Darkbloom a mode that serves more requests at once still comes first, as with this build's measurements.
        var lanes = afterUpdate
        lanes[0].concurrentRequests = 8
        expect(A.advise(lanes, throughDarkbloom: true, serving: true)
               == A(mode: pp, reason: "serves up to 8 requests at once; the others take fewer, and Darkbloom turns the rest away"),
               "through Darkbloom: more at once first")
        for line in [advice, both, pipelineFaster, asFast].map({ $0?.plainLine(model: "Gemma 4 26B") ?? "" }) {
            expect(!line.isEmpty && !line.contains("tok") && !line.contains("84") && !line.contains("57"), "after an update: no figure: \(line)")
        }
    }

    /// The recommendation can rest on what an earlier build served while this build has measured nothing, and the
    /// planner's first mode may be the other one (pair-2's Gemma right after an update: the pipeline first, tensor
    /// parallel recommended). The list's order and a model named on the command line follow the recommendation too, so
    /// the list never reads "pipeline or tensor parallel" while the question recommends tensor parallel. (A model started
    /// again keeps the mode it served in, as before: `chooseAndServe`'s `keepMode`.)
    static func theListAndTheDefaultFollowTheRecommendation() {
        let tp = "tensor_parallel_v1", pp = "pipeline_v1"
        var gemma = ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["15.6 GB · pipeline · this Mac 6 layers / the other Mac 24 layers"],
            blocker: nil, modelID: "gemma-4-26b-qat-4bit", validated: true, split: "pipeline",
            modes: [.init(mode: pp, split: "this Mac 6 layers / the other Mac 24 layers", measuredTokensPerSecond: nil, concurrentRequests: 1),
                    .init(mode: tp, split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: nil, concurrentRequests: 1)])
        expect(gemma.listLine(sameTitleElsewhere: false) == "Gemma 4 26B · 15.6 GB · pipeline or tensor parallel",
               "no recommendation: the planner's first: \(gemma.listLine(sameTitleElsewhere: false))")
        let unrecommended = gemma
        gemma.modeAdvice = ClusterOnboardingModeAdvice(mode: tp, reason: "the only one measured on these Macs so far")
        expect(gemma.listLine(sameTitleElsewhere: false) == "Gemma 4 26B · 15.6 GB · tensor parallel or pipeline",
               "the recommended mode first: \(gemma.listLine(sameTitleElsewhere: false))")
        expect(ClusterOnboardingMode.defaultIndex(gemma.modes!, recommended: "pipeline_mtp_v1") == 0,
               "a recommendation the list doesn't hold changes nothing")
        // Named on the command line (`darkbloom cluster local <model>`), so no question: the recommended mode loads.
        func named(_ choice: ClusterOnboardingModelChoice) -> [String] {
            let recorder = Recorder()
            let resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB")
            let run = TerminalRun(operations(recorder, resume: resume, pairEvents: [], pairResult: .failed([]), choices: [choice]),
                request: ClusterOnboardingRequest(scope: .localOnly(bind: ClusterServingScope.localOnlyDefaultBind), model: "Gemma 4 26B"))
            _ = run.finish()
            return recorder.all.filter { $0.hasPrefix("useMode") }
        }
        expect(named(gemma) == ["useMode 0 \(tp)"], "named: the recommended mode: \(named(gemma))")
        expect(named(unrecommended) == ["useMode 0 \(pp)"], "named, no recommendation: the planner's first, as before")
    }

    /// R6-2 (M5 Ultra pair, DevNet branch.81): "… the other Mac 44 layers) · ser…" at 120 columns, and a window widened
    /// to 220 kept the cut lines. Each mode's line fits the window as it is at every draw, the list redraws when the
    /// width changes, and a line too wide loses the split, then what each Mac does, then the long words: never the
    /// mode's name or how many requests it serves at once, never cut. Plain, the whole line.
    static func modeLinesFitTheWindowAsItIsNow() {
        typealias D = ClusterOnboardingDriver
        let tp = "tensor_parallel_v1", pp = "pipeline_v1"
        let modes: [ClusterOnboardingMode] = [
            .init(mode: tp, split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: 105.6, concurrentRequests: 8),
            .init(mode: pp, split: "this Mac 1 layer / the other Mac 44 layers", measuredTokensPerSecond: 40.8, concurrentRequests: 1)]
        let glm = ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel · this Mac 50% / the other Mac 50%"],
            blocker: nil, modelID: "glm-5.3-flash", validated: true, split: "tensor parallel", modes: modes,
            modeAdvice: ClusterOnboardingModeAdvice(mode: tp, reason: "faster here and serves up to 8 requests at once"))
        var stopped = qwenServing
        stopped.serving = false
        let names = ["Tensor parallel", "Pipeline"]
        let requests = [["serves up to 8 requests at once", "serves up to 8 at once"], ["serves one request at a time", "serves one at a time"]]
        func open(_ columns: UInt16, _ environment: [String: String]) -> TerminalRun {
            let run = TerminalRun(operations(Recorder(), resume: stopped, pairEvents: [], pairResult: .failed([]), choices: [switchChoices[0], glm],
                statusLines: ["Stopped; last model Qwen 3.8 27B."]), environment: environment, columns: columns)
            expect(run.waitFor("Qwen 3.8 27B"), "\(columns) columns: the model list")
            run.type("2")
            expect(run.waitFor(D.modeQuestion(model: glm.title)), "\(columns) columns: the mode question")
            return run
        }
        /// The list's rows as last drawn (wrap off for each draw), escapes removed: the hint, then each option's rows.
        func lastFrame(_ run: TerminalRun) -> [String] {
            let question = run.text.components(separatedBy: D.modeQuestion(model: glm.title)).last ?? ""
            let frame = (question.components(separatedBy: ClusterOnboardingBrand.noWrap).last ?? "").components(separatedBy: ClusterOnboardingBrand.wrap)[0]
            return frame.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                .components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        func frames(_ run: TerminalRun) -> Int {
            (run.text.components(separatedBy: D.modeQuestion(model: glm.title)).last ?? "").components(separatedBy: ClusterOnboardingBrand.noWrap).count - 1
        }
        func waitForDraws(_ run: TerminalRun, _ count: Int) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, frames(run) < count { usleep(10_000) }
            usleep(150_000)
            return frames(run) >= count
        }
        func check(_ run: TerminalRun, _ columns: Int, _ label: String) {
            let rows = lastFrame(run)
            let room = columns - 6
            let expected = modes.indices.flatMap { D.modeLine(modes[$0], recommended: $0 == 0, room: room).components(separatedBy: "\n") }
            expect(rows.count == expected.count + 1 && Array(rows.dropFirst()).map { String($0.dropFirst(4)) } == expected,
                   "\(label): each mode's rows as worded for \(room) columns: \(rows)")
            let wide = rows.filter { ClusterOnboardingBrand.textColumns($0) > columns - 2 }
            expect(wide.isEmpty, "\(label): every row fits the window: \(wide)")
            expect(!rows.dropFirst().contains { $0.contains("\u{2026}") }, "\(label): no mode row is cut: \(rows)")
            for index in modes.indices {
                expect(rows.contains { $0.contains(names[index]) } && rows.contains { row in requests[index].contains { row.contains($0) } },
                       "\(label): \(names[index]) and how many it serves at once, whole: \(rows)")
            }
            if D.modeLine(modes[1]).count <= room {
                expect(rows.contains { $0.hasSuffix(D.modeLine(modes[1])) }, "\(label): the whole pipeline line where it fits: \(rows)")
            }
        }
        for columns: UInt16 in [220, 120, 80, 40] {
            let run = open(columns, colourTerminal)
            defer { run.release() }
            expect(waitForDraws(run, 1), "\(columns) columns: the list drawn")
            check(run, Int(columns), "\(columns) columns")
            run.type("q")
            _ = run.finish()
            transcript("mode-lines-\(columns)", run.text, keys: run.keys)
        }
        // The window resized while the question is open: the list redraws for the new width each time.
        let run = open(120, colourTerminal)
        defer { run.release() }
        expect(waitForDraws(run, 1), "opened at 120 columns: the list drawn")
        check(run, 120, "opened at 120 columns")
        for columns: UInt16 in [220, 80, 40, 120] {
            let before = frames(run)
            var window = winsize(ws_row: 50, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(run.master, TIOCSWINSZ, &window)
            expect(waitForDraws(run, before + 1), "resized to \(columns): redrawn (\(before) draws before)")
            check(run, Int(columns), "resized to \(columns) columns")
        }
        run.type("2")
        expect(run.finish() == 0, "resized: 2 takes the pipeline")
        expect(visible(run.text).contains { $0.contains("Pipeline") && $0.contains("serves one") },
               "resized: the chosen line stays, whole words: \(visible(run.text).suffix(4))")
        // Plain, the whole line, however narrow the window.
        let plain = open(40, ["NO_COLOR": "1"])
        defer { plain.release() }
        expect(plain.waitFor("\n  1) " + D.modeLine(modes[0], recommended: true) + "\n  2) " + D.modeLine(modes[1]) + "\n"),
               "plain, 40 columns: the whole lines: \(plain.text.suffix(600))")
        plain.type("q")
        _ = plain.finish()
    }

    /// The list (team note: "Model selection should hide model that we don't allow them to be run there"): the model
    /// serving now marked, each model's modes by name, the measured one first; an approved model that cannot run is
    /// named with its reason, above the list. No speed, measured or not (owner, 2026-11-05: the model and mode choice
    /// never quote tok/s; DevNet .118, pair-2: "Gemma 4 26B · tensor parallel 96 tok/s or pipeline (not measured …)").
    static func modelListMarksTheCurrentModelAndQuotesNoSpeed() {
        let current = switchChoices[0].listLine(sameTitleElsewhere: false)
        expect(current == "Qwen 3.8 27B · 16.3 GB · tensor parallel", "list: a model's line: \(current)")
        let gemma = switchChoices[1].listLine(sameTitleElsewhere: false)
        expect(gemma == "Gemma 4 26B · 15.6 GB · pipeline or tensor parallel", "list: both modes, the measured one first: \(gemma)")
        var unmeasured = switchChoices[1]
        unmeasured.modes = unmeasured.modes!.map { var mode = $0; mode.measuredTokensPerSecond = nil; return mode }
        expect(unmeasured.listLine(sameTitleElsewhere: false) == "Gemma 4 26B · 15.6 GB · tensor parallel or pipeline",
               "list: none measured, the planner's first: \(unmeasured.listLine(sameTitleElsewhere: false))")
        // Pair-2 on DevNet .118 (09:38Z, Qwen serving): Gemma's tensor parallel had served with this build, the pipeline not.
        var pair2 = switchChoices[1]
        pair2.modes = [.init(mode: "pipeline_v1", split: ClusterOnboardingMode.decidedWhenItLoads, measuredTokensPerSecond: nil, concurrentRequests: 1),
                       .init(mode: "tensor_parallel_v1", split: ClusterOnboardingMode.decidedWhenItLoads, measuredTokensPerSecond: 96.4,
                             concurrentRequests: 1)]
        let pair2Line = pair2.listLine(sameTitleElsewhere: false)
        expect(pair2Line == "Gemma 4 26B · 15.6 GB · tensor parallel or pipeline", "list: pair-2's Gemma: \(pair2Line)")
        let mimo = ClusterOnboardingModelChoice(title: "MiMo V2.6 Flash", lines: ["172.9 GB · pipeline"], blocker: nil, modelID: "mimo-v2.6-flash-mopd",
            validated: true, modes: [.init(mode: "pipeline_mtp_v1", split: nil, measuredTokensPerSecond: 58.7),
                                     .init(mode: "tensor_parallel_v1", split: nil, measuredTokensPerSecond: 52.2)])
        expect(mimo.listLine(sameTitleElsewhere: false) == "MiMo V2.6 Flash · 172.9 GB · speculative pipeline or tensor parallel",
               "list: MiMo's speculative pipeline: \(mimo.listLine(sameTitleElsewhere: false))")
        for line in [current, gemma, unmeasured.listLine(sameTitleElsewhere: false), pair2Line, mimo.listLine(sameTitleElsewhere: false)] {
            expect(!line.contains("tok") && !line.contains("measured"), "list: no speed in a model's line: \(line)")
        }
        // An approved model that cannot run here is never hidden silently (2026-11-05: Qwen 3.8 27B left a pair's list
        // without a word when its plan failed): it is named with its reason in one line above the list, and cannot be
        // picked; a model not approved for clusters stays unnamed.
        let blocked = ClusterOnboardingModelChoice(title: "GLM", lines: [], blocker: "too large for this pair", modelID: "glm-5.3-flash", validated: true)
        let unapproved = ClusterOnboardingModelChoice(title: "Gemma 4 E4B", lines: [], blocker: "too large for this pair", modelID: "gemma-4-e4b", validated: false)
        let run = TerminalRun(operations(Recorder(), resume: qwenServing, pairEvents: [], pairResult: .failed([]),
                                         choices: switchChoices + [blocked, unapproved]))
        expect(run.waitFor(prompt(4)), "list screen: two models to choose, GLM not among them")
        expect(run.text.contains("  GLM: not offered on these two Macs: too large for this pair\n" + qwenList),
               "list screen: the blocked approved model and its reason above the list: \(run.text)")
        expect(!run.text.contains("Gemma 4 E4B"), "list screen: an unapproved model is not named")
        run.type("q")
        _ = run.finish()
        // The bug's own reason, plain and with its cause, on a 40-column screen: wrapped, every word kept.
        let failed = ClusterOnboardingModelChoice(title: "Qwen 3.8 27B", lines: [],
            blocker: "the plan for it failed (Tensor-parallel request allowance does not cover the requested context and chunk)",
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", validated: true)
        let narrow = TerminalRun(operations(Recorder(), resume: qwenServing, pairEvents: [], pairResult: .failed([]),
                                            choices: Array(switchChoices.dropFirst()) + [failed]), columns: 40)
        expect(narrow.waitFor(prompt(3)), "list screen, 40 columns: the list")
        let said = "Qwen 3.8 27B: not offered on these two Macs: the plan for it failed (Tensor-parallel request allowance "
            + "does not cover the requested context and chunk)"
        let shown = screen(narrow.text, columns: 40)
        expect(shown.allSatisfy { $0.count <= 40 } && shown.joined().replacingOccurrences(of: " ", with: "")
                .contains(said.replacingOccurrences(of: " ", with: "")),
               "list screen, 40 columns: the reason wraps and keeps every word: \(shown)")
        narrow.type("q")
        _ = narrow.finish()
    }

    /// A fresh setup says first what it will ask and how long it takes (brief: "one screen before 1/4").
    static func firstRunSaysWhatWillBeAsked() {
        typealias D = ClusterOnboardingDriver
        let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor(codeQuestion), "first run: pairing as before"); run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "first run: the model list"); run.type("\r")
        _ = run.finish()
        let text = run.text
        expect(text.hasPrefix("\nDarkbloom cluster\n  " + D.firstRunLines(localOnly: false).joined(separator: "\n  ") + "\n\n1/4 Connect\n"),
               "first run: what it asks and how long, before 1/4: \(text.prefix(600))")
        expect(D.firstRunLines(localOnly: false).joined(separator: " ").contains("Darkbloom login")
            && !D.firstRunLines(localOnly: true).joined(separator: " ").contains("login"), "first run: the login only when serving through Darkbloom")
        expect(D.firstRunLines(localOnly: false).joined(separator: " ").contains("about 2 minutes"), "first run: how long")
        let resumed = TerminalRun(operations(Recorder(), resume: qwenServing, pairEvents: [], pairResult: .failed([])))
        expect(resumed.waitFor(prompt(4)), "first run: not on a resumed Mac"); resumed.type("q")
        _ = resumed.finish()
        expect(!resumed.text.contains(D.firstRunLines(localOnly: false)[0]), "first run: a resumed Mac does not say it")
        transcript("first-run", text, keys: run.keys)
    }

    // MARK: - UX audit P3 (2026-11-04): silence is not a broken pairing

    /// What a Mac says when the other Mac does not answer over the cable, word for word (the audit's P2 words): that
    /// Mac by its name, its likely reasons, and what to run there.
    static func silentLine(_ mac: String) -> String {
        "The other Mac (\(mac)) isn't answering over the cable. Its cluster service is off, or that Mac is asleep, off, or waiting for "
            + "someone to log in. On that Mac, run `darkbloom start` or `darkbloom cluster`."
    }

    /// About 8 s of silence (a FileVault login window after a restart, sleep, a closed lid, `darkbloom cluster stop`)
    /// swapped Start over, which asks first, for Pair again, which does not, on both Macs. Silence now names the other
    /// Mac, its likely reasons and what to run there, and keeps Start over with its question. Only a pairing that
    /// cannot be used (this Mac's key changed) offers Pair again, as before.
    static func silenceIsNotABrokenPairing() {
        // The member whose leader is silent (B3): Try again, Start over or Quit; No at the question changes nothing.
        let member = Recorder()
        let followed = TerminalRun(operations(member, resume: memberResume(), pairEvents: [], pairResult: .failed([]), otherMacAnswers: [false]))
        expect(followed.waitFor(prompt(3)), "silence (member): a list")
        let asked = followed.text
        expect(asked.contains("This Mac follows \u{00B7} the other Mac (Apple M3 Ultra, 256 GB) leads\n  " + silentLine("Apple M3 Ultra, 256 GB") + "\n\n  1) Try again\n  2) "
            + ClusterOnboardingDriver.startOverItem + "\n  3) Quit\n"), "silence (member): the Mac, why and what to run there, then the list: \(asked)")
        expect(!asked.contains(") " + ClusterOnboardingDriver.pairAgainItem + "\n"), "silence (member): never Pair again")
        followed.type("2")
        expect(followed.waitFor(ClusterOnboardingDriver.startOverQuestion), "silence (member): Start over asks first"); followed.type("\r")
        expect(followed.finish() == 0 && followed.text.hasSuffix("Nothing changed.\n") && !member.all.contains("unpair"),
               "silence (member): No changes nothing: \(member.all)")
        transcript("member-silent-start-over", followed.text, keys: followed.keys)

        // The serving leader whose member is asleep or at its login window (D1, E1): its usual menu with Start over.
        let leader = Recorder()
        let led = TerminalRun(operations(leader, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB", serving: true,
            modelName: "Qwen3.8-27B-4bit-mtp"), pairEvents: [], pairResult: .failed([]), otherMacAnswers: [false]))
        expect(led.waitFor(prompt(3)), "silence (leader): the choices")
        let menu = led.text
        expect(menu.contains("  " + silentLine("Apple M5 Max, 128 GB") + "\n\n  1) Try again\n  2) " + ClusterOnboardingDriver.startOverItem + "\n  3) Quit\n"),
               "silence (leader): the Mac, why and what to run there, then Try again, Start over or Quit: \(menu)")
        expect(!menu.contains(") " + ClusterOnboardingDriver.pairAgainItem), "silence (leader): never Pair again")
        led.type("2")
        expect(led.waitFor(ClusterOnboardingDriver.startOverQuestion), "silence (leader): Start over asks first"); led.type("\r")
        expect(led.finish() == 0 && !leader.all.contains("unpair"), "silence (leader): No changes nothing: \(leader.all)")
        transcript("leader-silent-start-over", led.text, keys: led.keys)

        // A pairing that cannot be used still offers Pair again at once, without the question, on either Mac.
        for role in [ClusterOnboardingRole.leader, .member] {
            var broken = role == .member ? memberResume()
                : ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Max, 128 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
            broken.pairingProblem = .keyChanged
            let run = TerminalRun(operations(Recorder(), resume: broken, pairEvents: [], pairResult: .failed([]), otherMacAnswers: [false]))
            expect(run.waitFor(prompt(2)), "broken pairing (\(role)): its list")
            expect(run.text.contains("  " + ClusterOnboardingPairingProblem.keyChanged.line + "\n\n  1) " + ClusterOnboardingDriver.pairAgainItem
                + "\n  2) Quit\n"), "broken pairing (\(role)): Pair again, without a question: \(run.text)")
            run.type("2")
            _ = run.finish()
        }
    }

    /// Change model in a ✗ outcome's choices reads both Macs again with the choices of a Mac paired before this run:
    /// when the other Mac stops answering, Try again, Start over (which asks first) or Quit, as the next `darkbloom
    /// cluster` run offers; never only Try again or Cancel, which belongs right after pairing. Failing first on
    /// 1ec3a927ce.
    static func changeModelAfterNotServingKeepsTheChoices() {
        let failed = ["The other Mac (Apple M3 Ultra, 256 GB) did not answer over the cable within 2 minutes: the other Mac's cluster service did not answer on the cable"]
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false,
            modelName: "Qwen3.8-27B-4bit-mtp"), pairEvents: [], pairResult: .failed([]), reachFailure: failed, reachAnswers: [true, false],
            readyResult: .success(offeredReady), pairServingResults: [.failure(.init(notVerified))]))
        expect(run.waitFor(prompt(4)), "change model after ✗: the list, the last model preselected"); run.type("\r")
        expect(run.waitFor(notServingChoices), "change model after ✗: the outcome's choices"); run.type("2")
        expect(run.waitFor(failed[0] + "\n  1) Try again\n  2) " + ClusterOnboardingDriver.startOverItem + "\n  3) Quit\n"),
               "change model after ✗: Try again, Start over or Quit once the other Mac stops answering: \(run.text)")
        expect(!run.text.contains(") Cancel\n") && !run.text.contains(") " + ClusterOnboardingDriver.pairAgainItem + "\n"),
               "change model after ✗: neither Cancel only nor Pair again")
        run.type("3")
        expect(run.finish() == 1, "change model after ✗: Quit changes nothing")
        expect(recorder.all.filter { $0 == "reachMembers" }.count == 2 && !recorder.all.contains("unpair"), "change model after ✗: \(recorder.all)")
        transcript("leader-change-model-after-not-serving", run.text, keys: run.keys)
    }

    // MARK: - Stopped, and switching how it serves

    /// Gemma 4 26B stopped, last served in tensor parallel (its measured pipeline is the list's default otherwise).
    static let gemmaStopped: ClusterOnboardingResume = {
        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false, modelName: "gemma-4-26b-qat-4bit")
        resume.modelTitle = "Gemma 4 26B"
        resume.servingMode = "tensor_parallel_v1"
        return resume
    }()

    /// A stopped pair (UX audit P1, "How do I start it again?"): its last model marked "last used" and preselected; enter
    /// starts it again in the mode it served in, ending like `darkbloom start`. The scope line starts it that way.
    static func stoppedPairPreselectsTheLastModel() {
        typealias D = ClusterOnboardingDriver
        let stoppedStatus = ["Stopped; last model Gemma 4 26B."]
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: gemmaStopped, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            statusLines: stoppedStatus))
        expect(run.waitFor(prompt(4, enter: 2)), "stopped: the list, the last model preselected")
        expect(run.text.contains("  Stopped; last model Gemma 4 26B.\n\nModel\n  1) Qwen 3.8 27B · 16.3 GB · tensor parallel\n"
            + "  2) Gemma 4 26B · 15.6 GB · pipeline or tensor parallel · last used\n"
            + "  3) Switch to local only (this Mac's API, no Darkbloom traffic)\n  4) Start over (unpair and set up again)\n"), "stopped: \(run.text)")
        run.type("\r")
        expect(run.waitFor("  " + D.modeQuestion(model: "Gemma 4 26B") + "\n  1) " + D.modeLine(switchChoices[1].modes![0]) + "\n  2) "
            + D.modeLine(switchChoices[1].modes![1]) + "\n  " + prompt(2)), "stopped: the mode it served in, preselected: \(run.text)")
        run.type("\r")
        expect(run.finish() == 0, "stopped: started")
        let mode = recorder.all.firstIndex(of: "useMode 1 tensor_parallel_v1"), adopted = recorder.all.firstIndex(of: "adopt 1")
        expect(mode != nil && adopted != nil && mode! < adopted! && recorder.all.contains("serve"), "stopped: tensor parallel kept, then started: \(recorder.all)")
        expect(run.text.contains(startedLogs) && run.text.hasSuffix(commandLines) && !run.text.contains(D.switchAnswers[0]),
               "stopped: nothing to confirm; the card: \(run.text)")
        transcript("leader-stopped-start-again", run.text, keys: run.keys)

        let local = Recorder()
        let switched = TerminalRun(operations(local, resume: gemmaStopped, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            statusLines: stoppedStatus))
        expect(switched.waitFor(prompt(4, enter: 2)), "stopped, local: the list"); switched.type("3")
        expect(switched.finish() == 0, "stopped, local: started")
        expect(Array(local.all.prefix(5)) == ["ensureService", "status", "reachMembers", "planModels", "setScope local 0.0.0.0"]
            && local.all.contains("useMode 1 tensor_parallel_v1") && local.all.contains("serve"), "stopped, local: saved, then started locally: \(local.all)")
        expect(switched.text.contains("  Local:   http://localhost:"), "stopped, local: the local address in the card: \(switched.text)")
    }

    /// P8a (0.10.8 must-have): the list's switch to serving through Darkbloom checks both logins before it stops the
    /// working local API (2026-11-04 audit: it stopped the local API, then said "not logged in"); Cancel changes nothing.
    static func switchToDarkbloomChecksLoginsFirst() {
        var local = qwenServing
        local.scope = .localOnly(bind: "0.0.0.0")
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: local, pairEvents: [], pairResult: .failed([]), choices: switchChoices,
            missingLogins: [ClusterOnboardingMacName.this]))
        expect(run.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "logins first: the scope line"); run.type("3")
        expect(run.waitFor("  " + ClusterOnboardingNotServing.notLoggedIn([ClusterOnboardingMacName.this]) + ".\n  1) Log in on this Mac\n  2) Serve locally only\n  3) Cancel\n"),
               "logins first: who is not logged in, before anything changes: \(run.text)")
        run.type("3")
        expect(run.finish() == 0, "logins first: Cancel leaves")
        expect(run.text.hasSuffix("Nothing changed: the pair keeps serving locally only.\n"), "logins first: nothing changed: \(run.text)")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels"], "logins first: the local API never stopped: \(recorder.all)")
    }

    // MARK: - The Mac that joined follows the start; the registration in plain words (owner O8, A1, 2026-11-04)

    static let leaderName = "Apple M5 Ultra, 256 GB"
    static let leaderNamed = ClusterOnboardingMacName.other(named: leaderName)

    /// A Mac that joins, its window kept open through the start as `statusSequence` tells it.
    static func joining(_ recorder: Recorder, statusSequence: [[String]],
                        pairServingResults: [Result<[String], ClusterOnboardingFailure>] = [.failure(.init("not asked in this check"))],
                        followSeconds: Double = 900,
                        testResult: Result<[String], ClusterOnboardingFailure> = .success(["in 0.61 s"]),
                        localNetwork: @escaping @Sendable (ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork = { _ in .allowed })
        -> TerminalRun {
        TerminalRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName),
                               testResult: testResult, localNetwork: localNetwork, pairServingResults: pairServingResults,
                               statusSequence: statusSequence, followSeconds: followSeconds))
    }

    /// The leader's status line while its start still asks Darkbloom whether to offer the pair (`registrationPendingPID`
    /// in the record the leader publishes): a start, not its outcome.
    static let offerPendingLine = ClusterOnboardingReady.offerPendingLine(model: "Qwen 3.8 27B")

    /// Both windows tell the same truth: a leader that offers the pair late (its start's check with Darkbloom outlasting
    /// any wait) never gives the Mac that joined an early ✓. It follows until the pair's own wait settles, then shows the
    /// leader's ✗ (or ✓). Failing first on a63798006 (a 30 s hold, then ✓ from the API's serving line).
    static func aLateOfferNeverGivesTheJoinedMacAnEarlyTick() {
        let recorder = Recorder()
        let late = [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."]] + Array(repeating: [offerPendingLine], count: 30)
            + [["Qwen 3.8 27B: registering both Macs with the coordinator for pairing."],
               [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: notVerifiedTimed)]]
        // f2 (0.10.9 DevNet, pair-2): Apple's verification clears by itself, so the joining Mac never judges by it; an older
        // leader that publishes no outcome ends at the bound with what is known, never Retry it can't see.
        let run = joining(recorder, statusSequence: late, pairServingResults: [.failure(.init(notVerifiedTimed))], followSeconds: 10)
        expect(run.waitFor(codeQuestion), "late offer: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 1, "late offer: not serving is not success")
        let text = run.text
        expect(!text.contains("\u{2713} Serving") && !recorder.all.contains("testRequest"), "late offer: never an early ✓, nothing tested: \(text)")
        expect(text.contains("  " + ClusterOnboardingReady.offeredLine(model: "Qwen 3.8 27B") + "\n")
            && text.contains("\u{2717} Not serving: " + ClusterOnboardingDriver.noOutcomeReason(leaderName, seconds: 10) + ".\n"),
               "late offer: offered, then the honest ✗: \(text)")
        expect(!text.contains("Choose Retry") && !recorder.all.contains("pairServing"), "late offer: no Retry, no verdict of its own: \(text)")
        transcript("member-late-offer", text, keys: run.keys)
    }

    /// O8, ✓: the Mac that joined waits for the leader's start, follows it and ends with the same ✓ block, then says the
    /// window may close. Never "Done here" right after pairing.
    static func joinedMacFollowsTheStartToServing() {
        let served = "Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."], ["Stopped."], ["Starting Qwen 3.8 27B."],
                                                      ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [served]])
        expect(run.waitFor(codeQuestion), "follow ✓: the code"); run.type("y")
        expect(run.finish() == 0, "follow ✓: exit 0")
        let text = run.text
        expect(text.contains("  \u{2713} Paired. The other Mac leads.\n\n  " + ClusterOnboardingDriver.waitingForStartLine(leaderName) + "\n"),
               "follow ✓: what it waits for, right after pairing: \(text)")
        expect(text.hasSuffix(block("\u{2713}", String(served.dropLast()), []) + ClusterOnboardingDriver.closeWindowLine + "\n"),
               "follow ✓: the outcome block, then the window may close: \(text)")
        expect(!text.contains("Done here"), "follow ✓: never Done here: \(text)")
        expect(recorder.all.filter { $0 == "status" }.count == 5 && !recorder.all.contains("testRequest"),
               "follow ✓: followed the status until it served (the pair answered its own first request): \(recorder.all)")
        transcript("member-follows-start-served", text, keys: run.keys)

        // Serving on the leading Mac's API, its start done (no check with Darkbloom pending): tested at once, no hold.
        let local = Recorder()
        let api = joining(local, statusSequence: [["Stopped."], ["Serving Qwen 3.8 27B (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)."]])
        expect(api.waitFor(codeQuestion), "follow ✓ API: the code"); api.type("y")
        expect(api.finish() == 0, "follow ✓ API: exit 0")
        expect(api.text.hasSuffix(block("\u{2713}", "Serving Qwen 3.8 27B (pipeline) at http://localhost:8000 on the other Mac (earning through Darkbloom)",
            ["Test response in 0.61 s"]) + ClusterOnboardingDriver.closeWindowLine + "\n"), "follow ✓ API: tested, then the block: \(api.text)")
        expect(local.all.filter { $0 == "status" }.count >= 2 && local.all.last == "testRequest", "follow ✓ API: tested: \(local.all)")

        // The leader offers the pair to Darkbloom after its test: no ✓ while its serving line says the check is pending;
        // the pair's own wait.
        let offered = Recorder()
        let pair = joining(offered, statusSequence: [["Stopped."], [offerPendingLine],
            ["Stopped; last model Qwen 3.8 27B."], ["Qwen 3.8 27B: registering both Macs with the coordinator for pairing."],
            [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "waiting for the coordinator to pair both Macs")], [served]],
            pairServingResults: [.success(["in 0.84 s"])])
        expect(pair.waitFor(codeQuestion), "follow offered: the code"); pair.type("y")
        expect(pair.finish() == 0, "follow offered: exit 0")
        expect(pair.text.contains("  " + ClusterOnboardingReady.offeredLine(model: "Qwen 3.8 27B") + "\n"), "follow offered: said in plain words: \(pair.text)")
        expect(pair.text.hasSuffix(block("\u{2713}", String(served.dropLast()), []) + ClusterOnboardingDriver.closeWindowLine + "\n"),
               "follow offered: the leader's ✓ block: \(pair.text)")
        expect(pair.text.components(separatedBy: "\u{2713} Serving").count == 2 && !offered.all.contains("testRequest") && !offered.all.contains("pairServing"),
               "follow offered: one ✓, the leader's, no wait of its own: \(offered.all)")
        transcript("member-follows-start-offered", pair.text, keys: pair.keys)
    }

    /// O8, ✗: the same ✗ block as the leader's, then where to act (the choices are on the leader's screen).
    static func joinedMacFollowsTheStartToNotServing() {
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."],
            [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "waiting for the coordinator to pair both Macs")]],
            pairServingResults: [.failure(.init(notVerifiedTimed))], followSeconds: 1)
        expect(run.waitFor(codeQuestion), "follow ✗: the code"); run.type("y")
        expect(run.finish() == 1, "follow ✗: not serving is not success")
        let text = run.text
        // The leading Mac said no outcome (an older leader): the bound's ✗ with what is known, never a verdict of its own
        // (f2) and never Retry its screen may not show; the leader's own ✗ is `followFinalOutcomeChecks`.
        expect(text.hasSuffix(block("\u{2717}", ClusterOnboardingNotServing.title(reason: ClusterOnboardingDriver.noOutcomeReason(leaderName, seconds: 1)),
            ["Last: Qwen 3.8 27B is not serving yet: waiting for the coordinator to pair both Macs.", ClusterOnboardingDriver.noOutcomeLine])),
               "follow ✗: the honest ✗, then where to look: \(text)")
        expect(ClusterOnboardingDriver.retryOnLeaderLine(leaderName) == "Choose Retry on \(leaderNamed): its screen shows the choices.",
               "follow ✗: the leader by name")
        expect(!text.contains("\u{2713} Serving") && !text.contains(ClusterOnboardingDriver.closeWindowLine), "follow ✗: never ✓: \(text)")
        transcript("member-follows-start-not-serving", text, keys: run.keys)
    }

    /// O8: q leaves (the pair keeps going), and the follow is bounded as the leader's start; never silent.
    static func joinedMacLeavesOrStopsFollowingSaying() {
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."]])
        expect(run.waitFor(codeQuestion), "follow q: the code"); run.type("y")
        expect(run.waitFor(ClusterOnboardingDriver.waitingForStartLine(leaderName)), "follow q: waiting")
        _ = run.waitFor("never shown", seconds: 0.5)
        expect(run.code == nil, "follow q: the window stays open while the leader chooses")
        run.type("q")
        expect(run.finish() == 0, "follow q: exit 0")
        expect(run.text.hasSuffix(ClusterOnboardingDriver.waitingForStartLine(leaderName) + "\n" + ClusterOnboardingDriver.followLeftLine + "\n"),
               "follow q: the pair keeps going, last: \(run.text)")
        expect(ClusterOnboardingDriver.followLeftLine == "The pair keeps going; run `darkbloom cluster` here to see it.", "follow q: the words")
        transcript("member-follows-start-q", run.text, keys: run.keys)

        let waited = joining(Recorder(), statusSequence: [["Stopped."]], followSeconds: 0.6)
        expect(waited.waitFor(codeQuestion), "follow bound: the code"); waited.type("y")
        expect(waited.finish() == 1, "follow bound: ends, not success")
        expect(waited.text.hasSuffix(block("\u{2717}", ClusterOnboardingNotServing.title(reason: ClusterOnboardingDriver.notStartedReason(leaderName, seconds: 0.6)),
            ClusterOnboardingDriver.notStartedLines(leaderName, step: nil, status: "Stopped")) + ClusterOnboardingDriver.notStartedAfterLine + "\n"),
               "follow bound, not started: ✗ with the last status and what to do: \(waited.text)")
        let stuck = joining(Recorder(), statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."]], followSeconds: 0.6)
        expect(stuck.waitFor(codeQuestion), "follow bound, started: the code"); stuck.type("y")
        expect(stuck.finish() == 1, "follow bound, started: not success")
        expect(stuck.text.contains("\u{2717} Not serving: " + ClusterOnboardingDriver.noOutcomeReason(leaderName, seconds: 0.6)
                + ".\n  Last: Loading Qwen 3.8 27B: 1 of 2 parts ready.\n  " + ClusterOnboardingDriver.noOutcomeLine + "\n")
            && !stuck.text.contains("Choose Retry"), "follow bound, started: ✗ with the last state: \(stuck.text)")
    }

    /// The leader's status once its start's test request failed (`startTestFailure`): that start's outcome.
    static func testFailedStatus(_ reason: String) -> [String] {
        [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: reason), ClusterOnboardingReady.testFailedNote]
    }

    /// Both windows end alike when the leader's start test fails: the leader publishes that outcome instead of clearing
    /// its pending mark, so the Mac that joined shows the same ✗ and reason, sends no test of its own, and says where to
    /// test again (the leader's own ending: "Setup saved, but the test failed. To test again, …"). Exit 1 on both.
    /// Failing first on a148285f70 (the mark cleared, then ✓ from the joined Mac's own test).
    /// Validator D's re-check at 7a0e398921 (the owner's rule: both windows tell the same truth). P3c: a local-only
    /// leader's start was not marked, so its failed test was not published, and the joining Mac's own test passed: ✓
    /// here, "the test failed" there. P3d: the leader passed, the joining Mac's own test failed: ✗ here. The joining Mac
    /// now ends with the leader's published outcome for the start, ✓ with the leader's response time or ✗ with its
    /// reason, and sends no test of its own.
    static let localTestingLine = "Starting Qwen 3.8 27B: loaded on both Macs; the leading Mac is testing it."
    static let localServingLine = "Serving Qwen 3.8 27B (pipeline) at http://localhost:8000 (local only)."
    static let leadersTestLine = "Test response in 0.61 s (the leading Mac's test)"

    /// The pair-2 DevNet run (P2-1): the joining Mac's Local Network step passed (its service's broadcast probe said
    /// allowed), then macOS refused its follower's dial once the leader started, and its window said nothing. It now says
    /// so, and what to do on that Mac.
    static func theJoiningMacSaysWhenItsServiceIsKeptOffTheLocalNetwork() {
        let flip = LocalNetworkFlip(allowedCalls: 1)
        let run = joining(Recorder(), statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."],
                                                       ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."],
                                                       [localServingLine, leadersTestLine]], localNetwork: { flip.state($0) })
        expect(run.waitFor(codeQuestion), "P2-1, joining: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 0, "P2-1, joining: the start still ends with the leader's")
        // R4-4: the row macOS lists, and what to do where it lists none.
        let said = "  This Mac can't reach the other Mac over the cable: macOS keeps Darkbloom off the local network.\n"
            + "  On this Mac: System Settings → Privacy & Security → Local Network → turn on “Darkbloom”; if it isn't listed, click "
            + "Allow when macOS asks on this Mac's screen, the next time Darkbloom dials over the cable (on a Mac with no display, "
            + "through Screen Sharing); the start goes on by itself once it's on.\n"
        expect(run.text.contains(said) && run.text.components(separatedBy: said).count == 2, "P2-1, joining: said once, plainly: \(run.text)")
    }

    /// The pair-2 DevNet run (P2-7): the joining Mac's window showed nothing while the leader sat at ✗. It says each new
    /// state of the leader's start, and where to choose Retry when a part keeps ending there.
    static func theJoiningMacShowsTheLeadersStateWhileItWaits() {
        let ending = "Loading Qwen 3.8 27B: 1 of 2 parts ready (this Mac's part ended (exit 1: boom) and starts again by itself)."
        let run = joining(Recorder(), statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [ending], [ending],
                                                       [localServingLine, leadersTestLine]])
        expect(run.waitFor(codeQuestion), "P2-7: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 0, "P2-7: ends with the leader's ✓")
        // Retry is pointed to only in a final ✗ the leading Mac's screen shows (f2's rule): the part starts again by itself.
        expect(run.text.contains("  The other Mac: " + String(ending.dropLast()) + ".\n")
               && !run.text.contains("Choose Retry"), "P2-7: the leader's state, and no Retry mid-start: \(run.text)")
    }

    /// The pair-2 DevNet run (P2-4): after the pair was stopped (`cluster stop --service` on the member), Retry in the ✗
    /// only waited for parts nothing would start, silently, for 5+ minutes, and q was ignored. Retry starts a stopped pair
    /// again and says so; q leaves the wait at once, with a line.
    static func retryStartsAStoppedPairAndQLeavesTheWait() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), statusLines: ["Stopped."],
            readyResults: [.failure(.init(["A part keeps ending the same way: this Mac's part ended (exit 1: boom) and starts again by itself."])),
                           .success(localReady)]))
        expect(run.waitFor(prompt(2)), "P2-4: the list"); run.type("\r")
        expect(run.waitFor(notServingChoices), "P2-4: the ✗ and its choices"); run.type("1")
        expect(run.finish(seconds: 20) == 0, "P2-4: Retry served")
        expect(run.text.contains("  The pair is stopped: starting both Macs again.\n"), "P2-4: says it starts the pair: \(run.text)")
        expect(recorder.all.filter { $0 == "serve" }.count == 2, "P2-4: started again: \(recorder.all)")
        let waiting = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyReports: ["1 of 2 parts ready"], readyReportPause: 20_000_000), environment: colourTerminal)
        expect(waiting.waitFor(arrowHint), "P2-4, q: the list"); waiting.type("\r")
        expect(waiting.waitFor("1 of 2 parts ready"), "P2-4, q: the wait")
        waiting.type("q")
        expect(waiting.finish(seconds: 5) == 1, "P2-4, q: left at once")
        expect(waiting.text.contains("Left the start: the pair keeps starting by itself; run `darkbloom cluster` again to see how it is going.\n"),
               "P2-4, q: the line: \(waiting.text)")
    }

    static func theJoiningMacMirrorsALocalStartsFailedTest() {
        let reason = "The test request got an empty answer"
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [localTestingLine],
                                                     [localTestingLine],
                                                     [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: reason),
                                                      "Setup saved, but the test failed."]],
                          testResult: .success(["in 0.61 s"]))
        expect(run.waitFor(codeQuestion), "P3c: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 1, "P3c: not success, as the leader's exit 1")
        let text = run.text
        expect(text.hasSuffix(block("\u{2717}", "Not serving: " + reason + ".", ["Setup saved, but the test failed."])
            + ClusterOnboardingDriver.testAgainOnLeaderLine(leaderName) + "\n"), "P3c: the leader's ✗ and reason: \(text)")
        expect(!text.contains("\u{2713} Serving") && !recorder.all.contains("testRequest"), "P3c: no ✓, no test of its own: \(recorder.all)")
        transcript("member-mirrors-local-failed-test", text, keys: run.keys)
        expect(ClusterOnboardingDriver.followed([ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: reason),
                                                 ClusterOnboardingReady.lastTestFailedNote]) == .testFailed,
               "the latest test's failure is a published outcome too")
    }

    static func theJoiningMacMirrorsTheLeadersPass() {
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [localTestingLine],
                                                     [localServingLine, leadersTestLine]],
                          testResult: .failure(.init("The test request got an empty answer.")))
        expect(run.waitFor(codeQuestion), "P3d: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 0, "P3d: success, as the leader's exit 0")
        let text = run.text
        expect(text.contains("\u{2713} Serving Qwen 3.8 27B (pipeline) at http://localhost:8000") && text.contains("  " + leadersTestLine + "\n")
               && !text.contains("\u{2717}"), "P3d: the leader's ✓ and response time: \(text)")
        expect(!recorder.all.contains("testRequest"), "P3d: no test of its own: \(recorder.all)")
        transcript("member-mirrors-leaders-pass", text, keys: run.keys)
        // A leader on an older build publishes no outcome: the joining Mac tests the pair itself, as before.
        let older = Recorder()
        let fallback = joining(older, statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [localServingLine]])
        expect(fallback.waitFor(codeQuestion), "older leader: the code"); fallback.type("y")
        expect(fallback.finish(seconds: 20) == 0 && older.all.contains("testRequest"), "older leader: its own test, as before: \(older.all)")
    }

    static func aFailedStartTestEndsTheJoinedMacTheSame() {
        let reason = "The test request got an empty answer"
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: [["Stopped."], ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], [offerPendingLine],
                                                      [offerPendingLine], testFailedStatus(reason)])
        expect(run.waitFor(codeQuestion), "failed test, joined: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 1, "failed test, joined: not success, as the leader's exit 1")
        let text = run.text
        expect(text.hasSuffix(block("\u{2717}", "Not serving: " + reason + ".", [ClusterOnboardingReady.testFailedNote])
            + ClusterOnboardingDriver.testAgainOnLeaderLine(leaderName) + "\n"), "failed test, joined: the leader's reason, then where to test again: \(text)")
        expect(!text.contains("\u{2713} Serving") && !recorder.all.contains("testRequest") && !recorder.all.contains("pairServing"),
               "failed test, joined: no ✓, no test of its own: \(recorder.all)")
        expect(ClusterOnboardingDriver.followed(testFailedStatus(reason)) == .testFailed
               && ClusterOnboardingDriver.followed([ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: reason)]) == .offered,
               "failed test: only the leader's note makes a not-serving line the start's outcome")
        transcript("member-start-test-failed", text, keys: run.keys)

        // The leader's own window, the same start: the reason, then "Setup saved, but the test failed", exit 1.
        let leader = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                                            testResult: .failure(.init(reason + "."))))
        expect(leader.waitFor(codeQuestion), "failed test, leader: the code"); leader.type("y")
        expect(leader.waitFor(prompt(2), count: 2), "failed test, leader: the list"); leader.type("\r")
        expect(leader.finish(seconds: 20) == 1, "failed test, leader: exit 1")
        expect(leader.text.contains("  " + reason + ".\n") && leader.text.contains("Setup saved, but the test failed.")
               && !leader.text.contains("\u{2713} Serving"), "failed test, leader: the same reason, no ✓: \(leader.text)")
    }

    /// Only the screen's start through Darkbloom, which asks the coordinator after its test (`register`), marks itself
    /// pending, after its serve and before its wait. `serve` alone (as `darkbloom start` and `restart` run it) never
    /// does. The switch to Darkbloom is such a start since the DevNet traffic run (2026-11-04): it marks itself once
    /// and registers. Failing first on a148285f70 (the serve itself marked).
    static func onlyTheStartThatRegistersMarksItself() {
        let recorder = Recorder()
        var start = operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
        start.markRegistrationPending = { recorder.note("markRegistrationPending") }
        let run = TerminalRun(start)
        expect(run.waitFor(codeQuestion), "mark: the code"); run.type("y")
        expect(run.waitFor(prompt(2), count: 2), "mark: the list"); run.type("\r")
        expect(run.finish(seconds: 20) == 0, "mark: the start serves")
        let calls = recorder.all
        let at = { (name: String) in calls.firstIndex(of: name) ?? -1 }
        expect(calls.filter { $0 == "markRegistrationPending" }.count == 1 && at("serve") < at("markRegistrationPending")
               && at("markRegistrationPending") < at("waitReady") && at("waitReady") < at("register"),
               "mark: once, between the serve and the wait, before the registration: \(calls)")

        var resume = ClusterOnboardingResume(role: .leader, peerName: "Apple M4 Max, 128 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        resume.scope = .localOnly(bind: "0.0.0.0")
        let switched = Recorder()
        var scope = operations(switched, resume: resume, pairEvents: [], pairResult: .failed([]))
        scope.markRegistrationPending = { switched.note("markRegistrationPending") }
        let toDarkbloom = TerminalRun(scope)
        expect(toDarkbloom.waitFor("  3) Switch to serving through Darkbloom (both Macs logged in)\n"), "mark, scope: the list"); toDarkbloom.type("3")
        expect(toDarkbloom.finish(seconds: 20) == 0, "mark, scope: switched")
        let step = { (name: String) in switched.all.firstIndex(of: name) ?? -1 }
        expect(switched.all.filter { $0 == "markRegistrationPending" }.count == 1 && step("serve") < step("markRegistrationPending")
               && step("markRegistrationPending") < step("waitReady") && step("testRequest") < step("register"),
               "mark, scope: the switch to Darkbloom is a start: marked once after its serve, then tested and registered: \(switched.all)")
    }

    /// While the leader's start checks with Darkbloom, `darkbloom cluster` on either Mac shows that as a start, never ✓
    /// (the follow already treated it as unfinished). Failing first on a148285f70 (✓ from readiness alone).
    static func thePendingCheckIsNoTickOnAnyScreen() {
        let recorder = Recorder()
        let member = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([]), statusLines: [offerPendingLine]))
        expect(member.waitFor(prompt(2)), "pending, member: the screen"); member.type("\r")
        expect(member.finish() == 0, "pending, member: closes")
        expect(!member.text.contains("\u{2713}") && member.text.contains("  " + offerPendingLine + "\n"),
               "pending, member: the start's line, no ✓: \(member.text)")
        expect(ClusterOnboardingDriver.followed([offerPendingLine]) == .starting, "pending: the follow keeps following")
        // A leader on the first build with the mark said it inside a serving line: no ✓ for that either.
        let older = "Serving Qwen 3.8 27B (pipeline) at http://localhost:8000 on the other Mac (" + ClusterOnboardingReady.offerPendingWords + ")."
        let screen = TerminalRun(operations(Recorder(), resume: memberResume(), pairEvents: [], pairResult: .failed([]), statusLines: [older]))
        expect(screen.waitFor(prompt(2)), "pending, serving line: the screen"); screen.type("\r")
        expect(screen.finish() == 0 && !screen.text.contains("\u{2713}"), "pending, serving line: no ✓: \(screen.text)")
        transcript("member-status-while-the-start-checks", member.text, keys: member.keys)
    }

    /// The Mac that joined bounds each stage of the leader's start as the leader does (loading, then the test and the
    /// check with Darkbloom, then the registration's restart), not the whole start at once. A stage that never moves on
    /// still ends at the bound, and a status going back and forth inside one stage never starts it again.
    /// Failing first on a148285f70 (one bound across all stages).
    static func eachStageOfTheStartHasItsOwnBound() {
        let served = "Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."
        let stage = 8
        let stages = [["Stopped."]] + Array(repeating: ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], count: stage)
            + Array(repeating: [offerPendingLine], count: stage)
            + Array(repeating: ["Qwen 3.8 27B: registering both Macs with the coordinator for pairing."], count: stage)
            + [[ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "waiting for the coordinator to pair both Macs")], [served]]
        let recorder = Recorder()
        let run = joining(recorder, statusSequence: stages, pairServingResults: [.success(["in 0.84 s"])], followSeconds: 2.5)
        expect(run.waitFor(codeQuestion), "stages: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 0, "stages: each within its bound, the whole start longer: serves: \(run.text)")
        expect(recorder.all.filter { $0 == "status" }.count > 3 * stage && !recorder.all.contains("pairServing"),
               "stages: followed through every stage to the leader's ✓: \(recorder.all.count)")

        var flapping = [["Stopped."]]
        for _ in 0..<60 { flapping += [["Loading Qwen 3.8 27B: 1 of 2 parts ready."], ["Stopped."]] }
        let stuck = joining(Recorder(), statusSequence: flapping, followSeconds: 0.6)
        expect(stuck.waitFor(codeQuestion), "stages, back and forth: the code"); stuck.type("y")
        expect(stuck.finish(seconds: 30) == 1 && stuck.text.contains("\u{2717} Not serving: " + ClusterOnboardingDriver.noOutcomeReason(leaderName, seconds: 0.6)),
               "stages, back and forth: one stage, so its bound ends it: \(stuck.text)")
    }

    /// A1: the registration reads as offered, not accepted; the log line and the matcher stay as they were.
    static func registrationIsSaidAsOfferedNotAccepted() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), choices: [ClusterOnboardingModelChoice(title: "Qwen 3.8 27B", lines: ["16.3 GB · pipeline"], blocker: nil, validated: true)],
            registerResult: .success([registeredLine])))
        expect(run.waitFor(prompt(1)), "offered: the list"); run.type("\r")
        _ = run.finish()
        let text = run.text
        expect(text.contains("  Offered to Darkbloom as a pair for Qwen 3.8 27B; waiting for Darkbloom to accept this pair\u{2026}\n"
            + "Starting both Macs' parts again as cluster members\u{2026}\n"), "offered: plain words, then the restart (the matcher still knows it): \(text)")
        expect(!text.contains(ClusterOnboardingReady.registeredNotice) && !text.contains("approval release/") && !text.contains("2027-02-01T"),
               "offered: no approval id, no date, no 'Registered': \(text)")
        expect(ClusterOnboardingReady.registeredNotice == "Registered with the coordinator as a cluster member"
            && offeredLogLine == "Notice: Registered with the coordinator as a cluster member with an installed cluster approval",
               "offered: the log line and the matcher are unchanged")
        transcript("leader-registration-offered", text, keys: run.keys)
    }
}

/// A service's Local Network state that turns blocked after the first `allowedCalls` checks (its follower refused later).
final class LocalNetworkFlip: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let allowedCalls: Int
    init(allowedCalls: Int) { self.allowedCalls = allowedCalls }
    func state(_ subject: ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork {
        guard subject == .service else { return .allowed }
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls <= allowedCalls ? .allowed : .blocked
    }
}
