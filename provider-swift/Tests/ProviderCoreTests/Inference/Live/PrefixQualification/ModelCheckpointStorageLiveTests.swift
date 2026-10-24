import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Native live / checkpoint storage comparison (live)", .serialized)
struct ModelCheckpointStorageLiveTests {
    private static let enabled = ProcessInfo.processInfo.environment["DARKBLOOM_CHECKPOINT_STORAGE_BENCHMARK"] == "1"

    @Test("production factory public prompts, isolated SSD, deterministic same-profile restore",
          .timeLimit(.minutes(60)), .enabled(if: enabled))
    func checkpointStorageComparison() async throws {
        try #require(ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_EXCLUSIVE_GPU"] == "1")
        let spec = try ModelCheckpointStorageSpecification.load()
        let producer = try spec.producerReportPath.map { try ModelCheckpointStorageReport.load(from: $0) }
        // The control's complete model/engine lifetime ends before loading the
        // timed fixture. It never competes for memory or pollutes its warmup.
        let controlReport = spec.phase == .benchmark || spec.phase == .donate
            ? try await ModelCheckpointDonationControl.run(spec: spec) : nil
        let fixture = try await ModelPrefixBenchmarkFixture(spec.benchmark,
            persistentRoot: spec.checkpointRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
            persistentTestNamespace: try spec.namespace, maximumStageMegabytes: spec.phase == .refuse ? 1 : nil)
        let benchmark = await fixture.makeReport(comparison:
            "controlled same-binary storage comparison; public markers are observations, not a quality qualification; "
                + "cold versus SSD output equality is not required for lossy storage")
        var report = controlReport ?? ModelCheckpointStorageReport(runID: spec.runID, phase: spec.phase,
            processID: ProcessInfo.processInfo.processIdentifier, startedAt: Date(),
            checkpointRoot: spec.checkpointRoot, keyNamespaceID: spec.keyNamespaceID,
            keyAccessGroup: spec.keyAccessGroup,
            artifactDirectory: URL(fileURLWithPath: spec.benchmark.directory).resolvingSymlinksInPath().path,
            workload: ModelCheckpointStoragePrompts.version, warmupIterations: 0,
            benchmark: benchmark)
        report.benchmark = benchmark
        var fixtureClosed = false
        do {
            try requireSelectedStorage(report.benchmark, spec: spec.benchmark)
            if let producer {
                try report.validateProducer(producer)
                report.producerProcessID = producer.processID
            }
            if spec.phase == .benchmark || spec.phase == .donate {
                let cell = try #require(spec.benchmark.cases.first)
                let prompts = try ModelCheckpointStoragePrompts(fixture: fixture, cell: cell)
                for iteration in 0..<(spec.benchmark.warmupIterations ?? 1) {
                    _ = try await fixture.run(cell: cell.name, pair: -1, role: "excluded_warmup",
                        tokens: prompts.fork, scope: "excluded-warmup-\(iteration)", target: 0, cacheEnabled: false)
                    report.warmupIterations += 1
                }
            }
            for cell in spec.benchmark.cases {
                let prompts = try ModelCheckpointStoragePrompts(fixture: fixture, cell: cell)
                for localPair in 0..<spec.benchmark.pairs {
                    let pair = localPair + (spec.benchmark.pairOffset ?? 0)
                    let scope = "storage-\(cell.name)-\(pair)"
                    if let producer {
                        try await restoredProcessPair(fixture, spec: spec, prompts: prompts,
                            cell: cell, pair: pair, scope: scope, producer: producer, report: &report)
                    } else {
                        try await donorPair(fixture, prompts: prompts, cell: cell, pair: pair,
                            scope: scope, report: &report)
                    }
                    report.completedIterations += 1
                    try report.save(to: spec.benchmark.outputPath)
                }
            }
            report.authenticatedArtifacts = try await ModelCheckpointStorageArtifact.inspect(fixture)
            if spec.phase != .benchmark {
                try #require(report.authenticatedArtifacts?.isEmpty == false,
                    "persistent evidence requires real authenticated ciphertext, not directory presence")
            }
            try await fixture.close()
            fixtureClosed = true
            report.complete = true
            try report.save(to: spec.benchmark.outputPath)
        } catch {
            let failure = error
            report.complete = false
            report.failure = String(describing: error)
            if !fixtureClosed {
                do { try await fixture.close() }
                catch {
                    report.failure = "\(failure); teardown: \(error)"
                    try report.save(to: spec.benchmark.outputPath)
                    throw error
                }
            }
            try report.save(to: spec.benchmark.outputPath)
            throw failure
        }
    }

    private func requireSelectedStorage(_ report: ModelPrefixBenchmarkReport,
                                        spec: ModelPrefixBenchmarkSpecification) throws {
        try #require(report.liveKVQuantization == spec.resolvedLiveKVQuantization,
            "the requested live profile was not exercised")
        try #require(report.checkpointQuantization == spec.resolvedCheckpointQuantization,
            "the requested checkpoint profile is unsupported or was not exercised")
        if spec.resolvedLiveKVQuantization == "native" {
            let lossyLayouts = [CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout,
                CBv2CompleteCheckpointManifest.nativeQuantizedHistoricalLayout,
                CBv2CompleteCheckpointManifest.nativeQuantizedContiguousLayout,
                CBv2CompleteCheckpointManifest.nativeQuantizedContiguousHistoricalLayout]
            try #require(lossyLayouts.contains(report.checkpointBackendLayout ?? "")
                == (spec.resolvedCheckpointQuantization != "native"))
            if report.executionStorage?.paged == true {
                try #require(report.executionStorage?.quantizedGroupCount == 0
                    && report.executionStorage?.supportsOrdinaryDecodeChaining == true,
                    "checkpoint compression must not install a live packed pool or disable native chaining")
            }
        }
    }

    private func donorPair(_ fixture: ModelPrefixBenchmarkFixture, prompts: ModelCheckpointStoragePrompts,
                           cell: ModelPrefixBenchmarkSpecification.Case, pair: Int, scope: String,
                           report: inout ModelCheckpointStorageReport) async throws {
        let coldFirst = pair.isMultiple(of: 2)
        var cold: ModelPrefixBenchmarkRow?
        if coldFirst {
            cold = try await row(fixture, cell: cell.name, pair: pair, role: "cold_fork",
                tokens: prompts.fork, scope: scope, cache: false)
            report.benchmark.rows.append(cold!)
        }
        let novel = try await row(fixture, cell: cell.name, pair: pair, role: "novel_donor",
            tokens: prompts.donor, scope: scope + "-novel", cache: true,
            marker: ModelCheckpointStoragePrompts.donorMarker)
        report.benchmark.rows.append(novel)
        let donor = try await row(fixture, cell: cell.name, pair: pair, role: "donor",
            tokens: prompts.donor, scope: scope, target: prompts.demandedTokens, cache: true,
            marker: ModelCheckpointStoragePrompts.donorMarker, recordPrefillRanges: true)
        report.benchmark.rows.append(donor)
        let control = try #require(report.donationControls.first { $0.cell == cell.name && $0.pair == pair })
        try #require(control.warmupIterations == report.warmupIterations)
        try control.validate(donor: donor, actual: report.benchmark)
        let restored = try await row(fixture, cell: cell.name, pair: pair, role: "ssd_restore",
            tokens: prompts.fork, scope: scope, cache: true)
        report.benchmark.rows.append(restored)
        // Repeating a branch can legitimately donate its newly computed suffix
        // via provider-local demand. Repeat the original donor at its own
        // deepest archive instead, so these reads cannot re-encode that suffix.
        let donorRestored = try await row(fixture, cell: cell.name, pair: pair, role: "donor_ssd_restore",
            tokens: prompts.donor, scope: scope, cache: true, marker: ModelCheckpointStoragePrompts.donorMarker)
        report.benchmark.rows.append(donorRestored)
        let repeated = try await row(fixture, cell: cell.name, pair: pair, role: "donor_ssd_repeat",
            tokens: prompts.donor, scope: scope, cache: true, marker: ModelCheckpointStoragePrompts.donorMarker)
        report.benchmark.rows.append(repeated)
        if !coldFirst {
            cold = try await row(fixture, cell: cell.name, pair: pair, role: "cold_fork",
                tokens: prompts.fork, scope: scope, cache: false)
            report.benchmark.rows.append(cold!)
        }
        let reference = try #require(cold)
        report.comparisons.append(ModelCheckpointStorageComparison(cell: cell.name, pair: pair,
            coldMatchesRestored: reference.outputSHA256 == restored.outputSHA256,
            repeatedRestoreMatches: repeated.outputSHA256 == donorRestored.outputSHA256,
            ttftReductionPercent: (1 - restored.firstOutputSeconds / reference.firstOutputSeconds) * 100,
            generationTPSChangePercent: reference.generationTPS.flatMap { baseline in
                restored.generationTPS.map { ($0 / baseline - 1) * 100 }
            }, checkpointFileBytesWritten: donor.bytesWrittenDelta, restoredTokens: restored.restoredTokens,
            actualSharedTokens: prompts.sharedTokens))
        try #require(novel.filesWrittenDelta == 0 && donor.filesWrittenDelta > 0 && donor.bytesWrittenDelta > 0)
        // The zero-target novel row diagnoses demand/partition effects. Only
        // the equally partitioned, capture-refused row is the export reference.
        try requireRestore(restored, prompts: prompts)
        try requireRestore(donorRestored, prompts: prompts, maximumTokens: prompts.donor.count - 1)
        try requireRestore(repeated, prompts: prompts, maximumTokens: prompts.donor.count - 1)
        try #require(donorRestored.outputSHA256 == repeated.outputSHA256,
            "repeated reads of the same profile and ciphertext must be deterministic")
        try requireCold(reference)
        let warm = try await row(fixture, cell: cell.name, pair: pair, role: "warm_full_prefill",
            tokens: prompts.fork, scope: scope, cache: false)
        report.benchmark.rows.append(warm)
        try requireCold(warm)
        try #require(warm.filesReadDelta == 0 && warm.outputSHA256 == reference.outputSHA256)
        try await isolationAndCancellation(fixture, prompts: prompts, cell: cell.name,
            pair: pair, scope: scope, reference: reference, donorReference: donorRestored, report: &report)
    }

    private func restoredProcessPair(_ fixture: ModelPrefixBenchmarkFixture,
                                    spec: ModelCheckpointStorageSpecification,
                                    prompts: ModelCheckpointStoragePrompts,
                                    cell: ModelPrefixBenchmarkSpecification.Case, pair: Int, scope: String,
                                    producer: ModelCheckpointStorageReport,
                                    report: inout ModelCheckpointStorageReport) async throws {
        let source = try #require(producer.benchmark.rows.first {
            $0.cell == cell.name && $0.pair == pair && $0.role == "ssd_restore"
        })
        let promptDigest = try ModelCheckpointStoragePrompts.digest(prompts.fork)
        try #require(source.promptSHA256 == promptDigest,
            "producer and consumer must render the identical public prompt")
        if spec.phase == .refuse {
            // candidate() allows 1 MiB envelope slack above the configured cap.
            try #require(producer.authenticatedArtifacts?.allSatisfy { $0.encryptedFileBytes > 2 << 20 } == true,
                "the one-MiB read-cap control needs every producer checkpoint above two MiB")
            let refused = try await row(fixture, cell: cell.name, pair: pair, role: "read_budget_refusal",
                tokens: prompts.fork, scope: scope, cache: true)
            report.benchmark.rows.append(refused)
            try requireCold(refused)
            try #require(["miss_absent", "skipped_capacity"].contains(refused.stageDisposition),
                "a capped read must fall back cold without corrupting the retained ciphertext")
            return
        }
        // No warmup or prior generation runs in this new process before this read.
        let restored = try await row(fixture, cell: cell.name, pair: pair, role: "ssd_restart_restore",
            tokens: prompts.fork, scope: scope, cache: true)
        report.benchmark.rows.append(restored)
        try requireRestore(restored, prompts: prompts)
        try #require(restored.outputSHA256 == source.outputSHA256,
            "a fresh process must restore the same profile deterministically, not necessarily match cold tokens")
        let cold = try await row(fixture, cell: cell.name, pair: pair, role: "cold_fork",
            tokens: prompts.fork, scope: scope, cache: false)
        report.benchmark.rows.append(cold)
        try requireCold(cold)
        let warm = try await row(fixture, cell: cell.name, pair: pair, role: "warm_full_prefill",
            tokens: prompts.fork, scope: scope, cache: false)
        report.benchmark.rows.append(warm)
        try requireCold(warm)
        try #require(warm.filesReadDelta == 0 && warm.outputSHA256 == cold.outputSHA256)
        let donorRestored = try await row(fixture, cell: cell.name, pair: pair, role: "donor_ssd_restore",
            tokens: prompts.donor, scope: scope, cache: true, marker: ModelCheckpointStoragePrompts.donorMarker)
        report.benchmark.rows.append(donorRestored)
        try requireRestore(donorRestored, prompts: prompts, maximumTokens: prompts.donor.count - 1)
        let originalDonor = try #require(producer.benchmark.rows.first {
            $0.cell == cell.name && $0.pair == pair && $0.role == "donor_ssd_restore"
        })
        try #require(donorRestored.promptSHA256 == originalDonor.promptSHA256
            && donorRestored.outputSHA256 == originalDonor.outputSHA256)
        try await isolationAndCancellation(fixture, prompts: prompts, cell: cell.name,
            pair: pair, scope: scope, reference: cold, donorReference: donorRestored, report: &report)
    }

    private func isolationAndCancellation(_ fixture: ModelPrefixBenchmarkFixture,
                                          prompts: ModelCheckpointStoragePrompts, cell: String,
                                          pair: Int, scope: String, reference: ModelPrefixBenchmarkRow,
                                          donorReference: ModelPrefixBenchmarkRow,
                                          report: inout ModelCheckpointStorageReport) async throws {
        let otherTenant = try await row(fixture, cell: cell, pair: pair, role: "other_tenant",
            tokens: prompts.fork, scope: scope + "-other-tenant", cache: true)
        report.benchmark.rows.append(otherTenant)
        try requireCold(otherTenant)
        try #require(otherTenant.filesReadDelta == 0 && otherTenant.bytesReadDelta == 0
            && otherTenant.outputSHA256 == reference.outputSHA256)
        let cancellation = try await fixture.cancelRestored(cell: cell, pair: pair, tokens: prompts.fork, scope: scope)
        report.cancellations.append(cancellation)
        try #require(cancellation.cancellationIssued && cancellation.cancelledTerminalObserved
            && cancellation.outputTokensBeforeTerminal > 0
            && cancellation.stageDisposition == "staged" && cancellation.restoredTokens >= prompts.demandedTokens
            && cancellation.filesWrittenDelta == 0 && cancellation.bytesWrittenDelta == 0
            && cancellation.stagedBytesAfterRetirement == 0 && cancellation.writeHostBytesAfterRetirement == 0,
            "a fast normal completion is not cancellation evidence")
        let recovered = try await row(fixture, cell: cell, pair: pair, role: "after_cancel_restore",
            tokens: prompts.donor, scope: scope, cache: true, marker: ModelCheckpointStoragePrompts.donorMarker)
        report.benchmark.rows.append(recovered)
        try requireRestore(recovered, prompts: prompts, maximumTokens: prompts.donor.count - 1)
        try #require(recovered.outputSHA256 == donorReference.outputSHA256)
    }

    private func row(_ fixture: ModelPrefixBenchmarkFixture, cell: String, pair: Int, role: String,
                     tokens: [Int], scope: String, target: Int = 0, cache: Bool,
                     marker: String = ModelCheckpointStoragePrompts.forkMarker,
                     recordPrefillRanges: Bool = false) async throws -> ModelPrefixBenchmarkRow {
        let result = try await fixture.run(cell: cell, pair: pair, role: role, tokens: tokens,
            scope: scope, target: target, cacheEnabled: cache, observeStorage: true, expectedMarker: marker,
            recordPrefillRanges: recordPrefillRanges)
        try #require(result.checkpointWritesDrained && result.stagedBytesAfterRetirement == 0
            && result.writeHostBytesAfterRetirement == 0 && result.mtp.qualified)
        return result
    }

    private func requireRestore(_ row: ModelPrefixBenchmarkRow, prompts: ModelCheckpointStoragePrompts,
                                maximumTokens: Int? = nil) throws {
        try #require(row.stageDisposition == "staged" && row.stageConsumptionsDelta == 1
            && row.restoredTokens >= prompts.demandedTokens
            && row.restoredTokens <= (maximumTokens ?? prompts.sharedTokens)
            && row.filesReadDelta > 0 && row.bytesReadDelta > 0 && row.filesWrittenDelta == 0)
        let memory = try #require(row.memoryAtPrefillCompletion,
            "restored live memory needs the actual engine-queue prefill callback")
        try #require(memory.callbackCount == 1 && memory.backendBytesInUse > 0
            && memory.requestID == row.samplingRequestID && memory.promptTokens == row.promptTokens
            && memory.restoredTokens == row.restoredTokens,
            "restored live memory must be observed at prefill completion, before retirement")
    }

    private func requireCold(_ row: ModelPrefixBenchmarkRow) throws {
        try #require(row.restoredTokens == 0 && row.stageConsumptionsDelta == 0
            && row.filesWrittenDelta == 0 && row.bytesWrittenDelta == 0)
    }
}
