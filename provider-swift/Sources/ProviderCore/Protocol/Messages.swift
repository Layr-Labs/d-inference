import Foundation

public enum PrefixCacheStatusBackend: String, Codable, Sendable, Equatable, CaseIterable {
    case contiguous
    case paged
    case unknown
}

public enum PrefixCacheReplayStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    case direct
    case frozenFull = "frozen_full"
    case tailReplay = "tail_replay"
    case none
    case unknown
}

public enum PrefixCacheStatusState: String, Codable, Sendable, Equatable, CaseIterable {
    case ready
    case pending
    case disabled
    case error
}

public enum PrefixCacheStatusReason: String, Codable, Sendable, Equatable, CaseIterable {
    case ready
    case configDisabled = "config_disabled"
    case weightHashUnavailable = "weight_hash_unavailable"
    case runtimeIdentityUnavailable = "runtime_identity_unavailable"
    case unsupportedLayout = "unsupported_layout"
    case unsupportedBackend = "unsupported_backend"
    case pagedHybridUnsupported = "paged_hybrid_unsupported"
    case scanPending = "scan_pending"
    case scanFailed = "scan_failed"
    case diskUnavailable = "disk_unavailable"
    case cacheInitFailed = "cache_init_failed"
}

public struct PrefixCacheModelStatus: Codable, Sendable, Equatable {
    public let modelId: String
    public let backend: PrefixCacheStatusBackend
    public let replayStrategy: PrefixCacheReplayStrategy
    public let state: PrefixCacheStatusState
    public let reason: PrefixCacheStatusReason

    public init(
        modelId: String,
        backend: PrefixCacheStatusBackend,
        replayStrategy: PrefixCacheReplayStrategy,
        state: PrefixCacheStatusState,
        reason: PrefixCacheStatusReason
    ) {
        self.modelId = modelId
        self.backend = backend
        self.replayStrategy = replayStrategy
        self.state = state
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case backend
        case replayStrategy = "replay_strategy"
        case state
        case reason
    }
}

public enum PrefixCacheDonationOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case donated
    case belowEffectiveTokenFloor = "below_effective_token_floor"
    case noCompleteBlock = "no_complete_block"
    /// Retained for wire compatibility with pre-0.8.0 providers; the
    /// producing guard was removed in the kv-quant removal (no cache
    /// backend reports a lossy snapshot any more). The coordinator's
    /// `registry/cache_eligibility.go` still lists `lossy_snapshot`, so
    /// this case must not be dropped during the v0.8.0 rollout window.
    case lossySnapshot = "lossy_snapshot"
    case incompleteLayerState = "incomplete_layer_state"
    case stageSizeExceeded = "stage_size_exceeded"
    case writeRateLimited = "write_rate_limited"
    case writeQueueFull = "write_queue_full"
    case alreadyDurable = "already_durable"
    case alreadyQueued = "already_queued"
    case cacheClosed = "cache_closed"
    case diskUnavailable = "disk_unavailable"
    case writeFailed = "write_failed"
}

public struct PrefixCacheDonationOutcomeCount: Codable, Sendable, Equatable {
    public let outcome: PrefixCacheDonationOutcome
    public let count: UInt64

    public init(outcome: PrefixCacheDonationOutcome, count: UInt64) {
        self.outcome = outcome
        self.count = count
    }
}

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
    case capacityQuote(CapacityQuote)

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
        public var runtimeCapabilities: [ProviderRuntimeCapability]
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
        public var prefixCacheStatuses: [PrefixCacheModelStatus]?
        public var prefixCacheDonationOutcomes: [PrefixCacheDonationOutcomeCount]?
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
            runtimeCapabilities: [ProviderRuntimeCapability] = [],
            privateOnly: Bool = false,
            apnsDeviceToken: String? = nil,
            apnsEnvironment: String? = nil,
            prefixCacheProtocol: Int? = nil,
            prefixCacheV2Models: [PrefixCacheV2Capability]? = nil,
            prefixCacheStatuses: [PrefixCacheModelStatus]? = nil,
            prefixCacheDonationOutcomes: [PrefixCacheDonationOutcomeCount]? = nil,
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
            self.runtimeCapabilities = runtimeCapabilities.sorted()
            self.privateOnly = privateOnly
            self.apnsDeviceToken = apnsDeviceToken
            self.apnsEnvironment = apnsEnvironment
            self.prefixCacheProtocol = prefixCacheProtocol
            self.prefixCacheV2Models = prefixCacheV2Models
            self.prefixCacheStatuses = prefixCacheStatuses
            self.prefixCacheDonationOutcomes = prefixCacheDonationOutcomes
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
        public var prefixCacheStatuses: [PrefixCacheModelStatus]?
        public var prefixCacheDonationOutcomes: [PrefixCacheDonationOutcomeCount]?

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
            prefixCacheV2Models: [PrefixCacheV2Capability]? = nil,
            prefixCacheStatuses: [PrefixCacheModelStatus]? = nil,
            prefixCacheDonationOutcomes: [PrefixCacheDonationOutcomeCount]? = nil
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
            self.prefixCacheStatuses = prefixCacheStatuses
            self.prefixCacheDonationOutcomes = prefixCacheDonationOutcomes
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
        public let requestId: String
        /// Closed privacy-safe category. Present on all new-provider messages;
        /// nil only when decoding a legacy or future-unknown wire value.
        public let failureCode: InferenceFailureCode?
        /// Fixed compatibility text derived from `failureCode`. Raw error
        /// descriptions are never stored or accepted by the outbound initializer.
        public var error: String { (failureCode ?? .internalFailure).message }
        public let statusCode: UInt16
        /// Normalized, privacy-safe failure reason (DAR-341). One of the shared
        /// `error_reason` vocabulary values — "jinja_channel_tags",
        /// "jinja_null_bridge", "jinja_template", "model_load",
        /// "deadline_unreachable", and the bounded capacity/client reasons — or
        /// nil when the provider cannot confidently classify the failure.
        /// Omitted on the wire when nil.
        public let errorReason: InferenceErrorReason?
        /// Typed terminal cause for this error (closed vocabulary, mirrored by
        /// the coordinator's Go `terminal_cause` field). Present for CBv2
        /// platform/engine terminals (deadline leases, step watchdog) and the
        /// provider's own pre-output cancellation; nil for every legacy string
        /// error. Omitted on the wire when nil so the legacy shape stays
        /// byte-identical.
        public let terminalCause: InferenceTerminalCause?
        /// Engine-reconciled token usage of the failed attempt at its terminal
        /// (partial generation included). OBSERVABILITY ONLY — the coordinator
        /// persists/telemeters it but never bills from it. Omitted on the wire
        /// when nil (legacy providers, or a terminal with no usage).
        public let attemptUsage: UsageInfo?
        /// Routing-v2 enriched capacity rejection (additive, all omitted when
        /// absent so legacy frames stay byte-identical; mirrors the Go
        /// `omitempty` additions on InferenceErrorMessage). Populated only on
        /// capacity-shaped live-gate rejections, from the published capacity
        /// snapshot, so every rejection doubles as a fresh state sample.
        public let rejectionReason: CapacityRejectionReason?
        /// Live admittable token budget of the rejected model's slot at the
        /// moment of rejection (max − used − queued, floored at 0). Presence
        /// semantics on the wire: nil is omitted, but an EXPLICIT ZERO is
        /// encoded — a busy slot with zero free tokens must say so, or the
        /// coordinator falls back to its stale heartbeat budget.
        public let availableTokenBudget: Int64?
        /// Estimated milliseconds until the request would become admissible
        /// (duration, never a wall clock). Omitted when inestimable.
        public let feasibleAfterMs: Int64?
        /// `capacity_seq` of the published snapshot this rejection was
        /// evaluated against, so the coordinator can order it with heartbeats.
        public let capacitySeq: UInt64?

        public init(
            requestId: String,
            failure: InferenceFailure
        ) {
            self.requestId = requestId
            self.failureCode = failure.code
            self.statusCode = failure.statusCode
            self.errorReason = failure.errorReason
            self.terminalCause = failure.terminalCause
            self.attemptUsage = failure.attemptUsage
            self.rejectionReason = failure.rejectionReason
            self.availableTokenBudget = failure.availableTokenBudget
            self.feasibleAfterMs = failure.feasibleAfterMs
            self.capacitySeq = failure.capacitySeq
        }

        /// Decoder-only compatibility path. Discards the legacy free-form
        /// `error` value even when present, so decoding and re-encoding an old
        /// provider frame cannot revive request-derived text.
        fileprivate init(
            decodedRequestId: String,
            failureCode: InferenceFailureCode?,
            statusCode: UInt16,
            errorReason: InferenceErrorReason?,
            terminalCause: InferenceTerminalCause?,
            attemptUsage: UsageInfo?,
            rejectionReason: CapacityRejectionReason?,
            availableTokenBudget: Int64?,
            feasibleAfterMs: Int64?,
            capacitySeq: UInt64?
        ) {
            self.requestId = decodedRequestId
            self.failureCode = failureCode
            self.statusCode = statusCode
            self.errorReason = errorReason
            self.terminalCause = terminalCause
            self.attemptUsage = attemptUsage
            self.rejectionReason = rejectionReason
            self.availableTokenBudget = availableTokenBudget
            self.feasibleAfterMs = feasibleAfterMs
            self.capacitySeq = capacitySeq
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

    /// Reply to a `CoordinatorMessage.CapacityProbe` (routing v2). Computed
    /// from the lock-free published capacity snapshot — never by running
    /// inference, loading a model, or allocating KV. Mirrors
    /// CapacityQuoteMessage (Go); every field except `rejection_reason` is
    /// always on the wire (Go has no `omitempty` on them).
    public struct CapacityQuote: Sendable, Equatable {
        /// Echo of the probe's random, request-local id. Never a stable
        /// request/consumer identifier.
        public var quoteId: String
        /// Sequence of the published capacity snapshot this quote was
        /// computed from. Carried so ordering against heartbeats is possible;
        /// the coordinator currently trusts the 250ms probe window and does
        /// not compare seqs.
        public var capacitySeq: UInt64
        public var admissibleNow: Bool
        /// Bounded reason; nil (omitted) exactly when `admissibleNow`.
        public var rejectionReason: CapacityRejectionReason?
        /// End-to-end TTFT distribution quantiles (dispatch-received →
        /// first token) from completed real requests — never a sum of
        /// per-stage p95s, and durations only (never wall clocks).
        public var ttftP50Ms: Double
        public var ttftP90Ms: Double
        /// Estimated wait before the request could start (0 when admissible).
        public var queueEstMs: Double
        /// Live admittable token budget (max − used − queued, floored at 0).
        public var availableTokenBudget: Int64
        public var confidence: CapacityQuoteConfidence

        public init(
            quoteId: String,
            capacitySeq: UInt64,
            admissibleNow: Bool,
            rejectionReason: CapacityRejectionReason? = nil,
            ttftP50Ms: Double,
            ttftP90Ms: Double,
            queueEstMs: Double,
            availableTokenBudget: Int64,
            confidence: CapacityQuoteConfidence
        ) {
            self.quoteId = quoteId
            self.capacitySeq = capacitySeq
            self.admissibleNow = admissibleNow
            // Pin the contract at the type boundary: a reason rides the wire
            // exactly when the quote is a rejection.
            self.rejectionReason = admissibleNow ? nil : rejectionReason
            self.ttftP50Ms = ttftP50Ms
            self.ttftP90Ms = ttftP90Ms
            self.queueEstMs = queueEstMs
            self.availableTokenBudget = availableTokenBudget
            self.confidence = confidence
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
        case capacityQuote = "capacity_quote"
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
        case runtimeCapabilities = "runtime_capabilities"
        case privateOnly = "private_only"
        case apnsDeviceToken = "apns_device_token"
        case apnsEnvironment = "apns_environment"
        case prefixCacheProtocol = "prefix_cache_protocol"
        case prefixCacheV2Models = "prefix_cache_v2_models"
        case prefixCacheStatuses = "prefix_cache_statuses"
        case prefixCacheDonationOutcomes = "prefix_cache_donation_outcomes"
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
        case failureCode = "failure_code"
        case statusCode = "status_code"
        case errorReason = "error_reason"
        case terminalCause = "terminal_cause"
        case attemptUsage = "attempt_usage"
        // Enriched capacity rejection (InferenceError) + CapacityQuote
        case rejectionReason = "rejection_reason"
        case availableTokenBudget = "available_token_budget"
        case feasibleAfterMs = "feasible_after_ms"
        case capacitySeq = "capacity_seq"
        // CapacityQuote
        case quoteId = "quote_id"
        case admissibleNow = "admissible_now"
        case ttftP50Ms = "ttft_p50_ms"
        case ttftP90Ms = "ttft_p90_ms"
        case queueEstMs = "queue_est_ms"
        case confidence
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
            if !r.runtimeCapabilities.isEmpty {
                try container.encode(r.runtimeCapabilities.sorted(), forKey: .runtimeCapabilities)
            }
            if r.privateOnly {
                try container.encode(true, forKey: .privateOnly)
            }
            try container.encodeIfPresent(r.apnsDeviceToken, forKey: .apnsDeviceToken)
            try container.encodeIfPresent(r.apnsEnvironment, forKey: .apnsEnvironment)
            if let version = r.prefixCacheProtocol, version != 0 {
                try container.encode(version, forKey: .prefixCacheProtocol)
            }
            try container.encodeIfPresent(r.prefixCacheV2Models, forKey: .prefixCacheV2Models)
            try container.encodeIfPresent(r.prefixCacheStatuses, forKey: .prefixCacheStatuses)
            try container.encodeIfPresent(
                r.prefixCacheDonationOutcomes, forKey: .prefixCacheDonationOutcomes)
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
            try container.encodeIfPresent(h.prefixCacheStatuses, forKey: .prefixCacheStatuses)
            try container.encodeIfPresent(
                h.prefixCacheDonationOutcomes, forKey: .prefixCacheDonationOutcomes)

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
            try container.encodeIfPresent(e.failureCode?.rawValue, forKey: .failureCode)
            try container.encode(e.statusCode, forKey: .statusCode)
            try container.encodeIfPresent(e.errorReason?.rawValue, forKey: .errorReason)
            // Optional typed-terminal additions; omitted when nil so the legacy
            // wire shape is byte-identical (mirrors Go `omitempty`).
            try container.encodeIfPresent(e.terminalCause?.rawValue, forKey: .terminalCause)
            try container.encodeIfPresent(e.attemptUsage, forKey: .attemptUsage)
            // Enriched capacity-rejection additions (routing v2). Nil stays
            // off the wire so a legacy frame re-encodes byte-identically.
            try container.encodeIfPresent(e.rejectionReason?.rawValue, forKey: .rejectionReason)
            // available_token_budget carries PRESENCE semantics, not Go
            // omitempty: an explicit zero is real state — "busy slot, zero
            // free tokens right now" — and must reach the coordinator.
            // Omitting it made the coordinator fall back to the stale
            // heartbeat budget, which could misclassify this transient
            // reject as deterministic and stop failover. The Go mirror is
            // `*int64` (nil omitted, zero encoded) for the same reason.
            try container.encodeIfPresent(e.availableTokenBudget, forKey: .availableTokenBudget)
            if let feasibleAfterMs = e.feasibleAfterMs, feasibleAfterMs != 0 {
                try container.encode(feasibleAfterMs, forKey: .feasibleAfterMs)
            }
            if let seq = e.capacitySeq, seq != 0 {
                try container.encode(seq, forKey: .capacitySeq)
            }

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

        case .capacityQuote(let q):
            try container.encode(TypeValue.capacityQuote, forKey: .type)
            try container.encode(q.quoteId, forKey: .quoteId)
            try container.encode(q.capacitySeq, forKey: .capacitySeq)
            try container.encode(q.admissibleNow, forKey: .admissibleNow)
            // Omitted exactly when admissible (Go `omitempty`).
            try container.encodeIfPresent(q.rejectionReason, forKey: .rejectionReason)
            try container.encode(q.ttftP50Ms, forKey: .ttftP50Ms)
            try container.encode(q.ttftP90Ms, forKey: .ttftP90Ms)
            try container.encode(q.queueEstMs, forKey: .queueEstMs)
            try container.encode(q.availableTokenBudget, forKey: .availableTokenBudget)
            try container.encode(q.confidence, forKey: .confidence)
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
                runtimeCapabilities: try container.decodeIfPresent(
                    [ProviderRuntimeCapability].self, forKey: .runtimeCapabilities) ?? [],
                privateOnly: try container.decodeIfPresent(Bool.self, forKey: .privateOnly) ?? false,
                apnsDeviceToken: try container.decodeIfPresent(String.self, forKey: .apnsDeviceToken),
                apnsEnvironment: try container.decodeIfPresent(String.self, forKey: .apnsEnvironment),
                prefixCacheProtocol: try container.decodeIfPresent(Int.self, forKey: .prefixCacheProtocol),
                prefixCacheV2Models: try container.decodeIfPresent(
                    [PrefixCacheV2Capability].self, forKey: .prefixCacheV2Models),
                prefixCacheStatuses: try container.decodeIfPresent(
                    [PrefixCacheModelStatus].self, forKey: .prefixCacheStatuses),
                prefixCacheDonationOutcomes: try container.decodeIfPresent(
                    [PrefixCacheDonationOutcomeCount].self,
                    forKey: .prefixCacheDonationOutcomes),
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
                    [PrefixCacheV2Capability].self, forKey: .prefixCacheV2Models),
                prefixCacheStatuses: try container.decodeIfPresent(
                    [PrefixCacheModelStatus].self, forKey: .prefixCacheStatuses),
                prefixCacheDonationOutcomes: try container.decodeIfPresent(
                    [PrefixCacheDonationOutcomeCount].self,
                    forKey: .prefixCacheDonationOutcomes)
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
            // The legacy free-form `error` key is deliberately decoded and
            // discarded. It may contain prompt fragments, media URIs, template
            // source, tool IDs, or generated output.
            _ = try container.decodeIfPresent(String.self, forKey: .error)
            let failureCode = (try container.decodeIfPresent(String.self, forKey: .failureCode))
                .flatMap(InferenceFailureCode.init(rawValue:))
            let errorReason = (try container.decodeIfPresent(String.self, forKey: .errorReason))
                .flatMap(InferenceErrorReason.init(rawValue:))
            // Unknown terminal_cause strings decode to nil (tolerant): a newer
            // provider value must never crash an older decoder — it falls back to
            // the legacy string/status heuristics, exactly like an absent field.
            let terminalCause = (try container.decodeIfPresent(String.self, forKey: .terminalCause))
                .flatMap(InferenceTerminalCause.init(rawValue:))
            // Unknown rejection_reason strings likewise decode to nil.
            let rejectionReason = (try container.decodeIfPresent(String.self, forKey: .rejectionReason))
                .flatMap(CapacityRejectionReason.init(rawValue:))
            self = .inferenceError(InferenceError(
                decodedRequestId: try container.decode(String.self, forKey: .requestId),
                failureCode: failureCode,
                statusCode: try container.decode(UInt16.self, forKey: .statusCode),
                errorReason: errorReason,
                terminalCause: terminalCause,
                attemptUsage: try container.decodeIfPresent(UsageInfo.self, forKey: .attemptUsage),
                rejectionReason: rejectionReason,
                availableTokenBudget: try container.decodeIfPresent(
                    Int64.self, forKey: .availableTokenBudget),
                feasibleAfterMs: try container.decodeIfPresent(
                    Int64.self, forKey: .feasibleAfterMs),
                capacitySeq: try container.decodeIfPresent(UInt64.self, forKey: .capacitySeq)
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

        case .capacityQuote:
            self = .capacityQuote(CapacityQuote(
                quoteId: try container.decode(String.self, forKey: .quoteId),
                capacitySeq: try container.decodeIfPresent(UInt64.self, forKey: .capacitySeq) ?? 0,
                admissibleNow: try container.decode(Bool.self, forKey: .admissibleNow),
                rejectionReason: try container.decodeIfPresent(
                    CapacityRejectionReason.self, forKey: .rejectionReason),
                ttftP50Ms: try container.decodeIfPresent(Double.self, forKey: .ttftP50Ms) ?? 0,
                ttftP90Ms: try container.decodeIfPresent(Double.self, forKey: .ttftP90Ms) ?? 0,
                queueEstMs: try container.decodeIfPresent(Double.self, forKey: .queueEstMs) ?? 0,
                availableTokenBudget: try container.decodeIfPresent(
                    Int64.self, forKey: .availableTokenBudget) ?? 0,
                confidence: try container.decode(CapacityQuoteConfidence.self, forKey: .confidence)
            ))
        }
    }
}

// MARK: - Coordinator -> Provider

public enum CoordinatorMessage: Sendable, Equatable {
    case inferenceRequest(InferenceRequest)
    case cancel(Cancel)
    case attestationChallenge(AttestationChallenge)
    case codeAttestationResumeChallenge(CodeAttestationResumeChallenge)
    case runtimeStatus(RuntimeStatus)
    case loadModel(LoadModel)
    case prefetchModel(PrefetchModel)
    case desiredModels(DesiredModels)
    case trustStatus(TrustStatus)
    case capacityProbe(CapacityProbe)

    public struct InferenceRequest: Sendable, Equatable {
        public var requestId: String
        public var body: JSONValue
        public var encryptedBody: EncryptedPayload?
        /// Positive time remaining for this dispatch attempt to produce its
        /// first content-bearing chunk. Nil preserves the legacy wire shape.
        public var firstContentBudgetMs: Int64?
        public var cacheReceiptNonce: String?
        public var cacheScope: String?
        public var prefixCacheProtocol: Int?
        public var toolSchemaMetadataProtocol: Int?

        public init(
            requestId: String,
            body: JSONValue = .null,
            encryptedBody: EncryptedPayload? = nil,
            firstContentBudgetMs: Int64? = nil,
            cacheReceiptNonce: String? = nil,
            cacheScope: String? = nil,
            prefixCacheProtocol: Int? = nil,
            toolSchemaMetadataProtocol: Int? = nil
        ) {
            self.requestId = requestId
            self.body = body
            self.encryptedBody = encryptedBody
            self.firstContentBudgetMs = firstContentBudgetMs.flatMap { $0 > 0 ? $0 : nil }
            self.cacheReceiptNonce = cacheReceiptNonce
            self.cacheScope = cacheScope
            self.prefixCacheProtocol = prefixCacheProtocol
            self.toolSchemaMetadataProtocol = toolSchemaMetadataProtocol
        }
    }

    /// Routing-v2 capacity probe (coordinator → provider). Carries BUCKETED
    /// request-shape metadata ONLY — by protocol contract it never contains
    /// prompt text, ciphertext, image bytes, tool bodies, consumer/account
    /// identity, or the public request ID (`quoteId` is random and
    /// request-local). The provider answers with a `capacityQuote` computed
    /// from its published capacity snapshot. Mirrors CapacityProbeMessage (Go).
    public struct CapacityProbe: Sendable, Equatable {
        /// Prompt-size bucket granularity: estimates are rounded UP to a
        /// multiple of this, so non-serving providers learn shape only.
        public static let promptBucketTokens = 512

        public var quoteId: String
        public var model: String
        /// Prompt token estimate rounded UP to a multiple of
        /// ``promptBucketTokens`` by the coordinator.
        public var promptTokensBucket: Int
        public var maxOutputTokens: Int
        /// Omitted when false (Go `omitempty`).
        public var requiresVision: Bool
        /// Omitted when zero (Go `omitempty`).
        public var visionImageCount: Int
        /// Remaining first-content budget of the request being routed, as a
        /// duration (never a wall-clock timestamp — clock skew).
        public var deadlineRemainingMs: Int64

        public init(
            quoteId: String,
            model: String,
            promptTokensBucket: Int,
            maxOutputTokens: Int,
            requiresVision: Bool = false,
            visionImageCount: Int = 0,
            deadlineRemainingMs: Int64
        ) {
            self.quoteId = quoteId
            self.model = model
            self.promptTokensBucket = promptTokensBucket
            self.maxOutputTokens = maxOutputTokens
            self.requiresVision = requiresVision
            self.visionImageCount = visionImageCount
            self.deadlineRemainingMs = deadlineRemainingMs
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

    public struct CodeAttestationResumeChallenge: Sendable, Equatable {
        public var codeChallenge: EncryptedPayload
        public init(codeChallenge: EncryptedPayload) {
            self.codeChallenge = codeChallenge
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

    /// Coordinator informs the provider of its current trust level and status
    /// for local operator diagnostics.
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
        case codeAttestationResumeChallenge = "code_attestation_resume_challenge"
        case runtimeStatus = "runtime_status"
        case loadModel = "load_model"
        case prefetchModel = "prefetch_model"
        case desiredModels = "desired_models"
        case trustStatus = "trust_status"
        case capacityProbe = "capacity_probe"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case body
        case encryptedBody = "encrypted_body"
        case firstContentBudgetMs = "first_content_budget_ms"
        case cacheReceiptNonce = "cache_receipt_nonce"
        case cacheScope = "cache_scope"
        case prefixCacheProtocol = "prefix_cache_protocol"
        case toolSchemaMetadataProtocol = "tool_schema_metadata_protocol"
        case nonce, timestamp
        case codeChallenge = "code_challenge"
        case verified, mismatches
        case modelId = "model_id"
        case priority
        case trustLevel = "trust_level"
        case status, reason
        case models
        // CapacityProbe
        case quoteId = "quote_id"
        case model
        case promptTokensBucket = "prompt_tokens_bucket"
        case maxOutputTokens = "max_output_tokens"
        case requiresVision = "requires_vision"
        case visionImageCount = "vision_image_count"
        case deadlineRemainingMs = "deadline_remaining_ms"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .inferenceRequest(let r):
            try container.encode(TypeValue.inferenceRequest, forKey: .type)
            try container.encode(r.requestId, forKey: .requestId)
            try container.encode(r.body, forKey: .body)
            try container.encodeIfPresent(r.encryptedBody, forKey: .encryptedBody)
            if let firstContentBudgetMs = r.firstContentBudgetMs, firstContentBudgetMs > 0 {
                try container.encode(firstContentBudgetMs, forKey: .firstContentBudgetMs)
            }
            try container.encodeIfPresent(r.cacheReceiptNonce, forKey: .cacheReceiptNonce)
            try container.encodeIfPresent(r.cacheScope, forKey: .cacheScope)
            try container.encodeIfPresent(r.prefixCacheProtocol, forKey: .prefixCacheProtocol)
            try container.encodeIfPresent(
                r.toolSchemaMetadataProtocol,
                forKey: .toolSchemaMetadataProtocol)

        case .cancel(let c):
            try container.encode(TypeValue.cancel, forKey: .type)
            try container.encode(c.requestId, forKey: .requestId)

        case .attestationChallenge(let a):
            try container.encode(TypeValue.attestationChallenge, forKey: .type)
            try container.encode(a.nonce, forKey: .nonce)
            try container.encode(a.timestamp, forKey: .timestamp)

        case .codeAttestationResumeChallenge(let challenge):
            try container.encode(
                TypeValue.codeAttestationResumeChallenge, forKey: .type)
            try container.encode(challenge.codeChallenge, forKey: .codeChallenge)

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

        case .capacityProbe(let p):
            try container.encode(TypeValue.capacityProbe, forKey: .type)
            try container.encode(p.quoteId, forKey: .quoteId)
            try container.encode(p.model, forKey: .model)
            try container.encode(p.promptTokensBucket, forKey: .promptTokensBucket)
            try container.encode(p.maxOutputTokens, forKey: .maxOutputTokens)
            // Mirror the Go `omitempty` tags on the vision shape fields.
            if p.requiresVision {
                try container.encode(true, forKey: .requiresVision)
            }
            if p.visionImageCount != 0 {
                try container.encode(p.visionImageCount, forKey: .visionImageCount)
            }
            try container.encode(p.deadlineRemainingMs, forKey: .deadlineRemainingMs)
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
                firstContentBudgetMs: try container.decodeIfPresent(
                    Int64.self, forKey: .firstContentBudgetMs),
                cacheReceiptNonce: try container.decodeIfPresent(String.self, forKey: .cacheReceiptNonce),
                cacheScope: try container.decodeIfPresent(String.self, forKey: .cacheScope),
                prefixCacheProtocol: try container.decodeIfPresent(
                    Int.self, forKey: .prefixCacheProtocol),
                toolSchemaMetadataProtocol: try container.decodeIfPresent(
                    Int.self, forKey: .toolSchemaMetadataProtocol)
            ))

        case .cancel:
            self = .cancel(Cancel(
                requestId: try container.decode(String.self, forKey: .requestId)
            ))

        case .capacityProbe:
            self = .capacityProbe(CapacityProbe(
                quoteId: try container.decode(String.self, forKey: .quoteId),
                model: try container.decode(String.self, forKey: .model),
                promptTokensBucket: try container.decodeIfPresent(
                    Int.self, forKey: .promptTokensBucket) ?? 0,
                maxOutputTokens: try container.decodeIfPresent(
                    Int.self, forKey: .maxOutputTokens) ?? 0,
                requiresVision: try container.decodeIfPresent(
                    Bool.self, forKey: .requiresVision) ?? false,
                visionImageCount: try container.decodeIfPresent(
                    Int.self, forKey: .visionImageCount) ?? 0,
                deadlineRemainingMs: try container.decodeIfPresent(
                    Int64.self, forKey: .deadlineRemainingMs) ?? 0
            ))

        case .attestationChallenge:
            self = .attestationChallenge(AttestationChallenge(
                nonce: try container.decode(String.self, forKey: .nonce),
                timestamp: try container.decode(String.self, forKey: .timestamp)
            ))

        case .codeAttestationResumeChallenge:
            self = .codeAttestationResumeChallenge(
                CodeAttestationResumeChallenge(
                    codeChallenge: try container.decode(
                        EncryptedPayload.self, forKey: .codeChallenge)
                )
            )

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
