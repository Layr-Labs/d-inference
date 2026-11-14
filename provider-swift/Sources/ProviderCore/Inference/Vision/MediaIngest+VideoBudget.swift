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

    /// Qwen 3.8 27B's video caps, in the timestamped layout of Transformers'
    /// `Qwen3VLVideoProcessor` (a `<t.t seconds>` label and a vision block per
    /// frame pair). On 120 VGI-Bench questions with long videos condensed to 32
    /// keyframes (M5 Ultra, reasoning off) it answered 50% against 41% for
    /// 0.10.13's 8 frames, at 2.6 s to the first token against 0.7 s; 8,192
    /// tokens took 4.7 s for 51%, too slow for the first-content deadline on
    /// slower Macs.
    static let qwen38VideoBudget = VideoBudget(frames: 32, visualTokens: 4_096)

    /// The A3B MoE and 9B builds prefill about 2.5 times as fast as Qwen 3.8, so
    /// twice the tokens cost them less time than Qwen 3.8's budget.
    static let qwenFastPrefillVideoBudget = VideoBudget(frames: 32, visualTokens: 8_192)

    /// Video caps by served model id. Other models keep their processor's
    /// defaults (Qwen3VL: 8 frames, about 1,024 visual tokens). A clip the
    /// coordinator condenses to K keyframes plays them at 1 fps, so its labels
    /// count keyframes (0.5 s, 2.5 s, ...), not seconds of the source video.
    static let modelVideoBudget: [String: VideoBudget] = [
        "EigenLabs/Qwen3.8-27B-4bit-mtp": qwen38VideoBudget,
        "Qwen3.5-9B": qwenFastPrefillVideoBudget,
        "qwen3.5-35b-a3b": qwenFastPrefillVideoBudget,
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": qwenFastPrefillVideoBudget,
    ]

    static let qwenVideoFramesEnvironmentKey = "DARKBLOOM_QWEN_VIDEO_MAX_FRAMES"
    static let qwenVideoTokensEnvironmentKey = "DARKBLOOM_QWEN_VIDEO_MAX_TOKENS"

    /// Override bounds: at most the coordinator condenser's 64 keyframes and
    /// 16,384 tokens, so even a 200:1 clip, whose short side the resize keeps at
    /// 32 px, stays inside the `visionTokensPerVideo` KV reservation.
    static let qwenVideoFramesOverrideRange = 1 ... 64
    static let qwenVideoTokensOverrideRange = 256 ... 16_384

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
        let frames = override(qwenVideoFramesEnvironmentKey, in: qwenVideoFramesOverrideRange)
        let tokens = override(qwenVideoTokensEnvironmentKey, in: qwenVideoTokensOverrideRange)
        return VideoBudget(
            frames: frames ?? budget.frames, visualTokens: tokens ?? budget.visualTokens)
    }

    /// The processor caps for `request`'s clips: its model's frame cap, and its
    /// token budget shared by the video parts of user messages (the media
    /// `buildUserInput` keeps). Nil without a budget: the processor keeps its
    /// defaults.
    static func videoProcessing(
        for request: OpenAIChatCompletionRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserInput.VideoProcessing? {
        guard let budget = videoBudget(forModel: request.model, environment: environment) else {
            return nil
        }
        var videoCount = 0
        for message in request.messages where message.role == .user {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if case .videoURL = part { videoCount += 1 }
            }
        }
        let tokens = max(1, budget.visualTokens / max(1, videoCount))
        return .init(maxFrames: budget.frames, maxPixels: tokens * qwenVideoPixelsPerToken)
    }
}
