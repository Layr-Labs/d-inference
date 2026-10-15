import Foundation

/// A one-load loan of the actual downloader/removal writer leases. The outer
/// funnel acquires before eviction and retains it through publication/unwind.
/// Managed construction borrows this same owner instead of nesting flock.
final class GLM5NextArtifactOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private let weightDirectory: URL
    private let tokenizerDirectory: URL
    private let weightIdentity: ModelRevisionIdentity
    private let tokenizerIdentity: ModelRevisionIdentity
    private var leases: [ModelArtifactWriteLease]
    private var claimed = false
    private var quarantined = false

    private init(plan: GLM5NextArtifactPlan, leases: [ModelArtifactWriteLease]) {
        weightDirectory = plan.weights.directory
        tokenizerDirectory = plan.tokenizer.directory
        weightIdentity = ModelRevisionIdentity(plan.weights.manifest)
        tokenizerIdentity = ModelRevisionIdentity(plan.tokenizer.manifest)
        self.leases = leases
    }

    static func acquire(plan: GLM5NextArtifactPlan) throws -> GLM5NextArtifactOwnership {
        var leases: [ModelArtifactWriteLease] = []
        do {
            for id in Set([plan.weights.catalog.id, plan.tokenizer.catalog.id]).sorted() {
                leases.append(
                    try ModelArtifactWriteLease.acquireIfAvailable(
                        modelID: id, operation: "GLM load"))
            }
            try plan.weights.recheck()
            try plan.tokenizer.recheck()
            return .init(plan: plan, leases: leases)
        } catch {
            for lease in leases { lease.release() }
            throw error
        }
    }

    func claim(plan: GLM5NextArtifactPlan) throws {
        try lock.withLock {
            guard !leases.isEmpty, !claimed, !quarantined,
                plan.weights.directory == weightDirectory,
                plan.tokenizer.directory == tokenizerDirectory,
                ModelRevisionIdentity(plan.weights.manifest) == weightIdentity,
                ModelRevisionIdentity(plan.tokenizer.manifest) == tokenizerIdentity
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
