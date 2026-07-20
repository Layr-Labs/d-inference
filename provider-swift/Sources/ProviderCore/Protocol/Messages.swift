import Foundation

public struct PrefixCacheV2Capability: Codable, Sendable, Equatable {
    public let modelId: String
    public let modelAggregateHash: String
    public let promptContractId: String
    public let blockHashVersion: String
    public let blockSize: UInt32
    public let cacheEpoch: String
    public let enabled: Bool
    public let ready: Bool

    public init(
        modelId: String,
        modelAggregateHash: String,
        promptContractId: String,
        blockHashVersion: String,
        blockSize: UInt32,
        cacheEpoch: String,
        enabled: Bool,
        ready: Bool
    ) {
        self.modelId = modelId
        self.modelAggregateHash = modelAggregateHash
        self.promptContractId = promptContractId
        self.blockHashVersion = blockHashVersion
        self.blockSize = blockSize
        self.cacheEpoch = cacheEpoch
        self.enabled = enabled
        self.ready = ready
    }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case modelAggregateHash = "model_aggregate_hash"
        case promptContractId = "prompt_contract_id"
        case blockHashVersion = "block_hash_version"
        case blockSize = "block_size"
        case cacheEpoch = "cache_epoch"
        case enabled, ready
    }
}

public struct PrefixCacheAnchor: Codable, Sendable, Equatable {
    public let chainHash: String
    public let tokenCount: UInt64

    public init(chainHash: String, tokenCount: UInt64) {
        self.chainHash = chainHash
        self.tokenCount = tokenCount
    }

    enum CodingKeys: String, CodingKey {
        case chainHash = "chain_hash"
        case tokenCount = "token_count"
    }
}

// MARK: - Provider -> Coordinator

public enum ProviderMessage: Sendable, Equatable {
    case register(Register)
    case heartbeat(Heartbeat)
    case inferenceAccepted(InferenceAccepted)
    case inferenceResponseChunk(InferenceResponseChunk)
    case inferenceComplete(InferenceComplete)
    case inferenceError(InferenceError)
    case attestationResponse(AttestationResponse)
    case codeAttestationResponse(CodeAttestationResponse)
    case loadModelStatus(LoadModelStatus)
    case prefetchModelStatus(PrefetchModelStatus)
    case modelsUpdate(ModelsUpdate)
    case prefixCacheLookup(PrefixCacheLookup)
    case prefixCacheReady(PrefixCacheReady)
    case prefixCacheLookupV2(PrefixCacheLookupV2)
    case prefixCacheReadyV2(PrefixCacheReadyV2)

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
        /// APNs code-identity attestation (v0.6.0). Device token the coordinator
        /// pushes the E_K(nonce) challenge to + which APNs environment it belongs
        /// to. Mirrors RegisterMessage.APNsDeviceToken/APNsEnvironment (Go).
        public var apnsDeviceToken: String?
        public var apnsEnvironment: String?
        /// Provider-confirmed prefix-cache protocol version. Omitted by legacy
        /// providers; only version 2 carries exact, provider-proven ownership.
        public var prefixCacheProtocol: Int?
        public var prefixCacheV2Models: [PrefixCacheV2Capability]?
        /// Inference-time tool grammar capability. Protocol 1 is advertised
        /// only with concrete model IDs whose Gemma contract is enforced.
        public var toolConstraintProtocol: Int?
        public var toolConstraintModels: [String]?

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
            privateOnly: Bool = false,
            apnsDeviceToken: String? = nil,
            apnsEnvironment: String? = nil,
            prefixCacheProtocol: Int? = nil,
            prefixCacheV2Models: [PrefixCacheV2Capability]? = nil,
            toolConstraintProtocol: Int? = nil,
            toolConstraintModels: [String]? = nil
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
            self.apnsDeviceToken = apnsDeviceToken
            self.apnsEnvironment = apnsEnvironment
            self.prefixCacheProtocol = prefixCacheProtocol
            self.prefixCacheV2Models = prefixCacheV2Models
            self.toolConstraintProtocol = toolConstraintProtocol
            self.toolConstraintModels = toolConstraintModels
        }
    }

    public struct Heartbeat: Sendable, Equatable {
        public var status: ProviderStatus
        public var activeModel: String?
        public var warmModels: [String]
        public var stats: ProviderStats
        public var systemMetrics: SystemMetrics
        public var backendCapacity: BackendCapacity?
        /// APNs code-identity attestation (W5 Fix 2). Carries the device token (and
        /// its APNs environment) in the heartbeat so a coordinator can re-arm a
        /// code-identity challenge WITHOUT a reconnect when the token arrived after
        /// registration (headless/late-token Mac) or rotated mid-connection.
        /// Mirrors HeartbeatMessage.APNsDeviceToken/APNsEnvironment (Go). nil/omitted
        /// in the steady state. The token never grants attestation on its own — it
        /// only lets the coordinator send a challenge.
        public var apnsDeviceToken: String?
        public var apnsEnvironment: String?
        public var prefixCacheProtocol: Int?
        public var prefixCacheV2Models: [PrefixCacheV2Capability]?

        public init(
            status: ProviderStatus,
            activeModel: String? = nil,
            warmModels: [String] = [],
            stats: ProviderStats,
            systemMetrics: SystemMetrics,
            backendCapacity: BackendCapacity? = nil,
            apnsDeviceToken: String? = nil,
            apnsEnvironment: String? = nil,
            prefixCacheProtocol: Int? = nil,
            prefixCacheV2Models: [PrefixCacheV2Capability]? = nil
        ) {
            self.status = status
            self.activeModel = activeModel
            self.warmModels = warmModels
            self.stats = stats
            self.systemMetrics = systemMetrics
            self.backendCapacity = backendCapacity
            self.apnsDeviceToken = apnsDeviceToken
            self.apnsEnvironment = apnsEnvironment
            self.prefixCacheProtocol = prefixCacheProtocol
            self.prefixCacheV2Models = prefixCacheV2Models
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
        public var stopSequence: String?
        public var seSignature: String?
        public var responseHash: String?

        public init(
            requestId: String,
            usage: UsageInfo,
            stopSequence: String? = nil,
            seSignature: String? = nil,
            responseHash: String? = nil
        ) {
            self.requestId = requestId
            self.usage = usage
            self.stopSequence = stopSequence
            self.seSignature = seSignature
            self.responseHash = responseHash
        }
    }

    public struct InferenceError: Sendable, Equatable {
        public var requestId: String
        public var error: String
        public var statusCode: UInt16
        /// Normalized, privacy-safe failure reason (DAR-341). One of the shared
        /// `error_reason` vocabulary values — "jinja_channel_tags",
        /// "jinja_null_bridge", "jinja_template", "model_load" — or nil when the
        /// provider cannot confidently classify the failure (the coordinator then
        /// derives a reason from status/class). Omitted on the wire when nil.
        public var errorReason: String?

        public init(requestId: String, error: String, statusCode: UInt16, errorReason: String? = nil) {
            self.requestId = requestId
            self.error = error
            self.statusCode = statusCode
            self.errorReason = errorReason
        }
    }

    public struct PrefixCacheLookup: Sendable, Equatable {
        public var requestId: String
        public var cacheReceiptNonce: String
        public var outcome: PrefixCacheLookupOutcome
        public var tier: PrefixCacheTier?
        public var cachedTokens: UInt64?
        public var prefillTokensSaved: UInt64?
        public var stageMs: Double?

        public init(
            requestId: String,
            cacheReceiptNonce: String,
            outcome: PrefixCacheLookupOutcome,
            tier: PrefixCacheTier? = nil,
            cachedTokens: UInt64? = nil,
            prefillTokensSaved: UInt64? = nil,
            stageMs: Double? = nil
        ) {
            self.requestId = requestId
            self.cacheReceiptNonce = cacheReceiptNonce
            self.outcome = outcome
            self.tier = tier
            self.cachedTokens = cachedTokens
            self.prefillTokensSaved = prefillTokensSaved
            self.stageMs = stageMs
        }
    }

    public struct PrefixCacheReady: Sendable, Equatable {
        public var requestId: String
        public var cacheReceiptNonce: String
        public var readyTokens: UInt64
        public var requiredRecomputeTokens: UInt64
        public var expectedPrefillTokensSaved: UInt64
        public var tier: PrefixCacheTier
        public var stageMs: Double?

        public init(
            requestId: String,
            cacheReceiptNonce: String,
            readyTokens: UInt64,
            requiredRecomputeTokens: UInt64,
            expectedPrefillTokensSaved: UInt64,
            tier: PrefixCacheTier,
            stageMs: Double? = nil
        ) {
            self.requestId = requestId
            self.cacheReceiptNonce = cacheReceiptNonce
            self.readyTokens = readyTokens
            self.requiredRecomputeTokens = requiredRecomputeTokens
            self.expectedPrefillTokensSaved = expectedPrefillTokensSaved
            self.tier = tier
            if let stageMs, stageMs.isFinite {
                self.stageMs = min(PrefixCacheReadyResult.maxStageMs, max(0, stageMs))
            } else {
                self.stageMs = nil
            }
        }
    }

    public struct PrefixCacheLookupV2: Sendable, Equatable {
        public let requestId: String
        public let cacheReceiptNonce: String
        public let modelId: String
        public let modelAggregateHash: String
        public let promptContractId: String
        public let cacheEpoch: String
        public let cacheSeq: UInt64
        public let promptAnchor: PrefixCacheAnchor
        public let matchedAnchor: PrefixCacheAnchor?
        public let outcome: PrefixCacheLookupOutcome
        public let tier: PrefixCacheTier?
        public let requiredRecomputeTokens: UInt64
        public let expectedPrefillTokensSaved: UInt64
        public let stageMs: Double?

        public init(
            requestId: String,
            cacheReceiptNonce: String,
            modelId: String,
            modelAggregateHash: String,
            promptContractId: String,
            cacheEpoch: String,
            cacheSeq: UInt64,
            promptAnchor: PrefixCacheAnchor,
            matchedAnchor: PrefixCacheAnchor?,
            outcome: PrefixCacheLookupOutcome,
            tier: PrefixCacheTier?,
            requiredRecomputeTokens: UInt64,
            expectedPrefillTokensSaved: UInt64,
            stageMs: Double?
        ) {
            self.requestId = requestId
            self.cacheReceiptNonce = cacheReceiptNonce
            self.modelId = modelId
            self.modelAggregateHash = modelAggregateHash
            self.promptContractId = promptContractId
            self.cacheEpoch = cacheEpoch
            self.cacheSeq = cacheSeq
            self.promptAnchor = promptAnchor
            self.matchedAnchor = matchedAnchor
            self.outcome = outcome
            self.tier = tier
            self.requiredRecomputeTokens = requiredRecomputeTokens
            self.expectedPrefillTokensSaved = expectedPrefillTokensSaved
            self.stageMs = stageMs
        }
    }

    public struct PrefixCacheReadyV2: Sendable, Equatable {
        public let requestId: String
        public let cacheReceiptNonce: String
        public let modelId: String
        public let modelAggregateHash: String
        public let promptContractId: String
        public let cacheEpoch: String
        public let cacheSeq: UInt64
        public let outcome: String
        public let tier: PrefixCacheTier
        public let readyAnchors: [PrefixCacheAnchor]
        public let requiredRecomputeTokens: UInt64
        public let expectedPrefillTokensSaved: UInt64
        public let stageMs: Double?

        public init(
            requestId: String,
            cacheReceiptNonce: String,
            modelId: String,
            modelAggregateHash: String,
            promptContractId: String,
            cacheEpoch: String,
            cacheSeq: UInt64,
            outcome: String = "ready",
            tier: PrefixCacheTier,
            readyAnchors: [PrefixCacheAnchor],
            requiredRecomputeTokens: UInt64,
            expectedPrefillTokensSaved: UInt64,
            stageMs: Double?
        ) {
            self.requestId = requestId
            self.cacheReceiptNonce = cacheReceiptNonce
            self.modelId = modelId
            self.modelAggregateHash = modelAggregateHash
            self.promptContractId = promptContractId
            self.cacheEpoch = cacheEpoch
            self.cacheSeq = cacheSeq
            self.outcome = outcome
            self.tier = tier
            self.readyAnchors = Array(readyAnchors.prefix(2))
            self.requiredRecomputeTokens = requiredRecomputeTokens
            self.expectedPrefillTokensSaved = expectedPrefillTokensSaved
            self.stageMs = stageMs
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

    /// Progress/terminal reply to a `CoordinatorMessage.prefetchModel`. A
    /// prefetch only downloads + verifies the build on disk; it does NOT load
    /// weights into GPU. `verified` is the terminal success state (build is on
    /// disk and hash-checked, ready to advertise). `bytesDone`/`bytesTotal`
    /// are best-effort progress (0 when unknown).
    public struct PrefetchModelStatus: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            case started
            case downloading
            case verified
            case failed
        }

        public var modelId: String
        public var status: Status
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var error: String?

        public init(
            modelId: String,
            status: Status,
            bytesDone: Int64 = 0,
            bytesTotal: Int64 = 0,
            error: String? = nil
        ) {
            self.modelId = modelId
            self.status = status
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.error = error
        }
    }

    /// Authoritative, out-of-band update to the provider's advertised model
    /// inventory. Emitted after a coordinator-driven prefetch is downloaded AND
    /// verified on disk so the coordinator can cross-check the freshly-available
    /// build (including its computed weight hash) against the catalog BEFORE
    /// routing to it -- without the disruption of a full re-`register` (which
    /// would reset reputation and restart the attestation challenge loop).
    ///
    /// `models` reuses the SAME `ModelInfo` encoding as `register`'s `models[]`.
    /// Current providers also refresh model-scoped tool-constraint capability;
    /// legacy updates omit those additive fields.
    public struct ModelsUpdate: Sendable, Equatable {
        public var models: [ModelInfo]
        public var toolConstraintProtocol: Int?
        public var toolConstraintModels: [String]?

        public init(
            models: [ModelInfo],
            toolConstraintProtocol: Int? = nil,
            toolConstraintModels: [String]? = nil
        ) {
            self.models = models
            self.toolConstraintProtocol = toolConstraintProtocol
            self.toolConstraintModels = toolConstraintModels
        }
    }

    public struct AttestationResponse: Sendable, Equatable {
        public var nonce: String
        public var signature: String
        public var statusSignature: String?
        public var publicKey: String
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

    /// Reply to the APNs-delivered code-identity challenge (E_K(nonce) push).
    /// Returns the decrypted nonce (proves K-possession) + Sign_SE(nonce) (the
    /// separate SE P-256 key — K is X25519/decrypt-only). The WebSocket return
    /// leg of the push round-trip; distinct from the liveness AttestationResponse.
    /// Mirrors CodeAttestationResponseMessage (Go).
    public struct CodeAttestationResponse: Sendable, Equatable {
        public var nonce: String
        public var signature: String

        public init(nonce: String, signature: String) {
            self.nonce = nonce
            self.signature = signature
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
        case codeAttestationResponse = "code_attestation_response"
        case loadModelStatus = "load_model_status"
        case prefetchModelStatus = "prefetch_model_status"
        case modelsUpdate = "models_update"
        case prefixCacheLookup = "prefix_cache_lookup"
        case prefixCacheReady = "prefix_cache_ready"
        case prefixCacheLookupV2 = "prefix_cache_lookup_v2"
        case prefixCacheReadyV2 = "prefix_cache_ready_v2"
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
        case apnsDeviceToken = "apns_device_token"
        case apnsEnvironment = "apns_environment"
        case prefixCacheProtocol = "prefix_cache_protocol"
        case prefixCacheV2Models = "prefix_cache_v2_models"
        case toolConstraintProtocol = "tool_constraint_protocol"
        case toolConstraintModels = "tool_constraint_models"
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
        case stopSequence = "stop_sequence"
        case seSignature = "se_signature"
        case responseHash = "response_hash"
        // InferenceError
        case error
        case statusCode = "status_code"
        case errorReason = "error_reason"
        // AttestationResponse
        case nonce, signature
        case statusSignature = "status_signature"
        case rdmaDisabled = "rdma_disabled"
        case sipEnabled = "sip_enabled"
        case secureBootEnabled = "secure_boot_enabled"
        case binaryHash = "binary_hash"
        case activeModelHash = "active_model_hash"
        case modelHashes = "model_hashes"
        // LoadModelStatus
        case modelId = "model_id"
        // PrefetchModelStatus
        case bytesDone = "bytes_done"
        case bytesTotal = "bytes_total"
        // Prefix cache receipts
        case cacheReceiptNonce = "cache_receipt_nonce"
        case outcome, tier
        case cachedTokens = "cached_tokens"
        case prefillTokensSaved = "prefill_tokens_saved"
        case stageMs = "stage_ms"
        case readyTokens = "ready_tokens"
        case requiredRecomputeTokens = "required_recompute_tokens"
        case expectedPrefillTokensSaved = "expected_prefill_tokens_saved"
        case modelAggregateHash = "model_aggregate_hash"
        case promptContractId = "prompt_contract_id"
        case cacheEpoch = "cache_epoch"
        case cacheSeq = "cache_seq"
        case promptAnchor = "prompt_anchor"
        case matchedAnchor = "matched_anchor"
        case readyAnchors = "ready_anchors"
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
            try container.encodeIfPresent(r.apnsDeviceToken, forKey: .apnsDeviceToken)
            try container.encodeIfPresent(r.apnsEnvironment, forKey: .apnsEnvironment)
            if let version = r.prefixCacheProtocol, version != 0 {
                try container.encode(version, forKey: .prefixCacheProtocol)
            }
            try container.encodeIfPresent(r.prefixCacheV2Models, forKey: .prefixCacheV2Models)
            if let version = r.toolConstraintProtocol, version != 0 {
                try container.encode(version, forKey: .toolConstraintProtocol)
            }
            try container.encodeIfPresent(
                r.toolConstraintModels, forKey: .toolConstraintModels)

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
            // omitempty parity with Go: nil token/env emit nothing (steady state).
            try container.encodeIfPresent(h.apnsDeviceToken, forKey: .apnsDeviceToken)
            try container.encodeIfPresent(h.apnsEnvironment, forKey: .apnsEnvironment)
            if let version = h.prefixCacheProtocol, version != 0 {
                try container.encode(version, forKey: .prefixCacheProtocol)
            }
            try container.encodeIfPresent(h.prefixCacheV2Models, forKey: .prefixCacheV2Models)

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
            try container.encodeIfPresent(c.stopSequence, forKey: .stopSequence)
            try container.encodeIfPresent(c.seSignature, forKey: .seSignature)
            try container.encodeIfPresent(c.responseHash, forKey: .responseHash)

        case .inferenceError(let e):
            try container.encode(TypeValue.inferenceError, forKey: .type)
            try container.encode(e.requestId, forKey: .requestId)
            try container.encode(e.error, forKey: .error)
            try container.encode(e.statusCode, forKey: .statusCode)
            try container.encodeIfPresent(e.errorReason, forKey: .errorReason)

        case .attestationResponse(let a):
            try container.encode(TypeValue.attestationResponse, forKey: .type)
            try container.encode(a.nonce, forKey: .nonce)
            try container.encode(a.signature, forKey: .signature)
            try container.encodeIfPresent(a.statusSignature, forKey: .statusSignature)
            try container.encode(a.publicKey, forKey: .publicKey)
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

        case .codeAttestationResponse(let c):
            try container.encode(TypeValue.codeAttestationResponse, forKey: .type)
            try container.encode(c.nonce, forKey: .nonce)
            try container.encode(c.signature, forKey: .signature)

        case .loadModelStatus(let l):
            try container.encode(TypeValue.loadModelStatus, forKey: .type)
            try container.encode(l.modelId, forKey: .modelId)
            try container.encode(l.status.rawValue, forKey: .status)
            try container.encodeIfPresent(l.error, forKey: .error)

        case .prefetchModelStatus(let p):
            try container.encode(TypeValue.prefetchModelStatus, forKey: .type)
            try container.encode(p.modelId, forKey: .modelId)
            try container.encode(p.status.rawValue, forKey: .status)
            // Mirror the Go `omitempty` tags so the wire stays identical.
            if p.bytesDone != 0 {
                try container.encode(p.bytesDone, forKey: .bytesDone)
            }
            if p.bytesTotal != 0 {
                try container.encode(p.bytesTotal, forKey: .bytesTotal)
            }
            try container.encodeIfPresent(p.error, forKey: .error)

        case .modelsUpdate(let u):
            try container.encode(TypeValue.modelsUpdate, forKey: .type)
            // Reuse the ModelInfo encoding shared with `register`'s models[].
            try container.encode(u.models, forKey: .models)
            if let version = u.toolConstraintProtocol, version != 0 {
                try container.encode(
                    version, forKey: .toolConstraintProtocol)
            }
            try container.encodeIfPresent(
                u.toolConstraintModels, forKey: .toolConstraintModels)

        case .prefixCacheLookup(let receipt):
            try container.encode(TypeValue.prefixCacheLookup, forKey: .type)
            try container.encode(receipt.requestId, forKey: .requestId)
            try container.encode(receipt.cacheReceiptNonce, forKey: .cacheReceiptNonce)
            try container.encode(receipt.outcome, forKey: .outcome)
            try container.encodeIfPresent(receipt.tier, forKey: .tier)
            try container.encodeIfPresent(receipt.cachedTokens, forKey: .cachedTokens)
            try container.encodeIfPresent(receipt.prefillTokensSaved, forKey: .prefillTokensSaved)
            try container.encodeIfPresent(receipt.stageMs, forKey: .stageMs)

        case .prefixCacheReady(let receipt):
            try container.encode(TypeValue.prefixCacheReady, forKey: .type)
            try container.encode(receipt.requestId, forKey: .requestId)
            try container.encode(receipt.cacheReceiptNonce, forKey: .cacheReceiptNonce)
            try container.encode(receipt.readyTokens, forKey: .readyTokens)
            try container.encode(receipt.requiredRecomputeTokens, forKey: .requiredRecomputeTokens)
            try container.encode(receipt.expectedPrefillTokensSaved, forKey: .expectedPrefillTokensSaved)
            try container.encode(receipt.tier, forKey: .tier)
            try container.encodeIfPresent(receipt.stageMs, forKey: .stageMs)

        case .prefixCacheLookupV2(let receipt):
            try container.encode(TypeValue.prefixCacheLookupV2, forKey: .type)
            try container.encode(receipt.requestId, forKey: .requestId)
            try container.encode(receipt.cacheReceiptNonce, forKey: .cacheReceiptNonce)
            try container.encode(receipt.modelId, forKey: .modelId)
            try container.encode(receipt.modelAggregateHash, forKey: .modelAggregateHash)
            try container.encode(receipt.promptContractId, forKey: .promptContractId)
            try container.encode(receipt.cacheEpoch, forKey: .cacheEpoch)
            try container.encode(receipt.cacheSeq, forKey: .cacheSeq)
            try container.encode(receipt.promptAnchor, forKey: .promptAnchor)
            try container.encodeIfPresent(receipt.matchedAnchor, forKey: .matchedAnchor)
            try container.encode(receipt.outcome, forKey: .outcome)
            try container.encodeIfPresent(receipt.tier, forKey: .tier)
            try container.encode(
                receipt.requiredRecomputeTokens, forKey: .requiredRecomputeTokens)
            try container.encode(
                receipt.expectedPrefillTokensSaved, forKey: .expectedPrefillTokensSaved)
            try container.encodeIfPresent(receipt.stageMs, forKey: .stageMs)

        case .prefixCacheReadyV2(let receipt):
            try container.encode(TypeValue.prefixCacheReadyV2, forKey: .type)
            try container.encode(receipt.requestId, forKey: .requestId)
            try container.encode(receipt.cacheReceiptNonce, forKey: .cacheReceiptNonce)
            try container.encode(receipt.modelId, forKey: .modelId)
            try container.encode(receipt.modelAggregateHash, forKey: .modelAggregateHash)
            try container.encode(receipt.promptContractId, forKey: .promptContractId)
            try container.encode(receipt.cacheEpoch, forKey: .cacheEpoch)
            try container.encode(receipt.cacheSeq, forKey: .cacheSeq)
            try container.encode(receipt.outcome, forKey: .outcome)
            try container.encode(receipt.tier, forKey: .tier)
            try container.encode(receipt.readyAnchors, forKey: .readyAnchors)
            try container.encode(
                receipt.requiredRecomputeTokens, forKey: .requiredRecomputeTokens)
            try container.encode(
                receipt.expectedPrefillTokensSaved, forKey: .expectedPrefillTokensSaved)
            try container.encodeIfPresent(receipt.stageMs, forKey: .stageMs)
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
                privateOnly: try container.decodeIfPresent(Bool.self, forKey: .privateOnly) ?? false,
                apnsDeviceToken: try container.decodeIfPresent(String.self, forKey: .apnsDeviceToken),
                apnsEnvironment: try container.decodeIfPresent(String.self, forKey: .apnsEnvironment),
                prefixCacheProtocol: try container.decodeIfPresent(Int.self, forKey: .prefixCacheProtocol),
                prefixCacheV2Models: try container.decodeIfPresent(
                    [PrefixCacheV2Capability].self, forKey: .prefixCacheV2Models),
                toolConstraintProtocol: try container.decodeIfPresent(
                    Int.self, forKey: .toolConstraintProtocol),
                toolConstraintModels: try container.decodeIfPresent(
                    [String].self, forKey: .toolConstraintModels)
            ))

        case .heartbeat:
            self = .heartbeat(Heartbeat(
                status: try container.decode(ProviderStatus.self, forKey: .status),
                activeModel: try container.decodeIfPresent(String.self, forKey: .activeModel),
                warmModels: try container.decodeIfPresent([String].self, forKey: .warmModels) ?? [],
                stats: try container.decode(ProviderStats.self, forKey: .stats),
                systemMetrics: try container.decode(SystemMetrics.self, forKey: .systemMetrics),
                backendCapacity: try container.decodeIfPresent(BackendCapacity.self, forKey: .backendCapacity),
                apnsDeviceToken: try container.decodeIfPresent(String.self, forKey: .apnsDeviceToken),
                apnsEnvironment: try container.decodeIfPresent(String.self, forKey: .apnsEnvironment),
                prefixCacheProtocol: try container.decodeIfPresent(
                    Int.self, forKey: .prefixCacheProtocol),
                prefixCacheV2Models: try container.decodeIfPresent(
                    [PrefixCacheV2Capability].self, forKey: .prefixCacheV2Models)
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
                stopSequence: try container.decodeIfPresent(String.self, forKey: .stopSequence),
                seSignature: try container.decodeIfPresent(String.self, forKey: .seSignature),
                responseHash: try container.decodeIfPresent(String.self, forKey: .responseHash)
            ))

        case .inferenceError:
            self = .inferenceError(InferenceError(
                requestId: try container.decode(String.self, forKey: .requestId),
                error: try container.decode(String.self, forKey: .error),
                statusCode: try container.decode(UInt16.self, forKey: .statusCode),
                errorReason: try container.decodeIfPresent(String.self, forKey: .errorReason)
            ))

        case .attestationResponse:
            self = .attestationResponse(AttestationResponse(
                nonce: try container.decode(String.self, forKey: .nonce),
                signature: try container.decode(String.self, forKey: .signature),
                statusSignature: try container.decodeIfPresent(String.self, forKey: .statusSignature),
                publicKey: try container.decode(String.self, forKey: .publicKey),
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

        case .codeAttestationResponse:
            self = .codeAttestationResponse(CodeAttestationResponse(
                nonce: try container.decode(String.self, forKey: .nonce),
                signature: try container.decode(String.self, forKey: .signature)
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

        case .prefetchModelStatus:
            let raw = try container.decode(String.self, forKey: .status)
            guard let status = PrefetchModelStatus.Status(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "unknown prefetch_model_status value: \(raw)"
                )
            }
            self = .prefetchModelStatus(PrefetchModelStatus(
                modelId: try container.decode(String.self, forKey: .modelId),
                status: status,
                bytesDone: try container.decodeIfPresent(Int64.self, forKey: .bytesDone) ?? 0,
                bytesTotal: try container.decodeIfPresent(Int64.self, forKey: .bytesTotal) ?? 0,
                error: try container.decodeIfPresent(String.self, forKey: .error)
            ))

        case .modelsUpdate:
            self = .modelsUpdate(ModelsUpdate(
                models: try container.decode([ModelInfo].self, forKey: .models),
                toolConstraintProtocol: try container.decodeIfPresent(
                    Int.self, forKey: .toolConstraintProtocol),
                toolConstraintModels: try container.decodeIfPresent(
                    [String].self, forKey: .toolConstraintModels)
            ))

        case .prefixCacheLookup:
            self = .prefixCacheLookup(PrefixCacheLookup(
                requestId: try container.decode(String.self, forKey: .requestId),
                cacheReceiptNonce: try container.decode(String.self, forKey: .cacheReceiptNonce),
                outcome: try container.decode(PrefixCacheLookupOutcome.self, forKey: .outcome),
                tier: try container.decodeIfPresent(PrefixCacheTier.self, forKey: .tier),
                cachedTokens: try container.decodeIfPresent(UInt64.self, forKey: .cachedTokens),
                prefillTokensSaved: try container.decodeIfPresent(UInt64.self, forKey: .prefillTokensSaved),
                stageMs: try container.decodeIfPresent(Double.self, forKey: .stageMs)
            ))

        case .prefixCacheReady:
            self = .prefixCacheReady(PrefixCacheReady(
                requestId: try container.decode(String.self, forKey: .requestId),
                cacheReceiptNonce: try container.decode(String.self, forKey: .cacheReceiptNonce),
                readyTokens: try container.decode(UInt64.self, forKey: .readyTokens),
                requiredRecomputeTokens: try container.decode(UInt64.self, forKey: .requiredRecomputeTokens),
                expectedPrefillTokensSaved: try container.decode(UInt64.self, forKey: .expectedPrefillTokensSaved),
                tier: try container.decode(PrefixCacheTier.self, forKey: .tier),
                stageMs: try container.decodeIfPresent(Double.self, forKey: .stageMs)
            ))

        case .prefixCacheLookupV2:
            self = .prefixCacheLookupV2(PrefixCacheLookupV2(
                requestId: try container.decode(String.self, forKey: .requestId),
                cacheReceiptNonce: try container.decode(String.self, forKey: .cacheReceiptNonce),
                modelId: try container.decode(String.self, forKey: .modelId),
                modelAggregateHash: try container.decode(
                    String.self, forKey: .modelAggregateHash),
                promptContractId: try container.decode(String.self, forKey: .promptContractId),
                cacheEpoch: try container.decode(String.self, forKey: .cacheEpoch),
                cacheSeq: try container.decode(UInt64.self, forKey: .cacheSeq),
                promptAnchor: try container.decode(PrefixCacheAnchor.self, forKey: .promptAnchor),
                matchedAnchor: try container.decodeIfPresent(
                    PrefixCacheAnchor.self, forKey: .matchedAnchor),
                outcome: try container.decode(PrefixCacheLookupOutcome.self, forKey: .outcome),
                tier: try container.decodeIfPresent(PrefixCacheTier.self, forKey: .tier),
                requiredRecomputeTokens: try container.decode(
                    UInt64.self, forKey: .requiredRecomputeTokens),
                expectedPrefillTokensSaved: try container.decode(
                    UInt64.self, forKey: .expectedPrefillTokensSaved),
                stageMs: try container.decodeIfPresent(Double.self, forKey: .stageMs)
            ))

        case .prefixCacheReadyV2:
            self = .prefixCacheReadyV2(PrefixCacheReadyV2(
                requestId: try container.decode(String.self, forKey: .requestId),
                cacheReceiptNonce: try container.decode(String.self, forKey: .cacheReceiptNonce),
                modelId: try container.decode(String.self, forKey: .modelId),
                modelAggregateHash: try container.decode(
                    String.self, forKey: .modelAggregateHash),
                promptContractId: try container.decode(String.self, forKey: .promptContractId),
                cacheEpoch: try container.decode(String.self, forKey: .cacheEpoch),
                cacheSeq: try container.decode(UInt64.self, forKey: .cacheSeq),
                outcome: try container.decode(String.self, forKey: .outcome),
                tier: try container.decode(PrefixCacheTier.self, forKey: .tier),
                readyAnchors: try container.decode(
                    [PrefixCacheAnchor].self, forKey: .readyAnchors),
                requiredRecomputeTokens: try container.decode(
                    UInt64.self, forKey: .requiredRecomputeTokens),
                expectedPrefillTokensSaved: try container.decode(
                    UInt64.self, forKey: .expectedPrefillTokensSaved),
                stageMs: try container.decodeIfPresent(Double.self, forKey: .stageMs)
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
    case prefetchModel(PrefetchModel)
    case desiredModels(DesiredModels)
    case trustStatus(TrustStatus)

    public struct InferenceRequest: Sendable, Equatable {
        public var requestId: String
        public var body: JSONValue
        public var encryptedBody: EncryptedPayload?
        public var cacheReceiptNonce: String?
        public var cacheScope: String?
        public var prefixCacheProtocol: Int?

        public init(
            requestId: String,
            body: JSONValue = .null,
            encryptedBody: EncryptedPayload? = nil,
            cacheReceiptNonce: String? = nil,
            cacheScope: String? = nil,
            prefixCacheProtocol: Int? = nil
        ) {
            self.requestId = requestId
            self.body = body
            self.encryptedBody = encryptedBody
            self.cacheReceiptNonce = cacheReceiptNonce
            self.cacheScope = cacheScope
            self.prefixCacheProtocol = prefixCacheProtocol
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

    /// Coordinator-driven background prefetch. Provider should download AND
    /// verify the named build on disk WITHOUT loading it into GPU and without
    /// disrupting the model it is currently serving, then reply with
    /// `prefetchModelStatus` messages (terminal: `verified`). `priority` is an
    /// advisory ordering hint for concurrent prefetches (higher = sooner).
    public struct PrefetchModel: Sendable, Equatable {
        public var modelId: String
        public var priority: Int
        public init(modelId: String, priority: Int = 0) {
            self.modelId = modelId
            self.priority = priority
        }
    }

    /// One public model name's desired build, from the coordinator's declarative
    /// desired-state. `previousBuild` (if present) stays acceptable during a
    /// staggered rollout.
    public struct DesiredModelEntry: Sendable, Equatable, Codable {
        public var modelName: String
        public var desiredBuild: String
        public var previousBuild: String?
        public init(modelName: String, desiredBuild: String, previousBuild: String? = nil) {
            self.modelName = modelName
            self.desiredBuild = desiredBuild
            self.previousBuild = previousBuild
        }
        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case desiredBuild = "desired_build"
            case previousBuild = "previous_build"
        }
    }

    /// Declarative desired-build map (Coordinator → Provider). Sent after register
    /// and whenever a desired build changes. The provider reconciles each entry:
    /// background-prefetch the desired build if missing, then hard-swap (advertise
    /// the new build, drop the previous) and emit a models_update once verified.
    public struct DesiredModels: Sendable, Equatable {
        public var models: [DesiredModelEntry]
        public init(models: [DesiredModelEntry]) { self.models = models }
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
        case prefetchModel = "prefetch_model"
        case desiredModels = "desired_models"
        case trustStatus = "trust_status"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case body
        case encryptedBody = "encrypted_body"
        case cacheReceiptNonce = "cache_receipt_nonce"
        case cacheScope = "cache_scope"
        case prefixCacheProtocol = "prefix_cache_protocol"
        case nonce, timestamp
        case verified, mismatches
        case modelId = "model_id"
        case priority
        case trustLevel = "trust_level"
        case status, reason
        case models
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .inferenceRequest(let r):
            try container.encode(TypeValue.inferenceRequest, forKey: .type)
            try container.encode(r.requestId, forKey: .requestId)
            try container.encode(r.body, forKey: .body)
            try container.encodeIfPresent(r.encryptedBody, forKey: .encryptedBody)
            try container.encodeIfPresent(r.cacheReceiptNonce, forKey: .cacheReceiptNonce)
            try container.encodeIfPresent(r.cacheScope, forKey: .cacheScope)
            try container.encodeIfPresent(r.prefixCacheProtocol, forKey: .prefixCacheProtocol)

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

        case .prefetchModel(let p):
            try container.encode(TypeValue.prefetchModel, forKey: .type)
            try container.encode(p.modelId, forKey: .modelId)
            // Mirror the Go `omitempty` tag on priority.
            if p.priority != 0 {
                try container.encode(p.priority, forKey: .priority)
            }

        case .desiredModels(let d):
            try container.encode(TypeValue.desiredModels, forKey: .type)
            try container.encode(d.models, forKey: .models)

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
                encryptedBody: try container.decodeIfPresent(EncryptedPayload.self, forKey: .encryptedBody),
                cacheReceiptNonce: try container.decodeIfPresent(String.self, forKey: .cacheReceiptNonce),
                cacheScope: try container.decodeIfPresent(String.self, forKey: .cacheScope),
                prefixCacheProtocol: try container.decodeIfPresent(
                    Int.self, forKey: .prefixCacheProtocol)
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

        case .prefetchModel:
            self = .prefetchModel(PrefetchModel(
                modelId: try container.decode(String.self, forKey: .modelId),
                priority: try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
            ))

        case .desiredModels:
            self = .desiredModels(DesiredModels(
                models: try container.decodeIfPresent([DesiredModelEntry].self, forKey: .models) ?? []
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
