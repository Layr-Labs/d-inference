// Copyright © 2026 Eigen Labs.
//
// KV-backend GATE tests over the REAL `EngineV2Factory.makeProductionBuild`
// with tiny real-family models (JSON-decoded configs, random-init weights,
// no downloads): production-safe `auto` (always contiguous), the fleet
// kill switch at the deepest layer, explicit
// selections, and the eligibility fallback (ineligible head dim → paged
// selection degrades to contiguous, never a refusal).
//
// These tests CONSTRUCT engines (paged construction materializes its slab
// pool — a small Metal eval), but never run a forward pass.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Tiny real-family fixtures

private func decodeConfig<T: Decodable>(_ json: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(T.self, from: data)
}

/// 2-layer GPT-OSS: alternating sliding/full derivation, sinks on every
/// layer, headDim 64 / GQA 2 — the paged kernel's validated shape family.
private func tinyGPTOSS(headDim: Int = 64) throws -> GPTOSSModel {
    let config: GPTOSSConfiguration = try decodeConfig([
        "model_type": "gpt_oss",
        "num_hidden_layers": 2,
        "num_local_experts": 4,
        "num_experts_per_tok": 2,
        "vocab_size": 128,
        "rms_norm_eps": 1e-5,
        "hidden_size": 64,
        "intermediate_size": 64,
        "head_dim": headDim,
        "num_attention_heads": 4,
        "num_key_value_heads": 2,
        "sliding_window": 32,
    ])
    return GPTOSSModel(config)
}

/// 2-layer Gemma-4 text: [sliding(16), full], no KV sharing, headDim 64.
private func tinyGemma4Text() throws -> Gemma4TextModel {
    let config: Gemma4TextConfiguration = try decodeConfig([
        "model_type": "gemma4_text",
        "hidden_size": 64,
        "num_hidden_layers": 2,
        "intermediate_size": 128,
        "num_attention_heads": 4,
        "head_dim": 64,
        "global_head_dim": 64,
        "vocab_size": 128,
        "vocab_size_per_layer_input": 128,
        "num_key_value_heads": 2,
        "num_kv_shared_layers": 0,
        "hidden_size_per_layer_input": 32,
        "sliding_window": 16,
        "sliding_window_pattern": 2,
        "max_position_embeddings": 2048,
        "use_double_wide_mlp": false,
    ])
    return Gemma4TextModel(config)
}

private struct GateProcessorError: Error {}

private struct GateProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw GateProcessorError()
    }
}

private final class GateCacheCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _cache: SSDPrefixCache?
    private var _capability: CBv2PrefixReuseCapability?

    func set(cache: SSDPrefixCache, capability: CBv2PrefixReuseCapability) {
        lock.withLock {
            _cache = cache
            _capability = capability
        }
    }

    var cache: SSDPrefixCache? { lock.withLock { _cache } }
    var capability: CBv2PrefixReuseCapability? { lock.withLock { _capability } }
}

private let gateTestCapacity = 8 << 20  // 8 MiB pool — tiny but constructible

private func makeBuild(
    model: any LanguageModel,
    kvBackend: EngineV2KVBackendSelection,
    environment: [String: String] = [:],
    pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
) throws -> EngineV2Factory.ProductionBuild {
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    return try EngineV2Factory.makeProductionBuild(
        model: model,
        tokenizer: StubBridgeTokenizer(),
        kvBytesCapacity: gateTestCapacity,
        prefixCache: nil,
        maxConcurrentRequests: 2,
        kvBackend: kvBackend,
        maxContextLength: 2048,
        environment: environment,
        pagedPreflightOverride: pagedPreflightOverride)
}

// MARK: - Tests

@Suite("EngineV2 KV-backend gate (real tiny models)", .serialized)
struct EngineV2KVBackendGateTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("auto is contiguous for GPT-OSS and cannot drift with family defaults")
    func autoServesContiguousForGPTOSS() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .auto)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesBackendCapacity == gateTestCapacity)
        await build.engine.shutdown()
    }

    @Test("auto resolves contiguous for Gemma-4 (bf16 KV stays opt-in)")
    func autoServesContiguousForGemma() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), kvBackend: .auto)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("explicit contiguous wins over the GPT-OSS auto default")
    func explicitContiguous() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .contiguous)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("explicit paged GPT-OSS preflights packaged resources and physical pool truth")
    func explicitPagedGPTOSS() async throws {
        try PagedAttentionKernel.validateRuntimeResources()
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .paged)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesCapacity > 0)
        #expect(snapshot.kvBytesCapacity == snapshot.kvBytesBackendCapacity)
        #expect(snapshot.kvBytesCapacity < gateTestCapacity)
        await build.engine.shutdown()
    }

    @Test("explicit paged serves Gemma-4 TEXT (eligible shapes, opt-in)")
    func explicitPagedGemmaText() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), kvBackend: .paged)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("fleet kill switch forces explicit paged to contiguous at the deepest layer")
    func killSwitchForcesContiguous() async throws {
        let build = try makeBuild(
            model: try tinyGPTOSS(),
            kvBackend: .paged,
            environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"])
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == "kill_switch")
        await build.engine.shutdown()
    }

    @Test("kernel-ineligible shape falls back to contiguous, never refuses")
    func ineligibleFallsBack() async throws {
        // headDim 80 is outside the paged kernel's {64,128,256,512}.
        let build = try makeBuild(model: try tinyGPTOSS(headDim: 80), kvBackend: .paged)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason?.hasPrefix("kernel_preflight:") == true)
        await build.engine.shutdown()
    }

    @Test("failed kernel preflight falls back to contiguous before slab construction")
    func failedPreflightFallsBack() async throws {
        struct PreflightFailure: Error {}
        let build = try makeBuild(
            model: try tinyGPTOSS(),
            kvBackend: .paged,
            pagedPreflightOverride: { _ in throw PreflightFailure() })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason?.hasPrefix("kernel_preflight:") == true)
        await build.engine.shutdown()
    }

    @Test("explicit paged fallback constructs frozen-full cache for resolved contiguous backend")
    func pagedFallbackConstructsFrozenCache() async throws {
        struct PreflightFailure: Error {}
        let model = try tinyGemma4Text()
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: model,
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: [:],
            pagedPreflightOverride: { _ in throw PreflightFailure() })
        #expect(prepared.kind == .contiguous)
        #expect(prepared.fallbackReason?.hasPrefix("kernel_preflight:") == true)

        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: prepared.layerKinds,
            backendSelection: .contiguous)
        #expect(capability.strategy == .frozenFullReplay)
        #expect(capability.isSupported)

        let capacityFallback = try EngineV2Factory.prepareProductionBackend(
            model: model,
            kvBytesCapacity: 1_024,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: [:],
            pagedPreflightOverride: { _ in })
        #expect(capacityFallback.kind == .contiguous)
        #expect(capacityFallback.fallbackReason?.hasPrefix("physical_capacity:") == true)
        #expect(PrefixCachePolicy.prefixReuseCapability(
            layerKinds: capacityFallback.layerKinds,
            backendSelection: .contiguous
        ).strategy == .frozenFullReplay)

        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("paged-fallback-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SSDPrefixCache(
            config: .init(
                modelId: "tiny-gemma-paged-fallback",
                promptContractID: "tiny-gemma-contract",
                weightHash: "tiny-gemma-weights",
                blockSize: PrefixCachePolicy.blockSize,
                adoptionBoundTokens: capability.conservativeReplayBoundTokens,
                nominalFullKVBytesPerToken: capability.fullKVBytesPerToken,
                layoutEpoch: SSDBlockStore.layoutEpoch(
                    blockSize: PrefixCachePolicy.blockSize,
                    layerKinds: prepared.layerKinds),
                root: root,
                ttlSeconds: 900,
                minEffectiveTokens: 1,
                maxStageBytes: 1 << 20,
                maxStageMillis: 1_000,
                nowSeconds: { 1_000 }),
            kekKey: SymmetricKey(size: .bits256),
            kvBudget: nil,
            diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 0,
            strictFsync: false,
            diskBudgetBytes: { 1 << 20 })
        defer { cache.close() }

        let build = try EngineV2Factory.assembleProductionBuild(
            model: model,
            tokenizer: StubBridgeTokenizer(),
            prefixCache: cache,
            maxConcurrentRequests: 2,
            mtpDrafter: nil,
            mtpConfig: CBv2MTPConfig(),
            preparedBackend: prepared)
        #expect(build.kvBackendKind == .contiguous)
        let engine = try #require(build.engine as? EngineV2)
        #expect(engine.prefixReuseCapability.strategy == .frozenFullReplay)
        #expect(throws: CBv2KVError.self) {
            _ = try EngineV2Factory.assembleProductionBuild(
                model: model,
                tokenizer: StubBridgeTokenizer(),
                prefixCache: cache,
                maxConcurrentRequests: 2,
                mtpDrafter: nil,
                mtpConfig: CBv2MTPConfig(),
                preparedBackend: prepared)
        }
        await build.engine.shutdown()
    }

    @Test("slot factory resolves paged fallback before constructing frozen cache")
    func slotFactoryOrdersResolvedBackendBeforeCache() async throws {
        struct PreflightFailure: Error {}
        let model = try tinyGemma4Text()
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "tiny/gemma"),
                model: model,
                processor: GateProcessor(),
                tokenizer: tokenizer))
        let preparedModel = EngineV2PreparedModel(
            snapshot: EngineV2ModelSnapshot(
                model: model,
                eosTokenIds: [1],
                extraEOSTokens: []),
            servingModel: model,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("slot-fallback-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = GateCacheCapture()

        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: "tiny-gemma",
            modelType: "gemma4_text",
            isVLM: false,
            modelDirectory: nil,
            container: container,
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1,
                fp16KVBytesPerToken: 1_024,
                maxContextLength: 2_048,
                defaultMaxTokens: 32),
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBudget: nil,
            kvQuantConfigured: false,
            kvBackendConfig: "paged",
            weightHash: String(repeating: "a", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(
                promptContractID: "tiny-gemma-contract",
                pagedPreflight: { _ in throw PreflightFailure() },
                makePrefixCache: { layerKinds, capability in
                    let cache = SSDPrefixCache(
                        config: .init(
                            modelId: "tiny-gemma",
                            promptContractID: "tiny-gemma-contract",
                            weightHash: String(repeating: "a", count: 64),
                            blockSize: PrefixCachePolicy.blockSize,
                            adoptionBoundTokens: capability.conservativeReplayBoundTokens,
                            nominalFullKVBytesPerToken: capability.fullKVBytesPerToken,
                            layoutEpoch: SSDBlockStore.layoutEpoch(
                                blockSize: PrefixCachePolicy.blockSize,
                                layerKinds: layerKinds),
                            root: root,
                            ttlSeconds: 900,
                            minEffectiveTokens: 1,
                            maxStageBytes: 1 << 20,
                            maxStageMillis: 1_000,
                            nowSeconds: { 1_000 }),
                        kekKey: SymmetricKey(size: .bits256),
                        kvBudget: nil,
                        diskBudget: SSDDiskBudget(),
                        maxWriteBytesPerDay: 0,
                        strictFsync: false,
                        diskBudgetBytes: { 1 << 20 })
                    capture.set(cache: cache, capability: capability)
                    return cache
                }),
            environment: [:])
        let cache = try #require(capture.cache)
        let backendKind = await bundle.bridge.kvBackendKind
        #expect(backendKind == .contiguous)
        #expect(bundle.bridge.ssdPrefixCache === cache)
        #expect(capture.capability?.strategy == .frozenFullReplay)
        #expect(capture.capability?.backend == .contiguousUnquantized)
        await bundle.bridge.shutdown()
    }

    @Test("slot factory publishes GPT-OSS native contiguous rate without SSD staging")
    func slotFactoryPublishesNativeGPTOSSRate() async throws {
        let model = try tinyGPTOSS()
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "tiny/gpt-oss"),
                model: model,
                processor: GateProcessor(),
                tokenizer: tokenizer))
        let preparedModel = EngineV2PreparedModel(
            snapshot: EngineV2ModelSnapshot(
                model: model,
                eosTokenIds: [1],
                extraEOSTokens: []),
            servingModel: model,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)
        let nominalRate = 100_000
        let expectedRate =
            nominalRate
            + CBv2PrefixReuseCapability.derive(
                layerKinds: model.cbv2LayerKinds,
                backend: .contiguousUnquantized
            ).fullKVBytesPerToken

        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: "tiny-gpt-oss",
            modelType: "gpt_oss",
            isVLM: false,
            modelDirectory: nil,
            container: container,
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1,
                fp16KVBytesPerToken: nominalRate,
                maxContextLength: 2_048,
                defaultMaxTokens: 32),
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBudget: nil,
            kvQuantConfigured: false,
            kvBackendConfig: "contiguous",
            weightHash: String(repeating: "b", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            environment: [PrefixCachePolicy.environmentFlag: "0"])
        let backendKind = await bundle.bridge.kvBackendKind
        let nativeRate = await bundle.bridge.kvBytesPerToken
        let heartbeat = await bundle.bridge.backendSlotCapacity()
        #expect(backendKind == .contiguous)
        #expect(nativeRate == expectedRate)
        #expect(heartbeat.kvBytesPerToken == Int64(expectedRate))
        await bundle.bridge.shutdown()
    }
}
