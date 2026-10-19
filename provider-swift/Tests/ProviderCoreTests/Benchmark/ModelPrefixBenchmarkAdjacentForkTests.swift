import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Actual harness validation/accounting helpers only. These host cases do
/// not qualify native state, encrypted files, model parity or timings.
@Suite("Same original donor adjacent fork qualification")
struct ModelPrefixBenchmarkAdjacentForkTests {
    private let next = ModelPrefixBenchmarkSpecification.AdjacentFork(
        sharedTokens: 16_400, forkTokens: 16_896, expectedRestoredTokens: 16_384)

    private func cell(
        shared: Int = 14_464,
        adjacent: ModelPrefixBenchmarkSpecification.AdjacentFork? = nil
    ) -> ModelPrefixBenchmarkSpecification.Case {
        .init(name: "long", donorTokens: 16_513, sharedTokens: shared,
            forkTokens: 16_896, demandedTokens: 14_336, adjacentFork: adjacent)
    }

    private func specification(
        _ cell: ModelPrefixBenchmarkSpecification.Case
    ) -> ModelPrefixBenchmarkSpecification {
        .init(modelID: "Qwen3.5-9B", openRouterID: "qwen/qwen3.5-9b",
            directory: "/tmp/synthetic-adjacent-specification",
            expectedWeightHash: String(repeating: "a", count: 64), modelType: "qwen3_5",
            outputPath: "/tmp/synthetic-adjacent-report.json", pairs: 1, outputTokens: 128,
            cases: [cell])
    }

    @Test("optional adjacency preserves old specs and enforces later aligned workload bounds")
    func optionalSpecificationAndBounds() throws {
        let ordinary = specification(cell())
        try ordinary.validate()
        let encoder = JSONEncoder()
        let oldData = try encoder.encode(ordinary)
        let oldObject = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        let oldCases = try #require(oldObject["cases"] as? [[String: Any]])
        #expect(oldCases[0]["adjacentFork"] == nil)
        #expect(try JSONDecoder().decode(ModelPrefixBenchmarkSpecification.self, from: oldData)
            .cases[0].adjacentFork == nil)

        let configured = specification(cell(adjacent: next))
        try configured.validate()
        let decoded = try JSONDecoder().decode(ModelPrefixBenchmarkSpecification.self,
            from: encoder.encode(configured))
        #expect(decoded.cases[0].adjacentFork?.expectedRestoredTokens == 16_384)
        #expect(decoded.cases[0].adjacentFork?.sharedTokens == 16_400)
        for invalid in [
            (shared: 16_400, fork: 16_896, restored: 0),
            (shared: 16_400, fork: 16_896, restored: 16_385),
            (shared: 16_400, fork: 16_896, restored: 14_336),
            (shared: 16_400, fork: 16_896, restored: 16_640),
            (shared: 14_464, fork: 16_896, restored: 16_384),
            (shared: 16_513, fork: 16_896, restored: 16_384),
            (shared: 16_400, fork: 16_400, restored: 16_384),
            (shared: 16_400, fork: 20_001, restored: 16_384),
        ] {
            let candidate = specification(cell(adjacent: .init(
                sharedTokens: invalid.shared, forkTokens: invalid.fork,
                expectedRestoredTokens: invalid.restored)))
            #expect(throws: ModelPrefixBenchmarkSpecification.ValidationFailure.self) {
                try candidate.validate()
            }
        }
    }

    @Test("actual declared prefixes and first divergence are checked before any import")
    func intendedForksMustActuallyDiverge() throws {
        let configured = cell(adjacent: next)
        let donor = Array(repeating: 1, count: 16_513)
        let middle = Array(donor.prefix(14_464)) + Array(repeating: 2, count: 2_432)
        let adjacent = Array(donor.prefix(16_400)) + Array(repeating: 3, count: 496)
        try ModelPrefixBenchmarkAdjacentFork.validateInputs(
            donor: donor, middle: middle, adjacent: adjacent, cell: configured)
        var prefixMismatch = middle
        prefixMismatch[0] = 4
        var noMiddleDivergence = middle
        noMiddleDivergence[14_464] = donor[14_464]
        var noAdjacentDivergence = adjacent
        noAdjacentDivergence[16_400] = donor[16_400]
        var adjacentPrefixMismatch = adjacent
        adjacentPrefixMismatch[0] = 4
        for (wrongMiddle, wrongAdjacent, wrongCell) in [
            (prefixMismatch, adjacent, configured),
            (noMiddleDivergence, adjacent, configured),
            (middle, noAdjacentDivergence, configured),
            (middle, adjacentPrefixMismatch, configured),
            (middle, Array(adjacent.dropLast()), configured),
            (middle, adjacent, cell()),
            (middle, adjacent, cell(shared: -1, adjacent: next)),
            (middle, adjacent, cell(adjacent: .init(
                sharedTokens: -1, forkTokens: 16_896, expectedRestoredTokens: 16_384))),
        ] {
            #expect(throws: ModelPrefixBenchmarkAdjacentFork.QualificationFailure.self) {
                try ModelPrefixBenchmarkAdjacentFork.validateInputs(
                    donor: donor, middle: wrongMiddle, adjacent: wrongAdjacent, cell: wrongCell)
            }
        }
        #expect(throws: ModelPrefixBenchmarkAdjacentFork.QualificationFailure.self) {
            try ModelPrefixBenchmarkAdjacentFork.validateInputs(
                donor: Array(donor.dropLast()), middle: middle, adjacent: adjacent, cell: configured)
        }
    }

    @Test("positive donor delta must exactly match monotonic completed archive counters")
    func donorCounterProof() {
        let before = ModelPrefixBenchmarkArchiveWrites(files: 3, bytes: 400)
        let after = ModelPrefixBenchmarkArchiveWrites(files: 5, bytes: 1_024)
        #expect(ModelPrefixBenchmarkAdjacentFork.donorDeltaMatches(
            before: before, after: after, delta: .init(files: 2, bytes: 624)))
        for (invalidBefore, invalidAfter, invalidDelta) in [
            (before, after, ModelPrefixBenchmarkArchiveWrites(files: 1, bytes: 624)),
            (before, after, .init(files: 2, bytes: 623)),
            (before, before, .init(files: 0, bytes: 0)),
            (after, before, .init(files: 2, bytes: 624)),
            (.init(files: Int.min, bytes: 400), after, .init(files: 2, bytes: 624)),
            (.init(files: 3, bytes: Int.min), after, .init(files: 2, bytes: 624)),
            (before, .init(files: -1, bytes: 1_024), .init(files: 2, bytes: 624)),
            (before, after, .init(files: -1, bytes: Int.min)),
        ] {
            #expect(!ModelPrefixBenchmarkAdjacentFork.donorDeltaMatches(
                before: invalidBefore, after: invalidAfter, delta: invalidDelta))
        }
    }

    @Test("hidden writes or incomplete non-donor observations invalidate same-donor proof")
    func interveningWritesMustStayZero() {
        let donor = ModelPrefixBenchmarkArchiveWrites(files: 5, bytes: 1_024)
        let zero = ModelPrefixBenchmarkArchiveWrites(files: 0, bytes: 0)
        let deltas = Array(repeating: zero, count: 5)
        #expect(ModelPrefixBenchmarkAdjacentFork.archiveWritesPreserved(
            donorAfter: donor, afterOriginal: donor, afterWarm: donor, afterCold: donor,
            nonDonorDeltas: deltas))
        let changed = ModelPrefixBenchmarkArchiveWrites(files: 6, bytes: 1_025)
        for (afterOriginal, afterWarm, afterCold, observed) in [
            (changed, donor, donor, deltas),
            (donor, changed, donor, deltas),
            (donor, donor, changed, deltas),
            (donor, donor, donor, Array(deltas.prefix(4))),
            (donor, donor, donor, deltas + [zero]),
            (donor, donor, donor, [zero, zero, .init(files: 1, bytes: 1), zero, zero]),
        ] {
            #expect(!ModelPrefixBenchmarkAdjacentFork.archiveWritesPreserved(
                donorAfter: donor, afterOriginal: afterOriginal, afterWarm: afterWarm,
                afterCold: afterCold, nonDonorDeltas: observed))
        }
        let invalid = ModelPrefixBenchmarkArchiveWrites(files: -1, bytes: 0)
        #expect(!ModelPrefixBenchmarkAdjacentFork.archiveWritesPreserved(
            donorAfter: invalid, afterOriginal: invalid, afterWarm: invalid, afterCold: invalid,
            nonDonorDeltas: deltas))
    }
}
