import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Public pair-serving grants are derived from qualification records only, for any chips and any number of ranks
/// (owner, "universal mechanisms"; chip-agnostic, 2026-10-14 08:25); the owner's own serving is refused only for a
/// model no cluster stage adapter runs, and records steer it away from the exact shapes that diverged (08:45).
/// Synthetic records for Macs this bench never had; models named by registered identities.
@Suite struct ClusterPairServingDecisionsTests {
    private func record(_ model: String, _ chips: [String], cuts: [Int], mode: String = "pipeline_v1",
                        verdicts: [String] = ["divergedAtNearTie"], transport: String = "jaccl") -> ClusterPairQualificationRecord {
        .init(runtimeModelID: model, artifactSHA256: String(repeating: "a", count: 64),
              ranks: chips.enumerated().map { .init(rank: $0.offset, chip: $0.element, operatingSystem: "27.0") },
              cuts: cuts, generationMode: mode, prefillSchedule: "serial_v1", chunkTokens: 512, promptTokens: 4096, outputTokens: 128, transport: transport,
              pairReportSHA256: String(repeating: "b", count: 64), pairReportCreatedUTC: "2026-10-12T00:00:00Z",
              comparisons: verdicts.map { .init(referenceChip: chips.last, verdict: $0, firstDivergenceIndex: 7,
                                                gapInULPs: $0 == "diverged" ? 9 : 1, nearTieThresholdULPs: 4, allowed: ["cut"]) },
              producer: "test")
    }
    private func cls(_ name: String) -> ClusterChipClass { ClusterChipClass(chipName: name)! }
    /// The owner's serving of a placement.
    private func allows(_ classes: [ClusterChipClass?], _ model: String, _ decisions: ClusterPairServingDecisions,
                        mode: ClusterGenerationMode = .pipeline, cuts: [Int]? = nil) -> Bool {
        (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: cuts, mode: mode,
                                                        decisions: decisions)) != nil
    }
    /// The mode families qualified for public traffic, nil without a public grant.
    private func publicFamilies(_ model: String, _ decisions: ClusterPairServingDecisions) -> [ClusterPairServingModeFamily]? {
        (try? ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", decisions: decisions))?.families
    }

    @Test func publicGrantsFollowTheRecordsForAnyChipsAndRankCounts() throws {
        let dense = "registered_qwen35_9b", wide = "registered_qwen38_27b"
        let decisions = ClusterPairServingDecisions(records: [
            record(dense, ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record(dense, ["Apple M4 Pro", "Apple M3 Ultra"], cuts: [12], mode: "phase_split_v1", verdicts: ["exact"]),
            record(wide, ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [10, 20]),
        ])
        // A pass qualifies its mode family for public traffic on any chips, in any rank order.
        #expect(publicFamilies(dense, decisions) == [.pipeline, .handOff] && publicFamilies(wide, decisions) == [.pipeline])
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: wide, publicModelID: "p", decisions: decisions)
        #expect(grant.qualifiedChipClasses == [cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")])
        #expect(grant.qualifications == [.init(chipClasses: [cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")], cuts: [10, 20], mode: .pipeline)])
        // The owner is served on any chips, in any order and rank count, in any mode.
        #expect(allows([cls("Apple M2 Max"), cls("Apple M2 Max")], dense, decisions))
        #expect(allows([cls("Apple M4 Pro"), cls("Apple M3 Ultra")], dense, decisions, mode: .phaseSplit))
        #expect(allows([cls("Apple M3 Ultra"), cls("Apple M4 Pro")], dense, decisions, mode: .tensorParallel, cuts: []))
        #expect(allows([cls("Apple M4 Max"), cls("Apple M2 Ultra"), cls("Apple M1 Ultra")], wide, decisions))
        #expect(allows([cls("Apple M5 Pro"), cls("Apple M5 Pro"), cls("Apple M5 Pro")], wide, decisions))
        // A model nobody qualified: no public grant, served for its owner; a model no adapter runs and a classless chip: nothing.
        #expect(publicFamilies("registered_qwen36_35b_a3b", decisions) == nil)
        #expect(allows([cls("Apple M2 Max"), cls("Apple M2 Max")], "registered_qwen36_35b_a3b", decisions))
        #expect(!allows([cls("Apple M2 Max"), cls("Apple M2 Max")], "registered_other", decisions))
        #expect(!allows([nil, cls("Apple M2 Max")], dense, decisions))
    }

    @Test func aDivergedCutIsSteeredAwayFromAndUndecidedOrUnusableRecordsQualifyNothing() throws {
        let split = "registered_qwen35_9b"
        let decisions = ClusterPairServingDecisions(records: [
            record(split, ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record(split, ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["divergedAtNearTie", "diverged"]),
            record("registered_qwen38_27b", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["incomparable"]),
            record("registered_qwen35_35b_a3b", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], transport: "local-socket-test"),
            record("registered_qwen36_35b_a3b", ["Apple M1 (Virtual)", "Apple M2 Max"], cuts: [16]),
            record("registered_nemotron35_lightning", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [20, 10]),
        ])
        #expect(decisions.ignored == 3)
        #expect(decisions.granted.map(\.runtimeModelID) == [split] && decisions.withheld.isEmpty)
        // The shape that diverged is not served on the chips it ran; every other shape is.
        let m2 = cls("Apple M2 Max"), m4 = cls("Apple M4 Max")
        do {
            try ClusterPairServingGrants.requirePlacement([m2, m2], runtimeModelID: split, publicModelID: "p", cuts: [8],
                                                          mode: .pipeline, decisions: decisions)
            Issue.record("a diverged shape was allowed")
        } catch let refusal as ClusterPairServingRefusal {
            #expect(refusal.reason == .shapeDiverged(rank: 0, chipClass: m2, cuts: [8], mode: .pipeline,
                                                     diverged: "apple_m2_max then apple_m2_max at cut 8 (pipeline_v1)"))
        }
        #expect(allows([m2, m2], split, decisions, cuts: [16]) && allows([m2, m2], split, decisions, cuts: [12]))
        #expect(allows([m4, m4], split, decisions, cuts: [8]))
        // A family with a diverged record needs the placement's cuts.
        #expect(!allows([m4, m4], split, decisions))
        // Diverged with nothing passed: no public grant, in words.
        let only = ClusterPairServingDecisions(records: [record(split, ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["diverged"])])
        let why = try #require(only.withheld[split])
        #expect(why.contains("diverged at cut 8") && why.contains("9.0 ulp") && why.contains("output 7"))
        #expect(allows([m2, m2], split, only, cuts: [12]))
        // Unusable or inconclusive records qualify nothing for public traffic; the owner is served.
        for model in ["registered_qwen38_27b", "registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_nemotron35_lightning"] {
            do {
                _ = try ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", decisions: decisions)
                Issue.record("\(model) was qualified for public traffic")
            } catch let refusal as ClusterPairServingRefusal {
                #expect(refusal.reason == .noGrant, "\(model)")
            }
            try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: m2, runtimeModelID: model, publicModelID: "p",
                                                     cuts: [16], mode: .pipeline, decisions: decisions)
        }
        // A record whose stored verdict disagrees with its comparisons is not used.
        let edited = try record("registered_qwen35_9b", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["diverged"]).encodedLine()
            .replacingOccurrences(of: "\"passed\":false", with: "\"passed\":true")
        let read = try ClusterPairQualificationRecord.decodeLines(edited)
        #expect(ClusterPairServingDecisions(records: read).ignored == 1)
    }

    @Test func shapesComeFromTheSameRecordsAndRestrictOnlyTheShapesThatDiverged() {
        let m2 = cls("Apple M2 Max"), m4 = cls("Apple M4 Pro")
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_qwen35_9b", ["Apple M2 Max", "Apple M4 Pro"], cuts: [16]),
            record("registered_qwen35_9b", ["Apple M2 Max", "Apple M4 Pro"], cuts: [16]),
            record("registered_qwen35_9b", ["Apple M2 Max", "Apple M4 Pro"], cuts: [8], verdicts: ["diverged"]),
            record("registered_qwen38_27b", ["Apple M2 Max", "Apple M4 Pro"], cuts: [12]),
            record("registered_qwen35_35b_a3b", ["Apple M2 Max", "Apple M4 Pro"], cuts: [8], verdicts: ["diverged"], transport: "local-socket-test"),
        ])
        let split = decisions.shapes(runtimeModelID: "registered_qwen35_9b")
        #expect(split.restrictsShapes && split.passed.count == 1 && split.failed.count == 1)
        #expect(split.admits(chipClasses: [m2, m4], cuts: [16], mode: .pipeline))
        #expect(!split.admits(chipClasses: [m2, m4], cuts: [8], mode: .pipeline))
        // On the combination that diverged, any shape that did not diverge: another cut, the other order.
        #expect(split.admits(chipClasses: [m2, m4], cuts: [12], mode: .pipeline) && split.admits(chipClasses: [m4, m2], cuts: [16], mode: .pipeline)
            && split.admits(chipClasses: [m4, m2], cuts: [8], mode: .pipeline))
        // Another chip combination is not restricted; the Mac that ran the diverged shape at its rank refuses only that shape.
        let m4max = cls("Apple M4 Max")
        #expect(split.admits(chipClasses: [m4max, m4max], cuts: [8], mode: .pipeline))
        #expect(split.admits(chipClasses: [m2, m4max], cuts: [12], mode: .pipeline) && !split.admits(chipClasses: [m2, m4max], cuts: [8], mode: .pipeline))
        // A rank with no class: refused only where it could complete a shape that diverged.
        #expect(split.admits(chipClasses: [m2, nil], cuts: [16], mode: .pipeline) && !split.admits(chipClasses: [m2, nil], cuts: [8], mode: .pipeline)
            && split.admits(chipClasses: [nil, m4max], cuts: [8], mode: .pipeline) && !split.admits(chipClasses: [nil, nil], cuts: [8], mode: .pipeline))
        #expect(!decisions.shapes(runtimeModelID: "registered_qwen38_27b").restrictsShapes)
        // An unusable record restricts nothing; a model without records neither.
        #expect(!decisions.shapes(runtimeModelID: "registered_qwen35_35b_a3b").restrictsShapes)
        #expect(!decisions.shapes(runtimeModelID: "registered_none").restrictsShapes)
        #expect(ClusterPairServingGrants.records(runtimeModelID: "registered_qwen35_9b", decisions: decisions) == split)
    }

    /// Mode-bound public grants (owner sign-off O9): a record qualifies only its own mode family, on any chips; a diverged
    /// record with no pass in its family withholds the family from public traffic; an inconclusive one neither grants nor
    /// withholds. The owner is served in any mode the runtime has, away from the shapes that diverged.
    @Test func publicGrantsAreBoundToTheModeFamilyTheirRecordsRan() throws {
        let m3 = cls("Apple M3 Ultra"), m5u = cls("Apple M5 Ultra"), m5 = cls("Apple M5 Max"), m2 = cls("Apple M2 Max"), m4 = cls("Apple M4 Max")
        let handoff = "registered_qwen38_27b", retired = "registered_qwen35_9b", mixed = "registered_ternary_bonsai_2_27b"
        let unsure = "registered_nemotron35_lightning"
        let decisions = ClusterPairServingDecisions(records: [
            record(handoff, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_mtp_v1", verdicts: ["tokensEqualLogitsDiffer"]),
            record(retired, ["Apple M3 Ultra", "Apple M5 Max"], cuts: [16]),
            record(retired, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_v1"),
            record(mixed, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "pipeline_compact_decode_v1"),
            record(mixed, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1", verdicts: ["diverged"]),
            record(unsure, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], verdicts: ["incomparable"]),
            record(unsure, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1"),
        ])
        #expect(ClusterGenerationMode.pipelineCompactDecode.servingFamily == .pipeline && ClusterGenerationMode.phaseSplitMTP.servingFamily == .handOff)
        // A phase-split pass qualifies no pipeline for public traffic; the owner is served as a pipeline all the same.
        #expect(publicFamilies(handoff, decisions) == [.handOff])
        #expect(allows([m3, m5u], handoff, decisions, mode: .phaseSplitMTP) && allows([m3, m5u], handoff, decisions, mode: .pipeline))
        #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: handoff, mode: .pipeline, decisions: decisions)
            == ClusterPairOwnerServing.notYetQualified)
        // Without the mode a placement is refused, whatever the records.
        do {
            try ClusterPairServingGrants.requirePlacement([m3, m5u], runtimeModelID: handoff, publicModelID: "p", decisions: decisions)
            Issue.record("a placement without its mode was allowed")
        } catch let refusal as ClusterPairServingRefusal {
            #expect(refusal.reason == .modeMissing(rank: 0))
        }
        // A retired chip's record qualifies its own family on any chips.
        let retiredGrant = try ClusterPairServingGrants.grant(runtimeModelID: retired, publicModelID: "p", decisions: decisions)
        #expect(retiredGrant.families == [.pipeline, .handOff] && retiredGrant.qualifiedChipClasses == [m3, m5, m5u])
        #expect(allows([m4, m4], retired, decisions, mode: .phaseSplit))
        // A diverged hand-off record withholds the hand-off family from public traffic, and its shape from the owner.
        #expect(allows([m2, m4], mixed, decisions, cuts: [12]) && !allows([m2, m4], mixed, decisions, mode: .phaseSplit, cuts: [12])
            && allows([m2, m4], mixed, decisions, mode: .phaseSplit, cuts: [16]))
        #expect(decisions.withheld[mixed] == nil)
        #expect(try ClusterPairServingGrants.grant(runtimeModelID: mixed, publicModelID: "p", decisions: decisions).withheldFamilies.keys.sorted() == [.handOff])
        // An inconclusive record neither grants nor withholds.
        #expect(publicFamilies(unsure, decisions) == [.handOff])
        #expect(allows([m2, m4], unsure, decisions) && allows([m2, m4], unsure, decisions, mode: .phaseSplit))
        // The planner keeps to the owner's rule.
        #expect(ClusterPairServingGrants.plannable([m3, m5u], cuts: [8], mode: .phaseSplitMTP, runtimeModelID: handoff, decisions: decisions))
        #expect(ClusterPairServingGrants.plannable([m3, m5u], cuts: [8], mode: .pipeline, runtimeModelID: handoff, decisions: decisions))
        #expect(!ClusterPairServingGrants.plannable([m2, m4], cuts: [12], mode: .phaseSplit, runtimeModelID: mixed, decisions: decisions))
    }

    @Test func theShippedRecordsAreAllUsed() {
        #expect(!ClusterPairServingGrants.records.isEmpty)
        #expect(ClusterPairServingGrants.records.allSatisfy { $0.isConsistent })
        #expect(ClusterPairServingGrants.decisions.ignored == 0)
        #expect(ClusterPairServingGrants.records.allSatisfy { $0.producer == "darkbloom-cluster-pair-check record" })
    }
}
