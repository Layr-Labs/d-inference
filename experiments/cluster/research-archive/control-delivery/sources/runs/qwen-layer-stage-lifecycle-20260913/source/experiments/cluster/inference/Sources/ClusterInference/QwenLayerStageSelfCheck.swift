import Foundation
import MLX

func runQwenLayerStageSelfCheck(options: Options, check: () throws -> Void) throws {
    for (dtype, wrapped, fp16) in [("float32", false, false),
                                    ("bfloat16", true, false), ("bfloat16", true, true)] {
        try autoreleasepool {
            var fixtureOptions = options
            fixtureOptions.syntheticDType = dtype
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-stage-check-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try QwenLayerStageFixture(options: fixtureOptions, directory: directory,
                fp16FFNMetadata: fp16, wrapped: wrapped, check: check)
            let proof = try QwenLayerStageLoaderCheck(fixture: fixture, check: check)
            try emitJSON(proof.completeLoaderProof(check: check))
            try emitJSON(checkQwenLayerStageParity(fixture: fixture, proof: proof,
                options: fixtureOptions, check: check))
            try emitJSON(checkQwenLayerStageLifecycle(fixture: fixture, proof: proof,
                options: fixtureOptions, check: check))
        }
        Memory.clearCache()
        try check()
    }
}
