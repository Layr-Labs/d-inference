import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Model prefix-cache qualification (live)", .serialized)
struct ModelPrefixBenchmarkLiveTests {
    private static let enabled = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_MODEL_BENCHMARK"] == "1"

    @Test("current artifact cold, donor and actual SSD-restored forks", .timeLimit(.minutes(60)),
          .enabled(if: enabled))
    func modelPrefixPairs() async throws {
        try #require(ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_EXCLUSIVE_GPU"] == "1")
        let specification = try ModelPrefixBenchmarkSpecification.load()
        let fixture = try await ModelPrefixBenchmarkFixture(specification)
        do {
            let cache = await fixture.session.cacheSnapshot()
            var report = ModelPrefixBenchmarkReport(modelID: specification.modelID,
                openRouterID: specification.openRouterID, weightHash: specification.expectedWeightHash,
                modelType: specification.modelType, servingModelType: fixture.servingModelType,
                backend: fixture.session.backend, backendFallback: fixture.session.backendFallback,
                cacheMode: cache.durableMode, keyMode: cache.keyMode, mtpEnabled: specification.mtpEnabled ?? false,
                checkpointPartition: specification.checkpointPartition ?? "production", strictFsync: false,
                productionKVGrantBytes: cache.engineKVCapacityBytes, physicalMemoryBytes: cache.physicalMemoryBytes,
                activationReserveBytes: cache.activationReserveBytes, outputTokens: specification.outputTokens,
                comparison: specification.checkpointPartition == "demanded_recurrent_qualification"
                    ? "benchmark-only recurrent partition: cache-disabled versus actual scoped SSD reuse; not production or old binary"
                    : "current production factory: cache-disabled versus actual scoped SSD reuse; not old binary")
            report.assistantIdentity = cache.assistantIdentity
            // Excluded initialization pass on the same workload family.
            _ = try await fixture.run(cell: "priming", pair: -1, role: "excluded",
                tokens: fixture.promptTokens(count: 1025), scope: "priming",
                target: 0, cacheEnabled: false)
            for cell in specification.cases {
                let donorTokens = fixture.promptTokens(count: cell.donorTokens)
                let forkTokens = fixture.forkTokens(cell)
                for localPair in 0..<specification.pairs {
                    let pair = localPair + (specification.pairOffset ?? 0)
                    let scope = "qualification-\(cell.name)-\(pair)"
                    // Counterbalance the cold reference against donor+warm as
                    // one causal sequence. A warm fork always follows its donor.
                    let coldFirst = pair.isMultiple(of: 2)
                    var cold: ModelPrefixBenchmarkRow?
                    if coldFirst {
                        cold = try await fixture.run(cell: cell.name, pair: pair, role: "cold_fork",
                            tokens: forkTokens, scope: scope, target: 0, cacheEnabled: false)
                        report.rows.append(cold!)
                        try report.save(to: specification.outputPath)
                    }
                    // Also counterbalance capture-enabled and explicit-novel
                    // donors. Their scopes are independent; only donor+warm
                    // must retain their causal ordering.
                    var novel: ModelPrefixBenchmarkRow?
                    if coldFirst {
                        novel = try await fixture.run(cell: cell.name, pair: pair, role: "novel_donor",
                            tokens: donorTokens, scope: scope + "-novel", target: 0, cacheEnabled: true)
                        report.rows.append(novel!)
                        try report.save(to: specification.outputPath)
                    }
                    // Optional same-donor adjacency witnesses bind cumulative
                    // archive counters around this one demanded donor.
                    let donorWritesBefore = cell.adjacentFork == nil ? nil
                        : try await ModelPrefixBenchmarkAdjacentFork.writes(fixture)
                    let donor = try await fixture.run(cell: cell.name, pair: pair, role: "demanded_donor",
                        tokens: donorTokens, scope: scope, target: cell.demandedTokens, cacheEnabled: true)
                    report.rows.append(donor)
                    try report.save(to: specification.outputPath)
                    let donorWritesAfter = cell.adjacentFork == nil ? nil
                        : try await ModelPrefixBenchmarkAdjacentFork.writes(fixture)
                    let warm = try await fixture.run(cell: cell.name, pair: pair, role: "warm_fork",
                        tokens: forkTokens, scope: scope, target: 0, cacheEnabled: true)
                    report.rows.append(warm)
                    try report.save(to: specification.outputPath)
                    if !coldFirst {
                        novel = try await fixture.run(cell: cell.name, pair: pair, role: "novel_donor",
                            tokens: donorTokens, scope: scope + "-novel", target: 0, cacheEnabled: true)
                        report.rows.append(novel!)
                        try report.save(to: specification.outputPath)
                    }
                    if !coldFirst {
                        cold = try await fixture.run(cell: cell.name, pair: pair, role: "cold_fork",
                            tokens: forkTokens, scope: scope, target: 0, cacheEnabled: false)
                        report.rows.append(cold!)
                    }
                    let reference = try #require(cold)
                    let novelReference = try #require(novel)
                    let comparison = ModelPrefixBenchmarkComparison(cell: cell.name, pair: pair,
                        outputMatches: warm.outputSHA256 == reference.outputSHA256,
                        ttftReductionPercent: (1 - warm.firstOutputSeconds / reference.firstOutputSeconds) * 100,
                        totalLatencyReductionPercent: (1 - warm.terminalSeconds / reference.terminalSeconds) * 100,
                        endToEndTPSIncreasePercent: (warm.endToEndTPS / reference.endToEndTPS - 1) * 100,
                        donorOutputMatches: donor.outputSHA256 == novelReference.outputSHA256,
                        donorTTFTIncreasePercent: (donor.firstOutputSeconds / novelReference.firstOutputSeconds - 1) * 100,
                        checkpointBytesCreated: donor.bytesWrittenDelta, warmRestoredTokens: warm.restoredTokens)
                    report.comparisons.append(comparison)
                    try report.save(to: specification.outputPath)
                    if cell.adjacentFork != nil {
                        try await ModelPrefixBenchmarkAdjacentFork.run(
                            fixture: fixture, cell: cell, pair: pair, scope: scope,
                            donorTokens: donorTokens, middleTokens: forkTokens,
                            donor: donor, originalRows: [reference, novelReference, donor, warm],
                            writesBeforeDonor: try #require(donorWritesBefore),
                            writesAfterDonor: try #require(donorWritesAfter), report: &report)
                    }
                    // Persist observations before declaring a qualification:
                    // configured-but-idle assistants cannot become MTP evidence.
                    for row in [reference, novelReference, donor, warm] {
                        #expect(row.mtp.qualified,
                            "actual MTP qualification failed for \(row.role): \(row.mtp.qualificationFailure ?? "none")")
                    }
                    #expect(novelReference.filesWrittenDelta == 0, "explicit novel demand must not spend SSD writes")
                    #expect(comparison.outputMatches, "restored fork must preserve every generated token")
                    #expect(comparison.donorOutputMatches, "capture creation must preserve every generated token")
                    print("[model-prefix] model=\(specification.modelID) cell=\(cell.name) pair=\(pair) "
                        + "restored=\(warm.restoredTokens) coldTTFT=\(reference.firstOutputSeconds) "
                        + "warmTTFT=\(warm.firstOutputSeconds) sameTokens=\(comparison.outputMatches) "
                        + "donorSameTokens=\(comparison.donorOutputMatches)")
                }
            }
        } catch {
            try await fixture.close()
            throw error
        }
        try await fixture.close()
    }
}
