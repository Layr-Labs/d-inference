import Foundation

// MARK: - Provider -> Coordinator

public enum ProviderMessage: Sendable, Equatable {
    case register(Register)
    case heartbeat(Heartbeat)
    case inferenceAccepted(InferenceAccepted)
    case inferenceResponseChunk(InferenceResponseChunk)
    case inferenceComplete(InferenceComplete)
    case inferenceError(InferenceError)
    case attestationResponse(AttestationResponse)
    case loadModelStatus(LoadModelStatus)

    public struct Register: Sendable, Equatable {
        public var hardware: HardwareInfo
        public var models: [ModelInfo]
        public var backend: String
        public var version: String?
        public var publicKey: String?
        public var encryptedResponseChunks: Bool
        public var walletAddress: String?
        public var attestation: RawJSON?
        public var prefillTps: Double?
        public var decodeTps: Double?
        public var authToken: String?
        public var pythonHash: String?
        public var runtimeHash: String?
        public var templateHashes: [String: String]
        public var privacyCapabilities: PrivacyCapabilities?
        /// When true, this machine serves only its owner's self-route requests,
        /// never the public fleet. Mirrors RegisterMessage.PrivateOnly (Go).
        public var privateOnly: Bool

        public init(
            hardware: HardwareInfo,
            models: [ModelInfo],
            backend: String,
            version: String? = nil,
            publicKey: String? = nil,
            encryptedResponseChunks: Bool = false,
            walletAddress: String? = nil,
            attestation: RawJSON? = nil,
            prefillTps: Double? = nil,
            decodeTps: Double? = nil,
            authToken: String? = nil,
            pythonHash: String? = nil,
            runtimeHash: String? = nil,
            templateHashes: [String: String] = [:],
            privacyCapabilities: PrivacyCapabilities? = nil,
            privateOnly: Bool = false
        ) {
            self.hardware = hardware
            self.models = models
            self.backend = backend
            self.version = version
            self.publicKey = publicKey
            self.encryptedResponseChunks = encryptedResponseChunks
            self.walletAddress = walletAddress
            self.attestation = attestation
            self.prefillTps = prefillTps
            self.decodeTps = decodeTps
            self.authToken = authToken
            self.pythonHash = pythonHash
            self.runtimeHash = runtimeHash
            self.templateHashes = templateHashes
            self.privacyCapabilities = privacyCapabilities
            self.privateOnly = privateOnly
        }
    }

    public struct Heartbeat: Sendable, Equatable {
        public var status: ProviderStatus
        public var activeModel: String?
        public var warmModels: [String]
        public var stats: ProviderStats
        public var systemMetrics: SystemMetrics
        public var backendCapacity: BackendCapacity?

        public init(
            status: ProviderStatus,
            activeModel: String? = nil,
            warmModels: [String] = [],
            stats: ProviderStats,
            systemMetrics: SystemMetrics,
            backendCapacity: BackendCapacity? = nil
        ) {
            self.status = status
            self.activeModel = activeModel
            self.warmModels = warmModels
            self.stats = stats
            self.systemMetrics = systemMetrics
            self.backendCapacity = backendCapacity
        }
    }

    public struct InferenceAccepted: Sendable, Equatable {
        public var requestId: String
        public init(requestId: String) { self.requestId = requestId }
    }

    public struct InferenceResponseChunk: Sendable, Equatable {
        public var requestId: String
        public var data: String
        public var encryptedData: EncryptedPayload?

        public init(requestId: String, data: String = "", encryptedData: EncryptedPayload? = nil) {
            self.requestId = requestId
            self.data = data
            self.encryptedData = encryptedData
        }
    }

    public struct InferenceComplete: Sendable, Equatable {
        public var requestId: String
        public var usage: UsageInfo
        public var seSignature: String?
        public var responseHash: String?

        public init(requestId: String, usage: UsageInfo, seSignature: String? = nil, responseHash: String? = nil) {
            self.requestId = requestId
            self.usage = usage
            self.seSignature = seSignature
            self.responseHash = responseHash
        }
    }

    public struct InferenceError: Sendable, Equatable {
        public var requestId: String
        public var error: String
        public var statusCode: UInt16

        public init(requestId: String, error: String, statusCode: UInt16) {
            self.requestId = requestId
            self.error = error
            self.statusCode = statusCode
        }
    }

    /// Reply to a `CoordinatorMessage.loadModel`. `status` is one of
    /// "started", "succeeded", or "failed". On failure, `error` carries
    /// a human-readable reason.
    public struct LoadModelStatus: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            case started
            case succeeded
            case failed
        }

        public var modelId: String
        public var status: Status
        public var error: String?

        public init(modelId: String, status: Status, error: String? = nil) {
            self.modelId = modelId
            self.status = status
            self.error = error
        }
    }

    public struct AttestationResponse: Sendable, Equatable {
        public var nonce: String
        public var signature: String
        public var statusSignature: String?
        public var publicKey: String
        public var hypervisorActive: Bool?
        public var rdmaDisabled: Bool?
        public var sipEnabled: Bool?
        public var secureBootEnabled: Bool?
        public var binaryHash: String?
        public var activeModelHash: String?
        public var pythonHash: String?
        public var runtimeHash: String?
        public var templateHashes: [String: String]
        public var modelHashes: [String: String]

        public init(
            nonce: String,
            signature: String,
            statusSignature: String? = nil,
            publicKey: String,
            hypervisorActive: Bool? = nil,
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
            self.hypervisorActive = hypervisorActive
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
}

// MARK: - ProviderMessage Codable

extension ProviderMessage: Codable {
    enum TypeValue: String, Codable {
        case register
        case heartbeat
        case inferenceAccepted = "inference_accepted"
        case inferenceResponseChunk = "inference_response_chunk"
        case inferenceComplete = "inference_complete"
        case inferenceError = "inference_error"
        case attestationResponse = "attestation_response"
        case loadModelStatus = "load_model_status"
    }

    enum CodingKeys: String, CodingKey {
        case type
        // Register
        case hardware, models, backend, version
        case publicKey = "public_key"
        case encryptedResponseChunks = "encrypted_response_chunks"
        case walletAddress = "wallet_address"
        case attestation
        case prefillTps = "prefill_tps"
        case decodeTps = "decode_tps"
        case authToken = "auth_token"
        case pythonHash = "python_hash"
        case runtimeHash = "runtime_hash"
        case templateHashes = "template_hashes"
        case privacyCapabilities = "privacy_capabilities"
        case privateOnly = "private_only"
        // Heartbeat
        case status
        case activeModel = "active_model"
        case warmModels = "warm_models"
        case stats
        case systemMetrics = "system_metrics"
        case backendCapacity = "backend_capacity"
        // Common
        case requestId = "request_id"
        // InferenceResponseChunk
        case data
        case encryptedData = "encrypted_data"
        // InferenceComplete
        case usage
        case seSignature = "se_signature"
        case responseHash = "response_hash"
        // InferenceError
        case error
        case statusCode = "status_code"
        // AttestationResponse
        case nonce, signature
        case statusSignature = "status_signature"
        case hypervisorActive = "hypervisor_active"
        case rdmaDisabled = "rdma_disabled"
        case sipEnabled = "sip_enabled"
        case secureBootEnabled = "secure_boot_enabled"
        case binaryHash = "binary_hash"
        case activeModelHash = "active_model_hash"
        case modelHashes = "model_hashes"
        // LoadModelStatus
        case modelId = "model_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .register(let r):
            try container.encode(TypeValue.register, forKey: .type)
            try container.encode(r.hardware, forKey: .hardware)
            try container.encode(r.models, forKey: .models)
            try container.encode(r.backend, forKey: .backend)
            try container.encodeIfPresent(r.version, forKey: .version)
            try container.encodeIfPresent(r.publicKey, forKey: .publicKey)
            if r.encryptedResponseChunks {
                try container.encode(true, forKey: .encryptedResponseChunks)
            }
            try container.encodeIfPresent(r.walletAddress, forKey: .walletAddress)
            try container.encodeIfPresent(r.attestation, forKey: .attestation)
            try container.encodeIfPresent(r.prefillTps, forKey: .prefillTps)
            try container.encodeIfPresent(r.decodeTps, forKey: .decodeTps)
            try container.encodeIfPresent(r.authToken, forKey: .authToken)
            try container.encodeIfPresent(r.pythonHash, forKey: .pythonHash)
            try container.encodeIfPresent(r.runtimeHash, forKey: .runtimeHash)
            if !r.templateHashes.isEmpty {
                try container.encode(r.templateHashes, forKey: .templateHashes)
            }
            try container.encodeIfPresent(r.privacyCapabilities, forKey: .privacyCapabilities)
            if r.privateOnly {
                try container.encode(true, forKey: .privateOnly)
            }

        case .heartbeat(let h):
            try container.encode(TypeValue.heartbeat, forKey: .type)
            try container.encode(h.status, forKey: .status)
            try container.encodeIfPresent(h.activeModel, forKey: .activeModel)
            if !h.warmModels.isEmpty {
                try container.encode(h.warmModels, forKey: .warmModels)
            }
            try container.encode(h.stats, forKey: .stats)
            try container.encode(h.systemMetrics, forKey: .systemMetrics)
            try container.encodeIfPresent(h.backendCapacity, forKey: .backendCapacity)

        case .inferenceAccepted(let a):
            try container.encode(TypeValue.inferenceAccepted, forKey: .type)
            try container.encode(a.requestId, forKey: .requestId)

        case .inferenceResponseChunk(let c):
            try container.encode(TypeValue.inferenceResponseChunk, forKey: .type)
            try container.encode(c.requestId, forKey: .requestId)
            if !c.data.isEmpty {
                try container.encode(c.data, forKey: .data)
            }
            try container.encodeIfPresent(c.encryptedData, forKey: .encryptedData)

        case .inferenceComplete(let c):
            try container.encode(TypeValue.inferenceComplete, forKey: .type)
            try container.encode(c.requestId, forKey: .requestId)
            try container.encode(c.usage, forKey: .usage)
            try container.encodeIfPresent(c.seSignature, forKey: .seSignature)
            try container.encodeIfPresent(c.responseHash, forKey: .responseHash)

        case .inferenceError(let e):
            try container.encode(TypeValue.inferenceError, forKey: .type)
            try container.encode(e.requestId, forKey: .requestId)
            try container.encode(e.error, forKey: .error)
            try container.encode(e.statusCode, forKey: .statusCode)

        case .attestationResponse(let a):
            try container.encode(TypeValue.attestationResponse, forKey: .type)
            try container.encode(a.nonce, forKey: .nonce)
            try container.encode(a.signature, forKey: .signature)
            try container.encodeIfPresent(a.statusSignature, forKey: .statusSignature)
            try container.encode(a.publicKey, forKey: .publicKey)
            try container.encodeIfPresent(a.hypervisorActive, forKey: .hypervisorActive)
            try container.encodeIfPresent(a.rdmaDisabled, forKey: .rdmaDisabled)
            try container.encodeIfPresent(a.sipEnabled, forKey: .sipEnabled)
            try container.encodeIfPresent(a.secureBootEnabled, forKey: .secureBootEnabled)
            try container.encodeIfPresent(a.binaryHash, forKey: .binaryHash)
            try container.encodeIfPresent(a.activeModelHash, forKey: .activeModelHash)
            try container.encodeIfPresent(a.pythonHash, forKey: .pythonHash)
            try container.encodeIfPresent(a.runtimeHash, forKey: .runtimeHash)
            if !a.templateHashes.isEmpty {
                try container.encode(a.templateHashes, forKey: .templateHashes)
            }
            if !a.modelHashes.isEmpty {
                try container.encode(a.modelHashes, forKey: .modelHashes)
            }

        case .loadModelStatus(let l):
            try container.encode(TypeValue.loadModelStatus, forKey: .type)
            try container.encode(l.modelId, forKey: .modelId)
            try container.encode(l.status.rawValue, forKey: .status)
            try container.encodeIfPresent(l.error, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeValue.self, forKey: .type)

        switch type {
        case .register:
            self = .register(Register(
                hardware: try container.decode(HardwareInfo.self, forKey: .hardware),
                models: try container.decode([ModelInfo].self, forKey: .models),
                backend: try container.decode(String.self, forKey: .backend),
                version: try container.decodeIfPresent(String.self, forKey: .version),
                publicKey: try container.decodeIfPresent(String.self, forKey: .publicKey),
                encryptedResponseChunks: try container.decodeIfPresent(Bool.self, forKey: .encryptedResponseChunks) ?? false,
                walletAddress: try container.decodeIfPresent(String.self, forKey: .walletAddress),
                attestation: try container.decodeIfPresent(RawJSON.self, forKey: .attestation),
                prefillTps: try container.decodeIfPresent(Double.self, forKey: .prefillTps),
                decodeTps: try container.decodeIfPresent(Double.self, forKey: .decodeTps),
                authToken: try container.decodeIfPresent(String.self, forKey: .authToken),
                pythonHash: try container.decodeIfPresent(String.self, forKey: .pythonHash),
                runtimeHash: try container.decodeIfPresent(String.self, forKey: .runtimeHash),
                templateHashes: try container.decodeIfPresent([String: String].self, forKey: .templateHashes) ?? [:],
                privacyCapabilities: try container.decodeIfPresent(PrivacyCapabilities.self, forKey: .privacyCapabilities),
                privateOnly: try container.decodeIfPresent(Bool.self, forKey: .privateOnly) ?? false
            ))

        case .heartbeat:
            self = .heartbeat(Heartbeat(
                status: try container.decode(ProviderStatus.self, forKey: .status),
                activeModel: try container.decodeIfPresent(String.self, forKey: .activeModel),
                warmModels: try container.decodeIfPresent([String].self, forKey: .warmModels) ?? [],
                stats: try container.decode(ProviderStats.self, forKey: .stats),
                systemMetrics: try container.decode(SystemMetrics.self, forKey: .systemMetrics),
                backendCapacity: try container.decodeIfPresent(BackendCapacity.self, forKey: .backendCapacity)
            ))

        case .inferenceAccepted:
            self = .inferenceAccepted(InferenceAccepted(
                requestId: try container.decode(String.self, forKey: .requestId)
            ))

        case .inferenceResponseChunk:
            self = .inferenceResponseChunk(InferenceResponseChunk(
                requestId: try container.decode(String.self, forKey: .requestId),
                data: try container.decodeIfPresent(String.self, forKey: .data) ?? "",
                encryptedData: try container.decodeIfPresent(EncryptedPayload.self, forKey: .encryptedData)
            ))

        case .inferenceComplete:
            self = .inferenceComplete(InferenceComplete(
                requestId: try container.decode(String.self, forKey: .requestId),
                usage: try container.decode(UsageInfo.self, forKey: .usage),
                seSignature: try container.decodeIfPresent(String.self, forKey: .seSignature),
                responseHash: try container.decodeIfPresent(String.self, forKey: .responseHash)
            ))

        case .inferenceError:
            self = .inferenceError(InferenceError(
                requestId: try container.decode(String.self, forKey: .requestId),
                error: try container.decode(String.self, forKey: .error),
                statusCode: try container.decode(UInt16.self, forKey: .statusCode)
            ))

        case .attestationResponse:
            self = .attestationResponse(AttestationResponse(
                nonce: try container.decode(String.self, forKey: .nonce),
                signature: try container.decode(String.self, forKey: .signature),
                statusSignature: try container.decodeIfPresent(String.self, forKey: .statusSignature),
                publicKey: try container.decode(String.self, forKey: .publicKey),
                hypervisorActive: try container.decodeIfPresent(Bool.self, forKey: .hypervisorActive),
                rdmaDisabled: try container.decodeIfPresent(Bool.self, forKey: .rdmaDisabled),
                sipEnabled: try container.decodeIfPresent(Bool.self, forKey: .sipEnabled),
                secureBootEnabled: try container.decodeIfPresent(Bool.self, forKey: .secureBootEnabled),
                binaryHash: try container.decodeIfPresent(String.self, forKey: .binaryHash),
                activeModelHash: try container.decodeIfPresent(String.self, forKey: .activeModelHash),
                pythonHash: try container.decodeIfPresent(String.self, forKey: .pythonHash),
                runtimeHash: try container.decodeIfPresent(String.self, forKey: .runtimeHash),
                templateHashes: try container.decodeIfPresent([String: String].self, forKey: .templateHashes) ?? [:],
                modelHashes: try container.decodeIfPresent([String: String].self, forKey: .modelHashes) ?? [:]
            ))

        case .loadModelStatus:
            let raw = try container.decode(String.self, forKey: .status)
            guard let status = LoadModelStatus.Status(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "unknown load_model_status value: \(raw)"
                )
            }
            self = .loadModelStatus(LoadModelStatus(
                modelId: try container.decode(String.self, forKey: .modelId),
                status: status,
                error: try container.decodeIfPresent(String.self, forKey: .error)
            ))
        }
    }
}

// MARK: - Coordinator -> Provider

public enum CoordinatorMessage: Sendable, Equatable {
    case inferenceRequest(InferenceRequest)
    case cancel(Cancel)
    case attestationChallenge(AttestationChallenge)
    case runtimeStatus(RuntimeStatus)
    case loadModel(LoadModel)
    case trustStatus(TrustStatus)

    public struct InferenceRequest: Sendable, Equatable {
        public var requestId: String
        public var body: JSONValue
        public var encryptedBody: EncryptedPayload?

        public init(requestId: String, body: JSONValue = .null, encryptedBody: EncryptedPayload? = nil) {
            self.requestId = requestId
            self.body = body
            self.encryptedBody = encryptedBody
        }
    }

    public struct Cancel: Sendable, Equatable {
        public var requestId: String
        public init(requestId: String) { self.requestId = requestId }
    }

    public struct AttestationChallenge: Sendable, Equatable {
        public var nonce: String
        public var timestamp: String
        public init(nonce: String, timestamp: String) {
            self.nonce = nonce
            self.timestamp = timestamp
        }
    }

    public struct RuntimeStatus: Sendable, Equatable {
        public var verified: Bool
        public var mismatches: [RuntimeMismatch]
        public init(verified: Bool, mismatches: [RuntimeMismatch] = []) {
            self.verified = verified
            self.mismatches = mismatches
        }
    }

    /// Coordinator-driven model preload. Provider should eagerly load the
    /// named model (no inference attached) so subsequent requests find it
    /// already warm. Reply asynchronously with a `loadModelStatus`
    /// `ProviderMessage` when the load completes or fails.
    public struct LoadModel: Sendable, Equatable {
        public var modelId: String
        public init(modelId: String) { self.modelId = modelId }
    }

    /// Coordinator informs the provider of its current trust level and status.
    /// Providers that learn they are "self_signed" or "untrusted" can
    /// auto-report unified logs for troubleshooting.
    public struct TrustStatus: Sendable, Equatable {
        public var trustLevel: String
        public var status: String
        public var reason: String
        public init(trustLevel: String, status: String, reason: String = "") {
            self.trustLevel = trustLevel
            self.status = status
            self.reason = reason
        }
    }
}

// MARK: - CoordinatorMessage Codable

extension CoordinatorMessage: Codable {
    enum TypeValue: String, Codable {
        case inferenceRequest = "inference_request"
        case cancel
        case attestationChallenge = "attestation_challenge"
        case runtimeStatus = "runtime_status"
        case loadModel = "load_model"
        case trustStatus = "trust_status"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case body
        case encryptedBody = "encrypted_body"
        case nonce, timestamp
        case verified, mismatches
        case modelId = "model_id"
        case trustLevel = "trust_level"
        case status, reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .inferenceRequest(let r):
            try container.encode(TypeValue.inferenceRequest, forKey: .type)
            try container.encode(r.requestId, forKey: .requestId)
            try container.encode(r.body, forKey: .body)
            try container.encodeIfPresent(r.encryptedBody, forKey: .encryptedBody)

        case .cancel(let c):
            try container.encode(TypeValue.cancel, forKey: .type)
            try container.encode(c.requestId, forKey: .requestId)

        case .attestationChallenge(let a):
            try container.encode(TypeValue.attestationChallenge, forKey: .type)
            try container.encode(a.nonce, forKey: .nonce)
            try container.encode(a.timestamp, forKey: .timestamp)

        case .runtimeStatus(let s):
            try container.encode(TypeValue.runtimeStatus, forKey: .type)
            try container.encode(s.verified, forKey: .verified)
            if !s.mismatches.isEmpty {
                try container.encode(s.mismatches, forKey: .mismatches)
            }

        case .loadModel(let l):
            try container.encode(TypeValue.loadModel, forKey: .type)
            try container.encode(l.modelId, forKey: .modelId)

        case .trustStatus(let t):
            try container.encode(TypeValue.trustStatus, forKey: .type)
            try container.encode(t.trustLevel, forKey: .trustLevel)
            try container.encode(t.status, forKey: .status)
            if !t.reason.isEmpty {
                try container.encode(t.reason, forKey: .reason)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeValue.self, forKey: .type)

        switch type {
        case .inferenceRequest:
            self = .inferenceRequest(InferenceRequest(
                requestId: try container.decode(String.self, forKey: .requestId),
                body: try container.decodeIfPresent(JSONValue.self, forKey: .body) ?? .null,
                encryptedBody: try container.decodeIfPresent(EncryptedPayload.self, forKey: .encryptedBody)
            ))

        case .cancel:
            self = .cancel(Cancel(
                requestId: try container.decode(String.self, forKey: .requestId)
            ))

        case .attestationChallenge:
            self = .attestationChallenge(AttestationChallenge(
                nonce: try container.decode(String.self, forKey: .nonce),
                timestamp: try container.decode(String.self, forKey: .timestamp)
            ))

        case .runtimeStatus:
            self = .runtimeStatus(RuntimeStatus(
                verified: try container.decode(Bool.self, forKey: .verified),
                mismatches: try container.decodeIfPresent([RuntimeMismatch].self, forKey: .mismatches) ?? []
            ))

        case .loadModel:
            self = .loadModel(LoadModel(
                modelId: try container.decode(String.self, forKey: .modelId)
            ))

        case .trustStatus:
            self = .trustStatus(TrustStatus(
                trustLevel: try container.decode(String.self, forKey: .trustLevel),
                status: try container.decode(String.self, forKey: .status),
                reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            ))
        }
    }
}
