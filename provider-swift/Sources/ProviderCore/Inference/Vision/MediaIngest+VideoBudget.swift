// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

extension MediaIngest {

    struct VideoBudget: Equatable, Sendable {
        let frames: Int
        let visualTokens: Int
    }

    static let videoFramesOverrideRange = 1 ... 768
    static let videoTokensOverrideRange = 256 ... 24_576

    static func videoBudget(
        forModel model: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VideoBudget? {
        nil
    }

    static func videoProcessing(
        for request: OpenAIChatCompletionRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserInput.VideoProcessing {
        .init()
    }
}
