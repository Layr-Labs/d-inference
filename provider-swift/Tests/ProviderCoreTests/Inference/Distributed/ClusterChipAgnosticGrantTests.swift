import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Chips and memory do not gate what a pair is offered (owner, 2026-10-14 08:25), and records never block the owner's
/// own serving (08:45): a passing cross-cable record qualifies its model, artifact and mode family for PUBLIC traffic on
/// any detected Apple silicon; a diverged record steers the planner and the start away from the exact shapes it ran;
/// an inconclusive record decides nothing. Synthetic Macs this bench never had: 2x M4 Max (128 GB or 64 GB: memory is
/// the planner's and the load gate's business), M4 Max + M3 Ultra, and M1-M5 Pro/Max/Ultra generally. Models are named
/// by registered identities so a cluster stage adapter runs each (the owner's only non-memory refusal).
@Suite struct ClusterChipAgnosticGrantTests {
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

    // Registered models standing in for the shapes of record each test needs.
    private let dense = "registered_qwen35_9b", cutdep = "registered_gpt_oss_20b", bad = "registered_nemotron35_lightning"
    private let mixed = "registered_qwen38_27b", unsure = "registered_qwen35_35b_a3b", flaky = "registered_gemma4_26b_8bit"

    /// The owner's serving of one placement: the offer, the plan, every rank's own start check and the whole-placement
    /// check agree.
    private func serves(_ order: [ClusterChipClass?], _ model: String, cuts: [Int], mode: ClusterGenerationMode = .pipeline,
                        _ decisions: ClusterPairServingDecisions) -> Bool {
        let placement = (try? ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", cuts: cuts,
                                                                         mode: mode, decisions: decisions)) != nil
        let ranks = order.enumerated().allSatisfy { rank, chipClass in
            (try? ClusterPairServingGrants.requireRank(rank, of: order.count, chipClass: chipClass, runtimeModelID: model, publicModelID: "p",
                                                       cuts: cuts, mode: mode, decisions: decisions)) != nil
        }
        let offered = ClusterPairServingGrants.startRefusal(order, cuts: cuts, mode: mode, runtimeModelID: model, publicModelID: "p",
                                                           decisions: decisions) == nil
        let planned = ClusterPairServingGrants.plannable(order, cuts: cuts, mode: mode, runtimeModelID: model, decisions: decisions)
        #expect(placement == offered && offered == planned && (ranks || !offered),
                "\(model) \(order.map { $0?.rawValue ?? "nil" }) cut \(cuts): placement \(placement) ranks \(ranks) offered \(offered) planned \(planned)")
        return placement && ranks && offered && planned
    }

    private func publicFamilies(_ model: String, _ decisions: ClusterPairServingDecisions) -> [ClusterPairServingModeFamily]? {
        (try? ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", decisions: decisions))?.families
    }

    /// A record from the bench pair qualifies its family for public traffic on Macs nobody qualified on; the owner is
    /// served there at any cut the planner chooses, in any mode, with or without a record of that mode.
    @Test func aPassOnAnyChipsQualifiesTheFamilyForAnyDetectedAppleSilicon() {
        let decisions = ClusterPairServingDecisions(records: [
            record(dense, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8]),
            record(dense, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_mtp_v1"),
        ])
        #expect(publicFamilies(dense, decisions) == [.pipeline, .handOff])
        for order in [[m4max, m4max], [m4max, m3u], [m3u, m4max], [m5u, m3u],
                      [cls("Apple M1 Pro"), cls("Apple M2 Ultra")], [cls("Apple M5 Pro"), cls("Apple M4 Max"), cls("Apple M1 Max")]] {
            for cut in [3, 8, 20] {
                let cuts = order.count == 2 ? [cut] : [cut, cut + 4]
                #expect(serves(order, dense, cuts: cuts, decisions), "\(order) \(cuts)")
            }
        }
        // The owner is served in a mode no record ran; public traffic stays bound to the passing families.
        #expect(serves([m4max, m4max], dense, cuts: [], mode: .tensorParallel, decisions))
        #expect(serves([m4max, m4max], dense, cuts: [16], mode: .pipelineMTP, decisions))
        #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: dense, mode: .tensorParallel, decisions: decisions)
            == ClusterPairOwnerServing.notYetQualified)
        #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: dense, mode: .pipeline, decisions: decisions)
            .hasPrefix("qualified for public traffic in pipeline"))
        // A model no stage adapter runs gets nothing; a chip with no class (a virtual machine) runs no rank.
        #expect(!serves([m4max, m4max], "registered_other", cuts: [16], decisions))
        #expect((try? ClusterPairServingGrants.requireRank(1, of: 2, chipClass: ClusterChipClass(chipName: "Apple M1 (Virtual)"),
                    runtimeModelID: dense, publicModelID: "p", cuts: [16], mode: .pipeline, decisions: decisions)) == nil)
    }

    /// GPT-OSS's rule for the owner: the cuts that diverged on M3 Ultra x M5 Ultra are steered away from there; every
    /// other shape on that combination is served (passed or never checked), and every other combination at any cut.
    @Test func aDivergedRecordSteersAwayFromOnlyItsShapes() throws {
        let pair = ["Apple M3 Ultra", "Apple M5 Ultra"]
        var records = [11, 12, 16].map { record(cutdep, pair, cuts: [$0]) }
        records += [4, 8, 10].map { record(cutdep, pair, cuts: [$0], verdicts: ["diverged"]) }
        let decisions = ClusterPairServingDecisions(records: records)
        #expect(decisions.withheld[cutdep] == nil)
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: cutdep, publicModelID: "p", decisions: decisions)
        #expect(grant.families == [.pipeline] && grant.withheldFamilies.isEmpty)
        for cut in [11, 12, 16, 6, 20] { #expect(serves([m3u, m5u], cutdep, cuts: [cut], decisions), "cut \(cut)") }
        for cut in [4, 8, 10] { #expect(!serves([m3u, m5u], cutdep, cuts: [cut], decisions), "cut \(cut)") }
        #expect(serves([m5u, m3u], cutdep, cuts: [11], decisions))
        for cut in [4, 6, 8, 10, 11, 20] {
            #expect(serves([m4max, m4max], cutdep, cuts: [cut], decisions), "2x M4 Max cut \(cut)")
            #expect(serves([m4max, m3u], cutdep, cuts: [cut], decisions), "M4 Max + M3 Ultra cut \(cut)")
            #expect(serves([m5u, cls("Apple M5 Max")], cutdep, cuts: [cut], decisions), "M5 Ultra + M5 Max cut \(cut)")
        }
        // A Mac that ran a diverged shape at its rank cannot see its partner's chip at its own start, so it refuses that
        // exact shape at that rank with any partner; the planner and the offer keep to the same rule and pick another cut.
        #expect(!serves([m3u, m4max], cutdep, cuts: [4], decisions))
        #expect(!serves([cls("Apple M5 Max"), m5u], cutdep, cuts: [4], decisions))
        #expect(serves([cls("Apple M5 Max"), m5u], cutdep, cuts: [6], decisions))
        #expect(serves([m3u, m4max], cutdep, cuts: [6], decisions))
        #expect(serves([m3u, m4max], cutdep, cuts: [11], decisions))
    }

    /// Public traffic: a family with only diverged records is withheld everywhere; a model with only diverged records is
    /// withheld as a whole; inconclusive records neither grant nor withhold. The owner is served away from the shapes
    /// that diverged, whatever the public grant says.
    @Test func publicGrantsNeedAPassAndTheOwnerIsServedAwayFromDivergedShapes() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record(bad, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], verdicts: ["diverged"]),
            record(mixed, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8]),
            record(mixed, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_v1", verdicts: ["diverged"]),
            record(unsure, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], verdicts: ["incomparable"]),
            record(unsure, ["Apple M4 Max", "Apple M4 Max"], cuts: [8]),
        ])
        #expect(decisions.withheld[bad] != nil && publicFamilies(bad, decisions) == nil)
        #expect(serves([m4max, m4max], bad, cuts: [8], decisions))
        #expect(!serves([m3u, m5u], bad, cuts: [8], decisions) && serves([m3u, m5u], bad, cuts: [12], decisions))
        #expect(serves([m4max, m4max], mixed, cuts: [20], decisions))
        #expect(serves([m4max, m4max], mixed, cuts: [8], mode: .phaseSplit, decisions))
        #expect(!serves([m3u, m5u], mixed, cuts: [8], mode: .phaseSplit, decisions))
        #expect(try ClusterPairServingGrants.grant(runtimeModelID: mixed, publicModelID: "p", decisions: decisions)
            .withheldFamilies.keys.sorted() == [.handOff])
        // The M4 Max pass qualifies the family for the bench pair too; the inconclusive bench run restricts nothing.
        #expect(publicFamilies(unsure, decisions) == [.pipeline])
        #expect(serves([m3u, m5u], unsure, cuts: [8], decisions) && serves([m3u, m5u], unsure, cuts: [30], decisions))
    }

    /// A pass that a divergence of the very same shape contradicts (a flaky or chip-reference-dependent result, as the
    /// Gemma 4 8-bit records on the M3 Ultra and the retired M5 Max) is no evidence for public traffic; for the owner the
    /// divergence steers away from that shape only.
    @Test func aPassContradictedByTheSameShapeDivergingQualifiesNothing() {
        let decisions = ClusterPairServingDecisions(records: [
            record(flaky, ["Apple M3 Ultra", "Apple M5 Max"], cuts: [12]),
            record(flaky, ["Apple M3 Ultra", "Apple M5 Max"], cuts: [12], verdicts: ["diverged"]),
            record(flaky, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [5], verdicts: ["diverged"]),
        ])
        #expect(decisions.granted.isEmpty && decisions.withheld[flaky] != nil)
        #expect(serves([m4max, m4max], flaky, cuts: [12], decisions))
        #expect(!serves([m3u, cls("Apple M5 Max")], flaky, cuts: [12], decisions))
    }

    /// The records this build ships: the launch models and the 9B are served on 2x M4 Max (both memory sizes are the
    /// same chip class; whether a model fits is the planner's), and on M4 Max + M3 Ultra, at any cut, as pipelines.
    @Test func theShippedRecordsServeTheLaunchModelsOnMacsTheBenchNeverHad() {
        let decisions = ClusterPairServingGrants.decisions
        for model in ["registered_qwen35_9b", "registered_qwen38_27b", "registered_mimo_v26_flash_mopd"] {
            for order in [[m4max, m4max], [m4max, m3u], [m3u, m4max]] {
                for cut in [4, 16, 24] {
                    #expect(serves(order, model, cuts: [cut], decisions), "\(model) \(order) cut \(cut)")
                }
            }
        }
        #expect(!serves([m3u, m5u], "registered_gpt_oss_20b", cuts: [4], decisions))
        #expect(serves([m3u, m5u], "registered_gpt_oss_20b", cuts: [11], decisions))
        #expect(serves([m4max, m4max], "registered_gpt_oss_20b", cuts: [4], decisions))
        // Gemma 4 8-bit: no public grant (its one pass is contradicted); its owner is served away from the diverged shape.
        #expect(decisions.withheld["registered_gemma4_26b_8bit"] != nil)
        #expect(serves([m4max, m4max], "registered_gemma4_26b_8bit", cuts: [6], decisions))
    }
}
