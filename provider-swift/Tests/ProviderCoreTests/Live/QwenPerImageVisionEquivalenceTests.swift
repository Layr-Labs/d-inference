// Copyright © 2026 Eigen Labs.
//
// The correctness argument for the v0.8.7 vision fix is one claim: driving the
// Qwen3-VL tower once per image produces the same features as driving it once
// over the concatenated patch stream. Attention is block-diagonal per image
// and every other stage is per-token or per-grid, so the cross-image half of
// the mask was always zeros doing nothing — but "always zeros" is an argument,
// and this is the measurement.
//
// Live-gated on real weights (the tower cannot be exercised without them),
// following the same env gates as the Qwen3.6 production canary:
//
//   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_QWEN36=1 swift test \
//     --filter QwenPerImageVisionEquivalence
//
// Override the artifact paths with DARKBLOOM_LIVE_MLX_QWEN36_MODEL_PATH and
// DARKBLOOM_LIVE_MLX_QWEN36_IMAGE_PATH.

import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

private enum QwenVisionEquivalenceFixture {
    static let modelPathOverride = "DARKBLOOM_LIVE_MLX_QWEN36_MODEL_PATH"
    static let imagePathOverride = "DARKBLOOM_LIVE_MLX_QWEN36_IMAGE_PATH"
    static let defaultModelPath =
        "/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/opencode/"
        + "Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp-work"
    static let defaultImagePath =
        "/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/opencode/qwen36-vlm-proof.png"

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return LiveInferenceFixtures.gateValueEnabled(
            environment["DARKBLOOM_LIVE_MLX_TESTS"])
            && LiveInferenceFixtures.gateValueEnabled(
                environment["DARKBLOOM_LIVE_MLX_QWEN36"])
    }

    static var modelDirectory: URL {
        URL(
            fileURLWithPath: ProcessInfo.processInfo.environment[modelPathOverride]
                ?? defaultModelPath,
            isDirectory: true
        ).standardizedFileURL
    }

    static var imageURL: URL {
        URL(
            fileURLWithPath: ProcessInfo.processInfo.environment[imagePathOverride]
                ?? defaultImagePath,
            isDirectory: false
        ).standardizedFileURL
    }
}

@Suite("QwenPerImageVisionEquivalence", .serialized)
struct QwenPerImageVisionEquivalenceTests {

    @Test(
        "per-image tower features match the batched ones for a multi-image request",
        .enabled(
            if: QwenVisionEquivalenceFixture.enabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_QWEN36=1 to run the real-artifact Qwen vision equivalence check")
    )
    func perImageMatchesBatched() async throws {
        #expect(LiveInferenceFixtures.ensureMetallibColocated() != nil)
        let container = try await ModelContainerLoading.loadContainer(
            from: QwenVisionEquivalenceFixture.modelDirectory)

        // Three copies of the canary image: enough for the concatenated stream
        // to differ from any single image, small enough to run anywhere.
        let imageData = try Data(contentsOf: QwenVisionEquivalenceFixture.imageURL)
        let ciImage = try #require(CIImage(data: imageData))
        let userInput = UserInput(
            chat: [.user("describe these", images: (0 ..< 3).map { _ in .ciImage(ciImage) })])

        try await container.perform(nonSendable: userInput) { ctx, userInput in
            let wrapper = try #require(
                ctx.model as? MLXVLM.Qwen35MoE,
                "the live artifact must load as Qwen35MoE for this check to mean anything")
            let lmInput = try await ctx.processor.prepare(input: userInput)
            let image = try #require(lmInput.image, "processor produced no image pixels")
            let grids = try #require(image.frames, "processor produced no image grids")
            #expect(grids.count == 3)

            // The path the provider used to take: one tower call, every image
            // concatenated.
            let batched = try wrapper.visionFeatures(
                imagePixels: image.pixels, imageGrids: grids
            ).ordered.map(\.features)
            eval(batched)

            // The path it takes now.
            let perImage = try MLX.withError { (box: MLX.ErrorBox) in
                try EngineV2VisionPrefill.qwenPerImageVisionFeatures(
                    wrapper: wrapper,
                    pixels: image.pixels,
                    grids: grids,
                    towerLimits: VisionTowerBudget.liveLimits,
                    mlxErrors: box)
            }

            #expect(perImage.count == batched.count)
            for (index, (lhs, rhs)) in zip(perImage, batched).enumerated() {
                #expect(lhs.shape == rhs.shape, "image \(index) shape")
                let delta = MLX.abs(
                    lhs.asType(.float32) - rhs.asType(.float32)
                ).max().item(Float.self)
                // Bitwise equality is not promised: SDPA's reduction shape
                // changes with N, so float reduction order can differ. A
                // tolerance well inside bf16's ~3-decimal-digit resolution is
                // the strongest claim that survives that.
                #expect(delta < 5e-3, "image \(index) max abs delta \(delta)")
            }
        }
    }

    @Test(
        "the head factor read from the live config matches MLX's kernel rule",
        .enabled(
            if: QwenVisionEquivalenceFixture.enabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_QWEN36=1 to inspect the real vision config")
    )
    func headFactorMatchesTheLiveConfig() async throws {
        let container = try await ModelContainerLoading.loadContainer(
            from: QwenVisionEquivalenceFixture.modelDirectory)
        try await container.perform { ctx in
            let wrapper = try #require(ctx.model as? MLXVLM.Qwen35MoE)
            let vision = wrapper.config.visionConfiguration
            let headDim = vision.hiddenSize / max(1, vision.numHeads)
            let factor = EngineV2VisionPrefill.qwenAttentionHeadFactor(wrapper)
            // Documents whichever the shipping checkpoint actually is, and
            // fails loudly if the two ever disagree.
            if VisionTowerBudget.fusedAttentionHeadDims.contains(headDim) {
                #expect(factor == 1, "head dim \(headDim) is fusable but factor is \(factor)")
            } else {
                #expect(
                    factor == vision.numHeads,
                    "head dim \(headDim) is not fusable but factor is \(factor)")
            }
        }
    }
}
