import Foundation

/// Closed, privacy-safe inference failure vocabulary shared with the
/// coordinator. Raw `Error` descriptions must never cross the provider's
/// process boundary: they can contain prompt fragments, media URIs, tool-call
/// identifiers, template source, or generated output.
public enum InferenceFailureCode: String, Codable, Sendable, Equatable, CaseIterable {
    case invalidRequest = "invalid_request"
    case invalidMedia = "invalid_media"
    case mediaTooLarge = "media_too_large"
    case unsupportedMedia = "unsupported_media"
    case templateRender = "template_render"
    case modelUnavailable = "model_unavailable"
    case capacity
    case cancelled
    case encryptionFailure = "encryption_failure"
    case generationFailure = "generation_failure"
    case internalFailure = "internal_failure"

    /// Fixed legacy `error` text. This remains on the wire for older
    /// coordinators, but is derived solely from the closed code above.
    public var message: String {
        switch self {
        case .invalidRequest:
            return "Invalid inference request."
        case .invalidMedia:
            return "Invalid media input."
        case .mediaTooLarge:
            return "Media input is too large."
        case .unsupportedMedia:
            return "Media input is not supported."
        case .templateRender:
            return "Unable to render the inference template."
        case .modelUnavailable:
            return "Requested model is unavailable."
        case .capacity:
            return "Provider capacity is temporarily unavailable."
        case .cancelled:
            return "Request cancelled."
        case .encryptionFailure:
            return "Inference encryption failed."
        case .generationFailure:
            return "Inference generation failed."
        case .internalFailure:
            return "Internal inference failure."
        }
    }
}

/// Existing bounded diagnostic classification, now typed so a caller cannot
/// accidentally place arbitrary request-derived text in `error_reason`.
public enum InferenceErrorReason: String, Codable, Sendable, Equatable, CaseIterable {
    case jinjaChannelTags = "jinja_channel_tags"
    case jinjaNullBridge = "jinja_null_bridge"
    case jinjaTemplate = "jinja_template"
    case modelLoad = "model_load"
    case capacityTimeout = "capacity_timeout"
    case queueFull = "queue_full"
    case tokenBudgetExhausted = "token_budget_exhausted"
    /// Request-local media preparation could not finish on this machine now
    /// (no memory to reserve, a transient decoder fault, a spent decode
    /// allowance). No inference engine terminal is implied; mirrors the
    /// coordinator protocol constant.
    case mediaMemoryUnavailable = "media_memory_unavailable"
    case requestExceedsContext = "request_exceeds_context"
    case requestExceedsNode = "request_exceeds_node"
    case requestExceedsNodeBudget = "request_exceeds_node_budget"
    case requestExceedsBatchTokenBudget = "request_exceeds_batch_token_budget"
    case capacityBusy = "capacity_busy"
    case deadlineUnreachable = "deadline_unreachable"
    case cancelled
    case clientError = "client_error"
    case toolNoncompliance = "tool_noncompliance"
    /// The provider is refusing new work for an update drain / shutdown.
    /// Distinct from `capacityBusy` so the coordinator can skip the box
    /// without derating the (provider, model) pair or spending the request's
    /// capacity retries. Wire string mirrors coordinator/protocol/messages.go.
    case draining
}

/// Which check a `tool_noncompliance` failure failed, so production can tell
/// them apart. A closed vocabulary like `InferenceErrorReason`: it names the
/// check, never the tool, the arguments or the generated text.
public enum ToolNoncomplianceCheck: String, Codable, Sendable, Equatable, CaseIterable {
    /// A call to a function the request did not declare.
    case undeclaredName = "undeclared_name"
    /// Arguments that do not satisfy the declared parameters schema.
    case schema
    /// A streamed call whose frame closed with arguments that do not parse.
    case malformed
    /// A streamed call that parsed differently from what was already sent.
    case diverged
    /// A streamed call still open when generation stopped (not at the token limit).
    case unterminated
    /// A second call when `parallel_tool_calls` is false.
    case parallel
    /// An answer that fails the request's `response_format`.
    case responseFormat = "response_format"
    /// `tool_choice` none, required or named not honored: a call, no call,
    /// the wrong call or visible text where only a call may stand.
    case forcedChoice = "forced_choice"
    /// A native-channel family's own frame or reasoning check.
    case nativeOutput = "native_output"
    case other
}

/// The only value accepted by provider-to-coordinator inference error sinks.
/// It contains closed enums and bounded numeric/accounting metadata, never a
/// raw `Error`, URL, path, prompt, response, template, or tool identifier.
public struct InferenceFailure: Sendable, Equatable {
    public let code: InferenceFailureCode
    public let statusCode: UInt16
    public let errorReason: InferenceErrorReason?
    public let terminalCause: InferenceTerminalCause?
    public let attemptUsage: UsageInfo?
    /// Routing-v2 enriched capacity rejection (all nil away from the
    /// capacity-shaped live-gate paths; omitted on the wire when nil so the
    /// legacy frame shape is untouched). Stamped by
    /// `CapacityRejectionEnrichment.enrich` at the ProviderLoop's
    /// capacity-shaped rejection sites, from the published capacity snapshot
    /// so every rejection is also a fresh state sample for the coordinator's
    /// ledger/clamp/taxonomy.
    public let rejectionReason: CapacityRejectionReason?
    public let availableTokenBudget: Int64?
    public let feasibleAfterMs: Int64?
    public let capacitySeq: UInt64?
    /// The check behind a `tool_noncompliance` reason; nil for every other one.
    public let toolCheck: ToolNoncomplianceCheck?
    /// Why a client refusal refused the request; nil for every other failure.
    public internal(set) var refusal: InferenceRefusalReason?

    public init(
        code: InferenceFailureCode,
        statusCode: UInt16,
        errorReason: InferenceErrorReason? = nil,
        terminalCause: InferenceTerminalCause? = nil,
        attemptUsage: UsageInfo? = nil,
        rejectionReason: CapacityRejectionReason? = nil,
        availableTokenBudget: Int64? = nil,
        feasibleAfterMs: Int64? = nil,
        capacitySeq: UInt64? = nil,
        toolCheck: ToolNoncomplianceCheck? = nil,
        refusal: InferenceRefusalReason? = nil
    ) {
        self.code = code
        self.statusCode = statusCode
        self.errorReason = errorReason
        self.terminalCause = terminalCause
        self.attemptUsage = attemptUsage
        self.rejectionReason = rejectionReason
        self.availableTokenBudget = availableTokenBudget
        self.feasibleAfterMs = feasibleAfterMs
        self.capacitySeq = capacitySeq
        self.toolCheck = toolCheck
        self.refusal = refusal
    }

    public var message: String { code.message }
}

enum InferenceFailurePhase: Sendable, Equatable {
    case request
    case modelLoad
    case streamStart
    case generation
}

/// A narrow logger for inference failures. The production initializer emits a
/// fixed public category plus a private diagnostic line containing the request
/// ID and bounded wire classifications. Tests may inject the private sink.
/// There is deliberately no overload accepting `Error` or a free-form detail.
struct InferenceFailureLogger: Sendable {
    private let privateSink: @Sendable (String) -> Void
    private let publicSink: @Sendable (ProviderOperationalMessage) -> Void

    init(logger: ProviderLogger) {
        self.privateSink = { logger.error($0) }
        self.publicSink = { logger.error($0) }
    }

    init(sink: @escaping @Sendable (String) -> Void) {
        self.privateSink = sink
        self.publicSink = { _ in }
    }

    /// A client refusal (`failure.refusal`), before the request's inference
    /// task or while its prompt was prepared, publishes its fixed reason in
    /// place of the bare failure category.
    func record(requestId: String, failure: InferenceFailure) {
        guard let refusal = failure.refusal else {
            publicSink(ProviderOperationalMessage(failureCode: failure.code))
            privateSink(Self.privateLine(requestId: requestId, failure: failure))
            return
        }
        publicSink(ProviderOperationalMessage(refusal: refusal))
        privateSink(Self.privateLine(requestId: requestId, failure: failure) + " refusal=\(refusal.rawValue)")
    }

    private static func privateLine(requestId: String, failure: InferenceFailure) -> String {
        var line = "[\(requestId)] inference failure code=\(failure.code.rawValue)"
            + " status=\(failure.statusCode)"
        if let reason = failure.errorReason {
            line += " reason=\(reason.rawValue)"
        }
        if let cause = failure.terminalCause {
            line += " terminal_cause=\(cause.rawValue)"
        }
        if let check = failure.toolCheck {
            line += " tool_check=\(check.rawValue)"
        }
        return line
    }
}

private extension ProviderOperationalMessage {
    init(failureCode: InferenceFailureCode) {
        self = switch failureCode {
        case .invalidRequest: .inferenceFailureInvalidRequest
        case .invalidMedia: .inferenceFailureInvalidMedia
        case .mediaTooLarge: .inferenceFailureMediaTooLarge
        case .unsupportedMedia: .inferenceFailureUnsupportedMedia
        case .templateRender: .inferenceFailureTemplateRender
        case .modelUnavailable: .inferenceFailureModelUnavailable
        case .capacity: .inferenceFailureCapacity
        case .cancelled: .inferenceFailureCancelled
        case .encryptionFailure: .inferenceFailureEncryption
        case .generationFailure: .inferenceFailureGeneration
        case .internalFailure: .inferenceFailureInternal
        }
    }

    init(refusal: InferenceRefusalReason) {
        self = switch refusal {
        case .missingSenderKey: .refusalMissingSenderKey
        case .undecryptableRequest: .refusalUndecryptableRequest
        case .reservedToolSchemaMetadata: .refusalReservedToolSchemaMetadata
        case .malformedBody: .refusalMalformedBody
        case .invalidMessages: .refusalInvalidMessages
        case .unsupportedMessageRole: .refusalUnsupportedMessageRole
        case .invalidToolHistory: .refusalInvalidToolHistory
        case .invalidToolArguments: .refusalInvalidToolArguments
        case .invalidToolDeclaration: .refusalInvalidToolDeclaration
        case .invalidToolChoice: .refusalInvalidToolChoice
        case .unsupportedResponseFormat: .refusalUnsupportedResponseFormat
        case .invalidRequestField: .refusalInvalidRequestField
        case .unsupportedReasoningControl: .refusalUnsupportedReasoningControl
        case .contradictoryReasoningControls: .refusalContradictoryReasoningControls
        case .unsupportedToolType: .refusalUnsupportedToolType
        case .invalidToolSchema: .refusalInvalidToolSchema
        case .unsupportedAudio: .refusalUnsupportedAudio
        case .unansweredToolCall: .refusalUnansweredToolCall
        case .unmatchedToolResult: .refusalUnmatchedToolResult
        case .nativeDelimiterInHistory: .refusalNativeDelimiterInHistory
        case .nonTextContent: .refusalNonTextContent
        case .unsupportedForcedToolChoice: .refusalUnsupportedForcedToolChoice
        case .requestExceedsContext: .refusalRequestExceedsContext
        case .unsupportedOutputControl: .refusalUnsupportedOutputControl
        case .missingUserQuery: .refusalMissingUserQuery
        }
    }
}
