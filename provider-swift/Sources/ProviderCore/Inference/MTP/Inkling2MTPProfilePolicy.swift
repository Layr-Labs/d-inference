// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon

/// Red control: the names the tests use, with the base's behaviour (Inkling's
/// profile always drafts up to 7 and nothing reads the environment).
public enum Inkling2MTPProfilePolicy {
    public static let maxDraftKey = "DARKBLOOM_INKLING_MTP_MAX_DRAFT"
    public static let defaultMaxDraftTokens = 7

    public struct MaxDraft: Equatable, Sendable {
        public let tokens: Int
        public let unrecognized: String?
    }

    public static func maxDraftTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MaxDraft {
        MaxDraft(tokens: defaultMaxDraftTokens, unrecognized: nil)
    }

    public static func engineConfig(maxDraft: MaxDraft) -> CBv2MTPConfig {
        Inkling2DSparkDrafter.defaultMTPConfig()
    }
}
