import Foundation

public enum V2StructuredErrorClass: String, Sendable, Codable {
    case invalidRequest = "invalid_request"
    case capacity
    case modelNotReady = "model_not_ready"
    case draining
    case cancelled
    case fault
    case security
}

public struct V2Prepare: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var model: String
    public var requestDigest: ProtocolV2Digest
    public var encryptedBody: EncryptedPayload

    public init(
        identity: AttemptIdentity,
        model: String,
        requestDigest: ProtocolV2Digest,
        encryptedBody: EncryptedPayload
    ) {
        self.identity = identity
        self.model = model
        self.requestDigest = requestDigest
        self.encryptedBody = encryptedBody
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        model = try container.decode(String.self, forKey: .model)
        requestDigest = try container.decode(ProtocolV2Digest.self, forKey: .requestDigest)
        encryptedBody = try container.decode(EncryptedPayload.self, forKey: .encryptedBody)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encode(model, forKey: .model)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(encryptedBody, forKey: .encryptedBody)
    }

    /// Stable digest of the complete encrypted request envelope. Binding both
    /// the consumer key and ciphertext prevents a retry from swapping the
    /// response recipient while retaining the same ciphertext.
    public static func digest(of payload: EncryptedPayload) throws -> ProtocolV2Digest {
        guard let publicKey = Data(base64Encoded: payload.ephemeralPublicKey),
            publicKey.count == 32,
            publicKey.base64EncodedString() == payload.ephemeralPublicKey,
            let ciphertext = Data(base64Encoded: payload.ciphertext),
            ciphertext.base64EncodedString() == payload.ciphertext
        else {
            throw V2PrepareValidationError.invalidEncryptedPayload
        }
        var input = Data("darkbloom.protocol.v2.prepare-payload\0".utf8)
        input.append(publicKey)
        input.append(ciphertext)
        return .of(input)
    }
}

public enum V2PrepareValidationError: Error, Sendable, Equatable {
    case invalidEncryptedPayload
}

public struct V2Prepared: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var model: String
    public var requestDigest: ProtocolV2Digest
    public var leaseTTLMilliseconds: UInt64
    public var promptTokens: UInt64
    public var maxOutputTokens: UInt64
    public var engineQueueDepth: UInt32
    public var reservedKVBytes: UInt64
    public var reservedMediaBytes: UInt64
    public var prefillCanBegin: Bool
    public var estimatedPrefillMilliseconds: UInt64?

    public init(
        identity: AttemptIdentity,
        model: String,
        requestDigest: ProtocolV2Digest,
        leaseTTLMilliseconds: UInt64,
        promptTokens: UInt64,
        maxOutputTokens: UInt64,
        engineQueueDepth: UInt32,
        reservedKVBytes: UInt64,
        reservedMediaBytes: UInt64,
        prefillCanBegin: Bool,
        estimatedPrefillMilliseconds: UInt64? = nil
    ) {
        self.identity = identity
        self.model = model
        self.requestDigest = requestDigest
        self.leaseTTLMilliseconds = leaseTTLMilliseconds
        self.promptTokens = promptTokens
        self.maxOutputTokens = maxOutputTokens
        self.engineQueueDepth = engineQueueDepth
        self.reservedKVBytes = reservedKVBytes
        self.reservedMediaBytes = reservedMediaBytes
        self.prefillCanBegin = prefillCanBegin
        self.estimatedPrefillMilliseconds = estimatedPrefillMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        model = try container.decode(String.self, forKey: .model)
        requestDigest = try container.decode(ProtocolV2Digest.self, forKey: .requestDigest)
        leaseTTLMilliseconds = try container.decode(UInt64.self, forKey: .leaseTTLMilliseconds)
        promptTokens = try container.decode(UInt64.self, forKey: .promptTokens)
        maxOutputTokens = try container.decode(UInt64.self, forKey: .maxOutputTokens)
        engineQueueDepth = try container.decode(UInt32.self, forKey: .engineQueueDepth)
        reservedKVBytes = try container.decode(UInt64.self, forKey: .reservedKVBytes)
        reservedMediaBytes = try container.decode(UInt64.self, forKey: .reservedMediaBytes)
        prefillCanBegin = try container.decode(Bool.self, forKey: .prefillCanBegin)
        estimatedPrefillMilliseconds = try container.decodeIfPresent(
            UInt64.self, forKey: .estimatedPrefillMilliseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encode(model, forKey: .model)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(leaseTTLMilliseconds, forKey: .leaseTTLMilliseconds)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(engineQueueDepth, forKey: .engineQueueDepth)
        try container.encode(reservedKVBytes, forKey: .reservedKVBytes)
        try container.encode(reservedMediaBytes, forKey: .reservedMediaBytes)
        try container.encode(prefillCanBegin, forKey: .prefillCanBegin)
        try container.encodeIfPresent(
            estimatedPrefillMilliseconds, forKey: .estimatedPrefillMilliseconds)
    }
}

public struct V2Start: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public init(identity: AttemptIdentity) { self.identity = identity }
    public init(from decoder: Decoder) throws {
        identity = try decoder.container(keyedBy: V2WireCodingKeys.self).decodeAttemptIdentity()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
    }
}

public struct V2StartAck: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public init(identity: AttemptIdentity) { self.identity = identity }
    public init(from decoder: Decoder) throws {
        identity = try decoder.container(keyedBy: V2WireCodingKeys.self).decodeAttemptIdentity()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
    }
}

public struct V2QueryAttempt: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public init(identity: AttemptIdentity) { self.identity = identity }
    public init(from decoder: Decoder) throws {
        identity = try decoder.container(keyedBy: V2WireCodingKeys.self).decodeAttemptIdentity()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
    }
}

public enum V2AttemptStatusState: String, Sendable, Equatable, Codable {
    case unknown
    case prepared
    case started
    case terminal
}

public struct V2AttemptStatus: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var state: V2AttemptStatusState
    public var terminalDigest: ProtocolV2Digest?

    public init(
        identity: AttemptIdentity,
        state: V2AttemptStatusState,
        terminalDigest: ProtocolV2Digest? = nil
    ) throws {
        guard (state == .terminal) == (terminalDigest != nil) else {
            throw V2AttemptStatusError.invalidTerminalDigestShape
        }
        self.identity = identity
        self.state = state
        self.terminalDigest = terminalDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        state = try container.decode(V2AttemptStatusState.self, forKey: .state)
        terminalDigest = try container.decodeIfPresent(
            ProtocolV2Digest.self, forKey: .terminalDigest)
        guard (state == .terminal) == (terminalDigest != nil) else {
            throw V2AttemptStatusError.invalidTerminalDigestShape
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(terminalDigest, forKey: .terminalDigest)
    }
}

public enum V2AttemptStatusError: Error, Sendable, Equatable {
    case invalidTerminalDigestShape
}

public struct V2Abort: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var reason: String?

    public init(identity: AttemptIdentity, reason: String? = nil) {
        self.identity = identity
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

public struct V2AbortAck: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public init(identity: AttemptIdentity) { self.identity = identity }
    public init(from decoder: Decoder) throws {
        identity = try decoder.container(keyedBy: V2WireCodingKeys.self).decodeAttemptIdentity()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
    }
}

public struct V2Cancel: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var reason: String?

    public init(identity: AttemptIdentity, reason: String? = nil) {
        self.identity = identity
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

public struct V2CancelAck: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public init(identity: AttemptIdentity) { self.identity = identity }
    public init(from decoder: Decoder) throws {
        identity = try decoder.container(keyedBy: V2WireCodingKeys.self).decodeAttemptIdentity()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
    }
}

public struct V2StructuredError: Sendable, Equatable, Codable {
    public var identity: AttemptIdentity
    public var errorClass: V2StructuredErrorClass
    public var message: String?

    public init(
        identity: AttemptIdentity,
        errorClass: V2StructuredErrorClass,
        message: String? = nil
    ) {
        self.identity = identity
        self.errorClass = errorClass
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeAttemptIdentity()
        errorClass = try container.decode(V2StructuredErrorClass.self, forKey: .structuredErrorClass)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeAttemptIdentity(identity)
        try container.encode(errorClass, forKey: .structuredErrorClass)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

public struct V2ModelReady: Sendable, Equatable, Codable {
    public var identity: ProviderSessionIdentity
    public var model: String
    public var stateRevision: UInt64
    public var weightHash: String?

    public init(
        identity: ProviderSessionIdentity,
        model: String,
        stateRevision: UInt64,
        weightHash: String? = nil
    ) {
        self.identity = identity
        self.model = model
        self.stateRevision = stateRevision
        self.weightHash = weightHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeProviderSessionIdentity()
        model = try container.decode(String.self, forKey: .model)
        stateRevision = try container.decode(UInt64.self, forKey: .stateRevision)
        weightHash = try container.decodeIfPresent(String.self, forKey: .weightHash)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeProviderSessionIdentity(identity)
        try container.encode(model, forKey: .model)
        try container.encode(stateRevision, forKey: .stateRevision)
        try container.encodeIfPresent(weightHash, forKey: .weightHash)
    }
}

public struct V2ModelGone: Sendable, Equatable, Codable {
    public var identity: ProviderSessionIdentity
    public var model: String
    public var stateRevision: UInt64
    public var reason: String?

    public init(
        identity: ProviderSessionIdentity,
        model: String,
        stateRevision: UInt64,
        reason: String? = nil
    ) {
        self.identity = identity
        self.model = model
        self.stateRevision = stateRevision
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        identity = try container.decodeProviderSessionIdentity()
        model = try container.decode(String.self, forKey: .model)
        stateRevision = try container.decode(UInt64.self, forKey: .stateRevision)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encodeProviderSessionIdentity(identity)
        try container.encode(model, forKey: .model)
        try container.encode(stateRevision, forKey: .stateRevision)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

public enum V2CoordinatorControlMessage: Sendable, Equatable, Codable {
    case prepare(V2Prepare)
    case start(V2Start)
    case queryAttempt(V2QueryAttempt)
    case abort(V2Abort)
    case cancel(V2Cancel)
    case terminalAck(V2TerminalAck)
    case coordinatorReplayFence(CoordinatorReplayFenceProof)

    public var attemptIdentity: AttemptIdentity? {
        switch self {
        case .prepare(let message): message.identity
        case .start(let message): message.identity
        case .queryAttempt(let message): message.identity
        case .abort(let message): message.identity
        case .cancel(let message): message.identity
        case .terminalAck(let message): message.identity
        case .coordinatorReplayFence: nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "prepare": self = .prepare(try V2Prepare(from: decoder))
        case "start": self = .start(try V2Start(from: decoder))
        case "query_attempt": self = .queryAttempt(try V2QueryAttempt(from: decoder))
        case "abort": self = .abort(try V2Abort(from: decoder))
        case "cancel": self = .cancel(try V2Cancel(from: decoder))
        case "terminal_ack": self = .terminalAck(try V2TerminalAck(from: decoder))
        case "coordinator_replay_fence":
            self = .coordinatorReplayFence(
                try CoordinatorReplayFenceProof(from: decoder))
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown protocol-v2 coordinator message type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        switch self {
        case .prepare(let message):
            try container.encode("prepare", forKey: .type)
            try message.encode(to: encoder)
        case .start(let message):
            try container.encode("start", forKey: .type)
            try message.encode(to: encoder)
        case .queryAttempt(let message):
            try container.encode("query_attempt", forKey: .type)
            try message.encode(to: encoder)
        case .abort(let message):
            try container.encode("abort", forKey: .type)
            try message.encode(to: encoder)
        case .cancel(let message):
            try container.encode("cancel", forKey: .type)
            try message.encode(to: encoder)
        case .terminalAck(let message):
            try container.encode("terminal_ack", forKey: .type)
            try message.encode(to: encoder)
        case .coordinatorReplayFence(let proof):
            try container.encode("coordinator_replay_fence", forKey: .type)
            try proof.encode(to: encoder)
        }
    }
}

/// Confirms that one signed coordinator replay fence was durably applied.
///
/// The generation identifies the proof's historical partition and can differ
/// from the current WebSocket process generation.
public struct V2ReplayFenceAck: Sendable, Equatable, Codable {
    public var proofID: ProtocolV2UUID
    public var providerID: ProviderID
    public var providerProcessGeneration: ProviderProcessGenerationID

    public init(
        proofID: ProtocolV2UUID,
        providerID: ProviderID,
        providerProcessGeneration: ProviderProcessGenerationID
    ) {
        self.proofID = proofID
        self.providerID = providerID
        self.providerProcessGeneration = providerProcessGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        proofID = try container.decode(ProtocolV2UUID.self, forKey: .proofID)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        providerProcessGeneration = try container.decode(
            ProviderProcessGenerationID.self,
            forKey: .providerProcessGeneration
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        try container.encode(proofID, forKey: .proofID)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(
            providerProcessGeneration,
            forKey: .providerProcessGeneration
        )
    }
}

public enum V2ProviderControlMessage: Sendable, Equatable, Codable {
    case prepared(V2Prepared)
    case startAck(V2StartAck)
    case attemptStatus(V2AttemptStatus)
    case abortAck(V2AbortAck)
    case cancelAck(V2CancelAck)
    case terminal(V2ProviderTerminal)
    case structuredError(V2StructuredError)
    case modelReady(V2ModelReady)
    case modelGone(V2ModelGone)
    case replayFenceAck(V2ReplayFenceAck)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2WireCodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "prepared": self = .prepared(try V2Prepared(from: decoder))
        case "start_ack", "started": self = .startAck(try V2StartAck(from: decoder))
        case "attempt_status": self = .attemptStatus(try V2AttemptStatus(from: decoder))
        case "abort_ack", "aborted": self = .abortAck(try V2AbortAck(from: decoder))
        case "cancel_ack", "cancelled": self = .cancelAck(try V2CancelAck(from: decoder))
        case "provider_terminal": self = .terminal(try V2ProviderTerminal(from: decoder))
        case "structured_error": self = .structuredError(try V2StructuredError(from: decoder))
        case "model_ready": self = .modelReady(try V2ModelReady(from: decoder))
        case "model_gone": self = .modelGone(try V2ModelGone(from: decoder))
        case "replay_fence_ack":
            self = .replayFenceAck(try V2ReplayFenceAck(from: decoder))
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown protocol-v2 provider message type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2WireCodingKeys.self)
        switch self {
        case .prepared(let message):
            try container.encode("prepared", forKey: .type)
            try message.encode(to: encoder)
        case .startAck(let message):
            try container.encode("start_ack", forKey: .type)
            try message.encode(to: encoder)
        case .attemptStatus(let message):
            try container.encode("attempt_status", forKey: .type)
            try message.encode(to: encoder)
        case .abortAck(let message):
            try container.encode("abort_ack", forKey: .type)
            try message.encode(to: encoder)
        case .cancelAck(let message):
            try container.encode("cancel_ack", forKey: .type)
            try message.encode(to: encoder)
        case .terminal(let message):
            try container.encode("provider_terminal", forKey: .type)
            try message.encode(to: encoder)
        case .structuredError(let message):
            try container.encode("structured_error", forKey: .type)
            try message.encode(to: encoder)
        case .modelReady(let message):
            try container.encode("model_ready", forKey: .type)
            try message.encode(to: encoder)
        case .modelGone(let message):
            try container.encode("model_gone", forKey: .type)
            try message.encode(to: encoder)
        case .replayFenceAck(let message):
            try container.encode("replay_fence_ack", forKey: .type)
            try message.encode(to: encoder)
        }
    }
}

enum V2WireCodingKeys: String, CodingKey {
    case type
    case proofID = "proof_id"
    case providerID = "provider_id"
    case providerProcessGeneration = "provider_process_generation"
    case processGeneration = "process_generation"
    case sessionEpoch = "session_epoch"
    case requestID = "request_id"
    case attemptID = "attempt_id"
    case reservationID = "reservation_id"
    case leaseID = "lease_id"
    case model
    case requestDigest = "request_digest"
    case encryptedBody = "encrypted_body"
    case leaseTTLMilliseconds = "lease_ttl_ms"
    case promptTokens = "prompt_tokens"
    case maxOutputTokens = "max_output_tokens"
    case engineQueueDepth = "engine_queue_depth"
    case reservedKVBytes = "reserved_kv_bytes"
    case reservedMediaBytes = "reserved_media_bytes"
    case prefillCanBegin = "prefill_can_begin"
    case estimatedPrefillMilliseconds = "estimated_prefill_ms"
    case reason
    case state
    case errorClass = "error_class"
    case structuredErrorClass = "class"
    case message
    case outcome
    case completionTokens = "completion_tokens"
    case reasoningTokens = "reasoning_tokens"
    case responseHash = "response_hash"
    case finalGeneratedTokens = "final_generated_tokens"
    case rollingDigest = "rolling_digest"
    case rollingHashCheckpoint = "rolling_hash_checkpoint"
    case terminalDigest = "terminal_digest"
    case seSignature = "se_signature"
    case signature
    case disposition
    case stateRevision = "state_revision"
    case weightHash = "weight_hash"
}

extension KeyedDecodingContainer where Key == V2WireCodingKeys {
    func decodeAttemptIdentity() throws -> AttemptIdentity {
        AttemptIdentity(
            providerID: try decode(ProviderID.self, forKey: .providerID),
            providerProcessGeneration: try decode(
                ProviderProcessGenerationID.self, forKey: .providerProcessGeneration),
            sessionEpoch: try decode(UInt64.self, forKey: .sessionEpoch),
            requestID: try decode(RequestID.self, forKey: .requestID),
            attemptID: try decode(AttemptID.self, forKey: .attemptID),
            reservationID: try decode(ReservationID.self, forKey: .reservationID),
            leaseID: try decode(LeaseID.self, forKey: .leaseID)
        )
    }

    func decodeProviderSessionIdentity() throws -> ProviderSessionIdentity {
        ProviderSessionIdentity(
            providerID: try decode(ProviderID.self, forKey: .providerID),
            processGeneration: try decode(
                ProviderProcessGenerationID.self, forKey: .processGeneration),
            sessionEpoch: try decode(UInt64.self, forKey: .sessionEpoch)
        )
    }
}

extension KeyedEncodingContainer where Key == V2WireCodingKeys {
    mutating func encodeAttemptIdentity(_ identity: AttemptIdentity) throws {
        try encode(identity.providerID, forKey: .providerID)
        try encode(identity.providerProcessGeneration, forKey: .providerProcessGeneration)
        try encode(identity.sessionEpoch, forKey: .sessionEpoch)
        try encode(identity.requestID, forKey: .requestID)
        try encode(identity.attemptID, forKey: .attemptID)
        try encode(identity.reservationID, forKey: .reservationID)
        try encode(identity.leaseID, forKey: .leaseID)
    }

    mutating func encodeProviderSessionIdentity(_ identity: ProviderSessionIdentity) throws {
        try encode(identity.providerID, forKey: .providerID)
        try encode(identity.processGeneration, forKey: .processGeneration)
        try encode(identity.sessionEpoch, forKey: .sessionEpoch)
    }
}
