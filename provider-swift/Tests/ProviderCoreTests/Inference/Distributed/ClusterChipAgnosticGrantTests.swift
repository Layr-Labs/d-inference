import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Chips and memory do not gate what a pair is offered (owner, 2026-10-14): a passing cross-cable record approves its
/// model, artifact and mode family for any detected Apple silicon the planner can place it on; a diverged record
/// withholds only the exact chip combination and the shapes it covers; an inconclusive record neither grants nor
/// withholds. Synthetic Macs this bench never had: 2x M4 Max (128 GB or 64 GB: memory is the planner's and the load
/// gate's business, never the grant's), M4 Max + M3 Ultra, and M1-M5 Pro/Max/Ultra generally.
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
        // The offer, the plan, every rank's own start check and the whole-placement check agree (a model with no grant
        // at all is left to the start by the planner, which refuses it).
        let granted = (try? ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", decisions: decisions)) != nil
        #expect(placement == offered && (offered == planned || !granted) && (ranks || !offered),
                "\(model) \(order.map { $0?.rawValue ?? "nil" }) cut \(cuts): placement \(placement) ranks \(ranks) offered \(offered) planned \(planned)")
        return placement && ranks && offered && (planned || !granted)
    }

    /// A record from the bench pair approves its family for Macs nobody qualified on: 2x M4 Max, M4 Max + M3 Ultra in
    /// either order, and other Apple silicon, at any cut the planner chooses.
    @Test func aPassOnAnyChipsApprovesTheFamilyForAnyDetectedAppleSilicon() {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_dense", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8]),
            record("registered_dense", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_mtp_v1"),
        ])
        for order in [[m4max, m4max], [m4max, m3u], [m3u, m4max], [m5u, m3u],
                      [cls("Apple M1 Pro"), cls("Apple M2 Ultra")], [cls("Apple M5 Pro"), cls("Apple M4 Max"), cls("Apple M1 Max")]] {
            for cut in [3, 8, 20] {
                let cuts = order.count == 2 ? [cut] : [cut, cut + 4]
                #expect(serves(order, "registered_dense", cuts: cuts, decisions), "\(order) \(cuts)")
            }
        }
        // The mode family stays bound: a pipeline pass opens no tensor-parallel or speculative placement.
        #expect(!serves([m4max, m4max], "registered_dense", cuts: [16], mode: .tensorParallel, decisions))
        #expect(!serves([m4max, m4max], "registered_dense", cuts: [16], mode: .pipelineMTP, decisions))
        // A model nobody qualified, and a chip with no class (a virtual machine), get nothing.
        #expect(!serves([m4max, m4max], "registered_other", cuts: [16], decisions))
        #expect((try? ClusterPairServingGrants.requireRank(1, of: 2, chipClass: ClusterChipClass(chipName: "Apple M1 (Virtual)"),
                    runtimeModelID: "registered_dense", publicModelID: "p", cuts: [16], mode: .pipeline, decisions: decisions)) == nil)
    }

    /// GPT-OSS's rule, chip-agnostic: cuts that diverged on M3 Ultra x M5 Ultra stay withheld there, that combination is
    /// served only at the shapes a check passed in, and every other combination is served at any cut the planner picks.
    @Test func aDivergedRecordWithholdsOnlyItsChipCombinationAndShapes() throws {
        let pair = ["Apple M3 Ultra", "Apple M5 Ultra"]
        var records = [11, 12, 16].map { record("registered_cutdep", pair, cuts: [$0]) }
        records += [4, 8, 10].map { record("registered_cutdep", pair, cuts: [$0], verdicts: ["diverged"]) }
        let decisions = ClusterPairServingDecisions(records: records)
        #expect(decisions.withheld["registered_cutdep"] == nil)
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: "registered_cutdep", publicModelID: "p", decisions: decisions)
        #expect(grant.families == [.pipeline] && grant.withheldFamilies.isEmpty)
        // On the combination that diverged: passed shapes only, never a diverged one, never an unchecked one.
        for cut in [11, 12, 16] { #expect(serves([m3u, m5u], "registered_cutdep", cuts: [cut], decisions)) }
        for cut in [4, 8, 10, 6, 20] { #expect(!serves([m3u, m5u], "registered_cutdep", cuts: [cut], decisions), "cut \(cut)") }
        #expect(!serves([m5u, m3u], "registered_cutdep", cuts: [11], decisions))
        // Elsewhere: the passing records approve the family at any cut.
        for cut in [4, 6, 8, 10, 11, 20] {
            #expect(serves([m4max, m4max], "registered_cutdep", cuts: [cut], decisions), "2x M4 Max cut \(cut)")
            #expect(serves([m4max, m3u], "registered_cutdep", cuts: [cut], decisions), "M4 Max + M3 Ultra cut \(cut)")
            #expect(serves([m5u, cls("Apple M5 Max")], "registered_cutdep", cuts: [cut], decisions), "M5 Ultra + M5 Max cut \(cut)")
        }
        // A Mac that ran a diverged shape at its rank cannot see its partner's chip at its own start, so it refuses that
        // exact shape at that rank with any partner; the planner and the offer keep to the same rule and pick another cut.
        #expect(!serves([m3u, m4max], "registered_cutdep", cuts: [4], decisions))
        #expect(!serves([cls("Apple M5 Max"), m5u], "registered_cutdep", cuts: [4], decisions))
        #expect(serves([cls("Apple M5 Max"), m5u], "registered_cutdep", cuts: [6], decisions))
        #expect(serves([m3u, m4max], "registered_cutdep", cuts: [6], decisions))
        #expect(serves([m3u, m4max], "registered_cutdep", cuts: [11], decisions))
    }

    /// A family with only diverged records is withheld everywhere (a pass approves; nothing passed); a model with only
    /// diverged records is withheld as a whole; inconclusive records neither grant nor withhold.
    @Test func withoutAPassNothingIsApprovedAndInconclusiveDecidesNothing() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_bad", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], verdicts: ["diverged"]),
            record("registered_mixed", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8]),
            record("registered_mixed", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_v1", verdicts: ["diverged"]),
            record("registered_unsure", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], verdicts: ["incomparable"]),
            record("registered_unsure", ["Apple M4 Max", "Apple M4 Max"], cuts: [8]),
        ])
        #expect(decisions.withheld["registered_bad"] != nil)
        #expect(!serves([m4max, m4max], "registered_bad", cuts: [8], decisions))
        #expect(serves([m4max, m4max], "registered_mixed", cuts: [20], decisions))
        #expect(!serves([m4max, m4max], "registered_mixed", cuts: [8], mode: .phaseSplit, decisions))
        #expect(try ClusterPairServingGrants.grant(runtimeModelID: "registered_mixed", publicModelID: "p", decisions: decisions)
            .withheldFamilies.keys.sorted() == [.handOff])
        // The M4 Max pass approves the family for the bench pair too; the inconclusive bench run restricts nothing.
        #expect(serves([m3u, m5u], "registered_unsure", cuts: [8], decisions))
        #expect(serves([m3u, m5u], "registered_unsure", cuts: [30], decisions))
    }

    /// A pass that a divergence of the very same shape contradicts (a flaky or chip-reference-dependent result, as the
    /// Gemma 4 8-bit records on the M3 Ultra and the retired M5 Max) is no evidence: it approves nothing anywhere.
    @Test func aPassContradictedByTheSameShapeDivergingApprovesNothing() {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_flaky", ["Apple M3 Ultra", "Apple M5 Max"], cuts: [12]),
            record("registered_flaky", ["Apple M3 Ultra", "Apple M5 Max"], cuts: [12], verdicts: ["diverged"]),
            record("registered_flaky", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [5], verdicts: ["diverged"]),
        ])
        #expect(decisions.granted.isEmpty && decisions.withheld["registered_flaky"] != nil)
        #expect(!serves([m4max, m4max], "registered_flaky", cuts: [12], decisions))
        #expect(!serves([m3u, cls("Apple M5 Max")], "registered_flaky", cuts: [12], decisions))
    }

    /// The records this build ships: the launch models and the 9B are offered on 2x M4 Max (both memory sizes are the
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
        // GPT-OSS keeps its rule on the bench pair and is approved elsewhere by its passing records.
        #expect(!serves([m3u, m5u], "registered_gpt_oss_20b", cuts: [4], decisions))
        #expect(serves([m3u, m5u], "registered_gpt_oss_20b", cuts: [11], decisions))
        #expect(serves([m4max, m4max], "registered_gpt_oss_20b", cuts: [4], decisions))
        // Gemma 4 8-bit: its one pass is contradicted by a divergence of the same shape, so nothing approves it.
        #expect(decisions.withheld["registered_gemma4_26b_8bit"] != nil)
        #expect(!serves([m4max, m4max], "registered_gemma4_26b_8bit", cuts: [6], decisions))
    }
}
