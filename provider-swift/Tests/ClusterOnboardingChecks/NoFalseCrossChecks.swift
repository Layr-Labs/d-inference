import Foundation
import Darwin

/// R7-1 (DevNet branch.87, M5 Ultra pair, 2026-11-05 03:19:56Z and ~03:40Z): right after "✓ Load (58 s)" the joining
/// Mac's window ended with "✗ Not serving: not offered to Darkbloom (no cluster approval is attached to its setup)" and
/// "Choose Retry on the other Mac", while the leading Mac went on to its test, registered the pair (03:20:22Z), started
/// both parts again as cluster members and showed ✓ through Darkbloom. In the hand-off from its local test to the
/// registration the leading Mac's status says "not offered" while its start still runs (it publishes the start's step).
/// A not-offered status is the start's outcome only once the leading Mac's start is over: while it publishes a step,
/// the joining Mac follows it; the leading Mac's own ✗ (`failed`) ends it with that ✗.
extension OnboardingChecks {
    static func noFalseCrossChecks() {
        theRegistrationHandOffIsNoCross()
        aLeadersPublishedCrossAfterNotOfferedEndsIt()
        aNotOfferedPairWithNoStartRunningIsStillItsOutcome()
        anEarlierStartsCrossNeverHidesANotOfferedOutcome()
    }

    static let handOffNotOffered = [ClusterOnboardingNotServing.statusLine(model: "Z.ai: GLM-5.3-Flash", reason: ClusterOnboardingReady.notOfferedReason(nil)),
                                    "Meanwhile it answers only on the local API at http://localhost:8000 on the other Mac (no Darkbloom traffic)."]

    static func theRegistrationHandOffIsNoCross() {
        typealias P = ClusterOnboardingStartProgress
        let served = ["Serving Z.ai: GLM-5.3-Flash through Darkbloom on both Macs (tensor parallel).",
                      "No local API: requests reach the pair through Darkbloom"]
        // As branch.87's leader published it: loading, then its test and the registration while its status says "not
        // offered", the registration's stop and restart, the coordinator's wait, then ✓.
        let status: [[String]] = [["Stopped."]] + Array(repeating: ["Loading Z.ai: GLM-5.3-Flash: 1 of 2 parts ready."], count: 4)
            + Array(repeating: handOffNotOffered, count: 8)
            + Array(repeating: ["Stopped; last model Z.ai: GLM-5.3-Flash."], count: 3)
            + Array(repeating: ["Z.ai: GLM-5.3-Flash: registering both Macs with the coordinator for pairing."], count: 3)
            + Array(repeating: [ClusterOnboardingNotServing.statusLine(model: "Z.ai: GLM-5.3-Flash", reason: "waiting for the coordinator to pair both Macs")], count: 4)
            + [served]
        let start: [P?] = [nil] + Array(repeating: P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .loading)]), count: 4)
            + Array(repeating: P(.testing), count: 4) + Array(repeating: P(.registering), count: 10)
        for (label, environment) in [("80 columns", colourTerminal), ("plain", ["NO_COLOR": "1"])] {
            let recorder = Recorder()
            let run = TerminalRun(followingTheUltra(recorder, status: status, start: start), environment: environment, columns: 80)
            defer { run.release() }
            expect(run.waitFor(codeQuestion), "R7-1 \(label): the code"); run.type("y")
            expect(run.finish(seconds: 30) == 0, "R7-1 \(label): ends with the leader's ✓, exit 0: \(run.text)")
            let text = run.text
            expect(!text.contains("\u{2717}") && !text.contains("Choose Retry"), "R7-1 \(label): no ✗ and no Retry in the hand-off: \(text)")
            expect(text.contains("\u{2713} Serving Z.ai: GLM-5.3-Flash through Darkbloom on both Macs (tensor parallel)"), "R7-1 \(label): the leader's ✓")
            transcript("r7-1-hand-off-\(label.replacingOccurrences(of: " ", with: "-"))", text, keys: run.keys)
        }
    }

    static func aLeadersPublishedCrossAfterNotOfferedEndsIt() {
        typealias P = ClusterOnboardingStartProgress
        let failed = P.failed(title: ClusterOnboardingNotServing.title(reason: ClusterOnboardingReady.notOfferedReason(nil)),
                              lines: ["Meanwhile it answers only on the local API at http://localhost:8000 on this Mac (no Darkbloom traffic)."], retry: true)
        let run = TerminalRun(followingTheUltra(Recorder(), status: [["Stopped."], ["Loading Z.ai: GLM-5.3-Flash: 1 of 2 parts ready."]]
                                                    + Array(repeating: handOffNotOffered, count: 20),
                                                start: [nil, P(.loading)] + Array(repeating: P(.testing), count: 6) + [failed]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "R7-1, leader's ✗: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 1, "R7-1, leader's ✗: exit 1")
        let text = run.text
        expect(text.contains("\u{2717} Not serving: not offered to Darkbloom (no cluster approval is attached to its setup).\n")
               && text.contains("on the other Mac (Apple M3 Ultra, 256 GB) (no Darkbloom traffic)") && text.contains(retryOnLeader),
               "R7-1, leader's ✗: its words, named from this Mac, then where Retry is: \(text)")
        expect(text.components(separatedBy: "\u{2717}").count == 2, "R7-1, leader's ✗: once")
    }

    static func aNotOfferedPairWithNoStartRunningIsStillItsOutcome() {
        let run = TerminalRun(followingTheUltra(Recorder(), status: [["Stopped."], handOffNotOffered]))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "not offered, no start: the code")
        let typed = Date()
        run.type("y")
        expect(run.finish(seconds: 30) == 1, "not offered, no start: the ✗, exit 1: \(run.text)")
        expect(Date().timeIntervalSince(typed) < 10, "not offered, no start: at once, not at the 15-minute bound")
        expect(run.text.contains("\u{2717} Not serving: not offered to Darkbloom (no cluster approval is attached to its setup).\n"),
               "not offered, no start: the leading Mac's status is the outcome")
    }

    /// The review of R7-1 (B1): the leading Mac's ✗ from an earlier start stays published for 30 minutes. Opened then (no
    /// leader screen publishes a step, the status says "not offered"), the joining Mac must end with that true ✗ at once,
    /// never follow a start that isn't running until the 15-minute bound.
    static func anEarlierStartsCrossNeverHidesANotOfferedOutcome() {
        let earlier = ClusterOnboardingStartProgress.failed(title: ClusterOnboardingNotServing.title(reason: ClusterOnboardingReady.notOfferedReason(nil)),
                                                            lines: [], retry: true)
        let run = TerminalRun(followingTheUltra(Recorder(), status: [["Stopped."], handOffNotOffered], start: [earlier], step: nil))
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "earlier ✗, not offered: the code")
        let typed = Date()
        run.type("y")
        expect(run.finish(seconds: 30) == 1, "earlier ✗, not offered: exit 1: \(run.text)")
        expect(Date().timeIntervalSince(typed) < 10, "earlier ✗, not offered: at once, not at the 15-minute bound")
        expect(run.text.contains("\u{2717} Not serving: not offered to Darkbloom (no cluster approval is attached to its setup).\n")
               && !run.text.contains("didn't say how its start ended"), "earlier ✗, not offered: the true ✗: \(run.text)")
    }
}
