import Foundation

/// Why the coordinator handler refused a request before its inference task
/// started. A closed, log-only vocabulary: the `inference_error` frame does
/// not carry it, and no value holds request text.
enum InferenceRefusalReason: String, CaseIterable, Sendable, Equatable {
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
