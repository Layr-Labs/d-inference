import Foundation

/// A pair's admission state. There is no session lifetime and no request
/// count: a valid, idle pair admits a request for as long as its owner keeps it.
public struct ClusterWorkerPairAdmissionState: Sendable, Equatable {
    /// Requests admitted since the pair became ready, for diagnostics only.
    public let requestsServed: Int
    public let hasActiveRequest: Bool
    public let isDraining: Bool
    public let isValid: Bool
    /// Keep-warm exchanges completed and the last one's duration (tier 2).
    public let keepWarmExchanges: Int
    public let lastKeepWarmMicroseconds: Int?
    /// Requests reserved or running now, and how many the pair serves at once
    /// (continuous batching). With one lane `hasActiveRequest` is exactly
    /// `activeRequests == 1`; with more it means every lane is taken.
    public let activeRequests: Int
    public let lanes: Int

    public init(requestsServed: Int, hasActiveRequest: Bool, isDraining: Bool, isValid: Bool,
                keepWarmExchanges: Int = 0, lastKeepWarmMicroseconds: Int? = nil,
                activeRequests: Int? = nil, lanes: Int = 1) {
        self.requestsServed = requestsServed; self.hasActiveRequest = hasActiveRequest
        self.isDraining = isDraining; self.isValid = isValid
        self.keepWarmExchanges = keepWarmExchanges; self.lastKeepWarmMicroseconds = lastKeepWarmMicroseconds
        self.activeRequests = activeRequests ?? (hasActiveRequest ? 1 : 0); self.lanes = lanes
    }

    /// Whether a request could be reserved now. The actual reserve revalidates.
    public func canAdmit() -> Bool { isValid && !hasActiveRequest }
}

/// Keep-warm tier 2 as the pair's owner sequences it (S27): while the pair is
/// idle, about once every `dataPlaneIntervalNanoseconds`, both ranks exchange
/// one 1x16 record on the data plane so the queue pairs stay awake. Tier 1 (a
/// GPU pulse every half second on each rank's executor) runs inside each
/// worker, switched by its `--keep-warm` argument. Both are on by default.
public struct ClusterWorkerKeepWarmPolicy: Sendable, Equatable {
    public let enabled: Bool
    public let dataPlaneIntervalNanoseconds: UInt64
    /// How long both ranks may take to answer one exchange before the pair is
    /// invalidated (its owner then shuts it down cleanly).
    public let answerNanoseconds: UInt64

    public init(enabled: Bool = true, dataPlaneIntervalNanoseconds: UInt64 = 1_000_000_000,
                answerNanoseconds: UInt64 = 10_000_000_000) {
        self.enabled = enabled; self.dataPlaneIntervalNanoseconds = dataPlaneIntervalNanoseconds
        self.answerNanoseconds = answerNanoseconds
    }

    public static let standard = ClusterWorkerKeepWarmPolicy()
    public static let off = ClusterWorkerKeepWarmPolicy(enabled: false)
}
