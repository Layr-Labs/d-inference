import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

public struct ArrivalInvarianceBenchmarkReport: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public let row: Int
        public let scheduledDelayMs: Int
        public let submittedAtMs: Double
        /// Signed distance between the measured submission offset and the
        /// intended one (`submittedAtMs - scheduledDelayMs`); positive means
        /// the request entered the engine later than the topology asked for.
        public let arrivalErrorMs: Double
        public let ttftMs: Double
        public let decodeTokensPerSecond: Double
        public let generatedTokens: Int
        public let completedAtMs: Double
        public let tokenChecksum: String
    }

    public struct Sample: Codable, Sendable {
        public let iteration: Int
        public let rows: [Row]
        public let aggregateDecodeTokensPerSecond: Double
        public let endToEndTokensPerSecond: Double
        public let makespanMs: Double
        /// Worst absolute arrival error across this sample's rows.
        public let maxArrivalErrorMs: Double
        /// Attempts discarded before this one because their arrivals missed
        /// the tolerance. Non-zero means the host was scheduling badly.
        public let discardedAttempts: Int
    }

    public struct Pattern: Codable, Sendable {
        public let name: String
        public let arrivalDelaysMs: [Int]
        public let samples: [Sample]
        public let medianTTFTMs: Double
        public let medianPerRequestDecodeTokensPerSecond: Double
        public let medianAggregateDecodeTokensPerSecond: Double
        public let medianMakespanMs: Double
        public let outputsStableAcrossIterations: Bool
        public let outputsMatchBurst: Bool
        /// Per-row median of the *measured* submission offsets, directly
        /// comparable to `arrivalDelaysMs`.
        public let measuredArrivalOffsetsMs: [Double]
        public let maxArrivalErrorMs: Double
        public let arrivalWithinTolerance: Bool
    }

    /// 2 adds the measured delivered-topology evidence (per-row
    ///   `submittedAtMs`/`arrivalErrorMs`, the tolerance, discarded attempts).
    /// 3 adds the required `kvBackend` block: the selection this run was
    ///   launched with and the backend its engine actually built. Without it
    ///   the phase's numbers cannot be attributed to an arm, and `.auto`
    ///   resolves CONTIGUOUS.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    public let promptTokensPerRequest: Int
    public let decodeTokensPerRequest: Int
    public let iterations: Int
    /// Bound enforced on every measured row's `arrivalErrorMs`. Samples that
    /// exceed it are re-run, and the benchmark fails rather than reporting
    /// numbers produced by a topology it did not actually deliver.
    public let arrivalToleranceMs: Double
    public let arrivalMaxAttemptsPerSample: Int
    /// Selection versus the backend the ONE engine every pattern is measured
    /// on actually resolved to. One engine per run (deliberately: every
    /// arrival topology must see the same warm engine), so `resolved` carries
    /// exactly one descriptor on any run that got that far.
    public let kvBackend: BenchmarkKVBackend
    public let patterns: [Pattern]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Measures production ContinuousBatchingV2 under equivalent request sets
/// submitted with different arrival schedules. Prefix caching is absent, all
/// rows use greedy decoding, and exact output-token checksums pin numerical
/// invariance independently from latency and throughput.
public enum ArrivalInvarianceBenchmark {
    private struct PatternDefinition: Sendable {
        let name: String
        let delaysMs: [Int]
    }

    private struct ModelFacts: Sendable {
        let baseTokens: [Int]
        let weightBytes: Int
    }

    // `CBv2Engine` is `AnyObject, Sendable` in the frozen contract, so this
    // needs no `@unchecked` escape hatch (same reasoning as EngineV2Bridge).
    private struct EngineParts: Sendable {
        let engine: any CBv2Engine
        /// The backend the factory resolved to, with any fallback reason.
        let resolvedBackend: String
    }

    private struct MeasuredRow: Sendable {
        let report: ArrivalInvarianceBenchmarkReport.Row
        let tokenIDs: [Int]
        let firstTokenAt: UInt64
        let lastTokenAt: UInt64
        let finishedAt: UInt64
    }

    private struct MeasuredSample: Sendable {
        let report: ArrivalInvarianceBenchmarkReport.Sample
        let outputs: [[Int]]
    }

    private static let patterns = [
        PatternDefinition(name: "burst", delaysMs: [0, 0, 0, 0]),
        PatternDefinition(name: "stagger-25ms", delaysMs: [0, 25, 50, 75]),
        PatternDefinition(name: "stagger-100ms", delaysMs: [0, 100, 200, 300]),
        PatternDefinition(name: "rolling-250ms", delaysMs: [0, 250, 500, 750]),
    ]

    /// The tightest inter-arrival gap any topology asks for (25 ms today),
    /// derived from the definitions so a future, denser pattern automatically
    /// tightens the bound instead of silently outgrowing it.
    private static let minimumArrivalGapMs: Double = {
        let gaps = patterns
            .flatMap { zip($0.delaysMs, $0.delaysMs.dropFirst()).map { $1 - $0 } }
            .filter { $0 > 0 }
        return Double(gaps.min() ?? 25)
    }()

    /// Default arrival tolerance: one fifth of the tightest gap, so even two
    /// adjacent rows erring in opposite directions stay >= 15 ms apart and the
    /// named topology remains the topology that was actually delivered.
    /// Override with `DARKBLOOM_ARRIVAL_TOLERANCE_MS` on hosts that cannot
    /// hold it (the loosened value is recorded in the report).
    private static let defaultArrivalToleranceMs = minimumArrivalGapMs / 5

    private static let arrivalToleranceEnvKey = "DARKBLOOM_ARRIVAL_TOLERANCE_MS"

    /// Settle time between a rejected attempt and its retry.
    private static let retryCooldownNanoseconds: UInt64 = 250_000_000

    /// `kvBackend` is the operator-facing selection handed to the production
    /// factory, exactly as in `ThroughputSweep.run`. `.auto` resolves
    /// CONTIGUOUS, so a run that does not forward the wrapper's selection
    /// here measures a different arm than the sweep it is reported beside.
    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptTokens: Int = 512,
        decodeTokens: Int = 64,
        iterations: Int = 3,
        arrivalToleranceMs: Double? = nil,
        maxAttemptsPerSample: Int = 3,
        kvBackend: EngineV2KVBackendSelection = .auto
    ) async throws -> ArrivalInvarianceBenchmarkReport {
        let promptTokens = max(2, promptTokens)
        let decodeTokens = max(2, decodeTokens)
        let iterations = max(1, iterations)
        let toleranceMs = resolvedToleranceMs(explicit: arrivalToleranceMs)
        let maxAttempts = max(1, maxAttemptsPerSample)
        log("arrival tolerance \(String(format: "%.2f", toleranceMs)) ms, "
            + "up to \(maxAttempts) attempt(s) per sample")
        log("loading model \(modelID)")
        log("  path: \(modelDirectory.path)")

        let isVLM = ThroughputSweep.readHasVisionConfig(modelDirectory: modelDirectory)
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader()
            )
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader()
            )
        }

        let facts = await container.perform { context -> ModelFacts in
            let encoded = context.tokenizer.encode(
                text: ThroughputSweep.seedText,
                addSpecialTokens: false
            )
            let bytes = context.model.parameters().flattened().reduce(0) {
                $0 + $1.1.nbytes
            }
            return ModelFacts(
                baseTokens: encoded.isEmpty ? [0] : encoded,
                weightBytes: bytes
            )
        }

        let engineParts = try await makeEngine(
            container: container,
            modelDirectory: modelDirectory,
            isVLM: isVLM,
            weightBytes: facts.weightBytes,
            maxConcurrentRequests: patterns.map(\.delaysMs.count).max() ?? 1,
            kvBackend: kvBackend
        )
        let engine = engineParts.engine
        log("kv backend selection \(kvBackend.rawValue), engine resolved "
            + engineParts.resolvedBackend)

        var samplesByPattern = Dictionary(
            uniqueKeysWithValues: patterns.map { ($0.name, [MeasuredSample]()) }
        )
        var nextRequestID: UInt64 = 1
        do {
            // Reuse one engine so its asynchronous compiled-decode startup and
            // every arrival topology are fully warm before measurements begin.
            for pattern in patterns {
                log("warming \(pattern.name)")
                // Warm-up arrivals still use absolute deadlines, but a cold
                // engine is exactly when the host mis-schedules, so timing is
                // observed and not enforced here.
                _ = try await measure(
                    engine: engine,
                    facts: facts,
                    pattern: pattern,
                    promptTokens: promptTokens,
                    decodeTokens: min(8, decodeTokens),
                    iteration: 0,
                    requestIDBase: nextRequestID,
                    toleranceMs: toleranceMs,
                    maxAttempts: 1,
                    enforceTolerance: false
                )
                nextRequestID += UInt64(pattern.delaysMs.count)
            }

            // Rotate topology order each repetition to avoid a fixed thermal or
            // allocator-order bias while retaining deterministic reproduction.
            for iteration in 1 ... iterations {
                let shift = (iteration - 1) % patterns.count
                let ordered = Array(patterns[shift...]) + Array(patterns[..<shift])
                for pattern in ordered {
                    let sample = try await measure(
                        engine: engine,
                        facts: facts,
                        pattern: pattern,
                        promptTokens: promptTokens,
                        decodeTokens: decodeTokens,
                        iteration: iteration,
                        requestIDBase: nextRequestID,
                        toleranceMs: toleranceMs,
                        maxAttempts: maxAttempts,
                        enforceTolerance: true
                    )
                    // Every attempt burns a distinct block of request IDs so a
                    // retried sample can never collide with a discarded one.
                    nextRequestID += UInt64(pattern.delaysMs.count * maxAttempts)
                    log(
                        "  \(pattern.name) i=\(iteration): aggregate "
                            + "\(String(format: "%.1f", sample.report.aggregateDecodeTokensPerSecond)) tok/s, "
                            + "makespan \(String(format: "%.1f", sample.report.makespanMs)) ms, "
                            + "arrival err \(String(format: "%.2f", sample.report.maxArrivalErrorMs)) ms"
                    )
                    samplesByPattern[pattern.name, default: []].append(sample)
                }
            }
        } catch {
            await stopAndReclaim(engine)
            throw error
        }
        await stopAndReclaim(engine)

        let measuredByPattern = patterns.map {
            ($0, samplesByPattern[$0.name, default: []].sorted {
                $0.report.iteration < $1.report.iteration
            })
        }

        let burstOutputs = measuredByPattern.first?.1.first?.outputs ?? []
        let patternReports = measuredByPattern.map { definition, measured in
            let reports = measured.map(\.report)
            let allOutputs = measured.map(\.outputs)
            let firstOutputs = allOutputs.first ?? []
            let stable = allOutputs.allSatisfy { $0 == firstOutputs }
            let measuredOffsets = definition.delaysMs.indices.map { index in
                median(reports.compactMap { sample in
                    sample.rows.first { $0.row == index }?.submittedAtMs
                })
            }
            let worstArrivalError = reports.map(\.maxArrivalErrorMs).max() ?? 0
            return ArrivalInvarianceBenchmarkReport.Pattern(
                name: definition.name,
                arrivalDelaysMs: definition.delaysMs,
                samples: reports,
                medianTTFTMs: median(reports.flatMap { $0.rows.map(\.ttftMs) }),
                medianPerRequestDecodeTokensPerSecond: median(
                    reports.flatMap { $0.rows.map(\.decodeTokensPerSecond) }
                ),
                medianAggregateDecodeTokensPerSecond: median(
                    reports.map(\.aggregateDecodeTokensPerSecond)
                ),
                medianMakespanMs: median(reports.map(\.makespanMs)),
                outputsStableAcrossIterations: stable,
                outputsMatchBurst: allOutputs.allSatisfy { $0 == burstOutputs },
                measuredArrivalOffsetsMs: measuredOffsets,
                maxArrivalErrorMs: worstArrivalError,
                arrivalWithinTolerance: worstArrivalError <= toleranceMs
            )
        }

        return ArrivalInvarianceBenchmarkReport(
            schemaVersion: ArrivalInvarianceBenchmarkReport.currentSchemaVersion,
            modelID: modelID,
            modelPath: modelDirectory.path,
            promptTokensPerRequest: promptTokens,
            decodeTokensPerRequest: decodeTokens,
            iterations: iterations,
            arrivalToleranceMs: toleranceMs,
            arrivalMaxAttemptsPerSample: maxAttempts,
            kvBackend: BenchmarkKVBackend(
                selection: kvBackend.rawValue,
                resolved: [engineParts.resolvedBackend]),
            patterns: patternReports
        )
    }

    /// Explicit argument wins, then `DARKBLOOM_ARRIVAL_TOLERANCE_MS`, then the
    /// default. A non-positive or non-finite override is ignored rather than
    /// silently disabling the check.
    private static func resolvedToleranceMs(explicit: Double?) -> Double {
        if let explicit, explicit.isFinite, explicit > 0 { return explicit }
        if let raw = ProcessInfo.processInfo.environment[arrivalToleranceEnvKey],
           let parsed = Double(raw.trimmingCharacters(in: .whitespaces)),
           parsed.isFinite, parsed > 0 {
            return parsed
        }
        return defaultArrivalToleranceMs
    }

    /// Runs one arrival topology, re-running it while the delivered arrivals
    /// miss `toleranceMs`, and failing outright once the attempts are spent —
    /// a sample whose arrivals were not the named topology is never reported.
    private static func measure(
        engine: any CBv2Engine,
        facts: ModelFacts,
        pattern: PatternDefinition,
        promptTokens: Int,
        decodeTokens: Int,
        iteration: Int,
        requestIDBase: UInt64,
        toleranceMs: Double,
        maxAttempts: Int,
        enforceTolerance: Bool
    ) async throws -> MeasuredSample {
        let rowCount = pattern.delaysMs.count
        // Built before the clock starts so prompt tiling cannot leak into the
        // measured submission offsets.
        let prompts = (0 ..< rowCount).map { row in
            ThroughputSweep.tile(facts.baseTokens, to: promptTokens, offset: row * 17 + 1)
        }
        let attempts = max(1, maxAttempts)
        var worstObserved = 0.0

        for attempt in 0 ..< attempts {
            let (rows, scenarioStartedAt) = try await runArrivals(
                engine: engine,
                pattern: pattern,
                prompts: prompts,
                decodeTokens: decodeTokens,
                requestIDBase: requestIDBase + UInt64(attempt * rowCount)
            )
            let maxArrivalError = rows
                .map { abs($0.report.arrivalErrorMs) }
                .max() ?? 0

            if !enforceTolerance || maxArrivalError <= toleranceMs {
                return makeSample(
                    rows: rows,
                    iteration: iteration,
                    scenarioStartedAt: scenarioStartedAt,
                    maxArrivalErrorMs: maxArrivalError,
                    discardedAttempts: attempt
                )
            }

            worstObserved = max(worstObserved, maxArrivalError)
            log(
                "  \(pattern.name) i=\(iteration): discarding attempt \(attempt + 1)"
                    + "/\(attempts), arrival error "
                    + "\(String(format: "%.2f", maxArrivalError)) ms > "
                    + "\(String(format: "%.2f", toleranceMs)) ms tolerance"
            )
            try await Task.sleep(nanoseconds: retryCooldownNanoseconds)
        }

        throw BenchmarkError.arrivalOutOfTolerance(
            pattern: pattern.name,
            iteration: iteration,
            observedMs: worstObserved,
            toleranceMs: toleranceMs,
            attempts: attempts
        )
    }

    /// Submits one full topology once. Each row sleeps to an ABSOLUTE deadline
    /// derived from the shared scenario start, so a late-starting child task
    /// eats into its own sleep instead of shifting the whole schedule.
    private static func runArrivals(
        engine: any CBv2Engine,
        pattern: PatternDefinition,
        prompts: [[Int]],
        decodeTokens: Int,
        requestIDBase: UInt64
    ) async throws -> (rows: [MeasuredRow], scenarioStartedAt: UInt64) {
        let clock = SuspendingClock()
        let scenarioStartedAt = DispatchTime.now().uptimeNanoseconds
        let scenarioStartInstant = clock.now

        let rows = try await withThrowingTaskGroup(of: MeasuredRow.self) { group in
            for (row, delayMs) in pattern.delaysMs.enumerated() {
                let prompt = prompts[row]
                group.addTask {
                    try await sleepUntilArrival(
                        offsetMs: delayMs,
                        scenarioStart: scenarioStartInstant,
                        clock: clock
                    )
                    return try await consumeRow(
                        engine: engine,
                        requestID: requestIDBase + UInt64(row),
                        row: row,
                        delayMs: delayMs,
                        prompt: prompt,
                        decodeTokens: decodeTokens,
                        scenarioStartedAt: scenarioStartedAt
                    )
                }
            }

            var rows: [MeasuredRow] = []
            for try await row in group {
                rows.append(row)
            }
            return rows.sorted { $0.report.row < $1.report.row }
        }
        return (rows, scenarioStartedAt)
    }

    /// Sleeps to `scenarioStart + offsetMs`, never "offsetMs from whenever this
    /// task happened to be scheduled". Zero tolerance keeps the OS from
    /// coalescing the wake-up into a later timer batch.
    private static func sleepUntilArrival(
        offsetMs: Int,
        scenarioStart: SuspendingClock.Instant,
        clock: SuspendingClock
    ) async throws {
        guard offsetMs > 0 else { return }
        let deadline = scenarioStart.advanced(by: .milliseconds(offsetMs))
        guard clock.now < deadline else { return }
        try await Task.sleep(until: deadline, tolerance: .zero, clock: clock)
    }

    private static func makeSample(
        rows: [MeasuredRow],
        iteration: Int,
        scenarioStartedAt: UInt64,
        maxArrivalErrorMs: Double,
        discardedAttempts: Int
    ) -> MeasuredSample {
        let first = rows.map(\.firstTokenAt).min() ?? scenarioStartedAt
        let last = rows.map(\.lastTokenAt).max() ?? first
        let finished = rows.map(\.finishedAt).max() ?? last
        let decodeIntervals = rows.reduce(0) {
            $0 + max(0, $1.report.generatedTokens - 1)
        }
        let decodeSeconds = seconds(from: first, to: last)
        let makespanSeconds = seconds(from: scenarioStartedAt, to: finished)
        let aggregateTPS = decodeSeconds > 0
            ? Double(decodeIntervals) / decodeSeconds
            : 0
        let totalTokens = rows.reduce(0) { $0 + $1.report.generatedTokens }

        return MeasuredSample(
            report: ArrivalInvarianceBenchmarkReport.Sample(
                iteration: iteration,
                rows: rows.map(\.report),
                aggregateDecodeTokensPerSecond: aggregateTPS,
                endToEndTokensPerSecond: makespanSeconds > 0
                    ? Double(totalTokens) / makespanSeconds
                    : 0,
                makespanMs: makespanSeconds * 1000,
                maxArrivalErrorMs: maxArrivalErrorMs,
                discardedAttempts: discardedAttempts
            ),
            outputs: rows.map(\.tokenIDs)
        )
    }

    private static func makeEngine(
        container: ModelContainer,
        modelDirectory: URL,
        isVLM: Bool,
        weightBytes: Int,
        maxConcurrentRequests: Int,
        kvBackend: EngineV2KVBackendSelection
    ) async throws -> EngineParts {
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, weightBytes)),
                configReserveBytes: 0
            ),
            UInt64(Int.max)
        ))
        // `makeProductionBuild` is the construction `makeProductionEngine`
        // wraps, and additionally hands back the backend the engine actually
        // resolved to — without it a forwarded selection could not be shown
        // to have been honoured.
        return try await container.perform { context -> EngineParts in
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: context.model,
                isVLM: isVLM,
                modelDirectory: modelDirectory
            )
            let build = try EngineV2Factory.makeProductionBuild(
                model: servingModel,
                tokenizer: context.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: maxConcurrentRequests,
                kvBackend: kvBackend
            )
            return EngineParts(
                engine: build.engine,
                resolvedBackend: build.resolvedKVBackendDescriptor)
        }
    }

    private static func consumeRow(
        engine: any CBv2Engine,
        requestID: UInt64,
        row: Int,
        delayMs: Int,
        prompt: [Int],
        decodeTokens: Int,
        scenarioStartedAt: UInt64
    ) async throws -> MeasuredRow {
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let stream = try engine.submit(CBv2Request(
            id: CBv2RequestID(requestID),
            promptTokens: prompt,
            sampling: CBv2SamplingParams(temperature: 0.0),
            maxTokens: decodeTokens,
            stopTokens: []
        ))

        var tokenIDs: [Int] = []
        var timestamps: [UInt64] = []
        var finishedAt = submittedAt
        var finishReason: CBv2FinishReason?
        for await event in stream {
            let now = DispatchTime.now().uptimeNanoseconds
            switch event {
            case .delta(_, let tokens, _):
                tokenIDs.append(contentsOf: tokens)
                timestamps.append(contentsOf: repeatElement(now, count: tokens.count))
            case .finished(let reason, _):
                finishedAt = now
                finishReason = reason
            }
        }

        guard let first = timestamps.first, let last = timestamps.last else {
            throw BenchmarkError.noTokens(row)
        }
        guard finishReason == .length else {
            throw BenchmarkError.unexpectedFinish(
                row: row,
                reason: String(describing: finishReason)
            )
        }
        guard tokenIDs.count == decodeTokens else {
            throw BenchmarkError.unexpectedTokenCount(
                row: row,
                expected: decodeTokens,
                actual: tokenIDs.count
            )
        }
        let decodeSeconds = seconds(from: first, to: last)
        let decodeTPS = tokenIDs.count > 1 && decodeSeconds > 0
            ? Double(tokenIDs.count - 1) / decodeSeconds
            : 0
        let submittedAtMs = milliseconds(from: scenarioStartedAt, to: submittedAt)
        return MeasuredRow(
            report: ArrivalInvarianceBenchmarkReport.Row(
                row: row,
                scheduledDelayMs: delayMs,
                submittedAtMs: submittedAtMs,
                arrivalErrorMs: submittedAtMs - Double(delayMs),
                ttftMs: milliseconds(from: submittedAt, to: first),
                decodeTokensPerSecond: decodeTPS,
                generatedTokens: tokenIDs.count,
                completedAtMs: milliseconds(from: scenarioStartedAt, to: finishedAt),
                tokenChecksum: checksum(tokenIDs)
            ),
            tokenIDs: tokenIDs,
            firstTokenAt: first,
            lastTokenAt: last,
            finishedAt: finishedAt
        )
    }

    private static func stopAndReclaim(_ engine: any CBv2Engine) async {
        await engine.shutdown()
        Stream().synchronize()
        Memory.clearCache()
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000_000
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func checksum(_ tokens: [Int]) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for token in tokens {
            var word = UInt64(bitPattern: Int64(token))
            for _ in 0 ..< 8 {
                value ^= word & 0xff
                value &*= 0x100000001b3
                word >>= 8
            }
        }
        return String(format: "%016llx", value)
    }

    private enum BenchmarkError: Error, CustomStringConvertible {
        case noTokens(Int)
        case unexpectedFinish(row: Int, reason: String)
        case unexpectedTokenCount(row: Int, expected: Int, actual: Int)
        case arrivalOutOfTolerance(
            pattern: String,
            iteration: Int,
            observedMs: Double,
            toleranceMs: Double,
            attempts: Int
        )

        var description: String {
            switch self {
            case .noTokens(let row): return "row \(row) produced no tokens"
            case .unexpectedFinish(let row, let reason):
                return "row \(row) finished unexpectedly: \(reason)"
            case .unexpectedTokenCount(let row, let expected, let actual):
                return "row \(row) produced \(actual) tokens, expected \(expected)"
            case .arrivalOutOfTolerance(
                let pattern, let iteration, let observed, let tolerance, let attempts
            ):
                return "arrival topology \(pattern) iteration \(iteration) could not be "
                    + "delivered within \(String(format: "%.2f", tolerance)) ms in "
                    + "\(attempts) attempt(s) (worst arrival error "
                    + "\(String(format: "%.2f", observed)) ms); host scheduling is too "
                    + "noisy for this measurement"
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[arrival-invariance] \(message)\n".utf8))
    }
}
