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

    static func aStopFromAnywhereEndsTheLeadersWaitAtOnce() {
        let recorder = Recorder()
        let run = TerminalRun(coordinatorWait(recorder) { progress in
            progress("waiting for the coordinator to pair both Macs\nThis Mac: registered; waiting for the coordinator")
            usleep(300_000)
            return .failure(.stopped)
        })
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
        let run = TerminalRun(followingWithStops([(["Stopped."], nil, 2), ([loading], parts, 2), ([loading], parts, 2),
                                                  (["Stopped; last model Qwen 3.8 27B."], nil, 3)]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "joining stop: the code"); run.type("y")
        let began = Date()
        expect(run.finish(seconds: 40) == 1, "joining stop: ended, not after the bound: \(run.text)")
        expect(Date().timeIntervalSince(began) < 10, "joining stop: at once, never after a hold: \(Date().timeIntervalSince(began)) s")
        expect(run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs)"), "joining stop: the same line: \(run.text)")
    }

    /// The Mac that joined a leader whose looks say each of `looks` in turn (the last one repeats): its status lines, its
    /// start's progress, and how many stops a person asked for there (nil: a look that read none).
    static func followingWithStops(_ looks: [(lines: [String], start: ClusterOnboardingStartProgress?, stops: Int?)])
        -> ClusterOnboardingOperations {
        var made = operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName))
        let count = Recorder()
        made.leaderStatus = {
            count.note("look")
            let look = looks[min(count.all.count, looks.count) - 1]
            return .init(lines: look.lines, step: nil, start: look.start, stopsAsked: look.stops)
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
    /// `leadership.serving` is off, and only `localServe` turns it on) while its start publishes `downloading`, then
    /// `copying`; it reads "Stopped; last model …" again while it stops both parts to register them. None of that is a
    /// stop: the joining Mac follows the start to the leading Mac's outcome.
    static func aStatusThatReadsStoppedThroughADownloadIsNoStop() {
        typealias P = ClusterOnboardingStartProgress
        let served = "Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."
        var made = operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName))
        let clock = FirstLook()
        made.leaderStatus = {
            let seconds = clock.seconds
            switch seconds {
            case ..<21:
                // More than 20 s of "Stopped." beside the download's bytes.
                return .init(lines: ["Stopped."], step: .init(.copy),
                             start: P(.downloading, done: Int64(seconds / 21 * 16_300_000_000), total: 16_300_000_000))
            case ..<22:
                return .init(lines: ["Stopped."], step: .init(.copy), start: P(.copying, done: 8_000_000_000, total: 16_300_000_000))
            case ..<22.5:
                // Between the copy and the start (the plan again, the adopt): no figures any more, still "Stopped.".
                return .init(lines: ["Stopped."], step: .init(.starting), start: nil)
            case ..<23.5:
                return .init(lines: ["Starting Qwen 3.8 27B."], step: .init(.starting),
                             start: P(.loading, parts: [.init(rank: 0, state: .starting), .init(rank: 1, state: .starting)]))
            case ..<24.5:
                return .init(lines: ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], step: .init(.starting),
                             start: P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .loading)]))
            case ..<26:
                // The registration stops both parts, saves the approval on each Mac and starts them again as members.
                return .init(lines: ["Stopped; last model Qwen 3.8 27B."], step: .init(.starting), start: P(.registering))
            default:
                return .init(lines: [served], step: .init(.starting), start: nil)
            }
        }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "download, no stop: the code"); run.type("y")
        let code = run.finish(seconds: 50)
        let text = run.text
        expect(text.contains("4/4 Start"), "download, no stop: the joining Mac followed the start: \(text)")
        expect(!text.contains("Stopped (by `darkbloom cluster stop`"), "download, no stop: no stop line nobody asked for: \(text)")
        expect(code == 0 && text.hasSuffix(ending("Serving Qwen 3.8 27B on both Macs")),
               "download, no stop: the leading Mac's outcome, ✓: \(String(describing: code)) \(text)")
        transcript("member-download-no-stop", text, keys: run.keys)
    }

    /// What tells a stop: the leading Mac's count of the stops a person asked for, compared with the count before the start
    /// began; never the words of its status.
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
    }

    /// Someone runs `darkbloom cluster stop` while the leading Mac is still at its model list (nothing runs to stop): the
    /// start that follows is no stopped one.
    static func aStopBeforeTheStartIsNoStopOfIt() {
        typealias P = ClusterOnboardingStartProgress
        let loading = P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .loading)])
        let run = TerminalRun(followingWithStops([(["Stopped."], nil, nil), (["Stopped."], nil, 0), (["Stopped."], nil, 1),
            (["Stopped."], nil, 1), (["Starting Qwen 3.8 27B."], loading, 1), (["Loading Qwen 3.8 27B: 1 of 2 parts ready."], loading, 1),
            (["Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."], nil, 1)]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "stop before the start: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 0, "stop before the start: the start's outcome, ✓: \(run.text)")
        expect(!run.text.contains("Stopped (by `darkbloom cluster stop`") && run.text.hasSuffix(ending("Serving Qwen 3.8 27B on both Macs")),
               "stop before the start: no stop line: \(run.text)")
    }

    /// A real stop while the leading Mac downloads the model: the joining Mac ends at once with the leading Mac's line
    /// (whose own screen keeps the pair stopped: `aStopDuringTheDownloadKeepsThePairStopped`).
    static func aStopDuringTheDownloadEndsTheJoiningMacsWaitAtOnce() {
        typealias P = ClusterOnboardingStartProgress
        let run = TerminalRun(followingWithStops([(["Stopped."], nil, 0),
            (["Stopped."], P(.downloading, done: 1_000_000_000, total: 16_300_000_000), 0),
            (["Stopped."], P(.downloading, done: 2_000_000_000, total: 16_300_000_000), 0),
            (["Stopped."], P(.downloading, done: 3_000_000_000, total: 16_300_000_000), 1)]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "stop in the download: the code"); run.type("y")
        let began = Date()
        expect(run.finish(seconds: 20) == 1, "stop in the download: ended: \(run.text)")
        expect(Date().timeIntervalSince(began) < 10, "stop in the download: at once: \(Date().timeIntervalSince(began)) s")
        expect(run.text.contains("4/4 Start") && run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs)"),
               "stop in the download: the leading Mac's line: \(run.text)")
    }

    /// The leading Mac downloads a model no Mac has while someone runs `darkbloom cluster stop`: once the download is done
    /// its screen ends with the stop line and starts nothing (before, it started both Macs as if nobody had stopped them).
    static func aStopDuringTheDownloadKeepsThePairStopped() {
        let recorder = Recorder()
        let offer = ClusterOnboardingProvisionOffer(lines: ["This Mac: download from Darkbloom's catalog (16.3 GB)"],
                                                    downloadAlternative: false, leaderDownloads: true)
        let before = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · not on these Macs: downloaded from Darkbloom's catalog first"],
                                                   blocker: nil, provision: offer)]
        let after = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · this Mac 32 layers / the other Mac 32 layers"],
                                                  blocker: nil)]
        var made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
                              choices: before, replanned: after)
        // Two stops counted on earlier days before the download; the one asked during it after.
        made.stopsAsked = { recorder.all.contains("provision 0 copy") ? 3 : 2 }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(1)), "leader stop in the download: the list"); run.type("\r")
        expect(run.waitFor("  1) Download\n  2) Cancel\n"), "leader stop in the download: get it"); run.type("\r")
        expect(run.finish(seconds: 10) == 1, "leader stop in the download: ended, not served: \(run.text)")
        expect(run.text.hasSuffix("Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more. "
                                  + "Run `darkbloom cluster` on the leading Mac to start it again.\n"), "leader stop in the download: the line: \(run.text)")
        expect(recorder.all.contains("provision 0 copy") && !recorder.all.contains("serve") && !recorder.all.contains("waitReady"),
               "leader stop in the download: downloaded, nothing started: \(recorder.all)")
    }

    /// A real stop while the parts load: the leading Mac's wait for them ends at once with the stop line (its parts are
    /// stopped and nothing starts them again), never a ✗ after 15 minutes with Retry.
    static func aStopFromAnywhereEndsTheLeadersLoadAtOnce() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Max, 128 GB"), pairEvents: [],
                                         pairResult: .failed([]), readyResult: .failure(.stopped)))
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "leader stop in the load: the list"); run.type("\r")
        expect(run.finish(seconds: 10) == 1, "leader stop in the load: ended")
        expect(run.text.contains("Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more."),
               "leader stop in the load: said plainly: \(run.text)")
        expect(!run.text.contains(notServingChoices) && !recorder.all.contains("testRequest"), "leader stop in the load: no Retry, no test: \(run.text)")
    }
}
