// Copyright © 2026 Eigen Labs.
//
// The Qwen3VL-family builds' video caps (frames and a shared visual-token
// budget per request) and the tower gate's per-temporal-group admission.
// Pure arithmetic plus a seam stub: no GPU, no weights, no network.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import MLXVLM
@testable import ProviderCore

@Suite("Qwen video budget")
struct QwenVideoBudgetTests {

    static let qwenBuilds = [
        "Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
        "EigenLabs/Qwen3.8-27B-4bit-mtp",
    ]

    static func request(model: String, videos: Int) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: model,
            messages: [
                .init(
                    role: .user,
                    content: .parts(
                        (0 ..< videos).map { _ in OpenAIContentPart.videoURL("data:video/mp4;base64,AA==") }
                            + [.text("What happens?")]))
            ])
    }

    @Test("the four Qwen builds sample 32 frames under one 4,096-token budget")
    func qwenBuildsDefault() throws {
        for model in Self.qwenBuilds {
            let processing = try #require(
                MediaIngest.videoProcessing(
                    for: Self.request(model: model, videos: 1), environment: [:]))
            #expect(processing.maxFrames == 32, "\(model) frames")
            #expect(processing.maxPixels == 4_096 * 2_048, "\(model) clip pixels")
            #expect(processing.sampling == nil, "\(model) keeps the reference 2 fps")
        }
    }

    @Test("the clips the request places share its token budget")
    func clipsShareTheBudget() throws {
        var request = Self.request(model: "Qwen3.5-9B", videos: 4)
        let processing = try #require(MediaIngest.videoProcessing(for: request, environment: [:]))
        #expect(processing.maxFrames == 32)
        #expect(processing.maxPixels == 1_024 * 2_048, "4,096 tokens / 4 clips")
        // An assistant turn's video is placed too (`MediaIngest.everyRoleEnabled`):
        // it takes a share.
        request.messages.append(
            .init(role: .assistant, content: .parts([.videoURL("data:video/mp4;base64,AA==")])))
        let five = try #require(MediaIngest.videoProcessing(for: request, environment: [:]))
        if MediaIngest.everyRoleEnabled {
            #expect(five.maxPixels == (4_096 / 5) * 2_048, "4,096 tokens / 5 clips")
        } else {
            #expect(five == processing, "DARKBLOOM_MEDIA_ON_EVERY_ROLE off: the assistant video is dropped")
        }
    }

    @Test("other models keep their processor's defaults")
    func otherModelsUntouched() {
        for model in ["gemma-4-26b-qat-4bit", "nvidia-nemotron-3.5-super", "vlm", ""] {
            #expect(
                MediaIngest.videoProcessing(
                    for: Self.request(model: model, videos: 1), environment: [:]) == nil,
                "\(model)")
        }
    }

    @Test("valid overrides replace each cap; others are ignored")
    func environmentOverrides() {
        let model = "Qwen3.5-9B"
        let both = MediaIngest.videoBudget(
            forModel: model,
            environment: [
                "DARKBLOOM_QWEN_VIDEO_MAX_FRAMES": "64", "DARKBLOOM_QWEN_VIDEO_MAX_TOKENS": "16384",
            ])
        #expect(both == .init(frames: 64, visualTokens: 16_384))
        for (frames, tokens) in [("0", "255"), ("65", "16385"), ("x", ""), ("-8", "1e4")] {
            let ignored = MediaIngest.videoBudget(
                forModel: model,
                environment: [
                    "DARKBLOOM_QWEN_VIDEO_MAX_FRAMES": frames,
                    "DARKBLOOM_QWEN_VIDEO_MAX_TOKENS": tokens,
                ])
            #expect(ignored == .init(frames: 32, visualTokens: 4_096), "\(frames) / \(tokens)")
        }
        #expect(
            MediaIngest.videoBudget(
                forModel: "gemma-4-26b-qat-4bit",
                environment: ["DARKBLOOM_QWEN_VIDEO_MAX_FRAMES": "32"]) == nil,
            "an override does not give other models a budget")
    }

    @Test("a service Mac's provider job receives both overrides")
    func overridesReachTheLaunchdJob() {
        for key in ["DARKBLOOM_QWEN_VIDEO_MAX_FRAMES", "DARKBLOOM_QWEN_VIDEO_MAX_TOKENS"] {
            #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key), "\(key)")
        }
    }

    @Test("every allowed clip fits the per-video KV reservation")
    func budgetFitsTheReservation() throws {
        // The resize keeps each side at least 32 px, so a 200:1 clip can
        // exceed a small pixel budget. Price extreme and ordinary shapes at the
        // largest frame count; per frame pair the prompt adds a
        // `<ddd.d seconds>` label (8 tokens) and two vision delimiters.
        let frames = MediaIngest.qwenVideoFramesOverrideRange.upperBound
        let pairs = (frames + 1) / 2
        var overshoot = false
        for tokens in [256, 1_024, 4_096, MediaIngest.qwenVideoTokensOverrideRange.upperBound] {
            for (height, width) in [(32, 6_400), (6_400, 32), (64, 6_400), (720, 1_280)] {
                let size = try Qwen4ExpMediaGeometry.video(
                    frames: frames, height: height, width: width, temporalFactor: 2, factor: 32,
                    minPixels: 4_096, maxPixels: tokens * MediaIngest.qwenVideoPixelsPerToken)
                let visual = pairs * (size.height / 32) * (size.width / 32)
                overshoot = overshoot || visual > tokens
                #expect(
                    visual + pairs * 10 <= MediaIngest.visionTokensPerVideo,
                    "\(tokens) tokens, \(height) x \(width): \(visual)")
            }
        }
        #expect(overshoot, "a 32 px side overshoots a small budget")
    }
}

@Suite("Qwen video tower gate")
struct QwenVideoTowerGateTests {

    /// Returns zero features of the right shape; records the grids it saw.
    final class SeamStub: QwenVisionSeamModel {
        var seen: [[Int]] = []
        var visionSeamConfiguration: Qwen35VisionSeamConfiguration {
            .init(
                imagePlaceholderTokenId: 248_056, videoPlaceholderTokenId: 248_057,
                imagePositionTokenId: 248_056, videoPositionTokenId: 248_057,
                visionStartTokenId: 248_053, visionEndTokenId: 248_054,
                spatialMergeSize: 2, temporalPatchSize: 2, attention: .causal)
        }
        var imagePlaceholderTokenId: Int { 248_056 }
        var videoPlaceholderTokenId: Int { 248_057 }
        var visionTowerAttentionGeometry: (hiddenSize: Int, numHeads: Int) { (1152, 16) }
        func positionResult(
            tokens: MLXArray, imageGrids: [THW]?, videoGrids: [THW]?, attentionMask: MLXArray?
        ) throws -> Qwen35PositionResult { throw CancellationError() }
        func visionFeatures(
            imagePixels: MLXArray?, imageGrids: [THW]?, videoPixels: MLXArray?, videoGrids: [THW]?
        ) throws -> Qwen35VisionFeatures {
            let grid = videoGrids![0]
            seen.append([grid.t, grid.h, grid.w])
            let group = grid.h * grid.w / 4
            return Qwen35VisionFeatures(
                ordered: (0 ..< grid.t).map {
                    .init(
                        kind: .videoFrame(videoIndex: 0, frameIndex: $0),
                        features: MLXArray.zeros([1, group, 8]))
                },
                flattenedFeatures: MLXArray.zeros([grid.t * group, 8]))
        }
    }

    /// 32 frame pairs of 32x32 patches (a 512x512 frame): 32,768 patches in
    /// the clip, 1,024 in one group.
    let clip = THW(32, 32, 32)

    /// A buffer that holds one group's 16-plane scores (1,024² x 32 B, 32 MiB)
    /// but not the clip's (32,768² x 32 B, 32 GiB).
    var limits: VisionTowerBudget.Limits {
        VisionTowerBudget.Limits(
            maxBufferBytes: 64 << 20, attentionElementBytes: 2, headFactor: 1)
    }

    @Test("a clip is admitted by its largest temporal group, not its whole grid")
    func admitsByGroup() throws {
        let stub = SeamStub()
        let features = try MLX.withError { errors in
            try EngineV2VisionPrefill.qwenPerVideoVisionFeatures(
                wrapper: stub, pixels: MLXArray.zeros([clip.product, 1]), grids: [clip],
                towerLimits: limits, mlxErrors: errors)
        }
        #expect(features.count == 32, "one embedding per frame pair")
        #expect(stub.seen == [[32, 32, 32]], "one tower call over the whole clip")
    }

    @Test("a group over the buffer is still refused")
    func refusesAnOversizedGroup() {
        let stub = SeamStub()
        let wide = THW(2, 64, 64)  // 4,096 patches a group: 512 MiB of scores
        #expect(throws: EngineV2VisionPrefillError.self) {
            try MLX.withError { errors in
                try EngineV2VisionPrefill.qwenPerVideoVisionFeatures(
                    wrapper: stub, pixels: MLXArray.zeros([wide.product, 1]), grids: [wide],
                    towerLimits: limits, mlxErrors: errors)
            }
        }
        #expect(stub.seen.isEmpty, "refused before the tower")
    }
}
