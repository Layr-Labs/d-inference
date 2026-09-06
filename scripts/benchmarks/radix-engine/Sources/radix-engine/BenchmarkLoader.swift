import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
#else
import ProviderCore
#endif

/// Only explicit resident reproduction uses the older direct factory. SSD
/// measurements use the ordinary slot factory after the same load hash bracket.
enum BenchmarkLoader {
    static func load(
        options: BenchmarkOptions, report: HTTPReport, modelID: String,
        environment: [String: String]? = nil
    ) async throws -> Loaded {
        try options.persistentTestKeys?.validate(environment: environment ?? ProcessInfo.processInfo.environment)
        #if !RADIX_CANDIDATE
        guard !options.productionKVGrant else {
            throw RadixBenchmark.Failure.message("production grant requires the candidate artifact")
        }
        #endif
        #if RADIX_CANDIDATE
        if options.cacheMode == "ssd" {
            guard let digest = bindRuntimeMetallibForMLX() else {
                throw RadixBenchmark.Failure.message("normal immutable metallib binding failed")
            }
            RadixBenchmark.log("bound-metallib: " + digest)
        }
        #endif
        let directory = options.modelDirectory
        let cacheEnabled = options.cacheEnabled
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("config.json"))) as! [String: Any]
        let isVLM = config["vision_config"] is [String: Any]
        let modelType = config["model_type"] as? String
        #if RADIX_CANDIDATE
        let hashBefore = options.cacheMode == "ssd"
            ? WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) : nil
        #endif
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        }
        #if RADIX_CANDIDATE
        if options.cacheMode == "ssd" {
            guard let hashBefore,
                WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) == hashBefore
            else { throw RadixBenchmark.Failure.message("model hash changed or unavailable around load") }
            if let expected = options.expectedModelSHA256, hashBefore != expected {
                throw RadixBenchmark.Failure.message("loaded artifact hash does not match the pinned model")
            }
            let input = try await container.perform { context in
                try inputs(report, context: context, modelType: modelType)
            }
            var effectiveEnvironment = environment ?? ProcessInfo.processInfo.environment
            effectiveEnvironment["DARKBLOOM_PREFIX_CACHE"] = options.cacheEnabled ? "1" : "0"
            try options.persistentTestKeys?.validate(environment: effectiveEnvironment)
            let session = try await EngineV2Factory.makeBenchmarkSession(
                modelId: modelID, modelDirectory: directory, isVLM: isVLM,
                container: container, tokenizer: TokenizerHandle(input.tokenizer),
                verifiedWeightHash: hashBefore, kvBytesCapacity: options.kvBudgetBytes,
                maxConcurrentRequests: options.concurrency, mtpEnabled: options.mtpEnabled,
                assistantDirectory: options.assistantDirectory,
                gemmaMTPVerification: options.gemmaMTPVerification.flatMap(EngineV2BenchmarkMTPVerification.init(rawValue:)),
                useProductionKVGrant: options.productionKVGrant,
                kvBackendConfig: options.backend.rawValue,
                requirePersistentKey: options.requirePersistentKey,
                persistentTestNamespace: options.persistentTestKeys?.namespace, environment: effectiveEnvironment)
            var projection: Data?
            if let tokens = options.gemmaProjectionTokens {
                do {
                    projection = try await container.perform { context in
                        let target = try EngineV2Factory.benchmarkServingModel(
                            model: context.model, isVLM: isVLM, modelDirectory: directory)
                        return try BenchmarkGemmaProjection.capture(target: target, tokens: tokens,
                            verifiedModelSHA256: hashBefore,
                            directory: options.outputURL.deletingPathExtension().appendingPathExtension("gemma-projection"))
                    }
                } catch {
                    await session.shutdown()
                    throw error
                }
            }
            return Loaded(engine: session.rawEngine, tokenizer: input.tokenizer,
                inputs: input.inputs, warmup: input.warmup, eos: input.eos, backend: session.backend,
                fallback: session.backendFallback, verifiedModelHash: hashBefore,
                gemmaProjection: projection, session: session)
        }
        #endif
        guard options.gemmaMTPVerification == nil else {
            throw RadixBenchmark.Failure.message("Gemma verifier control requires the production benchmark session")
        }
        return try await container.perform { context -> Loaded in
            let model = try EngineV2Factory.benchmarkServingModel(
                model: context.model, isVLM: isVLM, modelDirectory: directory)
            let assistant = options.mtpEnabled
                ? try Qwen35InlineMTPAssistant.load(from: directory, target: model) : nil
            let verification = assistant?.requiredVerificationMode ?? .automatic
            let mtpConfig = CBv2MTPConfig(
                enabled: options.mtpEnabled, fixedDraftTokens: nil, verificationMode: verification,
                maxAutomaticRectangularTokens: verification == .automatic
                    ? MTPAutomaticVerificationPolicy.maxRectangularTokens() : 0)
            let input = try inputs(report, context: context, modelType: modelType)
            #if RADIX_CANDIDATE
            let hybrid = cacheEnabled ? CBv2HybridPrefixCacheConfig(
                maximumBytes: 1_073_741_824, maximumEntries: 32, maximumCheckpointsPerRequest: 2,
                modelID: modelID, promptContractID: "radix-benchmark-thinking-off-v1",
                buildID: "radix-benchmark-v1") : nil
            let resident = cacheEnabled ? CBv2PagedPrefixCacheConfig(
                promptContractID: "radix-benchmark-thinking-off-v1", scopeID: modelID) : nil
            let build = try EngineV2Factory.makeProductionBuild(
                model: model, modelID: modelID, tokenizer: context.tokenizer,
                kvBytesCapacity: options.kvBudgetBytes, maxConcurrentRequests: options.concurrency,
                residentPrefixCache: resident, hybridPrefixCache: hybrid,
                mtpDrafter: assistant, mtpConfig: mtpConfig, kvBackend: options.backend)
            #else
            let build = try EngineV2Factory.makeProductionBuild(
                model: model, tokenizer: context.tokenizer,
                kvBytesCapacity: options.kvBudgetBytes, maxConcurrentRequests: options.concurrency,
                mtpDrafter: assistant, mtpConfig: mtpConfig, kvBackend: options.backend)
            #endif
            if options.mtpEnabled, (build.engine as? EngineV2)?.mtpMetricsSnapshot() == nil {
                throw RadixBenchmark.Failure.message("MTP requested but engine has no active drafter")
            }
            return Loaded(engine: build.engine, tokenizer: input.tokenizer, inputs: input.inputs,
                          warmup: input.warmup, eos: input.eos, backend: build.kvBackendKind.rawValue, fallback: build.kvBackendFallbackReason)
        }
    }

    struct PreparedInput: @unchecked Sendable {
        let tokenizer: any MLXLMCommon.Tokenizer
        let inputs: [Input]
        let warmup: Input
        let eos: Set<Int>
    }

    private static func inputs(_ report: HTTPReport, context: ModelContext, modelType: String?) throws -> PreparedInput {
        let rendering = templateContext()
        func prepare(name: String, kind: String, body: Data, maxTokens: Int) throws -> Input {
            #if RADIX_CANDIDATE
            let prompt = try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: context.tokenizer,
                modelType: modelType, defaultDate: PromptRenderDate(rendering.date!)!)
            return Input(name: name, kind: kind, tokens: prompt.tokens, maxTokens: maxTokens,
                         promptRenderDate: prompt.renderDate)
            #else
            guard let raw = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = raw["messages"] as? [[String: String]] else {
                throw RadixBenchmark.Failure.message("historical renderer accepts plain role/content messages only")
            }
            let values: [[String: any Sendable]] = messages.map { $0.mapValues { $0 as any Sendable } }
            let tokens = try context.tokenizer.applyChatTemplate(messages: values, tools: nil,
                                                                 additionalContext: rendering.values)
            return Input(name: name, kind: kind, tokens: tokens, maxTokens: maxTokens)
            #endif
        }
        let inputs = try report.rows.map { row in
            try prepare(name: row.case.id, kind: row.case.kind,
                body: JSONEncoder().encode(row.request.body), maxTokens: row.request.max_tokens)
        }
        let warmupBody: [String: Any] = ["model": report.rows[0].request.model,
            "messages": [["role": "user", "content": "Say hello."]], "max_tokens": 8,
            "chat_template_kwargs": ["enable_thinking": false],
            "_darkbloom_prompt_date": inputs[0].promptRenderDate as Any? ?? NSNull()]
        let warmup = try prepare(name: "excluded-warmup", kind: "warmup",
            body: JSONSerialization.data(withJSONObject: warmupBody), maxTokens: 8)
        var eos = context.configuration.eosTokenIds
        if let token = context.tokenizer.eosTokenId { eos.insert(token) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { eos.insert(id) }
        }
        return PreparedInput(tokenizer: context.tokenizer, inputs: inputs, warmup: warmup, eos: eos)
    }

    static func templateContext() -> (date: String?, values: [String: any Sendable]) {
        #if RADIX_CANDIDATE
        let date = PromptRenderDate.capture()
        var result = date.templateContext()
        result["enable_thinking"] = false
        return (date.value, result)
        #else
        // Preserve the historical renderer in a baseline that predates the
        // request-owned date contract. Such an artifact is not a GPT v2 oracle.
        return (nil, ["enable_thinking": false])
        #endif
    }
}
