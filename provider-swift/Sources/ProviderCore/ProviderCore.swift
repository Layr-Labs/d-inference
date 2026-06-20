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
    public static let version = "0.6.17"
}
