import MLXLMCommon

extension PackagedRuntimeSmoke {
    public static let qwen4MetalSuccessMarker = "qwen4-metal-resources-runtime-smoke: ok"

    /// Loads every native Qwen4 Metal preamble through the same accessor used
    /// by inference, from the final app rather than the CI build directory.
    public static func verifyQwen4MetalResources() throws {
        try Qwen4ExpMetalHeaders.validateResources()
        _ = Qwen4ExpMetalHeaders.gemm
        _ = Qwen4ExpMetalHeaders.quantizedUtils
        _ = Qwen4ExpMetalHeaders.quantized
    }
}
