// Copyright © 2026 Eigen Labs.
//
// Per-model video caps for the Qwen3VL-family builds: how many frames a clip
// samples and how many visual tokens a request's clips share.

import Foundation
import MLXLMCommon
import MLXLMServer

extension MediaIngest {

    /// A request's video caps: each clip samples at most `frames` frames (the
    /// processor's 2 fps), and the request's clips share `visualTokens` visual
    /// tokens, one per 32x32 px of a temporal pair of frames.
    struct VideoBudget: Equatable, Sendable {
        let frames: Int
        let visualTokens: Int
    }

    /// The clip pixels (frames x height x width) of one Qwen3VL-family visual
    /// token: a 32x32 px merged patch of two frames.
    static let qwenVideoPixelsPerToken = 32 * 32 * 2

    /// The Qwen3VL-family builds' video caps, in the timestamped layout of
    /// Transformers' `Qwen3VLVideoProcessor` (a `<t.t seconds>` label and a
    /// vision block per frame pair). The coordinator's condenser sends at most
    /// 64 keyframes.
    static let qwenVideoBudget = VideoBudget(frames: 64, visualTokens: 8_192)

    /// Video caps by served model id. Other models keep their processor's
    /// defaults (Qwen3VL: 8 frames, about 1,024 visual tokens).
    static let modelVideoBudget: [String: VideoBudget] = [
        "Qwen3.5-9B": qwenVideoBudget,
        "qwen3.5-35b-a3b": qwenVideoBudget,
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": qwenVideoBudget,
        "EigenLabs/Qwen3.8-27B-4bit-mtp": qwenVideoBudget,
    ]

    static let videoFramesEnvironmentKey = "DARKBLOOM_QWEN_VIDEO_MAX_FRAMES"
    static let videoTokensEnvironmentKey = "DARKBLOOM_QWEN_VIDEO_MAX_TOKENS"

    /// Override bounds. Frames stop at the reference's 768; tokens at twice the
    /// reference's 12,288, so a clip with its timestamps stays inside the
    /// `visionTokensPerVideo` KV reservation.
    static let videoFramesOverrideRange = 1 ... 768
    static let videoTokensOverrideRange = 256 ... 24_576

    /// The video caps of `model`'s requests, if it has any. A valid
    /// `DARKBLOOM_QWEN_VIDEO_MAX_FRAMES` / `_MAX_TOKENS` replaces that cap.
    static func videoBudget(
        forModel model: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VideoBudget? {
        guard let budget = model.flatMap({ modelVideoBudget[$0] }) else { return nil }
        func override(_ key: String, in range: ClosedRange<Int>) -> Int? {
            environment[key].flatMap { Int($0) }.flatMap { range.contains($0) ? $0 : nil }
        }
        return VideoBudget(
            frames: override(videoFramesEnvironmentKey, in: videoFramesOverrideRange)
                ?? budget.frames,
            visualTokens: override(videoTokensEnvironmentKey, in: videoTokensOverrideRange)
                ?? budget.visualTokens)
    }

    /// The processor caps for `request`'s clips: its model's frame cap, and its
    /// token budget shared by every video part. Without a budget, the processor
    /// keeps its defaults.
    static func videoProcessing(
        for request: OpenAIChatCompletionRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserInput.VideoProcessing {
        guard let budget = videoBudget(forModel: request.model, environment: environment) else {
            return .init()
        }
        var videoCount = 0
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if case .videoURL = part { videoCount += 1 }
            }
        }
        let tokens = max(1, budget.visualTokens / max(1, videoCount))
        return .init(maxFrames: budget.frames, maxPixels: tokens * qwenVideoPixelsPerToken)
    }
}
