// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMServer

/// Every exact-id LFM2.5 request refusal, in one place for the three gates
/// (pre-accept on the coordinator path, pre-acquire on the local engine, and
/// the prompt-contract pipeline). Reasoning controls are checked first.
enum LFM2RequestPolicy {
    static func validate(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls) throws {
        try LFM2ReasoningControlPolicy.validate(request: request, controls: controls)
        try LFM2ResponseFormatPolicy.validate(request: request)
    }
}
