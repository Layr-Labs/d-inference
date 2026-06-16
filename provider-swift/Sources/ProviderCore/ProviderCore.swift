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
    public static let version = "0.6.11"
}
