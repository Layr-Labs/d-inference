import Foundation

/// Pending HTTP work, before tokenization or native admission. Bounds describe
/// every request this listener accepts, not an estimate from raw prompt bytes.
public struct DistributedLocalBatchDemand: Sendable {
    public let generationID: UUID
    public let waitingRequests: Int
    public let activeRequests: Int
    public let currentCapacity: Int
    public let publicModelID: String
    public let runtimeModelID: String
    public let artifactSHA256: String
    public let configurationSHA256: String
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let maximumContextTokens: Int
    public let requestTimeout: Duration
}

/// Planning is read-only. These factories run only after the preceding bridge
/// and both native owners have proved release. They prepare fresh sessions;
/// the host validates and starts them. No owner is resurrected for rollback.
public struct DistributedLocalBatchReplacement: Sendable {
    public let requestedCapacity: Int
    let makeSession: @Sendable () async throws -> any DistributedLocalServerSession
    let restorePreviousSession: (@Sendable () async throws -> any DistributedLocalServerSession)?

    public init(requestedCapacity: Int,
                makeSession: @escaping @Sendable () async throws -> DistributedInstalledSession,
                restorePreviousSession: (@Sendable () async throws -> DistributedInstalledSession)? = nil) {
        self.requestedCapacity = requestedCapacity
        self.makeSession = { try await makeSession() }
        if let restorePreviousSession {
            self.restorePreviousSession = { try await restorePreviousSession() }
        } else {
            self.restorePreviousSession = nil
        }
    }

    init(requestedCapacity: Int,
         makeTestSession: @escaping @Sendable () async throws -> any DistributedLocalServerSession,
         restoreTestSession: (@Sendable () async throws -> any DistributedLocalServerSession)? = nil) {
        self.requestedCapacity = requestedCapacity
        makeSession = makeTestSession; restorePreviousSession = restoreTestSession
    }
}

/// A completed read-only proposal owns no worker or HTTP request. It may be
/// consumed once by renewed pressure on the same serving generation, before
/// expiry; its factory still revalidates the exact width after owner release.
struct DistributedLocalReadyBatchReplacement: Sendable {
    let generationID: UUID
    let expiresAt: ContinuousClock.Instant
    let intent: DistributedLocalBatchReplacement

    func isUsable(generationID: UUID, capacity: Int, now: ContinuousClock.Instant) -> Bool {
        self.generationID == generationID && now < expiresAt
            && intent.requestedCapacity > capacity
            && intent.requestedCapacity <= DistributedRequestQueue.maximumLanes
    }
}
