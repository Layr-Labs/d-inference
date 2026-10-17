import DarkbloomClusterProtocol
import Foundation

/// Only cancellation/readiness state crosses the worker's control thread.
/// Native work remains synchronous and exclusive; no lock is held over it.
final class QwenResidentControl: @unchecked Sendable {
    enum Phase { case loading, idle, reserved(UUID), running(UUID), failed, closing, closed }
    private let lock = NSLock()
    private var phase = Phase.loading
    private var cancelled = false
    /// Recent request IDs, to refuse a replay: a window, never a request count.
    private var used = Set<UUID>()
    private var usedOrder: [UUID] = []
    private let fixedDeadline: UInt64
    private let lease: ClusterLeaseDeadline?
    /// The process's deadline now: the rank lease's when leased. A leased
    /// owner has no fixed lifetime and no request limit.
    var deadline: UInt64 { lease?.uptimeNanoseconds ?? fixedDeadline }

    init(deadline: UInt64, lease: ClusterLeaseDeadline? = nil) { fixedDeadline = deadline; self.lease = lease }
    var available: Bool { locked { if case .idle = phase { return !cancelled }; return false } }
    func loaded() throws { try locked { guard case .loading = phase, !cancelled else { throw ProbeError("Resident load invalidated") }; phase = .idle } }
    func reserve(_ id: UUID) throws {
        try locked {
            guard case .idle = phase, !cancelled, used.insert(id).inserted else {
                throw ProbeError("Resident owner busy, unavailable or request UUID reused") }
            usedOrder.append(id)
            if usedOrder.count > ClusterWorkerLimits.requestReplayWindow { used.remove(usedOrder.removeFirst()) }
            phase = .reserved(id)
        }
    }
    func start(_ id: UUID) throws {
        try locked { guard case .reserved(let expected) = phase, expected == id, !cancelled else {
            throw ProbeError("Resident start differs from its reservation") }; phase = .running(id) }
    }
    func completed(_ id: UUID) throws {
        try locked { guard case .running(let expected) = phase, expected == id, !cancelled else {
            throw ProbeError("Resident request invalidated before completion") }; phase = .idle }
    }
    /// Gives back a reservation that never started: the owner is idle again
    /// and takes the next request. False (and nothing changes) unless `id` is
    /// the reservation held now and no cancel or failure has ended it.
    @discardableResult
    func release(_ id: UUID) -> Bool {
        locked {
            guard case .reserved(let current) = phase, current == id, !cancelled else { return false }
            phase = .idle; return true
        }
    }
    /// Gives back a reservation the owner cancelled before it started (the
    /// pair's other rank refused the request): idle again, cancel cleared.
    /// False unless `id` is the reservation held now.
    @discardableResult
    func withdraw(_ id: UUID) -> Bool {
        locked {
            guard case .reserved(let current) = phase, current == id else { return false }
            phase = .idle; cancelled = false; return true
        }
    }
    func fail() { locked { cancelled = true; phase = .failed } }
    func cancel(_ id: UUID) {
        locked {
            switch phase {
            case .reserved(let current), .running(let current): if current == id { cancelled = true }
            default: break
            }
        }
    }
    func check(deadline requestDeadline: UInt64? = nil) throws {
        try locked {
            let now = DispatchTime.now().uptimeNanoseconds
            guard !cancelled, now < deadline, requestDeadline.map({ now < $0 }) ?? true else {
                throw ProbeError("Resident operation cancelled or past its absolute local deadline")
            }
        }
    }
    func beginClose() throws {
        try locked {
            switch phase {
            case .idle, .failed, .reserved: phase = .closing; cancelled = true
            default: throw ProbeError("Resident close requires no running native request")
            }
        }
    }
    func closed() { locked { phase = .closed } }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

/// Process-wide exclusivity also prevents two independently constructed owners
/// from sharing MLX's global streams/cache or cached environment concurrently.
final class QwenResidentProcessLease: @unchecked Sendable {
    static let shared = QwenResidentProcessLease()
    private let lock = NSLock()
    private var owned = false
    func acquire() throws { lock.lock(); defer { lock.unlock() }; guard !owned else {
        throw ProbeError("This process already owns a resident runtime") }; owned = true }
    func release() { lock.lock(); owned = false; lock.unlock() }
}
