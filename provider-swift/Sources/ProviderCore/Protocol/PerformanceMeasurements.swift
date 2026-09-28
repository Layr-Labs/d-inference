import Foundation

/// Optional engine observations. Ages are elapsed monotonic time at snapshot;
/// the epoch and count identify samples independently of heartbeat sequence.
public struct PerformanceRateObservation: Codable, Sendable, Equatable {
    public var tokensPerSecond: Double
    public var sampleCount: Int64
    public var sampleAgeMs: Int64

    enum CodingKeys: String, CodingKey {
        case tokensPerSecond = "tokens_per_second"
        case sampleCount = "sample_count"
        case sampleAgeMs = "sample_age_ms"
    }
}

/// Numeric workload shapes only; never prompt text, token IDs or cache keys.
public struct PerformanceWorkloadBucket: Codable, Sendable, Equatable {
    public var phase: String
    public var promptTokenBucket: Int
    public var contextTokenBucket: Int
    public var cacheState: String
    public var contention: String
    public var otherModelActivity: Bool
    public var observation: PerformanceRateObservation

    enum CodingKeys: String, CodingKey {
        case phase, contention, observation
        case promptTokenBucket = "prompt_token_bucket"
        case contextTokenBucket = "context_token_bucket"
        case cacheState = "cache_state"
        case otherModelActivity = "other_model_activity"
    }
}

public struct PerformanceMeasurements: Codable, Sendable, Equatable {
    public var epoch: String
    public var isolatedPrefill: PerformanceRateObservation?
    public var contendedPrefill: PerformanceRateObservation?
    public var decode: PerformanceRateObservation?
    public var deliveredDecode: PerformanceRateObservation?
    public var endToEnd: PerformanceRateObservation?
    public var workloadBuckets: [PerformanceWorkloadBucket]

    enum CodingKeys: String, CodingKey {
        case epoch, decode
        case isolatedPrefill = "isolated_prefill"
        case contendedPrefill = "contended_prefill"
        case deliveredDecode = "delivered_decode"
        case endToEnd = "end_to_end"
        case workloadBuckets = "workload_buckets"
    }
}
