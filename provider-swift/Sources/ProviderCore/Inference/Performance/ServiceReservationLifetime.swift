import Foundation

/// Producer proof that a coordinator attempt cannot own service again. The
/// request pipeline and its engine leases have independent lifetimes: a client
/// terminal can precede retirement, or the engine can retire before terminal.
public final class ServiceReservationLifetime: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var pipelineFinished = false
    private var leases = 0
    private var released = false
    private let onReleased: @Sendable (String) -> Void

    init?(id: String?, onReleased: @escaping @Sendable (String) -> Void) {
        guard let id = Self.normalizedID(id) else { return nil }
        self.id = id
        self.onReleased = onReleased
    }

    static func normalizedID(_ id: String?) -> String? {
        guard let id, id.utf8.count == 36 else { return nil }
        return UUID(uuidString: id)?.uuidString.lowercased()
    }

    /// Called under the service-budget lock before inserting an owned charge.
    /// Never calls out: lock ordering is budget → lifetime, never the reverse.
    func acquireLease() -> Bool {
        lock.withLock {
            guard !pipelineFinished, !released else { return false }
            leases += 1
            return true
        }
    }

    /// Called after removing the owned charge, outside the service-budget lock.
    func releaseLease() {
        let notify = lock.withLock {
            guard leases > 0 else { return false }
            leases -= 1
            return claimReleaseLocked()
        }
        if notify { onReleased(id) }
    }

    /// The caller has unwound every path that could acquire another lease.
    /// Never call this merely because a consumer terminal was sent.
    func finishPipeline() {
        let notify = lock.withLock {
            pipelineFinished = true
            return claimReleaseLocked()
        }
        if notify { onReleased(id) }
    }

    private func claimReleaseLocked() -> Bool {
        guard pipelineFinished, leases == 0, !released else { return false }
        released = true
        return true
    }
}
