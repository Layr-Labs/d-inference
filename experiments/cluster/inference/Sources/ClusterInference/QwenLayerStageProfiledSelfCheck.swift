import Foundation
import MLX

/// Both lengths use chunk512, including a one-token tail and all sixteen 8K
/// frames. Each parity request starts fresh; model weights remain resident only
/// within one dtype fixture. This function reads no performance clock.
func runQwenLayerStageProfiledSelfCheck(options: Options,
    arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt, check: () throws -> Void
) throws {
    try validateQwenLayerStageProfiledCheckOptions(options)
    struct EnvironmentRecord: Encodable {
        let kind = "qwen_layer_stage_profiled_fixture_environment", correctnessOnly = true
        let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
        let profile = QwenLayerStagePrefillProfile.longPrefill8KV1
        let promptCounts = [1025, 8192], chunkSize = 512, outputCount = 1
        let syntheticDTypes = ["float32", "bfloat16"]
        let throughputMeasurementValid = false
    }
    try emitJSON(EnvironmentRecord(arithmeticEnvironment: arithmeticEnvironment))
    for dtype in ["float32", "bfloat16"] {
        try autoreleasepool {
            var fixtureOptions = options; fixtureOptions.syntheticDType = dtype
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-stage-profiled-check-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try QwenLayerStageFixture(options: fixtureOptions, directory: directory,
                fp16FFNMetadata: false, wrapped: dtype == "bfloat16",
                prefillProfile: .longPrefill8KV1, check: check)
            let proof = try QwenLayerStageLoaderCheck(fixture: fixture, check: check)
            try emitJSON(proof.completeLoaderProof(check: check))
            try emitJSON(checkQwenLayerStageProfiledLifecycle(fixture: fixture, proof: proof, check: check))
            for promptCount in [1025, 8192] {
                try emitJSON(checkQwenLayerStageProfiledParity(fixture: fixture, proof: proof,
                    promptCount: promptCount, check: check))
            }
        }
        Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try check()
    }
}
