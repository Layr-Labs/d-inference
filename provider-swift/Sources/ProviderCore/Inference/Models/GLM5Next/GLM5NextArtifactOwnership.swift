import Foundation

/// A one-load loan of the actual downloader/removal writer leases. The outer
/// funnel acquires before eviction and retains it through publication/unwind.
/// Managed construction borrows this same owner instead of nesting flock.
final class GLM5NextArtifactOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private let weightDirectory: URL
    private let weightIdentity: ModelRevisionIdentity
    private var leases: [ModelArtifactWriteLease]
    private let fencedByCaller: Bool
    private var claimed = false
    private var quarantined = false

    private init(plan: GLM5NextArtifactPlan, leases: [ModelArtifactWriteLease], fencedByCaller: Bool = false) {
        weightDirectory = plan.weights.directory
        weightIdentity = ModelRevisionIdentity(plan.weights.manifest)
        self.leases = leases
        self.fencedByCaller = fencedByCaller
    }

    /// Revision activation already holds this model's writer lease for the
    /// whole swap; flock does not nest, so borrow that fence instead. The
    /// caller names the model whose activation holds it.
    static func borrowingCallerLease(plan: GLM5NextArtifactPlan, heldForModelID: String?) throws
        -> GLM5NextArtifactOwnership
    {
        guard heldForModelID == plan.weights.catalog.id else {
            throw GLM5NextManagedLoadError.lifecycle
        }
        try plan.weights.recheck()
        return .init(plan: plan, leases: [], fencedByCaller: true)
    }

    static func acquire(plan: GLM5NextArtifactPlan) throws -> GLM5NextArtifactOwnership {
        var leases: [ModelArtifactWriteLease] = []
        do {
            leases.append(
                try ModelArtifactWriteLease.acquireIfAvailable(
                    modelID: plan.weights.catalog.id, operation: "GLM load"))
            try plan.weights.recheck()
            return .init(plan: plan, leases: leases)
        } catch {
            for lease in leases { lease.release() }
            throw error
        }
    }

    func claim(plan: GLM5NextArtifactPlan) throws {
        try lock.withLock {
            guard !leases.isEmpty || fencedByCaller, !claimed, !quarantined,
                plan.weights.directory == weightDirectory,
                ModelRevisionIdentity(plan.weights.manifest) == weightIdentity
            else {
                throw GLM5NextManagedLoadError.lifecycle
            }
            claimed = true
        }
    }

    func retainAfterUnprovenCompletion() {
        lock.withLock { quarantined = true }
        GLM5NextLoadFaultState.retain([self])
    }

    func release() {
        let released: [ModelArtifactWriteLease] = lock.withLock {
            guard !quarantined else { return [] }
            let result = leases
            leases = []
            return result
        }
        for lease in released { lease.release() }
    }
    deinit { release() }
}
