import Foundation
import MLXLMServer

/// The native template exposes a binary thinking switch, not effort levels.
/// An explicit positive effort must enable that switch; absence keeps the
/// checkpoint default. Never inherit Qwen's default-on assumption.
enum DiffusionGemmaReasoningControl {
    /// Same precedence as the template renderer; the native checkpoint defaults
    /// thinking off. Output routing must not expose unexpected thought text when
    /// that request-level switch is off, even on a failed generation.
    static func enabled(for request: OpenAIChatCompletionRequest, controls: ChatTemplateControls) -> Bool {
        request.reasoning?.enabled ?? controls.enableThinking
            ?? enabled(for: request.reasoning?.effort ?? controls.reasoningEffort) ?? false
    }

    static func enabled(for effort: String?) -> Bool? {
        guard let effort else { return nil }
        switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "off", "0": return false
        case "minimal", "low", "medium", "high", "xhigh": return true
        default: return nil
        }
    }

    static func validate(request: OpenAIChatCompletionRequest,
        controls: ChatTemplateControls, modelType: String?) throws
    {
        guard modelType == "diffusion_gemma",
            request.reasoning?.enabled == nil, controls.enableThinking == nil,
            let effort = request.reasoning?.effort ?? controls.reasoningEffort
        else { return }
        guard enabled(for: effort) != nil else {
            throw MultiModelBatchSchedulerEngineError.unsupportedNativeReasoningEffort
        }
    }
}
