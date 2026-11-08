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

    /// Every effort but `none` thinks (`ReasoningEffort.oneDepthThinking`); nil
    /// names no effort (`ReasoningEffortPolicy.validate` refuses it).
    static func enabled(for effort: String?) -> Bool? {
        effort.flatMap(ReasoningEffort.init(clientValue:))?.oneDepthThinking
    }
}
