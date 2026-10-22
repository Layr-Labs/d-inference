import DarkbloomClusterProtocol
import Foundation

/// CPU identity supplied by the existing admitted request, not a new decoder.
/// Repeated histories are valid; only request UUIDs and wire epochs are unique.
struct QwenLayerStageResidentRequestIdentity: Equatable {
    let requestID: UUID
    let epoch: UUID
    let recordedRequestFingerprint: String
}

enum QwenLayerStageResidentLifecycleError: Error, CustomStringConvertible {
    case rejected(String)
    var description: String {
        switch self { case .rejected(let message): return message }
    }
}

struct QwenLayerStageResidentLifecycleSnapshot: Equatable {
    let admittedRequests: Int
    let completedRequestScopes: Int
    let requestScopeActive: Bool
    let failed: Bool
    let releaseAttempted: Bool
    let releaseCallbackCompleted: Bool
}

/// A serialized callback gate, NOT proof of model ownership or native retirement.
/// Its trusted private owner must return only CPU values from each body, after
/// the unchanged request loop and its autorelease scope have both returned.
/// It must check actual weak model release inside the final release callback.
/// No model, native array, request cache, trace recorder or cleanup callback is
/// retained here. A failed body poisons the cohort even if its error is caught.
final class QwenLayerStageResidentLifecycle {
    private enum Phase { case idle, request(UUID), releasing, released, releaseFailed }
    private let lock = NSLock()
    private var phase = Phase.idle
    private var failure = false
    private var rejectionGeneration = UUID()
    /// Recent request IDs and epochs, to refuse a reuse: windows of
    /// `requestReplayWindow`, never a request count. A resident owner serves
    /// requests for as long as its worker is kept.
    private var requestIDs = Set<UUID>()
    private var epochs = Set<UUID>()
    private var recent: [(request: UUID, epoch: UUID)] = []
    private var admittedRequests = 0
    private var completedScopes = 0

    init() {}

    var snapshot: QwenLayerStageResidentLifecycleSnapshot {
        locked {
            let active: Bool
            if case .request = phase { active = true } else { active = false }
            let attempted: Bool, released: Bool
            switch phase {
            case .releasing, .releaseFailed: attempted = true; released = false
            case .released: attempted = true; released = true
            case .idle, .request: attempted = false; released = false
            }
            return .init(admittedRequests: admittedRequests, completedRequestScopes: completedScopes,
                requestScopeActive: active, failed: failure, releaseAttempted: attempted,
                releaseCallbackCompleted: released)
        }
    }

    /// The lease and its completion transition are private. There is no public
    /// complete(retired: Bool) operation and no way to replay a completed lease.
    /// The generic return does not enforce CPU-only ownership: the private owner
    /// must constrain its own external result type and body implementation.
    func withRequest<Result>(identity: QwenLayerStageResidentRequestIdentity,
        _ body: () throws -> Result
    ) throws -> Result {
        let lease = try locked { () throws -> UUID in
            guard case .idle = phase, !failure else { throw reject("Resident owner is not available") }
            let bytes = identity.recordedRequestFingerprint.utf8
            guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw reject("Resident request requires its admitted lowercase history fingerprint")
            }
            guard !requestIDs.contains(identity.requestID), !epochs.contains(identity.epoch) else {
                throw reject("Resident request UUID or epoch was reused")
            }
            requestIDs.insert(identity.requestID); epochs.insert(identity.epoch)
            recent.append((identity.requestID, identity.epoch)); admittedRequests += 1
            if recent.count > ClusterWorkerLimits.requestReplayWindow {
                let oldest = recent.removeFirst(); requestIDs.remove(oldest.request); epochs.remove(oldest.epoch)
            }
            let lease = UUID(); phase = .request(lease)
            return lease
        }
        do {
            // Deliberately outside the lock: a concurrent/reentrant operation
            // refuses and poisons this scope instead of silently queuing work.
            let result = try body()
            try locked {
                guard case .request(let active) = phase, active == lease, !failure else {
                    throw reject("Resident request was invalidated while its body ran")
                }
                completedScopes += 1; phase = .idle
            }
            return result
        } catch {
            locked {
                failure = true
                if case .request(let active) = phase, active == lease { phase = .idle }
            }
            // The caller's existing request loop owns cancellation and reports
            // cleanup errors. Ending this CPU scope does NOT assert clean cancel.
            throw error
        }
    }

    /// May clean up an already poisoned cohort once its request body unwound.
    /// It never runs while that body is active and never retries release.
    func withModelRelease(_ body: () throws -> Void) throws {
        let generation = try locked { () throws -> UUID in
            guard case .idle = phase else { throw reject("Resident model release is not available") }
            phase = .releasing
            return rejectionGeneration
        }
        do {
            try body()
            try locked {
                guard case .releasing = phase, rejectionGeneration == generation else {
                    throw reject("Resident release was invalidated while its body ran")
                }
                phase = .released
            }
        } catch {
            locked { failure = true; phase = .releaseFailed }
            throw error
        }
    }

    private func reject(_ message: String) -> QwenLayerStageResidentLifecycleError {
        failure = true
        rejectionGeneration = UUID()
        return .rejected(message)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
