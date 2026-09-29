import Foundation

/// Names reviewed deadline-only evidence and the actual immutable scheduler.
/// A reference cannot certify itself or alter any serving policy.
public struct DeadlinePerformanceProfileReference: Codable, Sendable, Equatable {
    public var id: String
    public var runtimeRevision: String
    public var configuredContextTokens: Int
    public var effectiveMaxConcurrency: Int
    public var prefillChunkSize: Int
    public var maxConcurrentPartialPrefills: Int
    public var mixedPrefillTokenCap: Int?
    public var soloPrefillStripeTokens: Int?
    public var mtp: ServingMTPConfiguration? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case runtimeRevision = "runtime_revision"
        case configuredContextTokens = "configured_context_tokens"
        case effectiveMaxConcurrency = "effective_max_concurrency"
        case prefillChunkSize = "prefill_chunk_size"
        case maxConcurrentPartialPrefills = "max_concurrent_partial_prefills"
        case mixedPrefillTokenCap = "mixed_prefill_token_cap"
        case soloPrefillStripeTokens = "solo_prefill_stripe_tokens"
        case mtp
    }

    init(profile: DeadlinePerformanceProfile) {
        id = profile.id
        runtimeRevision = profile.runtimeRevision
        configuredContextTokens = profile.configuredContextTokens
        effectiveMaxConcurrency = profile.effectiveMaxConcurrency
        prefillChunkSize = profile.prefillChunkSize
        maxConcurrentPartialPrefills = profile.maxConcurrentPartialPrefills
        mixedPrefillTokenCap = profile.mixedPrefillTokenCap
        soloPrefillStripeTokens = profile.soloPrefillStripeTokens
        mtp = profile.mtp
    }
}
