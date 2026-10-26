import Foundation

/// Why the coordinator handler refused a request as a client error, before its
/// inference task started or while its prompt was prepared. A closed, log-only
/// vocabulary: the `inference_error` frame does not carry it, and no value
/// holds request text. Public only because the public
/// `MultiModelBatchSchedulerEngineError.invalidToolPayload` carries it.
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

    /// The reason a request was refused as a client error while its prompt was
    /// prepared or admitted to the engine, or nil when the refusal names none
    /// and keeps the bare category line.
    init?(promptRefusal error: any Error) {
        guard let engineError = error as? MultiModelBatchSchedulerEngineError else { return nil }
        switch engineError {
        case .invalidToolPayload(_, let refusal?): self = refusal
        case .invalidRole: self = .unsupportedMessageRole
        case .unsupportedReasoningEffort, .unsupportedNativeReasoningEffort: self = .unsupportedReasoningControl
        case .advertisedContextExceeded: self = .requestExceedsContext
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
