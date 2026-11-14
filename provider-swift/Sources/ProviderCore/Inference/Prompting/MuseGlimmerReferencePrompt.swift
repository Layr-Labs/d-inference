// Copyright © 2026 Eigen Labs.
//
// Muse Glimmer's prompt as its reference servers (Transformers, vLLM) render
// it. The template writes a full system block (strength line, tool
// definitions, recipients) for every system message, and its default block
// (helpful-assistant line, knowledge cutoff, current date) only when no
// message is a system message. So:
//
// - Tool declarations render as the caller sent them. The ingress repair's
//   render types (`ToolSchemaNormalization`) are for other templates: this one
//   only writes each schema as JSON, so the repair would tell the model that a
//   `$ref` parameter is a string and show it the repair's marker key.
// - A request with a `developer` message has its system messages merged into
//   one leading block, as vLLM merges them.
// - An instruction the service adds (the JSON `response_format` instruction,
//   `tool_choice: none`, the system half of a forced choice) is appended to
//   the caller's leading system message, else to the last user turn. A new
//   system message would replace the default block, or add a second block.
//
// `DARKBLOOM_MUSE_GLIMMER_REFERENCE_PROMPT`: `0`, `off` or `false` renders the
// earlier prompt. The coordinator's prompt sidecar renders the same contract
// for providers that report `muse_glimmer_v1`.

import Foundation
import MLXLMServer
import ProviderCoreFoundation

enum MuseGlimmerReferencePrompt {
    static let environmentKey = "DARKBLOOM_MUSE_GLIMMER_REFERENCE_PROMPT"

    static let current = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "off", "false"].contains(raw ?? "")
    }

    /// Whether injected instructions for `modelType` are appended rather than
    /// sent as a new system message.
    static func appendsInstructions(modelType: String?, enabled: Bool = current) -> Bool {
        enabled && MuseGlimmerModelPolicy.isModelType(modelType)
    }

    /// `request` as the reference servers render it, for Muse Glimmer only:
    /// the caller's tool declarations, merged system messages when the body
    /// has a `developer` message, and the service's JSON `response_format`
    /// instruction appended. Every other model, and Muse with the switch off,
    /// keeps `request`.
    static func restoring(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
        modelType: String?, enabled: Bool = current
    ) -> OpenAIChatCompletionRequest {
        guard appendsInstructions(modelType: modelType, enabled: enabled) else { return request }
        var copy = request
        if copy.tools != nil, let original = callerTools(controls) { copy.tools = original }
        var messages = request.messages
        let instruction = removingResponseFormatInstruction(from: &messages, request: request)
        if controls.hasDeveloperMessage { messages = consolidatingSystemMessages(messages) }
        if let instruction { messages = appendingInstruction(instruction, to: messages) }
        copy.messages = messages
        return copy
    }

    /// The body's own declarations. Nil keeps the decoded ones: the body had
    /// none, they did not decode, or they carry the ingress repair's reserved
    /// metadata (a coordinator that repaired them before forwarding). The
    /// existing admission check then decides whether that metadata is trusted.
    private static func callerTools(_ controls: ChatTemplateControls) -> [OpenAITool]? {
        guard let tools = controls.declaredTools,
              (try? ToolConstraintValidation.rejectReservedSchemaMetadata(
                  tools, allowInternalSchemaMetadata: false)) != nil
        else { return nil }
        return tools
    }

    /// vLLM's merge (`safe_apply_chat_template`): every system message's text,
    /// in order and joined by a blank line, becomes one leading system message
    /// when there is more than one or one that is not first. A list content's
    /// text parts are joined by a newline; empty texts are dropped.
    static func consolidatingSystemMessages(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        let systems = messages.indices.filter { messages[$0].role == .system }
        guard systems.count > 1 || systems.first.map({ $0 > 0 }) == true else { return messages }
        let text = systems.compactMap { index -> String? in
            let content: String
            switch messages[index].content {
            case .text(let value): content = value
            case .parts(let parts):
                content = parts.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
            case .null: content = ""
            }
            return content.isEmpty ? nil : content
        }.joined(separator: "\n\n")
        return [OpenAIChatMessage(role: .system, content: .text(text))]
            + messages.filter { $0.role != .system }
    }

    /// `instruction` appended to the leading system message, else to the last
    /// user turn, after a blank line. With neither, it becomes the leading
    /// system message, as for every other model.
    static func appendingInstruction(
        _ instruction: String, to messages: [OpenAIChatMessage]
    ) -> [OpenAIChatMessage] {
        var messages = messages
        if messages.first?.role == .system {
            append(instruction, to: &messages[0])
        } else if let user = messages.lastIndex(where: { $0.role == .user }) {
            append(instruction, to: &messages[user])
        } else {
            messages.insert(OpenAIChatMessage(role: .system, content: .text(instruction)), at: 0)
        }
        return messages
    }

    /// A forced choice's instruction, which every other model writes into the
    /// leading system message (inserting one) and the last user turn: here
    /// into the leading system message only when the caller sent one.
    static func forcingInstruction(
        _ instruction: String, in messages: [OpenAIChatMessage]
    ) -> [OpenAIChatMessage] {
        guard let user = messages.lastIndex(where: { $0.role == .user }) else {
            return appendingInstruction(instruction, to: messages)
        }
        var messages = messages
        if messages.first?.role == .system { append(instruction, to: &messages[0]) }
        append(instruction, to: &messages[user])
        return messages
    }

    private static func append(_ instruction: String, to message: inout OpenAIChatMessage) {
        switch message.content {
        case .text(let text): message.content = .text(text.isEmpty ? instruction : text + "\n\n" + instruction)
        case .parts(var parts):
            // Parts render joined without a separator.
            parts.append(.text(parts.isEmpty ? instruction : "\n\n" + instruction))
            message.content = .parts(parts)
        case .null: message.content = .text(instruction)
        }
    }

    /// Removes the instruction `OpenAIResponseFormatSupport.preparedRequest`
    /// inserted for a JSON `response_format`, a system message after the
    /// leading system messages, and returns its text. Nil when the request
    /// asks for no JSON output or the message is not there (the callers that
    /// count tokens from the body never insert it).
    private static func removingResponseFormatInstruction(
        from messages: inout [OpenAIChatMessage], request: OpenAIChatCompletionRequest
    ) -> String? {
        guard request.responseFormat?.requiresJSONOutput == true else { return nil }
        var bare = request
        bare.messages = []
        guard let inserted = try? OpenAIResponseFormatSupport.preparedRequest(bare).messages,
              inserted.count == 1, case .text(let instruction) = inserted[0].content
        else { return nil }
        let leading = messages.firstIndex { $0.role != .system } ?? messages.endIndex
        guard leading > 0, messages[leading - 1].content == .text(instruction) else { return nil }
        messages.remove(at: leading - 1)
        return instruction
    }
}

extension ChatTemplateControls {
    /// The decoded request as the loaded model's own prompt contract takes
    /// it: MiMo's and Muse Glimmer's original tool declarations, and Muse
    /// Glimmer's reference messages (`MuseGlimmerReferencePrompt`). Every
    /// caller that renders a request for a known model type goes through it.
    func restoringOriginalRequest(
        _ request: OpenAIChatCompletionRequest, modelType: String?,
        museReferencePrompt: Bool = MuseGlimmerReferencePrompt.current
    ) throws -> OpenAIChatCompletionRequest {
        MuseGlimmerReferencePrompt.restoring(
            try rawMiMoTools.restoring(request, modelType: modelType), controls: self,
            modelType: modelType, enabled: museReferencePrompt)
    }
}
