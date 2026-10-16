import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import ProviderCore

/// The owner's flow (2026-10-14 08:45): detect -> pick a model -> memory check -> the planner picks tensor parallel or
/// pipeline. A pair refuses a model for its owner only when no sharded layout fits both Macs' memory (the planner's
/// refusal) or when no cluster stage adapter runs the model. Qualification records never block owner serving: they
/// gate PUBLIC traffic (the coordinator's parity qualification, unchanged) and steer the planner away from the exact
/// shapes that diverged on a chip combination. A model with no record is served for its owner and says, in one line,
/// that it is not yet qualified for public traffic. Synthetic Macs: 2x M4 Max (64 GB or 128 GB: memory is the
/// planner's and the load gate's business), M3 Ultra x M5 Ultra (the bench pair the GPT-OSS records ran on).
@Suite struct ClusterOwnerServingTests {
    private func record(_ model: String, _ chips: [String], cuts: [Int], mode: String = "pipeline_v1",
                        verdicts: [String] = ["exact"], artifact: String = String(repeating: "a", count: 64)) -> ClusterPairQualificationRecord {
        .init(runtimeModelID: model, artifactSHA256: artifact,
              ranks: chips.enumerated().map { .init(rank: $0.offset, chip: $0.element, operatingSystem: "27.0") },
              cuts: cuts, generationMode: mode, prefillSchedule: "serial_v1", chunkTokens: 512, promptTokens: 4096, outputTokens: 128,
              transport: "jaccl", pairReportSHA256: String(repeating: "b", count: 64), pairReportCreatedUTC: "2026-10-12T00:00:00Z",
              comparisons: verdicts.map { .init(referenceChip: chips.last, verdict: $0, firstDivergenceIndex: 7,
                                                gapInULPs: $0 == "diverged" ? 9 : 1, nearTieThresholdULPs: 4, allowed: ["cut"]) },
              producer: "test")
    }
    private func cls(_ name: String) -> ClusterChipClass { ClusterChipClass(chipName: name)! }
    private var m3u: ClusterChipClass { cls("Apple M3 Ultra") }
    private var m5u: ClusterChipClass { cls("Apple M5 Ultra") }
    private var m4max: ClusterChipClass { cls("Apple M4 Max") }

    /// The owner's start, offer and planner agree for one placement.
    private func ownerServes(_ order: [ClusterChipClass?], _ model: String, cuts: [Int], mode: ClusterGenerationMode = .pipeline,
                             artifact: String? = nil, _ decisions: ClusterPairServingDecisions) -> Bool {
        let ranks = order.enumerated().allSatisfy { rank, chipClass in
            (try? ClusterPairServingGrants.requireRank(rank, of: order.count, chipClass: chipClass, runtimeModelID: model, publicModelID: "p",
                                                       artifactSHA256: artifact, cuts: cuts, mode: mode, decisions: decisions)) != nil
        }
        let offered = ClusterPairServingGrants.startRefusal(order, cuts: cuts, mode: mode, runtimeModelID: model, publicModelID: "p",
                                                           artifactSHA256: artifact, decisions: decisions) == nil
        let planned = ClusterPairServingGrants.plannable(order, cuts: cuts, mode: mode, runtimeModelID: model, artifactSHA256: artifact,
                                                         decisions: decisions)
        let placement = (try? ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", cuts: cuts,
                                                                         mode: mode, decisions: decisions)) != nil
        #expect(ranks == offered && offered == planned && planned == placement,
                "\(model) \(order.map { $0?.rawValue ?? "nil" }) \(cuts) \(mode.rawValue): ranks \(ranks) offered \(offered) planned \(planned) placement \(placement)")
        return ranks && offered && planned && placement
    }

    /// A model nobody has qualified is planned and served for its owner on 2x M4 Max, in every sharded mode the runtime
    /// has (tensor parallel included, with no tensor-parallel record), and says it is not yet qualified for public
    /// traffic. The public grant is unchanged: it still needs a passing record.
    @Test func aModelWithNoRecordIsServedForItsOwnerOnly() throws {
        let none = ClusterPairServingDecisions(records: [])
        let owner = try ClusterPairServingGrants.ownerServing(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", decisions: none)
        #expect(owner.publicGrant == nil)
        #expect(owner.publicTrafficLine == ClusterPairOwnerServing.notYetQualified)
        #expect(ClusterPairOwnerServing.notYetQualified == "not yet qualified for public traffic")
        for (mode, cuts) in [(ClusterGenerationMode.pipeline, [16]), (.pipelineCompactDecode, [16]), (.pipelineMTP, [20]), (.tensorParallel, [])] {
            #expect(ownerServes([m4max, m4max], "registered_qwen35_9b", cuts: cuts, mode: mode, none), "\(mode.rawValue)")
        }
        // Public traffic still needs a record: the public grant refuses it, in its own words.
        #expect(throws: ClusterPairServingRefusal.self) {
            _ = try ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", decisions: none)
        }
        #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: "registered_qwen35_9b", mode: .pipeline, decisions: none)
            == "not yet qualified for public traffic")
    }

    /// With a passing pipeline record the pipeline family is qualified for public traffic, tensor parallel is not; both
    /// are served for the owner.
    @Test func publicTrafficFollowsThePassingRecordsOnly() throws {
        let decisions = ClusterPairServingDecisions(records: [record("registered_qwen38_27b", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8])])
        let owner = try ClusterPairServingGrants.ownerServing(runtimeModelID: "registered_qwen38_27b", publicModelID: "p", decisions: decisions)
        #expect(owner.publicGrant?.families == [.pipeline])
        #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: "registered_qwen38_27b", mode: .pipeline, decisions: decisions)
            .hasPrefix("qualified for public traffic"))
        #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: "registered_qwen38_27b", mode: .tensorParallel, decisions: decisions)
            == "not yet qualified for public traffic")
        #expect(ownerServes([m4max, m4max], "registered_qwen38_27b", cuts: [], mode: .tensorParallel, decisions))
        #expect(ownerServes([m4max, cls("Apple M5 Pro")], "registered_qwen38_27b", cuts: [40], decisions))
    }

    /// The other owner refusal: a model no cluster stage adapter of this build runs is refused, with that reason.
    @Test func aModelWithNoStageAdapterIsRefusedWithThatReason() {
        let none = ClusterPairServingDecisions(records: [])
        do {
            _ = try ClusterPairServingGrants.ownerServing(runtimeModelID: "registered_future_model", publicModelID: "future/model", decisions: none)
            Issue.record("a model with no stage adapter was served")
        } catch let refusal as ClusterPairServingRefusal {
            #expect(refusal.reason == .noStageAdapter)
            #expect(refusal.description.contains("no cluster stage adapter") && refusal.description.contains("future/model"))
        } catch { Issue.record("\(error)") }
        #expect(!ownerServes([m4max, m4max], "registered_future_model", cuts: [8], none))
    }

    /// GPT-OSS's rule for the owner: on M3 Ultra x M5 Ultra the cuts that diverged (4, 8, 10) are steered away from,
    /// and ANY other cut is served (not only the passed 11, 12, 16); on 2x M4 Max every cut is served.
    @Test func gptOSSIsSteeredToACutThatDidNotDiverge() {
        let decisions = ClusterPairServingGrants.decisions
        let model = "registered_gpt_oss_20b"
        for cut in [4, 8, 10] { #expect(!ownerServes([m3u, m5u], model, cuts: [cut], decisions), "diverged cut \(cut)") }
        for cut in [1, 5, 6, 9, 11, 12, 16, 20] { #expect(ownerServes([m3u, m5u], model, cuts: [cut], decisions), "cut \(cut)") }
        for cut in [4, 6, 8, 10, 12] { #expect(ownerServes([m4max, m4max], model, cuts: [cut], decisions), "2x M4 Max cut \(cut)") }
        // The records' own rule, as the planner and the start apply it.
        let records = ClusterPairServingGrants.records(runtimeModelID: model)
        #expect(records.admits(chipClasses: [m3u, m5u], cuts: [6], mode: .pipeline))
        #expect(records.admits(chipClasses: [m5u, m3u], cuts: [12], mode: .pipeline))
        #expect(!records.admits(chipClasses: [m3u, m5u], cuts: [10], mode: .pipelineCompactDecode))
    }

    /// On a combination that diverged, any shape that did not diverge is admitted; a family whose every record diverged
    /// (no pass at all) is still served for the owner away from its diverged shapes. Gemma 4 8-bit: its one pass is
    /// contradicted by a divergence of the same shape, so it has no public grant, and the owner is served elsewhere.
    @Test func onADivergedCombinationAnyShapeThatDidNotDivergeIsAdmitted() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_qwen35_9b", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], verdicts: ["diverged"]),
        ])
        #expect(decisions.withheld["registered_qwen35_9b"] != nil)
        #expect(!ownerServes([m3u, m5u], "registered_qwen35_9b", cuts: [8], decisions))
        #expect(ownerServes([m3u, m5u], "registered_qwen35_9b", cuts: [12], decisions))
        #expect(ownerServes([m4max, m4max], "registered_qwen35_9b", cuts: [8], decisions))
        let owner = try ClusterPairServingGrants.ownerServing(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", decisions: decisions)
        #expect(owner.publicGrant == nil && owner.publicTrafficLine == "not yet qualified for public traffic")

        let shipped = ClusterPairServingGrants.decisions
        #expect(shipped.withheld["registered_gemma4_26b_8bit"] != nil)
        #expect(ownerServes([m4max, m4max], "registered_gemma4_26b_8bit", cuts: [6], shipped))
        #expect(!ownerServes([m3u, cls("Apple M5 Max")], "registered_gemma4_26b_8bit", cuts: [12], shipped))
    }

    /// The planner refuses only when every placeable shape diverged on these chips: then no shape is plannable.
    @Test func everyShapeDivergedRefusesThoseShapesOnly() {
        let decisions = ClusterPairServingDecisions(records: [4, 8, 12, 16].map {
            record("registered_qwen35_9b", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [$0], verdicts: ["diverged"])
        })
        for cut in [4, 8, 12, 16] {
            #expect(!ClusterPairServingGrants.plannable([m3u, m5u], cuts: [cut], mode: .pipeline, runtimeModelID: "registered_qwen35_9b",
                                                        decisions: decisions))
            #expect(ClusterPairServingGrants.plannable([m5u, m3u], cuts: [cut], mode: .pipeline, runtimeModelID: "registered_qwen35_9b",
                                                       decisions: decisions))
        }
    }

    /// An installed artifact other than the one the records ran has no record of its own: served for its owner, not
    /// for public traffic (its public grant still refuses it as another artifact).
    @Test func anUnqualifiedArtifactIsServedForTheOwnerOnly() throws {
        let decisions = ClusterPairServingDecisions(records: [record("registered_qwen35_9b", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8])])
        let other = String(repeating: "c", count: 64)
        let owner = try ClusterPairServingGrants.ownerServing(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: other,
                                                              decisions: decisions)
        #expect(owner.publicGrant == nil && owner.publicTrafficLine == "not yet qualified for public traffic")
        #expect(ownerServes([m4max, m4max], "registered_qwen35_9b", cuts: [16], artifact: other, decisions))
        #expect(throws: ClusterPairServingRefusal.self) {
            _ = try ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: other, decisions: decisions)
        }
    }

    /// A Mac whose chip has no class (a virtual machine) still cannot run a rank: kept for owner serving.
    @Test func aChipWithNoClassStillRunsNoRank() {
        let none = ClusterPairServingDecisions(records: [])
        #expect((try? ClusterPairServingGrants.requireRank(0, of: 2, chipClass: ClusterChipClass(chipName: "Apple M1 (Virtual)"),
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p", cuts: [16], mode: .pipeline, decisions: none)) == nil)
        #expect((try? ClusterPairServingGrants.requireRank(0, of: 2, chipClass: m4max,
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p", cuts: [16], mode: nil, decisions: none)) == nil)
    }
}

/// Time budgets derived from the setup (whose request deadline the planner derived from the chosen placement's
/// predicted prefill and decode on the detected Macs) and the installed artifact's size, instead of one typed row per
/// model: a model without a row (GPT-OSS 20B, Gemma 4 26B QAT4) gets budgets, and every figure the old rows were
/// sized from (the pair's own measurements across the cable) is inside them.
@Suite struct ClusterDerivedTimeBudgetTests {
    private let gb = 1_000_000_000.0

    @Test func aModelWithoutARowGetsBudgets() throws {
        // GPT-OSS 20B (13.8 GB) and Gemma 4 26B QAT4 (15.6 GB) on a plan whose request deadline is 600 s.
        for bytes in [13.8, 15.6] {
            let derived = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: 600, maximumPromptTokens: 8192,
                artifactBytes: Int64(bytes * gb), largestStageShare: 0.6, lastRankLoadsEverything: false)
            #expect(derived.budgets.startupAllowanceNanoseconds >= 90_000_000_000)
            #expect(derived.budgets.firstTokenBaseMilliseconds == 10_000)
            #expect(derived.basis.count >= 3)
        }
    }

    /// The first-token allowance reaches the setup's request deadline at the longest prompt, so it is at least the
    /// planner's margin (3x) over the predicted prefill; a short prompt gets its share.
    @Test func theFirstTokenAllowanceFollowsThePlannedDeadline() {
        let derived = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: 330, maximumPromptTokens: 8192,
            artifactBytes: Int64(15.1 * gb), largestStageShare: 0.75, lastRankLoadsEverything: false).budgets
        let atLongest = derived.firstTokenBaseMilliseconds + 8192 * derived.firstTokenMillisecondsPerPromptToken
        #expect(atLongest >= 330_000 && atLongest < 330_000 + 8192)
        // A deadline at the codec's floor still leaves the base and one millisecond a token.
        let floor = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: 1, maximumPromptTokens: 8192,
            artifactBytes: Int64(5 * gb), largestStageShare: 0.5, lastRankLoadsEverything: false).budgets
        #expect(floor.firstTokenBaseMilliseconds == 10_000 && floor.firstTokenMillisecondsPerPromptToken == 1)
    }

    /// Every derived timing is one `ClusterWorkerPair` accepts (it refuses a wait above one minute before it looks at its
    /// workers). Round 6f hardware: the 27B's setup derived a clean-stop wait above a minute and both ranks ended at
    /// startup with "Pair waits must be between one nanosecond and one minute".
    @Test func everyDerivedTimingIsOneThePairAccepts() {
        for seconds in [1, 60, 330, 900, 3_600] {
            let timing = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: seconds, maximumPromptTokens: 8192,
                artifactBytes: Int64(15.1 * gb), largestStageShare: 0.75, lastRankLoadsEverything: false).budgets.pairTiming
            do {
                _ = try ClusterWorkerPair(workers: [], startupDeadline: 0, timing: timing)
                Issue.record("an empty pair formed")
            } catch ClusterWorkerOwnerError.invalid(let message) {
                #expect(message != "Pair waits must be between one nanosecond and one minute", "\(seconds) s deadline: \(timing)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    /// Every figure the per-model rows were sized from stays inside the derived budgets: the slowest ready time
    /// (pipeline and phase split) times three, and the pair's first token at its longest measured prompt for a setup
    /// whose deadline the planner derived from a prediction no faster than what was measured.
    @Test func derivedBudgetsCoverWhatThePairMeasured() {
        // (model, artifact GB, largest stage share, slowest pipeline ready s, slowest phase-split ready s,
        //  prompt, pair first token s at that prompt, slower Mac decode tok/s)
        let measured: [(String, Double, Double, Double, Double, Int, Double, Double)] = [
            ("9B", 5.0, 0.75, 7.3, 12.3, 30_720, 15.61, 67), ("27B", 15.1, 0.75, 13.7, 23.0, 30_720, 39.91, 23),
            ("35B A3B", 20.9, 0.75, 25.8, 29.0, 16_384, 8.68, 65), ("36 A3B", 21.3, 0.75, 25.1, 30.6, 16_384, 8.33, 65),
            ("Bonsai", 8.6, 0.75, 9.4, 11.8, 16_384, 45.52, 29), ("Nemotron", 19.1, 0.75, 16.8, 19.7, 16_384, 8.28, 77),
            ("MiMo", 172.9, 0.71, 63.7, 63.7, 16_384, 37.66, 28),
        ]
        for (name, bytes, share, pipelineReady, splitReady, prompt, firstToken, decode) in measured {
            // The planner's own deadline for a prediction exactly as fast as measured (the longest request: this prompt,
            // 128 outputs), as `ClusterPlacementRequestLimits` derives it.
            let predicted = firstToken + 128 / decode
            let deadline = min(3600, max(60, Int((3 * predicted + 30).rounded(.up))))
            let pipeline = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: deadline, maximumPromptTokens: prompt,
                artifactBytes: Int64(bytes * gb), largestStageShare: share, lastRankLoadsEverything: false).budgets
            let split = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: deadline, maximumPromptTokens: prompt,
                artifactBytes: Int64(bytes * gb), largestStageShare: share, lastRankLoadsEverything: true).budgets
            #expect(Double(pipeline.startupAllowanceNanoseconds) / 1e9 >= 3 * pipelineReady, "\(name) pipeline startup")
            #expect(Double(split.startupAllowanceNanoseconds) / 1e9 >= 3 * splitReady, "\(name) phase-split startup")
            #expect(split.startupAllowanceNanoseconds >= pipeline.startupAllowanceNanoseconds, "\(name): a whole-model load takes longer")
            #expect(pipeline.startupAllowanceNanoseconds <= 3_600_000_000_000, "\(name): never an hour")
            let allowance = Double(pipeline.firstTokenBaseMilliseconds + Int64(prompt) * pipeline.firstTokenMillisecondsPerPromptToken) / 1000
            #expect(allowance >= 3 * firstToken, "\(name): first token \(firstToken) s against \(allowance) s")
            #expect(pipeline.admissionWaitNanoseconds == 5_000_000_000)
            #expect(pipeline.cleanStopWaitNanoseconds >= 10_000_000_000 && pipeline.cleanStopWaitNanoseconds <= 60_000_000_000)
            #expect(pipeline.shutdownAcknowledgementNanoseconds >= 2_000_000_000 && pipeline.stopMarginNanoseconds >= 15_000_000_000)
        }
    }
}
