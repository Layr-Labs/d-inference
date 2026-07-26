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
    // 0.7.2 lets engine_v2 (continuous batching) serve TEXT requests on
    // allowlisted VLM-loaded Gemma 4 slots. Every prod Gemma 4 checkpoint
    // ships a vision tower, so it loads via VLMModelFactory and the per-slot
    // isVLM gate previously kept 100% of Gemma traffic on the legacy engine.
    // The slot factory now extracts the CBv2-adapted MLXLLM text model over
    // the SAME weight arrays (zero extra weight memory) and serves text
    // through v2; image/video requests keep the legacy VLM path. No protocol
    // change — capability is behavioral, gated by the existing engine_v2
    // allowlist + flag.
    // 0.7.3 fixes the v0.7.2 black-hole incident: the VLM text extraction's
    // two module trees each lazily built their own multi-GiB SwitchGLU fused
    // gate+up expert cache at the load-time parity probe (~15 GiB × 2 on
    // gemma-4-26b-8bit), pushing 64 GB (8-bit) and 36 GB (qat-4bit) boxes
    // past the 90% unified-memory cap so the shared KV gate rejected every
    // request forever. The trees now share ONE fused cache
    // (SwitchGLU.shareFusedGateUpCache); the load path re-checks serveable
    // KV headroom AFTER the engine build and unloads instead of advertising
    // a dead model; and GlobalKVCacheBudget audits + drops stale
    // reservations under sustained full-rejection (defense in depth). No
    // protocol changes.
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
    // `.auto` STAYS CONTIGUOUS. The flip to paged was made and then
    // reverted before release: paged ADOPTION is not transparent.
    // Measured on gemma-4 at a 28,672-token prompt, one process, one
    // paged slot, paged cold is deterministic (byte-identical across
    // runs) but paged ADOPTED diverges from its own cold output at token
    // 20 of 32 — same prompt, same config, a different answer depending
    // on cache state the caller cannot see. Contiguous adoption is exact
    // in every arm. That is disqualifying for a default and acceptable
    // for an opt-in, so paged stays available per-slot via
    // engine_v2_kv_backend = "paged"; re-flip when paged adopted ==
    // paged cold on that prompt. Grep `case .auto: resolvedKind` in
    // `EngineV2Factory+Production.swift` for the live answer.
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
    public static let version = "0.8.0"
}
