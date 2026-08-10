import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

public struct SchedulerPrefillBenchmarkReport: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public let strategy: String
        public let promptTokens: Int
        public let iteration: Int
        public let ttftMs: Double
        public let msPerPrefillToken: Double
    }

    public let modelID: String
    public let modelPath: String
    public let promptLengths: [Int]
    public let strategies: [String]
    public let iterations: Int
    public let samples: [Sample]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Cold-prefill TTFT benchmark through the PRODUCTION ContinuousBatchingV2
/// engine (`EngineV2Factory.makeProductionEngine` — the one-engine entry
/// point every serving slot uses as of v0.7.5). For each prompt length it
/// submits a single greedy request with `maxTokens: 1` against a fresh
/// engine and times to the first event: engine-internal chunked prefill,
/// exactly as production requests experience it. The prefix cache is not
/// constructed (the factory's `prefixCache` defaults to nil), so every
/// iteration is a true cold prefill.
///
/// The legacy strategy machinery (fixed-chunk vs adaptive prefill) died with
/// the legacy engine — CBv2's prefill chunking is engine-internal — so the
/// report's `strategy` label is always `"cbv2"`.
public enum SchedulerPrefillBenchmark {
    public static let strategyLabel = "cbv2"

    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptLengths: [Int],
        iterations: Int
    ) async throws -> SchedulerPrefillBenchmarkReport {
        let lengths = promptLengths.filter { $0 > 1 }.sorted()
        let iterations = max(1, iterations)
        log("loading model \(modelID)")
        log("  path: \(modelDirectory.path)")

        // VLM checkpoints load via the VLM factory and measure the exact
        // text tower owned by the wrapper (the production serving path).
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
        let facts = await container.perform { ctx -> (baseTokens: [Int], weightBytes: Int) in
            let encoded = ctx.tokenizer.encode(text: ThroughputSweep.seedText, addSpecialTokens: false)
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            return (encoded.isEmpty ? [0] : encoded, bytes)
        }
        let baseTokens = facts.baseTokens

        // Warm-up (kernel compiles, Metal pipelines) — not recorded.
        _ = try await measureOne(
            container: container,
            baseTokens: baseTokens,
            promptTokens: min(lengths.first ?? 128, 128),
            iteration: 0,
            weightBytes: facts.weightBytes,
            isVLM: isVLM
        )

        var samples: [SchedulerPrefillBenchmarkReport.Sample] = []
        for length in lengths {
            for iteration in 1 ... iterations {
                let sample = try await measureOne(
                    container: container,
                    baseTokens: baseTokens,
                    promptTokens: length,
                    iteration: iteration,
                    weightBytes: facts.weightBytes,
                    isVLM: isVLM
                )
                log("  \(strategyLabel) L=\(length) i=\(iteration): \(String(format: "%.3f", sample.msPerPrefillToken)) ms/t (\(String(format: "%.1f", sample.ttftMs)) ms)")
                samples.append(sample)
            }
        }

        return SchedulerPrefillBenchmarkReport(
            modelID: modelID,
            modelPath: modelDirectory.path,
            promptLengths: lengths,
            strategies: [strategyLabel],
            iterations: iterations,
            samples: samples
        )
    }

    private static func measureOne(
        container: ModelContainer,
        baseTokens: [Int],
        promptTokens: Int,
        iteration: Int,
        weightBytes: Int,
        isVLM: Bool
    ) async throws -> SchedulerPrefillBenchmarkReport.Sample {
        // Same KV-ceiling derivation as a single-model serving slot; far
        // above what one row needs, so admission never binds.
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, weightBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        let engine = try await container.perform { ctx -> any CBv2Engine in
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: ctx.model, isVLM: isVLM)
            return try EngineV2Factory.makeProductionEngine(
                model: servingModel,
                tokenizer: ctx.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: 1)
        }

        let prompt = ThroughputSweep.tile(baseTokens, to: promptTokens, offset: iteration * 17)
        let started = ContinuousClock.now
        let stream = try engine.submit(CBv2Request(
            id: CBv2RequestID(1),
            promptTokens: prompt,
            sampling: CBv2SamplingParams(temperature: 0.0),
            maxTokens: 1
        ))

        var firstOutput: Duration?
        for await event in stream {
            if firstOutput == nil {
                firstOutput = ContinuousClock.now - started
            }
            if case .finished(let reason, _) = event {
                if case .error(let message) = reason {
                    await stopAndReclaim(engine)
                    throw BenchmarkError.requestFailed(message)
                }
                break
            }
        }
        let elapsed = firstOutput ?? (ContinuousClock.now - started)
        let ttftMs = ThroughputSweep.seconds(elapsed) * 1000.0
        let prefillTokens = max(1, promptTokens - 1)
        await stopAndReclaim(engine)
        return SchedulerPrefillBenchmarkReport.Sample(
            strategy: strategyLabel,
            promptTokens: promptTokens,
            iteration: iteration,
            ttftMs: ttftMs,
            msPerPrefillToken: ttftMs / Double(prefillTokens)
        )
    }

    private static func stopAndReclaim(_ engine: any CBv2Engine) async {
        await engine.shutdown()
        Stream().synchronize()
        Memory.clearCache()
    }

    private enum BenchmarkError: Error, CustomStringConvertible {
        case requestFailed(String)

        var description: String {
            switch self {
            case .requestFailed(let message): return message
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[scheduler-prefill] \(message)\n".utf8))
    }
}
