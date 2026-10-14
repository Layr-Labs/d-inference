import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Pair-serving grants are derived from qualification records only, for any
/// chips and any number of ranks (owner, "universal mechanisms"; chip-agnostic,
/// 2026-10-14): synthetic records for Macs this bench never had.
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
    private func allows(_ classes: [ClusterChipClass?], _ model: String, _ decisions: ClusterPairServingDecisions,
                        mode: ClusterGenerationMode = .pipeline, cuts: [Int]? = nil) -> Bool {
        (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: cuts, mode: mode,
                                                        decisions: decisions)) != nil
    }

    @Test func grantsFollowTheRecordsForAnyChipsAndRankCounts() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_dense", ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record("registered_dense", ["Apple M4 Pro", "Apple M3 Ultra"], cuts: [12], mode: "phase_split_v1", verdicts: ["exact"]),
            record("registered_wide", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [10, 20]),
        ])
        // A pass approves its mode family on any chips, in any rank order.
        #expect(allows([cls("Apple M2 Max"), cls("Apple M2 Max")], "registered_dense", decisions))
        #expect(allows([cls("Apple M4 Pro"), cls("Apple M3 Ultra")], "registered_dense", decisions, mode: .phaseSplit))
        #expect(allows([cls("Apple M4 Pro"), cls("Apple M3 Ultra")], "registered_dense", decisions))
        #expect(allows([cls("Apple M3 Ultra"), cls("Apple M4 Pro")], "registered_dense", decisions, mode: .phaseSplit))
        #expect(allows([cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")], "registered_wide", decisions))
        #expect(allows([cls("Apple M4 Max"), cls("Apple M2 Ultra"), cls("Apple M1 Ultra")], "registered_wide", decisions))
        #expect(allows([cls("Apple M5 Pro"), cls("Apple M5 Pro"), cls("Apple M5 Pro")], "registered_wide", decisions))
        let wide = try ClusterPairServingGrants.grant(runtimeModelID: "registered_wide", publicModelID: "p", decisions: decisions)
        #expect(wide.qualifiedChipClasses == [cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")])
        #expect(wide.qualifications == [.init(chipClasses: [cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")], cuts: [10, 20], mode: .pipeline)])
        // A model nobody qualified, and a claimed or classless chip, get nothing.
        #expect(!allows([cls("Apple M2 Max"), cls("Apple M2 Max")], "registered_other", decisions))
        #expect(!allows([nil, cls("Apple M2 Max")], "registered_dense", decisions))
    }

    @Test func aDivergedCutWithholdsOnlyItsShapeAndUndecidedOrUnusableRecordsGrantNothing() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["divergedAtNearTie", "diverged"]),
            record("registered_unsure", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["incomparable"]),
            record("registered_loopback", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], transport: "local-socket-test"),
            record("registered_virtual", ["Apple M1 (Virtual)", "Apple M2 Max"], cuts: [16]),
            record("registered_disorder", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [20, 10]),
        ])
        #expect(decisions.ignored == 3)
        #expect(decisions.granted.map(\.runtimeModelID) == ["registered_split"] && decisions.withheld.isEmpty)
        // The cut that diverged is withheld on the chips it ran; the passed cut is served; other chips are not restricted.
        let m2 = cls("Apple M2 Max"), m4 = cls("Apple M4 Max")
        do {
            try ClusterPairServingGrants.requirePlacement([m2, m2], runtimeModelID: "registered_split", publicModelID: "p", cuts: [8],
                                                          mode: .pipeline, decisions: decisions)
            Issue.record("a diverged shape was allowed")
        } catch let refusal as ClusterPairServingRefusal {
            #expect(refusal.reason == .shapeNotQualified(rank: 0, chipClass: m2, cuts: [8], mode: .pipeline,
                                                         qualified: "apple_m2_max then apple_m2_max at cut 16 (pipeline_v1)"))
        }
        #expect(allows([m2, m2], "registered_split", decisions, cuts: [16]) && !allows([m2, m2], "registered_split", decisions, cuts: [12]))
        #expect(allows([m4, m4], "registered_split", decisions, cuts: [8]))
        // A family with a diverged record needs the placement's cuts.
        #expect(!allows([m4, m4], "registered_split", decisions))
        // Diverged with nothing passed: withheld as a whole.
        let only = ClusterPairServingDecisions(records: [record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["diverged"])])
        let why = try #require(only.withheld["registered_split"])
        #expect(why.contains("diverged at cut 8") && why.contains("9.0 ulp") && why.contains("output 7"))
        for model in ["registered_unsure", "registered_loopback", "registered_virtual", "registered_disorder"] {
            do {
                try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: cls("Apple M2 Max"), runtimeModelID: model, publicModelID: "p",
                                                         mode: .pipeline, decisions: decisions)
                Issue.record("\(model) was allowed")
            } catch let refusal as ClusterPairServingRefusal {
                #expect(refusal.reason == .noGrant, "\(model)")
            }
        }
        // A record whose stored verdict disagrees with its comparisons is not used.
        let edited = try record("registered_edited", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["diverged"]).encodedLine()
            .replacingOccurrences(of: "\"passed\":false", with: "\"passed\":true")
        let read = try ClusterPairQualificationRecord.decodeLines(edited)
        #expect(ClusterPairServingDecisions(records: read).ignored == 1)
    }

    @Test func shapesComeFromTheSameRecordsAndRestrictOnlyTheCombinationThatDiverged() {
        let m2 = cls("Apple M2 Max"), m4 = cls("Apple M4 Pro")
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_split", ["Apple M2 Max", "Apple M4 Pro"], cuts: [16]),
            record("registered_split", ["Apple M2 Max", "Apple M4 Pro"], cuts: [16]),
            record("registered_split", ["Apple M2 Max", "Apple M4 Pro"], cuts: [8], verdicts: ["diverged"]),
            record("registered_clean", ["Apple M2 Max", "Apple M4 Pro"], cuts: [12]),
            record("registered_loopback", ["Apple M2 Max", "Apple M4 Pro"], cuts: [8], verdicts: ["diverged"], transport: "local-socket-test"),
        ])
        let split = decisions.shapes(runtimeModelID: "registered_split")
        #expect(split.restrictsShapes && split.passed.count == 1 && split.failed.count == 1)
        #expect(split.admits(chipClasses: [m2, m4], cuts: [16], mode: .pipeline))
        #expect(!split.admits(chipClasses: [m2, m4], cuts: [8], mode: .pipeline))
        #expect(!split.admits(chipClasses: [m4, m2], cuts: [16], mode: .pipeline))
        // Another chip combination is not restricted; the Mac that ran the diverged shape at its rank refuses only that shape.
        let m4max = cls("Apple M4 Max")
        #expect(split.admits(chipClasses: [m4max, m4max], cuts: [8], mode: .pipeline))
        #expect(split.admits(chipClasses: [m2, m4max], cuts: [12], mode: .pipeline) && !split.admits(chipClasses: [m2, m4max], cuts: [8], mode: .pipeline))
        #expect(!split.admits(chipClasses: [m2, nil], cuts: [16], mode: .pipeline) && split.admits(chipClasses: [m4max, nil], cuts: [16], mode: .pipeline))
        #expect(!decisions.shapes(runtimeModelID: "registered_clean").restrictsShapes)
        // An unusable record restricts nothing; a model without records neither.
        #expect(!decisions.shapes(runtimeModelID: "registered_loopback").restrictsShapes)
        #expect(!decisions.shapes(runtimeModelID: "registered_none").restrictsShapes)
        #expect(ClusterPairServingGrants.records(runtimeModelID: "registered_split", decisions: decisions) == split)
    }

    /// Mode-bound grants (owner sign-off O9): a record grants only its own mode family, on any chips; a diverged record
    /// with no pass in its family withholds the family; an inconclusive one neither grants nor withholds.
    @Test func grantsAreBoundToTheModeFamilyTheirRecordsRan() throws {
        let m3 = cls("Apple M3 Ultra"), m5u = cls("Apple M5 Ultra"), m5 = cls("Apple M5 Max"), m2 = cls("Apple M2 Max"), m4 = cls("Apple M4 Max")
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_handoff", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_mtp_v1", verdicts: ["tokensEqualLogitsDiffer"]),
            record("registered_retired", ["Apple M3 Ultra", "Apple M5 Max"], cuts: [16]),
            record("registered_retired", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_v1"),
            record("registered_mixed", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "pipeline_compact_decode_v1"),
            record("registered_mixed", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1", verdicts: ["diverged"]),
            record("registered_unsure", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], verdicts: ["incomparable"]),
            record("registered_unsure", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1"),
        ])
        #expect(ClusterGenerationMode.pipelineCompactDecode.servingFamily == .pipeline && ClusterGenerationMode.phaseSplitMTP.servingFamily == .handOff)
        // A phase-split pass opens no pipeline shape.
        #expect(allows([m3, m5u], "registered_handoff", decisions, mode: .phaseSplitMTP))
        #expect(!allows([m3, m5u], "registered_handoff", decisions, mode: .pipeline))
        do {
            try ClusterPairServingGrants.requirePlacement([m3, m5u], runtimeModelID: "registered_handoff", publicModelID: "p", mode: .pipeline, decisions: decisions)
            Issue.record("a hand-off record opened a pipeline placement")
        } catch let refusal as ClusterPairServingRefusal {
            #expect(refusal.reason == .modeNotQualified(rank: 0, mode: .pipeline, granted: [.handOff]))
        }
        // Without the mode a placement is refused, whatever the records.
        #expect((try? ClusterPairServingGrants.requirePlacement([m3, m5u], runtimeModelID: "registered_handoff", publicModelID: "p", decisions: decisions)) == nil)
        // A retired chip's record approves its own family on any chips.
        #expect(allows([m3, m5], "registered_retired", decisions) && allows([m3, m5u], "registered_retired", decisions))
        #expect(allows([m3, m5u], "registered_retired", decisions, mode: .phaseSplit) && allows([m4, m4], "registered_retired", decisions, mode: .phaseSplit))
        let retired = try ClusterPairServingGrants.grant(runtimeModelID: "registered_retired", publicModelID: "p", decisions: decisions)
        #expect(retired.families == [.pipeline, .handOff] && retired.qualifiedChipClasses == [m3, m5, m5u])
        // A diverged hand-off record withholds the hand-off family only.
        #expect(allows([m2, m4], "registered_mixed", decisions) && !allows([m2, m4], "registered_mixed", decisions, mode: .phaseSplit))
        #expect(decisions.withheld["registered_mixed"] == nil)
        #expect(try ClusterPairServingGrants.grant(runtimeModelID: "registered_mixed", publicModelID: "p", decisions: decisions).withheldFamilies.keys.sorted() == [.handOff])
        // An inconclusive record neither grants nor withholds.
        #expect(!allows([m2, m4], "registered_unsure", decisions) && allows([m2, m4], "registered_unsure", decisions, mode: .phaseSplit))
        // The planner keeps to the same rule.
        #expect(ClusterPairServingGrants.plannable([m3, m5u], cuts: [8], mode: .phaseSplitMTP, runtimeModelID: "registered_handoff", decisions: decisions))
        #expect(!ClusterPairServingGrants.plannable([m3, m5u], cuts: [8], mode: .pipeline, runtimeModelID: "registered_handoff", decisions: decisions))
    }

    @Test func theShippedRecordsAreAllUsed() {
        #expect(!ClusterPairServingGrants.records.isEmpty)
        #expect(ClusterPairServingGrants.records.allSatisfy { $0.isConsistent })
        #expect(ClusterPairServingGrants.decisions.ignored == 0)
        #expect(ClusterPairServingGrants.records.allSatisfy { $0.producer == "darkbloom-cluster-pair-check record" })
    }
}
