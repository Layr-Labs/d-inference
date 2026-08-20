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
//     `PagedKVBackend` for an explicit "paged", slabs capped by
//     `PagedKVPhysicalCapacityPolicy` and committed lazily
//     (`.atFirstAdmission`); `CBv2ContiguousKVBackend` for "auto" (v0.8.1
//     reverts the default to contiguous; the argument is at
//     `case .auto: resolvedKind` below), an explicit "contiguous", a slot
//     veto, or the kill switch,
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
import MLXVLM

/// Failure modes of production v2-engine construction. Each maps to the
/// factory's REFUSAL path (ERROR `engine_v2_refusal` telemetry + throw).
enum EngineV2ProductionError: Error, CustomStringConvertible {
    /// The loaded module is not a CBv2-adapted family (an unexpected
    /// architecture). Gemma 4 VLM wrappers are resolved to their directly
    /// owned text tower before engine construction.
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
    /// `DARKBLOOM_CBV2_PAGED_KV_DTYPE` was set to something that is neither
    /// `float16` nor `float32`. Thrown by the parse
    /// (`EngineV2Factory.pagedPoolDType(environment:)`) and surfaced as a
    /// REFUSAL only for an EXPLICIT `.paged` selection — the measurement
    /// posture the knob exists for, where silently serving fp16 under an
    /// fp32 label would fake a control arm. If `.auto` resolves paged, the
    /// factory catches this and DEGRADES to contiguous with
    /// `fallbackReason = "invalid_dtype: …"` instead. That path is dormant
    /// while `.auto` resolves contiguous as of v0.8.1, but remains the safety
    /// contract for any future paged default.
    case invalidPagedPoolDType(String)

    var description: String {
        switch self {
        case .unsupportedModel(let type):
            return "engine_v2: model type \(type) has no CBv2 adapter"
        case .noKVHeadroom:
            return "engine_v2: no KV byte headroom under the unified-memory cap"
        case .pagedUnavailable(let reason):
            return "engine_v2: paged KV backend explicitly requested but "
                + "unavailable — \(reason)"
        case .invalidPagedPoolDType(let raw):
            return "engine_v2: \(EngineV2Factory.pagedPoolDTypeEnvKey)=\"\(raw)\" is not a "
                + "recognized paged page dtype (expected float16 or float32)"
        }
    }
}

extension EngineV2Factory {
    /// Resolve the exact module instance served by CBv2. Gemma 4 VLM owns
    /// its `Gemma4TextModel`; direct VLM forwards and CBv2 therefore share
    /// one language tower, one parameter tree, and one residency footprint.
    static func directServingModel(
        model: any LanguageModel, isVLM: Bool
    ) throws -> any LanguageModel {
        guard isVLM else { return model }
        guard let gemma4 = model as? MLXVLM.Gemma4 else {
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
        return gemma4.textModel
    }


    /// Environment key arming the CBv2 solo-prefill stripe (tokens). See
    /// `CBv2SchedulerConfig.soloPrefillStripeTokens` for semantics. 2,048 is
    /// the largest expert-tile-qualified stripe for the E=256 top-8 MoE
    /// geometry (16,384 assignments); larger values remain correct but drop
    /// that model family's routed experts off the tile route.
    public static let soloPrefillStripeKey = "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE"

    /// Serving default for the solo-prefill stripe (tokens). 2,048 is the
    /// largest expert-tile-qualified stripe (16,384 assignments at top-8)
    /// and the measured winner with trust + prompt narrowing.
    public static let defaultSoloPrefillStripeTokens = 2048

    /// Resolve the solo-stripe setting: absent env -> the serving default;
    /// an explicit value above the plain chunk overrides; any other
    /// explicit value (`0`, garbage, <= plain chunk) DISARMS — the escape
    /// hatch mirrors the `=1` drain-restore convention.
    public static func soloPrefillStripeTokens(
        abovePlainChunk plainChunk: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = environment[soloPrefillStripeKey] else {
            return defaultSoloPrefillStripeTokens > plainChunk
                ? defaultSoloPrefillStripeTokens : nil
        }
        guard let value = Int(raw), value > plainChunk else { return nil }
        return value
    }

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

    /// Element type of the PAGED pool's pages (`PagedKVPoolConfig.dtype`):
    /// `float16` (default) or `float32`.
    ///
    /// Read ONLY when the resolved backend is paged — the contiguous
    /// backend has no pages and ignores this entirely. `float32` is a
    /// MEASUREMENT posture, not a serving one: it is the perturbation the
    /// backend-parity harness needs for a same-backend control arm and for
    /// its fp32 seam-accuracy reference, both of which are otherwise
    /// unconstructible in-process.
    static let pagedPoolDTypeEnvKey = "DARKBLOOM_CBV2_PAGED_KV_DTYPE"

    /// Parse `DARKBLOOM_CBV2_PAGED_KV_DTYPE`. Unset or empty ⇒ `.float16`.
    ///
    /// An unrecognized value THROWS `invalidPagedPoolDType` instead of
    /// reverting to the default. That is deliberately the OPPOSITE of
    /// `DARKBLOOM_CBV2_PAGED_PTOK_TARGET`, which clamps over-range values
    /// at parse and silently takes its default on a typo
    /// (`PagedAttentionKernel.partitionTarget`), and the difference is not
    /// an inconsistency. PTOK is a numeric TUNING target evaluated in a
    /// `static let` initializer with no throw path, and every value it
    /// accepts computes the SAME answers at a different speed — a typo
    /// there costs microseconds. This knob selects the arithmetic the
    /// answers are computed IN. An operator who writes `fp32` and silently
    /// gets float16 has run a different experiment than they believe, and
    /// a control arm that is secretly a second copy of the baseline looks
    /// exactly like agreement.
    ///
    /// The throw is the PARSE's verdict, not the load's: what happens to it
    /// depends on who selected paged. `prepareProductionBackend` rethrows
    /// it for an explicit `.paged` (the measurement posture above) and
    /// catches it under `.auto`, degrading to contiguous with
    /// `fallbackReason = "invalid_dtype: …"` — see the catch site for the
    /// full argument.
    ///
    /// CAPACITY AT fp32 — the arithmetic, because it is a real wall:
    /// a page costs `2 * kvHeads * pageSize * headDim * dtype.size` bytes
    /// (`PagedKVGroup.pageBytes`), so fp32 pages cost exactly 2x, and
    /// `PagedKVPool.init` sizes a group as `pageCount = groupBytes /
    /// pageBytes`. The same byte grant therefore buys HALF the pages.
    /// Page DEMAND does not move — `PagedKVPool.pageDemand` counts pages,
    /// not bytes — so `CBv2PagedKVResidency` charges every admitted row
    /// exactly what it charged at fp16, against a pool holding half as
    /// many pages: concurrency-times-context halves. A grant that leaves a
    /// group under two pages at fp32 (one poison, one tenant) throws
    /// `CBv2KVError.capacityExhausted` from `PagedKVPool.init`. A config
    /// that fit at fp16 and refuses at fp32 is CORRECT: it is refused
    /// rather than quietly served at half the size.
    ///
    /// NOT keyed into the prefix cache. `PagedKVBackend.prefixReuseBackend`
    /// is the constant `.pagedFP16` and `PrefixCacheV2` never considers
    /// dtype, so a block donated under one dtype would be adopted under
    /// another and silently converted by `PagedKVPool.writeTokens`'
    /// `asType`. Unreachable today: a pool's dtype is fixed for its
    /// lifetime and no paged cache entry outlives the pool that donated
    /// it. Anyone making a paged prefix cache PERSISTENT across processes
    /// — where this env var can differ between donor and adopter — must
    /// fold the dtype into the cache key before doing so.
    static func pagedPoolDType(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DType {
        guard let raw = environment[pagedPoolDTypeEnvKey] else { return .float16 }
        // `.whitespacesAndNewlines`, not the `.whitespaces` its two
        // neighbouring bool knobs use: those default on anything they do
        // not recognize, so an `export VAR=$(cat file)` trailing newline
        // costs them nothing, while here it would REFUSE a value whose
        // intent is unambiguous. Normalize what cannot be misread; refuse
        // everything that can.
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "float16": return .float16
        case "float32": return .float32
        default: throw EngineV2ProductionError.invalidPagedPoolDType(raw)
        }
    }

    /// Operator-facing name of a resolved page dtype, in the SAME
    /// vocabulary `pagedPoolDTypeEnvKey` accepts — what a run reports can
    /// be pasted straight back in to reproduce it.
    static func pagedPoolDTypeName(_ dtype: DType) -> String {
        switch dtype {
        case .float16: return "float16"
        case .float32: return "float32"
        default: return "\(dtype)"
        }
    }

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
        case let qwen as Qwen35MoEModel:
            guard qwen.cbv2Capabilities.supportsPrefixReuse else { return 0 }
            return PrefixCachePolicy.adoptionBoundTokens(layerKinds: qwen.cbv2LayerKinds)
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
        case let qwen as Qwen35MoEModel:
            return qwen.cbv2LayerKinds
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

    /// Per-token KV rate for the RESOLVED backend, including the paged
    /// pool's page dtype. This is the figure the slot publishes as
    /// `kv_bytes_per_token` and divides the pool's byte capacity by to get
    /// `activeTokenBudgetMax` (`EngineV2Bridge+Capacity`), so it must be
    /// what a token ACTUALLY costs, not what it costs at the nominal rate.
    ///
    /// Under `DARKBLOOM_CBV2_PAGED_KV_DTYPE=float32` every page is 4 bytes
    /// per element instead of 2, so the whole row doubles — windowed
    /// layers included. That is why this is a flat 2x and NOT
    /// `fullRowsUseFP32`: that flag adds only the owning-full-attention
    /// delta (`+ fp16FullKVBytesPerToken`), which is right for GPT-OSS's
    /// fp32 full rows on the CONTIGUOUS backend and wrong here, where the
    /// sliding-window pages doubled too.
    ///
    /// Without this the byte figure is correct and the divisor is half the
    /// truth, so the slot advertises ~2x the tokens it can hold — which
    /// defeats the pool bound in `EngineV2Bridge+Capacity` that exists
    /// precisely to keep advertised capacity from over-routing past pool
    /// truth. It is NOT an over-admission: paged rows are admitted by
    /// `CBv2PagedKVResidency` against real pages, and the shared-KV ledger
    /// is gated `kvBackendKind == .contiguous` (`EngineV2Bridge`), so a
    /// paged slot never reserves against it.
    ///
    /// The two adjustments are mutually exclusive by construction:
    /// `fullRowsUseFP32` requires a resolved CONTIGUOUS backend and
    /// `pagedPoolDType` is non-nil only on a resolved PAGED one. If both
    /// ever arrive together the result over-counts, which under-advertises
    /// — the safe direction.
    static func processKVBytesPerToken(
        nominalFP16BytesPerToken: Int,
        fp16FullKVBytesPerToken: Int,
        fullRowsUseFP32: Bool,
        pagedPoolDType: String?
    ) -> Int {
        let base = nativeKVBytesPerToken(
            nominalFP16BytesPerToken: nominalFP16BytesPerToken,
            fp16FullKVBytesPerToken: fp16FullKVBytesPerToken,
            fullRowsUseFP32: fullRowsUseFP32)
        guard pagedPoolDType == pagedPoolDTypeName(.float32) else { return base }
        let (doubled, overflow) = base.multipliedReportingOverflow(by: 2)
        return overflow ? Int.max : doubled
    }

    /// Build the real `EngineV2` over a loaded model.
    ///
    /// - Parameters:
    ///   - model: the loaded serving language module; for Gemma 4 VLM this
    ///     is the exact text tower owned by the wrapper.
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
        maxConcurrentRequests: Int,
        prefixCache: (any CBv2PrefixCache)? = nil,
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
            maxConcurrentRequests: maxConcurrentRequests,
            prefixCache: prefixCache,
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
        /// Exact post-resolution fixed request residency from the concrete
        /// engine. This includes any captured-MTP generation expansion and is
        /// the bridge/shared-budget source of truth.
        public let fixedRequestBytes: Int
        public let kvBackendKind: EngineV2KVBackendKind
        /// Non-nil when a paged selection DEGRADED to contiguous: the fleet
        /// kill switch always, and preflight/capacity/eligibility failures
        /// under `.auto`. A degrade is supported — INFO, never a refusal.
        /// An EXPLICIT `.paged` selection never degrades for a failure; it
        /// throws `EngineV2ProductionError.pagedUnavailable`.
        public let kvBackendFallbackReason: String?
        /// The dtype of the pages the PAGED pool was ACTUALLY built with
        /// (`pagedPoolDTypeName` vocabulary), or nil when the resolved
        /// backend is contiguous and there are no pages. Read off the
        /// constructed pool, never off the requested config: a
        /// `DARKBLOOM_CBV2_PAGED_KV_DTYPE=float32` that lands on a
        /// contiguous engine (kill switch, `.auto`) reports nil here, not
        /// "float32", so a parity arm can tell "fp32 served" from "fp32
        /// asked for and ignored" instead of reporting a control that
        /// never ran.
        public let pagedPoolDType: String?

        /// The resolved backend as a benchmark artifact records it: the kind,
        /// with any degrade reason carried in a `(fallback: <reason>)` tail.
        /// One spelling for every report, because the wrapper parses the kind
        /// off the leading word and the reason out of the tail — two producers
        /// formatting this differently would make one of them unreadable.
        public var resolvedKVBackendDescriptor: String {
            kvBackendFallbackReason.map { "\(kvBackendKind.rawValue) (fallback: \($0))" }
                ?? kvBackendKind.rawValue
        }

        public init(
            engine: any CBv2Engine,
            fixedRequestBytes: Int,
            kvBackendKind: EngineV2KVBackendKind,
            kvBackendFallbackReason: String?,
            pagedPoolDType: String? = nil
        ) {
            self.engine = engine
            self.fixedRequestBytes = fixedRequestBytes
            self.kvBackendKind = kvBackendKind
            self.kvBackendFallbackReason = kvBackendFallbackReason
            self.pagedPoolDType = pagedPoolDType
        }
    }

    /// Fully resolved backend resources, created before SSD cache construction
    /// so provider capability follows the backend that will actually serve.
    final class ProductionBackendPreparation {
        let layerKinds: [CBv2LayerKind]
        let modelCapabilities: CBv2ModelCapabilities
        let kind: EngineV2KVBackendKind
        let fallbackReason: String?
        /// The ONE scheduler config of this build. Constructed in
        /// `prepareProductionBackend`, where it sizes the paged pool's
        /// `maxPrefillChunk`, and carried here so `assembleProductionBuild`
        /// hands the ENGINE that same instance instead of an unrelated
        /// twin that happened to agree on the memberwise defaults.
        let schedulerConfig: CBv2SchedulerConfig
        /// Resolved page dtype of the constructed paged pool; nil on
        /// contiguous. Carried so `assembleProductionBuild` can put it on
        /// `ProductionBuild` without re-deriving it from the environment.
        let pagedPoolDType: String?

        private let lock = NSLock()
        private let modelIdentity: ObjectIdentifier
        private let maxConcurrentRequests: Int
        private var backend: CBv2KVBackend?
        private var caches: [any CBv2AttendingLayerCache]?

        init(
            model: any LanguageModel,
            maxConcurrentRequests: Int,
            layerKinds: [CBv2LayerKind],
            modelCapabilities: CBv2ModelCapabilities,
            backend: CBv2KVBackend,
            caches: [any CBv2AttendingLayerCache],
            kind: EngineV2KVBackendKind,
            fallbackReason: String?,
            schedulerConfig: CBv2SchedulerConfig,
            pagedPoolDType: String?
        ) {
            self.modelIdentity = ObjectIdentifier(model)
            self.maxConcurrentRequests = max(1, maxConcurrentRequests)
            self.layerKinds = layerKinds
            self.modelCapabilities = modelCapabilities
            self.backend = backend
            self.caches = caches
            self.kind = kind
            self.fallbackReason = fallbackReason
            self.schedulerConfig = schedulerConfig
            self.pagedPoolDType = pagedPoolDType
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
    /// (VLM) already applied; `.auto` resolves CONTIGUOUS (grep
    /// `case .auto: resolvedKind` below for the argument), so paged is
    /// reached only by an explicit operator selection.
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
        maxConcurrentRequests: Int,
        prefixCache: (any CBv2PrefixCache)? = nil,
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
        maxConcurrentRequests: Int,
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
        let modelCapabilities: CBv2ModelCapabilities
        let newCaches:
            ((Int, CBv2LayerKind) -> any CBv2AttendingLayerCache)
                throws -> [any CBv2AttendingLayerCache]
        switch model {
        case let gemma as Gemma4TextModel:
            layerKinds = gemma.cbv2LayerKinds
            modelCapabilities = .attentionOnly
            newCaches = { make in try gemma.newCacheV2(makeLayerCache: make) }
        case let gptoss as GPTOSSModel:
            layerKinds = gptoss.cbv2LayerKinds
            modelCapabilities = .attentionOnly
            newCaches = { make in gptoss.newCacheV2(makeLayerCache: make) }
        case let qwen as Qwen35MoEModel:
            layerKinds = qwen.cbv2LayerKinds
            modelCapabilities = qwen.cbv2Capabilities
            newCaches = { make in qwen.newCacheV2(makeLayerCache: make) }
        default:
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }

        var resolvedKind: EngineV2KVBackendKind
        switch kvBackend {
        case .contiguous: resolvedKind = .contiguous
        case .paged: resolvedKind = .paged
        // v0.8.1: `.auto` resolves CONTIGUOUS again. v0.8.0 flipped it to
        // paged on adoption-exactness evidence (see below, still true) and
        // production answered with a capacity failure large enough to
        // dominate every other property the backend has.
        //
        // WHY CONTIGUOUS — the paged pool is too small to serve the fleet.
        // A contiguous slot's KV capacity IS its logical grant. A paged
        // slot's is `PagedKVPhysicalCapacityPolicy.decide`, the minimum of
        // FIVE terms:
        //
        //   min(logicalGrant,                       // what contiguous gets
        //       usefulDemand   = 32Ki tok x B x rate,
        //       machineCap     = min(8 GiB, RAM/16),
        //       liveKVHeadroom / 4,                 // liveHeadroomDivisor
        //       2 x Metal maxBufferLength)
        //
        // Summed over the real fleet that is 1,137 GiB of KV against
        // 11,453 GiB under contiguous — an order of magnitude less. Since
        // v0.8.0 shipped: 32.7% of provider attempts return
        // `token_budget_exhausted`, TTFT p95 12.8s / p99 33s, ~8.8% of
        // client requests are cancelled before their first token, and
        // OpenRouter-scored uptime sits near 85%.
        //
        // Relaxing the static caps was considered and REJECTED. The binding
        // term on most boxes is `liveKVHeadroom / 4`, which pins any paged
        // pool to 25% of the contiguous grant no matter how the other four
        // move; raising `absoluteHardCapBytes` and `physicalMemoryDivisor`
        // recovers only ~10% of the deficit. The pool is small by
        // CONSTRUCTION, not by tuning.
        //
        // WHAT WOULD HAVE TO BE TRUE TO MOVE IT AGAIN: a paged slot must
        // advertise KV capacity within a small factor of the same box's
        // contiguous grant. That means the four non-grant terms above stop
        // binding — which needs eager slabs replaced by a headroom model
        // that can be sized against real residency rather than a fixed
        // quarter of a probe, not a bigger constant. Throughput is NOT the
        // blocker and was never the argument: paged still wins the batch
        // curve (1.27x aggregate decode B=4->B=8 against contiguous's
        // 1.07x, plus faster long prefill), and this revert knowingly gives
        // back ~15% aggregate decode at B=8 on gemma-4/M4 Max to buy back
        // 10x the KV. Capacity dominates because a request that is never
        // admitted has no decode rate at all.
        //
        // WHAT THIS COSTS, and where it is paid. The v0.8.0 evidence stands
        // — measured on the real slot path with the SSD tier, six arms,
        // backend label confirmed on every one, cold-twin byte-identical
        // throughout. Prefix-cache ADOPTION exactness:
        //
        //   model                     paged        contiguous
        //   gemma-4-26B-A4B-it-qat    EXACT        DIVERGES at byte 4
        //   gpt-oss-20b-MXFP4-Q8      EXACT        DIVERGES
        //   gemma-4-e2b-it-4bit       diverges     exact
        //
        // The first two are the ENTIRE production catalog, so on every
        // model we actually serve, contiguous is the arm that answers
        // differently when a prefix-cache hit occurs. Roughly 2.3% of
        // flagship traffic clears the 26,624-token donation floor and would
        // silently receive a truncated answer instead of an error. That
        // class is closed in the SAME release, not accepted: the SSD prefix
        // cache is NOT CONSTRUCTED for a resolved-contiguous slot
        // (`PrefixCachePolicy.adoptionIsExact(onResolvedBackend:)`, applied
        // in `EngineV2SlotFactory`), so no prefix is ever staged, matched
        // or adopted there. Contiguous slots trade cache hits — a latency
        // optimization — for correctness, and paged keeps both.
        //
        // gemma-4 greedy token ids move back to the contiguous values.
        // Paged is measurably closer to an fp32 reference (7-17x on the
        // full-attention layers), so this is a real accuracy give-back and
        // is taken deliberately, same as the flip that introduced it.
        //
        // Paged is unchanged and fully supported: `engine_v2_kv_backend =
        // "paged"` (global or by-model) still resolves paged, and the
        // parity harness, the blocking paged CI lane, the kill switch and
        // the crash-loop guard all still exercise it. NOTE the asymmetry a
        // contiguous default creates: `DARKBLOOM_CBV2_PAGED_KV` is a
        // negative-polarity KILL switch, so there is no env var that turns
        // paged back ON — re-enabling it fleet-wide is a release, and
        // per-box it is the config key.
        case .auto: resolvedKind = .contiguous
        }
        var fallbackReason: String?
        if resolvedKind == .paged, !modelCapabilities.supportsPagedKV {
            resolvedKind = .contiguous
            fallbackReason = "model_capability"
        }
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

        // Crash-loop backend guard — the AUTOMATED sibling of the kill
        // switch above, tripped by the watchdog after
        // `WatchdogPolicy.crashLoopTripThreshold` consecutive short-uptime
        // restarts (see KVBackendGuard.swift for the full lifecycle) and
        // enforced at this same deepest layer so no call path bypasses it.
        // Checked AFTER the kill switch so a box with both reports the
        // operator's reason, not the automation's.
        //
        // Scoped to `.auto` ONLY, by design: an explicit
        // `engine_v2_kv_backend = "paged"` (global or by-model) is operator
        // intent, and automation silently downgrading an explicit selection
        // would be the same silent-degrade defect the refusal path exists
        // to prevent — the kill switch may override an explicit selection
        // because it IS an operator; the guard is a robot. Version-scoped:
        // the record binds only the binary version that tripped it, so the
        // next release (the fleet's only fix-delivery vector) auto-clears
        // and a stale guard cannot outlive its defect. The record is read
        // through the injected `environment` (path override
        // `DARKBLOOM_KV_BACKEND_GUARD`), keeping this seam as hermetically
        // testable as the kill switch's.
        //
        // DORMANT as of v0.8.1 and deliberately kept: `.auto` no longer
        // resolves paged, so the two conditions below cannot both hold in
        // production today. The guard costs one file read on a path that
        // already builds an engine, and it is the thing that makes a future
        // re-flip safe to attempt — deleting it would have to be undone by
        // whoever attempts one. `autoHonorsCrashLoopGuard` keeps it live by
        // driving `.auto` through the factory directly.
        if resolvedKind == .paged, kvBackend == .auto,
            EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                record: KVBackendGuardStore.read(environment: environment),
                runningVersion: ProviderCore.version)
        {
            resolvedKind = .contiguous
            fallbackReason = "crash_loop_guard"
        }

        // Page dtype, read HERE: inside the paged branch, so a contiguous
        // slot ignores a knob that means nothing to it and the kill switch
        // (which has already forced contiguous above) leaves it inert; and
        // BEFORE preflight, so the reason names the typo rather than
        // whatever unrelated failure preflight would have hit first.
        //
        // Under `.auto` a malformed value DEGRADES to contiguous
        // (`fallbackReason = "invalid_dtype: …"`) rather than refusing, so
        // one typo'd env var cannot turn a measurement knob into a
        // fleet-wide 503. An explicit `.paged` still REFUSES loudly with
        // the original `invalidPagedPoolDType` (classified
        // `paged_kv_dtype_invalid`, not `pagedUnavailable` — a typo must
        // stay separable from paged infrastructure failing), so a control
        // arm can never silently measure fp16 wearing an fp32 label.
        //
        // The `.auto` half of that split is dormant as of v0.8.1 for the
        // same reason as the guard above — `.auto` never arrives here
        // paged — and stays for the same reason: it is the safety property
        // a re-flip depends on, and `degradesPagedFailure` still pins it.
        var pagedDType = DType.float16
        if resolvedKind == .paged {
            do {
                pagedDType = try Self.pagedPoolDType(environment: environment)
            } catch let error as EngineV2ProductionError {
                guard case .invalidPagedPoolDType(let raw) = error,
                    EngineV2KVBackendPolicy.degradesPagedFailure(selection: kvBackend)
                else { throw error }
                resolvedKind = .contiguous
                fallbackReason = "invalid_dtype: \(raw)"
            }
        }

        // Paged FAILED: we CANNOT do what was asked (kernel preflight,
        // physical-capacity planning, or pool construction) — the other
        // half of the distinction drawn at the kill switch above. The
        // degrade-or-refuse rule itself lives in
        // `EngineV2KVBackendPolicy.degradesPagedFailure`, next to the
        // other four selection layers and unit-testable without building
        // an engine. As of v0.8.1 only an explicit `.paged` reaches this
        // code, so in production it is the REFUSAL half that fires; the
        // degrade half was the common path for the one release where
        // `.auto` resolved paged and is retained for the next one.
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
        var schedulerConfig = CBv2SchedulerConfig(
            maxConcurrentRequests: max(1, maxConcurrentRequests))
        schedulerConfig.soloPrefillStripeTokens = Self.soloPrefillStripeTokens(
            abovePlainChunk: schedulerConfig.prefillChunkSize,
            environment: environment)
        schedulerConfig.maxConcurrentPartialPrefills =
            environment["DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS"].flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }

        func contiguousPreparation() throws -> ProductionBackendPreparation {
            let backend = CBv2ContiguousKVBackend(
                config: CBv2ContiguousBackendConfig(bytesCapacity: cappedCapacity))
            let caches = try newCaches { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            }
            return ProductionBackendPreparation(
                model: model,
                maxConcurrentRequests: maxConcurrentRequests,
                layerKinds: layerKinds,
                modelCapabilities: modelCapabilities,
                backend: backend,
                caches: caches,
                kind: .contiguous,
                fallbackReason: fallbackReason,
                schedulerConfig: schedulerConfig,
                // Contiguous has no pages: report NO dtype rather than the
                // requested one, so a parity arm cannot read a knob it set
                // as evidence the fp32 pool exists.
                pagedPoolDType: nil)
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
                            dtype: pagedDType,
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
                            maxPrefillChunk: max(
                                schedulerConfig.prefillChunkSize,
                                // A solo stripe is a chunk the engine can
                                // actually schedule, so the lockstep above
                                // must cover it or a striped windowed-layer
                                // update would trap the process.
                                schedulerConfig.soloPrefillStripeTokens ?? 0),
                            nominalMaxSequenceLength: max(
                                1, maxContextLength ?? 8192),
                            maxBufferLength: maxBufferLength),
                        // D1: the slabs are NOT wired here. Under
                        // `.atFirstAdmission` (the plan's production
                        // posture) `PagedKVBackend` commits them at the
                        // pool's first admission instead, so a slot that has
                        // served nothing does not occupy unified memory that
                        // the NEXT model's post-load headroom guard
                        // measures. Everything the old eager commit
                        // protected against still holds: resource and size
                        // eligibility threw catchably in `PagedKVPool.init`
                        // above, and the commitment happens before any row
                        // exists, so no admitted page is ever unbacked.
                        slabCommitment: plan.commitment)
                    let pagedCaches = paged.makeLayerCaches()
                    let caches = try newCaches { index, _ in pagedCaches[index] }
                    return ProductionBackendPreparation(
                        model: model,
                        maxConcurrentRequests: maxConcurrentRequests,
                        layerKinds: layerKinds,
                        modelCapabilities: modelCapabilities,
                        backend: paged,
                        caches: caches,
                        kind: .paged,
                        fallbackReason: nil,
                        schedulerConfig: schedulerConfig,
                        // From the CONSTRUCTED pool, not from `pagedDType`:
                        // `PagedKVPool.init` is what validated the dtype and
                        // stamped every group's slabs with it, so this is
                        // the built artifact reporting itself.
                        pagedPoolDType: Self.pagedPoolDTypeName(
                            paged.pool.config.dtype))
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
        return try contiguousPreparation()
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
        let effectivePrefixCache = preparedBackend.modelCapabilities.supportsPrefixReuse
            ? prefixCache : nil
        // The ONE config, read back off the preparation. `consume` has
        // already refused a `maxConcurrentRequests` that differs from the
        // prepared one, so the only field this phase may decide is
        // `enablePrefixCache` — SSD cache construction deliberately runs
        // AFTER backend preparation, because the cache's replay capability
        // follows the backend that will actually serve. Everything else,
        // `prefillChunkSize` above all, reaches the engine byte-identical
        // to what the paged pool's `maxPrefillChunk` was sized from.
        var schedulerConfig = preparedBackend.schedulerConfig
        schedulerConfig.enablePrefixCache = effectivePrefixCache != nil
        let engine = makeEngineV2(
            model: model,
            tokenizer: tokenizer,
            layerKinds: preparedBackend.layerKinds,
            backend: backend,
            caches: caches,
            schedulerConfig: schedulerConfig,
            prefixCache: effectivePrefixCache,
            // New monotonic phase leases are on by default
            // (`useLegacyRequestTimeout` defaults false). The ONLY override
            // is the emergency rollback kill-switch below — production never
            // otherwise touches the lease config.
            loopConfig: CBv2EngineLoopConfig(
                useLegacyRequestTimeout: Self.legacyRequestTimeoutEnabled()),
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig)
        return ProductionBuild(
            engine: engine,
            fixedRequestBytes: engine.resolvedFixedBytesPerRequest,
            kvBackendKind: preparedBackend.kind,
            kvBackendFallbackReason: preparedBackend.fallbackReason,
            pagedPoolDType: preparedBackend.pagedPoolDType)
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
