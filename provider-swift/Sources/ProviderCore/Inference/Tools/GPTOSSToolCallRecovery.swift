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

    /// The events to send now. Visible text after the loop guard's exit is
    /// held; a call releases what is held, in order, before itself.
    mutating func route(_ event: MLXServerGenerationEvent) -> [MLXServerGenerationEvent] {
        switch event {
        case .content(let text):
            tail += text
            if tail.count > Self.tailLimit { tail = String(tail.suffix(Self.tailLimit)) }
            guard !sawCall, loopExit?.requested != nil else { return [event] }
            held.append(event)
            heldText += text
            return []
        case .toolCall, .toolCallDelta:
            sawCall = true
            defer { held = []; heldText = "" }
            return held + [event]
        default:
            return [event]
        }
    }

    /// End of generation: the recovered call, or nil with the held events to
    /// send as they were. Only an answer that ended with a stop and has no
    /// call recovers one.
    mutating func finish(stopReason: String, cutAtLimit: Bool, hasCalls: Bool)
        -> (call: ToolCall?, release: [MLXServerGenerationEvent])
    {
        defer { held = []; heldText = "" }
        guard !sawCall, !hasCalls, !cutAtLimit, stopReason == "stop" else { return (nil, held) }
        if loopExit?.requested != nil, !heldText.isEmpty {
            if let call = Self.answerCall(afterExit: heldText, prepared: prepared) { return (call, []) }
            return (nil, held)
        }
        if let call = Self.analysisCall(tail, prepared: prepared) { return (call, held) }
        return (nil, held)
    }

    // MARK: - The two shapes

    /// The call an answer after the exit spells: its last message, a `final`
    /// or recipientless `commentary` header and a single JSON object, that
    /// exactly one declared tool admits.
    static func answerCall(afterExit text: String, prepared: ToolChoicePromptPolicy.Prepared) -> ToolCall? {
        guard let opener = text.range(of: messageMarker, options: .backwards),
              let channel = text[..<opener.lowerBound].range(of: "<|channel|>", options: .backwards)
        else { return nil }
        // The message starts there: the exit's assistant start precedes its channel.
        guard text[..<channel.lowerBound].hasSuffix(startMarker) else { return nil }
        guard isAnswerHeader(text[channel.lowerBound..<opener.lowerBound]),
              let arguments = jsonObject(text[opener.upperBound...]), !arguments.isEmpty else { return nil }
        let matches = prepared.allowedToolNames.sorted().compactMap { name -> ToolCall? in
            let call = ToolCall(function: .init(name: name, arguments: arguments))
            return admits(call, prepared: prepared) ? call : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The call a still-open analysis message ends with: the text after its
    /// last recipient, `to=functions.<name>`, is the rest of a call header,
    /// `<|message|>` and a single JSON object, for a declared function whose
    /// schema holds it.
    static func analysisCall(_ text: String, prepared: ToolChoicePromptPolicy.Prepared) -> ToolCall? {
        guard let analysis = text.range(of: analysisOpener, options: .backwards) else { return nil }
        let body = text[analysis.upperBound...]
        // The analysis is still open: no message end and no new message after it.
        guard messageEnds.allSatisfy({ !body.contains($0) }), !body.contains("<|start|>") else { return nil }
        guard let recipient = body.range(of: "to=functions.", options: .backwards) else { return nil }
        let frame = body[recipient.upperBound...]
        guard let opener = frame.range(of: messageMarker) else { return nil }
        let head = frame[..<opener.lowerBound]
        let name = String(head.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        guard !name.isEmpty, prepared.allowedToolNames.contains(name),
              isCallHeaderRest(head.dropFirst(name.count)),
              let arguments = jsonObject(frame[opener.upperBound...]) else { return nil }
        let call = ToolCall(function: .init(name: name, arguments: arguments))
        return admits(call, prepared: prepared) ? call : nil
    }

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
