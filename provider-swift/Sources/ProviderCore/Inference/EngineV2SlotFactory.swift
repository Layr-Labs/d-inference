// Copyright © 2026 Eigen Labs.
//
// Shared production v2-slot bridge assembly (v0.7.5 one-engine).
//
// Both slot owners — the coordinator-serving `ProviderLoop` and the
// standalone `darkbloom start --local` server — construct their model
// slots through THIS one path so the assembly can never drift between
// them: snapshot the loaded module's EOS config out of the container,
// apply the model-specific EOS policy (`ModelEOSPolicy`), build the
// production CBv2 engine over the loaded module (with the weight-sharing
// VLM text extraction for Gemma 4 VLM checkpoints), and wrap it in an
// `EngineV2Bridge` via the fail-loud `EngineV2Factory.makeBridge` (any
// construction failure emits the ERROR `engine_v2_refusal` telemetry and
// throws — the caller unloads and maps to a 503; there is no legacy
// fallback).
//
// Call-site differences stay at the call sites: the ProviderLoop
// registers the bridge with `EngineV2Runtime` (heartbeat/cancel fan-out)
// and supports its own `EngineV2SlotHooks` test seam; the standalone
// server keeps its slots private to the HTTP endpoint. Test seams here
// are limited to `makeEngineOverride` (scripted engines, no weights).

import Foundation
import MLXLMCommon

/// Model handle + EOS config snapshot pulled out of `ModelContainer.perform`.
///
/// `@unchecked Sendable` justification: the module reference crosses the
/// container's isolation exactly once, at load time, to be handed to the v2
/// engine — which serializes every use on its own engine thread.
struct EngineV2ModelSnapshot: @unchecked Sendable {
    let model: any LanguageModel
    let eosTokenIds: Set<Int>
    let extraEOSTokens: [String]
}

enum EngineV2SlotFactory {

    // MARK: - Prefix-cache carve (T-041, v0.7.5)

    /// Outcome of the tier selection + funding gate + carve for one slot.
    struct PrefixCarveDecision {
        /// The grant split: engine admission ceiling + cache byte budget.
        /// Only the opt-in RAM tier ever carves; `.ssd`/`.off` modes are a
        /// passthrough (the SSD tier's budget is DISK, not memory).
        let carve: PrefixCachePolicy.Carve
        /// Resolved tier for this environment (`PrefixCachePolicy.mode`):
        /// SSD default-on, RAM opt-in (with SSD killed), master kill.
        let mode: PrefixCachePolicy.Mode
        /// Whether the per-model funding gate funded the RAM tier's carve
        /// (RAM tier only — the SSD tier gates per DONATION instead).
        let funded: Bool
        /// The model's adoption bound (tokens) the funding gate judged.
        let adoptionBoundTokens: Int
    }

    /// THE single carve point (T-041): split a slot's re-slice grant
    /// between the engine's admission ceiling and the RAM-only v2 prefix
    /// cache. Order of the load pipeline: re-slice grant → THIS funding-
    /// gated carve (`.ram` mode only; `.ssd`/`.off` ⇒ passthrough) →
    /// SSD tier construction (`.ssd` mode, no memory carve) → engine
    /// construction with the (possibly reduced) grant.
    ///
    /// Per-model funding gate — RAM TIER ONLY (see PrefixCachePolicy's
    /// header): a hybrid model whose adoption bound (windowCount ×
    /// maxWindow) exceeds the funding threshold can never produce a hit
    /// at real prompt lengths, so its cache is NOT funded and the full
    /// grant stays with live KV (gemma-4: bound 25,600 ⇒ unfunded;
    /// gpt-oss: 1,536 ⇒ funded). The SSD tier ignores this gate and gates
    /// each DONATION on the same bound instead (`SSDPrefixCache.donate`).
    /// Text slots read the bound off the loaded model; VLM slots derive
    /// it from the checkpoint's text_config (config-only — the weight-
    /// sharing extraction runs later, inside engine construction).
    /// `model` nil (test hooks) / unknown families ⇒ bound 0
    /// (pure-full-attention semantics ⇒ fundable).
    ///
    /// Everything downstream reads ENGINE TRUTH — the engine's private
    /// ledger (`AdmissionV2`), the bridge capacity snapshot, and the
    /// heartbeat `activeTokenBudgetMax` all derive from the REDUCED
    /// engine capacity — so the coordinator is never told about bytes the
    /// cache will consume, and cached KV + live-request KV can never
    /// jointly exceed the slot's grant. Live serving wins: the carve
    /// shrinks the PREFIX budget (down to 0) before it would starve the
    /// engine below the serviceable floor.
    static func resolvePrefixCarve(
        modelId: String,
        isVLM: Bool,
        modelDirectory: URL?,
        model: (any LanguageModel)?,
        slotKVBytesCapacity: Int,
        kvBytesPerToken: Int,
        environment: [String: String]
    ) -> PrefixCarveDecision {
        let mode = PrefixCachePolicy.mode(environment: environment)
        let ramTier = mode == .ram
        let adoptionBound: Int
        if ramTier, let model {
            if isVLM {
                adoptionBound = modelDirectory.flatMap {
                    EngineV2VLMTextExtraction.adoptionBoundTokens(modelDirectory: $0)
                } ?? 0
            } else {
                adoptionBound = EngineV2Factory.adoptionBoundTokens(model: model)
            }
        } else {
            adoptionBound = 0
        }
        let funded = ramTier
            && PrefixCachePolicy.shouldFund(
                adoptionBoundTokens: adoptionBound, environment: environment)
        let requestedBudget = funded
            ? PrefixCachePolicy.budgetBytes(environment: environment)
            : 0
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: slotKVBytesCapacity,
            requestedBudgetBytes: requestedBudget,
            kvBytesPerToken: kvBytesPerToken)
        return PrefixCarveDecision(
            carve: carve,
            mode: mode,
            funded: funded,
            adoptionBoundTokens: adoptionBound)
    }

    /// Human-readable cache state for the slot-serving log line.
    static func prefixCacheStateDescription(
        decision: PrefixCarveDecision,
        ssdCache: SSDPrefixCache?,
        environment: [String: String]
    ) -> String {
        if let ssdCache {
            // Saturating sum: an operator-set
            // DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS near Int.max
            // must not trap while FORMATTING this load-time log line (the
            // actual staging/donation gates already saturate — mirror them).
            let (floor, floorOverflow) = ssdCache.config.adoptionBoundTokens
                .addingReportingOverflow(ssdCache.config.minEffectiveTokens)
            let floorDesc = floorOverflow ? "Int.max (saturated)" : "\(floor)"
            return "on (tier=ssd: encrypted offload, HMAC-keyed names, "
                + "15-min sliding TTL, NO memory carve, per-donation gate "
                + "> \(floorDesc) tok — T-041)"
        }
        if decision.carve.prefixCacheBudgetBytes > 0 {
            return "on, budget \(decision.carve.prefixCacheBudgetBytes) B "
                + "(tier=ram opt-in, salt-scoped — T-041)"
        }
        if decision.mode == .ram && !decision.funded {
            // RAM tier only — the SSD tier has no per-model funding gate
            // (it gates per donation instead). Name WHY: this model's
            // hybrid window shape makes hits unreachable at real prompt
            // lengths, so its budget stays with live KV (see
            // PrefixCachePolicy's funding-gate rationale).
            return "unfunded (adoption bound \(decision.adoptionBoundTokens) tok, "
                + "funding cap "
                + "\(PrefixCachePolicy.maxAdoptionBoundTokens(environment: environment)) "
                + "— full grant stays with live KV)"
        }
        return "off"
    }

    /// Build the production `EngineV2Bridge` for a freshly-loaded model.
    /// THROWS on any construction failure (the factory emits the ERROR
    /// `engine_v2_refusal` event first) — the caller unloads + maps to 503.
    ///
    /// - Parameters:
    ///   - modelId: catalog id the slot serves under.
    ///   - modelType: `model_type` from config.json (EOS policy input).
    ///   - isVLM: config declares `vision_config` — the engine is built
    ///     over `EngineV2VLMTextExtraction`'s weight-sharing text model.
    ///   - modelDirectory: checkpoint dir (required for VLM extraction).
    ///   - container: the just-loaded model container.
    ///   - tokenizer: the container's tokenizer handle.
    ///   - sizing: scheduler-free sizing snapshot (fp16 KV rate, context,
    ///     default max tokens).
    ///   - kvBytesCapacity: this SLOT's total KV grant, already re-sliced
    ///     against co-resident slots by the caller. The factory carves the
    ///     prefix-cache budget out of it (`resolvePrefixCarve`) and hands
    ///     the engine the REDUCED remainder; the bridge carries the budget
    ///     so `slotKVBytesClaim()` reconstructs the total (T-041).
    ///   - maxConcurrentRequests: effective `engine_v2_max_concurrent`.
    ///   - kvBudget: process-wide shared KV reservation ledger (nil ⇒ no
    ///     shared gating — unit tests only; both production callers pass
    ///     their ledger).
    ///   - kvQuantConfigured: operator set `kv_quant` — v2 is fp16-only,
    ///     so a WARN telemetry event fires once per load.
    ///   - weightHash: the slot's verified weight hash (metadata binding
    ///     for the SSD tier's on-disk artifacts). nil ⇒ the tier degrades
    ///     to a model-id binding (same posture as the legacy tier) — the
    ///     standalone server passes nil (it never computes weight hashes).
    ///   - environment: prefix-cache policy environment
    ///     (`DARKBLOOM_PREFIX_CACHE*`); injectable for tests.
    ///   - emitTelemetry: injectable sink (tests); nil ⇒ shared client.
    ///   - makeEngineOverride: scripted engine builder for tests
    ///     ((modelId, post-carve engine capacity) — mirrors
    ///     `ProviderLoop.EngineV2SlotHooks`); nil ⇒ the real
    ///     `EngineV2Factory.makeProductionEngine`. The carve + budget
    ///     bookkeeping run either way (production shape); the cache
    ///     INSTANCES (RAM or SSD) and stats loggers exist only on the
    ///     production path.
    ///   - logInfo: sink for the VLM parity-gate + cache-state info lines.
    ///   - logWarning: sink for the both-tiers-requested WARN line.
    static func makeProductionBridge(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        container: ModelContainer,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBudget: GlobalKVCacheBudget?,
        kvQuantConfigured: Bool,
        kvBackendConfig: String = "auto",
        kvBackendConfigByModel: [String: String] = [:],
        weightHash: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngineOverride: (@Sendable (String, Int) throws -> any CBv2Engine)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2Bridge {
        // KV-backend gate, slot-veto layer (`EngineV2KVBackendPolicy`):
        // parse the operator selection (per-model override wins; typo →
        // WARN + auto), then force contiguous for slots the paged cache
        // cannot serve — VLM (span masks unsupported: media would 4xx at
        // submit) and kv_quant intent (fp16 pages only). `auto` resolves
        // contiguous; the fleet kill switch, physical-capacity planning,
        // and eligibility fallback live in `makeProductionBuild`.
        let parsedKVBackend = EngineV2KVBackendPolicy.parseSelection(
            global: kvBackendConfig, byModel: kvBackendConfigByModel, modelID: modelId)
        if let unrecognized = parsedKVBackend.unrecognized {
            logWarning(
                "engine_v2: unrecognized engine_v2_kv_backend value "
                    + "\"\(unrecognized)\" for \(modelId) — using \"auto\"")
        }
        let vetoed = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: parsedKVBackend.selection,
            isVLM: isVLM,
            kvQuantConfigured: kvQuantConfigured)
        let kvBackendSelection = vetoed.selection
        if let veto = vetoed.veto {
            logInfo(
                "engine_v2: \(modelId) paged KV backend forced to contiguous "
                    + "(\(veto))")
        }
        // Snapshot the model handle + EOS config out of the container.
        // Handing the module reference to the v2 engine serializes all
        // forward passes on the engine's own step thread. Taken BEFORE the
        // carve because the per-model funding gate needs the model's layer
        // shape.
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        // Same model-specific EOS augmentation as always (GPT-OSS/Harmony
        // adds its generation-config action stops) — from the
        // scheduler-free policy home.
        let eosTokenIds = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: modelId,
            modelType: modelType,
            base: snapshot.eosTokenIds,
            tokenToId: { tokenizer.inner.convertTokenToId($0) }
        )

        // THE single carve point (T-041): re-slice grant → RAM-tier
        // funding-gated carve (RAM is dormant by default ⇒ passthrough) → SSD tier
        // construction (no memory carve) → engine construction with the
        // (possibly reduced) ceiling. Both production slot owners share
        // this path.
        let carveDecision = resolvePrefixCarve(
            modelId: modelId,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            model: snapshot.model,
            slotKVBytesCapacity: kvBytesCapacity,
            kvBytesPerToken: sizing.fp16KVBytesPerToken,
            environment: environment)
        let engineKVBytesCapacity = carveDecision.carve.engineKVBytesCapacity
        let prefixCacheBudgetBytes = carveDecision.carve.prefixCacheBudgetBytes

        // Funded RAM cache instance (opt-in tier; production engines only —
        // scripted test engines have no cache seam; the budget bookkeeping
        // still applies so claim/heartbeat math keeps production shape).
        // Built HERE, not inside the closure, so the factory keeps the
        // handle for the periodic stats logger below.
        let prefixCache = makeEngineOverride == nil
            ? PrefixCachePolicy.makePrefixCache(
                modelId: modelId, budgetBytes: prefixCacheBudgetBytes)
            : nil

        // SSD tier instance (v0.7.5 encrypted offload — the DEFAULT for
        // every CBv2-adapted model in `.ssd` mode; production path only).
        // The same object serves as the ENGINE's `CBv2PrefixCache` and the
        // BRIDGE's staging/backstop/shutdown handle. NOT funding-gated:
        // the tier gates each DONATION on the model's own adoption bound +
        // benefit floor instead (`SSDPrefixCache.donate`), so gemma-4's
        // long-context tail caches while gpt-oss's never-adoptable short
        // donations are skipped. Its budget is DISK (own kv2/ root, 20 GiB
        // box-wide LRU) — the engine keeps the FULL slot grant; the tier's
        // only RAM claims are per-request staging reservations in the
        // shared `GlobalKVCacheBudget` (refused ⇒ silent recompute).
        //
        // VLM slots derive layer kinds from config.json's text_config
        // alone (`EngineV2VLMTextExtraction.cbv2LayerKinds` — drift tests
        // pin config-derived shape == engine truth); the weight-sharing
        // extraction itself still runs inside engine construction. A
        // family with no derivable kinds gets no cache (it would throw
        // unsupportedModel at engine build anyway).
        var ssdPrefixCache: SSDPrefixCache?
        if makeEngineOverride == nil, case .ssd(let warnBothTiers) = carveDecision.mode {
            if warnBothTiers {
                logWarning(
                    "engine_v2: DARKBLOOM_PREFIX_CACHE=1 (RAM tier opt-in) and the "
                        + "SSD tier are BOTH active for \(modelId) — SSD wins for "
                        + "this slot; tiers do not compose in v1")
            }
            let ssdLayerKinds: [CBv2LayerKind]?
            if isVLM {
                ssdLayerKinds = modelDirectory.flatMap {
                    EngineV2VLMTextExtraction.cbv2LayerKinds(modelDirectory: $0)
                }
            } else {
                ssdLayerKinds = EngineV2Factory.cbv2LayerKinds(model: snapshot.model)
            }
            if let ssdLayerKinds {
                ssdPrefixCache = await SSDPrefixCacheFactory.make(
                    modelId: modelId,
                    weightHash: weightHash,
                    layerKinds: ssdLayerKinds,
                    kvBudget: kvBudget,
                    environment: environment)
            } else {
                logInfo(
                    "engine_v2: SSD prefix cache skipped for \(modelId) — no "
                        + "derivable CBv2 layer kinds (non-adapted family)")
            }
        }

        // The cache handed to the engine: the RAM tier when opted in (and
        // the SSD tier killed), else the SSD conformer — both ride the
        // engine's frozen existential `CBv2PrefixCache` seam.
        let enginePrefixCache: (any CBv2PrefixCache)?
        if let prefixCache {
            enginePrefixCache = prefixCache
        } else if let ssdPrefixCache {
            enginePrefixCache = ssdPrefixCache
        } else {
            enginePrefixCache = nil
        }

        let makeEngine: () throws -> EngineV2Factory.ProductionBuild
        if let makeEngineOverride {
            // Scripted engines are backend-less stubs: report contiguous
            // (the shared-gate/reslice default) with no fallback.
            makeEngine = {
                EngineV2Factory.ProductionBuild(
                    engine: try makeEngineOverride(modelId, engineKVBytesCapacity),
                    kvBackendKind: .contiguous,
                    kvBackendFallbackReason: nil)
            }
        } else {
            makeEngine = {
                // VLM slot: extract the CBv2-adapted MLXLLM text model over
                // the SAME weight arrays (zero extra weight memory) and
                // build the engine on that; any extraction/verify/parity
                // failure throws into the factory's engine_v2_refusal ERROR.
                let servingModel: any LanguageModel
                if isVLM {
                    guard let modelDirectory else {
                        throw EngineV2VLMTextExtractionError.missingModelDirectory
                    }
                    let extraction = try EngineV2VLMTextExtraction.extractTextModel(
                        from: snapshot.model, modelDirectory: modelDirectory)
                    if let parityDiff = extraction.parityMaxAbsLogitDiff {
                        logInfo(
                            "engine_v2: \(modelId) VLM text-model extraction passed the "
                                + "load-time forward parity gate (max |Δlogit| \(parityDiff))")
                    }
                    servingModel = extraction.model
                } else {
                    servingModel = snapshot.model
                }
                return try EngineV2Factory.makeProductionBuild(
                    model: servingModel,
                    tokenizer: tokenizer.inner,
                    kvBytesCapacity: engineKVBytesCapacity,
                    prefixCache: enginePrefixCache,
                    maxConcurrentRequests: maxConcurrentRequests,
                    kvBackend: kvBackendSelection,
                    // Sizes the paged pool's per-group split
                    // (`nominalMaxSequenceLength`); 0/unknown → factory
                    // default.
                    maxContextLength: sizing.maxContextLength > 0
                        ? sizing.maxContextLength : nil,
                    environment: environment)
            }
        }

        let bridge = try EngineV2Factory.makeBridge(
            modelId: modelId,
            tokenizer: tokenizer,
            eosTokenIds: eosTokenIds,
            extraEOSTokens: snapshot.extraEOSTokens,
            defaultMaxTokens: sizing.defaultMaxTokens,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBytesPerToken: sizing.fp16KVBytesPerToken,
            // Shared KV ledger: v2 submissions RESERVE their worst-case
            // KV here before engine admission (process-wide gate) and the
            // reservation is what the model-LOAD gate subtracts.
            kvBudget: kvBudget,
            // The carve's budget (0 when the cache is off): fleet-sizing
            // bookkeeping — the bridge exposes it via `slotKVBytesClaim()`
            // so re-slices and heartbeats subtract the cache's bytes too.
            prefixCacheBudgetBytes: prefixCacheBudgetBytes,
            // SSD tier handle for the bridge's pre-submit staging hook,
            // release backstops, and shutdown (closed by `makeBridge` on
            // an engine-init failure so background tasks never leak).
            ssdPrefixCache: ssdPrefixCache,
            emitTelemetry: emitTelemetry,
            makeEngine: makeEngine)

        // Periodic cache stats (v2 analog of the legacy checkpoint-tier
        // logger; cancelled by `bridge.shutdown()` on unload).
        if let prefixCache {
            await bridge.startPrefixCacheStatsLogger(cache: prefixCache)
        }
        if let ssdPrefixCache {
            await bridge.startSSDPrefixCacheStatsLogger(cache: ssdPrefixCache)
        }
        logInfo(
            "engine_v2: \(modelId) prefix cache "
                + prefixCacheStateDescription(
                    decision: carveDecision,
                    ssdCache: ssdPrefixCache,
                    environment: environment))

        // WARN once (per load) that kv_quant is ignored on the v2 path
        // (fp16 caches are what the engine builds).
        if kvQuantConfigured {
            EngineV2Factory.emitKVQuantUnsupportedTelemetry(
                modelId: modelId, emitTelemetry: emitTelemetry)
        }
        return bridge
    }
}
