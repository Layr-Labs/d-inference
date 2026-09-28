import Foundation

/// Only cancellation/readiness state crosses the worker's control thread.
/// Native work remains synchronous and exclusive; no lock is held over it.
final class QwenResidentControl: @unchecked Sendable {
    enum Phase { case loading, idle, reserved(UUID), running(UUID), failed, closing, closed }
    private let lock = NSLock()
    private var phase = Phase.loading
    private var cancelled = false
    private var used = Set<UUID>()
    let deadline: UInt64

    init(deadline: UInt64) { self.deadline = deadline }
    var available: Bool { locked { if case .idle = phase { return !cancelled && used.count < QwenResidentAdmission.maximumRequests }; return false } }
    func loaded() throws { try locked { guard case .loading = phase, !cancelled else { throw ProbeError("Resident load invalidated") }; phase = .idle } }
    func reserve(_ id: UUID) throws {
        try locked {
            guard case .idle = phase, !cancelled, used.count < QwenResidentAdmission.maximumRequests,
                  used.insert(id).inserted else { throw ProbeError("Resident owner busy, unavailable or request UUID reused") }
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
