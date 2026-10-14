import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Pair-serving grants are derived from qualification records only, for any
/// chips and any number of ranks (owner, "universal mechanisms"): synthetic
/// records for Macs this bench never had.
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
                        mode: ClusterGenerationMode = .pipeline) -> Bool {
        (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", mode: mode, decisions: decisions)) != nil
    }

    @Test func grantsFollowTheRecordsForAnyChipsAndRankCounts() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_dense", ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record("registered_dense", ["Apple M4 Pro", "Apple M3 Ultra"], cuts: [12], mode: "phase_split_v1", verdicts: ["exact"]),
            record("registered_wide", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [10, 20]),
        ])
        #expect(allows([cls("Apple M2 Max"), cls("Apple M2 Max")], "registered_dense", decisions))
        #expect(allows([cls("Apple M4 Pro"), cls("Apple M3 Ultra")], "registered_dense", decisions, mode: .phaseSplit))
        #expect(!allows([cls("Apple M4 Pro"), cls("Apple M3 Ultra")], "registered_dense", decisions))
        #expect(!allows([cls("Apple M3 Ultra"), cls("Apple M4 Pro")], "registered_dense", decisions, mode: .phaseSplit))
        #expect(allows([cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")], "registered_wide", decisions))
        #expect(!allows([cls("Apple M4 Max"), cls("Apple M2 Ultra"), cls("Apple M1 Ultra")], "registered_wide", decisions))
        let wide = try ClusterPairServingGrants.grant(runtimeModelID: "registered_wide", publicModelID: "p", decisions: decisions)
        #expect(wide.pipelineRankChipClasses == [cls("Apple M1 Ultra"), cls("Apple M2 Ultra")])
        #expect(wide.decodingRankChipClasses == [cls("Apple M4 Max")])
        #expect(wide.qualifications == [.init(chipClasses: [cls("Apple M1 Ultra"), cls("Apple M2 Ultra"), cls("Apple M4 Max")], cuts: [10, 20], mode: .pipeline)])
        // A model nobody qualified, and a claimed or classless chip, get nothing.
        #expect(!allows([cls("Apple M2 Max"), cls("Apple M2 Max")], "registered_other", decisions))
        #expect(!allows([nil, cls("Apple M2 Max")], "registered_dense", decisions))
    }

    @Test func oneDivergedCutWithholdsAndUndecidedOrUnusableRecordsGrantNothing() throws {
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["divergedAtNearTie", "diverged"]),
            record("registered_unsure", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["incomparable"]),
            record("registered_loopback", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], transport: "local-socket-test"),
            record("registered_virtual", ["Apple M1 (Virtual)", "Apple M2 Max"], cuts: [16]),
            record("registered_disorder", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [20, 10]),
        ])
        #expect(decisions.ignored == 3)
        #expect(decisions.granted.isEmpty)
        let why = try #require(decisions.withheld["registered_split"])
        #expect(why.contains("diverged at cut 8") && why.contains("9.0 ulp") && why.contains("output 7"))
        do {
            try ClusterPairServingGrants.requirePlacement([cls("Apple M2 Max"), cls("Apple M2 Max")], runtimeModelID: "registered_split",
                                                          publicModelID: "p", mode: .pipeline, decisions: decisions)
            Issue.record("a withheld model was allowed")
        } catch let refusal as ClusterPairServingRefusal {
            #expect(refusal.reason == .withheld(why))
        }
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

    @Test func shapesComeFromTheSameRecordsAndRestrictOnlyAModelWithADivergence() {
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
        #expect(!decisions.shapes(runtimeModelID: "registered_clean").restrictsShapes)
        // An unusable record restricts nothing; a model without records neither.
        #expect(!decisions.shapes(runtimeModelID: "registered_loopback").restrictsShapes)
        #expect(!decisions.shapes(runtimeModelID: "registered_none").restrictsShapes)
        #expect(ClusterPairServingGrants.records(runtimeModelID: "registered_split", decisions: decisions) == split)
    }

    /// Mode-bound grants (owner sign-off O9): a record grants only its own mode family and the chip classes in the roles
    /// it ran; a diverged record withholds its own family; an inconclusive one neither grants nor withholds.
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
        // A retired chip's record grants that chip only, in its own family.
        #expect(allows([m3, m5], "registered_retired", decisions) && !allows([m3, m5u], "registered_retired", decisions))
        #expect(allows([m3, m5u], "registered_retired", decisions, mode: .phaseSplit) && !allows([m3, m5], "registered_retired", decisions, mode: .phaseSplit))
        let retired = try ClusterPairServingGrants.grant(runtimeModelID: "registered_retired", publicModelID: "p", decisions: decisions)
        #expect(retired.families == [.pipeline, .handOff])
        #expect(retired.chipClasses(for: .decodingRank, family: .pipeline) == [m5] && retired.chipClasses(for: .decodingRank, family: .handOff) == [m5u])
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
