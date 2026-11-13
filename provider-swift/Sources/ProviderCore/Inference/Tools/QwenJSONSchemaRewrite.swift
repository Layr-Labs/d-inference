// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

enum QwenJSONSchemaRewrite {
    static let environmentKey = "DARKBLOOM_QWEN_JSON_SCHEMA_REWRITE"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    enum Widening: Equatable, Sendable {
        case rewritten
        case relaxed
        case object
    }

    static func isEnabled(_ value: String?) -> Bool { true }

    static func answerFormat(_ format: OpenAIResponseFormat, profile: JSONAnswerProfile, widens: Bool)
        -> (format: JSONAnswerFormat, widening: Widening?)? {
        guard let exact = try? JSONAnswerFormat(format, forbidding: profile.contentMarkers, family: profile.family)
        else { return nil }
        return (exact, nil)
    }
}
