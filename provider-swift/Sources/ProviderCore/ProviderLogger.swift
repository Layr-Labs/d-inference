import Foundation
#if canImport(os)
import os
#endif

/// Unified provider logger.
///
/// Free-form `String` messages are private by default. The public overloads
/// accept only `ProviderOperationalMessage`, whose fixed cases are the complete
/// public vocabulary. This prevents request-derived text, URLs, model names,
/// identifiers, or error descriptions from becoming public unified-log data.
/// It is defense in depth for macOS unified logging, not a boundary against a
/// malicious host owner.
///
/// Internal access lets `ProviderLoop` companion files and the coordinator
/// client share the same privacy contract.
struct ProviderLogger: Sendable {
    typealias Sink = @Sendable (ProviderLogLevel, ProviderLogVisibility, String) -> Void

    #if canImport(os)
    private let osLogger: os.Logger
    #endif
    private let category: String
    private let sink: Sink?

    init(subsystem: String, category: String, sink: Sink? = nil) {
        self.category = category
        self.sink = sink
        #if canImport(os)
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
        #endif
    }

    func info(_ message: ProviderOperationalMessage) {
        publicLog(.info, message)
    }

    func warning(_ message: ProviderOperationalMessage) {
        publicLog(.warning, message)
    }

    func error(_ message: ProviderOperationalMessage) {
        publicLog(.error, message)
    }

    func info(_ message: String) {
        privateLog(.info, message)
    }

    func warning(_ message: String) {
        privateLog(.warning, message)
    }

    func error(_ message: String) {
        privateLog(.error, message)
    }

    private func publicLog(_ level: ProviderLogLevel, _ message: ProviderOperationalMessage) {
        if let sink {
            sink(level, .public, message.text)
            return
        }
        #if canImport(os)
        switch level {
        case .info:
            osLogger.info("\(message.text, privacy: .public)")
        case .warning:
            osLogger.warning("\(message.text, privacy: .public)")
        case .error:
            osLogger.error("\(message.text, privacy: .public)")
        }
        #else
        print("[\(category)] \(level.label): \(message.text)")
        #endif
    }

    private func privateLog(_ level: ProviderLogLevel, _ message: String) {
        if let sink {
            sink(level, .private, message)
            return
        }
        #if canImport(os)
        switch level {
        case .info:
            osLogger.info("\(message, privacy: .private)")
        case .warning:
            osLogger.warning("\(message, privacy: .private)")
        case .error:
            osLogger.error("\(message, privacy: .private)")
        }
        #else
        // Match unified-log redaction instead of exposing private text on
        // platforms without os.Logger.
        print("[\(category)] \(level.label): <private>")
        #endif
    }
}

enum ProviderLogLevel: Sendable, Equatable {
    case info
    case warning
    case error

    fileprivate var label: String {
        switch self {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

enum ProviderLogVisibility: Sendable, Equatable {
    case `public`
    case `private`
}

/// Fixed, bounded text that may be exposed by `darkbloom logs`.
///
/// Do not add associated values or `ExpressibleByStringLiteral` conformance:
/// public log text must remain a closed vocabulary.
enum ProviderOperationalMessage: String, CaseIterable, Sendable {
    /// The published text. `{cli}` names this build's command
    /// (`BuildEnvironment.cliName`); no other substitution exists.
    var text: String {
        rawValue.replacingOccurrences(of: "{cli}", with: BuildEnvironment.current.cliName)
    }

    // Startup and shutdown.
    case providerStarting = "Provider starting"
    case startupPreloadInsufficientMemory = "Startup preload skipped: low free memory. Run {cli} status or doctor."
    case coordinatorClientStarted = "Coordinator client started"
    case coordinatorEventStreamEnded = "Coordinator event stream ended; shutting down"

    // Coordinator connection lifecycle.
    case connectingToCoordinator = "Connecting to coordinator"
    case coordinatorConnectionClosed = "Coordinator connection closed; reconnecting"
    case coordinatorConnectionFailed = "Coordinator connection failed; reconnecting"
    case coordinatorClientShutdown = "Coordinator client shut down"
    case coordinatorTransportReady = "Coordinator transport ready; sending registration"
    case coordinatorRegistrationSent = "Coordinator registration sent"
    case coordinatorConnected = "Connected to coordinator"
    case coordinatorDisconnected = "Disconnected from coordinator"
    case coordinatorSendFailed = "Coordinator WebSocket send failed"
    case coordinatorChunkEncodeFailed = "Coordinator chunk encode failed"
    case coordinatorChunkSendFailed = "Coordinator chunk send failed"
    case coordinatorNotRoutingConnection = "Coordinator is not routing work to this connection. Run {cli} status for the reason."
    case coordinatorRoutingConnection = "Coordinator authorizes this connection for work"
    case unauthorizedConnectionReregistering = "Coordinator has not authorized this connection for 15 min; re-registering it"

    // Attestation and integrity lifecycle.
    case attestationChallengeReceived = "Attestation challenge received"
    case attestationIdentityUnavailable = "Attestation identity unavailable"
    case attestationResponseSent = "Attestation challenge response sent"
    case attestationSigningFailed = "Attestation challenge signing failed"
    case codeAttestationSignerUnavailable = "Code-attestation signer unavailable"
    case codeAttestationResponseSent = "Code-attestation challenge response sent"
    case codeAttestationSigningFailed = "Code-attestation challenge signing failed"
    case runtimeIntegrityVerified = "Runtime integrity verified by coordinator"
    case runtimeIntegrityFailed = "Runtime integrity verification failed"

    // Closed inference-failure categories.
    case inferenceFailureInvalidRequest = "Inference failure: invalid request"
    case inferenceFailureInvalidMedia = "Inference failure: invalid media"
    case inferenceFailureMediaTooLarge = "Inference failure: media too large"
    case inferenceFailureUnsupportedMedia = "Inference failure: unsupported media"
    case inferenceFailureTemplateRender = "Inference failure: template render"
    case inferenceFailureModelUnavailable = "Inference failure: model unavailable"
    case inferenceFailureCapacity = "Inference failure: capacity"
    case inferenceFailureCancelled = "Inference failure: cancelled"
    case inferenceFailureEncryption = "Inference failure: encryption"
    case inferenceFailureGeneration = "Inference failure: generation"
    case inferenceFailureInternal = "Inference failure: internal"

    // Closed reasons for client refusals before the inference task or while
    // the prompt is prepared (`InferenceRefusalReason`).
    case refusalMissingSenderKey = "Inference failure: invalid request (missing sender key)"
    case refusalUndecryptableRequest = "Inference failure: invalid request (undecryptable request)"
    case refusalReservedToolSchemaMetadata = "Inference failure: invalid request (reserved tool schema metadata)"
    case refusalMalformedBody = "Inference failure: invalid request (malformed body)"
    case refusalInvalidMessages = "Inference failure: invalid request (invalid messages)"
    case refusalUnsupportedMessageRole = "Inference failure: invalid request (unsupported message role)"
    case refusalInvalidToolHistory = "Inference failure: invalid request (invalid tool history)"
    case refusalInvalidToolArguments = "Inference failure: invalid request (invalid tool arguments)"
    case refusalInvalidToolDeclaration = "Inference failure: invalid request (invalid tool declaration)"
    case refusalInvalidToolChoice = "Inference failure: invalid request (invalid tool choice)"
    case refusalUnsupportedResponseFormat = "Inference failure: invalid request (unsupported response format)"
    case refusalInvalidRequestField = "Inference failure: invalid request (invalid request field)"
    case refusalUnsupportedReasoningControl = "Inference failure: invalid request (unsupported reasoning control)"
    case refusalContradictoryReasoningControls = "Inference failure: invalid request (contradictory reasoning controls)"
    case refusalUnsupportedToolType = "Inference failure: invalid request (unsupported tool type)"
    case refusalInvalidToolSchema = "Inference failure: invalid request (invalid tool schema)"
    case refusalUnsupportedAudio = "Inference failure: invalid media (unsupported audio)"
    case refusalUnansweredToolCall = "Inference failure: invalid request (unanswered tool call)"
    case refusalUnmatchedToolResult = "Inference failure: invalid request (unmatched tool result)"
    case refusalNativeDelimiterInHistory = "Inference failure: invalid request (native delimiter in history)"
    case refusalNonTextContent = "Inference failure: invalid request (non-text content)"
    case refusalUnsupportedForcedToolChoice = "Inference failure: invalid request (unsupported forced tool choice)"
    case refusalRequestExceedsContext = "Inference failure: invalid request (request exceeds context)"
    case refusalUnsupportedOutputControl = "Inference failure: invalid request (unsupported output control)"

    // Operator guidance.
    case glmWiredLimitNotice = "GLM-5.3-Flash hit the macOS GPU wired-memory limit. Run {cli} doctor for the fix."
    case prefixCacheUnavailable = "SSD prefix cache did not start for a loaded model; it serves uncached. Run {cli} status."
}
