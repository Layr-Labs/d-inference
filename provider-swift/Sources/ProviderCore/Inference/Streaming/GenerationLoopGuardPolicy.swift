// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Which chat requests get a loop guard (`GenerationLoopGuard`).
///
/// On by default for the families whose answers were seen repeating verbatim
/// to their cap: Gemma 4, Qwen 3.5/3.6/3.8 (and Flash-Next), GPT-OSS,
/// Nemotron 3.5 Lightning and Super, GLM-5.3 and MiMo. Super's text requests
/// take the owner's own route, which resolves the same guard from its request
/// plan (`NemotronSuperRequestPlan.loopGuard()`). One Mac's image and video
/// requests (`EngineV2VisionPrefill`) take the same rule as text; the pairs'
/// media routes, MiMo's native media and Super's media pass none.
/// Off for every other family (diffusion Gemma, exact Flint, Bonsai,
/// Qwen3-VL), and for any request whose output is a constrained or JSON value:
/// a token constraint, a forced tool call, or a JSON `response_format`.
///
/// `DARKBLOOM_LOOP_GUARD`: unset, `1` or `on` keeps the default list; `0` or
/// `off` turns the guard off; any other value is the comma-separated list of
/// `model_type`s to guard instead.
enum GenerationLoopGuardPolicy {
    static let environmentKey = "DARKBLOOM_LOOP_GUARD"

    static let defaultModelTypes: Set<String> = [
        "gemma4", "gemma4_text",
        "qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text",
        "gpt_oss",
        "nemotron_h", "nemotron_h_omni",
        "glm5_next",
        "mimo_v2",
    ]

    /// Text that opens a tool call in any served family's output (Qwen, GLM,
    /// MiMo, Nemotron, Gemma 4, Harmony). The request's own parser adds its tags.
    static let genericToolCallMarkers = [
        "<tool_call>", "<|tool_call>", "<function=", "to=functions.", "<start_function_call>",
    ]

    enum Setting: Sendable, Equatable {
        case off
        case modelTypes(Set<String>)
    }

    static let current = setting(environment: ProcessInfo.processInfo.environment)

    static func setting(environment: [String: String]) -> Setting {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .modelTypes(defaultModelTypes) }
        switch raw.lowercased() {
        case "1", "on", "true": return .modelTypes(defaultModelTypes)
        case "0", "off", "false": return .off
        default:
            let types = Set(raw.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return types.isEmpty ? .off : .modelTypes(types)
        }
    }

    /// The guard for one text, image or video request, or nil when it must not have one.
    static func resolve(
        modelType: String?,
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        tokenConstraint: (any CBv2TokenConstraint)?,
        setting: Setting = current,
        thresholds: GenerationLoopDetector.Thresholds = .init(),
        exitThinking: GenerationLoopExitThinking? = nil
    ) -> GenerationLoopGuard? {
        guard case .modelTypes(let enabled) = setting,
              let modelType = modelType?.lowercased(), enabled.contains(modelType) else { return nil }
        guard tokenConstraint == nil, !prepared.requiresToolCall,
              prepared.responseFormat == nil, prepared.glmResponseFormat == nil,
              request.responseFormat?.requiresJSONOutput != true else { return nil }
        var markers = genericToolCallMarkers
        // MiMo parses calls even without declared tools (`ToolStreamPreparation`).
        if prepared.tools?.isEmpty == false || modelType == "mimo_v2" {
            // A parser that also reads a call without any tag (bare JSON, or a
            // function name then JSON) leaves no marker to stop at.
            guard let format = try? ServerToolParser.resolve(
                requested: request.toolCallParser, modelType: modelType) else { return nil }
            let parser = format.createParser()
            guard !parser.supportsBareJSON, !parser.supportsMarkerlessNamedJSON else { return nil }
            markers += [parser.startTag].compactMap { $0 } + parser.alternateStartTags
        }
        return GenerationLoopGuard(
            modelType: modelType, toolCallMarkers: markers, thresholds: thresholds, exitThinking: exitThinking)
    }
}
