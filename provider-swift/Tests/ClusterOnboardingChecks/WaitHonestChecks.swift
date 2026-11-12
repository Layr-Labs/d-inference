import Foundation
import Darwin

/// The leader's wait for the coordinator, on real hardware (pair-2, DevNet branch.81/82, 2026-11-05): its 15-minute ✗
/// blamed Apple verification on two authorized Macs (the coordinator refused `serves_model`); q did nothing in it and a
/// `cluster stop` elsewhere left it waiting; and the joining Mac showed "This Mac runs its part by itself … Close"
/// through the leader's model change (R5-8).
extension OnboardingChecks {
    static func waitHonestChecks() {
        theCoordinatorsWaitNamesOnlyWhatTheMacsReportNow()
        aStaleTrustWordOnVerifiedMacsIsTheCoordinators()
        qLeavesTheCoordinatorsWaitAndSaysWhatKeepsGoing()
        aStopFromAnywhereEndsTheLeadersWaitAtOnce()
        aStopFromAnywhereEndsTheJoiningMacsWait()
        theJoiningMacFollowsTheLeadersModelChange()
        // An external pair on 0.10.12 (2026-11-12): the joining Mac said the stop line 20 s into a download nobody stopped.
        aStatusThatReadsStoppedThroughADownloadIsNoStop()
        aStopIsTheLeadersRecordNeverItsStatusWords()
        aStopBeforeTheStartIsNoStopOfIt()
        aStopDuringTheDownloadEndsTheJoiningMacsWaitAtOnce()
        aStopDuringTheDownloadKeepsThePairStopped()
        aStopFromAnywhereEndsTheLeadersLoadAtOnce()
        thePairsOwnStopsNeverEndTheLeadersWait()
        aStopDuringTheTestEndsTheLeadersScreen()
        aStartRefusedForAStopEndsTheScreen()
        aStopDuringTheSoloQuestionKeepsThePairStopped()
        retryIsANewStart()
    }

    static func theCoordinatorsWaitNamesOnlyWhatTheMacsReportNow() {
        let unverified = ClusterOnboardingNotServing.notVerified("the other Mac (Apple M5 Max, 128 GB)")
        var wait = ClusterOnboardingPairWait(started: 0, bound: 900, settle: 90)
        // A new key's authorization is missing for a minute after registering, then lands: nothing ends the wait.
        expect(wait.look(reason: unverified, holds: false, now: 30) == nil, "coordinator wait: a reason within the settle waits")
        expect(wait.look(reason: nil, holds: false, now: 120) == nil, "coordinator wait: nothing reported, still waiting")
        // At the bound, both Macs registered and authorized: the coordinator didn't pair them, never Apple.
        let end = wait.look(reason: nil, holds: false, now: 900)
        expect(end == "The coordinator didn't pair both Macs within 15 minutes; both are registered with it, and it gave no reason",
               "coordinator wait: the bound says the coordinator didn't pair them: \(end ?? "nil")")
        expect(!(end ?? "").contains("Apple"), "coordinator wait: Apple is never named when no Mac reports it")
        // A reason the Macs report now still ends it, after the settle; one only a person mends at once.
        var now = ClusterOnboardingPairWait(started: 0)
        expect(now.look(reason: unverified, holds: false, now: 95) == unverified, "coordinator wait: a reported reason after the settle")
        var login = ClusterOnboardingPairWait(started: 0)
        expect(login.look(reason: "This Mac isn't logged in to Darkbloom", holds: true, now: 1) != nil, "coordinator wait: a login at once")
        // The coordinator's reason when the Macs know it (a catalog refusal, PR #1799) is the bound's ✗.
        var known = ClusterOnboardingPairWait(started: 0, bound: 900, settle: 1_000)
        _ = known.look(reason: "The coordinator does not pair Macs for gemma-4-26b-qat-4bit: its model catalog does not list it",
                       holds: false, now: 10)
        expect(known.timedOut.hasPrefix("The coordinator does not pair Macs for gemma"), "coordinator wait: the coordinator's own reason")
    }

    static func aStaleTrustWordOnVerifiedMacsIsTheCoordinators() {
        let verified = ClusterOnboardingNotServing.words(reason: "liveness:private_text", mac: "one of the Macs", anyUnverified: false)
        expect(!verified.contains("Apple yet") && verified.contains("The coordinator didn't accept the pair yet (liveness:private_text)"),
               "trust word, both verified: the coordinator's: \(verified)")
        let unverified = ClusterOnboardingNotServing.words(reason: "liveness:private_text", mac: "one of the Macs", anyUnverified: true)
        expect(unverified.contains("isn't verified by Apple yet"), "trust word, a Mac unverified: Apple: \(unverified)")
        expect(ClusterOnboardingNotServing.words(reason: "serves_model", mac: "one of the Macs", anyUnverified: false)
               == ClusterOnboardingNotServing.words(reason: "serves_model", mac: "one of the Macs"), "other words unchanged")
    }

    /// The leader whose pair is offered, waiting for the coordinator; `pairServing` runs as given.
    static func coordinatorWait(_ recorder: Recorder,
                                pairServing: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure>)
        -> ClusterOnboardingOperations {
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [],
                              pairResult: .failed([]), readyResult: .success(offeredReady))
        made.pairServing = pairServing
        return made
    }

    static func qLeavesTheCoordinatorsWaitAndSaysWhatKeepsGoing() {
        let recorder = Recorder()
        let run = TerminalRun(coordinatorWait(recorder) { progress in
            progress("waiting for the coordinator to pair both Macs\nThis Mac: registered; waiting for the coordinator")
            sleep(30)
            return .failure(.init("not reached"))
        })
        expect(run.waitFor(prompt(2)), "coordinator q: the list"); run.type("\r")
        expect(run.waitFor("registered; waiting for the coordinator"), "coordinator q: the wait: \(run.text)")
        run.type("q")
        expect(run.finish(seconds: 5) == 1, "coordinator q: left at once")
        expect(run.text.contains("Left the wait: both Macs stay registered and the pair keeps trying to be paired by the coordinator "
               + "by itself. Check with `darkbloom status`."), "coordinator q: what keeps going, and how to check: \(run.text)")
        expect(!run.text.contains(notServingChoices), "coordinator q: no ✗ or Retry")
    }

    /// A `darkbloom cluster stop` while the leading Mac waits for the coordinator: the count grows (`stopsAsked`), and the
    /// screen ends at once, while the wait itself would go on for minutes.
    static func aStopFromAnywhereEndsTheLeadersWaitAtOnce() {
        let recorder = Recorder(), waiting = Recorder()
        var made = coordinatorWait(recorder) { progress in
            waiting.note("pairServing")
            progress("waiting for the coordinator to pair both Macs\nThis Mac: registered; waiting for the coordinator")
            sleep(30)
            return .failure(.init("not reached"))
        }
        made.stopsAsked = { waiting.all.isEmpty ? 4 : 5 }
        let run = TerminalRun(made)
        expect(run.waitFor(prompt(2)), "leader stop: the list"); run.type("\r")
        expect(run.finish(seconds: 10) == 1, "leader stop: ended")
        expect(run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more."),
               "leader stop: said plainly: \(run.text)")
        expect(!run.text.contains(notServingChoices) && !run.text.contains("registering"), "leader stop: no Retry, no rows back: \(run.text)")
    }

    /// A real `darkbloom cluster stop` while the parts load: the leading Mac counts it (`stopsAsked`), and the joining Mac
    /// ends at once with the leading Mac's line. Its record already counted two stops from an earlier day.
    static func aStopFromAnywhereEndsTheJoiningMacsWait() {
        typealias P = ClusterOnboardingStartProgress
        let loading = "Loading Qwen 3.8 27B: 1 of 2 parts ready."
        let parts = P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .loading)])
        let run = TerminalRun(followingWithStops([.init(["Stopped."], stops: 2), .init([loading], start: parts, stops: 2),
                                                  .init([loading], start: parts, stops: 2),
                                                  .init(["Stopped; last model Qwen 3.8 27B."], stops: 3)]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "joining stop: the code"); run.type("y")
        let began = Date()
        expect(run.finish(seconds: 40) == 1, "joining stop: ended, not after the bound: \(run.text)")
        expect(Date().timeIntervalSince(began) < 10, "joining stop: at once, never after a hold: \(Date().timeIntervalSince(began)) s")
        expect(run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs)"), "joining stop: the same line: \(run.text)")
    }

    /// One look of the joining Mac at the leading Mac's status: its lines, its start's progress, how many stops a person
    /// asked for there (nil: a look that read none) and the step its screen published.
    struct FollowLook: Sendable {
        var lines: [String]
        var start: ClusterOnboardingStartProgress?
        var stops: Int?
        var step: ClusterOnboardingLeaderStep?
        init(_ lines: [String], start: ClusterOnboardingStartProgress? = nil, stops: Int? = nil, step: ClusterOnboardingLeaderStep? = nil) {
            self.lines = lines; self.start = start; self.stops = stops; self.step = step
        }
    }

    /// The Mac that joined a leader whose looks say each of `looks` in turn (the last one repeats).
    static func followingWithStops(_ looks: [FollowLook]) -> ClusterOnboardingOperations {
        var made = operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName))
        let count = Recorder()
        made.leaderStatus = {
            count.note("look")
            let look = looks[min(count.all.count, looks.count) - 1]
            return .init(lines: look.lines, step: look.step, start: look.start, stopsAsked: look.stops)
        }
        return made
    }

    static func theJoiningMacFollowsTheLeadersModelChange() {
        var made = operations(Recorder(), resume: memberResume(), pairEvents: [], pairResult: .failed([]))
        let status = made.status
        made.leaderStatus = {
            .init(lines: status(), step: nil,
                  start: .init(.loading, parts: [.init(rank: 0, state: .loading), .init(rank: 1, state: .loading)]))
        }
        let run = TerminalRun(made)
        expect(run.waitFor("4/4 Start"), "model change: the joining Mac follows the start: \(run.text)")
        run.type("q")
        expect(run.finish(seconds: 5) == 0, "model change: q leaves the follow")
        expect(!run.text.contains(ClusterOnboardingDriver.memberRunsByItselfLine), "model change: not the idle member screen: \(run.text)")
    }

    /// Seconds since it was first read: a scripted leader's start runs from the joining Mac's first look.
    final class FirstLook: @unchecked Sendable {
        private let lock = NSLock()
        private var began: Date?
        var seconds: Double {
            lock.withLock {
                let now = Date()
                if began == nil { began = now }
                return now.timeIntervalSince(began!)
            }
        }
    }

    /// The report (an external pair on 0.10.12, 2026-11-12 ~20:46Z): the leading Mac downloaded the chosen model and the
    /// joining Mac's screen ended about 20 s later with "Stopped (by `darkbloom cluster stop` on one of the Macs) …",
    /// though nobody ran it. Until both parts start, the leading Mac's status reads "Stopped." (`localStatus` says so while
    /// `leadership.serving` is off, and only `localServe` turns it on): through the download and the copy, which publish
    /// their bytes, and through what comes before the start with nothing published (here a login after the download). It
    /// reads "Stopped; last model …" again while it stops both parts to register them. Each stretch lasts over 20 s, so no
    /// rule that takes "Stopped" held a while for a stop passes, whichever phases it leaves out. None of it is a stop: the
    /// joining Mac follows the start to the leading Mac's outcome.
    static func aStatusThatReadsStoppedThroughADownloadIsNoStop() {
        typealias P = ClusterOnboardingStartProgress
        let served = "Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."
        var made = operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName))
        let clock = FirstLook()
        made.leaderStatus = {
            let seconds = clock.seconds
            switch seconds {
            case ..<21:
                return .init(lines: ["Stopped."], step: .init(.copy),
                             start: P(.downloading, done: Int64(seconds / 21 * 16_300_000_000), total: 16_300_000_000))
            case ..<22:
                return .init(lines: ["Stopped."], step: .init(.copy), start: P(.copying, done: 8_000_000_000, total: 16_300_000_000))
            case ..<43:
                // After the copy and before the start (a login asked on the leading Mac's screen): no figures, "Stopped.".
                return .init(lines: ["Stopped."], step: .init(.login), start: nil)
            case ..<44:
                return .init(lines: ["Starting Qwen 3.8 27B."], step: .init(.starting),
                             start: P(.loading, parts: [.init(rank: 0, state: .starting), .init(rank: 1, state: .starting)]))
            case ..<45:
                return .init(lines: ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], step: .init(.starting),
                             start: P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .loading)]))
            case ..<66:
                // The registration stops both parts, saves the approval on each Mac and starts them again as members.
                return .init(lines: ["Stopped; last model Qwen 3.8 27B."], step: .init(.starting), start: P(.registering))
            default:
                return .init(lines: [served], step: .init(.starting), start: nil)
            }
        }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "download, no stop: the code"); run.type("y")
        let code = run.finish(seconds: 90)
        let text = run.text
        expect(text.contains("4/4 Start"), "download, no stop: the joining Mac followed the start: \(text)")
        expect(!text.contains("Stopped (by `darkbloom cluster stop`"), "download, no stop: no stop line nobody asked for: \(text)")
        expect(code == 0 && text.hasSuffix(ending("Serving Qwen 3.8 27B on both Macs")),
               "download, no stop: the leading Mac's outcome, ✓: \(String(describing: code)) \(text)")
        transcript("member-download-no-stop", text, keys: run.keys)
    }

    /// What tells a stop: the leading Mac's count of the stops a person asked for, compared with the count when the start
    /// began; never the words of its status. The start begins at the leading Mac's first step of it.
    static func aStopIsTheLeadersRecordNeverItsStatusWords() {
        let asked = ClusterOnboardingStopped.asked
        expect(!asked(nil, nil) && !asked(nil, 1) && !asked(1, nil) && !asked(1, 1) && !asked(2, 0),
               "stop asked: a count not read (an older leader, a status that couldn't be read), the same count or a lower one is no stop")
        expect(asked(0, 1) && asked(1, 3), "stop asked: a higher count is")
        var stop = ClusterOnboardingFollowedStop()
        expect(!stop.look(nil, begun: false) && !stop.look(0, begun: false) && !stop.look(1, begun: false),
               "followed stop: before the start, the latest count is the one to compare with")
        expect(!stop.look(1, begun: true) && !stop.look(nil, begun: true), "followed stop: the same count once begun, or none read, is no stop")
        expect(stop.look(2, begun: true), "followed stop: a higher count once begun ends the follow")
        var late = ClusterOnboardingFollowedStop()
        expect(!late.look(nil, begun: true) && !late.look(4, begun: true),
               "followed stop: a start already running when a count is first read compares with that count")
        expect(late.look(5, begun: true), "followed stop: then a higher one ends it")
        var remade = ClusterOnboardingFollowedStop()
        expect(!remade.look(3, begun: false) && !remade.look(0, begun: true) && remade.look(1, begun: true),
               "followed stop: a lower count (a record made again) is the one to compare with from then on")
        let kinds: [ClusterOnboardingLeaderStep.Kind] = [.localNetwork, .reading, .tryAgain, .modelList, .copy, .login, .starting, .refused, .unknown]
        let begun = kinds.filter { ClusterOnboardingLeaderStep($0).startBegun }
        expect(begun == [.copy, .starting], "the start begins at the model's transfer or the start itself: \(begun)")
    }

    /// Someone runs `darkbloom cluster stop` while the leading Mac is still at its model list (nothing runs to stop): the
    /// start that follows is no stopped one.
    static func aStopBeforeTheStartIsNoStopOfIt() {
        typealias P = ClusterOnboardingStartProgress
        let loading = P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .loading)])
        let list = ClusterOnboardingLeaderStep(.modelList)
        let run = TerminalRun(followingWithStops([.init(["Stopped."], step: list), .init(["Stopped."], stops: 0, step: list),
            .init(["Stopped."], stops: 1, step: list), .init(["Stopped."], stops: 1, step: .init(.starting)),
            .init(["Starting Qwen 3.8 27B."], start: loading, stops: 1, step: .init(.starting)),
            .init(["Loading Qwen 3.8 27B: 1 of 2 parts ready."], start: loading, stops: 1),
            .init(["Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."], stops: 1)]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "stop before the start: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 0, "stop before the start: the start's outcome, ✓: \(run.text)")
        expect(!run.text.contains("Stopped (by `darkbloom cluster stop`") && run.text.hasSuffix(ending("Serving Qwen 3.8 27B on both Macs")),
               "stop before the start: no stop line: \(run.text)")
    }

    /// A real stop while the leading Mac downloads the model, or while its screen asks how to get it there (the start's
    /// first step, before any figure): the joining Mac ends at once with the leading Mac's line, whose own screen keeps
    /// the pair stopped (`aStopDuringTheDownloadKeepsThePairStopped`).
    static func aStopDuringTheDownloadEndsTheJoiningMacsWaitAtOnce() {
        typealias P = ClusterOnboardingStartProgress
        let copy = ClusterOnboardingLeaderStep(.copy)
        for (label, during) in [("stop in the download", P(.downloading, done: 3_000_000_000, total: 16_300_000_000)), ("stop at the copy question", nil)] {
            let run = TerminalRun(followingWithStops([.init(["Stopped."], stops: 0, step: .init(.modelList)),
                .init(["Stopped."], start: during, stops: 0, step: copy), .init(["Stopped."], start: during, stops: 0, step: copy),
                .init(["Stopped."], start: during, stops: 1, step: copy)]))
            defer { run.release() }
            expect(run.waitFor(codeQuestion), "\(label): the code"); run.type("y")
            let began = Date()
            expect(run.finish(seconds: 20) == 1, "\(label): ended: \(run.text)")
            expect(Date().timeIntervalSince(began) < 10, "\(label): at once: \(Date().timeIntervalSince(began)) s")
            expect(run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs)"), "\(label): the leading Mac's line: \(run.text)")
        }
    }

    /// The leading Mac downloads a model no Mac has while someone runs `darkbloom cluster stop`, or asks how to get it
    /// there when they do: its screen ends at once, as the joining Mac's does, and starts nothing (before, it started both
    /// Macs once the download was done, as if nobody had stopped them). What arrived stays for the next start.
    static func aStopDuringTheDownloadKeepsThePairStopped() {
        let offer = ClusterOnboardingProvisionOffer(lines: ["This Mac: download from Darkbloom's catalog (16.3 GB)"],
                                                    downloadAlternative: false, leaderDownloads: true)
        let before = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · not on these Macs: downloaded from Darkbloom's catalog first"],
                                                   blocker: nil, provision: offer)]
        let after = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"],
                                                  blocker: nil)]
        for atTheQuestion in [false, true] {
            let label = atTheQuestion ? "leader stop at the copy question" : "leader stop in the download"
            let recorder = Recorder(), stopped = Recorder()
            // A download of about 8 s.
            var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
                                  choices: before, replanned: after, provisionReports: Array(repeating: copyReports[0], count: 80),
                                  provisionReportPause: 100_000)
            // Two stops counted on earlier days; one more asked at the question or during the download.
            made.stopsAsked = { !stopped.all.isEmpty || (!atTheQuestion && recorder.all.contains("provision 0 copy")) ? 3 : 2 }
            let steps = Recorder()
            made.publishStep = { step in steps.note("\(step?.kind.rawValue ?? "none") \(step?.stopsBefore.map(String.init) ?? "-")") }
            let run = TerminalRun(made)
            defer { run.release() }
            expect(run.waitFor(prompt(1)), "\(label): the list"); run.type("\r")
            expect(run.waitFor("  1) Download\n  2) Cancel\n"), "\(label): get it")
            if atTheQuestion { stopped.note("stop") }
            run.type("\r")
            let began = Date()
            expect(run.finish(seconds: 10) == 1, "\(label): ended, not served: \(run.text)")
            expect(Date().timeIntervalSince(began) < 5, "\(label): at once, not after the download: \(Date().timeIntervalSince(began)) s")
            expect(run.text.hasSuffix("Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more. "
                                      + "Run `darkbloom cluster` on the leading Mac to start it again.\n  "
                                      + ClusterOnboardingStopped.transferKeptLine + "\n"), "\(label): the line, and what stays: \(run.text)")
            expect(recorder.all.contains("provision 0 copy") && recorder.all.filter({ $0 == "planModels" }).count == 1 && !recorder.all.contains("serve"),
                   "\(label): nothing planned or started after it: \(recorder.all)")
            expect(steps.all.contains("copy 2"), "\(label): the start's step carries the count it began with: \(steps.all)")
        }
    }

    /// A stop that lands while the leading Mac tests the started pair: the stop is the outcome, never ✓ or "test failed",
    /// and nothing registers or starts again.
    static func aStopDuringTheTestEndsTheLeadersScreen() {
        for testPasses in [true, false] {
            let recorder = Recorder(), tested = Recorder()
            var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]))
            made.testRequest = {
                tested.note("test")
                return testPasses ? .success(["in 0.61 s"]) : .failure(.init("The test request did not reach this Mac: closed"))
            }
            made.stopsAsked = { tested.all.isEmpty ? 0 : 1 }
            let run = TerminalRun(made)
            defer { run.release() }
            expect(run.waitFor(prompt(2)), "stop in the test: the list"); run.type("\r")
            expect(run.finish(seconds: 10) == 1, "stop in the test (\(testPasses ? "passed" : "failed")): ended: \(run.text)")
            expect(run.text.hasSuffix(ClusterOnboardingStopped.line + "\n")
                   && !run.text.contains("\u{2713} Serving") && !run.text.contains("the test failed") && !recorder.all.contains("register"),
                   "stop in the test (\(testPasses ? "passed" : "failed")): the stop, nothing else: \(run.text) \(recorder.all)")
        }
    }

    /// The leading Mac refuses its start under the lock (`serveUnlessStopped`): a stop took the lock first. The screen
    /// ends with the stop line and waits for nothing.
    static func aStartRefusedForAStopEndsTheScreen() {
        let recorder = Recorder()
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]))
        made.serveUnlessStopped = { since in recorder.note("serveUnlessStopped \(since.map(String.init) ?? "-")"); return .failure(.stopped) }
        made.stopsAsked = { 7 }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "refused start: the list"); run.type("\r")
        expect(run.finish(seconds: 10) == 1, "refused start: ended")
        expect(run.text.hasSuffix(ClusterOnboardingStopped.line + "\n") && !recorder.all.contains("waitReady") && !recorder.all.contains("serve")
               && recorder.all.contains("serveUnlessStopped 7"), "refused start: the stop line, nothing waited for: \(run.text) \(recorder.all)")
    }

    /// A stop asked while the leading Mac's screen asks to stop single-Mac serving (found while the parts loaded): the
    /// same start goes on there, so the stop stands and nothing starts again (the joining Mac, which still follows, ends
    /// on the same stop).
    static func aStopDuringTheSoloQuestionKeepsThePairStopped() {
        let recorder = Recorder(), stopped = Recorder()
        let ready = ClusterOnboardingReady(servedBy: "this Mac", port: 8000, deployment: "Serving Gemma 4 26B across both Macs: tensor parallel",
                                           split: "tensor parallel")
        var made = soloOperations(recorder, serving: [], readyResults: [.failure(.soloServing([soloBoth[1]])), .success(ready)])
        made.stopsAsked = { stopped.all.isEmpty ? 0 : 1 }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "stop at the solo question: the list"); run.type("\r")
        expect(run.waitFor("  2) Leave\n"), "stop at the solo question: the offer")
        stopped.note("stop")
        run.type("1")
        expect(run.finish(seconds: 10) == 1, "stop at the solo question: ended: \(run.text)")
        expect(run.text.hasSuffix(ClusterOnboardingStopped.line + "\n") && recorder.all.filter({ $0 == "serve" }).count == 1,
               "stop at the solo question: the stop line, not started again: \(run.text) \(recorder.all)")
    }

    /// Retry after a ✗ is a new start (the joining Mac ended on that ✗): a stop asked before it is no stop of the new one.
    static func retryIsANewStart() {
        let recorder = Recorder(), stopped = Recorder()
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
                              readyResults: [.failure(.init("A part keeps ending the same way: boom")), .success(offeredReady)])
        made.stopsAsked = { stopped.all.isEmpty ? 0 : 1 }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "retry: the list"); run.type("\r")
        expect(run.waitFor(notServingItemLines), "retry: the ✗ and its choices: \(run.text)")
        stopped.note("stop")
        run.type("1")
        expect(run.finish(seconds: 15) == 0, "retry: served: \(run.text)")
        expect(!run.text.contains("Stopped (by `darkbloom cluster stop`"), "retry: no stop line from before it: \(run.text)")
    }

    /// A real stop while the parts load: the leading Mac's screen ends at once with the stop line (its parts are stopped
    /// and nothing starts them again), never a ✗ after 15 minutes with Retry. The wait itself goes on by itself (here it
    /// would answer only after 20 s).
    static func aStopFromAnywhereEndsTheLeadersLoadAtOnce() {
        let recorder = Recorder()
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
                              readyReports: ["1 of 2 parts ready"], readyReportPause: 20_000_000)
        made.stopsAsked = { recorder.all.contains("waitReady") ? 3 : 2 }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "leader stop in the load: the list"); run.type("\r")
        let began = Date()
        expect(run.finish(seconds: 15) == 1, "leader stop in the load: ended")
        expect(Date().timeIntervalSince(began) < 10, "leader stop in the load: at once, not when the wait answers: \(Date().timeIntervalSince(began)) s")
        expect(run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more."),
               "leader stop in the load: said plainly: \(run.text)")
        expect(!run.text.contains(notServingChoices) && !recorder.all.contains("testRequest"), "leader stop in the load: no Retry, no test: \(run.text)")
    }

    /// The leading Mac's own stops while the parts load (a part a model change or the registration stopped, the cluster
    /// service's restart for an approval) count none: its wait goes on to the outcome.
    static func thePairsOwnStopsNeverEndTheLeadersWait() {
        let recorder = Recorder()
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
                              readyReports: ["1 of 2 parts ready", "2 of 2 parts ready"], readyReportPause: 1_500_000)
        made.stopsAsked = { 2 }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "own stops: the list"); run.type("\r")
        expect(run.finish(seconds: 20) == 0, "own stops: served: \(run.text)")
        expect(!run.text.contains("Stopped (by `darkbloom cluster stop`") && recorder.all.contains("testRequest"), "own stops: no stop line: \(run.text)")
    }
}
