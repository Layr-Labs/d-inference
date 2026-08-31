import Foundation

public struct WorkerInferenceConfiguration: Codable, Sendable {
    public let maximumCachedModels: Int
    public let engineV2MaximumConcurrent: UInt64
    public let engineV2MaximumConcurrentByModel: [String: UInt64]
    public let engineV2KVBackend: String
    public let engineV2KVBackendByModel: [String: String]
    public let prefillDeadlineMode: PrefillDeadlineMode?
    public let mtpMode: MTPMode

    public init(
        maximumCachedModels: Int,
        engineV2MaximumConcurrent: UInt64,
        engineV2MaximumConcurrentByModel: [String: UInt64],
        engineV2KVBackend: String,
        engineV2KVBackendByModel: [String: String],
        prefillDeadlineMode: PrefillDeadlineMode?,
        mtpMode: MTPMode
    ) {
        self.maximumCachedModels = maximumCachedModels
        self.engineV2MaximumConcurrent = engineV2MaximumConcurrent
        self.engineV2MaximumConcurrentByModel = engineV2MaximumConcurrentByModel
        self.engineV2KVBackend = engineV2KVBackend
        self.engineV2KVBackendByModel = engineV2KVBackendByModel
        self.prefillDeadlineMode = prefillDeadlineMode
        self.mtpMode = mtpMode
    }

    public static let defaultValue = WorkerInferenceConfiguration(
        maximumCachedModels: 3,
        engineV2MaximumConcurrent: BackendSettings.defaultEngineV2MaxConcurrent,
        engineV2MaximumConcurrentByModel: [:],
        engineV2KVBackend: "auto",
        engineV2KVBackendByModel: [:],
        prefillDeadlineMode: nil,
        mtpMode: .auto)
}

public struct WorkerPrefixLookupMetadata: Codable, Sendable {
    public let outcome: PrefixCacheLookupOutcome
    public let tier: PrefixCacheTier?
    public let cachedTokens: UInt64
    public let prefillTokensSaved: UInt64
    public let stageMilliseconds: Double?
    public let promptAnchor: PrefixCacheAnchor?
    public let matchedAnchor: PrefixCacheAnchor?
    public let requiredRecomputeTokens: UInt64

    public init(outcome: PrefixCacheLookupOutcome, tier: PrefixCacheTier?, cachedTokens: UInt64, prefillTokensSaved: UInt64, stageMilliseconds: Double?, promptAnchor: PrefixCacheAnchor?, matchedAnchor: PrefixCacheAnchor?, requiredRecomputeTokens: UInt64) {
        self.outcome = outcome; self.tier = tier; self.cachedTokens = cachedTokens
        self.prefillTokensSaved = prefillTokensSaved; self.stageMilliseconds = stageMilliseconds
        self.promptAnchor = promptAnchor; self.matchedAnchor = matchedAnchor
        self.requiredRecomputeTokens = requiredRecomputeTokens
    }
}

public struct WorkerPrefixReadyMetadata: Codable, Sendable {
    public let readyTokens: UInt64
    public let requiredRecomputeTokens: UInt64
    public let expectedPrefillTokensSaved: UInt64
    public let tier: PrefixCacheTier
    public let stageMilliseconds: Double?
    public let finalAnchor: PrefixCacheAnchor?

    public init(readyTokens: UInt64, requiredRecomputeTokens: UInt64, expectedPrefillTokensSaved: UInt64, tier: PrefixCacheTier, stageMilliseconds: Double?, finalAnchor: PrefixCacheAnchor?) {
        self.readyTokens = readyTokens; self.requiredRecomputeTokens = requiredRecomputeTokens
        self.expectedPrefillTokensSaved = expectedPrefillTokensSaved; self.tier = tier
        self.stageMilliseconds = stageMilliseconds; self.finalAnchor = finalAnchor
    }
}

public struct WorkerPrefixLookupV2Metadata: Codable, Sendable {
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
    public let tier: PrefixCacheTier
    public let requiredRecomputeTokens: UInt64
    public let expectedPrefillTokensSaved: UInt64
    public let stageMs: Double?

    public init(requestId: String, cacheReceiptNonce: String, modelId: String, modelAggregateHash: String, promptContractId: String, cacheEpoch: String, cacheSeq: UInt64, promptAnchor: PrefixCacheAnchor, matchedAnchor: PrefixCacheAnchor?, outcome: PrefixCacheLookupOutcome, tier: PrefixCacheTier, requiredRecomputeTokens: UInt64, expectedPrefillTokensSaved: UInt64, stageMs: Double?) {
        self.requestId = requestId; self.cacheReceiptNonce = cacheReceiptNonce; self.modelId = modelId
        self.modelAggregateHash = modelAggregateHash; self.promptContractId = promptContractId
        self.cacheEpoch = cacheEpoch; self.cacheSeq = cacheSeq; self.promptAnchor = promptAnchor
        self.matchedAnchor = matchedAnchor; self.outcome = outcome; self.tier = tier
        self.requiredRecomputeTokens = requiredRecomputeTokens
        self.expectedPrefillTokensSaved = expectedPrefillTokensSaved; self.stageMs = stageMs
    }

    var providerMessage: ProviderMessage.PrefixCacheLookupV2 {
        ProviderMessage.PrefixCacheLookupV2(requestId: requestId, cacheReceiptNonce: cacheReceiptNonce, modelId: modelId, modelAggregateHash: modelAggregateHash, promptContractId: promptContractId, cacheEpoch: cacheEpoch, cacheSeq: cacheSeq, promptAnchor: promptAnchor, matchedAnchor: matchedAnchor, outcome: outcome, tier: tier, requiredRecomputeTokens: requiredRecomputeTokens, expectedPrefillTokensSaved: expectedPrefillTokensSaved, stageMs: stageMs)
    }
}

public struct WorkerPrefixReadyV2Metadata: Codable, Sendable {
    public let requestId: String
    public let cacheReceiptNonce: String
    public let modelId: String
    public let modelAggregateHash: String
    public let promptContractId: String
    public let cacheEpoch: String
    public let cacheSeq: UInt64
    public let tier: PrefixCacheTier
    public let readyAnchors: [PrefixCacheAnchor]
    public let requiredRecomputeTokens: UInt64
    public let expectedPrefillTokensSaved: UInt64
    public let stageMs: Double?

    public init(requestId: String, cacheReceiptNonce: String, modelId: String, modelAggregateHash: String, promptContractId: String, cacheEpoch: String, cacheSeq: UInt64, tier: PrefixCacheTier, readyAnchors: [PrefixCacheAnchor], requiredRecomputeTokens: UInt64, expectedPrefillTokensSaved: UInt64, stageMs: Double?) {
        self.requestId = requestId; self.cacheReceiptNonce = cacheReceiptNonce; self.modelId = modelId
        self.modelAggregateHash = modelAggregateHash; self.promptContractId = promptContractId
        self.cacheEpoch = cacheEpoch; self.cacheSeq = cacheSeq; self.tier = tier
        self.readyAnchors = readyAnchors; self.requiredRecomputeTokens = requiredRecomputeTokens
        self.expectedPrefillTokensSaved = expectedPrefillTokensSaved; self.stageMs = stageMs
    }

    var providerMessage: ProviderMessage.PrefixCacheReadyV2 {
        ProviderMessage.PrefixCacheReadyV2(requestId: requestId, cacheReceiptNonce: cacheReceiptNonce, modelId: modelId, modelAggregateHash: modelAggregateHash, promptContractId: promptContractId, cacheEpoch: cacheEpoch, cacheSeq: cacheSeq, tier: tier, readyAnchors: readyAnchors, requiredRecomputeTokens: requiredRecomputeTokens, expectedPrefillTokensSaved: expectedPrefillTokensSaved, stageMs: stageMs)
    }
}

public struct WorkerTerminalMetadata: Codable, Sendable {
    public let cacheReceiptNonce: String?
    public let prefixCacheProtocol: Int?
    public let lookup: WorkerPrefixLookupMetadata?
    public let ready: WorkerPrefixReadyMetadata?
    public let lookupV2: WorkerPrefixLookupV2Metadata?
    public let readyV2: WorkerPrefixReadyV2Metadata?
    public let reasoningTokens: UInt64
    public let errorReason: InferenceErrorReason?
    public let terminalCause: InferenceTerminalCause?
    public let attemptUsage: UsageInfo?

    public init(cacheReceiptNonce: String?, prefixCacheProtocol: Int?, lookup: WorkerPrefixLookupMetadata?, ready: WorkerPrefixReadyMetadata?, lookupV2: WorkerPrefixLookupV2Metadata?, readyV2: WorkerPrefixReadyV2Metadata?, reasoningTokens: UInt64, errorReason: InferenceErrorReason? = nil, terminalCause: InferenceTerminalCause? = nil, attemptUsage: UsageInfo? = nil) {
        self.cacheReceiptNonce = cacheReceiptNonce; self.prefixCacheProtocol = prefixCacheProtocol
        self.lookup = lookup; self.ready = ready; self.lookupV2 = lookupV2; self.readyV2 = readyV2
        self.reasoningTokens = reasoningTokens
        self.errorReason = errorReason; self.terminalCause = terminalCause
        self.attemptUsage = attemptUsage
    }
}

public struct WorkerPrefixCacheAdvertisementMetadata: Codable, Sendable {
    public let protocolVersion: Int
    public let models: [PrefixCacheV2Capability]
    public let statuses: [PrefixCacheModelStatus]
    public let donationOutcomes: [PrefixCacheDonationOutcomeCount]

    public init(protocolVersion: Int, models: [PrefixCacheV2Capability], statuses: [PrefixCacheModelStatus], donationOutcomes: [PrefixCacheDonationOutcomeCount]) {
        self.protocolVersion = protocolVersion; self.models = models
        self.statuses = statuses; self.donationOutcomes = donationOutcomes
    }
}
