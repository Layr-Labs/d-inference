@_exported import ProviderCoreFoundation

import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

public enum ProviderCore {
    /// Provider version. Bumped manually on each cut; CI reads this to derive
    /// the release tag and the registered binary version. Until we land a
    /// SwiftPM build-tool plugin that injects the value from `git describe`,
    /// keep this in sync with the tag (`vX.Y.Z-swift[.N]`) at release time.
    ///
    /// 0.5.0 is the first Swift cutover release: drops Python, drops
    /// vllm-mlx, ships only `darkbloom` + `darkbloom-enclave` +
    /// `mlx.metallib`. (`eigeninference-enclave` ships as a backward-
    /// compatibility symlink to `darkbloom-enclave`.)
    // 0.5.17 ships declarative desired-build support (the `desired_models`
    // message + provider self-reconcile/hard-swap). The coordinator gates
    // `desired_models` on provider version >= 0.5.17 (minProviderVersionForDesiredModels)
    // so pre-feature providers never receive a message their decoder would reject.
    // 0.6.0 ships APNs code-identity attestation (graced rollout), encrypted SSD
    // KV cache (default-on), Gemma 4 image/video VLM serving with vision-aware
    // routing, graceful download-first auto-update, and the model-alias hot-swap
    // layer. Semver compares numerically per-component, so 0.6.0 > 0.5.17 keeps
    // the desired_models gate satisfied.
    // 0.6.9 fixes a Gemma 4 batched-attention NaN bug: when continuous batching
    // co-prefills requests of different lengths, short rows are left-padded and
    // their fully-masked padding queries softmaxed to NaN, which `0 * NaN`
    // propagated into every row -> token-salad/repetition under concurrent load.
    // Fixed in mlx-swift-lm#38 (gemma4AttentionFallback NaN-guard); submodule
    // pin advanced to ee2a921.
    // 0.6.10 ships the resource-count-safe MLX allocator pins, bounded model
    // weight hashing, attestation reconnect stability, alias-aware catalog UX,
    // and coordinator-side TTFT 429 admission for overloaded OpenRouter traffic.
    // 0.6.11 fixes Gemma 4 VLM continuous-batched repetition: the VLM model's
    // batched decode used a scalar RoPE offset (wrong per-row positions in
    // mixed-length batches) and an explicit-mask fused-attention kernel that
    // diverges on 4-bit Gemma 4 (MLX #3384). Fixed via per-row RoPE offsets, a
    // manual masked-attention fallback for padded decode, and .none decode masks
    // for unpadded single-token steps; submodule pin advanced to f2f40e5
    // (mlx-swift-lm#41).
    // 0.6.12 hardens memory & reliability: a 90% unified-memory cap with KV purge
    // on unload + serve-while-load reservation (no more byte-OOM machine crashes),
    // a bounded checkpoint-capture pipeline (stops the Metal [metal::malloc]
    // resource-limit 499000 leak), resumable 4-bit model downloads, default-on
    // [rsrc] resource telemetry in reports, and no raw request-parse errors in
    // logs (prompt-fragment privacy). Submodule pin advanced to e7af9df
    // (mlx-swift-lm#42).
    // 0.6.13 fixes the Gemma 4 machine-crash for good and adds Routing v2 provider
    // support: the decode-path Metal live-resource COUNT leak is fixed (asyncEval of
    // batchOffset/leftPadding; gemma-4-26B 53/step -> ~0.03/step, live-validated,
    // flat bytes; DAR-325 / mlx-swift-lm#44), provider-measured prefill TPS +
    // model-load time are reported for TTFT-accurate routing (W1), the live APNs
    // device token rides heartbeats so code-identity re-arms without a reconnect and
    // prefix-cache restores no longer skew the prefill EWMA (W5), and a
    // `darkbloom benchmark --sweep` decode-bandwidth diagnostic is added (W6).
    // Submodule pin advanced to 5d3bb51b. Additive/omitempty wire fields — fully
    // backward-compatible with the currently-deployed coordinator.
    // 0.6.16 fixes the fleet-wide admission wedge and adds a backend-liveness
    // watchdog. The KV reclaimable-pool self-heal flush (a blocking GPU
    // synchronize) no longer runs on the GlobalKVCacheBudget actor / admission hot
    // path — it moved to a dedicated off-actor KVPoolReclaimer (coalesced and
    // rate-limited, with both on-pressure and proactive sweeps), so a near-miss
    // admission can never serialize every other reservation behind a GPU sync.
    // An in-process backend-liveness watchdog detects a wedged engine (a request
    // admitted but 0 tokens past the pending-timeout window) or a pinned/collapsed
    // KV pool (budget at the floor with 0 successes), reports a truthful heartbeat
    // slot_state ("crashed"/"reloading" instead of a lying "idle"), and
    // self-restarts the engine/model slot to recover. Wire-compatible: only
    // existing slot_state string values are emitted; no protocol changes.
    // 0.6.17 adds the DAR-341 Harmony channel-tag inbound sanitizer + normalized
    // inference `error_reason` classification (jinja_channel_tags /
    // jinja_null_bridge / jinja_template / model_load), so durable telemetry can
    // tell the two indistinguishable gpt-oss 500 modes apart. Wire-compatible:
    // `error_reason` is an optional inference-error field, omitted when nil.
    // 0.7.2 first enabled CBv2 for VLM-loaded Gemma 4 by reconstructing a
    // separate MLXLLM text module over shared arrays. That convention was the
    // source of the historical multi-tree memory/parity complexity.
    // Gemma 4 VLM now owns the canonical `Gemma4TextModel` directly: direct
    // VLM, CBv2, media prefill, and MTP all retain the same module identity.
    // The post-build serveable-headroom guard and stale-reservation cleanup
    // remain defense in depth; no protocol change is required.
    // 0.7.5 is the ONE-ENGINE release: every request — text, image, video,
    // mixed — on every slot serves through ContinuousBatchingV2, and the
    // legacy BatchScheduler engine is DELETED from the binary (~15k lines
    // across provider + mlx-swift-lm: scheduler, v1 BatchedEngine, batched
    // KV caches, legacy compiled decode, B=1 fast paths, adaptive prefill,
    // KV-quant schemes, checkpoint capture + encrypted on-disk KV tier).
    // What replaced each piece:
    //   * Multi-model co-residency: KV grants are RE-SLICED at every
    //     load/unload (EngineV2KVSizing.resliceGrants over runtime-resizable
    //     engine ceilings; single-model boxes keep the full budget) —
    //     the postmortem's silent-legacy-fallback-at-batch-4 class is
    //     structurally impossible.
    //   * Fail loud, never fall back: engine construction failure or
    //     media-prefill failure is an ERROR engine_v2_refusal /
    //     engine_v2_vision_refusal + retriable 503; the coordinator's
    //     pre-content failover reroutes invisibly. The supported set is
    //     architecture-derived at scan time (EngineV2SupportedModels) —
    //     unsupported models are never advertised.
    //   * Media: image + video prefill through CBv2 multimodal
    //     (EngineV2VisionPrefill spans per image / per sampled video frame),
    //     media_kind-tagged telemetry.
    //   * Prefix cache: encrypted SSD offload is the only production tier,
    //     ships default-on with no serving-memory carve, and applies the
    //     adoption bound plus effective-token floor to each donation.
    //     DARKBLOOM_PREFIX_CACHE=0 is the single local kill switch.
    //   * Liveness: wedge self-recovery rebuilds the engine over the
    //     retained container with the same grant (drain → rebuild →
    //     swap; 120s cooldown), replacing the legacy self-restart.
    //   * Standalone `darkbloom start --local` serves through the same v2
    //     slot factory; local chat body ceiling raised to 32 MiB.
    //   * Retired knobs WARN loudly: DARKBLOOM_ENGINE_V2(+_MODELS),
    //     DARKBLOOM_COMPILED_DECODE, B=1 fast-path + KV-quant + adaptive-
    //     prefill envs; [backend] engine_v2 /
    //     continuous_batching / adaptive_prefill / legacy_compiled_decode
    //     parse-and-WARN as retired.
    // Rollback is release-level (re-point latest to 0.7.4) — there is no
    // in-binary legacy engine to fall back to. No protocol changes: same
    // WebSocket message types, same BackendSlotCapacity wire shape;
    // max_concurrency now truthfully reports the engine cap (≤ 8, default
    // 4) instead of legacy's 24.
    // 0.7.6 introduced PagedAttention for GPT-OSS; the safety follow-up keeps
    // "auto" contiguous and leaves paged explicit/experimental. Explicit pools
    // eagerly commit only an independently capped physical plan, report pool
    // truth through existing heartbeat fields, and map terminal exhaustion to
    // retryable capacity. VLM slots stay contiguous.
    // 0.7.12 restores exact hybrid-attention SSD prefix reuse through
    // frozen-full tail replay and enforces Gemma tool choices during decoding.
    // Constrained requests advertise an explicit per-model protocol capability
    // so mixed fleets fail closed instead of silently routing to old providers.
    // 0.7.13 adds bounded, privacy-safe cache eligibility and donation outcome
    // snapshots. The optional fields are forward-compatible and never gate
    // registration; strict v2 routing capabilities remain independently validated.
    // 0.7.14 replaces the CBv2 flat 120s request wall with monotonic phase
    // leases (admission-only timeout, prefill/decode progress leases, generous
    // safety ceiling): a request producing tokens is never expired. Terminals
    // carry a typed terminal_cause and reconciled attempt_usage on the wire
    // (optional fields; old coordinators ignore them). Kill-switch:
    // DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT=1 restores the legacy wall.
    // 0.7.15 cuts CBv2 prompt work that was computed and discarded. Prompt
    // chunks no longer build full [B, L, vocab] logits for positions the
    // engine never reads; the final decoder layer keeps full attention and
    // every K/V write but evaluates only the frontier row; and equal-length
    // text chunks execute as ONE rectangular [B, L] forward instead of B
    // separate ones, which is what fixes concurrent-burst TTFT. Decode is
    // untouched: the compiled [B, 1] path and MTP verification never enter
    // the prompt seam, and packing disengages for any model or cache
    // provider that does not vouch for per-row independence. Measured on
    // Gemma 4 26B-A4B QAT 4-bit (M4 Max): TTFT -15%/-20%/-19% at
    // 128/512/2048 tokens and -25% for a 4x512 burst, decode within noise,
    // exact output invariance held. Kill switches:
    // DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS=0 and
    // DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY=0; the opt-in mixed-step prefill
    // quota is DARKBLOOM_CBV2_MIXED_PREFILL_CAP.
    //
    // 0.8.0 — PagedAttention. The paged KV backend reaches parity with
    // contiguous: prefix reuse at an identical bound on both gemma-4
    // (25,600) and gpt-oss (1,536), packed prefill and vision spans ACTIVE,
    // per-sequence KV 1.00x at 1k/10k/100k, and 1.27x aggregate decode from
    // B=4 to B=8 where contiguous gains only 1.07x. The ring is 65 pages.
    // `.auto` RESOLVES PAGED — the release's headline change. On the two
    // models production actually serves (gemma-4-26B-A4B-it-qat and
    // gpt-oss-20b-MXFP4-Q8) paged prefix-cache ADOPTION is exact and
    // CONTIGUOUS is the arm that diverges from its own cold decode; the
    // reverse holds only on gemma-4-e2b-it-4bit, an e2e fixture that
    // appears zero times in the catalog. KNOWN AND ACCEPTED: gemma-4
    // greedy token ids differ from contiguous — closer to an fp32
    // reference, but different. Roll back fleet-wide with
    // DARKBLOOM_CBV2_PAGED_KV=0 (degrades, never refuses) or per slot
    // with engine_v2_kv_backend = "contiguous". See
    // `case .auto: resolvedKind` in `EngineV2Factory+Production.swift`.
    //
    // The box-wide concurrency default DOES move 4 -> 8, and stands on
    // its own: contiguous gains ~1.07x from B=4 to B=8. A `provider.toml`
    // written before v0.8.0 carries the generated
    // `engine_v2_max_concurrent = 4`; it is raised once, warned about,
    // and stamped with `config_version`.
    // Note gemma-4 greedy token ids differ under
    // paged — measurably more accurate against an fp32 reference, but not
    // identical. kv-quantization and the compiled [B,1] decode path are
    // removed; `kv_quant` is accepted and ignored via RetiredCodingKeys.
    //
    // 0.8.1 — `.auto` RESOLVES CONTIGUOUS again. v0.8.0's paged default
    // sized the fleet's KV at 1,137 GiB against contiguous's 11,453 GiB
    // (the paged pool is the min of five terms, and `liveKVHeadroom / 4`
    // structurally pins it to a quarter of the logical grant), and the
    // resulting admission failures — 32.7% of provider attempts returning
    // token_budget_exhausted, TTFT p95 12.8s / p99 33s, ~8.8% of client
    // requests cancelled before first token, OpenRouter-scored uptime near
    // 85% — dominate paged's batch-curve and adoption-exactness wins. Costs
    // ~15% aggregate decode at B=8 on gemma-4/M4 Max, knowingly. The
    // exactness loss is CLOSED, not accepted: the SSD prefix cache is no
    // longer constructed on a resolved-contiguous slot, so no prefix is
    // staged, matched or adopted where adoption diverges. Paged code, the
    // DARKBLOOM_CBV2_PAGED_KV kill switch, the crash-loop guard and the
    // blocking paged CI lane all stay; `engine_v2_kv_backend = "paged"`
    // still resolves paged. The box-wide concurrency default returns to 4
    // with contiguous. The v0.8.1 migration preserves an existing 8 only for
    // an explicitly paged config, and 8 remains the supported upper bound for
    // operator and per-model overrides.
    //
    // 0.8.2 adds the benchmark-retained Gemma 4 optimization stack: layer-18
    // lazy prefill submission plus the coupled weighted-unsort/safe-R1 path,
    // both default-on and durably rollbackable through provider config. VLM,
    // CBv2, media prefill, and MTP share the canonical Gemma text tower, and
    // serve/benchmark startup projects config before the first MLX access.
    // 0.8.3 adds Qwen3.6-35B-A3B text, image, and tool serving with request-owned
    // recurrent/mRoPE state and exact serial verification of its inline MTP.
    // Unsupported Qwen paths remain fail-closed pending dedicated canaries.
    // 0.8.4 streams Qwen3.6 reasoning deltas immediately: the engine
    // synthesizes the template's pre-opened <think> so the streaming parser
    // stops buffering the whole block (TTFT was 755ms + 12.5ms per
    // reasoning token; now first-token latency).
    // 0.8.5 ships the Qwen3.6 speed stack: E=256 expert-tile prefill route
    // (+15% at 8k with trust) with fused gate_up, MTP GDN capture-verify +
    // target_prefix + single-forward drafts (1.13x, behind the mtp beta
    // flag), symlink-proof inline-MTP inspection, MTP /metrics counters,
    // and hardened plaintext egress paths.
    // 0.8.6 ships the default-on CBv2 prefill stack: expert-tile trust
    // serving default, solo-prefill stripe (2048), Qwen prompt narrowing,
    // and packed prefill — 8k cold prefill -27.6% (~1,766 tok/s, +38%) and
    // 4x8k aggregate +13-17% vs 0.8.5 defaults; plus the opt-in mean-TTFT
    // partial-prefill cap and adaptive persistent-history MTP (mtp beta).
    // 0.8.7 restores the Qwen3.5/3.6 late-system-message normalizer that
    // shipped from the v0.8.5 release branch but was absent from master and
    // therefore v0.8.6. Text-only system turns are folded into Qwen's required
    // leading system slot; structured/media system content remains fail-closed.
    // 0.8.8 enables the merged upstream qmv_wide route automatically for
    // generation-15+ affine small-M projections. M=1 remains on ordinary QMV,
    // matrix-sized inputs remain on QMM, and gathered expert projections are
    // unchanged. Existing Gemma and CBv2 default-on optimization postures stay
    // enabled; no beta flag or provider-config migration is required.
    public static let version = "0.8.8"
}
