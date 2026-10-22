import Foundation
import MLX
import MLXLMCommon
@_spi(Benchmarking) import ProviderCore
import ProviderCoreFoundation

/// Concurrent greedy decode through the actual production slot: the same
/// `makeBenchmarkSession` construction as runtime generation, including the
/// artifact's MTP policy, with prefix caches off. One engine per batch size,
/// warmed by one identical batch before the measured one. Raw engine events
/// carry token IDs, so every token has an exact arrival time.
public enum RuntimeConcurrencyBenchmark {
    static let batchSizeRange = 1 ... 64
    /// Every staggered quota is at least this, so third-token times exist.
    static let minimumStaggeredTokens = 3

    /// Comma-separated batch sizes. An empty, non-numeric or out-of-range
    /// entry refuses the whole list rather than running another workload.
    public static func batchSizes(parsing list: String) throws -> [Int] {
        try list.split(separator: ",", omittingEmptySubsequences: false).map { entry in
            guard let size = Int(entry.trimmingCharacters(in: .whitespaces)),
                batchSizeRange.contains(size)
            else { throw RuntimeGenerationBenchmark.Failure.invalidArguments }
            return size
        }
    }

    /// Output quota per row. Staggered row i of B stops after
    /// maxTokens * (B - i) / B tokens; maxTokens >= 3B keeps the quotas
    /// distinct and at least three tokens, so the decode cohort shrinks one
    /// row at a time. Nil when the combination cannot do that.
    static func rowMaxTokens(maxTokens: Int, batchSize: Int, staggered: Bool) -> [Int]? {
        guard staggered else { return Array(repeating: maxTokens, count: batchSize) }
        guard maxTokens >= minimumStaggeredTokens * batchSize else { return nil }
        return (0 ..< batchSize).map { maxTokens * (batchSize - $0) / batchSize }
    }

    public static func run(
        modelID: String, modelDirectory: URL, prompt: String, batchSizes: [Int],
        maxTokens: Int, staggered: Bool = false, warmupMaxTokens: Int = 32, backend: String,
        mtpEnabled: Bool, assistantDirectory: URL? = nil, renderDate: String,
        checkpointQuantizationConfig: String = "balanced"
    ) async throws -> (json: String, succeeded: Bool) {
        guard maxTokens > 2, maxTokens <= 131_072, prompt.utf8.count <= 4 << 20,
            let widest = batchSizes.max(), batchSizes.allSatisfy(batchSizeRange.contains),
            let date = PromptRenderDate(renderDate),
            ["auto", "paged", "contiguous"].contains(backend),
            assistantDirectory == nil || mtpEnabled
        else { throw RuntimeGenerationBenchmark.Failure.invalidArguments }
        let cellQuotas = try batchSizes.map { batchSize in
            guard let quotas = rowMaxTokens(
                maxTokens: maxTokens, batchSize: batchSize, staggered: staggered)
            else { throw RuntimeGenerationBenchmark.Failure.invalidArguments }
            return quotas
        }
        let target = try await RuntimeGenerationBenchmark.loadVerifiedTarget(
            modelID: modelID, modelDirectory: modelDirectory)
        // An unproven native retirement keeps the container's resources.
        var retirementUnproven = false
        do {
            // Distinct public prompts per row; greedy, so each row is reproducible.
            let prompts = try (0 ..< widest).map { row in
                try RuntimeGenerationBenchmark.preparedPrompt(
                    "Request \(row + 1). \(prompt)", modelID: modelID, maxTokens: maxTokens,
                    target: target, date: date)
            }
            let environment = RuntimeGenerationBenchmark.prefixCacheDisabledEnvironment()
            var cells: [Cell] = []
            var refusedCells: [RefusedCell] = []
            for quotas in cellQuotas {
                let batchSize = quotas.count
                let session = try await EngineV2Factory.makeBenchmarkSession(
                    modelId: modelID, modelDirectory: modelDirectory, isVLM: target.isVLM,
                    container: target.container, tokenizer: target.tokenizer,
                    verifiedWeightHash: target.weightHash,
                    kvBytesCapacity: 1 << 30, maxConcurrentRequests: batchSize,
                    mtpEnabled: mtpEnabled, assistantDirectory: assistantDirectory,
                    useProductionKVGrant: true, kvBackendConfig: backend,
                    checkpointQuantizationConfig: checkpointQuantizationConfig,
                    requirePersistentKey: false, environment: environment)
                let measurement: Result<Void, any Error>
                do {
                    // Model policy can lower the slot's width; queued rows are not a batch.
                    let width = session.effectiveMaxConcurrentRequests
                    if width == batchSize {
                        cells.append(
                            try await measure(
                                session, prompts: prompts.prefix(batchSize), rowMaxTokens: quotas,
                                staggered: staggered, warmupMaxTokens: warmupMaxTokens))
                    } else {
                        refusedCells.append(
                            RefusedCell(
                                batchSize: batchSize, effectiveMaxConcurrentRequests: width))
                    }
                    measurement = .success(())
                } catch {
                    measurement = .failure(error)
                }
                // Native teardown must prove retirement before the next cell or
                // the container release; a measurement error still wins.
                do {
                    try await session.shutdownReportingCompletion()
                } catch {
                    retirementUnproven = true
                    try measurement.get()
                    throw error
                }
                try measurement.get()
            }
            let report = Report(
                modelID: modelID, verifiedModelAggregateSHA256: target.weightHash,
                runtimeIdentity: EngineV2Factory.benchmarkRuntimeIdentity(),
                promptSHA256: RuntimeGenerationBenchmark.sha256Hex(Data(prompt.utf8)),
                renderDate: prompts[0].renderDate, mtpRequested: mtpEnabled,
                maxTokens: maxTokens, staggered: staggered, warmupMaxTokens: warmupMaxTokens,
                cells: cells, refusedCells: refusedCells)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(decoding: try encoder.encode(report), as: UTF8.self)
            await EngineV2Factory.releaseBenchmarkContainer(target.container)
            return (json, refusedCells.isEmpty && cells.allSatisfy(\.failures.isEmpty))
        } catch {
            if !retirementUnproven {
                await EngineV2Factory.releaseBenchmarkContainer(target.container)
            }
            throw error
        }
    }

    /// One identical warmup batch, then the measured batch, on a slot whose
    /// width equals the number of prompts.
    private static func measure(
        _ session: EngineV2BenchmarkSession, prompts: ArraySlice<EngineV2Factory.BenchmarkPrompt>,
        rowMaxTokens: [Int], staggered: Bool, warmupMaxTokens: Int
    ) async throws -> Cell {
        let stopTokens = await session.stopTokenIDs()
        let requests = zip(prompts, rowMaxTokens).enumerated().map { row, input in
            CBv2Request(
                id: CBv2RequestID(UInt64(row + 1)), promptTokens: input.0.tokens,
                sampling: input.0.sampling, maxTokens: input.1, stopTokens: stopTokens,
                prefixCacheEnabled: false)
        }
        func run(_ batch: [CBv2Request]) async throws -> [Measured] {
            try await runBatch(
                batch, submit: { try await session.submit($0) },
                complete: { await session.complete(receiptID: $0) })
        }
        var warmup = requests
        for index in warmup.indices { warmup[index].maxTokens = warmupMaxTokens }
        _ = try await run(warmup)
        let chainedBefore = session.rawEngine.chainedStepCount
        // CBV2_STEP_PROFILE=1: phase timers cover the measured batch only.
        if CBv2StepProfiler.enabled { CBv2StepProfiler.reset() }
        let measured = try await run(requests)
        if CBv2StepProfiler.enabled {
            FileHandle.standardError.write(
                Data(
                    ("step profile B=\(requests.count)\n" + CBv2StepProfiler.summaryTable())
                        .utf8))
        }
        let summary = try summarize(measured, stopTokens: stopTokens, staggered: staggered)
        return Cell(
            batchSize: requests.count,
            effectiveMaxConcurrentRequests: session.effectiveMaxConcurrentRequests,
            resolvedBackend: session.backend,
            kvQuantization: session.kvQuantization.rawValue,
            kvCheckpointQuantization: session.kvCheckpointQuantization.rawValue,
            checkpointBackendLayout: session.checkpointBackendLayout,
            mtpActive: session.rawEngine.mtpMetricsSnapshot() != nil,
            assistantIdentity: (await session.cacheSnapshot()).assistantIdentity,
            failures: summary.failures, rows: summary.rows,
            allRowsDecodeTokensPerSecond: summary.allRowsDecodeTokensPerSecond,
            allRowsWindowMs: summary.allRowsWindowMs,
            medianRowDecodeTokensPerSecond: summary.medianRowDecodeTokensPerSecond,
            mtpMetrics: MTPBenchmarkEngineMetrics.snapshot(engine: session.rawEngine),
            chainedSteps: session.rawEngine.chainedStepCount - chainedBefore)
    }

    /// Submit rows in order on this task and start draining each row as soon
    /// as its submit returns, so arrivals are timed as the engine publishes
    /// them rather than after the remaining submissions. `complete` runs for
    /// every receipt once all streams are drained.
    static func runBatch(
        _ requests: [CBv2Request],
        submit: (CBv2Request) async throws -> EngineV2BenchmarkSession.Submission,
        complete: (CBv2RequestID) async -> Void
    ) async throws -> [Measured] {
        try await withThrowingTaskGroup(of: (Int, Measured).self) { group in
            var receipts: [CBv2RequestID] = []
            for (index, request) in requests.enumerated() {
                let submitted = DispatchTime.now().uptimeNanoseconds
                let submission = try await submit(request)
                receipts.append(submission.receiptID)
                group.addTask {
                    (index, await drain(submission.events, of: request, submittedNanos: submitted))
                }
            }
            var measured = [Measured?](repeating: nil, count: requests.count)
            for try await (index, row) in group { measured[index] = row }
            for receipt in receipts { await complete(receipt) }
            return measured.compactMap { $0 }
        }
    }

    private static func drain(
        _ events: AsyncStream<CBv2Event>, of request: CBv2Request, submittedNanos: UInt64
    ) async -> Measured {
        var tokens: [Int] = []
        var arrivals: [UInt64] = []
        var finishReason: CBv2FinishReason?
        for await event in events {
            switch event {
            case .delta(_, let sampled, _):
                let now = DispatchTime.now().uptimeNanoseconds
                tokens.append(contentsOf: sampled)
                arrivals.append(contentsOf: repeatElement(now, count: sampled.count))
            case .finished(let reason, _):
                finishReason = reason
            }
        }
        return Measured(
            promptTokens: request.promptTokens, maxTokens: request.maxTokens,
            submittedNanos: submittedNanos, tokens: tokens, arrivalNanos: arrivals,
            finishReason: finishReason)
    }
}
