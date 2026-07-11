// Copyright © 2026 Eigen Labs.
//
// Production CBv2 engine construction over an ALREADY-LOADED model.
//
// `EngineV2Factory.makeBridge` takes the engine as a closure so the
// refusal/telemetry logic stays engine-agnostic and unit-testable with a
// scripted stub. This file supplies the closure's production body: assemble
// the real `MLXLMCommon.EngineV2` from the model the provider just loaded
// (no re-download, no second weight copy — the engine retains the same
// module instance retained by the loaded model container) plus the runtime
// pieces:
//
//   * layer kinds + per-layer attending caches from the model's own
//     `cbv2LayerKinds` / `newCacheV2` (Gemma 4 text, GPT-OSS — the two
//     families the engine is correct-by-construction for; GPT-OSS's
//     `newCacheV2` also primes its sinks-activation probe at build time),
//   * a KV backend sized from the unified-memory KV budget —
//     `CBv2ContiguousKVBackend` for production "auto" (admission ceiling
//     only — nothing is preallocated), or the explicitly experimental
//     `PagedKVBackend`, whose physical slabs are independently capped by
//     `PagedKVPhysicalCapacityPolicy` before eager materialization,
//   * `CBv2LayerCacheBank` over the model-built caches,
//   * `CBv2DefaultSampler` + `CBv2TextDetokenizerFactory` (real incremental
//     detokenization with stop-string holdback).
//
// Any throw here lands in `makeBridge`'s catch (v0.7.5 fail-loud): ERROR
// `engine_health` telemetry (`operation=engine_v2_refusal`) + rethrow —
// the load fails with a 503 and the coordinator reroutes. There is no
// legacy engine to fall back to.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Failure modes of production v2-engine construction. Each maps to the
/// factory's REFUSAL path (ERROR `engine_v2_refusal` telemetry + throw).
enum EngineV2ProductionError: Error, CustomStringConvertible {
    /// The loaded module is not a CBv2-adapted family (an unexpected
    /// architecture). Allowlisted Gemma 4 VLM wrappers do NOT land here —
    /// the slot factory extracts their CBv2-adapted text model first
    /// (`EngineV2VLMTextExtraction`) and hands THAT to this factory.
    case unsupportedModel(String)
    /// No KV byte budget is left under the unified-memory cap — an engine
    /// admitted with a zero ceiling would reject every request, so the
    /// load is refused (503; the coordinator reroutes).
    case noKVHeadroom

    var description: String {
        switch self {
        case .unsupportedModel(let type):
            return "engine_v2: model type \(type) has no CBv2 adapter"
        case .noKVHeadroom:
            return "engine_v2: no KV byte headroom under the unified-memory cap"
        }
    }
}

extension EngineV2Factory {

    /// Clamp a KV admission ceiling to physical unified memory. A ceiling
    /// above physical RAM can only come from a mis-derivation upstream; the
    /// engine would then admit requests that can never fit. Pure/static so it
    /// is unit-testable without building an engine. `physicalBytes` defaults
    /// to the machine's real memory; `Int.max`-safe.
    static func clampKVBytesCapacity(
        _ kvBytesCapacity: Int,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let physicalCap = Int(min(physicalBytes, UInt64(Int.max)))
        return min(max(0, kvBytesCapacity), physicalCap)
    }

    /// Scheduler knobs for the production v2 engine. `maxConcurrentRequests`
    /// follows the CBv2 product target (4, max 8) rather than the legacy
    /// scheduler's 24-way ceiling — the v2 rollout is deliberately
    /// conservative and the coordinator sees the true value in heartbeats.
    public static let productionMaxConcurrentRequests = 4

    /// The model's prefix-cache adoption bound (`PrefixCachePolicy
    /// .adoptionBoundTokens` over the model's own `cbv2LayerKinds`), kept
    /// NEXT TO the authoritative family switch in `makeProductionEngine` so
    /// the two can never drift. Unknown families return 0 — treated as
    /// "fund" by the gate (pure-full-attention semantics; such a model
    /// throws `unsupportedModel` before any cache matters anyway).
    static func adoptionBoundTokens(model: any LanguageModel) -> Int {
        switch model {
        case let gemma as Gemma4TextModel:
            return PrefixCachePolicy.adoptionBoundTokens(layerKinds: gemma.cbv2LayerKinds)
        case let gptoss as GPTOSSModel:
            return PrefixCachePolicy.adoptionBoundTokens(layerKinds: gptoss.cbv2LayerKinds)
        default:
            return 0
        }
    }

    /// The model's CBv2 layer kinds, or nil for a non-adapted family
    /// (which throws `unsupportedModel` at engine construction anyway).
    /// Needed by the SSD prefix cache's construction (layout-epoch
    /// binding + adoption bound) — kept NEXT TO the authoritative family
    /// switch, like `adoptionBoundTokens`, so the two can never drift.
    static func cbv2LayerKinds(model: any LanguageModel) -> [CBv2LayerKind]? {
        switch model {
        case let gemma as Gemma4TextModel:
            return gemma.cbv2LayerKinds
        case let gptoss as GPTOSSModel:
            return gptoss.cbv2LayerKinds
        default:
            return nil
        }
    }

    /// Build the real `EngineV2` over a loaded model.
    ///
    /// - Parameters:
    ///   - model: the loaded language module (the SAME instance the legacy
    ///     engine serves — weights are shared, never duplicated).
    ///   - tokenizer: the model's tokenizer, for incremental detokenization.
    ///   - kvBytesCapacity: admission ceiling for sequence KV, in bytes
    ///     (derive from `UnifiedMemoryCap.kvBudgetBytes`). When a prefix
    ///     cache is supplied, the caller has ALREADY carved that cache's
    ///     byte budget out of this figure (`PrefixCachePolicy.carve`) so
    ///     cached KV + live-request KV can never jointly exceed the slot's
    ///     grant under the unified-memory cap.
    ///   - prefixCache: v2 prefix cache — either the RAM `PrefixCacheV2`
    ///     (`PrefixCachePolicy.makePrefixCache`, opt-in-experimental) or
    ///     the provider's `SSDPrefixCache` (the v0.7.5 encrypted SSD
    ///     offload tier, default for supported models with per-donation
    ///     benefit gating and zero memory carve).
    ///     Widened to the existential (`any CBv2PrefixCache`) so
    ///     provider-side conformers plug in with ZERO mlx-swift-lm
    ///     changes (the engine already stores the cache existentially).
    ///     Gate + budget + carve + tier selection are the caller's job.
    ///     Non-nil ⇒ the engine runs with `enablePrefixCache: true`
    ///     (lookup/adopt on submit, donate on finish, per-request
    ///     `cacheSalt` tenant scoping live). nil means cache unavailable or
    ///     disabled. Threat model: T-041 (SSD tier: at-rest
    ///     artifacts with HMAC-keyed names — leak #2 closed; the in-process
    ///     cross-tenant TTFT oracle stays the SEC-035 accepted risk).
    ///   - maxConcurrentRequests: concurrent-decode row cap.
    /// PUBLIC: the perf-gate benchmark harness (`ProviderBenchmark`'s
    /// `ThroughputSweep`/`SchedulerPrefillBenchmark`) builds its engines
    /// through this exact production entry point so the numbers it reports
    /// are the engine the fleet serves with — never a parallel construction
    /// that could drift. Thin wrapper over `makeProductionBuild` (same
    /// defaults, backend-kind metadata discarded).
    public static func makeProductionEngine(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        kvBytesCapacity: Int,
        prefixCache: (any CBv2PrefixCache)? = nil,
        maxConcurrentRequests: Int = EngineV2Factory.productionMaxConcurrentRequests,
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any CBv2Engine {
        try makeProductionBuild(
            model: model,
            tokenizer: tokenizer,
            kvBytesCapacity: kvBytesCapacity,
            prefixCache: prefixCache,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBackend: kvBackend,
            maxContextLength: maxContextLength,
            environment: environment
        ).engine
    }

    /// Result of production v2-engine construction: the engine plus the KV
    /// backend it was ACTUALLY built with. The bridge keys its shared-gate
    /// accounting, heartbeat clamp, and re-slice policy off the kind; the
    /// fallback reason feeds the INFO `engine_v2_kv_backend` telemetry so
    /// the fleet reports which backend every slot serves with.
    public struct ProductionBuild {
        public let engine: any CBv2Engine
        public let kvBackendKind: EngineV2KVBackendKind
        /// Non-nil when a paged selection fell back to contiguous (fleet
        /// kill switch, kernel ineligibility, pool-construction capacity).
        /// A fallback is a supported degradation — INFO, never a refusal.
        public let kvBackendFallbackReason: String?
    }

    /// Build the real `EngineV2` over a loaded model, returning the engine
    /// together with the KV-backend decision (`ProductionBuild`).
    ///
    /// KV-backend gate (see `EngineV2KVBackendPolicy` for the full layer
    /// order): the caller passes the operator selection with slot vetoes
    /// (VLM, kv-quant) already applied; `.auto` is always contiguous.
    /// Paged remains an explicit experimental selection.
    /// The `DARKBLOOM_CBV2_PAGED_KV=0` fleet kill switch is enforced at
    /// THIS deepest layer so no call path (benchmarks included) bypasses
    /// it. Paged construction throwing `CBv2KVError` (kernel ineligibility,
    /// pool capacity) falls back to contiguous — a paged-ineligible model
    /// must load and serve, never refuse.
    public static func makeProductionBuild(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        kvBytesCapacity: Int,
        prefixCache: (any CBv2PrefixCache)? = nil,
        maxConcurrentRequests: Int = EngineV2Factory.productionMaxConcurrentRequests,
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
    ) throws -> ProductionBuild {
        guard kvBytesCapacity > 0 else {
            throw EngineV2ProductionError.noKVHeadroom
        }
        // Upper-bound sanity: a KV admission ceiling larger than physical
        // unified memory is nonsensical (only reachable via a bad upstream
        // computation) and would make the engine admit far past what can ever
        // fit. Clamp to physical RAM as a cheap guard so a mis-derived budget
        // degrades to "all of memory" instead of an absurd ceiling. Real
        // budgets (cap − weights − activations) are always well under this.
        let cappedCapacity = clampKVBytesCapacity(kvBytesCapacity)

        // Model adaptation: layer kinds + per-layer caches come from the
        // model's own CBv2 hooks so the derivation can never drift from the
        // constructors (see LayerKindDerivation.swift in mlx-swift-lm).
        // Neither family uses attention softcapping (Gemma 4's final-logit
        // softcap lives inside the model's logits path), so the caches take
        // the default nil softcap. `newCacheV2` stays the single cache
        // construction funnel on BOTH backends — GPT-OSS primes its
        // sinks-activation probe inside it (one host readback per layer,
        // at build time — never on the step path).
        let layerKinds: [CBv2LayerKind]
        let newCaches:
            ((Int, CBv2LayerKind) -> any CBv2AttendingLayerCache)
                -> [any CBv2AttendingLayerCache]
        switch model {
        case let gemma as Gemma4TextModel:
            layerKinds = gemma.cbv2LayerKinds
            newCaches = { make in gemma.newCacheV2(makeLayerCache: make) }
        case let gptoss as GPTOSSModel:
            layerKinds = gptoss.cbv2LayerKinds
            newCaches = { make in gptoss.newCacheV2(makeLayerCache: make) }
        default:
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }

        var resolvedKind: EngineV2KVBackendKind
        switch kvBackend {
        case .contiguous: resolvedKind = .contiguous
        case .paged: resolvedKind = .paged
        case .auto: resolvedKind = .contiguous
        }
        var fallbackReason: String?
        if resolvedKind == .paged,
            EngineV2KVBackendPolicy.killSwitchDisabled(environment: environment)
        {
            resolvedKind = .contiguous
            fallbackReason = "kill_switch"
        }

        let schedulerConfig = CBv2SchedulerConfig(
            maxConcurrentRequests: max(1, maxConcurrentRequests),
            enablePrefixCache: prefixCache != nil)

        func contiguousAssembly() -> (CBv2KVBackend, [any CBv2AttendingLayerCache]) {
            let backend = CBv2ContiguousKVBackend(
                config: CBv2ContiguousBackendConfig(bytesCapacity: cappedCapacity))
            let caches = newCaches { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            }
            return (backend, caches)
        }

        if resolvedKind == .paged {
            do {
                if let pagedPreflightOverride {
                    try pagedPreflightOverride(layerKinds)
                } else {
                    try PagedKernelPreflight.run(layerKinds: layerKinds)
                }
            } catch {
                resolvedKind = .contiguous
                fallbackReason = "kernel_preflight: \(error)"
            }
        }

        if resolvedKind == .paged {
            let maxBufferLength = MLX.GPU.deviceInfo().maxBufferSize
            let rate = PagedKVPhysicalCapacityPolicy.fp16BytesPerToken(
                layerKinds: layerKinds) ?? 0
            let decision = PagedKVPhysicalCapacityPolicy.decide(
                logicalGrantBytes: cappedCapacity,
                fp16BytesPerToken: rate,
                maxContextLength: maxContextLength,
                maxConcurrentRequests: schedulerConfig.maxConcurrentRequests,
                inputs: .init(
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    liveKVHeadroomBytes: KVHeadroomProbe.measuredLiveKVHeadroomBytes,
                    maxBufferLength: maxBufferLength))
            switch decision {
            case .contiguous(let reason):
                fallbackReason = reason
            case .paged(let plan):
                do {
                    let paged = try PagedKVBackend(
                        layerKinds: layerKinds,
                        config: PagedKVPoolConfig(
                            capacityBytes: plan.capacityBytes,
                            // LOCKSTEP: a windowed-layer update larger than the
                            // ring's provision traps the process
                            // (PagedSequenceKV precondition) — size the pool to
                            // the scheduler's REAL chunk, never a parallel
                            // constant.
                            maxPrefillChunk: schedulerConfig.prefillChunkSize,
                            nominalMaxSequenceLength: max(
                                1, maxContextLength ?? 8192),
                            maxBufferLength: maxBufferLength))
                    let pagedCaches = paged.makeLayerCaches()
                    let caches = newCaches { index, _ in pagedCaches[index] }
                    // Commit only the independently-capped PHYSICAL pool.
                    // Resource and size eligibility has already thrown
                    // catchably; first traffic cannot discover either.
                    paged.pool.materializeSlabs()
                    return ProductionBuild(
                        engine: makeEngineV2(
                            model: model, tokenizer: tokenizer, layerKinds: layerKinds,
                            backend: paged, caches: caches,
                            schedulerConfig: schedulerConfig, prefixCache: prefixCache),
                        kvBackendKind: .paged,
                        kvBackendFallbackReason: nil)
                } catch let error as CBv2KVError {
                    // Paged ineligibility/capacity is a supported degradation:
                    // fall back to the contiguous backend (INFO telemetry at the
                    // bridge — never the engine_v2_refusal path).
                    switch error {
                    case .backendIneligible(let reason):
                        fallbackReason = "ineligible: \(reason)"
                    case .capacityExhausted(let needed, let available):
                        fallbackReason =
                            "pool_construction_capacity: needed \(needed), available \(available)"
                    }
                }
            }
        }
        let (backend, caches) = contiguousAssembly()
        return ProductionBuild(
            engine: makeEngineV2(
                model: model, tokenizer: tokenizer, layerKinds: layerKinds,
                backend: backend, caches: caches,
                schedulerConfig: schedulerConfig, prefixCache: prefixCache),
            kvBackendKind: .contiguous,
            kvBackendFallbackReason: fallbackReason)
    }

    /// Shared final assembly for both backends.
    private static func makeEngineV2(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        layerKinds: [CBv2LayerKind],
        backend: CBv2KVBackend,
        caches: [any CBv2AttendingLayerCache],
        schedulerConfig: CBv2SchedulerConfig,
        prefixCache: (any CBv2PrefixCache)?
    ) -> any CBv2Engine {
        let steppableModel = CBv2SteppableLanguageModelAdapter(model)
        let admissionConfig = AdmissionV2.Config()
        let compiledDecodeConfig = CBv2CompiledDecodeConfig()

        // Mirror the exact external reserve EngineV2 derives for compiled
        // decode so a prepared lease and the eventual submit use the same
        // admission ceiling on both contiguous and paged backends.
        let compiledAdmissionReserve =
            CBv2CompiledDecode.build(
                model: steppableModel,
                layerKinds: layerKinds,
                config: compiledDecodeConfig,
                maxConcurrentRequests: schedulerConfig.maxConcurrentRequests,
                kvBytesCapacity: backend.bytesCapacity
            )?.admissionPaddingReserve ?? 0
        let preparedAdmission = EngineV2PreparedAdmission(
            layerKinds: layerKinds,
            config: admissionConfig,
            externalReserveBytes: compiledAdmissionReserve)

        let engine = EngineV2(
            model: steppableModel,
            layerKinds: layerKinds,
            backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: caches),
            sampler: CBv2DefaultSampler(),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: schedulerConfig,
            admissionConfig: admissionConfig,
            // TB-007 / T-041 (v0.7.5): this CBv2 cache is either the
            // default-on encrypted SSD tier or the opt-in RAM PrefixCacheV2
            // tier. Both use per-request cacheSalt scoping; selection and
            // budgets live in PrefixCachePolicy.
            prefixCache: prefixCache,
            compiledDecodeConfig: compiledDecodeConfig)
        return PreparedAdmissionCBv2Engine(
            engine: engine,
            preparedAdmission: preparedAdmission)
    }
}
