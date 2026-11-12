import Foundation

/// Why the coordinator handler refused a request as a client error, before its
/// inference task started or while its prompt was prepared. A closed
/// vocabulary: no value holds request text. The refusal's `inference_error`
/// frame carries it as `refusal_reason`, beside its fixed `clientMessage` as
/// `refusal_message`, and `darkbloom logs` names it.
public enum InferenceRefusalReason: String, CaseIterable, Sendable, Equatable {
    // The sealed request.
    case missingSenderKey = "missing_sender_key"
    case undecryptableRequest = "undecryptable_request"
    case reservedToolSchemaMetadata = "reserved_tool_schema_metadata"

    // The chat body (`ProviderLoop.decodeInboundChatRequest`).
    case malformedBody = "malformed_body"
    case invalidMessages = "invalid_messages"
    case unsupportedMessageRole = "unsupported_message_role"
    case invalidToolHistory = "invalid_tool_history"
    case invalidToolArguments = "invalid_tool_arguments"
    case invalidToolDeclaration = "invalid_tool_declaration"
    case invalidToolChoice = "invalid_tool_choice"
    case unsupportedResponseFormat = "unsupported_response_format"
    case invalidRequestField = "invalid_request_field"

    // The model's native controls (`ProviderPromptContractPipeline.validateNativeControls`).
    case unsupportedReasoningControl = "unsupported_reasoning_control"
    case contradictoryReasoningControls = "contradictory_reasoning_controls"
    case unsupportedToolType = "unsupported_tool_type"
    case invalidToolSchema = "invalid_tool_schema"

    // Media admission (`MediaIngest.rejectUnsupportedAudio`).
    case unsupportedAudio = "unsupported_audio"

    // Prompt preparation and engine admission (`init(promptRefusal:)`).
    case unansweredToolCall = "unanswered_tool_call"
    case unmatchedToolResult = "unmatched_tool_result"
    case nativeDelimiterInHistory = "native_delimiter_in_history"
    case nonTextContent = "non_text_content"
    case unsupportedForcedToolChoice = "unsupported_forced_tool_choice"
    case requestExceedsContext = "request_exceeds_context"
    case unsupportedOutputControl = "unsupported_output_control"
    case missingUserQuery = "missing_user_query"

    /// One fixed sentence per reason, safe to show the requester: derived from
    /// the reason alone, never from the request.
    public var clientMessage: String {
        switch self {
        case .missingSenderKey: "The request is missing its sender key."
        case .undecryptableRequest: "The request could not be decrypted."
        case .reservedToolSchemaMetadata: "A tool schema uses a reserved metadata key."
        case .malformedBody: "The request body is not a valid chat completion request."
        case .invalidMessages: "A message is malformed or has an unsupported content part."
        case .unsupportedMessageRole: "A message has an unsupported role."
        case .invalidToolHistory: "A tool call in the conversation is malformed."
        case .invalidToolArguments: "A tool call in the conversation has invalid arguments."
        case .invalidToolDeclaration: "A declared tool is malformed or has an invalid name."
        case .invalidToolChoice: "tool_choice is malformed or names an undeclared tool."
        case .unsupportedResponseFormat: "response_format is malformed or not supported for this request."
        case .invalidRequestField: "A request field has an invalid value."
        case .unsupportedReasoningControl: "A reasoning control is not supported by this model."
        case .contradictoryReasoningControls: "The reasoning controls contradict each other."
        case .unsupportedToolType: "A declared tool type is not supported by this model."
        case .invalidToolSchema: "A tool schema cannot be represented for this model."
        case .unsupportedAudio: "Audio input is not supported by this model."
        case .unansweredToolCall: "A tool call in the conversation has no tool result."
        case .unmatchedToolResult: "A tool message does not answer a preceding assistant tool call."
        case .nativeDelimiterInHistory: "The conversation contains this model's reserved tool-call markers."
        case .nonTextContent: "This model accepts only text content here."
        case .unsupportedForcedToolChoice: "The required or named tool_choice cannot be enforced for this request."
        case .requestExceedsContext: "The request does not fit the model's context window."
        case .unsupportedOutputControl: "An output control, such as logprobs, is not supported by this model."
        case .missingUserQuery: "The conversation needs a user message that is more than a tool result."
        }
    }

    /// The reason a request was refused as a client error while its prompt was
    /// prepared or admitted to the engine, or nil when the refusal names none
    /// and keeps the bare category line.
    init?(promptRefusal error: any Error) {
        guard let engineError = error as? MultiModelBatchSchedulerEngineError else { return nil }
        switch engineError {
        case .invalidToolPayload(_, let refusal?): self = refusal
        case .invalidRole: self = .unsupportedMessageRole
        case .unsupportedReasoningEffort: self = .unsupportedReasoningControl
        case .conflictingReasoningEfforts: self = .contradictoryReasoningControls
        case .advertisedContextExceeded, .promptExceedsContext: self = .requestExceedsContext
        case .unsupportedOutputControl: self = .unsupportedOutputControl
        default: return nil
        }
    }

    /// The reason a chat body failed `ProviderLoop.decodeInboundChatRequest`:
    /// its typed error, else the request field the decoding error's path
    /// starts at. The path is read, never logged; below the top level it can
    /// name caller-chosen keys.
    init(chatDecodeFailure error: any Error) {
        if let engineError = error as? MultiModelBatchSchedulerEngineError {
            switch engineError {
            case .invalidRole: self = .unsupportedMessageRole
            // Only a legacy assistant `function_call` throws this while decoding.
            case .invalidToolPayload: self = .invalidToolHistory
            default: self = .malformedBody
            }
            return
        }
        guard let decodingError = error as? DecodingError else {
            self = .malformedBody
            return
        }
        let path = decodingError.failurePath.map(\.stringValue)
        switch path.first {
        case nil:
            self = .malformedBody
        case "messages":
            // Message paths hold only schema keys and array indices.
            if path.contains("tool_calls") {
                self = path.contains("arguments") ? .invalidToolArguments : .invalidToolHistory
            } else {
                self = path.contains("tool_call_id") ? .invalidToolHistory : .invalidMessages
            }
        case "tools": self = .invalidToolDeclaration
        case "tool_choice": self = .invalidToolChoice
        case "response_format": self = .unsupportedResponseFormat
        case "reasoning": self = .unsupportedReasoningControl
        default: self = .invalidRequestField
        }
    }
}

private extension DecodingError {
    /// The coding path to the value that failed, a missing key included.
    var failurePath: [any CodingKey] {
        switch self {
        case .keyNotFound(let key, let context): context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath
        @unknown default: []
        }
    }
}
