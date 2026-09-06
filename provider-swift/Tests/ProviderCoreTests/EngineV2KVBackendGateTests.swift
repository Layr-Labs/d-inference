// Copyright © 2026 Eigen Labs.
//
// KV-backend GATE tests over the REAL `EngineV2Factory.makeProductionBuild`
// with tiny real-family models (JSON-decoded configs, random-init weights,
// no downloads): exact-artifact candidate `auto`, the
// fleet kill switch at the deepest layer, explicit selections, and the
// degrade-or-REFUSE split — an explicit paged request that cannot be
// served throws `EngineV2ProductionError.pagedUnavailable` with the reason
// attached, while the kill switch still degrades because an operator
// override is not a failure.
//
// These tests construct engines with empty segmented storage and run native
// dtype/resource preflight; they do not run a serving forward pass.

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

private let candidateQwenIDs = [
    "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
    "EigenLabs/Qwen3.8-27B-4bit-mtp",
]

private func tinyQwen() throws -> Qwen35MoEModel {
    let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: Data("""
        {"model_type":"qwen3_5_moe","text_config":{
          "model_type":"qwen3_5_moe_text","hidden_size":64,"num_hidden_layers":4,
          "intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,
          "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
          "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
          "full_attention_interval":4,"vocab_size":64,"num_experts":4,
          "num_experts_per_tok":2,"moe_intermediate_size":32,
          "shared_expert_intermediate_size":32,"norm_topk_prob":true}}
        """.utf8))
    return Qwen35MoEModel(configuration)
}

/// 2-layer GPT-OSS: alternating sliding/full derivation, sinks on every
/// layer, headDim 64 / GQA 2 — the paged kernel's validated shape family.
/// `kvHeads` widens the KV geometry for the pool-throw test, which needs a
/// page big enough that a floor-sized plan holds only one.
private func tinyGPTOSS(headDim: Int = 64, kvHeads: Int = 2) throws -> GPTOSSModel {
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
        "num_attention_heads": max(4, kvHeads),
        "num_key_value_heads": kvHeads,
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

/// One-way "did this run?" latch for closures the factory may or may not
/// invoke. Asserting that work did NOT happen needs a sink; a Bool captured
/// by a `@Sendable` closure will not compile.
private final class GateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() { lock.withLock { _value = true } }
    var value: Bool { lock.withLock { _value } }
}

private final class GateTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func record(_ event: TelemetryEvent) { lock.withLock { _events.append(event) } }
}

private let gateTestCapacity = 8 << 20  // 8 MiB pool — tiny but constructible

/// Hermetic default for every construction in this suite: point the
/// crash-loop guard store at a file that can never decode. Without it a
/// developer box whose REAL provider tripped the guard on the checked-out
/// version would fail every explicit-paged assertion here — the same reason
/// tests inject `environment:` instead of inheriting the shell's kill switch.
/// A caller's explicit value wins.
private let hermeticGuardEnvironment = [KVBackendGuardStore.pathEnvKey: "/dev/null"]

private func gateEnvironment(_ overrides: [String: String] = [:]) -> [String: String] {
    hermeticGuardEnvironment.merging(overrides) { _, explicit in explicit }
}

private func makeBuild(
    model: any LanguageModel,
    modelID: String? = nil,
    kvBackend: EngineV2KVBackendSelection,
    kvBudget: GlobalKVCacheBudget? = nil,
    hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil,
    environment: [String: String] = [:],
    pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
) throws -> EngineV2Factory.ProductionBuild {
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    return try EngineV2Factory.makeProductionBuild(
        model: model,
        modelID: modelID,
        tokenizer: StubBridgeTokenizer(),
        kvBytesCapacity: gateTestCapacity,
        // Deliberately 2: these gates assert BACKEND SELECTION, and a small
        // pool keeps construction cheap. Production defaults to B=4 while
        // still supporting explicit overrides through B=8.
        maxConcurrentRequests: 2,
        kvBudget: kvBudget,
        prefixCache: nil,
        hybridPrefixCache: hybridPrefixCache,
        kvBackend: kvBackend,
        maxContextLength: 2048,
        environment: gateEnvironment(environment),
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

    @Test(arguments: candidateQwenIDs)
    func candidateAutoBuild(modelID: String) async throws {
        let build = try makeBuild(model: tinyQwen(), modelID: modelID, kvBackend: .auto)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType != nil)
        #expect(build.engine.capacity().kvBytesCapacity == gateTestCapacity)
        await build.engine.shutdown()
    }

    @Test("public engine entry point forwards the candidate model identity")
    func candidatePublicEngineEntryPoint() async throws {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: tinyQwen(), modelID: candidateQwenIDs[0], tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: gateTestCapacity, maxConcurrentRequests: 2,
            maxContextLength: 2048, environment: gateEnvironment())
        #expect(engine.capacity().pagedStorage != nil)
        await engine.shutdown()
    }

    @Test(arguments: [EngineV2KVBackendSelection.auto, .contiguous])
    func candidateExplicitContiguousAndMissingIdentity(selection: EngineV2KVBackendSelection) async throws {
        let preflightRan = GateFlag()
        let build = try makeBuild(
            model: tinyQwen(), modelID: selection == .auto ? nil : candidateQwenIDs[0],
            kvBackend: selection, pagedPreflightOverride: { _ in preflightRan.set() })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(!preflightRan.value)
        await build.engine.shutdown()
    }

    @Test(arguments: candidateQwenIDs, [false, true])
    func candidateAutoDegradesFailures(modelID: String, invalidDType: Bool) async throws {
        let preflightRan = GateFlag()
        let build = try makeBuild(
            model: tinyQwen(), modelID: modelID, kvBackend: .auto,
            environment: invalidDType ? [EngineV2Factory.pagedPoolDTypeEnvKey: "invalid"] : [:],
            pagedPreflightOverride: { _ in
                preflightRan.set()
                throw GateProcessorError()
            })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.pagedPoolDType == nil)
        #expect(build.kvBackendFallbackReason?.hasPrefix(
            invalidDType ? "invalid_dtype:" : "kernel_preflight:") == true)
        #expect(preflightRan.value == !invalidDType)
        await build.engine.shutdown()
    }

    @Test(arguments: [EngineV2KVBackendSelection.auto, .paged], [false, true])
    func candidateGuardAndKillSwitch(selection: EngineV2KVBackendSelection, killed: Bool) async throws {
        try await withGuardFile(KVBackendGuard(
            trippedAt: 1, providerVersion: ProviderCore.version, crashCount: 3)
        ) { environment in
            var environment = environment
            if killed { environment[EngineV2KVBackendPolicy.killSwitchEnvKey] = "0" }
            let build = try makeBuild(
                model: tinyQwen(), modelID: candidateQwenIDs[0],
                kvBackend: selection, environment: environment)
            let guarded = selection == .auto
            #expect(build.kvBackendKind == (killed || guarded ? .contiguous : .paged))
            #expect(build.kvBackendFallbackReason == (
                killed ? "kill_switch" : guarded ? "crash_loop_guard" : nil))
            await build.engine.shutdown()
        }
    }

    @Test("candidate auto retries paged when the crash guard belongs to another version")
    func candidateStaleGuard() async throws {
        try await withGuardFile(KVBackendGuard(
            trippedAt: 1, providerVersion: ProviderCore.version + "-other", crashCount: 3)
        ) { environment in
            let build = try makeBuild(
                model: tinyQwen(), modelID: candidateQwenIDs[0],
                kvBackend: .auto, environment: environment)
            #expect(build.kvBackendKind == .paged)
            #expect(build.kvBackendFallbackReason == nil)
            await build.engine.shutdown()
        }
    }

    @Test(arguments: [EngineV2KVBackendSelection.auto, .paged, .contiguous], [false, true])
    func hybridBudgetFollowsResolvedBackend(selection: EngineV2KVBackendSelection, killed: Bool) async throws {
        let hybridBytes = 1 << 20
        let hybrid = CBv2HybridPrefixCacheConfig(
            maximumBytes: hybridBytes, modelID: candidateQwenIDs[0],
            promptContractID: "candidate-budget-contract", buildID: "candidate-budget-build")
        let environment = killed ? [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"] : [:]
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: tinyQwen(), modelID: candidateQwenIDs[0],
            kvBytesCapacity: gateTestCapacity, maxConcurrentRequests: 2,
            kvBackend: selection, maxContextLength: 2048,
            environment: gateEnvironment(environment), hybridPrefixCache: hybrid)
        let contiguous = selection == .contiguous || killed
        #expect((prepared.hybridPrefixCache != nil) == contiguous)
        let build = try makeBuild(
            model: tinyQwen(), modelID: candidateQwenIDs[0], kvBackend: selection,
            hybridPrefixCache: hybrid, environment: environment)
        #expect(build.kvBackendKind == (contiguous ? .contiguous : .paged))
        #expect(build.engine.capacity().kvBytesCapacity == gateTestCapacity - (contiguous ? hybridBytes : 0))
        await build.engine.shutdown()
    }

    @Test("automatic preflight fallback reserves only its installed hybrid bank")
    func hybridBudgetAfterAutomaticFallback() async throws {
        let hybridBytes = 1 << 20
        let hybrid = CBv2HybridPrefixCacheConfig(
            maximumBytes: hybridBytes, modelID: candidateQwenIDs[0],
            promptContractID: "fallback-budget-contract", buildID: "fallback-budget-build")
        let build = try makeBuild(
            model: tinyQwen(), modelID: candidateQwenIDs[0], kvBackend: .auto,
            hybridPrefixCache: hybrid, pagedPreflightOverride: { _ in throw GateProcessorError() })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason?.hasPrefix("kernel_preflight:") == true)
        #expect(build.engine.capacity().kvBytesCapacity == gateTestCapacity - hybridBytes)
        await build.engine.shutdown()
    }

    @Test("an unused hybrid bank cannot reject a paged grant")
    func unusedHybridBudgetCannotRefusePaged() async throws {
        let hybrid = CBv2HybridPrefixCacheConfig(
            maximumBytes: gateTestCapacity * 2, modelID: candidateQwenIDs[0],
            promptContractID: "unused-budget-contract", buildID: "unused-budget-build")
        let build = try makeBuild(
            model: tinyQwen(), modelID: candidateQwenIDs[0], kvBackend: .auto,
            hybridPrefixCache: hybrid)
        #expect(build.kvBackendKind == .paged)
        #expect(build.engine.capacity().kvBytesCapacity == gateTestCapacity)
        await build.engine.shutdown()
        #expect(throws: EngineV2ProductionError.self) {
            try makeBuild(model: tinyQwen(), modelID: candidateQwenIDs[0],
                kvBackend: .contiguous, hybridPrefixCache: hybrid)
        }
    }

    @Test("two paged builds share one owner authority and empty teardown retires both",
          arguments: [false, true])
    func sharedPagedOwners(candidateAuto: Bool) async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            let usage = Memory.snapshot()
            return .init(total: 64 << 30, active: UInt64(usage.activeMemory),
                         cache: UInt64(usage.cacheMemory), systemAvailable: 64 << 30)
        })
        var first: EngineV2Factory.ProductionBuild? = try makeBuild(
            model: candidateAuto ? tinyQwen() : tinyGemma4Text(),
            modelID: candidateAuto ? candidateQwenIDs[0] : nil,
            kvBackend: candidateAuto ? .auto : .paged, kvBudget: budget)
        var second: EngineV2Factory.ProductionBuild? = try makeBuild(
            model: candidateAuto ? tinyQwen() : tinyGemma4Text(),
            modelID: candidateAuto ? candidateQwenIDs[1] : nil,
            kvBackend: candidateAuto ? .auto : .paged, kvBudget: budget)
        #expect(first?.usesProcessMemoryOwner == true)
        #expect(second?.usesProcessMemoryOwner == true)
        #expect(budget.processLedger.snapshot().ownerCount == 2)
        #expect(budget.processLedger.snapshot().chargedBytes == 0)
        await first?.engine.shutdown()
        first = nil // Empty native pool deinit must not write to the retired owner.
        #expect(budget.processLedger.snapshot().ownerCount == 1)
        await second?.engine.shutdown()
        second = nil
        #expect(budget.processLedger.snapshot().ownerCount == 0)
        let contiguous = try makeBuild(model: tinyGemma4Text(), kvBackend: .contiguous, kvBudget: budget)
        #expect(!contiguous.usesProcessMemoryOwner)
        #expect(budget.processLedger.snapshot().ownerCount == 0)
        await contiguous.engine.shutdown()
    }

    @Test(arguments: ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
    func releaseAttentionModelsDefaultToPaged(modelID: String) async throws {
        let model: any LanguageModel = try modelID == "gpt-oss-20b"
            ? tinyGPTOSS() : tinyGemma4Text()
        let build = try makeBuild(model: model, modelID: modelID, kvBackend: .auto)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType != nil)
        #expect(build.engine.capacity().kvBytesCapacity == gateTestCapacity)
        await build.engine.shutdown()
    }

    @Test("auto resolves CONTIGUOUS for Gemma-4")
    func autoServesContiguousForGemma() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), modelID: "gemma-4-26b", kvBackend: .auto)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType == nil)
        await build.engine.shutdown()
    }

    @Test("an EXPLICIT paged selection still resolves paged after the v0.8.1 flip")
    func explicitPagedSurvivesTheContiguousDefault() async throws {
        // The path that must survive the revert. `.auto` moving to
        // contiguous is a change to the DEFAULT; it must not quietly become
        // a change to the backend's availability, or the parity harness,
        // the blocking paged CI lane and every by-model override lose their
        // subject. Driven for both families, because the default and the
        // explicit selection are read in the same `switch`.
        for model in [try tinyGPTOSS() as any LanguageModel, try tinyGemma4Text()] {
            let build = try makeBuild(model: model, kvBackend: .paged)
            #expect(build.kvBackendKind == .paged)
            #expect(build.kvBackendFallbackReason == nil)
            #expect(build.pagedPoolDType == "float32") // Random-init tiny model parameters are FP32.
            await build.engine.shutdown()
        }
    }

    @Test("explicit contiguous wins over the GPT-OSS auto default")
    func explicitContiguous() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .contiguous)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("explicit paged GPT-OSS preflights resources and preserves its admitted segmented grant")
    func explicitPagedGPTOSS() async throws {
        try PagedAttentionKernel.validateRuntimeResources()
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .paged)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesCapacity > 0)
        #expect(snapshot.kvBytesCapacity == snapshot.kvBytesBackendCapacity)
        #expect(snapshot.kvBytesCapacity == gateTestCapacity)
        let storage = try #require(snapshot.pagedStorage)
        #expect(storage.grantBytes == gateTestCapacity)
        #expect(storage.committedBytes == 0)
        #expect(storage.segmentCount == 0 && storage.addressPages == 0)
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

    @Test("a tiny admitted grant constructs empty segmented metadata without an eager-pool minimum")
    func tinyGrantDoesNotRequireEagerPoolMinimum() throws {
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: try tinyGemma4Text(),
            kvBytesCapacity: 1_024,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: [:],
            pagedPreflightOverride: { _ in })
        #expect(prepared.kind == .paged)
        #expect(prepared.fallbackReason == nil)
        #expect(prepared.pagedPoolConfig?.capacityBytes == 1_024)
        #expect(prepared.pagedPoolConfig?.segmentSizeBytes != nil)
    }

    @Test("non-explicit selections permit paged-failure degradation")
    func nonExplicitSelectionsPermitPagedFailureDegradation() async throws {
        // Automatic candidate selection must retain the degrade contract;
        // an explicit `.paged` request must continue to refuse instead.
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .auto))
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .contiguous))
        #expect(!EngineV2KVBackendPolicy.degradesPagedFailure(selection: .paged))
    }

    // MARK: unidentified `.auto` never enters the paged branch

    @Test("unidentified `.auto` never enters the paged ladder — no preflight, no reason, no dtype")
    func autoNeverEntersThePagedLadder() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let preflightRan = GateFlag()

        // Without an exact model ID, a throwing preflight and invalid dtype
        // must remain unconsulted, even with a tiny admitted grant.
        struct PreflightFailure: Error {}
        let build = try EngineV2Factory.makeProductionBuild(
            model: try tinyGemma4Text(),
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: 1_024,
            maxConcurrentRequests: 2,
            kvBackend: .auto,
            maxContextLength: 2048,
            environment: gateEnvironment(
                [EngineV2Factory.pagedPoolDTypeEnvKey: "invalid"]),
            pagedPreflightOverride: { _ in
                preflightRan.set()
                throw PreflightFailure()
            })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType == nil)
        // Unknown identities must not pay the paged preflight cost.
        #expect(!preflightRan.value, "`.auto` must not run the paged kernel preflight")
        await build.engine.shutdown()
    }

    // MARK: crash-loop guard resolution (the guard's factory half; the
    // watchdog half, the store semantics and the activation predicate all
    // live in WatchdogCrashLoopGuardTests).

    private func withGuardFile(
        _ record: KVBackendGuard?,
        _ body: ([String: String]) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        if let record {
            #expect(KVBackendGuardStore.write(record, environment: env))
        }
        try await body(env)
    }

    @Test("the crash-loop guard degrades automatically paged GPT-OSS with truthful fallback")
    func crashLoopGuardDegradesGPTOSSDefault() async throws {
        try await withGuardFile(
            KVBackendGuard(
                trippedAt: 1, providerVersion: ProviderCore.version, crashCount: 3)
        ) { env in
            #expect(
                EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                    record: KVBackendGuardStore.read(environment: env),
                    runningVersion: ProviderCore.version),
                "premise: the record is ACTIVE — if this goes false the test below proves nothing")

            let build = try makeBuild(
                model: try tinyGPTOSS(), modelID: "gpt-oss-20b", kvBackend: .auto, environment: env)
            #expect(build.kvBackendKind == .contiguous)
            #expect(
                build.kvBackendFallbackReason == "crash_loop_guard",
                "the exact GPT-OSS default is paged, so the guard must report the degrade")
            await build.engine.shutdown()
        }
    }

    @Test("explicit paged IGNORES the crash-loop guard — operator intent beats automation")
    func explicitPagedIgnoresCrashLoopGuard() async throws {
        try await withGuardFile(
            KVBackendGuard(
                trippedAt: 1, providerVersion: ProviderCore.version, crashCount: 3)
        ) { env in
            let build = try makeBuild(
                model: try tinyGPTOSS(), kvBackend: .paged, environment: env)
            #expect(build.kvBackendKind == .paged)
            #expect(build.kvBackendFallbackReason == nil)
            await build.engine.shutdown()
        }
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
        // The solo-prefill stripe (default-on) is a chunk the engine can
        // actually schedule, so the lockstep covers max(chunk, stripe).
        #expect(
            paged.pool.config.maxPrefillChunk
                == max(
                    prepared.schedulerConfig.prefillChunkSize,
                    prepared.schedulerConfig.soloPrefillStripeTokens ?? 0))
        #expect(prepared.schedulerConfig.soloPrefillStripeTokens
            == EngineV2Factory.defaultSoloPrefillStripeTokens)
        #expect(prepared.schedulerConfig.maxConcurrentRequests == 2)
        // Prefix caching is the ONLY field assembly may still decide, and
        // it is off until a cache instance is supplied.
        #expect(!prepared.schedulerConfig.enablePrefixCache)
    }

    @Test("resident cache policy is prompt-bound and follows the master gate")
    func residentPrefixCachePolicy() throws {
        let config = try #require(PrefixCachePolicy.residentConfig(
            modelId: "tiny-gemma",
            promptContractID: " prompt-contract ",
            environment: [PrefixCachePolicy.memoryEnvironmentFlag: "1"]))
        #expect(config.blockSize == PrefixCachePolicy.residentBlockSize)
        #expect(config.promptContractID == "prompt-contract")
        #expect(config.scopeID == "tiny-gemma")
        #expect(PrefixCachePolicy.residentConfig(
            modelId: "tiny-gemma",
            promptContractID: nil,
            environment: [:]) == nil)
        #expect(PrefixCachePolicy.residentConfig(
            modelId: "tiny-gemma",
            promptContractID: "contract",
            environment: [PrefixCachePolicy.environmentFlag: "0"]) == nil)
    }

    @Test("resolved paged backend installs resident L1; contiguous ignores it")
    func residentPrefixCacheFollowsResolvedBackend() throws {
        let model = try tinyGemma4Text()
        let config = try #require(PrefixCachePolicy.residentConfig(
            modelId: "tiny-gemma",
            promptContractID: "prompt-contract",
            environment: [PrefixCachePolicy.memoryEnvironmentFlag: "1"]))
        let paged = try EngineV2Factory.prepareProductionBackend(
            model: model,
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: gateEnvironment(),
            residentPrefixCache: config)
        #expect(paged.kind == .paged)
        #expect(paged.residentPrefixCacheEnabled)
        let (backend, _) = try paged.consume(model: model, maxConcurrentRequests: 2)
        let pagedBackend = try #require(backend as? PagedKVBackend)
        #expect(
            pagedBackend.pool.config.prefixSharingBlockSize
                == PrefixCachePolicy.residentBlockSize)

        let contiguous = try EngineV2Factory.prepareProductionBackend(
            model: model,
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .contiguous,
            maxContextLength: 2048,
            environment: gateEnvironment(),
            residentPrefixCache: config)
        #expect(contiguous.kind == .contiguous)
        #expect(!contiguous.residentPrefixCacheEnabled)
    }

    @Test("slot factory binds complete historical SSD state to the resolved paged backend")
    func slotFactoryOrdersResolvedBackendBeforeCache() async throws {
        let outcome = try await slotCacheOutcome(kvBackendConfig: "paged")
        #expect(outcome.kind == .paged)
        #expect(outcome.cache)
        #expect(outcome.completeLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(outcome.usesEphemeralKey)
        #expect(!outcome.legacyConstructionAttempted)
        #expect(outcome.status.backend == .paged)
        #expect(outcome.status.replayStrategy == .direct)
        #expect(outcome.status.state == .ready)
        #expect(outcome.status.reason == .ready)
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

    // MARK: - Complete prefix-cache backend gate

    /// Exercise the real Gemma complete-store factory with an isolated root,
    /// in-memory KEK and existing runtime-identity seam. Successful construction
    /// must expose the historical layout; gated outcomes retain their precise
    /// reason, distinguishing layout refusal from a failed store initializer.
    /// The attention-only factory remains a tripwire for an incorrect fallback.
    private func slotCacheOutcome(
        kvBackendConfig: String,
        modelID: String = "tiny-gemma",
        environment: [String: String] = [PrefixCachePolicy.environmentFlag: "1"]
    ) async throws -> (
        kind: EngineV2KVBackendKind,
        legacyConstructionAttempted: Bool,
        completeLayout: String?,
        usesEphemeralKey: Bool,
        cache: Bool,
        status: PrefixCacheModelStatus
    ) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("slot-cache-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let attempted = GateFlag()
        let model: any LanguageModel = try modelID == "gpt-oss-20b"
            ? tinyGPTOSS() : tinyGemma4Text()
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
            modelId: modelID,
            modelType: modelID == "gpt-oss-20b" ? "gpt_oss" : "gemma4_text",
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
            kvBackendConfig: kvBackendConfig,
            weightHash: String(repeating: "d", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(
                promptContractID: "tiny-gemma-contract",
                completeCheckpointIdentity: .init(
                    modelAggregateHash: String(repeating: "d", count: 64),
                    promptContractID: "tiny-gemma-contract",
                    buildID: "gate-runtime-identity", numericsFingerprint: "gate-float32-paged-history"),
                makePrefixCache: { _, _ in
                    attempted.set()
                    return nil
                }),
            environment: gateEnvironment(environment.merging([
                "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
            ]) { _, isolated in isolated }))
        let kind = await bundle.bridge.kvBackendKind
        let outcome = (
            kind: kind,
            legacyConstructionAttempted: attempted.value,
            completeLayout: bundle.bridge.ssdHybridCheckpointStore?.config.backendLayout,
            usesEphemeralKey: bundle.bridge.ssdHybridCheckpointStore?.usesEphemeralKey == true,
            cache: bundle.bridge.ssdHybridCheckpointStore != nil || bundle.bridge.ssdPrefixCache != nil,
            status: bundle.bridge.prefixCacheModelStatus()
        )
        await bundle.bridge.shutdown()
        return outcome
    }

    @Test("a resolved-CONTIGUOUS slot gets NO prefix cache — adoption is not exact there")
    func contiguousSlotGetsNoPrefixCache() async throws {
        let outcome = try await slotCacheOutcome(kvBackendConfig: "contiguous")
        #expect(outcome.kind == .contiguous)
        #expect(!outcome.legacyConstructionAttempted)
        #expect(!outcome.cache, "a contiguous slot must not hold an SSD prefix cache")
        #expect(outcome.status.backend == .contiguous)
        #expect(outcome.status.state == .disabled)
        #expect(outcome.status.reason == .unsupportedLayout)
        #expect(outcome.status.replayStrategy == .unknown)
        #expect(outcome.completeLayout == nil)
    }

    @Test("a resolved-PAGED slot KEEPS the prefix cache — the gate is not a global disable")
    func pagedSlotKeepsPrefixCache() async throws {
        let outcome = try await slotCacheOutcome(kvBackendConfig: "paged")
        #expect(outcome.kind == .paged)
        #expect(!outcome.legacyConstructionAttempted)
        #expect(outcome.completeLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(outcome.status.replayStrategy == .direct)
        #expect(outcome.cache)
        #expect(outcome.status.backend == .paged)
        #expect(outcome.status.state == .ready)
        #expect(outcome.status.reason == .ready)
    }

    @Test("the gate follows the RESOLVED backend: paged degraded by the kill switch gets no cache")
    func killSwitchDegradedSlotGetsNoPrefixCache() async throws {
        // The control the v0.8.0 gate found by accident and the reason this
        // must key on the resolved kind: an arm that REQUESTED paged,
        // resolved contiguous under the kill switch, and diverged with the
        // contiguous rows. Requested does not predict; resolved does.
        let outcome = try await slotCacheOutcome(
            kvBackendConfig: "paged",
            environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0",
                          PrefixCachePolicy.environmentFlag: "1"])
        #expect(outcome.kind == .contiguous)
        #expect(
            !outcome.legacyConstructionAttempted,
            "a slot serving contiguous gets no cache however it got there")
        #expect(!outcome.cache)
        #expect(outcome.status.reason == .unsupportedLayout)
    }

    @Test("unlisted tiny Gemma `.auto` stays contiguous even with explicit cache opt-in")
    func autoSlotGetsNoPrefixCache() async throws {
        // Only exact release IDs change automatic backend selection.
        let outcome = try await slotCacheOutcome(kvBackendConfig: "")
        #expect(outcome.kind == .contiguous)
        #expect(!outcome.legacyConstructionAttempted)
        #expect(!outcome.cache)
        #expect(outcome.status.reason == .unsupportedLayout)
    }

    @Test(arguments: ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
    func releasePagedModelsDefaultToNoSSD(modelID: String) async throws {
        let outcome = try await slotCacheOutcome(
            kvBackendConfig: "auto", modelID: modelID, environment: [:])
        #expect(outcome.kind == .paged)
        #expect(!outcome.legacyConstructionAttempted)
        #expect(!outcome.cache)
        #expect(outcome.completeLayout == nil)
        #expect(outcome.status.backend == .paged)
        #expect(outcome.status.state == .disabled)
        #expect(outcome.status.reason == .configDisabled)
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
    /// `preparedModel` is supplied so real VLM wrapper resolution is skipped:
    /// the subject here is the ROUTING for `isVLM: true`, not selection of the
    /// wrapper's directly owned text tower.
    @Test("slot factory routes eligible VLM slots without rewriting auto",
          arguments: candidateQwenIDs + ["tiny-gemma-vlm"])
    func slotFactoryRoutesVLMToPagedWhenTheCacheVouches(modelID: String) async throws {
        #expect(
            PagedLayerCache.honorsSpanMaskContextsByConstruction,
            "premise: the paged cache affirms span masks — if this ever goes false the expectation below must flip to .contiguous with a \"vlm\" veto")
        let bundle = try await vlmGateBundle(
            modelID: modelID, kvBackendConfig: modelID == "tiny-gemma-vlm" ? "paged" : "auto")
        #expect(await bundle.bridge.kvBackendKind == .paged)
        #expect(await bundle.bridge.kvBackendFallbackReason == nil)
        await bundle.bridge.shutdown()
    }

    @Test(arguments: [false, true])
    func candidateSlotFallbackTelemetry(invalidDType: Bool) async throws {
        let bundle = try await vlmGateBundle(
            modelID: candidateQwenIDs[0], kvBackendConfig: "auto",
            environment: invalidDType ? [EngineV2Factory.pagedPoolDTypeEnvKey: "invalid"] : [:],
            pagedPreflightOverride: { _ in throw GateProcessorError() })
        #expect(await bundle.bridge.kvBackendKind == .contiguous)
        let reason = await bundle.bridge.kvBackendFallbackReason
        #expect(reason?.hasPrefix(invalidDType ? "invalid_dtype:" : "kernel_preflight:") == true)
        #expect(await bundle.bridge.clampedKVBackendFallbackReason == reason)
        await bundle.bridge.shutdown()
    }

    @Test(arguments: ["auto", "paged", "contiguous"])
    func candidateSlotPerModelOverride(selection: String) async throws {
        let bundle = try await vlmGateBundle(
            modelID: candidateQwenIDs[0],
            kvBackendConfig: selection == "contiguous" ? "paged" : "contiguous",
            kvBackendConfigByModel: [candidateQwenIDs[0]: selection])
        #expect(await bundle.bridge.kvBackendKind == (selection == "contiguous" ? .contiguous : .paged))
        #expect(await bundle.bridge.kvBackendFallbackReason == nil)
        await bundle.bridge.shutdown()
    }

    private func vlmGateBundle(
        modelID: String,
        kvBackendConfig: String,
        kvBackendConfigByModel: [String: String] = [:],
        environment: [String: String] = [:],
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
    ) async throws -> ProviderEngineBundle {
        let isQwen = candidateQwenIDs.contains(modelID)
        let model: any LanguageModel = try isQwen ? tinyQwen() : tinyGemma4Text()
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: modelID),
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

        return try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID,
            modelType: isQwen ? "qwen3_5_moe" : "gemma4",
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
            kvBackendConfig: kvBackendConfig,
            kvBackendConfigByModel: kvBackendConfigByModel,
            weightHash: String(repeating: "c", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(pagedPreflight: pagedPreflightOverride),
            environment: gateEnvironment(environment.merging(
                [PrefixCachePolicy.environmentFlag: "0"]) { _, disabled in disabled }))
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
