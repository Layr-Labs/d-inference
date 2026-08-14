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
    case requestExceedsContext = "request_exceeds_context"
    case requestExceedsNode = "request_exceeds_node"
    case requestExceedsNodeBudget = "request_exceeds_node_budget"
    case requestExceedsBatchTokenBudget = "request_exceeds_batch_token_budget"
    case capacityBusy = "capacity_busy"
    case cancelled
    case clientError = "client_error"
    case toolNoncompliance = "tool_noncompliance"
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

    public init(
        code: InferenceFailureCode,
        statusCode: UInt16,
        errorReason: InferenceErrorReason? = nil,
        terminalCause: InferenceTerminalCause? = nil,
        attemptUsage: UsageInfo? = nil
    ) {
        self.code = code
        self.statusCode = statusCode
        self.errorReason = errorReason
        self.terminalCause = terminalCause
        self.attemptUsage = attemptUsage
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
    private let publicSink: @Sendable (InferenceFailureCode) -> Void

    init(logger: ProviderLogger) {
        self.privateSink = { logger.error($0) }
        self.publicSink = { code in
            logger.error(ProviderOperationalMessage(failureCode: code))
        }
    }

    init(sink: @escaping @Sendable (String) -> Void) {
        self.privateSink = sink
        self.publicSink = { _ in }
    }

    func record(requestId: String, failure: InferenceFailure) {
        publicSink(failure.code)

        var line = "[\(requestId)] inference failure code=\(failure.code.rawValue)"
            + " status=\(failure.statusCode)"
        if let reason = failure.errorReason {
            line += " reason=\(reason.rawValue)"
        }
        if let cause = failure.terminalCause {
            line += " terminal_cause=\(cause.rawValue)"
        }
        privateSink(line)
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
}
