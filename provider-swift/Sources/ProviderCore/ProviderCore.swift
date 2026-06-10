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
    public static let version = "0.6.1"
}
