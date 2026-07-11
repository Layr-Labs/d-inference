// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Runtime gate for the installed provider artifact. Release packaging runs
/// this through the staged app executable before publication.
public enum PackagedRuntimeSmoke {
    public static let pagedCapabilityRelativePath =
        "Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
    public static let mlxLMCommonBundleName =
        "mlx-swift-lm_MLXLMCommon.bundle"

    public static func runPagedKernel(
        shapes: [PagedAttentionKernelSmokeShape] =
            PagedAttentionKernel.gptOSSRuntimeSmokeShapes
    ) throws {
        try PagedAttentionKernel.runtimeSmoke(shapes: shapes)
    }

    public static func runPagedKernel(arguments: [String]) throws {
        let shapes = try arguments.isEmpty
            ? PagedAttentionKernel.gptOSSRuntimeSmokeShapes
            : arguments.map(PagedAttentionKernelSmokeShape.init(argumentValue:))
        try runPagedKernel(shapes: shapes)
    }
}
