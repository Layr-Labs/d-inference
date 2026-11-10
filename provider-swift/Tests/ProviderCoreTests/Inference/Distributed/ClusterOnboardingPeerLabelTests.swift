import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

struct ClusterOnboardingPeerLabelTests {
    /// R3-3 (the M5 Ultra pair's round-3 re-test): GLM's mode question offered "this Mac 1 layers / the other Mac 44
    /// layers" while Qwen served (and 26 / 19 while GLM's tensor parallel served); 44 / 1 loaded both times. Each share
    /// is named for the Mac that runs it, in either order, a count of one is "1 layer", and while a model serves the
    /// list's split isn't the one that loads (the adopt stops it and plans again with its memory free), so no number.
    @Test func theModeSplitIsTheOneThatLoads() {
        typealias Share = ClusterSetupPlanSummary.Mode.Share
        let thisFirst = [Share(local: true, firstLayer: 0, endLayer: 44, share: nil), Share(local: false, firstLayer: 44, endLayer: 45, share: nil)]
        let otherFirst = [Share(local: false, firstLayer: 0, endLayer: 44, share: nil), Share(local: true, firstLayer: 44, endLayer: 45, share: nil)]
        func split(_ shares: [Share], serving: Bool = false) -> String? {
            OnboardingLive.modeSplit(shares, here: "this Mac", there: "the other Mac", serving: serving)
        }
        #expect(split(thisFirst) == "this Mac 44 layers / the other Mac 1 layer")
        #expect(split(otherFirst) == "the other Mac 44 layers / this Mac 1 layer", "named by the Mac that runs it")
        #expect(split(thisFirst, serving: true) == ClusterOnboardingMode.decidedWhenItLoads, "no number while a model serves")
        let tensor = [Share(local: true, firstLayer: 0, endLayer: 45, share: 0.5), Share(local: false, firstLayer: 0, endLayer: 45, share: 0.5)]
        #expect(split(tensor) == "this Mac 50% / the other Mac 50%")
        #expect(split([], serving: true) == nil)
        #expect(ClusterOnboardingDeployment.sharesWords(mode: "pipeline_v1", shares: [.init(name: "Apple M5 Ultra", layers: 44, label: "this Mac"),
            .init(name: "Apple M5 Ultra", layers: 1, label: "the other Mac")]) == "this Mac 44 layers / the other Mac 1 layer", "the card's line")
    }

    /// R4-13 (the M5 Ultra pair's DevNet run, branch.80): with nothing serving, GLM-5.3-Flash's mode question offered
    /// Pipeline as "this Mac 1 layer / the other Mac 44 layers", and 44 / 1 loaded. The question showed the pipeline in
    /// the listed tensor-parallel plan's assessment, and the start planned the pipeline again, with this Mac's speed
    /// measured again: on two Macs of one speed, a pipeline's layers follow whichever measured faster. Each mode now shows
    /// what loads when it is chosen: the listed plan's split for its own mode, another mode's own plan for that mode.
    @Test func eachModeShowsThePlanThatLoadsWhenItIsChosen() {
        typealias Share = ClusterSetupPlanSummary.Mode.Share
        let tensor = [Share(local: true, firstLayer: 0, endLayer: 45, share: 0.5), Share(local: false, firstLayer: 0, endLayer: 45, share: 0.5)]
        let assessed = [Share(local: true, firstLayer: 0, endLayer: 1, share: nil), Share(local: false, firstLayer: 1, endLayer: 45, share: nil)]
        let loads = [Share(local: true, firstLayer: 0, endLayer: 44, share: nil), Share(local: false, firstLayer: 44, endLayer: 45, share: nil)]
        let listed = [ClusterSetupPlanSummary.Mode(mode: ClusterGenerationMode.tensorParallel.rawValue, shares: tensor, servedDecodeTokensPerSecond: nil),
                      ClusterSetupPlanSummary.Mode(mode: ClusterGenerationMode.pipeline.rawValue, shares: assessed, servedDecodeTokensPerSecond: 41)]
        let listedPlan = ClusterSetupPlanning.Loads(shares: tensor, concurrentRequests: 8)
        let offered = ClusterSetupPlanning.offered(listed, listed: listedPlan, listedMode: .tensorParallel,
                                                   families: [ClusterForcedMode.pipeline: .init(shares: loads, concurrentRequests: 1)])
        #expect(offered.map(\.shares) == [tensor, loads], "each mode shows its own plan's split")
        #expect(offered.map(\.concurrentRequests) == [8, 1], "and how many requests that plan serves at once")
        #expect(offered.map(\.servedDecodeTokensPerSecond) == [nil, 41], "the measured speeds stay")
        func split(_ mode: ClusterSetupPlanSummary.Mode, serving: Bool = false) -> String? {
            OnboardingLive.modeSplit(mode.shares, here: "this Mac", there: "the other Mac", serving: serving)
        }
        #expect(split(offered[1]) == "this Mac 44 layers / the other Mac 1 layer", "the split that loads")
        // A mode that could not be planned on its own shows no split, rather than one that won't load.
        let unplanned = ClusterSetupPlanning.offered(listed, listed: listedPlan, listedMode: .tensorParallel, families: [:])
        #expect(unplanned[0].shares == tensor && unplanned[1].shares.isEmpty && unplanned[1].concurrentRequests == nil && split(unplanned[1]) == nil)
        // Round 4's R3-3: while a model serves, the start plans again once its memory is back, and the question says so.
        #expect(split(offered[1], serving: true) == ClusterOnboardingMode.decidedWhenItLoads)
    }

    /// R4-13: the start adopts the plan the question showed for the mode chosen when nothing serves, instead of planning
    /// that mode again. While a model serves, it plans again once that memory is back ("decided when it loads").
    @Test func aChosenModeAdoptsThePlanItWasShown() {
        #expect(OnboardingLive.adoption(modeDiffers: true, serving: false, shown: true) == .shown, "the plan whose split was shown")
        #expect(OnboardingLive.adoption(modeDiffers: false, serving: false, shown: false) == .listed)
        #expect(OnboardingLive.adoption(modeDiffers: true, serving: false, shown: false) == .planAgain, "no plan was made for it")
        #expect(OnboardingLive.adoption(modeDiffers: true, serving: true, shown: true) == .planAgain, "decided when it loads")
        #expect(OnboardingLive.adoption(modeDiffers: false, serving: true, shown: false) == .planAgain, "a model change frees memory first")
    }

    /// R4-13, on both Macs: a choice made on the joining Mac's screen is adopted on the leader, which planned the list. The
    /// mode chosen there goes with the adopt, so the leader adopts that mode's plan, not its own list's default.
    @Test func aForwardedAdoptCarriesTheModeChosen() throws {
        let request = OnboardingLive.adoptRequest(index: 1, model: "glm-5.3-flash", scope: nil, family: .pipeline)
        let decoded = try JSONDecoder().decode(ClusterControlRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.op == .adopt && decoded.index == 1 && decoded.model == "glm-5.3-flash")
        #expect(decoded.mode == ClusterForcedMode.pipeline.rawValue, "the mode chosen on the joining Mac's screen")
        // From an older build, with no mode: the leader keeps the one chosen on its own screen, as before.
        let older = try JSONDecoder().decode(ClusterControlRequest.self, from: Data(#"{"op":"adopt","index":1,"model":"glm-5.3-flash"}"#.utf8))
        #expect(older.mode == nil && older.op == .adopt)
    }

    /// The owner (2026-11-04): the mode question recommends one mode for these Macs. The leading Mac reads it from the
    /// plans the list made: each mode's own plan (the listed one for its family, else its family plan) for whether it
    /// fits now and its predicted speed, and the mode for its measured speed, requests at once and public traffic.
    @Test func theRecommendationComesFromEachModesOwnPlan() {
        typealias Share = ClusterSetupPlanSummary.Mode.Share
        func plan(_ mode: String, fitsNow: Bool, decode: Double, absolute: Bool = true) -> ClusterSetupPlanSummary {
            .init(cut: 0, mode: mode, prefillSchedule: "serial", leaderID: "local", ranks: Self.ranks(peerID: "peer"), promptTokens: 1024,
                  outputTokens: 256, firstTokenSeconds: 1, decodeTokensPerSecond: decode, absolute: absolute, measured: false, alone: [],
                  aloneAsFast: [], fitsNow: fitsNow, needsBytes: nil, explanation: [])
        }
        let shares = [Share(local: true, firstLayer: 0, endLayer: 45, share: 0.5), Share(local: false, firstLayer: 0, endLayer: 45, share: 0.5)]
        func mode(_ raw: String, lanes: Int, measured: Double? = nil, planned: Bool = true) -> ClusterSetupPlanSummary.Mode {
            var mode = ClusterSetupPlanSummary.Mode(mode: raw, shares: planned ? shares : [], servedDecodeTokensPerSecond: measured)
            mode.concurrentRequests = lanes; mode.publicTraffic = true
            return mode
        }
        let tp = ClusterGenerationMode.tensorParallel.rawValue, pp = ClusterGenerationMode.pipeline.rawValue
        let modes = [mode(tp, lanes: 8), mode(pp, lanes: 1)]
        // Two M5 Ultras, nothing measured yet: the planner's predictions, then the requests at once.
        let advice = OnboardingLive.modeAdvice(modes, listed: plan(tp, fitsNow: true, decode: 92),
                                               families: [plan(pp, fitsNow: true, decode: 38)], throughDarkbloom: true, serving: false)
        #expect(advice == ClusterOnboardingModeAdvice(mode: tp, reason: "faster here and serves up to 8 requests at once"))
        // A memory-tight pair: the pipeline's own plan fits now, tensor parallel's doesn't.
        let tight = OnboardingLive.modeAdvice(modes, listed: plan(pp, fitsNow: true, decode: 20),
                                              families: [plan(tp, fitsNow: false, decode: 30)], throughDarkbloom: true, serving: false)
        #expect(tight == ClusterOnboardingModeAdvice(mode: pp, reason: "the only one that fits these Macs now"))
        // Only relative figures and one lane each: no evidence, no guess.
        let equal = [mode(tp, lanes: 1), mode(pp, lanes: 1)]
        let unknown = OnboardingLive.modeAdvice(equal, listed: plan(tp, fitsNow: true, decode: 1, absolute: false),
                                                families: [plan(pp, fitsNow: true, decode: 1, absolute: false)], throughDarkbloom: false, serving: false)
        #expect(unknown == ClusterOnboardingModeAdvice(mode: nil, reason: "no speed is measured or predicted for these Macs yet"))
        // A mode with no plan of its own (its split is empty) is not recommended.
        let lone = OnboardingLive.modeAdvice([mode(tp, lanes: 8, planned: false), mode(pp, lanes: 1)], listed: plan(pp, fitsNow: true, decode: 20),
                                             families: [], throughDarkbloom: true, serving: false)
        #expect(lone?.mode == pp)
        // While a model serves, the split still reads "decided when it loads" (round 4); the recommendation stands.
        #expect(OnboardingLive.modeSplit(shares, here: "this Mac", there: "the other Mac", serving: true) == ClusterOnboardingMode.decidedWhenItLoads)
        let serving = OnboardingLive.modeAdvice(modes, listed: plan(tp, fitsNow: false, decode: 92),
                                                families: [plan(pp, fitsNow: false, decode: 38)], throughDarkbloom: true, serving: true)
        #expect(serving?.mode == tp)
    }

    /// R3-2 (the round-3 re-test): the joining Mac's window ended "After a restart, this Mac serves again by itself"
    /// while its service ran from an SSH session (`starts_at_login: false`): the ending read what this run's service
    /// setup left at its start. The running service's own word, read when the line is said, decides.
    @Test func theLoginStateIsReadWhenTheLineIsSaid() {
        #expect(OnboardingLive.startsAtLogin(now: false, setUp: true) == false, "a service replaced since: the running one decides")
        #expect(OnboardingLive.startsAtLogin(now: true, setUp: false) == true)
        #expect(OnboardingLive.startsAtLogin(now: nil, setUp: true) == true, "no running service's word: this run's setup")
        #expect(OnboardingLive.startsAtLogin(now: nil, setUp: nil) == nil)
    }

    @Test func freshPeerFactsReplaceSavedMachineAndPlanLabelsWithoutChangingIntent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        let before = try fixture.store.readRecord().leadership
        // Supply the report at the authenticated exchange boundary; no transport,
        // hardware probe, installed service, or live pairing store is exercised.
        live.rememberPeerReport(Self.report(), memberID: fixture.pairing.peerMemberID)
        #expect(live.peerName == "Apple M5 Max, 96 GB")
        #expect(live.resume().peerName == "Apple M5 Max, 96 GB")
        let shares = live.planShares(Self.ranks(peerID: fixture.pairing.peerMemberID), localName: "Apple M3 Ultra, 256 GB")
        #expect(shares.map(\.name) == ["Apple M3 Ultra, 256 GB", "Apple M5 Max, 96 GB"])
        #expect(shares.map(\.layers) == [16, 16])
        let line = ClusterOnboardingDeployment.line(model: "fixture-model", mode: "pipeline", shares: shares)
        #expect(line.contains("M5 Max"))
        #expect(!line.contains("M4 Max"))
        #expect(live.resume().modelName == "saved-model")
        #expect(try fixture.store.readRecord().leadership == before)
    }

    @Test func missingFreshReportKeepsSavedName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        #expect(live.peerName == "Apple M4 Max, 128 GB")
        #expect(live.resume().role == .leader)
        #expect(live.resume().modelName == "saved-model")
    }

    @Test func changedPeerPinCannotResumeOrReuseOldPeerDisplayFacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: String(repeating: "c", count: 64))
        live.rememberPeerReport(Self.report(), memberID: fixture.pairing.peerMemberID)
        #expect(live.resume().role == nil)
        #expect(live.resume().modelName == nil)
        #expect(live.peerName == "Apple M4 Max, 128 GB")
        #expect(try fixture.store.readRecord().leadership?.peerPin == Fixture.peerPin)
    }

    /// 2026-11-03: the pairing was the production app's and this Mac signed with the DevNet app's key; `darkbloom cluster`
    /// showed the usual menu while every start failed "pair again". The resume says so; the part this Mac plays stays.
    @Test func aPairingMadeWithAnotherKeyIsSaidSo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let changed = fixture.live(peerPin: Fixture.peerPin, currentPin: String(repeating: "d", count: 64)).resume()
        #expect(changed.pairingProblem == .keyChanged)
        #expect(changed.role == .leader && changed.modelName == "saved-model")
        #expect(fixture.live(peerPin: Fixture.peerPin).resume().pairingProblem == nil, "the key it paired with")
        #expect(fixture.live(peerPin: Fixture.peerPin, currentPin: nil).resume().pairingProblem == nil, "no key read: nothing claimed")
        #expect(fixture.live(peerPin: String(repeating: "c", count: 64), currentPin: String(repeating: "d", count: 64)).resume()
            == ClusterOnboardingResume(), "a pairing the record does not name resumes nothing, as before")
    }

    /// Pair again on a Mac that holds no pairing removes nothing and goes on to pair.
    /// Round 9 (validator D's delta check at f7e9619637): the status shows the leading Mac's latest test. A failed test
    /// that isn't a start (the serving model's test, its Retry, the scope switch's, a re-test) after a passing start: the
    /// ✗ with an accurate note, never the start's time under a ✓.
    @Test func aFailedTestAfterAPassingStartIsShownNotTheStartsTime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.updateRecord { $0.startTestPassed = "in 0.61 s" }
        let live = OnboardingLive(context: fixture.context, store: fixture.store, settings: fixture.settings, readPairing: { nil },
                                  currentPin: { nil })
        live.settleTest(.failure(.init(["The test request got an empty answer."])))
        let serving = "Serving Qwen 3.8 27B (pipeline) at http://localhost:8000 (local only)."
        let lines = OnboardingLive.outcomeLines(record: try fixture.store.readRecord(), pending: false, local: true,
                                                model: "Qwen 3.8 27B", serving: serving)
        #expect(lines == [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "The test request got an empty answer"),
                          "The last test from the leading Mac failed."])
        #expect(try fixture.store.readRecord().startTestPassed == nil)
        #expect(ClusterOnboardingReady.lastTestFailedNote == "The last test from the leading Mac failed.")
        // A pass afterwards is the latest test: its time again, no failure.
        live.settleTest(.success(["in 0.58 s"]))
        #expect(OnboardingLive.outcomeLines(record: try fixture.store.readRecord(), pending: false, local: true, model: "Qwen 3.8 27B",
                                            serving: serving) == [serving, "Test response in 0.58 s (the leading Mac's test)"])
    }

    /// The DevNet traffic run (2026-11-04): a pair set to serve through Darkbloom whose start is over and that serves on
    /// the leading Mac's API has no cluster approval attached, so the coordinator never has it. Its status said "Serving …
    /// (earning through Darkbloom)."; it says it isn't serving through Darkbloom and why, where it answers meanwhile, then
    /// the test.
    @Test func aPairThatIsNotOfferedSaysSoAndWhy() {
        let ready = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.this, port: 8001, split: "tensor parallel")
        let test = "Test response in 0.23 s (the leading Mac's test)"
        let outcome = [ready.summary(model: "Qwen 3.8 27B") + ClusterOnboardingDriver.servesWords(ready: ready) + ".", test]
        let note = "Not offered for pairing: this Mac's check refused it: " + ClusterApprovalAttachment.unequalTensorSharesServeLocally
        let lines = OnboardingLive.notOfferedLines(model: "Qwen 3.8 27B", ready: ready, note: note, outcome: outcome)
        #expect(lines == [
            "Qwen 3.8 27B is not serving yet: not offered to Darkbloom (this Mac's check refused it: "
                + ClusterApprovalAttachment.unequalTensorSharesServeLocally + ").",
            "Meanwhile it answers only on the local API at http://localhost:8001 (no Darkbloom traffic).",
            test])
        #expect(!lines.joined().contains("earning") && !lines.joined().contains("Serving "))
        // The other Mac reads it as not serving, with that reason (`ClusterOnboardingNotServing.reason(inStatusLine:)`).
        #expect(ClusterOnboardingReady.isNotOffered(ClusterOnboardingNotServing.reason(inStatusLine: lines[0])))
        // No note: none attached. A coordinator that can't take a cluster member: said so, whatever the note.
        #expect(OnboardingLive.notOfferedLines(model: "m", ready: ready, note: nil, outcome: ["x"]).first
            == "m is not serving yet: not offered to Darkbloom (no cluster approval is attached to its setup).")
        var unsupported = ready
        unsupported.notice = ClusterLocalServing.notice
        #expect(OnboardingLive.notOfferedLines(model: "m", ready: unsupported, note: note, outcome: ["x"]).first
            == "m is not serving yet: not offered to Darkbloom (the coordinator could not be reached or has no cluster support).")
    }

    /// The DevNet traffic run (2026-11-04): `cluster status` repeated the setup screen's "Then choose Retry, or serve
    /// locally only now." under an offered pair's reason, but it has no Retry, and neither has the other Mac's window.
    @Test func anOfferedPairsWaitNamesNoScreenChoice() {
        let reason = ClusterOnboardingNotServing.notVerified(ClusterOnboardingMacName.this)
        let wait = "waiting for the coordinator to pair both Macs"
        let lines = OnboardingLive.offeredWaitLines(model: "Qwen 3.8 27B", reason: reason, wait: wait)
        #expect(lines == [ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: reason)])
        #expect(!lines.joined().contains("Retry") && ClusterOnboardingNotServing.remedy(forReason: reason)?.contains("Retry") == true)
        #expect(OnboardingLive.offeredWaitLines(model: "m", reason: nil, wait: wait) == ["m is not serving yet: \(wait)."])
    }

    /// The leading Mac's setup step reaches the Mac that joined in its status reply (a user's report, 2026-11-04: the
    /// joined Mac said only "waiting for the other Mac" while the leader waited at its own screen): with this build's
    /// version, only while the screen that set it runs, a refusal after its screen ended, and nothing from an older
    /// leader's reply.
    @Test func theLeadersSetupStepIsPublishedInItsStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        #expect(live.currentLeaderStep() == nil, "nothing set: no step")
        live.publishStep(.init(.localNetwork))
        let reply = live.execute(.init(op: .status), leaderID: "leader")
        #expect(reply.step == .init(.localNetwork, version: ProviderCore.version))
        let decoded = try JSONDecoder().decode(ClusterControlReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded.step?.words == "it's waiting for Allow on its Local Network prompt", "the step crosses the cable")
        let older = try JSONDecoder().decode(ClusterControlReply.self, from: Data(#"{"lines":["Stopped."],"failed":false}"#.utf8))
        #expect(older.step == nil && older.lines == ["Stopped."], "an older leader's reply reads as no step")

        // A screen that is gone (its process no longer runs) leaves a step that no longer counts; its refusal still does.
        let gone = ClusterOnboardingLeaderStepMark(step: .init(.modelList), pid: Int32.max, started: 1, at: Date().timeIntervalSince1970)
        try fixture.store.updateRecord { $0.onboardingStep = gone }
        #expect(live.currentLeaderStep() == nil)
        let refused = ClusterOnboardingLeaderStepMark(step: .init(.refused, reason: ClusterSetupPlanning.differentBuilds), pid: Int32.max,
                                                      started: 1, at: Date().timeIntervalSince1970)
        try fixture.store.updateRecord { $0.onboardingStep = refused }
        #expect(live.currentLeaderStep()?.differentBuilds == true, "the planner's different-builds blocker is the refusal the joined Mac reads")
        live.publishStep(nil)
        #expect(try fixture.store.readRecord().onboardingStep == nil)
    }

    /// A running start publishes its own outcome: while its mark is live, another test writes nothing.
    @Test func aRunningStartsOutcomeIsNeverOverwrittenByAnotherTest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = getppid()
        let started = try #require(OnboardingLive.processStarted(other))
        try fixture.store.updateRecord { $0.registrationPending = .init(pid: other, started: started) }
        let live = OnboardingLive(context: fixture.context, store: fixture.store, settings: fixture.settings, readPairing: { nil },
                                  currentPin: { nil })
        live.settleTest(.failure(.init(["The test request got an empty answer."])))
        let record = try fixture.store.readRecord()
        #expect(record.lastTestFailure == nil && record.startTestFailure == nil && record.registrationPending?.pid == other)
    }

    /// A scope switch clears both published results: the pair starts again another way, so neither holds any more.
    @Test func aScopeSwitchClearsBothResults() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var record = try fixture.store.readRecord()
        record.startTestPassed = "in 0.61 s"
        record.startTestFailure = "The test request got an empty answer"
        OnboardingLive.savingScope(.localOnly(bind: "0.0.0.0"), &record)
        #expect(record.startTestPassed == nil && record.startTestFailure == nil && record.leadership?.scope.isLocalOnly == true)
    }

    /// The DevNet run on the M5 Ultra pair (A-9): choosing Pipeline for GLM-5.3-Flash loaded tensor parallel again. Its
    /// listing put Pipeline first while its plan was tensor parallel, so the choice was taken for the planner's own and
    /// nothing was kept. The person's family is kept, and the adopt plans again in it.
    @Test func aChosenPipelineIsKeptWhenTheListingPutsItFirst() {
        let family = OnboardingLive.keptFamily("pipeline_v1")
        #expect(family != nil && OnboardingLive.replansInFamily(family, listedPlanMode: "tensor_parallel_v1"),
                "pipeline kept, and the tensor-parallel plan planned again in it")
        #expect(!OnboardingLive.replansInFamily(OnboardingLive.keptFamily("tensor_parallel_v1"), listedPlanMode: "tensor_parallel_v1"),
                "the listed plan's own mode: adopted as listed")
    }

    /// The same through `useMode` itself, on GLM's listing (Pipeline first, the plan tensor parallel): the family it
    /// keeps for the adopt is the one chosen, either way.
    @Test func useModeKeepsTheChosenFamilyWhateverTheListingsOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        let modes = ["pipeline_v1", "tensor_parallel_v1"].map { ClusterOnboardingMode(mode: $0, split: nil, measuredTokensPerSecond: nil) }
        let glm = "zai-org/GLM-5.3-Flash"
        live.useListing([.init(title: "Z.ai: GLM-5.3-Flash", lines: [], blocker: nil, modelID: glm, split: "tensor parallel", modes: modes)])
        live.useMode(0, "pipeline_v1")
        let pipeline = live.keptFamily(forModel: glm)
        #expect(pipeline == .pipeline && OnboardingLive.replansInFamily(pipeline, listedPlanMode: "tensor_parallel_v1"),
                "Pipeline kept, and the tensor-parallel plan planned again in it")
        live.useMode(0, "tensor_parallel_v1")
        let tensor = live.keptFamily(forModel: glm)
        #expect(tensor == .tensorParallel && !OnboardingLive.replansInFamily(tensor, listedPlanMode: "tensor_parallel_v1"),
                "the plan's own family: adopted as listed")
        live.useMode(1, "pipeline_v1")
        #expect(live.keptFamily(forModel: glm) == .tensorParallel, "a choice the list doesn't have changes nothing")
    }

    @Test func unpairWithoutAPairingChangesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = OnboardingLive(context: fixture.context, store: fixture.store, settings: fixture.settings, readPairing: { nil },
                                  currentPin: { nil })
        #expect(try live.unpair().get().isEmpty)
        #expect(try fixture.store.readRecord().leadership?.peerPin == Fixture.peerPin)
    }

    @Test func peerDisplaySanitizesControlCharactersAndUsesRemoteMemory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        var report = Self.report()
        report.mac.chip = "Apple M5\nMax\u{1B}"
        live.rememberPeerReport(report, memberID: fixture.pairing.peerMemberID)
        #expect(live.peerName == "Apple M5Max, 96 GB")
    }

    /// Two Macs of one kind share a hardware name: the lines name them "this Mac" and "the other Mac (<its name>)" for
    /// the screen that shows them, which for an answer to a forwarded command is the other Mac's (2026-10-25).
    @Test func linesNameTheTwoMacsForTheScreenThatShowsThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        live.rememberPeerReport(Self.report(), memberID: fixture.pairing.peerMemberID)
        #expect(live.here == "this Mac" && live.hereShort == "this Mac")
        #expect(live.there == "the other Mac (Apple M5 Max, 96 GB)" && live.thereShort == "the other Mac")
        let forwarded = live.answeringForwarded { (live.here, live.hereShort, live.there, live.thereShort) }
        #expect(forwarded.0.hasPrefix("the other Mac (") && forwarded.1 == "the other Mac")
        #expect(forwarded.2 == "this Mac" && forwarded.3 == "this Mac")
        #expect(live.here == "this Mac", "the other Mac's wording ends with the answer")
        #expect(live.startsWhenItAnswers.hasPrefix("This Mac's cluster service starts the other Mac's part"))

        let ranks = Self.ranks(peerID: fixture.pairing.peerMemberID)
        let shown = live.planShares(ranks, localName: "Apple M3 Ultra, 256 GB", perspective: true)
        #expect(shown.map(\.label) == ["this Mac", "the other Mac"])
        #expect(ClusterOnboardingDeployment.sharesWords(mode: "pipeline_v1", shares: shown) == "this Mac 16 layers / the other Mac 16 layers")
        let answered = live.answeringForwarded { live.planShares(ranks, localName: "Apple M3 Ultra, 256 GB", perspective: true) }
        #expect(answered.map(\.label) == ["the other Mac", "this Mac"])
        // A line recorded for both Macs names each by its hardware.
        #expect(live.planShares(ranks, localName: "Apple M3 Ultra, 256 GB").allSatisfy { $0.label == nil })
    }

    /// Each Mac's teardown summary names it as the screen does; the other Mac's own answer names itself by hardware.
    @Test func teardownSummariesAreRenamedForTheScreen() {
        let other = "The other Mac (Apple M5 Ultra, 256 GB)"
        #expect(OnboardingLive.teardownLine("Apple M5 Ultra, 256 GB: nothing left running", mac: other) == other + ": nothing left running")
        #expect(OnboardingLive.teardownLine("Apple M5 Ultra, 256 GB: still running: a cluster process", mac: "This Mac")
            == "This Mac: still running: a cluster process")
        #expect(OnboardingLive.teardownLine("garbled", mac: "This Mac") == "garbled")
        // The update's release check still reads both renamed summaries.
        #expect(ClusterOnboardingUpdate.released(["This Mac: nothing left running", other + ": nothing left running"]))
    }

    /// One line per artifact and name (2026-10-25: GLM-5.3-Flash offered from the folder whose manifest the cluster
    /// worker pins, and "not supported on a cluster yet" right under it for the catalog's clone of the same bytes).
    @Test func connectsFirstLineAsksForMacOSPermissions() {
        #expect(ClusterOnboardingDriver.approvalsLine(remote: false) == "Allow macOS permissions.")
        #expect(ClusterOnboardingDriver.approvalsLine(remote: true)
            == "Allow macOS permissions here and on this Mac's screen (Screen Sharing if headless).")
    }

    @Test func theModelListShowsOneLinePerArtifactAndName() {
        typealias A = OnboardingLive.ListedArtifact
        let glm = A(aggregate: "3aae", files: "f1")
        let offered = ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel"], blocker: nil,
                                                   modelID: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp")
        let clone = ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: [], blocker: ClusterSetupPlanning.notClusterModel,
                                                 modelID: "glm-5.3-flash")
        func kept(_ choices: [ClusterOnboardingModelChoice], _ artifacts: [A?], servable: Set<String> = ["3aae"]) -> [(Int, String?)] {
            OnboardingLive.presentedChoices(choices, artifacts: artifacts, servable: servable).map { ($0.index, $0.choice.blocker) }
        }
        #expect(kept([offered, clone], [glm, glm]).map(\.0) == [0])
        // Only the copy the worker does not take: the model is still one a pair serves.
        #expect(kept([clone], [glm]).map(\.1) == [ClusterSetupPlanning.copyNotTaken])
        #expect(kept([clone], [glm], servable: []).map(\.1) == [ClusterSetupPlanning.notClusterModel], "an artifact this build does not serve")
        // Two catalog entries that share every file keep their own lines.
        var renamed = clone
        renamed.title = "Z.ai: GLM-5.3-Flash (8-bit)"
        #expect(kept([offered, renamed], [glm, glm]).map(\.0) == [0, 1])
        // Another files digest is another artifact; an older build's missing digest matches any.
        #expect(kept([offered, clone], [glm, A(aggregate: "3aae", files: "f2")]).map(\.0) == [0, 1])
        #expect(kept([offered, clone], [A(aggregate: "3aae", files: nil), glm]).map(\.0) == [0])
        // Neither can be served: the reason that is not the copy itself is said once.
        var tooLarge = offered
        tooLarge.blocker = "Too large for these Macs together right now."
        #expect(kept([clone, tooLarge], [glm, glm]).map(\.0) == [1])
        let twice = kept([clone, clone], [glm, glm])
        #expect(twice.map(\.0) == [0] && twice.first?.1 == ClusterSetupPlanning.copyNotTaken)
        // A choice the list cannot compare (no artifact) is kept as it is.
        #expect(kept([offered, clone], [nil, glm]).map(\.0) == [0, 1])
        #expect(kept([offered], [glm]).first?.1 == nil)
    }

    private static func report() -> ClusterSetupReport {
        .init(observedAt: "2026-10-17T00:00:00Z", version: "fixture",
              mac: .init(profile: nil, profileError: nil, chip: "Apple M5 Max", physicalMemoryBytes: 96 << 30,
                         osVersion: "26.2", osMajor: 26, osMinor: 2, diskFreeBytes: nil, diskTotalBytes: nil),
              link: .init(state: "ready", guidance: nil, port: nil, portsDown: 0, thunderbolt: nil, thunderboltError: nil),
              saved: .notConfigured, inbox: nil, journal: .absent,
              memoryGuard: .init(decision: .clear, wiredBytes: nil, baselineBytes: nil, detail: nil),
              models: [], modelsError: nil, pairingCode: nil, checks: [])
    }

    private static func ranks(peerID: String) -> [ClusterSetupPlanSummary.Rank] {
        [1, 0].map { rank in
            .init(rank: rank, memberID: rank == 0 ? "local" : peerID, local: rank == 0,
                  firstLayer: rank * 16, endLayer: (rank + 1) * 16, weightsBytes: 1024, needBytes: 2048,
                  admissibleNowBytes: 4096, physicalMemoryBytes: 8192, fit: "now", fitDetail: "fits", shortBytes: nil)
        }
    }

    private struct Fixture {
        static let peerPin = String(repeating: "b", count: 64)
        let home: URL
        let store: ClusterSetupStore
        let context: LiveContext
        let settings: ClusterOnboardingOperations.LiveSettings
        let pairing: ClusterSetupLinkExchange.Pairing

        init() throws {
            home = try NativePairMemberFixture.privateRoot()
            let paths = try ClusterUserPaths(homeDirectory: home)
            store = ClusterSetupStore(paths: .init(paths: paths))
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: home.appendingPathComponent("provider.toml"),
                darkbloomExecutable: home.appendingPathComponent("not-executed"), sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
            context = LiveContext(paths: paths, store: store, settings: wizard,
                                  clean: ClusterConsoleFreeText(homeDirectory: home.path))
            settings = .init(service: .init(wizard: wizard, leaderArguments: [], followerArguments: []), serviceArguments: [])
            pairing = Self.pairing(peerPin: Self.peerPin)
            var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: pairing.localPin,
                peerPin: Self.peerPin, peerName: "Apple M4 Max, 128 GB", since: "2026-10-17T00:00:00Z")
            leadership.modelName = "saved-model"
            _ = try store.updateRecord { $0.leadership = leadership }
        }

        /// `currentPin`: this Mac's key as the live lookup would read it (the pairing's own by default; never the keychain).
        func live(peerPin: String, currentPin: String? = Self.localPin) -> OnboardingLive {
            let pairing = Self.pairing(peerPin: peerPin)
            return OnboardingLive(context: context, store: store, settings: settings, readPairing: { pairing }, currentPin: { currentPin })
        }

        static let localPin = String(repeating: "a", count: 64)

        func remove() { try? FileManager.default.removeItem(at: home) }

        private static func pairing(peerPin: String) -> ClusterSetupLinkExchange.Pairing {
            .init(localPin: localPin, peerPin: peerPin, clusterID: "fixture",
                  linkEpoch: "fixture", edgeID: "fixture", secretFile: "/not-read", secret: Data(repeating: 0, count: 32))
        }
    }
}
