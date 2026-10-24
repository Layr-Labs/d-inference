import Foundation

/// Owns the provider's encoded-media allowance. The wire can be borrowed once
/// by one bridge submission; the allowance cannot close until that complete
/// async scope and the native generation have both retired. A client terminal,
/// cancellation, timeout or dropped owner is not a retirement acknowledgement.
public final class DistributedQwenMediaLifetime: @unchecked Sendable {
    struct Submission: Equatable, Sendable {
        let generation: UUID
        let requestID: String
    }

    enum Failure: Error { case alreadySubmitted, staleSubmission }
    private let lock = NSLock()
    private var wire: Data?
    private var submission: Submission?
    private var scopeEnded = false
    private var needsNativeRetirement = false
    private var nativeRetired = false
    private var closed = false
    private let release: @Sendable () -> Void

    init(wire: Data, release: @escaping @Sendable () -> Void) {
        self.wire = wire
        self.release = release
    }

    /// `body` must await every task that can retain its wire argument. Native
    /// request owners have their own fence, registered before this scope ends.
    func withSubmission<T: Sendable>(requestID: String,
        body: @escaping @Sendable (Data, Submission) async throws -> T
    ) async throws -> T {
        var borrowed: Data?
        let key = try lock.withLock {
            guard submission == nil, !closed, let wire else { throw Failure.alreadySubmitted }
            let key = Submission(generation: UUID(), requestID: requestID)
            submission = key
            borrowed = wire
            return key
        }
        let producer = Task { [wire = borrowed!] in try await body(wire, key) }
        do {
            let result = try await withTaskCancellationHandler {
                try await producer.value
            } onCancel: { producer.cancel() }
            borrowed = nil
            finishScope(key)
            return result
        } catch {
            borrowed = nil
            finishScope(key)
            throw error
        }
    }

    func submissionKey(requestID: String, matching bytes: Data) throws -> Submission {
        try lock.withLock {
            guard let submission, submission.requestID == requestID, !closed,
                !scopeEnded, wire == bytes else { throw Failure.staleSubmission }
            return submission
        }
    }

    /// Called synchronously before engine submission. A rejected admission
    /// closes through no-native-owner cleanup; an accepted generation waits
    /// for its definitive retirement, including post-admission cancellation.
    func requireNativeRetirement(_ key: Submission) throws {
        try lock.withLock {
            guard submission == key, !closed, !scopeEnded else { throw Failure.staleSubmission }
            needsNativeRetirement = true
        }
    }

    /// The engine must first drop encoded bytes in its request and native
    /// reservation. A stale request ID alone can never retire another owner.
    func nativeDidRetire(_ key: Submission) {
        let close = lock.withLock {
            guard submission == key, needsNativeRetirement, !closed else { return false }
            nativeRetired = true
            return closeIfRetired()
        }
        if close { release() }
    }

    /// Preparation succeeded but submission was never attempted (for example,
    /// a deadline expired between preprocessing and bridge acquisition).
    func releaseIfUnsubmitted() {
        let close = lock.withLock {
            guard submission == nil, !closed else { return false }
            wire = nil
            closed = true
            return true
        }
        if close { release() }
    }

    private func finishScope(_ key: Submission) {
        let close = lock.withLock {
            guard submission == key, !closed else { return false }
            scopeEnded = true
            return closeIfRetired()
        }
        if close { release() }
    }

    // Only under lock. The wire alias owned here dies before its allowance.
    private func closeIfRetired() -> Bool {
        guard scopeEnded, !needsNativeRetirement || nativeRetired else { return false }
        wire = nil
        closed = true
        return true
    }
}
