import Foundation

// MARK: - Protocol v2 attempt identity (mirrors Go protocol.AttemptIdentity)

public struct AttemptIdentity: Codable, Sendable, Equatable {
    public var jobId: String
    public var attemptId: String
    public var leaseId: String?
    public var sessionEpoch: UInt64
    public var coordinatorEpoch: UInt64
    public var dispatchNonce: String
    public var requestDigest: String
    public var providerGeneration: Int64?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case leaseId = "lease_id"
        case sessionEpoch = "session_epoch"
        case coordinatorEpoch = "coordinator_epoch"
        case dispatchNonce = "dispatch_nonce"
        case requestDigest = "request_digest"
        case providerGeneration = "provider_generation"
    }

    public init(
        jobId: String,
        attemptId: String,
        leaseId: String? = nil,
        sessionEpoch: UInt64,
        coordinatorEpoch: UInt64,
        dispatchNonce: String,
        requestDigest: String,
        providerGeneration: Int64? = nil
    ) {
        self.jobId = jobId
        self.attemptId = attemptId
        self.leaseId = leaseId
        self.sessionEpoch = sessionEpoch
        self.coordinatorEpoch = coordinatorEpoch
        self.dispatchNonce = dispatchNonce
        self.requestDigest = requestDigest
        self.providerGeneration = providerGeneration
    }
}

public enum StructuredErrorClass: String, Codable, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case capacity
    case modelNotReady = "model_not_ready"
    case draining
    case cancelled
    case fault
    case security
}

/// Coordinator → Provider prepare frame (protocol v2).
public struct PrepareCommand: Codable, Sendable, Equatable {
    public var type: String = "prepare"
    public var identity: AttemptIdentity
    public var model: String
    public var encryptedBody: String?

    enum CodingKeys: String, CodingKey {
        case type, model
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case leaseId = "lease_id"
        case sessionEpoch = "session_epoch"
        case coordinatorEpoch = "coordinator_epoch"
        case dispatchNonce = "dispatch_nonce"
        case requestDigest = "request_digest"
        case providerGeneration = "provider_generation"
        case encryptedBody = "encrypted_body"
    }

    public init(identity: AttemptIdentity, model: String, encryptedBody: String? = nil) {
        self.identity = identity
        self.model = model
        self.encryptedBody = encryptedBody
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(identity.jobId, forKey: .jobId)
        try c.encode(identity.attemptId, forKey: .attemptId)
        try c.encodeIfPresent(identity.leaseId, forKey: .leaseId)
        try c.encode(identity.sessionEpoch, forKey: .sessionEpoch)
        try c.encode(identity.coordinatorEpoch, forKey: .coordinatorEpoch)
        try c.encode(identity.dispatchNonce, forKey: .dispatchNonce)
        try c.encode(identity.requestDigest, forKey: .requestDigest)
        try c.encodeIfPresent(identity.providerGeneration, forKey: .providerGeneration)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(encryptedBody, forKey: .encryptedBody)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        identity = AttemptIdentity(
            jobId: try c.decode(String.self, forKey: .jobId),
            attemptId: try c.decode(String.self, forKey: .attemptId),
            leaseId: try c.decodeIfPresent(String.self, forKey: .leaseId),
            sessionEpoch: try c.decode(UInt64.self, forKey: .sessionEpoch),
            coordinatorEpoch: try c.decode(UInt64.self, forKey: .coordinatorEpoch),
            dispatchNonce: try c.decode(String.self, forKey: .dispatchNonce),
            requestDigest: try c.decode(String.self, forKey: .requestDigest),
            providerGeneration: try c.decodeIfPresent(Int64.self, forKey: .providerGeneration)
        )
        model = try c.decode(String.self, forKey: .model)
        encryptedBody = try c.decodeIfPresent(String.self, forKey: .encryptedBody)
    }
}

/// Provider → Coordinator prepared reply.
public struct PreparedReply: Codable, Sendable, Equatable {
    public var type: String = "prepared"
    public var identity: AttemptIdentity
    public var leaseTtlMs: Int64
    public var promptTokens: Int
    public var maxOutputTokens: Int
    public var engineQueueDepth: Int
    public var prefillCanBegin: Bool
    public var estimatedPrefillMs: Int64?

    enum CodingKeys: String, CodingKey {
        case type
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case leaseId = "lease_id"
        case sessionEpoch = "session_epoch"
        case coordinatorEpoch = "coordinator_epoch"
        case dispatchNonce = "dispatch_nonce"
        case requestDigest = "request_digest"
        case providerGeneration = "provider_generation"
        case leaseTtlMs = "lease_ttl_ms"
        case promptTokens = "prompt_tokens"
        case maxOutputTokens = "max_output_tokens"
        case engineQueueDepth = "engine_queue_depth"
        case prefillCanBegin = "prefill_can_begin"
        case estimatedPrefillMs = "estimated_prefill_ms"
    }

    public init(
        identity: AttemptIdentity,
        leaseTtlMs: Int64,
        promptTokens: Int,
        maxOutputTokens: Int,
        engineQueueDepth: Int,
        prefillCanBegin: Bool,
        estimatedPrefillMs: Int64? = nil
    ) {
        self.identity = identity
        self.leaseTtlMs = leaseTtlMs
        self.promptTokens = promptTokens
        self.maxOutputTokens = maxOutputTokens
        self.engineQueueDepth = engineQueueDepth
        self.prefillCanBegin = prefillCanBegin
        self.estimatedPrefillMs = estimatedPrefillMs
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(identity.jobId, forKey: .jobId)
        try c.encode(identity.attemptId, forKey: .attemptId)
        try c.encodeIfPresent(identity.leaseId, forKey: .leaseId)
        try c.encode(identity.sessionEpoch, forKey: .sessionEpoch)
        try c.encode(identity.coordinatorEpoch, forKey: .coordinatorEpoch)
        try c.encode(identity.dispatchNonce, forKey: .dispatchNonce)
        try c.encode(identity.requestDigest, forKey: .requestDigest)
        try c.encodeIfPresent(identity.providerGeneration, forKey: .providerGeneration)
        try c.encode(leaseTtlMs, forKey: .leaseTtlMs)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encode(engineQueueDepth, forKey: .engineQueueDepth)
        try c.encode(prefillCanBegin, forKey: .prefillCanBegin)
        try c.encodeIfPresent(estimatedPrefillMs, forKey: .estimatedPrefillMs)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        identity = AttemptIdentity(
            jobId: try c.decode(String.self, forKey: .jobId),
            attemptId: try c.decode(String.self, forKey: .attemptId),
            leaseId: try c.decodeIfPresent(String.self, forKey: .leaseId),
            sessionEpoch: try c.decode(UInt64.self, forKey: .sessionEpoch),
            coordinatorEpoch: try c.decode(UInt64.self, forKey: .coordinatorEpoch),
            dispatchNonce: try c.decode(String.self, forKey: .dispatchNonce),
            requestDigest: try c.decode(String.self, forKey: .requestDigest),
            providerGeneration: try c.decodeIfPresent(Int64.self, forKey: .providerGeneration)
        )
        leaseTtlMs = try c.decode(Int64.self, forKey: .leaseTtlMs)
        promptTokens = try c.decode(Int.self, forKey: .promptTokens)
        maxOutputTokens = try c.decode(Int.self, forKey: .maxOutputTokens)
        engineQueueDepth = try c.decode(Int.self, forKey: .engineQueueDepth)
        prefillCanBegin = try c.decode(Bool.self, forKey: .prefillCanBegin)
        estimatedPrefillMs = try c.decodeIfPresent(Int64.self, forKey: .estimatedPrefillMs)
    }
}

/// Coordinator → Provider start (idempotent).
public struct StartCommand: Codable, Sendable, Equatable {
    public var type: String = "start"
    public var identity: AttemptIdentity

    enum CodingKeys: String, CodingKey {
        case type
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case leaseId = "lease_id"
        case sessionEpoch = "session_epoch"
        case coordinatorEpoch = "coordinator_epoch"
        case dispatchNonce = "dispatch_nonce"
        case requestDigest = "request_digest"
        case providerGeneration = "provider_generation"
    }

    public init(identity: AttemptIdentity) {
        self.identity = identity
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(identity.jobId, forKey: .jobId)
        try c.encode(identity.attemptId, forKey: .attemptId)
        try c.encodeIfPresent(identity.leaseId, forKey: .leaseId)
        try c.encode(identity.sessionEpoch, forKey: .sessionEpoch)
        try c.encode(identity.coordinatorEpoch, forKey: .coordinatorEpoch)
        try c.encode(identity.dispatchNonce, forKey: .dispatchNonce)
        try c.encode(identity.requestDigest, forKey: .requestDigest)
        try c.encodeIfPresent(identity.providerGeneration, forKey: .providerGeneration)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        identity = AttemptIdentity(
            jobId: try c.decode(String.self, forKey: .jobId),
            attemptId: try c.decode(String.self, forKey: .attemptId),
            leaseId: try c.decodeIfPresent(String.self, forKey: .leaseId),
            sessionEpoch: try c.decode(UInt64.self, forKey: .sessionEpoch),
            coordinatorEpoch: try c.decode(UInt64.self, forKey: .coordinatorEpoch),
            dispatchNonce: try c.decode(String.self, forKey: .dispatchNonce),
            requestDigest: try c.decode(String.self, forKey: .requestDigest),
            providerGeneration: try c.decodeIfPresent(Int64.self, forKey: .providerGeneration)
        )
    }
}

/// Provider → Coordinator started ACK.
public struct StartedReply: Codable, Sendable, Equatable {
    public var type: String = "started"
    public var identity: AttemptIdentity

    enum CodingKeys: String, CodingKey {
        case type
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case leaseId = "lease_id"
        case sessionEpoch = "session_epoch"
        case coordinatorEpoch = "coordinator_epoch"
        case dispatchNonce = "dispatch_nonce"
        case requestDigest = "request_digest"
        case providerGeneration = "provider_generation"
    }

    public init(identity: AttemptIdentity) {
        self.identity = identity
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(identity.jobId, forKey: .jobId)
        try c.encode(identity.attemptId, forKey: .attemptId)
        try c.encodeIfPresent(identity.leaseId, forKey: .leaseId)
        try c.encode(identity.sessionEpoch, forKey: .sessionEpoch)
        try c.encode(identity.coordinatorEpoch, forKey: .coordinatorEpoch)
        try c.encode(identity.dispatchNonce, forKey: .dispatchNonce)
        try c.encode(identity.requestDigest, forKey: .requestDigest)
        try c.encodeIfPresent(identity.providerGeneration, forKey: .providerGeneration)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        identity = AttemptIdentity(
            jobId: try c.decode(String.self, forKey: .jobId),
            attemptId: try c.decode(String.self, forKey: .attemptId),
            leaseId: try c.decodeIfPresent(String.self, forKey: .leaseId),
            sessionEpoch: try c.decode(UInt64.self, forKey: .sessionEpoch),
            coordinatorEpoch: try c.decode(UInt64.self, forKey: .coordinatorEpoch),
            dispatchNonce: try c.decode(String.self, forKey: .dispatchNonce),
            requestDigest: try c.decode(String.self, forKey: .requestDigest),
            providerGeneration: try c.decodeIfPresent(Int64.self, forKey: .providerGeneration)
        )
    }
}

/// Provider → Coordinator signed terminal.
public struct ProviderTerminal: Codable, Sendable, Equatable {
    public var type: String = "provider_terminal"
    public var identity: AttemptIdentity
    public var outcome: String
    public var errorClass: StructuredErrorClass?
    public var promptTokens: Int
    public var completionTokens: Int
    public var responseHash: String
    public var finalGeneratedTokens: Int
    public var seSignature: String
    public var terminalDigest: String
    public var model: String

    enum CodingKeys: String, CodingKey {
        case type, outcome, model
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case leaseId = "lease_id"
        case sessionEpoch = "session_epoch"
        case coordinatorEpoch = "coordinator_epoch"
        case dispatchNonce = "dispatch_nonce"
        case requestDigest = "request_digest"
        case providerGeneration = "provider_generation"
        case errorClass = "error_class"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case responseHash = "response_hash"
        case finalGeneratedTokens = "final_generated_tokens"
        case seSignature = "se_signature"
        case terminalDigest = "terminal_digest"
    }

    public init(
        identity: AttemptIdentity,
        outcome: String,
        errorClass: StructuredErrorClass? = nil,
        promptTokens: Int,
        completionTokens: Int,
        responseHash: String,
        finalGeneratedTokens: Int,
        seSignature: String,
        terminalDigest: String,
        model: String
    ) {
        self.identity = identity
        self.outcome = outcome
        self.errorClass = errorClass
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.responseHash = responseHash
        self.finalGeneratedTokens = finalGeneratedTokens
        self.seSignature = seSignature
        self.terminalDigest = terminalDigest
        self.model = model
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(identity.jobId, forKey: .jobId)
        try c.encode(identity.attemptId, forKey: .attemptId)
        try c.encodeIfPresent(identity.leaseId, forKey: .leaseId)
        try c.encode(identity.sessionEpoch, forKey: .sessionEpoch)
        try c.encode(identity.coordinatorEpoch, forKey: .coordinatorEpoch)
        try c.encode(identity.dispatchNonce, forKey: .dispatchNonce)
        try c.encode(identity.requestDigest, forKey: .requestDigest)
        try c.encodeIfPresent(identity.providerGeneration, forKey: .providerGeneration)
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(errorClass, forKey: .errorClass)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        try c.encode(responseHash, forKey: .responseHash)
        try c.encode(finalGeneratedTokens, forKey: .finalGeneratedTokens)
        try c.encode(seSignature, forKey: .seSignature)
        try c.encode(terminalDigest, forKey: .terminalDigest)
        try c.encode(model, forKey: .model)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        identity = AttemptIdentity(
            jobId: try c.decode(String.self, forKey: .jobId),
            attemptId: try c.decode(String.self, forKey: .attemptId),
            leaseId: try c.decodeIfPresent(String.self, forKey: .leaseId),
            sessionEpoch: try c.decode(UInt64.self, forKey: .sessionEpoch),
            coordinatorEpoch: try c.decode(UInt64.self, forKey: .coordinatorEpoch),
            dispatchNonce: try c.decode(String.self, forKey: .dispatchNonce),
            requestDigest: try c.decode(String.self, forKey: .requestDigest),
            providerGeneration: try c.decodeIfPresent(Int64.self, forKey: .providerGeneration)
        )
        outcome = try c.decode(String.self, forKey: .outcome)
        errorClass = try c.decodeIfPresent(StructuredErrorClass.self, forKey: .errorClass)
        promptTokens = try c.decode(Int.self, forKey: .promptTokens)
        completionTokens = try c.decode(Int.self, forKey: .completionTokens)
        responseHash = try c.decode(String.self, forKey: .responseHash)
        finalGeneratedTokens = try c.decode(Int.self, forKey: .finalGeneratedTokens)
        seSignature = try c.decode(String.self, forKey: .seSignature)
        terminalDigest = try c.decode(String.self, forKey: .terminalDigest)
        model = try c.decode(String.self, forKey: .model)
    }
}
