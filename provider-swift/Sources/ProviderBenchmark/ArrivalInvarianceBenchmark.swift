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
    }

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    public let promptTokensPerRequest: Int
    public let decodeTokensPerRequest: Int
    public let iterations: Int
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

    private struct EngineParts: @unchecked Sendable {
        let engine: any CBv2Engine
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

    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptTokens: Int = 512,
        decodeTokens: Int = 64,
        iterations: Int = 3
    ) async throws -> ArrivalInvarianceBenchmarkReport {
        let promptTokens = max(2, promptTokens)
        let decodeTokens = max(2, decodeTokens)
        let iterations = max(1, iterations)
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

        let engine = try await makeEngine(
            container: container,
            modelDirectory: modelDirectory,
            isVLM: isVLM,
            weightBytes: facts.weightBytes,
            maxConcurrentRequests: patterns.map(\.delaysMs.count).max() ?? 1
        )

        var samplesByPattern = Dictionary(
            uniqueKeysWithValues: patterns.map { ($0.name, [MeasuredSample]()) }
        )
        var nextRequestID: UInt64 = 1
        do {
            // Reuse one engine so its asynchronous compiled-decode startup and
            // every arrival topology are fully warm before measurements begin.
            for pattern in patterns {
                log("warming \(pattern.name)")
                _ = try await measure(
                    engine: engine,
                    facts: facts,
                    pattern: pattern,
                    promptTokens: promptTokens,
                    decodeTokens: min(8, decodeTokens),
                    iteration: 0,
                    requestIDBase: nextRequestID
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
                        requestIDBase: nextRequestID
                    )
                    nextRequestID += UInt64(pattern.delaysMs.count)
                    log(
                        "  \(pattern.name) i=\(iteration): aggregate "
                            + "\(String(format: "%.1f", sample.report.aggregateDecodeTokensPerSecond)) tok/s, "
                            + "makespan \(String(format: "%.1f", sample.report.makespanMs)) ms"
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
                outputsMatchBurst: allOutputs.allSatisfy { $0 == burstOutputs }
            )
        }

        return ArrivalInvarianceBenchmarkReport(
            schemaVersion: 1,
            modelID: modelID,
            modelPath: modelDirectory.path,
            promptTokensPerRequest: promptTokens,
            decodeTokensPerRequest: decodeTokens,
            iterations: iterations,
            patterns: patternReports
        )
    }

    private static func measure(
        engine: any CBv2Engine,
        facts: ModelFacts,
        pattern: PatternDefinition,
        promptTokens: Int,
        decodeTokens: Int,
        iteration: Int,
        requestIDBase: UInt64
    ) async throws -> MeasuredSample {
        let scenarioStartedAt = DispatchTime.now().uptimeNanoseconds
        let rows = try await withThrowingTaskGroup(of: MeasuredRow.self) { group in
            for (row, delayMs) in pattern.delaysMs.enumerated() {
                let prompt = ThroughputSweep.tile(
                    facts.baseTokens,
                    to: promptTokens,
                    offset: row * 17 + 1
                )
                group.addTask {
                    if delayMs > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    }
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
                makespanMs: makespanSeconds * 1000
            ),
            outputs: rows.map(\.tokenIDs)
        )
    }

    private static func makeEngine(
        container: ModelContainer,
        modelDirectory: URL,
        isVLM: Bool,
        weightBytes: Int,
        maxConcurrentRequests: Int
    ) async throws -> any CBv2Engine {
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, weightBytes)),
                configReserveBytes: 0
            ),
            UInt64(Int.max)
        ))
        let parts = try await container.perform { context -> EngineParts in
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: context.model,
                isVLM: isVLM,
                modelDirectory: modelDirectory
            )
            return EngineParts(engine: try EngineV2Factory.makeProductionEngine(
                model: servingModel,
                tokenizer: context.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: maxConcurrentRequests
            ))
        }
        return parts.engine
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
        return MeasuredRow(
            report: ArrivalInvarianceBenchmarkReport.Row(
                row: row,
                scheduledDelayMs: delayMs,
                submittedAtMs: milliseconds(from: scenarioStartedAt, to: submittedAt),
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

        var description: String {
            switch self {
            case .noTokens(let row): return "row \(row) produced no tokens"
            case .unexpectedFinish(let row, let reason):
                return "row \(row) finished unexpectedly: \(reason)"
            case .unexpectedTokenCount(let row, let expected, let actual):
                return "row \(row) produced \(actual) tokens, expected \(expected)"
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[arrival-invariance] \(message)\n".utf8))
    }
}
