import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

public struct SchedulerPrefillBenchmarkReport: Codable, Sendable {
    /// 1: the first VERSIONED scheduler-prefill payload — adds the required
    ///    `kvBackend` block and the per-sample `resolvedKVBackend`. An
    ///    UNVERSIONED payload predates the backend pin and cannot say which
    ///    backend it measured, so a gate must refuse it rather than assume.
    /// 2 adds required effective config-projected Gemma settings.
    /// 3 adds `soloPrefillStripeTokens` — the effective solo-stripe posture
    /// the measured engines were built with (nil/absent = plain 512 chunks).
    /// 4 adds per-cell memory evidence and full-context warmup.
    /// 4 adds optional prompt metadata: absent fields in older reports mean
    /// unspecified provenance, not a verified fixed-prompt run.
    /// 5 adds `prefillChunkTokens` and `maxBatchedTokensPerStep`: the plain
    /// chunk is no longer always 512, so a nil stripe alone is ambiguous.
    public static let currentSchemaVersion = 5

    public struct Sample: Codable, Sendable {
        public let strategy: String
        public let promptTokens: Int
        public let iteration: Int
        public let ttftMs: Double
        public let peakMemoryBytes: Int
        public let activeMemoryBytes: Int
        public let msPerPrefillToken: Double
        /// The backend THIS sample's engine actually resolved to. Per sample
        /// rather than once per run because each measurement builds its own
        /// engine: a selection can be honoured at L=128 and degrade at
        /// L=28k, and a TTFT curve averaged across that describes neither
        /// backend.
        public let resolvedKVBackend: String
        /// Seed-token offset passed to tiling, before wrapping by seed length.
        public var promptOffset: Int? = nil
    }

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    public let promptLengths: [Int]
    public let strategies: [String]
    public let iterations: Int
    /// Config-projected Gemma settings this subprocess actually benchmarked.
    public let gemmaOptimizations: BenchmarkGemmaOptimizations
    /// Selection versus the backends the measured engines were built with.
    public let kvBackend: BenchmarkKVBackend
    /// Effective `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` the measured engines
    /// were built with (nil = no stripe above `prefillChunkTokens`). Recorded
    /// so a stripe arm can never masquerade as a plain-chunk baseline.
    public let soloPrefillStripeTokens: Int?
    /// Effective plain chunk and step budget of the measured engines; absent
    /// before schema 5, when every production chunk was 512 tokens.
    public let prefillChunkTokens: Int?
    public let maxBatchedTokensPerStep: Int?
    public let samples: [Sample]
    public var promptMode: SchedulerPrefillBenchmark.PromptMode? = nil
    /// Both the bootstrap and full-context warmups use this offset.
    public var warmupPromptOffset: Int? = nil

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

    public enum PromptMode: String, Codable, Sendable {
        case rotating
        case fixed
    }

    /// Shared by warmup and measured requests. Fixed mode changes only the
    /// seed offset; engine construction, cache posture and timing stay intact.
    static func makePrompt(
        baseTokens: [Int], length: Int, iteration: Int, mode: PromptMode = .rotating
    ) -> (tokens: [Int], offset: Int) {
        let offset = mode == .fixed ? 0 : iteration * 17
        return (ThroughputSweep.tile(baseTokens, to: length, offset: offset), offset)
    }

    /// Qwen3.6 35B solo prefill measured in the release trust+stripe posture.
    public static let qwenReleaseModeledPromptTPS =
        SchedulerPrefillDecisionScenarios.qwenModeledPromptTokensPerSecond
    public static let qwenReleaseDecisionWorkloads =
        SchedulerPrefillDecisionScenarios.qwenReleaseWorkloads

    /// `kvBackend` is the operator-facing selection handed to the production
    /// factory, exactly as in `ThroughputSweep.run`. Quantized `.auto` requires
    /// paged storage; native `.auto` retains its model policy and fallback.
    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptLengths: [Int],
        iterations: Int,
        kvBackend: EngineV2KVBackendSelection = .auto,
        gemmaOptimizations: GemmaOptimizationSettings,
        checkpointQuantizationConfig: String = "balanced",
        fixedPrompt: Bool = false
    ) async throws -> SchedulerPrefillBenchmarkReport {
        let lengths = promptLengths.filter { $0 > 1 }.sorted()
        let iterations = max(1, iterations)
        let promptMode: PromptMode = fixedPrompt ? .fixed : .rotating
        let checkpointQuantization = try EngineV2KVQuantizationPolicy.resolve(
            modelType: ModelBenchmark.decodedModelType(
                from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))),
            global: checkpointQuantizationConfig, modelID: modelID, purpose: .checkpoint)
        // Direct factory loading bypasses the serving scheduler's allocator
        // setup. Install the same limits before allocating model weights.
        MLXMemoryGuard.configureOnce(log: { limits in
            log("allocator limits: memory_bytes=\(limits.memoryLimitBytes) cache_bytes=\(limits.cacheLimitBytes)")
        })
        log("allocator applied: cache_limit_bytes=\(Memory.cacheLimit)")
        Memory.peakMemory = 0
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
            eval(ctx.model.parameters().flattened().map { $0.1 })
            let encoded = ctx.tokenizer.encode(text: ThroughputSweep.seedText, addSpecialTokens: false)
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            return (encoded.isEmpty ? [0] : encoded, bytes)
        }
        log("load memory: active_bytes=\(Memory.activeMemory) peak_bytes=\(Memory.peakMemory)")
        let baseTokens = facts.baseTokens

        log("kv backend selection \(kvBackend.rawValue)")
        log("prompt mode: \(promptMode.rawValue); warmup offset=0")

        // Warm-up (kernel compiles, Metal pipelines) — not recorded. It is
        // also the FIRST engine an explicit, unservable `--kv-backend paged`
        // is refused on, so the run fails here rather than after a full
        // matrix of measurements nobody can attribute. Its engine also fixes the
        // prompt geometry the receipt records: the scheduler handed to the
        // engine, after serving, calibration and GLM policy.
        let geometry = try await measureOne(
            container: container,
            modelID: modelID,
            baseTokens: baseTokens,
            promptTokens: min(lengths.first ?? 128, 128),
            iteration: 0,
            promptMode: promptMode,
            weightBytes: facts.weightBytes,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            kvBackend: kvBackend,
            checkpointQuantization: checkpointQuantization
        ).geometry

        var samples: [SchedulerPrefillBenchmarkReport.Sample] = []
        var resolved: [String] = []
        for length in lengths {
            // Warm the actual context geometry; the short bootstrap cannot
            // compile all kernels a long-context cell will exercise.
            log("warming prefill shape: prompt=\(length), maxTokens=1 (unmeasured)")
            _ = try await measureOne(
                container: container, modelID: modelID, baseTokens: baseTokens,
                promptTokens: length, iteration: 0, promptMode: promptMode,
                weightBytes: facts.weightBytes,
                isVLM: isVLM, modelDirectory: modelDirectory, kvBackend: kvBackend,
                checkpointQuantization: checkpointQuantization)
        }
        for length in lengths {
            for iteration in 1 ... iterations {
                let measured = try await measureOne(
                    container: container,
                    modelID: modelID,
                    baseTokens: baseTokens,
                    promptTokens: length,
                    iteration: iteration,
                    promptMode: promptMode,
                    weightBytes: facts.weightBytes,
                    isVLM: isVLM,
                    modelDirectory: modelDirectory,
                    kvBackend: kvBackend,
                    checkpointQuantization: checkpointQuantization
                )
                guard measured.geometry == geometry else {
                    throw BenchmarkError.requestFailed(
                        "L=\(length) engine prompt geometry differs from the warm-up engine's")
                }
                let sample = measured.sample
                if !resolved.contains(sample.resolvedKVBackend) {
                    resolved.append(sample.resolvedKVBackend)
                    log("  engine resolved kv backend: \(sample.resolvedKVBackend)")
                }
                log("  \(strategyLabel) L=\(length) i=\(iteration): \(String(format: "%.3f", sample.msPerPrefillToken)) ms/t (\(String(format: "%.1f", sample.ttftMs)) ms)")
                samples.append(sample)
            }
        }

        return SchedulerPrefillBenchmarkReport(
            schemaVersion: SchedulerPrefillBenchmarkReport.currentSchemaVersion,
            modelID: modelID,
            modelPath: modelDirectory.path,
            promptLengths: lengths,
            strategies: [strategyLabel],
            iterations: iterations,
            gemmaOptimizations: BenchmarkGemmaOptimizations(
                settings: gemmaOptimizations),
            kvBackend: BenchmarkKVBackend(
                selection: kvBackend.rawValue, resolved: resolved),
            soloPrefillStripeTokens: geometry.soloPrefillStripeTokens,
            prefillChunkTokens: geometry.prefillChunkTokens,
            maxBatchedTokensPerStep: geometry.maxBatchedTokensPerStep,
            samples: samples,
            promptMode: promptMode,
            warmupPromptOffset: 0
        )
    }

    private static func measureOne(
        container: ModelContainer,
        modelID: String,
        baseTokens: [Int],
        promptTokens: Int,
        iteration: Int,
        promptMode: PromptMode,
        weightBytes: Int,
        isVLM: Bool,
        modelDirectory: URL,
        kvBackend: EngineV2KVBackendSelection,
        checkpointQuantization: EngineV2KVQuantizationSelection
    ) async throws -> (sample: SchedulerPrefillBenchmarkReport.Sample,
        geometry: EngineV2Factory.PrefillGeometry)
    {
        // Same KV-ceiling derivation as a single-model serving slot; far
        // above what one row needs, so admission never binds.
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, weightBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        struct EngineParts: @unchecked Sendable {
            let engine: any CBv2Engine
            /// The backend the factory resolved to, with any fallback reason.
            let resolvedBackend: String
            let geometry: EngineV2Factory.PrefillGeometry?
        }
        // `makeProductionBuild` is the construction `makeProductionEngine`
        // wraps, and additionally hands back the backend the engine actually
        // resolved to — without it a forwarded selection could not be shown
        // to have been honoured.
        let parts = try await container.perform { ctx -> EngineParts in
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: ctx.model, isVLM: isVLM, modelDirectory: modelDirectory)
            let build = try EngineV2Factory.makeProductionBuild(
                model: servingModel,
                modelID: modelID,
                tokenizer: ctx.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: 1,
                constructionPurpose: .benchmark,
                kvBudget: BenchmarkMemoryBudget.shared,
                kvBackend: kvBackend,
                checkpointQuantization: checkpointQuantization)
            return EngineParts(
                engine: build.engine,
                resolvedBackend: build.resolvedKVBackendDescriptor,
                geometry: build.prefillGeometry)
        }
        let engine = parts.engine
        guard let geometry = parts.geometry else {
            await stopAndReclaim(engine)
            throw BenchmarkError.requestFailed("production build carried no prompt geometry")
        }

        let prompt = makePrompt(
            baseTokens: baseTokens, length: promptTokens, iteration: iteration, mode: promptMode)
        Memory.peakMemory = 0
        let started = ContinuousClock.now
        let stream = try engine.submit(CBv2Request(
            id: CBv2RequestID(1),
            promptTokens: prompt.tokens,
            sampling: CBv2SamplingParams(temperature: 0.0),
            maxTokens: 1
        ))

        var firstOutput: Duration?
        var generatedTokens = 0
        var finishReason: CBv2FinishReason?
        for await event in stream {
            if case .delta(_, let tokens, _) = event {
                generatedTokens += tokens.count
                if !tokens.isEmpty, firstOutput == nil {
                    firstOutput = ContinuousClock.now - started
                }
            }
            if case .finished(let reason, _) = event {
                finishReason = reason
                break
            }
        }
        if let failure = ThroughputSweep.decodeRowFailure(
            expectedTokens: 1, tokenCount: generatedTokens, finishReason: finishReason)
        {
            await stopAndReclaim(engine)
            throw BenchmarkError.requestFailed(failure)
        }
        guard let elapsed = firstOutput else {
            await stopAndReclaim(engine)
            throw BenchmarkError.requestFailed("prefill produced no output token")
        }
        let peakMemoryBytes = Memory.peakMemory
        let activeMemoryBytes = Memory.activeMemory
        let ttftMs = ThroughputSweep.seconds(elapsed) * 1000.0
        let prefillTokens = max(1, promptTokens - 1)
        await stopAndReclaim(engine)
        let sample = SchedulerPrefillBenchmarkReport.Sample(
            strategy: strategyLabel,
            promptTokens: promptTokens,
            iteration: iteration,
            ttftMs: ttftMs,
            peakMemoryBytes: peakMemoryBytes,
            activeMemoryBytes: activeMemoryBytes,
            msPerPrefillToken: ttftMs / Double(prefillTokens),
            resolvedKVBackend: parts.resolvedBackend,
            promptOffset: prompt.offset
        )
        return (sample, geometry)
    }

    static func stopAndReclaim(_ engine: any CBv2Engine) async {
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
