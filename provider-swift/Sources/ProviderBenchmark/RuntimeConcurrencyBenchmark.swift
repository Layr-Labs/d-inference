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
    struct Row: Encodable {
        let row: Int
        let promptTokenCount: Int
        let generatedTokens: [Int]
        let finishReason: String
        /// Submit to first token, and to the third.
        let firstTokenMs: Double?
        let thirdTokenMs: Double?
        /// Submit to each of the first eight tokens.
        let earlyTokenMs: [Double]
        /// (tokens - 1) / (last arrival - first arrival).
        let decodeTokensPerSecond: Double?
    }

    struct Cell: Encodable {
        let batchSize: Int
        let effectiveMaxConcurrentRequests: Int
        let rows: [Row]
        /// Tokens arriving while every row is past its first token and none
        /// has received its last, over that window.
        let allRowsDecodeTokensPerSecond: Double?
        let allRowsWindowMs: Double?
        let medianRowDecodeTokensPerSecond: Double?
        let mtpMetrics: MTPBenchmarkMetrics
        let chainedSteps: Int
    }

    struct Report: Encodable {
        let schema = 1
        let scope = "production_runtime_concurrency"
        let modelID: String
        let runtimeIdentity: [String: String]
        let mtpRequested: Bool
        let mtpActive: Bool
        let resolvedBackend: String
        let maxTokens: Int
        /// Row i of a B-row batch stops after `staggeredMaxTokens` tokens.
        let staggered: Bool
        let warmupMaxTokens: Int
        let cells: [Cell]
    }

    /// Row i of a B-row batch: maxTokens * (B - i) / B, at least 3, so rows
    /// finish one by one and the last decodes alone.
    static func staggeredMaxTokens(_ maxTokens: Int, row: Int, batchSize: Int) -> Int {
        max(3, maxTokens * (batchSize - row) / batchSize)
    }

    public static func run(
        modelID: String, modelDirectory: URL, prompt: String, batchSizes: [Int],
        maxTokens: Int, staggered: Bool = false, warmupMaxTokens: Int = 32, backend: String,
        mtpEnabled: Bool, assistantDirectory: URL? = nil, renderDate: String,
        checkpointQuantizationConfig: String = "balanced"
    ) async throws -> (json: String, succeeded: Bool) {
        guard maxTokens > 2, maxTokens <= 131_072, !batchSizes.isEmpty,
            batchSizes.allSatisfy({ (1 ... 64).contains($0) }),
            let date = PromptRenderDate(renderDate),
            ["auto", "paged", "contiguous"].contains(backend),
            assistantDirectory == nil || mtpEnabled
        else { throw RuntimeGenerationBenchmark.Failure.invalidArguments }
        let modelType = try ModelBenchmark.decodedModelType(
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        guard modelType != "mimo_v2" else { throw RuntimeGenerationBenchmark.Failure.unsupportedMiMo }
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        guard let verified = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID)
        else { throw RuntimeGenerationBenchmark.Failure.modelHashMismatch }
        let loaded = try await EngineV2Factory.loadBenchmarkContainer(
            modelID: modelID, directory: modelDirectory)
        let container = loaded.container
        do {
            let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
            // Distinct public prompts per row; greedy, so each row is reproducible.
            func prepared(_ row: Int) throws -> CBv2Request {
                let body = try JSONSerialization.data(
                    withJSONObject: [
                        "model": modelID,
                        "messages": [["role": "user", "content": "Request \(row + 1). \(prompt)"]],
                        "temperature": 0, "seed": 1, "max_tokens": maxTokens,
                    ] as [String: Any])
                let rendered = try EngineV2Factory.benchmarkPrompt(
                    body: body, tokenizer: tokenizer.inner, modelType: modelType, defaultDate: date)
                return CBv2Request(
                    id: CBv2RequestID(UInt64(row + 1)), promptTokens: rendered.tokens,
                    sampling: rendered.sampling, maxTokens: maxTokens, prefixCacheEnabled: false)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["DARKBLOOM_PREFIX_CACHE"] = "0"
            environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
            var cells: [Cell] = []
            var mtpActive = false
            var resolvedBackend = ""
            var succeeded = true
            for batchSize in batchSizes {
                let session = try await EngineV2Factory.makeBenchmarkSession(
                    modelId: modelID, modelDirectory: modelDirectory, isVLM: loaded.isVLM,
                    container: container, tokenizer: tokenizer, verifiedWeightHash: verified,
                    kvBytesCapacity: 1 << 30, maxConcurrentRequests: batchSize,
                    mtpEnabled: mtpEnabled, assistantDirectory: assistantDirectory,
                    useProductionKVGrant: true, kvBackendConfig: backend,
                    checkpointQuantizationConfig: checkpointQuantizationConfig,
                    requirePersistentKey: false, environment: environment)
                do {
                    mtpActive = session.rawEngine.mtpMetricsSnapshot() != nil
                    resolvedBackend = session.backend
                    let stopTokens = await session.stopTokenIDs()
                    var requests = try (0 ..< batchSize).map(prepared)
                    for index in requests.indices {
                        requests[index].stopTokens = stopTokens
                        if staggered {
                            requests[index].maxTokens = staggeredMaxTokens(
                                maxTokens, row: index, batchSize: batchSize)
                        }
                    }
                    var warmup = requests
                    for index in warmup.indices { warmup[index].maxTokens = warmupMaxTokens }
                    _ = try await runBatch(session, warmup)
                    let chainedBefore = session.rawEngine.chainedStepCount
                    // CBV2_STEP_PROFILE=1: phase timers cover the measured batch only.
                    if CBv2StepProfiler.enabled { CBv2StepProfiler.reset() }
                    let rows = try await runBatch(session, requests)
                    if CBv2StepProfiler.enabled {
                        FileHandle.standardError.write(
                            Data(
                                ("step profile B=\(batchSize)\n" + CBv2StepProfiler.summaryTable())
                                    .utf8))
                    }
                    succeeded = succeeded && rows.allSatisfy {
                        $0.finishReason == "stop" || $0.finishReason == "length"
                    }
                    cells.append(cell(
                        batchSize: batchSize,
                        effectiveMaxConcurrentRequests: session.effectiveMaxConcurrentRequests,
                        rows: rows, engine: session.rawEngine,
                        chainedSteps: session.rawEngine.chainedStepCount - chainedBefore))
                    await session.shutdown()
                } catch {
                    await session.shutdown()
                    throw error
                }
            }
            let report = Report(
                modelID: modelID, runtimeIdentity: EngineV2Factory.benchmarkRuntimeIdentity(),
                mtpRequested: mtpEnabled, mtpActive: mtpActive, resolvedBackend: resolvedBackend,
                maxTokens: maxTokens, staggered: staggered, warmupMaxTokens: warmupMaxTokens,
                cells: cells)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(decoding: try encoder.encode(report), as: UTF8.self)
            await EngineV2Factory.releaseBenchmarkContainer(container)
            return (json, succeeded)
        } catch {
            await EngineV2Factory.releaseBenchmarkContainer(container)
            throw error
        }
    }

    private struct Measured: Sendable {
        let promptTokenCount: Int
        let submittedNanos: UInt64
        let tokens: [Int]
        let arrivalNanos: [UInt64]
        let finishReason: String
    }

    /// Submit every row in order on this task, then drain all streams
    /// concurrently so no consumer backpressure shapes the schedule.
    private static func runBatch(
        _ session: EngineV2BenchmarkSession, _ requests: [CBv2Request]
    ) async throws -> [Measured] {
        var submissions: [(UInt64, EngineV2BenchmarkSession.Submission)] = []
        for request in requests {
            let submitted = DispatchTime.now().uptimeNanoseconds
            submissions.append((submitted, try await session.submit(request)))
        }
        let measured = await withTaskGroup(of: (Int, Measured).self) { group in
            for (index, (submitted, submission)) in submissions.enumerated() {
                let promptTokenCount = requests[index].promptTokens.count
                group.addTask {
                    var tokens: [Int] = []
                    var arrivals: [UInt64] = []
                    var reason = "missing"
                    for await event in submission.events {
                        switch event {
                        case .delta(_, let sampled, _):
                            let now = DispatchTime.now().uptimeNanoseconds
                            tokens.append(contentsOf: sampled)
                            arrivals.append(contentsOf: repeatElement(now, count: sampled.count))
                        case .finished(let finish, _):
                            reason = String(describing: finish)
                        }
                    }
                    return (index, Measured(
                        promptTokenCount: promptTokenCount, submittedNanos: submitted,
                        tokens: tokens, arrivalNanos: arrivals, finishReason: reason))
                }
            }
            var rows: [(Int, Measured)] = []
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        for (_, submission) in submissions {
            await session.complete(receiptID: submission.receiptID)
        }
        return measured
    }

    private static func cell(
        batchSize: Int, effectiveMaxConcurrentRequests: Int, rows: [Measured],
        engine: EngineV2, chainedSteps: Int
    ) -> Cell {
        func ms(_ nanos: UInt64, from start: UInt64) -> Double { Double(nanos &- start) / 1e6 }
        let reported = rows.enumerated().map { index, row -> Row in
            let rate: Double? = {
                guard row.arrivalNanos.count > 1,
                    let first = row.arrivalNanos.first, let last = row.arrivalNanos.last, last > first
                else { return nil }
                return Double(row.arrivalNanos.count - 1) / (Double(last - first) / 1e9)
            }()
            return Row(
                row: index, promptTokenCount: row.promptTokenCount,
                generatedTokens: row.tokens, finishReason: row.finishReason,
                firstTokenMs: row.arrivalNanos.first.map { ms($0, from: row.submittedNanos) },
                thirdTokenMs: row.arrivalNanos.count > 2
                    ? ms(row.arrivalNanos[2], from: row.submittedNanos) : nil,
                earlyTokenMs: row.arrivalNanos.prefix(8).map { ms($0, from: row.submittedNanos) },
                decodeTokensPerSecond: rate)
        }
        var windowRate: Double?
        var windowMs: Double?
        if let start = rows.compactMap(\.arrivalNanos.first).max(),
            let end = rows.compactMap(\.arrivalNanos.last).min(), end > start
        {
            let count = rows.reduce(0) { total, row in
                total + row.arrivalNanos.filter { $0 > start && $0 <= end }.count
            }
            windowMs = Double(end - start) / 1e6
            windowRate = Double(count) / (Double(end - start) / 1e9)
        }
        let rates = reported.compactMap(\.decodeTokensPerSecond).sorted()
        return Cell(
            batchSize: batchSize, effectiveMaxConcurrentRequests: effectiveMaxConcurrentRequests,
            rows: reported, allRowsDecodeTokensPerSecond: windowRate, allRowsWindowMs: windowMs,
            medianRowDecodeTokensPerSecond: rates.isEmpty ? nil : rates[rates.count / 2],
            mtpMetrics: MTPBenchmarkEngineMetrics.snapshot(engine: engine),
            chainedSteps: chainedSteps)
    }
}
