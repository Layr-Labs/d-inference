import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Cumulative physical archive counters, sampled only after the existing
/// completed-request idle and writer barriers. No namespace or prompt is emitted.
struct ModelPrefixBenchmarkArchiveWrites: Codable, Sendable, Equatable {
    let files: Int
    let bytes: Int
}

struct ModelPrefixBenchmarkAdjacentComparison: Codable, Sendable {
    let cell: String
    let pair: Int
    let sharedTokens: Int
    let expectedRestoredTokens: Int
    let originalDonorHintTokens: Int
    let outputMatches: Bool
    let sameOriginalDonorSessionAndScope: Bool
    let precedingRowsRetiredAndDrained: Bool
    let originalDonorWriteDeltaMatchesRow: Bool
    let noInterveningArchiveWrites: Bool
    let writesBeforeDonor: ModelPrefixBenchmarkArchiveWrites
    let writesAfterDonor: ModelPrefixBenchmarkArchiveWrites
    let writesAfterOriginalRows: ModelPrefixBenchmarkArchiveWrites
    let writesAfterAdjacentWarm: ModelPrefixBenchmarkArchiveWrites
    let writesAfterAdjacentCold: ModelPrefixBenchmarkArchiveWrites
    let restoredTokens: Int
    let replayTokens: Int
    let filesReadDelta: Int
    let bytesReadDelta: Int
}

/// Appended correctness witnesses. They use the original donor's exact
/// session/store/scope and never submit a second donor or spend capture writes.
/// Their fixed warm-before-cold order is excluded from policy-rate economics.
enum ModelPrefixBenchmarkAdjacentFork {
    enum QualificationFailure: Error { case invalidForkInputs }

    static func validateInputs(
        donor: [Int], middle: [Int], adjacent: [Int],
        cell: ModelPrefixBenchmarkSpecification.Case
    ) throws {
        guard let next = cell.adjacentFork,
            cell.sharedTokens >= 0, next.sharedTokens >= 0,
            donor.count == cell.donorTokens, middle.count == cell.forkTokens,
            adjacent.count == next.forkTokens,
            cell.sharedTokens < donor.count, cell.sharedTokens < middle.count,
            next.sharedTokens < donor.count, next.sharedTokens < adjacent.count,
            donor.prefix(cell.sharedTokens).elementsEqual(middle.prefix(cell.sharedTokens)),
            donor.prefix(next.sharedTokens).elementsEqual(adjacent.prefix(next.sharedTokens)),
            donor[cell.sharedTokens] != middle[cell.sharedTokens],
            donor[next.sharedTokens] != adjacent[next.sharedTokens]
        else { throw QualificationFailure.invalidForkInputs }
    }

    static func writes(_ fixture: ModelPrefixBenchmarkFixture) async throws
        -> ModelPrefixBenchmarkArchiveWrites
    {
        let cache = await fixture.session.cacheSnapshot()
        let counters = try #require(cache.checkpoints, "actual COMPLETE store counters are required")
        return .init(files: counters.filesWritten, bytes: counters.bytesWritten)
    }

    static func donorDeltaMatches(
        before: ModelPrefixBenchmarkArchiveWrites, after: ModelPrefixBenchmarkArchiveWrites,
        delta: ModelPrefixBenchmarkArchiveWrites
    ) -> Bool {
        before.files >= 0 && before.bytes >= 0
            && after.files >= before.files && after.bytes >= before.bytes
            && after.files - before.files == delta.files
            && after.bytes - before.bytes == delta.bytes
            && delta.files > 0 && delta.bytes > 0
    }

    static func archiveWritesPreserved(
        donorAfter: ModelPrefixBenchmarkArchiveWrites,
        afterOriginal: ModelPrefixBenchmarkArchiveWrites,
        afterWarm: ModelPrefixBenchmarkArchiveWrites,
        afterCold: ModelPrefixBenchmarkArchiveWrites,
        nonDonorDeltas: [ModelPrefixBenchmarkArchiveWrites]
    ) -> Bool {
        donorAfter.files >= 0 && donorAfter.bytes >= 0
            && afterOriginal == donorAfter && afterWarm == donorAfter && afterCold == donorAfter
            && nonDonorDeltas.count == 5
            && nonDonorDeltas.allSatisfy { $0.files == 0 && $0.bytes == 0 }
    }

    static func run(
        fixture: ModelPrefixBenchmarkFixture, cell: ModelPrefixBenchmarkSpecification.Case,
        pair: Int, scope: String, donorTokens: [Int], middleTokens: [Int],
        donor: ModelPrefixBenchmarkRow, originalRows: [ModelPrefixBenchmarkRow],
        writesBeforeDonor: ModelPrefixBenchmarkArchiveWrites,
        writesAfterDonor: ModelPrefixBenchmarkArchiveWrites,
        report: inout ModelPrefixBenchmarkReport
    ) async throws {
        let next = try #require(cell.adjacentFork)
        let adjacentTokens = fixture.promptTokens(count: next.sharedTokens)
            + fixture.promptTokens(count: next.forkTokens - next.sharedTokens, variant: 1)
        try validateInputs(donor: donorTokens, middle: middleTokens,
            adjacent: adjacentTokens, cell: cell)
        let afterOriginal = try await writes(fixture)
        let originalDrained = originalRows.count == 4
            && Set(originalRows.map(\.role)) == Set(["cold_fork", "novel_donor", "demanded_donor", "warm_fork"])
            && originalRows.allSatisfy {
                $0.cell == cell.name && $0.pair == pair && $0.checkpointWritesDrained
            }
        let originalNonDonorDeltas = originalRows.filter { $0.role != "demanded_donor" }
            .map { ModelPrefixBenchmarkArchiveWrites(files: $0.filesWrittenDelta, bytes: $0.bytesWrittenDelta) }
        // The literal session and scope used for the one original donor
        // are reused here. These are structural fixture proofs, not a
        // provider-issued namespace receipt or an account-level hit claim.
        let warm = try await fixture.run(cell: cell.name, pair: pair, role: "adjacent_warm_fork",
            tokens: adjacentTokens, scope: scope, target: 0, cacheEnabled: true)
        report.rows.append(warm)
        try report.save(to: fixture.specification.outputPath)
        let afterWarm = try await writes(fixture)
        let cold = try await fixture.run(cell: cell.name, pair: pair, role: "adjacent_cold_fork",
            tokens: adjacentTokens, scope: scope, target: 0, cacheEnabled: false)
        report.rows.append(cold)
        let afterCold = try await writes(fixture)
        let deltaMatches = donorDeltaMatches(
            before: writesBeforeDonor, after: writesAfterDonor,
            delta: .init(files: donor.filesWrittenDelta, bytes: donor.bytesWrittenDelta))
        let noInterveningWrites = archiveWritesPreserved(
            donorAfter: writesAfterDonor, afterOriginal: afterOriginal,
            afterWarm: afterWarm, afterCold: afterCold,
            nonDonorDeltas: originalNonDonorDeltas + [
                .init(files: warm.filesWrittenDelta, bytes: warm.bytesWrittenDelta),
                .init(files: cold.filesWrittenDelta, bytes: cold.bytesWrittenDelta)])
        let comparison = ModelPrefixBenchmarkAdjacentComparison(
            cell: cell.name, pair: pair, sharedTokens: next.sharedTokens,
            expectedRestoredTokens: next.expectedRestoredTokens,
            originalDonorHintTokens: cell.demandedTokens,
            outputMatches: warm.outputSHA256 == cold.outputSHA256,
            sameOriginalDonorSessionAndScope: true,
            precedingRowsRetiredAndDrained: originalDrained,
            originalDonorWriteDeltaMatchesRow: deltaMatches,
            noInterveningArchiveWrites: noInterveningWrites,
            writesBeforeDonor: writesBeforeDonor, writesAfterDonor: writesAfterDonor,
            writesAfterOriginalRows: afterOriginal, writesAfterAdjacentWarm: afterWarm,
            writesAfterAdjacentCold: afterCold, restoredTokens: warm.restoredTokens,
            replayTokens: warm.replayTokens, filesReadDelta: warm.filesReadDelta,
            bytesReadDelta: warm.bytesReadDelta)
        report.adjacentComparisons = (report.adjacentComparisons ?? []) + [comparison]
        try report.save(to: fixture.specification.outputPath)
        #expect(originalDrained && deltaMatches && noInterveningWrites,
            "adjacent archive must originate from the completed original demanded donor")
        #expect(warm.restoredTokens == next.expectedRestoredTokens && warm.replayTokens == 0,
            "same original donor must retain its usable actual next-turn frontier")
        #expect(warm.matchedTokens == next.expectedRestoredTokens && warm.stageDisposition == "staged"
            && warm.filesReadDelta > 0 && warm.bytesReadDelta > 0)
        #expect(cold.restoredTokens == 0 && cold.matchedTokens == 0 && cold.replayTokens == 0
            && cold.filesReadDelta == 0 && cold.bytesReadDelta == 0)
        #expect(warm.mtp.qualified && cold.mtp.qualified)
        #expect(comparison.outputMatches, "adjacent SSD-restored fork must preserve every generated token")
    }
}
