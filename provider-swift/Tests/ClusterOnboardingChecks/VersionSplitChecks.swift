import Foundation
import Darwin

/// The two Macs of a pair on different Darkbloom versions (account 668cf2b3, 2026-11-04: the M5 Max updated to 0.10.8
/// alone, its part ended every 38 s and no screen named the versions). The split is said before anything starts, ends
/// the wait at once on both Macs, is re-checked before a start goes on, comes before single-Mac serving, and names the
/// Mac to update with the build's own command.
extension OnboardingChecks {
    static func versionSplitChecks() {
        aVersionSplitIsWordedForEachMacAndTheStatus()
        aVersionSplitIsSaidBeforeAnythingStartsAndCheckedAgain()
        aVersionSplitIsLeftWithNothingStarted()
        aVersionSplitFoundWhileWaitingIsNeverRetried()
        aVersionSplitComesBeforeSingleMacServing()
        aVersionSplitNamesTheDevNetCommand()
        theJoinedMacEndsItsWaitAtOnceOnAVersionSplit()
        theWaitLinesNameTheOtherMacsVersion()
    }

    static let m4Max = "the other Mac (Apple M4 Max, 128 GB)"
    /// This Mac on 0.10.8, the other Mac still on 0.10.7.
    static let splitThere = ClusterOnboardingVersionSplit(thisVersion: "0.10.8", otherVersion: "0.10.7", other: m4Max)
    static let splitTitle = "\u{2717} The two Macs run different Darkbloom versions: The other Mac (Apple M4 Max, 128 GB) runs 0.10.7, this Mac runs 0.10.8."
    static let splitChoices = "  1) Check the versions again (after `darkbloom update` on the Mac named)\n  2) Leave\n"

    static func aVersionSplitIsWordedForEachMacAndTheStatus() {
        typealias V = ClusterOnboardingVersionSplit
        expect(V.detect(thisVersion: "0.10.9", otherVersion: "0.10.9", other: m4Max) == nil, "split: one version is none")
        expect(V.detect(thisVersion: "0.10.9", otherVersion: nil, other: m4Max) == nil, "split: an unknown version is none")
        expect(V.detect(thisVersion: "0.10.9", otherVersion: "dev", other: m4Max) == nil, "split: a non-numeric version is none")
        expect(splitThere.remedies == ["On the other Mac (Apple M4 Max, 128 GB), run `darkbloom update`; the pair starts once both Macs run 0.10.8.",
                                       "Check with `darkbloom --version` on both Macs."], "split: the older Mac there: \(splitThere.remedies)")
        let here = V(thisVersion: "0.10.8", otherVersion: "0.10.10", other: m4Max)
        expect(here.remedies.first == "On this Mac, run `darkbloom update`; the pair starts once both Macs run 0.10.10.",
               "split: the older Mac here, compared by number: \(here.remedies)")
        expect(splitThere.reason == "the two Macs run different Darkbloom versions, 0.10.8 and 0.10.7: run `darkbloom update` on the Mac with 0.10.7",
               "split: the status reason names no Mac by 'this': \(splitThere.reason)")
        // `status` on each Mac reads the same reason and names the Mac for its own window.
        expect(V.next(reason: splitThere.reason, thisVersion: "0.10.7", other: "the other Mac (Apple M5 Max, 128 GB)", cli: "darkbloom")
               == "On this Mac, run `darkbloom update`; then check that `darkbloom --version` shows 0.10.8 on both Macs.",
               "split: next on the older Mac")
        expect(V.next(reason: splitThere.reason, thisVersion: "0.10.8", other: m4Max, cli: "darkbloom-dev")
               == "On the other Mac (Apple M4 Max, 128 GB), run `darkbloom-dev update`; then check that `darkbloom-dev --version` shows 0.10.8 on both Macs.",
               "split: next on the newer Mac, with the build's command")
        expect(V.next(reason: "the other Mac lacks free memory", thisVersion: "0.10.8", other: m4Max, cli: "darkbloom") == nil,
               "split: any other reason has no split next")
    }

    /// The leading Mac's start with the other Mac on 0.10.7 until `splitsFor` version reads, then one version.
    static func splitOperations(_ recorder: Recorder, splitsFor reads: Int, solo: [ClusterOnboardingSoloServing] = [],
                                readyResults: [Result<ClusterOnboardingReady, ClusterOnboardingFailure>]? = nil) -> ClusterOnboardingOperations {
        var made = soloOperations(recorder, serving: solo, readyResults: readyResults)
        let counted = Recorder()
        made.versionSplit = {
            recorder.note("versionSplit")
            counted.note("read")
            return counted.all.count <= reads ? splitThere : nil
        }
        return made
    }

    static func aVersionSplitIsSaidBeforeAnythingStartsAndCheckedAgain() {
        let recorder = Recorder()
        let run = TerminalRun(splitOperations(recorder, splitsFor: 2))
        expect(run.waitFor(prompt(2)), "split start: choice"); run.type("\r")
        expect(run.waitFor(splitChoices), "split start: Check again or Leave: \(run.text)")
        expect(!recorder.all.contains("serve"), "split start: nothing started: \(recorder.all)")
        run.type("1")
        // Still split at the second read: the ✗ again, nothing started.
        expect(run.waitFor(splitChoices + "\n") || run.text.components(separatedBy: splitTitle).count >= 3,
               "split start: still split, said again: \(run.text)")
        expect(!recorder.all.contains("serve"), "split start: still nothing started")
        run.type("1")
        expect(run.finish() == 0, "split start: served once the versions match: \(run.text)")
        expect(run.text.contains(splitTitle + "\n"), "split start: the ✗ names both versions: \(run.text)")
        expect(run.text.contains("On the other Mac (Apple M4 Max, 128 GB), run `darkbloom update`; the pair starts once both Macs run 0.10.8."),
               "split start: the Mac and the command")
        expect(!run.text.contains(notServingChoices) && !run.text.contains("starts again by itself"), "split start: never a Retry loop")
        expect(recorder.all.filter { $0 == "versionSplit" }.count >= 3, "split start: re-read before starting: \(recorder.all)")
    }

    static func aVersionSplitIsLeftWithNothingStarted() {
        let recorder = Recorder()
        let run = TerminalRun(splitOperations(recorder, splitsFor: 99))
        expect(run.waitFor(prompt(2)), "split leave: choice"); run.type("\r")
        expect(run.waitFor(splitChoices), "split leave: the choices"); run.type("2")
        expect(run.finish() == 1, "split leave: exit 1")
        expect(run.text.contains("The pair was not started. Run `darkbloom update` on the Mac named, then `darkbloom cluster` here."),
               "split leave: the last line: \(run.text)")
        expect(!recorder.all.contains("serve") && !recorder.all.contains("waitReady"), "split leave: nothing started: \(recorder.all)")
    }

    static func aVersionSplitFoundWhileWaitingIsNeverRetried() {
        let recorder = Recorder()
        let ready = ClusterOnboardingReady(servedBy: "this Mac", port: 8000,
            deployment: "Serving Gemma 4 26B across both Macs: tensor parallel", split: "tensor parallel")
        // Found by the wait (the other Mac's part loops on the old setup); the update there lands before Check again.
        let run = TerminalRun(splitOperations(recorder, splitsFor: 0, readyResults: [.failure(splitThere.failure), .success(ready)]))
        expect(run.waitFor(prompt(2)), "split wait: choice"); run.type("\r")
        expect(run.waitFor(splitChoices), "split wait: Check again, not Retry: \(run.text)")
        run.type("1")
        expect(run.finish() == 0, "split wait: served once the versions match: \(run.text)")
        expect(run.text.contains(splitTitle + "\n") && !run.text.contains(notServingChoices), "split wait: the ✗, no Retry: \(run.text)")
        expect(recorder.all.filter { $0 == "serve" }.count == 2, "split wait: started again once: \(recorder.all)")
    }

    static func aVersionSplitComesBeforeSingleMacServing() {
        let recorder = Recorder()
        let run = TerminalRun(splitOperations(recorder, splitsFor: 99, solo: [soloBoth[1]]))
        expect(run.waitFor(prompt(2)), "split first: choice"); run.type("\r")
        expect(run.waitFor(splitChoices), "split first: the split's choices: \(run.text)")
        run.type("2")
        expect(run.finish() == 1, "split first: exit 1")
        expect(run.text.contains(splitTitle) && !run.text.contains("single-Mac Darkbloom provider"),
               "split first: the versions, before single-Mac serving: \(run.text)")
    }

    static func aVersionSplitNamesTheDevNetCommand() {
        ClusterOnboardingCommand.use("darkbloom-dev")
        defer { ClusterOnboardingCommand.use("darkbloom") }
        let run = TerminalRun(splitOperations(Recorder(), splitsFor: 99))
        expect(run.waitFor(prompt(2)), "split dev: choice"); run.type("\r")
        expect(run.waitFor("  2) Leave\n"), "split dev: the choices"); run.type("2")
        expect(run.finish() == 1, "split dev: exit 1")
        expect(run.text.contains("run `darkbloom-dev update`") && run.text.contains("`darkbloom-dev --version`")
               && !run.text.contains("`darkbloom update`"), "split dev: the DevNet app's command: \(run.text)")
    }

    static func theJoinedMacEndsItsWaitAtOnceOnAVersionSplit() {
        var made = followingTheM5Max(steps: [nil], thisVersion: "0.10.7")
        made.versionSplit = { ClusterOnboardingVersionSplit(thisVersion: "0.10.7", otherVersion: "0.10.8", other: m5MaxNamed) }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "split follow: the code"); run.type("y")
        let began = Date()
        expect(run.finish() == 1, "split follow: not success")
        expect(Date().timeIntervalSince(began) < 5, "split follow: at once, not after the bound")
        expect(run.text.contains("\u{2717} The two Macs run different Darkbloom versions: The other Mac (Apple M5 Max, 128 GB) runs 0.10.8, this Mac runs 0.10.7."),
               "split follow: the ✗ from this Mac's side: \(run.text)")
        expect(run.text.contains("On this Mac, run `darkbloom update`; the pair starts once both Macs run 0.10.8."), "split follow: update here")
        expect(run.text.contains("Once both Macs run the same version, run `darkbloom cluster` on the other Mac (Apple M5 Max, 128 GB) again"),
               "split follow: what then")
    }

    static func theWaitLinesNameTheOtherMacsVersion() {
        typealias U = ClusterOnboardingUpdate
        expect(U.memberWaitLine(version: "0.10.9", otherVersion: "0.10.8")
               == "this Mac runs Darkbloom v0.10.9, but its saved setup is for an earlier build: waiting for the other Mac's setup for v0.10.9 "
               + "(the old setup is not started); the other Mac runs v0.10.8, this Mac v0.10.9: run `darkbloom update` on the other Mac",
               "wait: the member names the leader's version and the command: \(U.memberWaitLine(version: "0.10.9", otherVersion: "0.10.8"))")
        expect(U.memberWaitLine(version: "0.10.9", otherVersion: "0.10.9") == U.memberWaitLine(version: "0.10.9"),
               "wait: one version keeps the line")
        expect(U.leaderWaitLine(macs: "this Mac", model: "gemma-4-26b", thisVersion: "0.10.9", otherVersion: "0.10.8").hasSuffix(
            "for gemma-4-26b; the other Mac runs v0.10.8, this Mac v0.10.9: run `darkbloom update` on the other Mac"), "wait: the leader too")
        expect(U.leaderWaitLine(macs: "the other Mac", model: "m", thisVersion: "0.10.8", otherVersion: "0.10.9").hasSuffix(
            "run `darkbloom update` on this Mac"), "wait: this Mac behind")
    }
}
