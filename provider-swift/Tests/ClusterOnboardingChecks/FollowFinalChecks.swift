import Foundation
import Darwin

/// 0.10.9 DevNet, pair-2 (f2, 2026-11-05 00:23Z): 6 s after its part registered with the coordinator, the joining Mac's
/// window ended with "✗ Not serving: This Mac isn't verified by Apple yet …" and "Choose Retry on the other Mac", while
/// the leading Mac kept waiting and showed "✓ Serving Qwen 3.8 27B through Darkbloom on both Macs" 41 s later. The
/// joining Mac had judged the pair by its own wait. Now a state that clears by itself keeps it waiting, and its final ✓
/// or ✗ is the leading Mac's, in the same words; an older leader that publishes no outcome ends in an honest ✗.
extension OnboardingChecks {
    static func followFinalOutcomeChecks() {
        theJoiningMacWaitsForAppleAndEndsWithTheLeadersTick()
        anOlderLeaderEndsInAnHonestCross()
        theLeadersFinalCrossIsTheJoiningMacsCross()
        theLeaderPublishesItsFinalCrossForTheJoiningMac()
        anEarlierStartsCrossIsNeverThisStartsOutcome()
    }

    /// The leading Mac's ✗ counts for 30 minutes after its screen ends, and a pairing keeps its record: until the leading
    /// Mac's new screen publishes its first step, its status still carries the earlier start's ✗. The joining Mac takes a
    /// ✗ as this start's outcome only once it saw that screen publish a step.
    static func anEarlierStartsCrossIsNeverThisStartsOutcome() {
        typealias P = ClusterOnboardingStartProgress
        let stale = P.failed(title: ClusterOnboardingNotServing.title(reason: "The other Mac isn't verified by Apple yet"), lines: [], retry: true)
        let recorder = Recorder()
        var made = followingTheUltra(recorder, status: [])
        let looks = Recorder()
        made.leaderStatus = {
            looks.note("look")
            switch looks.all.count {
            case ...3: return .init(lines: ["Stopped."], step: nil, start: stale)
            case 4: return .init(lines: ["Stopped."], step: .init(.reading), start: nil)
            case 5: return .init(lines: ["Starting Qwen 3.8 27B."], step: .init(.starting), start: nil)
            default: return .init(lines: pairServedStatus, step: .init(.starting), start: nil)
            }
        }
        let run = TerminalRun(made, environment: ["NO_COLOR": "1"])
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "earlier ✗: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 0, "earlier ✗: ends with this start's ✓, exit 0: \(run.text)")
        let text = run.text
        expect(!text.contains("\u{2717}") && !text.contains("Choose Retry"), "earlier ✗: never shown as this start's outcome: \(text)")
    }

    static let ultraName = "Apple M3 Ultra, 256 GB"
    static let appleReason = ClusterOnboardingNotServing.notVerified(ClusterOnboardingMacName.this)
    static let appleWaitStatus = [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: appleReason),
                                  ClusterOnboardingNotServing.remedy(forReason: appleReason) ?? ""]
    static let pairServedStatus = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).",
                                   "No local API: requests reach the pair through Darkbloom"]
    static let appleWaitRow = "Waiting for Apple to verify this Mac (Darkbloom retries by itself)"

    /// The joining Mac of an M3 Ultra leader whose status goes through `status` in turn (one per look, the last repeats),
    /// with what it publishes of its start (`start`, by look; nil: an older leader). The joining Mac's own wait for the
    /// pair (`pairServing`) says what f2's said: it must never decide.
    static func followingTheUltra(_ recorder: Recorder, status: [[String]], start: [ClusterOnboardingStartProgress?] = [],
                                  followSeconds: Double = 900, step: ClusterOnboardingLeaderStep? = .init(.starting)) -> ClusterOnboardingOperations {
        var made = operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: ultraName),
                              pairServingResults: [.failure(.init([appleReason + ".", "Then choose Retry, or serve locally only now."]))],
                              followSeconds: followSeconds)
        let looks = Recorder()
        made.leaderStatus = {
            looks.note("look")
            let seen = looks.all.count
            return .init(lines: status[min(seen, status.count) - 1], step: step,
                         start: start.isEmpty ? nil : start[min(seen, start.count) - 1])
        }
        return made
    }

    static func theJoiningMacWaitsForAppleAndEndsWithTheLeadersTick() {
        let status = [["Stopped."], ["Starting Qwen 3.8 27B."]] + Array(repeating: appleWaitStatus, count: 30) + [pairServedStatus]
        for (label, environment) in [("80 columns", colourTerminal), ("plain", ["NO_COLOR": "1"])] {
            let recorder = Recorder()
            let run = TerminalRun(followingTheUltra(recorder, status: status), environment: environment, columns: 80)
            defer { run.release() }
            expect(run.waitFor(codeQuestion), "f2 \(label): the code"); run.type("y")
            expect(run.finish(seconds: 30) == 0, "f2 \(label): ends with the leader's ✓, exit 0: \(run.text)")
            let text = run.text
            expect(text.contains("\u{2713} Serving Qwen 3.8 27B on both Macs"), "f2 \(label): the ✓: \(text)")
            expect(!text.contains("\u{2717}") && !text.contains("Choose Retry"), "f2 \(label): no ✗ and no Retry for a pair that serves: \(text)")
            expect(text.contains(appleWaitRow), "f2 \(label): it says it waits for Apple: \(text)")
            expect(!recorder.all.contains("pairServing"), "f2 \(label): its own wait never decides: \(recorder.all)")
            if label == "plain" {
                expect(text.components(separatedBy: appleWaitRow).count == 2, "f2 plain: the wait said once")
            } else {
                expect(text.contains(appleWaitRow + " \u{00B7} "), "f2 80 columns: the live row with its time")
                let rows = liveRows(text)
                expect(rows.allSatisfy { $0.count <= 79 }, "f2 80 columns: every live row fits: \(rows.filter { $0.count > 79 })")
            }
            transcript("joining-apple-wait-\(label.replacingOccurrences(of: " ", with: "-"))", text, keys: run.keys)
        }
    }

    static func anOlderLeaderEndsInAnHonestCross() {
        let recorder = Recorder()
        let run = TerminalRun(followingTheUltra(recorder, status: [["Stopped."], ["Starting Qwen 3.8 27B."], appleWaitStatus], followSeconds: 2))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "older leader: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 1, "older leader: exit 1: \(run.text)")
        let text = run.text
        expect(text.contains("\u{2717} Not serving: The other Mac (Apple M3 Ultra, 256 GB) didn't say how its start ended within"),
               "older leader: the honest ✗: \(text)")
        expect(text.contains("Its screen shows how the start ended and what to do next."), "older leader: where to look")
        expect(!text.contains("isn't verified by Apple yet; Darkbloom retries") || !text.contains("\u{2717} Not serving: This Mac isn't verified"),
               "older leader: never the transient reason as its ✗")
        expect(!text.contains("Choose Retry"), "older leader: no Retry it can't see: \(text)")
        expect(!recorder.all.contains("pairServing"), "older leader: its own wait never decides")
    }

    static func theLeadersFinalCrossIsTheJoiningMacsCross() {
        typealias P = ClusterOnboardingStartProgress
        let missing = ClusterOnboardingNotServing.notLoggedIn([ClusterOnboardingMacName.other(named: "Apple M5 Max, 128 GB")])
        let published = P.failed(title: ClusterOnboardingNotServing.title(reason: missing),
                                 lines: [ClusterOnboardingNotServing.remedy(forReason: missing) ?? ""], retry: true)
        let waiting = [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "Waiting for the coordinator to pair both Macs")]
        let recorder = Recorder()
        let run = TerminalRun(followingTheUltra(recorder, status: [["Stopped."], ["Starting Qwen 3.8 27B."]] + Array(repeating: waiting, count: 12),
                                                start: Array(repeating: nil, count: 14) + [published]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "leader's ✗: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 1, "leader's ✗: exit 1: \(run.text)")
        let text = run.text
        expect(text.contains("\u{2717} Not serving: This Mac isn't logged in to Darkbloom, so the coordinator won't pair it.\n"),
               "leader's ✗: its words, named from this Mac: \(text)")
        expect(text.contains("Run `darkbloom login` on each Mac named, then Retry."), "leader's ✗: its next step")
        expect(text.contains(retryOnLeader), "leader's ✗: where Retry is: \(text)")
        expect(text.components(separatedBy: "\u{2717}").count == 2, "leader's ✗: one ✗ only")
    }

    static let retryOnLeader = "Choose Retry on the other Mac (Apple M3 Ultra, 256 GB): its screen shows the choices."

    static func theLeaderPublishesItsFinalCrossForTheJoiningMac() {
        let published = Recorder()
        let missing = ClusterOnboardingNotServing.notLoggedIn([ClusterOnboardingMacName.other(named: "Apple M3 Ultra, 256 GB")])
        var made = operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyResult: .success(.init(servedBy: "this Mac", port: 8000, offered: "offered for pairing")),
            pairServingResults: [.failure(.init(missing))])
        let shown = ClusterOnboardingMailbox<ClusterOnboardingStartProgress?>()
        made.publishStart = { shown.post($0); published.note($0?.phase.rawValue ?? "nil") }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(prompt(2)), "leader publishes: the list"); run.type("\r")
        expect(run.waitFor("Not serving: The other Mac (Apple M3 Ultra, 256 GB) isn't logged in"), "leader publishes: its ✗: \(run.text)")
        _ = run.waitFor(prompt(4), seconds: 3)
        run.type("q")
        _ = run.finish()
        let failed = shown.take().compactMap { $0 }.last { $0.phase == .failed }
        expect(failed?.retry == true, "leader publishes: a final ✗ with Retry: \(published.all)")
        let member = failed?.viewed(leader: "Apple M3 Ultra, 256 GB")
        expect(member?.title == "Not serving: This Mac isn't logged in to Darkbloom, so the coordinator won't pair it.",
               "leader publishes: the joining Mac reads it named from its side: \(String(describing: member))")
    }
}
