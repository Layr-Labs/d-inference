// Copyright © 2026 Eigen Labs.
//
// KV-backend GATE tests over the REAL `EngineV2Factory.makeProductionBuild`
// with tiny real-family models (JSON-decoded configs, random-init weights,
// no downloads): production-safe `auto` (always contiguous), the fleet
// kill switch at the deepest layer, explicit selections, and the
// degrade-or-REFUSE split — an explicit paged request that cannot be
// served throws `EngineV2ProductionError.pagedUnavailable` with the reason
// attached, while the kill switch still degrades because an operator
// override is not a failure.
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

private final class GateTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func record(_ event: TelemetryEvent) { lock.withLock { _events.append(event) } }
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

/// Run `body` and require it REFUSED an explicit paged request, returning
/// the reason the refusal carries. `body` COMPLETING is itself the
/// failure: it means the policy silently degraded to contiguous, which is
/// the exact defect OPEN-9 closes — a run that reports paged and measures
/// contiguous. Also pins the telemetry classification, because
/// `engine_init_failed` would bury a paged regression among unrelated bad
/// model loads.
private func pagedRefusalReason(
    _ body: () async throws -> Void
) async -> String? {
    do {
        try await body()
        Issue.record("explicit paged must refuse, not degrade to contiguous")
        return nil
    } catch let error as EngineV2ProductionError {
        guard case .pagedUnavailable(let reason) = error else {
            Issue.record("expected .pagedUnavailable, got \(error)")
            return nil
        }
        #expect(EngineV2RefusalReason.classify(error) == .pagedBackendUnavailable)
        #expect("\(error)".contains("explicitly requested but unavailable"))
        return reason
    } catch {
        Issue.record("expected EngineV2ProductionError, got \(error)")
        return nil
    }
}

// MARK: - Tests

@Suite("EngineV2 KV-backend gate (real tiny models)", .serialized)
struct EngineV2KVBackendGateTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("auto is PAGED for GPT-OSS and cannot drift with family defaults")
    func autoServesPagedForGPTOSS() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .auto)
        // v0.8.0 flipped `.auto` from contiguous to paged. This assertion is
        // the anti-drift guard for that decision in BOTH directions: it
        // caught the flip when it landed, and it will catch a silent revert.
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        // Paged reports the PHYSICAL pool it committed, not the logical
        // admission grant a contiguous slot advertises, so this is
        // deliberately not `gateTestCapacity`.
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesBackendCapacity > 0)
        await build.engine.shutdown()
    }

    @Test("auto resolves PAGED for Gemma-4 (bf16 KV stays opt-in)")
    func autoServesPagedForGemma() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), kvBackend: .auto)
        #expect(build.kvBackendKind == .paged)
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

    // DEGRADE, deliberately — the one paged-to-contiguous case that
    // survives OPEN-9, and the only test pinning the distinction. The kill
    // switch is an operator override ("do NOT do what you asked"), not a
    // failure ("we CANNOT do what you asked"); refusing here would 503
    // every slot on a fleet configured `engine_v2_kv_backend = "paged"`
    // the moment an operator pulled it. The three refusal tests below are
    // the other half of that split.
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

    @Test("kernel-ineligible shape REFUSES an explicit paged request")
    func ineligibleShapeRefusesExplicitPaged() async throws {
        // headDim 80 is outside the paged kernel's {64,128,256,512}.
        let reason = await pagedRefusalReason {
            let build = try makeBuild(
                model: try tinyGPTOSS(headDim: 80), kvBackend: .paged)
            // Reached only on a policy regression; still tear the engine
            // down so the failure is one clean assertion, not a leak too.
            await build.engine.shutdown()
        }
        #expect(reason?.hasPrefix("kernel_preflight:") == true)
    }

    @Test("failed kernel preflight REFUSES before slab construction")
    func failedPreflightRefuses() async throws {
        struct PreflightFailure: Error {}
        let reason = await pagedRefusalReason {
            let build = try makeBuild(
                model: try tinyGPTOSS(),
                kvBackend: .paged,
                pagedPreflightOverride: { _ in throw PreflightFailure() })
            await build.engine.shutdown()
        }
        #expect(reason?.hasPrefix("kernel_preflight:") == true)
        // The underlying cause survives into the refusal, so an operator
        // reading the 503 sees WHY paged could not be served.
        #expect(reason?.contains("PreflightFailure") == true)
    }

    @Test("physical-capacity shortfall REFUSES an explicit paged request")
    func capacityShortfallRefusesExplicitPaged() async throws {
        let reason = await pagedRefusalReason {
            _ = try EngineV2Factory.prepareProductionBackend(
                model: try tinyGemma4Text(),
                kvBytesCapacity: 1_024,
                maxConcurrentRequests: 2,
                kvBackend: .paged,
                maxContextLength: 2048,
                environment: [:],
                pagedPreflightOverride: { _ in })
        }
        #expect(reason?.hasPrefix("physical_capacity:") == true)
    }

    @Test("`.auto` still degrades when paged cannot be served")
    func autoDegradesOnPagedFailure() async throws {
        // Layer 5's degrade half. `.auto` short-circuits to contiguous
        // before any paged attempt today, so the real construction path
        // cannot reach the branch; the policy predicate is the seam that
        // decides it, and it must keep answering "degrade" for every
        // non-explicit selection or an auto fleet starts 503-ing the day
        // auto begins resolving paged.
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .auto))
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .contiguous))
        #expect(!EngineV2KVBackendPolicy.degradesPagedFailure(selection: .paged))
    }

    @Test("kill-switch degrade constructs frozen-full cache for resolved contiguous backend")
    func pagedFallbackConstructsFrozenCache() async throws {
        let model = try tinyGemma4Text()
        // The kill switch is now the only route to a DEGRADED preparation
        // from an explicit paged selection — preflight and capacity
        // failures refuse instead (see the three refusal tests above). The
        // property under test is unchanged: whatever produces a resolved
        // contiguous backend must also produce a frozen-full SSD cache
        // capability, so the cache can never be built for a backend that
        // is not the one serving.
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: model,
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"],
            pagedPreflightOverride: { _ in })
        #expect(prepared.kind == .contiguous)
        #expect(prepared.fallbackReason == "kill_switch")

        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: prepared.layerKinds,
            backendSelection: .contiguous)
        #expect(capability.strategy == .frozenFullReplay)
        #expect(capability.isSupported)

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

    @Test("paged pool is sized from the ONE scheduler config the engine runs on")
    func pagedPoolLocksStepWithSchedulerConfig() async throws {
        let model = try tinyGemma4Text()
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: model,
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: [:])
        #expect(prepared.kind == .paged)
        let (backend, _) = try prepared.consume(model: model, maxConcurrentRequests: 2)
        let paged = try #require(backend as? PagedKVBackend)
        // LOCKSTEP. `PagedSequenceKV` PRECONDITIONS that a windowed update
        // never exceeds the pool's `maxPrefillChunk` — a process kill, not
        // a throw — so the pool must be sized from the chunk the ENGINE
        // actually schedules. There is now one `CBv2SchedulerConfig` per
        // build, carried on the preparation and reused verbatim by
        // `assembleProductionBuild`; this pins the pool against it so a
        // re-introduced parallel constant fails here instead of aborting
        // the daemon under a long windowed prefill.
        #expect(
            paged.pool.config.maxPrefillChunk
                == prepared.schedulerConfig.prefillChunkSize)
        #expect(prepared.schedulerConfig.maxConcurrentRequests == 2)
        // Prefix caching is the ONLY field assembly may still decide, and
        // it is off until a cache instance is supplied.
        #expect(!prepared.schedulerConfig.enablePrefixCache)
    }

    @Test("slot factory resolves the degraded backend before constructing frozen cache")
    func slotFactoryOrdersResolvedBackendBeforeCache() async throws {
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
            kvBackendConfig: "paged",
            weightHash: String(repeating: "a", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(
                promptContractID: "tiny-gemma-contract",
                // Kill-switch degrade, not a preflight failure: an
                // explicit `paged` config whose preflight fails now
                // refuses out of this same call (see
                // `slotFactoryRefusesExplicitPagedRequest`).
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
            environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"])
        let cache = try #require(capture.cache)
        let backendKind = await bundle.bridge.kvBackendKind
        #expect(backendKind == .contiguous)
        #expect(bundle.bridge.ssdPrefixCache === cache)
        #expect(capture.capability?.strategy == .frozenFullReplay)
        #expect(capture.capability?.backend == .contiguousUnquantized)
        let status = bundle.bridge.prefixCacheModelStatus()
        #expect(status.backend == .contiguous)
        #expect(status.replayStrategy == .frozenFull)
        #expect(status.state == .pending)
        #expect(status.reason == .scanPending)
        await bundle.bridge.shutdown()
    }

    @Test("slot factory REFUSES an explicit paged request it cannot serve")
    func slotFactoryRefusesExplicitPagedRequest() async throws {
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
        let telemetry = GateTelemetrySink()

        // The production 503 path end to end: operator config says paged,
        // the kernel cannot be preflighted, so the LOAD fails instead of
        // quietly serving a contiguous slot under a paged label.
        let reason = await pagedRefusalReason {
            _ = try await EngineV2SlotFactory.makeProductionBundle(
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
                kvBackendConfig: "paged",
                weightHash: String(repeating: "a", count: 64),
                specDecPreparation: SpecDecPreparation(
                    artifact: nil,
                    status: .disabled(.configDisabled, configured: false)),
                preparedModel: preparedModel,
                assemblyOverrides: .init(
                    promptContractID: "tiny-gemma-contract",
                    pagedPreflight: { _ in throw PreflightFailure() }),
                environment: [:],
                emitTelemetry: { telemetry.record($0) })
        }
        #expect(reason?.hasPrefix("kernel_preflight:") == true)

        // ERROR `engine_v2_refusal`, classified so a paged-rollout
        // regression stays separable from every other bad load in
        // aggregate — `engine_init_failed` would bury it.
        let refusals = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_refusal"
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.severity == .error)
        #expect(
            refusals.first?.fields?["reason"]?.description
                == "paged_backend_unavailable")
        #expect(
            refusals.first?.fields?["error"]?.description
                .contains("kernel_preflight:") == true)
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
        let status = bundle.bridge.prefixCacheModelStatus()
        #expect(status.state == .disabled)
        #expect(status.reason == .configDisabled)
        await bundle.bridge.shutdown()
    }

    // MARK: VLM slot routing (WS-2.2)

    /// THROUGH the slot factory, which is the point.
    ///
    /// Every other test of paged vision — the backend suites in
    /// mlx-swift-lm, `BackendParityHarness` — constructs the engine
    /// directly and therefore never runs `applySlotVetoes`. That is exactly
    /// how the span-mask work could land, pass everywhere, and still be
    /// unreachable in production: the veto forced every VLM slot to
    /// contiguous and nothing that ran asked it. This test goes through
    /// `makeProductionBundle` and asserts the backend the bridge ACTUALLY
    /// resolved, so the next capability cannot land with the same invisible
    /// gap.
    ///
    /// `preparedModel` is supplied so the VLM text extraction (which needs a
    /// checkpoint directory) is skipped: the subject here is the ROUTING for
    /// `isVLM: true`, not the extraction.
    @Test("slot factory routes a VLM slot to paged now that the cache vouches")
    func slotFactoryRoutesVLMToPagedWhenTheCacheVouches() async throws {
        #expect(
            PagedLayerCache.honorsSpanMaskContextsByConstruction,
            "premise: the paged cache affirms span masks — if this ever goes false the expectation below must flip to .contiguous with a \"vlm\" veto")
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
                model: model, eosTokenIds: [1], extraEOSTokens: []),
            servingModel: model,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)

        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: "tiny-gemma-vlm",
            modelType: "gemma4",
            isVLM: true,
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
            kvBackendConfig: "paged",
            weightHash: String(repeating: "c", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            environment: [PrefixCachePolicy.environmentFlag: "0"])
        let backendKind = await bundle.bridge.kvBackendKind
        #expect(
            backendKind == .paged,
            "an explicit paged VLM slot must now resolve PAGED — the veto is gated on the cache's span claim, and the paged cache affirms it")
        await bundle.bridge.shutdown()
    }

    /// The other side of the same gate, and the reason it is a gate rather
    /// than a deletion: a VLM slot whose cache does NOT vouch still goes
    /// contiguous, silently, with the `"vlm"` tag for the slot log. Asserted
    /// on the policy directly because no shipping cache answers false — the
    /// veto has to keep working for the backend that has not implemented
    /// spans YET, which is the whole point of gating on the claim.
    @Test("a VLM slot whose cache does not vouch is still forced to contiguous")
    func vlmSlotWithoutSpanClaimStaysContiguous() {
        let refused = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: true, pagedHonorsSpanMasks: false)
        #expect(refused.selection == .contiguous)
        #expect(refused.veto == "vlm")

        let allowed = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: true, pagedHonorsSpanMasks: true)
        #expect(allowed.selection == .paged)
        #expect(allowed.veto == nil, "an unvetoed slot has nothing to log")
    }
}
