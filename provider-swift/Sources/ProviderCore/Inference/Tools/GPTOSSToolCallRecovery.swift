// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// GPT-OSS calls the Harmony parser does not see, for an `auto` request that
/// declares tools. Two shapes, each recovered only when it is a whole,
/// declared and valid call:
///
/// - **Arguments as the answer.** After the loop guard ended the analysis
///   (`GenerationLoopExitThinking.harmonyAnalysis`), the model sometimes
///   answers in the next message without a recipient: the final (or a
///   recipientless commentary) message is the call's JSON object and nothing
///   else. The answer after the exit is held to the end of generation; when it
///   is a single JSON object that exactly one declared tool admits (every key
///   a declared property, and the caller's schema holds:
///   `ToolConstraintValidation.breaksDeclaration`), it leaves as a call to
///   that tool instead. Anything else leaves as it was written.
/// - **A call frame inside the analysis.** The model sometimes writes its
///   call as text inside an analysis message it never closes, and generation
///   stops right after it. When the open analysis ends with a complete frame,
///   `to=functions.<name>`, its header and `<|message|>`, then one JSON object
///   and nothing else, for a declared function whose schema holds the
///   arguments, it leaves as that call. A partial frame never does.
///
/// vLLM returns both as text (or nothing). Neither changes a rendered prompt.
///
/// `DARKBLOOM_GPTOSS_TOOL_CALL_RECOVERY`: unset or any other value keeps it on;
/// `0`, `off`, `false` or `no` turns it off. Read once per process.
struct GPTOSSToolCallRecovery: Sendable {
    static let environmentKey = "DARKBLOOM_GPTOSS_TOOL_CALL_RECOVERY"
    static let enabled = isEnabled(environment: ProcessInfo.processInfo.environment)

    static func isEnabled(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[environmentKey])
    }

    /// The most visible text kept for the analysis check: a frame is a header
    /// and one argument object.
    static let tailLimit = 16_384

    private static let startMarker = "<|start|>assistant"
    private static let analysisOpener = "<|channel|>analysis<|message|>"
    private static let messageMarker = "<|message|>"
    private static let messageEnds = ["<|end|>", "<|return|>", "<|call|>"]

    private let prepared: ToolChoicePromptPolicy.Prepared
    private let loopExit: GenerationLoopExitRecord?
    /// The answer after the loop guard's exit, held to the end of generation.
    private var held: [MLXServerGenerationEvent] = []
    private var heldText = ""
    /// The last `tailLimit` characters of the visible text.
    private var tail = ""
    /// A call or delta already left: nothing is recovered.
    private var sawCall = false

    /// The recovery for a request, or nil where it does not apply: GPT-OSS's
    /// Harmony call parser, `auto` with declared tools.
    static func make(
        modelType: String?, format: ToolCallFormat?, prepared: ToolChoicePromptPolicy.Prepared,
        loopExit: GenerationLoopExitRecord?, enabled: Bool = true
    ) -> GPTOSSToolCallRecovery? {
        guard enabled, modelType == "gpt_oss", format == .harmony, prepared.mode == .auto,
              !prepared.allowedToolNames.isEmpty, prepared.tools?.isEmpty == false else { return nil }
        return GPTOSSToolCallRecovery(prepared: prepared, loopExit: loopExit)
    }

    init(prepared: ToolChoicePromptPolicy.Prepared, loopExit: GenerationLoopExitRecord?) {
        self.prepared = prepared
        self.loopExit = loopExit
    }

    /// Red control: nothing is held and no call is recovered.
    mutating func route(_ event: MLXServerGenerationEvent) -> [MLXServerGenerationEvent] { [event] }

    mutating func finish(stopReason: String, cutAtLimit: Bool, hasCalls: Bool)
        -> (call: ToolCall?, release: [MLXServerGenerationEvent]) { (nil, []) }

    static func answerCall(afterExit text: String, prepared: ToolChoicePromptPolicy.Prepared) -> ToolCall? { nil }

    static func analysisCall(_ text: String, prepared: ToolChoicePromptPolicy.Prepared) -> ToolCall? { nil }

    /// `<|channel|>final` or `<|channel|>commentary`, with no recipient, an
    /// optional `json` or `<|constrain|>json` content type.
    private static func isAnswerHeader(_ header: Substring) -> Bool {
        guard !header.contains("to=") else { return false }
        var rest = header.trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("<|channel|>") else { return false }
        rest.removeFirst("<|channel|>".count)
        for channel in ["final", "commentary"] where rest.hasPrefix(channel) {
            return isContentType(rest.dropFirst(channel.count))
        }
        return false
    }

    /// What may follow the function name in a call header: an optional
    /// `<|channel|>commentary` and an optional content type.
    private static func isCallHeaderRest(_ rest: Substring) -> Bool {
        var rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("<|channel|>") {
            rest.removeFirst("<|channel|>".count)
            guard rest.hasPrefix("commentary") else { return false }
            rest.removeFirst("commentary".count)
        }
        return isContentType(Substring(rest))
    }

    private static func isContentType(_ text: Substring) -> Bool {
        let type = text.replacingOccurrences(of: "<|constrain|>", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return type.isEmpty || type == "json"
    }

    /// The text as one JSON object and nothing else (surrounding whitespace
    /// aside).
    private static func jsonObject(_ text: Substring) -> [String: MLXLMCommon.JSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}" else { return nil }
        return try? JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(trimmed.utf8))
    }

    /// Every key is a declared property and the caller's schema holds.
    private static func admits(_ call: ToolCall, prepared: ToolChoicePromptPolicy.Prepared) -> Bool {
        guard let tool = (prepared.declaredTools ?? prepared.tools)?
            .first(where: { $0.function.name == call.function.name }) else { return false }
        var properties: [String: MLXLMCommon.JSONValue] = [:]
        if case .object(let parameters)? = tool.function.parameters,
           case .object(let declared)? = parameters["properties"] {
            properties = declared
        }
        guard call.function.arguments.keys.allSatisfy({ properties[$0] != nil }) else { return false }
        return !ToolConstraintValidation.breaksDeclaration(call, prepared: prepared)
    }
}
