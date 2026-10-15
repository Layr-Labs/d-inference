import Foundation

/// Observation of the original member session's terminal barriers. Not Codable,
/// a saved approval, or evidence synthesized by a request owner's shutdown.
struct NativePairSessionCompletion: Equatable, Sendable {
    let membershipEpoch: UUID
    let nativeCleanupObserved: Bool
    let ownerReleaseAcknowledged: Bool
    let ownerExitedNormally: Bool
    let requestTransportJoined: Bool
    let cancellationPublicationJoined: Bool
    let localReleasePublished: Bool
    let aggregateReleaseObserved: Bool

    var released: Bool {
        nativeCleanupObserved && ownerReleaseAcknowledged && ownerExitedNormally
            && requestTransportJoined && cancellationPublicationJoined
            && localReleasePublished && aggregateReleaseObserved
    }
}

/// The session publishes once, after its existing final cancellation join.
final class NativePairSessionCompletionSignal: @unchecked Sendable {
    private let lock = NSLock(), done = DispatchGroup()
    private var result: NativePairSessionCompletion?
    init() { done.enter() }
    var observation: NativePairSessionCompletion? { lock.withLock { result } }
    func complete(_ value: NativePairSessionCompletion) {
        let first = lock.withLock { if result != nil { return false }; result = value; return true }
        if first { done.leave() }
    }
    func wait() async -> NativePairSessionCompletion {
        await withCheckedContinuation { continuation in
            done.notify(queue: .global()) { continuation.resume(returning: self.observation!) }
        }
    }
}
