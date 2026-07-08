// Copyright © 2026 Eigen Labs.
//
// Production CBv2 engine construction over an ALREADY-LOADED model.
//
// `EngineV2Factory.makeBridge` takes the engine as a closure so the
// refusal/telemetry logic stays engine-agnostic and unit-testable with a
// scripted stub. This file supplies the closure's production body: assemble
// the real `MLXLMCommon.EngineV2` from the model the provider just loaded
// (no re-download, no second weight copy — the engine retains the same
// module instance the legacy `BatchedEngine` serves) plus the v2 runtime
// pieces:
//
//   * layer kinds + per-layer attending caches from the model's own
//     `cbv2LayerKinds` / `newCacheV2` (Gemma 4 text, GPT-OSS — the two
//     families the engine is correct-by-construction for; GPT-OSS's
//     `newCacheV2` also primes its sinks-activation probe at build time),
//   * `CBv2ContiguousKVBackend` sized from the unified-memory KV budget
//     (admission ceiling only — nothing is preallocated),
//   * `CBv2LayerCacheBank` over the model-built caches,
//   * `CBv2DefaultSampler` + `CBv2TextDetokenizerFactory` (real incremental
//     detokenization with stop-string holdback).
//
// Any throw here lands in `makeBridge`'s catch (v0.7.5 fail-loud): ERROR
// `engine_health` telemetry (`operation=engine_v2_refusal`) + rethrow —
// the load fails with a 503 and the coordinator reroutes. There is no
// legacy engine to fall back to.

import Foundation
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
    ///   - prefixCache: RAM-only v2 prefix cache (`PrefixCachePolicy
    ///     .makePrefixCache` — gate + budget + carve are the caller's job).
    ///     Non-nil ⇒ the engine runs with `enablePrefixCache: true`
    ///     (lookup/adopt on submit, donate on finish, per-request
    ///     `cacheSalt` tenant scoping live). nil ⇒ no cache, byte-identical
    ///     to the pre-v0.7.5 engine. Threat model: T-041 (RAM-only on v2 —
    ///     no on-disk artifact; the in-process cross-tenant TTFT oracle is
    ///     the SEC-035 accepted risk).
    ///   - maxConcurrentRequests: concurrent-decode row cap.
    /// PUBLIC: the perf-gate benchmark harness (`ProviderBenchmark`'s
    /// `ThroughputSweep`/`SchedulerPrefillBenchmark`) builds its engines
    /// through this exact production entry point so the numbers it reports
    /// are the engine the fleet serves with — never a parallel construction
    /// that could drift.
    public static func makeProductionEngine(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        kvBytesCapacity: Int,
        prefixCache: PrefixCacheV2? = nil,
        maxConcurrentRequests: Int = EngineV2Factory.productionMaxConcurrentRequests
    ) throws -> any CBv2Engine {
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
        // the default nil softcap.
        let layerKinds: [CBv2LayerKind]
        let caches: [any CBv2AttendingLayerCache]
        switch model {
        case let gemma as Gemma4TextModel:
            layerKinds = gemma.cbv2LayerKinds
            caches = gemma.newCacheV2 { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            }
        case let gptoss as GPTOSSModel:
            layerKinds = gptoss.cbv2LayerKinds
            // GPT-OSS primes its sinks-activation probe inside newCacheV2
            // (one host readback per layer, HERE at build time — never on
            // the step path).
            caches = gptoss.newCacheV2 { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            }
        default:
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }

        let backend = CBv2ContiguousKVBackend(
            config: CBv2ContiguousBackendConfig(bytesCapacity: cappedCapacity))
        return EngineV2(
            model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: layerKinds,
            backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: caches),
            sampler: CBv2DefaultSampler(),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: CBv2SchedulerConfig(
                maxConcurrentRequests: max(1, maxConcurrentRequests),
                enablePrefixCache: prefixCache != nil),
            // TB-007 / T-041 (updated for v0.7.5): the v2 prefix cache is
            // RAM-only `PrefixCacheV2` with per-request `cacheSalt` tenant
            // scoping — reviewed under the existing SEC-035 accepted risk
            // (in-process TTFT oracle; strictly safer than the legacy
            // on-disk tier). Gate/budget/carve: `PrefixCachePolicy`.
            prefixCache: prefixCache
        )
    }
}
