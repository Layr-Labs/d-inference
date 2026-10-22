// Copyright © 2026 Eigen Labs.
// Production prompt geometry: Gemma 4 takes the wide plain chunk, its
// bidirectional media keeps the SDK chunk, every other family keeps the SDK
// geometry, and explicit overrides roll back or opt in without changing what
// the paged pool is sized from.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

private func decodeGeometryConfig<T: Decodable>(_ json: [String: Any]) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
}

private func geometryGPTOSS() throws -> GPTOSSModel {
    GPTOSSModel(try decodeGeometryConfig([
        "model_type": "gpt_oss", "num_hidden_layers": 2, "num_local_experts": 4,
        "num_experts_per_tok": 2, "vocab_size": 128, "rms_norm_eps": 1e-5,
        "hidden_size": 64, "intermediate_size": 64, "head_dim": 64,
        "num_attention_heads": 4, "num_key_value_heads": 2, "sliding_window": 32,
    ]))
}

private func qwenTextConfig(moe: Bool) -> [String: Any] {
    var text: [String: Any] = [
        "model_type": moe ? "qwen3_5_moe_text" : "qwen3_5_text", "hidden_size": 64,
        "num_hidden_layers": 2, "intermediate_size": moe ? 32 : 64, "num_attention_heads": 1,
        "num_key_value_heads": 1, "head_dim": 64, "linear_num_value_heads": 1,
        "linear_num_key_heads": 1, "linear_key_head_dim": 64, "linear_value_head_dim": 64,
        "linear_conv_kernel_dim": 4, "full_attention_interval": 2, "vocab_size": 64,
    ]
    if moe {
        text.merge([
            "num_experts": 4, "num_experts_per_tok": 2, "moe_intermediate_size": 32,
            "shared_expert_intermediate_size": 32, "norm_topk_prob": true,
        ]) { _, new in new }
    }
    return ["model_type": moe ? "qwen3_5_moe" : "qwen3_5", "text_config": text]
}

private func geometryDenseQwen() throws -> Qwen35Model {
    Qwen35Model(try decodeGeometryConfig(qwenTextConfig(moe: false)) as Qwen35Configuration)
}

private func geometryMoEQwen() throws -> Qwen35MoEModel {
    Qwen35MoEModel(try decodeGeometryConfig(qwenTextConfig(moe: true)) as Qwen35Configuration)
}

/// `vision` bidirectional attention lets the tiny text tower serve CBv2 spans.
private func geometryGemma4Text() throws -> Gemma4TextModel {
    Gemma4TextModel(try decodeGeometryConfig([
        "model_type": "gemma4_text", "hidden_size": 64, "num_hidden_layers": 2,
        "intermediate_size": 128, "num_attention_heads": 4, "head_dim": 64,
        "global_head_dim": 64, "vocab_size": 128, "vocab_size_per_layer_input": 128,
        "num_key_value_heads": 2, "num_kv_shared_layers": 0,
        "hidden_size_per_layer_input": 32, "sliding_window": 16,
        "sliding_window_pattern": 2, "max_position_embeddings": 2048,
        "use_double_wide_mlp": false, "use_bidirectional_attention": "vision",
    ]))
}

private typealias Geometry = EngineV2Factory.PrefillGeometry

private let sdk = CBv2SchedulerConfig()

private let rollback = [
    EngineV2Factory.prefillChunkKey: "512", EngineV2Factory.stepTokenBudgetKey: "2048",
]

private let optIn = [
    EngineV2Factory.prefillChunkKey: "2048", EngineV2Factory.stepTokenBudgetKey: "4096",
]

private func geometry(
    _ model: (any LanguageModel)?, _ environment: [String: String] = [:]
) -> Geometry {
    EngineV2Factory.prefillGeometry(model: model, environment: environment)
}

private func wide(stripe: Int?) -> Geometry {
    Geometry(
        prefillChunkTokens: 2048, maxBatchedTokensPerStep: 4096, soloPrefillStripeTokens: stripe,
        bidirectionalMediaPrefillChunkCeiling: sdk.prefillChunkSize)
}

private func sdkGeometry(stripe: Int?) -> Geometry {
    Geometry(
        prefillChunkTokens: sdk.prefillChunkSize, maxBatchedTokensPerStep: sdk.maxBatchedTokensPerStep,
        soloPrefillStripeTokens: stripe, bidirectionalMediaPrefillChunkCeiling: nil)
}

@Suite("Production prefill geometry")
struct EngineV2PrefillGeometryTests {
    @Test("only Gemma 4 takes the wide chunk by default")
    func gemmaUsesWideChunk() throws {
        #expect(geometry(try geometryGemma4Text()) == wide(stripe: nil))
    }

    @Test("every other family keeps the SDK geometry and its armed stripe")
    func otherFamiliesKeepSDKGeometry() throws {
        // GPT-OSS and dense Qwen measured faster with the wide chunk, but their
        // activation peaks rose further above their floors at 8 x 32k.
        let models: [(any LanguageModel)?] = [nil, try geometryMoEQwen(), try geometryGPTOSS()]
        for model in models {
            let name = model.map { String(describing: type(of: $0)) } ?? "nil"
            #expect(geometry(model) == sdkGeometry(stripe: EngineV2Factory.defaultSoloPrefillStripeTokens),
                "\(name)")
        }
        #expect(geometry(try geometryDenseQwen())
            == sdkGeometry(stripe: EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens))
    }

    @Test("the scheduler config carries exactly the resolved geometry")
    func schedulerConfigUsesGeometry() throws {
        let models: [any LanguageModel] = [
            try geometryGPTOSS(), try geometryGemma4Text(), try geometryDenseQwen(), try geometryMoEQwen(),
        ]
        for model in models {
            let resolved = geometry(model)
            let config = EngineV2Factory.productionSchedulerConfig(
                maxConcurrentRequests: 8, model: model, environment: [:])
            #expect(config.prefillChunkSize == resolved.prefillChunkTokens)
            #expect(config.maxBatchedTokensPerStep == resolved.maxBatchedTokensPerStep)
            #expect(config.soloPrefillStripeTokens == resolved.soloPrefillStripeTokens)
            #expect(config.bidirectionalMediaPrefillChunkCeiling
                == resolved.bidirectionalMediaPrefillChunkCeiling)
            #expect(config.maxConcurrentPartialPrefills == 1)
        }
    }

    @Test("pool sizing is unchanged: the largest schedulable chunk stays the old stripe")
    func pagedPoolChunkIsUnchanged() throws {
        // `makeSegmentedPagedBackend` sizes windowed rings, and the KV charges
        // derived from them, from max(chunk, stripe). The wide chunk, Gemma's
        // default and the measured opt-in elsewhere, replaces the 2,048-token
        // stripe rather than exceeding it, and media stays below it.
        let gemma = try geometryGemma4Text()
        #expect(geometry(gemma) == geometry(gemma, optIn))
        let models: [any LanguageModel] = [try geometryGPTOSS(), gemma, try geometryDenseQwen()]
        for model in models {
            let widened = geometry(model, optIn)
            let old = geometry(model, rollback)
            let ring = max(widened.prefillChunkTokens, widened.soloPrefillStripeTokens ?? 0)
            #expect(ring == max(old.prefillChunkTokens, old.soloPrefillStripeTokens ?? 0))
            #expect(widened.soloPrefillStripeTokens.map { $0 > widened.prefillChunkTokens } ?? true)
            #expect((widened.bidirectionalMediaPrefillChunkCeiling ?? 0) <= ring)
        }
    }

    @Test("512 and 2048 restore the SDK geometry, including the re-armed stripe")
    func explicitRollback() throws {
        #expect(geometry(try geometryGPTOSS(), rollback)
            == sdkGeometry(stripe: EngineV2Factory.defaultSoloPrefillStripeTokens))
        #expect(geometry(try geometryGemma4Text(), rollback)
            == sdkGeometry(stripe: EngineV2Factory.defaultSoloPrefillStripeTokens))
        #expect(geometry(try geometryDenseQwen(), rollback)
            == sdkGeometry(stripe: EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens))
        // The chunk alone already selects the SDK budget: twice 512 is below it.
        let gemma = try geometryGemma4Text()
        #expect(geometry(gemma, [EngineV2Factory.prefillChunkKey: "512"]) == geometry(gemma, rollback))
    }

    @Test("an explicit chunk applies to every family, scales the budget and keeps media narrow")
    func explicitChunkOverride() throws {
        #expect(geometry(try geometryMoEQwen(), [EngineV2Factory.prefillChunkKey: "2048"])
            == wide(stripe: nil))
        #expect(geometry(try geometryGPTOSS(), [EngineV2Factory.prefillChunkKey: "1024"])
            == Geometry(prefillChunkTokens: 1024, maxBatchedTokensPerStep: 2048,
                soloPrefillStripeTokens: EngineV2Factory.defaultSoloPrefillStripeTokens,
                bidirectionalMediaPrefillChunkCeiling: sdk.prefillChunkSize))
        #expect(geometry(try geometryDenseQwen(), [EngineV2Factory.prefillChunkKey: "8192"])
            == Geometry(prefillChunkTokens: 8192, maxBatchedTokensPerStep: 16384,
                soloPrefillStripeTokens: nil, bidirectionalMediaPrefillChunkCeiling: sdk.prefillChunkSize))
        #expect(geometry(nil, [EngineV2Factory.prefillChunkKey: "256"])
            == Geometry(prefillChunkTokens: 256, maxBatchedTokensPerStep: sdk.maxBatchedTokensPerStep,
                soloPrefillStripeTokens: EngineV2Factory.defaultSoloPrefillStripeTokens,
                bidirectionalMediaPrefillChunkCeiling: nil))
        let saturated = geometry(nil, [EngineV2Factory.prefillChunkKey: String(Int.max)])
        #expect(saturated.prefillChunkTokens == Int.max)
        #expect(saturated.maxBatchedTokensPerStep == Int.max)
    }

    @Test("malformed or nonpositive chunks restore the SDK chunk for every family")
    func malformedChunkFailsTowardSDK() throws {
        let gemma = try geometryGemma4Text()
        for raw in ["0", "-512", "2k", "", " 2048"] {
            #expect(geometry(gemma, [EngineV2Factory.prefillChunkKey: raw])
                == sdkGeometry(stripe: EngineV2Factory.defaultSoloPrefillStripeTokens), "\(raw)")
        }
    }

    @Test("a step budget must cover the chunk; anything else restores the SDK budget")
    func stepBudgetOverride() throws {
        let gemma = try geometryGemma4Text()
        func budget(_ raw: String) -> Int {
            geometry(gemma, [EngineV2Factory.stepTokenBudgetKey: raw]).maxBatchedTokensPerStep
        }
        #expect(budget("6144") == 6144)
        #expect(budget("2048") == 2048)
        for raw in ["2047", "0", "-1", "4k", ""] {
            #expect(budget(raw) == sdk.maxBatchedTokensPerStep, "\(raw)")
        }
        let wideChunk = [
            EngineV2Factory.prefillChunkKey: "4096", EngineV2Factory.stepTokenBudgetKey: "1",
        ]
        #expect(geometry(nil, wideChunk).maxBatchedTokensPerStep == 4096)
    }
}

/// Drives production paged assemblies of tiny real models through the real
/// scheduler: a decoding row keeps the engine busy, so the measured prompt can
/// only prefill beside it.
@Suite("Production prefill geometry through the real scheduler", .serialized)
struct EngineV2PrefillGeometryEngineTests {
    private static let environment = [
        KVBackendGuardStore.pathEnvKey: "/dev/null",
        EngineV2KVQuantizationPolicy.environmentKey: "native",
        "DARKBLOOM_PREFIX_CACHE": "0",
    ]

    private func prefillBesideDecode(
        model: any LanguageModel, request: (CBv2RequestID) -> CBv2Request,
        overrides: [String: String] = [:], maxContextLength: Int
    ) async throws -> CBv2RequestTiming {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let build = try EngineV2Factory.makeProductionBuild(
            model: model, tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: 64 << 20, maxConcurrentRequests: 2, kvBackend: .paged,
            maxContextLength: maxContextLength,
            environment: Self.environment.merging(overrides) { _, explicit in explicit })
        #expect(build.kvBackendKind == .paged)
        let engine = build.engine
        do {
            let decoder = try engine.submit(CBv2Request(
                id: .init(1), promptTokens: Array(repeating: 3, count: 64),
                sampling: .init(temperature: 0), maxTokens: 512, prefixCacheEnabled: false))
            let firstToken = AsyncStream<Void>.makeStream()
            let drain = Task {
                var signalled = false
                for await event in decoder {
                    if case .delta = event, !signalled {
                        signalled = true
                        firstToken.continuation.yield()
                    }
                }
                firstToken.continuation.finish()
            }
            for await _ in firstToken.stream { break }
            let measured = try engine.submit(request(.init(2)))
            var timing: CBv2RequestTiming?
            for await event in measured {
                if case .finished(let reason, let usage) = event {
                    #expect(reason == .length)
                    timing = usage.timing
                }
            }
            engine.cancel(.init(1))
            await drain.value
            await engine.shutdown()
            return try #require(timing)
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    private static func textRequest(_ id: CBv2RequestID, tokens: Int) -> CBv2Request {
        CBv2Request(
            id: id, promptTokens: (0..<tokens).map { $0 % 100 + 1 },
            sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false)
    }

    @Test("a busy GPT-OSS engine keeps 512-token chunks; the opt-in prefills 2,048")
    func busyEngineChunkGeometry() async throws {
        let model = try geometryGPTOSS()
        let request = { (id: CBv2RequestID) in Self.textRequest(id, tokens: 5_000) }
        let widened = try await prefillBesideDecode(
            model: model, request: request, overrides: optIn, maxContextLength: 8_192)
        #expect(widened.prefillChunkTokensMax == 2_048)
        #expect(widened.prefillChunks == 3)
        #expect(widened.soloStripeChunks == 0)
        let sdk = try await prefillBesideDecode(model: model, request: request, maxContextLength: 8_192)
        #expect(sdk.prefillChunkTokensMax == 512)
        #expect(sdk.prefillChunks == UInt32((5_000 + 511) / 512))
        #expect(sdk.soloStripeChunks == 0)
    }

    @Test("Gemma 4 text widens beside decode while its bidirectional media keeps 512")
    func gemmaMediaKeepsSDKChunk() async throws {
        let hidden = 64
        let prompt = 1_800
        let text = try await prefillBesideDecode(
            model: try geometryGemma4Text(),
            request: { Self.textRequest($0, tokens: prompt) }, maxContextLength: 2_048)
        #expect(text.prefillChunkTokensMax == UInt32(prompt))
        #expect(text.prefillChunks == 1)

        let span = CBv2ImageSpan(tokenOffset: 1_100, length: 40)
        let embedding = MLXArray.zeros([1, span.length, hidden], dtype: .float32)
        eval(embedding)
        let media = try await prefillBesideDecode(
            model: try geometryGemma4Text(),
            request: { id in
                var request = Self.textRequest(id, tokens: prompt)
                request.multimodal = CBv2MultimodalInput(spans: [span]) { [embedding] }
                return request
            }, maxContextLength: 2_048)
        #expect(media.prefillChunkTokensMax == 512)
        #expect(media.prefillChunks == UInt32((prompt + 511) / 512))
        #expect(media.visionChunks == 1)
    }
}
