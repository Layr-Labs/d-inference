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
            sink(level, .public, message.rawValue)
            return
        }
        #if canImport(os)
        switch level {
        case .info:
            osLogger.info("\(message.rawValue, privacy: .public)")
        case .warning:
            osLogger.warning("\(message.rawValue, privacy: .public)")
        case .error:
            osLogger.error("\(message.rawValue, privacy: .public)")
        }
        #else
        print("[\(category)] \(level.label): \(message.rawValue)")
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
    // Startup and shutdown.
    case providerStarting = "Provider starting"
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
}
