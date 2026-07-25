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
//
// An EXPLICITLY requested paged backend that cannot be built takes that
// same route: `pagedUnavailable` rather than a quiet contiguous engine,
// so a paged benchmark or e2e run can never report paged and measure
// contiguous. `.auto` and the fleet kill switch still degrade.

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
    /// An EXPLICIT paged request could not be served: `engine_v2_kv_backend
    /// = "paged"`, a per-model override in `engine_v2_kv_backend_by_model`,
    /// or the benchmark's `--kv-backend paged`. Those are claims someone
    /// VERIFIES against — with no canary fleet, benchmarks and e2e are the
    /// only safety net, so degrading a named paged run to contiguous would
    /// report paged while measuring contiguous. `.auto` still degrades.
    /// Carries the underlying reason (kernel preflight, physical-capacity
    /// planning, or pool construction) verbatim.
    case pagedUnavailable(String)

    var description: String {
        switch self {
        case .unsupportedModel(let type):
            return "engine_v2: model type \(type) has no CBv2 adapter"
        case .noKVHeadroom:
            return "engine_v2: no KV byte headroom under the unified-memory cap"
        case .pagedUnavailable(let reason):
            return "engine_v2: paged KV backend explicitly requested but "
                + "unavailable — \(reason)"
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

    /// Process-wide per-request reservation rate for the contiguous backend.
    /// GPT-OSS owning full-attention rows are fp32 while the sizing snapshot is
    /// all-fp16; Gemma and paged rows stay at the nominal fp16 rate.
    static func nativeKVBytesPerToken(
        nominalFP16BytesPerToken: Int,
        fp16FullKVBytesPerToken: Int,
        fullRowsUseFP32: Bool
    ) -> Int {
        guard nominalFP16BytesPerToken > 0 else { return 0 }
        guard fullRowsUseFP32 else { return nominalFP16BytesPerToken }
        guard fp16FullKVBytesPerToken >= 0 else { return Int.max }
        let (nativeRate, overflow) = nominalFP16BytesPerToken.addingReportingOverflow(
            fp16FullKVBytesPerToken)
        return overflow ? Int.max : nativeRate
    }

    /// Build the real `EngineV2` over a loaded model.
    ///
    /// - Parameters:
    ///   - model: the loaded language module (the SAME instance the legacy
    ///     engine serves — weights are shared, never duplicated).
    ///   - tokenizer: the model's tokenizer, for incremental detokenization.
    ///   - kvBytesCapacity: admission ceiling for live sequence KV, in bytes
    ///     (derive from `UnifiedMemoryCap.kvBudgetBytes`).
    ///   - prefixCache: the provider's encrypted `SSDPrefixCache`, with
    ///     per-donation benefit gating and zero serving-memory carve.
    ///     Widened to the existential (`any CBv2PrefixCache`) so
    ///     provider-side conformers plug in with ZERO mlx-swift-lm
    ///     changes (the engine already stores the cache existentially).
    ///     The local kill switch and construction are the caller's job.
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
        mtpDrafter: (any CBv2MTPDrafter)? = nil,
        mtpConfig: CBv2MTPConfig = CBv2MTPConfig(),
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
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig,
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
        /// Non-nil when a paged selection DEGRADED to contiguous: the fleet
        /// kill switch always, and preflight/capacity/eligibility failures
        /// under `.auto`. A degrade is supported — INFO, never a refusal.
        /// An EXPLICIT `.paged` selection never degrades for a failure; it
        /// throws `EngineV2ProductionError.pagedUnavailable`.
        public let kvBackendFallbackReason: String?
    }

    /// Fully resolved backend resources, created before SSD cache construction
    /// so provider capability follows the backend that will actually serve.
    final class ProductionBackendPreparation {
        let layerKinds: [CBv2LayerKind]
        let kind: EngineV2KVBackendKind
        let fallbackReason: String?
        /// The ONE scheduler config of this build. Constructed in
        /// `prepareProductionBackend`, where it sizes the paged pool's
        /// `maxPrefillChunk`, and carried here so `assembleProductionBuild`
        /// hands the ENGINE that same instance instead of an unrelated
        /// twin that happened to agree on the memberwise defaults.
        let schedulerConfig: CBv2SchedulerConfig

        private let lock = NSLock()
        private let modelIdentity: ObjectIdentifier
        private let maxConcurrentRequests: Int
        private var backend: CBv2KVBackend?
        private var caches: [any CBv2AttendingLayerCache]?

        init(
            model: any LanguageModel,
            maxConcurrentRequests: Int,
            layerKinds: [CBv2LayerKind],
            backend: CBv2KVBackend,
            caches: [any CBv2AttendingLayerCache],
            kind: EngineV2KVBackendKind,
            fallbackReason: String?,
            schedulerConfig: CBv2SchedulerConfig
        ) {
            self.modelIdentity = ObjectIdentifier(model)
            self.maxConcurrentRequests = max(1, maxConcurrentRequests)
            self.layerKinds = layerKinds
            self.backend = backend
            self.caches = caches
            self.kind = kind
            self.fallbackReason = fallbackReason
            self.schedulerConfig = schedulerConfig
        }

        func consume(
            model: any LanguageModel,
            maxConcurrentRequests: Int
        ) throws -> (CBv2KVBackend, [any CBv2AttendingLayerCache]) {
            try lock.withLock {
                guard modelIdentity == ObjectIdentifier(model) else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend model identity changed before assembly")
                }
                guard self.maxConcurrentRequests == max(1, maxConcurrentRequests) else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend concurrency changed before assembly")
                }
                guard let backend, let caches else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend was already consumed")
                }
                self.backend = nil
                self.caches = nil
                return (backend, caches)
            }
        }
    }

    /// Build the real `EngineV2` over a loaded model, returning the engine
    /// together with the KV-backend decision (`ProductionBuild`).
    ///
    /// KV-backend gate (see `EngineV2KVBackendPolicy` for the full layer
    /// order): the caller passes the operator selection with slot vetoes
    /// (VLM) already applied; `.auto` is always contiguous. Paged remains
    /// an explicit experimental selection.
    /// The `DARKBLOOM_CBV2_PAGED_KV=0` fleet kill switch is enforced at
    /// THIS deepest layer so no call path (benchmarks included) bypasses
    /// it, and it DEGRADES rather than refuses — an operator override is
    /// not a failure. Everything that IS a failure (kernel preflight,
    /// physical-capacity planning, `PagedKVBackend` throwing `CBv2KVError`)
    /// degrades to contiguous under `.auto` but THROWS
    /// `EngineV2ProductionError.pagedUnavailable` under an explicit
    /// `.paged`, so a paged run can never silently serve contiguous.
    public static func makeProductionBuild(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        kvBytesCapacity: Int,
        prefixCache: (any CBv2PrefixCache)? = nil,
        maxConcurrentRequests: Int = EngineV2Factory.productionMaxConcurrentRequests,
        mtpDrafter: (any CBv2MTPDrafter)? = nil,
        mtpConfig: CBv2MTPConfig = CBv2MTPConfig(),
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
    ) throws -> ProductionBuild {
        let preparedBackend = try prepareProductionBackend(
            model: model,
            kvBytesCapacity: kvBytesCapacity,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBackend: kvBackend,
            maxContextLength: maxContextLength,
            environment: environment,
            pagedPreflightOverride: pagedPreflightOverride)
        return try assembleProductionBuild(
            model: model,
            tokenizer: tokenizer,
            prefixCache: prefixCache,
            maxConcurrentRequests: maxConcurrentRequests,
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig,
            preparedBackend: preparedBackend)
    }

    /// Resolve and materialize the exact production backend without creating
    /// EngineV2. Slot assembly uses this phase before SSD construction, then
    /// injects the cache only when the resolved backend capability supports it.
    static func prepareProductionBackend(
        model: any LanguageModel,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int = EngineV2Factory.productionMaxConcurrentRequests,
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
    ) throws -> ProductionBackendPreparation {
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
        // DEGRADE, not refuse — even on an explicit paged selection. This
        // is the branch that must never be collapsed into the failure
        // handling below: the kill switch says "DO NOT do what you asked",
        // a preflight/capacity failure says "we CANNOT do what you asked".
        // Only the second is a broken promise worth a 503. An operator who
        // sets DARKBLOOM_CBV2_PAGED_KV=0 on a fleet configured
        // `engine_v2_kv_backend = "paged"` is asking for contiguous
        // SERVICE, not for every slot to start failing — a kill switch
        // that refuses is not a kill switch. `killSwitchForcesContiguous`
        // in `EngineV2KVBackendGateTests` is the only thing pinning this
        // apart from the refusal cases; keep it a degrade assertion.
        if resolvedKind == .paged,
            EngineV2KVBackendPolicy.killSwitchDisabled(environment: environment)
        {
            resolvedKind = .contiguous
            fallbackReason = "kill_switch"
        }

        // Paged FAILED: we CANNOT do what was asked (kernel preflight,
        // physical-capacity planning, or pool construction) — the other
        // half of the distinction drawn at the kill switch above. The
        // degrade-or-refuse rule itself lives in
        // `EngineV2KVBackendPolicy.degradesPagedFailure`, next to the
        // other four selection layers and unit-testable without building
        // an engine; note the degrade branch is currently reachable only
        // once `.auto` starts resolving paged, since today it short-
        // circuits to contiguous before any of this runs.
        //
        // The refusal is a catchable throw, never a trap: the slot factory
        // maps it to ERROR `engine_v2_refusal` (reason
        // `paged_backend_unavailable`) + 503 and the coordinator reroutes;
        // the benchmark logs the cell as failed. Slot vetoes (VLM) resolve
        // BEFORE this call, so a `.paged` arriving here is a request
        // nothing has excused.
        func degradeOrRefuse(_ reason: String) throws -> String {
            guard EngineV2KVBackendPolicy.degradesPagedFailure(selection: kvBackend)
            else {
                throw EngineV2ProductionError.pagedUnavailable(reason)
            }
            return reason
        }

        // ONE scheduler config for the whole build: this instance sizes the
        // paged pool's `maxPrefillChunk` below AND is the instance the
        // engine runs on — `assembleProductionBuild` reads it back off the
        // preparation and sets only `enablePrefixCache`.
        let schedulerConfig = CBv2SchedulerConfig(
            maxConcurrentRequests: max(1, maxConcurrentRequests))

        func contiguousPreparation() -> ProductionBackendPreparation {
            let backend = CBv2ContiguousKVBackend(
                config: CBv2ContiguousBackendConfig(bytesCapacity: cappedCapacity))
            let caches = newCaches { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            }
            return ProductionBackendPreparation(
                model: model,
                maxConcurrentRequests: maxConcurrentRequests,
                layerKinds: layerKinds,
                backend: backend,
                caches: caches,
                kind: .contiguous,
                fallbackReason: fallbackReason,
                schedulerConfig: schedulerConfig)
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
                fallbackReason = try degradeOrRefuse("kernel_preflight: \(error)")
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
                fallbackReason = try degradeOrRefuse(reason)
            case .paged(let plan):
                do {
                    let paged = try PagedKVBackend(
                        layerKinds: layerKinds,
                        config: PagedKVPoolConfig(
                            capacityBytes: plan.capacityBytes,
                            // LOCKSTEP: a windowed-layer update larger than
                            // the ring's provision traps the PROCESS
                            // (`PagedSequenceKV` precondition), so the pool
                            // must be sized from the chunk the engine
                            // actually schedules. `schedulerConfig` IS that
                            // instance: it is carried on the preparation and
                            // `assembleProductionBuild` hands the very same
                            // value to `EngineV2`, copying it only to set
                            // `enablePrefixCache`. There is no second config
                            // left to drift from.
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
                    return ProductionBackendPreparation(
                        model: model,
                        maxConcurrentRequests: maxConcurrentRequests,
                        layerKinds: layerKinds,
                        backend: paged,
                        caches: caches,
                        kind: .paged,
                        fallbackReason: nil,
                        schedulerConfig: schedulerConfig)
                } catch let error as CBv2KVError {
                    // Paged ineligibility/capacity under `.auto` is a
                    // supported degradation: fall back to the contiguous
                    // backend (INFO telemetry at the bridge — never the
                    // engine_v2_refusal path). Under an explicit `.paged`,
                    // `degradeOrRefuse` rethrows it as `pagedUnavailable`.
                    switch error {
                    case .backendIneligible(let reason):
                        fallbackReason = try degradeOrRefuse("ineligible: \(reason)")
                    case .capacityExhausted(let needed, let available):
                        fallbackReason = try degradeOrRefuse(
                            "pool_construction_capacity: needed \(needed), "
                                + "available \(available)")
                    }
                }
            }
        }
        return contiguousPreparation()
    }

    /// Emergency rollback kill-switch for the monotonic deadline leases. Set
    /// `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT` to `1`/`true`/`yes`/`on` to
    /// restore the legacy single total-lifetime wall
    /// (`CBv2EngineLoopConfig.useLegacyRequestTimeout = true`) — the incident
    /// behavior — for one release cycle while a regression is investigated.
    /// Absent or any other value keeps the new-lease default: a typo must never
    /// silently re-arm the flat 120s wall. Opposite polarity to the
    /// `DARKBLOOM_CBV2_PAGED_KV` kill-switch (that one is on by default).
    static let legacyRequestTimeoutEnvKey = "DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT"

    /// True only when the kill-switch env var is set to an affirmative value.
    static func legacyRequestTimeoutEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[legacyRequestTimeoutEnvKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Final engine assembly over an already resolved backend. This method has
    /// no backend fallback path, so its cache capability cannot drift, and it
    /// builds no scheduler config of its own — it runs the engine on the very
    /// instance `prepareProductionBackend` sized the paged pool against.
    static func assembleProductionBuild(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        prefixCache: (any CBv2PrefixCache)?,
        maxConcurrentRequests: Int,
        mtpDrafter: (any CBv2MTPDrafter)?,
        mtpConfig: CBv2MTPConfig,
        preparedBackend: ProductionBackendPreparation
    ) throws -> ProductionBuild {
        let (backend, caches) = try preparedBackend.consume(
            model: model,
            maxConcurrentRequests: maxConcurrentRequests)
        // The ONE config, read back off the preparation. `consume` has
        // already refused a `maxConcurrentRequests` that differs from the
        // prepared one, so the only field this phase may decide is
        // `enablePrefixCache` — SSD cache construction deliberately runs
        // AFTER backend preparation, because the cache's replay capability
        // follows the backend that will actually serve. Everything else,
        // `prefillChunkSize` above all, reaches the engine byte-identical
        // to what the paged pool's `maxPrefillChunk` was sized from.
        var schedulerConfig = preparedBackend.schedulerConfig
        schedulerConfig.enablePrefixCache = prefixCache != nil
        return ProductionBuild(
            engine: makeEngineV2(
                model: model,
                tokenizer: tokenizer,
                layerKinds: preparedBackend.layerKinds,
                backend: backend,
                caches: caches,
                schedulerConfig: schedulerConfig,
                prefixCache: prefixCache,
                // New monotonic phase leases are on by default
                // (`useLegacyRequestTimeout` defaults false). The ONLY override
                // is the emergency rollback kill-switch below — production never
                // otherwise touches the lease config.
                loopConfig: CBv2EngineLoopConfig(
                    useLegacyRequestTimeout: Self.legacyRequestTimeoutEnabled()),
                mtpDrafter: mtpDrafter,
                mtpConfig: mtpConfig),
            kvBackendKind: preparedBackend.kind,
            kvBackendFallbackReason: preparedBackend.fallbackReason)
    }

    /// Shared final assembly for both backends.
    private static func makeEngineV2(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        layerKinds: [CBv2LayerKind],
        backend: CBv2KVBackend,
        caches: [any CBv2AttendingLayerCache],
        schedulerConfig: CBv2SchedulerConfig,
        prefixCache: (any CBv2PrefixCache)?,
        loopConfig: CBv2EngineLoopConfig,
        mtpDrafter: (any CBv2MTPDrafter)?,
        mtpConfig: CBv2MTPConfig
    ) -> EngineV2 {
        EngineV2(
            model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: layerKinds,
            backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: caches),
            sampler: CBv2DefaultSampler(),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: schedulerConfig,
            loopConfig: loopConfig,
            // Production reusable prefixes use only the encrypted SSD tier.
            // The coordinator-authored cache scope isolates accounts.
            prefixCache: prefixCache,
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig
        )
    }

}
