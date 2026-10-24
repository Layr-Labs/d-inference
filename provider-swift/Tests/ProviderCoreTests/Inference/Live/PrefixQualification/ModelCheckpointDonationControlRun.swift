import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

extension ModelCheckpointDonationControl {
    /// Return only value evidence; no model, engine or store survives this call.
    static func run(spec: ModelCheckpointStorageSpecification) async throws -> ModelCheckpointStorageReport {
        let namespace = try spec.namespace
        let persistentRoot = namespace.map { _ in
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("checkpoint-donation-control-\(UUID().uuidString)", isDirectory: true)
        }
        let fixture = try await ModelPrefixBenchmarkFixture(spec.benchmark,
            persistentRoot: persistentRoot, persistentTestNamespace: namespace, maximumStageMegabytes: 1)
        var report = ModelCheckpointStorageReport(runID: spec.runID, phase: spec.phase,
            processID: ProcessInfo.processInfo.processIdentifier, startedAt: Date(),
            checkpointRoot: spec.checkpointRoot, keyNamespaceID: spec.keyNamespaceID,
            keyAccessGroup: spec.keyAccessGroup,
            artifactDirectory: URL(fileURLWithPath: spec.benchmark.directory).resolvingSymlinksInPath().path,
            workload: ModelCheckpointStoragePrompts.version, warmupIterations: 0,
            benchmark: await fixture.makeReport(comparison: "matched-geometry export control; not a performance row"))
        var closed = false
        do {
            _ = try await cacheWitness(fixture)
            let first = try #require(spec.benchmark.cases.first)
            let warmupPrompt = try ModelCheckpointStoragePrompts(fixture: fixture, cell: first)
            let warmups = spec.benchmark.warmupIterations ?? 1
            for iteration in 0..<warmups {
                _ = try await fixture.run(cell: first.name, pair: -1, role: "excluded_warmup",
                    tokens: warmupPrompt.fork, scope: "excluded-warmup-\(iteration)", target: 0, cacheEnabled: false)
            }
            for cell in spec.benchmark.cases {
                let prompts = try ModelCheckpointStoragePrompts(fixture: fixture, cell: cell)
                for localPair in 0..<spec.benchmark.pairs {
                    let pair = localPair + (spec.benchmark.pairOffset ?? 0)
                    let row = try await fixture.run(cell: cell.name, pair: pair, role: "donation_control",
                        tokens: prompts.donor, scope: "storage-\(cell.name)-\(pair)",
                        target: prompts.demandedTokens, cacheEnabled: true, observeStorage: true,
                        expectedMarker: ModelCheckpointStoragePrompts.donorMarker, recordPrefillRanges: true)
                    try #require(row.filesReadDelta == 0 && row.bytesReadDelta == 0
                        && row.filesWrittenDelta == 0 && row.bytesWrittenDelta == 0
                        && row.restoredTokens == 0 && row.matchedTokens == 0 && row.replayTokens == 0
                        && row.stageConsumptionsDelta == 0 && row.checkpointWritesDrained
                        && row.stagedBytesAfterRetirement == 0 && row.writeHostBytesAfterRetirement == 0
                        && row.mtp.qualified,
                        "the real capped control must finish without checkpoint IO or retained owners")
                    report.donationControls.append(Self(cell: cell.name, pair: pair, controlRow: row,
                        benchmark: report.benchmark, cacheWitness: try await cacheWitness(fixture),
                        warmupIterations: warmups))
                    try report.save(to: spec.benchmark.outputPath)
                }
            }
            try await fixture.close()
            closed = true
            if let persistentRoot { try FileManager.default.removeItem(at: persistentRoot) }
            return report
        } catch {
            let failure = error
            report.failure = String(describing: failure)
            if !closed {
                do {
                    try await fixture.close()
                    closed = true
                    if let persistentRoot { try FileManager.default.removeItem(at: persistentRoot) }
                } catch {
                    report.failure = "\(failure); control teardown: \(error)"
                    try report.save(to: spec.benchmark.outputPath)
                    throw error
                }
            }
            try report.save(to: spec.benchmark.outputPath)
            throw failure
        }
    }
}
