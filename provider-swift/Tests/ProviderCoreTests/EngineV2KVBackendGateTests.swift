// Copyright © 2026 Eigen Labs.
//
// KV-backend GATE tests over the REAL `EngineV2Factory.makeProductionBuild`
// with tiny real-family models (JSON-decoded configs, random-init weights,
// no downloads): production-safe `auto` (CONTIGUOUS as of v0.8.1), the
// fleet kill switch at the deepest layer, explicit selections, and the
// degrade-or-REFUSE split — an explicit paged request that cannot be
// served throws `EngineV2ProductionError.pagedUnavailable` with the reason
// attached, while the kill switch still degrades because an operator
// override is not a failure.
//
// v0.8.1 NOTE. `.auto` resolving contiguous means `.auto` no longer enters
// the paged branch AT ALL, so three mechanisms that were reachable in
// v0.8.0 are now DORMANT: the crash-loop guard (scoped to `.auto` and
// checked only when paged already resolved), the `.auto` half of the
// dtype degrade, and the degrade half of `degradeOrRefuse`. They are
// retained, not deleted — they are the safety properties a future re-flip
// depends on. What pins them now is:
//
//   * the predicates themselves (`degradesPagedFailure`,
//     `crashLoopGuardForcesContiguous`), unit-tested without an engine;
//   * the guard's store and activation semantics, in
//     `WatchdogCrashLoopGuardTests` ("KV-backend guard store" and
//     "Crash-loop guard activation predicate");
//   * the three explicit-paged REFUSAL tests below, which drive the same
//     three failure stages the `.auto` degrade tests used to drive.
//
// So this suite asserts the dormancy directly (`autoNeverEntersThePaged
// Ladder`) rather than keeping tests whose subject the flip removed.
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
    kvBackend: EngineV2KVBackendSelection,
    environment: [String: String] = [:],
    pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
) throws -> EngineV2Factory.ProductionBuild {
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    return try EngineV2Factory.makeProductionBuild(
        model: model,
        tokenizer: StubBridgeTokenizer(),
        kvBytesCapacity: gateTestCapacity,
        // Deliberately 2: these gates assert BACKEND SELECTION, and a small
        // pool keeps construction cheap. Production defaults to B=4 while
        // still supporting explicit overrides through B=8.
        maxConcurrentRequests: 2,
        prefixCache: nil,
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

    @Test("auto is CONTIGUOUS for GPT-OSS and cannot drift with family defaults")
    func autoServesContiguousForGPTOSS() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .auto)
        // `.auto` is CONTIGUOUS as of v0.8.1 — see the rationale at
        // EngineV2Factory+Production.swift's `.auto` case. This assertion
        // guards BOTH directions: it caught the first flip, it caught the
        // revert, it caught the re-flip, and it will catch a silent fourth
        // change.
        #expect(build.kvBackendKind == .contiguous)
        // NIL, not "the default": a fallback reason means something
        // OVERRODE the selection (kill switch, guard, a paged failure), and
        // the heartbeat/dashboard population split on exactly this field.
        // The default resolving to its default is not a fallback.
        #expect(build.kvBackendFallbackReason == nil)
        // Contiguous advertises its LOGICAL grant — the whole point of the
        // revert. It must not shrink to a paged-style physical pool.
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesBackendCapacity > 0)
        #expect(snapshot.kvBytesCapacity == gateTestCapacity)
        // No pool, so no page dtype to report.
        #expect(build.pagedPoolDType == nil)
        await build.engine.shutdown()
    }

    @Test("auto resolves CONTIGUOUS for Gemma-4")
    func autoServesContiguousForGemma() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), kvBackend: .auto)
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
            #expect(build.pagedPoolDType == "float16")
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

    @Test("non-explicit selections permit paged-failure degradation")
    func nonExplicitSelectionsPermitPagedFailureDegradation() async throws {
        // Layer 5's degrade half, pinned as a policy predicate. `.auto`
        // resolves contiguous as of v0.8.1 and therefore does not currently
        // enter a paged-failure branch. The predicate remains the fail-open
        // contract if a future release selects paged automatically; an
        // explicit `.paged` request must continue to refuse instead.
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .auto))
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .contiguous))
        #expect(!EngineV2KVBackendPolicy.degradesPagedFailure(selection: .paged))
    }

    // MARK: `.auto` never enters the paged branch (v0.8.1)
    //
    // Replaces the three `.auto`-degrade construction tests. Their subject
    // — an `.auto` slot that tries paged, fails, and degrades with a reason
    // — cannot occur now that `.auto` resolves contiguous outright. The
    // three failure STAGES they covered are still driven through the real
    // factory by the three explicit-paged refusal tests above; what is
    // asserted here instead is the stronger new property: `.auto` does not
    // merely survive those failures, it never reaches them.

    @Test("`.auto` never enters the paged ladder — no preflight, no reason, no dtype")
    func autoNeverEntersThePagedLadder() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let preflightRan = GateFlag()

        // Every input that used to force an `.auto` degrade, at once: a
        // preflight that throws, a sub-floor grant the physical-capacity
        // policy rejects, and an fp32 page dtype that makes pool
        // construction throw. None of them can be consulted, because the
        // `.auto` slot never asks for paged — so the build is a plain
        // contiguous one with NO fallback reason to report.
        struct PreflightFailure: Error {}
        let build = try EngineV2Factory.makeProductionBuild(
            model: try tinyGemma4Text(),
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: 1_024,
            maxConcurrentRequests: 2,
            kvBackend: .auto,
            maxContextLength: 2048,
            environment: gateEnvironment(
                [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"]),
            pagedPreflightOverride: { _ in
                preflightRan.set()
                throw PreflightFailure()
            })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType == nil)
        // The load-bearing one: paged's kernel preflight is real work on
        // the model-load path, and an `.auto` fleet must not pay it.
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

    @Test("the crash-loop guard is DORMANT under the v0.8.1 contiguous default")
    func crashLoopGuardIsDormantUnderContiguousDefault() async throws {
        // Replaces `autoHonorsCrashLoopGuard`, `staleGuardFailsOpen`,
        // `corruptGuardFailsOpen`, `manualClearRestoresPaged` and
        // `killSwitchReasonOutranksGuard`, all of which asserted a
        // guard/kill-switch EFFECT on `.auto` that is now unobservable: the
        // guard only fires when paged already resolved, and `.auto` no
        // longer resolves paged. The outcome those tests wanted —
        // contiguous — is now the unconditional default, so they could only
        // pass vacuously.
        //
        // What is still real, and still tested where it is real: the guard
        // record's store and activation semantics
        // (`WatchdogCrashLoopGuardTests`), and the guard NOT touching an
        // explicit paged selection (the next test). What this pins is that
        // an active guard changes nothing about an `.auto` build — in
        // particular that it does not start reporting a fallback reason for
        // an override that did not happen.
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
                model: try tinyGPTOSS(), kvBackend: .auto, environment: env)
            #expect(build.kvBackendKind == .contiguous)
            #expect(
                build.kvBackendFallbackReason == nil,
                "the default resolving to contiguous is not a guard degrade and must not be labelled one")
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

    @Test("unshippable chunk and budget env names cannot retune serving")
    func unsupportedSchedulerEnvironmentDoesNotRetuneServing() throws {
        let model = try tinyGemma4Text()
        let prepared = try EngineV2Factory.prepareProductionBackend( // pragma: allowlist secret
            model: model,
            kvBytesCapacity: gateTestCapacity,
            maxConcurrentRequests: 4,
            kvBackend: .contiguous,
            maxContextLength: 8192,
            environment: [
                "DARKBLOOM_CBV2_PREFILL_CHUNK": "1024",
                "DARKBLOOM_CBV2_MAX_BATCHED_TOKENS": "4096",
            ])
        #expect(prepared.schedulerConfig.prefillChunkSize == 512)
        #expect(prepared.schedulerConfig.maxBatchedTokensPerStep == 2048)
        #expect(prepared.schedulerConfig.soloPrefillStripeTokens == 2048)
        #expect(prepared.schedulerConfig.maxConcurrentRequests == 4)
    }

    @Test("slot factory hands the cache factory the RESOLVED backend's capability")
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
            environment: gateEnvironment())
        // The invariant, unchanged since it was written: a cache is never
        // built for a backend other than the one serving. What changed in
        // v0.8.1 is which side of it is observable here — the kill-switch
        // DEGRADE this test used to drive now produces no cache at all
        // (`killSwitchDegradedSlotGetsNoPrefixCache` owns that half), so
        // the surviving half is the positive one: a slot that really does
        // resolve paged hands the cache factory the PAGED capability.
        let cache = try #require(capture.cache)
        let backendKind = await bundle.bridge.kvBackendKind
        #expect(backendKind == .paged)
        #expect(bundle.bridge.ssdPrefixCache === cache)
        #expect(capture.capability?.backend == .pagedFP16)
        #expect(capture.capability?.isSupported == true)
        let status = bundle.bridge.prefixCacheModelStatus()
        #expect(status.backend == .paged)
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

    // MARK: prefix-cache backend gate (v0.8.1)
    //
    // The correctness half of the contiguous revert. On both production
    // checkpoints a contiguous slot that ADOPTS a cached prefix answers
    // differently from its own cold run, so a contiguous slot gets no cache
    // at all. Asserted through `makeProductionBundle` — the real path,
    // where the resolved backend and the cache decision meet — and on the
    // RESOLVED kind, not the requested one.

    /// Build a real slot and report whether the cache-construction path was
    /// ENTERED, alongside the backend it actually resolved.
    /// `kvBackendConfig` is the operator string, so these go through config
    /// parsing too.
    ///
    /// The construction closure is injected rather than letting
    /// `SSDPrefixCacheFactory` run, for two reasons: the real factory needs
    /// a keychain KEK and a writable cache root that a unit test has no
    /// business requiring, and — more importantly — "was the closure
    /// called?" is the exact question the gate decides. A test that only
    /// checked `ssdPrefixCache == nil` could not tell "gated" from "tried
    /// and failed", which is precisely the confusion an unhermetic
    /// environment would introduce.
    private func slotCacheOutcome(
        kvBackendConfig: String,
        environment: [String: String] = [:]
    ) async throws -> (
        kind: EngineV2KVBackendKind,
        constructionAttempted: Bool,
        cache: Bool,
        status: PrefixCacheModelStatus
    ) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("slot-cache-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attempted = GateFlag()
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
            kvBackendConfig: kvBackendConfig,
            weightHash: String(repeating: "d", count: 64),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            // A prompt contract is required for construction, so supplying
            // it removes the one OTHER reason a cache could be absent —
            // without it a green test would prove nothing.
            assemblyOverrides: .init(
                promptContractID: "tiny-gemma-contract",
                makePrefixCache: { layerKinds, capability in
                    attempted.set()
                    return SSDPrefixCache(
                        config: .init(
                            modelId: "tiny-gemma",
                            promptContractID: "tiny-gemma-contract",
                            weightHash: String(repeating: "d", count: 64),
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
                }),
            environment: gateEnvironment(environment))
        let kind = await bundle.bridge.kvBackendKind
        let outcome = (
            kind: kind,
            constructionAttempted: attempted.value,
            cache: bundle.bridge.ssdPrefixCache != nil,
            status: bundle.bridge.prefixCacheModelStatus()
        )
        await bundle.bridge.shutdown()
        return outcome
    }

    @Test("a resolved-CONTIGUOUS slot gets NO prefix cache — adoption is not exact there")
    func contiguousSlotGetsNoPrefixCache() async throws {
        let outcome = try await slotCacheOutcome(kvBackendConfig: "contiguous")
        #expect(outcome.kind == .contiguous)
        // Not "it failed to build" — never ATTEMPTED. Nil is then the
        // single switch that disarms the tier: no engine `CBv2PrefixCache`,
        // no pre-submit `stage`, no donation, no stats logger. There is no
        // `adopt` entry point to disable more narrowly — adoption IS a
        // non-nil `lookup`, across three overloads plus the bridge's
        // disk-rehydrating `stage`.
        #expect(
            !outcome.constructionAttempted,
            "a contiguous slot must not even attempt to construct the SSD prefix cache")
        #expect(!outcome.cache, "a contiguous slot must not hold an SSD prefix cache")
        #expect(outcome.status.backend == .contiguous)
        #expect(outcome.status.state == .disabled)
        #expect(outcome.status.reason == .unsupportedBackend)
        // `none`, not `unknown`: no replay happens here and we know it.
        #expect(outcome.status.replayStrategy == PrefixCacheReplayStrategy.none)
    }

    @Test("a resolved-PAGED slot KEEPS the prefix cache — the gate is not a global disable")
    func pagedSlotKeepsPrefixCache() async throws {
        let outcome = try await slotCacheOutcome(kvBackendConfig: "paged")
        #expect(outcome.kind == .paged)
        #expect(
            outcome.constructionAttempted,
            "paged adoption is exact; the tier must survive the v0.8.1 gate")
        #expect(outcome.cache)
        #expect(outcome.status.backend == .paged)
        #expect(outcome.status.state == .pending)
        #expect(outcome.status.reason == .scanPending)
    }

    @Test("the gate follows the RESOLVED backend: paged degraded by the kill switch gets no cache")
    func killSwitchDegradedSlotGetsNoPrefixCache() async throws {
        // The control the v0.8.0 gate found by accident and the reason this
        // must key on the resolved kind: an arm that REQUESTED paged,
        // resolved contiguous under the kill switch, and diverged with the
        // contiguous rows. Requested does not predict; resolved does.
        let outcome = try await slotCacheOutcome(
            kvBackendConfig: "paged",
            environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"])
        #expect(outcome.kind == .contiguous)
        #expect(
            !outcome.constructionAttempted,
            "a slot serving contiguous gets no cache however it got there")
        #expect(!outcome.cache)
        #expect(outcome.status.reason == .unsupportedBackend)
    }

    @Test("`.auto` slots get no prefix cache, because `.auto` is contiguous")
    func autoSlotGetsNoPrefixCache() async throws {
        // The fleet case, end to end: a stock install writes no
        // `engine_v2_kv_backend`, resolves contiguous, and therefore serves
        // with the cache off. This is the assertion that would fail if the
        // default flipped back without revisiting the cache gate.
        let outcome = try await slotCacheOutcome(kvBackendConfig: "")
        #expect(outcome.kind == .contiguous)
        #expect(!outcome.constructionAttempted)
        #expect(!outcome.cache)
        #expect(outcome.status.reason == .unsupportedBackend)
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
