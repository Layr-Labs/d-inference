import MLXLMCommon

import MLXLLM

enum PagedKernelPreflight {
    typealias Runner =
        ([PagedAttentionKernelSmokeShape]) throws -> Void

    static func run(
        layerKinds: [CBv2LayerKind],
        runner: Runner? = nil
    ) throws {
        let shapes = PagedAttentionKernel.smokeShapes(
            layerKinds: layerKinds)
        try (runner ?? {
            try PagedAttentionKernel.runtimeSmoke(shapes: $0)
        })(shapes)
    }
}
