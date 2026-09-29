import Foundation

/// Read from the final scheduler configuration, after model/backend policy.
/// These values identify evidence; they never change the engine's settings.
public struct DeadlineRuntimeConfiguration: Codable, Sendable, Equatable {
    public var configuredContextTokens: Int
    public var effectiveMaxConcurrency: Int
    public var prefillChunkSize: Int
    public var maxConcurrentPartialPrefills: Int
    public var mixedPrefillTokenCap: Int?
    public var soloPrefillStripeTokens: Int?

    enum CodingKeys: String, CodingKey {
        case configuredContextTokens = "configured_context_tokens"
        case effectiveMaxConcurrency = "effective_max_concurrency"
        case prefillChunkSize = "prefill_chunk_size"
        case maxConcurrentPartialPrefills = "max_concurrent_partial_prefills"
        case mixedPrefillTokenCap = "mixed_prefill_token_cap"
        case soloPrefillStripeTokens = "solo_prefill_stripe_tokens"
    }

    var isValid: Bool {
        (1...1_048_576).contains(configuredContextTokens)
            && (1...16).contains(effectiveMaxConcurrency)
            && (1...1_048_576).contains(prefillChunkSize)
            && (1...16).contains(maxConcurrentPartialPrefills)
            && (mixedPrefillTokenCap.map { (1...1_048_576).contains($0) } ?? true)
            && (soloPrefillStripeTokens.map { (1...1_048_576).contains($0) } ?? true)
    }
}
