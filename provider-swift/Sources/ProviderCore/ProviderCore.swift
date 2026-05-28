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
    public static let version = "0.5.12"
}
