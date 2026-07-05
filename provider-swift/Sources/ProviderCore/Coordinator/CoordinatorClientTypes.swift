// CoordinatorClient wire/value types: coordinator events, client config +
// runtime hashes, outbound message enum + attestation payload, and errors.

import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - Event Types

public enum CoordinatorEvent: Sendable {
    case connected
    case disconnected
    /// `ciphertext` is the **decoded** NaCl-box ciphertext (nonce ‖ tag ‖ body),
    /// i.e. base64 already stripped. `senderPublicKey` is the consumer's
    /// 32-byte X25519 ephemeral public key, also decoded.
    /// Consumers (ProviderLoop) feed both directly to NodeKeyPair.decrypt
    /// without further base64 manipulation.
    case inferenceRequest(requestId: String, ciphertext: Data, senderPublicKey: Data?)
    case cancel(requestId: String)
    case attestationChallenge(nonce: String, timestamp: String)
    case runtimeOutdated(mismatches: [RuntimeMismatch])
    /// Coordinator-driven preload. Provider should eagerly load the model
    /// (off-thread) and reply with a `loadModelStatus` outbound message
    /// when the load completes or fails.
    case loadModel(modelId: String)
    /// Coordinator-driven background prefetch. Provider should download +
    /// verify the build on disk (off-thread, no GPU load) and reply with
    /// `prefetchModelStatus` outbound messages. `priority` orders concurrent
    /// prefetches (higher = sooner). Handler wired in Layer 3.
    case prefetchModel(modelId: String, priority: Int)
    /// Coordinator's declarative desired-build map. The provider reconciles each
    /// entry: prefetch the desired build if missing, then hard-swap (advertise
    /// new, drop the previous build) once verified. Sent after register and on
    /// every change. Replaces the old push-driven migration ramp.
    case desiredModels(entries: [CoordinatorMessage.DesiredModelEntry])
    /// Coordinator informs the provider of its current trust level and status.
    case trustStatus(trustLevel: String, status: String, reason: String)
}


// MARK: - Configuration

public struct CoordinatorClientConfig: Sendable {
    public let url: String
    public let hardware: HardwareInfo
    public let models: [ModelInfo]
    public let backendName: String
    public let heartbeatInterval: TimeInterval
    public let publicKey: String?
    public let walletAddress: String?
    public let attestation: RawJSON?
    public let authToken: String?
    public let runtimeHashes: RuntimeHashes?
    public let modelHashes: [String: String]
    public let privacyCapabilities: PrivacyCapabilities?
    /// When true, this machine registers as private-only: the coordinator
    /// serves it exclusively to its owner's self-route requests, never the
    /// public fleet.
    public let privateOnly: Bool
    /// APNs code-identity (v0.6.0): the device token to push the E_K(nonce)
    /// code-identity challenge to, and which APNs environment it belongs to.
    /// nil on headless/no-GUI boxes (no token) — those register un-attested.
    public let apnsDeviceToken: String?
    public let apnsEnvironment: String?

    public init(
        url: String,
        hardware: HardwareInfo,
        models: [ModelInfo],
        backendName: String,
        heartbeatInterval: TimeInterval = 30.0,
        publicKey: String? = nil,
        walletAddress: String? = nil,
        attestation: RawJSON? = nil,
        authToken: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        modelHashes: [String: String] = [:],
        privacyCapabilities: PrivacyCapabilities? = nil,
        privateOnly: Bool = false,
        apnsDeviceToken: String? = nil,
        apnsEnvironment: String? = nil
    ) {
        self.url = url
        self.hardware = hardware
        self.models = models
        self.backendName = backendName
        self.heartbeatInterval = heartbeatInterval
        self.publicKey = publicKey
        self.walletAddress = walletAddress
        self.attestation = attestation
        self.authToken = authToken
        self.runtimeHashes = runtimeHashes
        self.modelHashes = modelHashes
        self.privacyCapabilities = privacyCapabilities
        self.privateOnly = privateOnly
        self.apnsDeviceToken = apnsDeviceToken
        self.apnsEnvironment = apnsEnvironment
    }
}

public struct RuntimeHashes: Sendable {
    public let pythonHash: String?
    public let runtimeHash: String?
    public let templateHashes: [String: String]

    public init(
        pythonHash: String? = nil,
        runtimeHash: String? = nil,
        templateHashes: [String: String] = [:]
    ) {
        self.pythonHash = pythonHash
        self.runtimeHash = runtimeHash
        self.templateHashes = templateHashes
    }
}


// MARK: - Outbound message type (provider -> coordinator)

public enum OutboundMessage: Sendable {
    case inferenceAccepted(requestId: String)
    case inferenceChunk(requestId: String, data: String, encryptedData: EncryptedPayload?)
    case inferenceComplete(requestId: String, usage: UsageInfo, seSignature: String?, responseHash: String?)
    case inferenceError(requestId: String, error: String, statusCode: UInt16, errorReason: String?)
    case attestationResponse(AttestationResponsePayload)
    case codeAttestationResponse(nonce: String, signature: String)
    case loadModelStatus(modelId: String, status: ProviderMessage.LoadModelStatus.Status, error: String?)
    case prefetchModelStatus(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    )
    /// Authoritative out-of-band advertisement of newly-available builds
    /// (e.g. a verified prefetch), carrying full `ModelInfo` including the
    /// computed weight hash so the coordinator can cross-check before routing.
    case modelsUpdate(models: [ModelInfo])
}

public struct AttestationResponsePayload: Sendable {
    public let nonce: String
    public let signature: String
    public let statusSignature: String?
    public let publicKey: String
    public let rdmaDisabled: Bool?
    public let sipEnabled: Bool?
    public let secureBootEnabled: Bool?
    public let binaryHash: String?
    public let activeModelHash: String?
    public let pythonHash: String?
    public let runtimeHash: String?
    public let templateHashes: [String: String]
    public let modelHashes: [String: String]

    public init(
        nonce: String,
        signature: String,
        statusSignature: String? = nil,
        publicKey: String,
        rdmaDisabled: Bool? = nil,
        sipEnabled: Bool? = nil,
        secureBootEnabled: Bool? = nil,
        binaryHash: String? = nil,
        activeModelHash: String? = nil,
        pythonHash: String? = nil,
        runtimeHash: String? = nil,
        templateHashes: [String: String] = [:],
        modelHashes: [String: String] = [:]
    ) {
        self.nonce = nonce
        self.signature = signature
        self.statusSignature = statusSignature
        self.publicKey = publicKey
        self.rdmaDisabled = rdmaDisabled
        self.sipEnabled = sipEnabled
        self.secureBootEnabled = secureBootEnabled
        self.binaryHash = binaryHash
        self.activeModelHash = activeModelHash
        self.pythonHash = pythonHash
        self.runtimeHash = runtimeHash
        self.templateHashes = templateHashes
        self.modelHashes = modelHashes
    }
}


// MARK: - Errors

public enum CoordinatorError: Error, CustomStringConvertible {
    case invalidURL(String)
    case encodingFailed
    case pongTimeout
    case connectionClosed(Error)
    case suspensionDetected

    public var description: String {
        switch self {
        case .invalidURL(let url): return "Invalid coordinator URL: \(url)"
        case .encodingFailed: return "Failed to encode message"
        case .pongTimeout: return "WebSocket pong timeout (no response in 30s)"
        case .connectionClosed(let err): return "WebSocket connection closed: \(err.localizedDescription)"
        case .suspensionDetected: return "Process suspension detected (timer gap); forcing reconnect"
        }
    }
}

