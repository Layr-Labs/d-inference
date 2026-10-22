import Foundation
import MLX

/// Standing residency for a published GLM engine: acceleration only, never a
/// model-memory permit or a promise that specific buffers are wired.
///
/// Without a standing residency set every command buffer must make the
/// large NVFP4 payload resident again. On a 256 GiB host prefill then runs
/// at a quarter of its speed (measured 263–367 versus 1,246 tok/s for
/// 512-token chunks on an M5 Ultra); decode is unaffected. The wired-memory
/// ticket requests the shared safe ceiling, not the payload size: the residency
/// walk over already-allocated buffers is unordered, so a payload-sized request
/// could leave weight banks out while it wires the KV pool. The ceiling still
/// leaves max(16 GiB, 10%) of physical memory unwired.
final class GLM5NextWiredResidency: @unchecked Sendable {
    static let environmentFlag = "DARKBLOOM_GLM_PERSISTENT_WIRED_RESIDENCY"

    /// Same rollback spellings as the MiMo flag; unset or any other value keeps
    /// the default.
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        guard let raw = environment[environmentFlag] else { return true }
        return !MiMoV26WiredResidency.rollbackValues.contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    enum Phase: Equatable, Sendable { case prepared, starting, held, ending, ended, retainedFault }
    enum EndResult: Equatable, Sendable { case ended, pendingStart, pendingEnd, retainedFault }

    private let policy: MiMoV26WiredResidency.Policy
    private let policyEntry: UUID
    private let startTicket: @Sendable () async -> Bool
    private let endTicket: @Sendable () async -> Bool
    private let lock = NSLock()
    private var phase = Phase.prepared
    private var endRequested = false
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []

    /// Registers `policyEntry` with `policy`; the closures install and remove
    /// the device ticket.
    init(
        policy: MiMoV26WiredResidency.Policy, policyEntry: UUID,
        ceiling: @escaping @Sendable () -> Int,
        startTicket: @escaping @Sendable () async -> Bool,
        endTicket: @escaping @Sendable () async -> Bool
    ) {
        self.policy = policy
        self.policyEntry = policyEntry
        self.startTicket = startTicket
        self.endTicket = endTicket
        policy.register(policyEntry, ceiling: ceiling)
    }

    /// Never started: nothing is wired, so only the policy entry is released.
    deinit {
        if phase == .prepared { policy.remove(policyEntry) }
    }

    /// Nil when disabled or when the host offers no positive safe ceiling.
    static func prepare(
        budget: GlobalKVCacheBudget, enabled: Bool = isEnabled()
    ) -> GLM5NextWiredResidency? {
        guard enabled, MiMoV26WiredResidency.platformSupported,
            let recommended = try? withError({ GPU.maxRecommendedWorkingSetBytes() }),
            recommended > 0
        else { return nil }
        let physical = budget.physicalMemoryBytes
        let readCeiling: @Sendable () -> Int = {
            MiMoV26WiredResidency.Bounds(
                physicalBytes: physical, recommendedBytes: UInt64(recommended),
                loadCapBytes: budget.processLedger.policySnapshot().capBytes
            ).safeCeiling ?? 0
        }
        let ceiling = readCeiling()
        guard ceiling > 0 else { return nil }
        let policy = MiMoV26WiredResidency.Policy.shared
        let ticket = WiredMemoryTicket(size: ceiling, policy: policy, manager: .shared, kind: .active)
        return GLM5NextWiredResidency(
            policy: policy, policyEntry: ticket.id, ceiling: readCeiling,
            startTicket: {
                do {
                    try await Device.withDefaultDevice(.gpu) {
                        try await withError { errors in
                            _ = await ticket.start()
                            try errors.check()
                        }
                    }
                    return true
                } catch { return false }
            },
            endTicket: {
                do {
                    try await Device.withDefaultDevice(.gpu) {
                        try await withError { errors in
                            _ = await ticket.end()
                            try errors.check()
                        }
                    }
                    return true
                } catch { return false }
            })
    }

    var currentPhase: Phase { lock.withLock { phase } }

    /// A start fault may follow manager registration. Keep the ticket and
    /// policy entry until process retirement instead of claiming it was absent.
    func start() async {
        guard lock.withLock({ () -> Bool in
            guard phase == .prepared else { return false }
            phase = .starting
            return true
        }) else { return }
        let started = await startTicket()
        let endNow = lock.withLock { () -> Bool in
            guard started else {
                phase = .retainedFault
                return false
            }
            if endRequested {
                phase = .ending
                return true
            }
            phase = .held
            return false
        }
        if endNow { await release() }
        resumeSettlementWaiters()
    }

    /// Pending work and backend faults never authorize a clean retirement.
    @discardableResult
    func end() async -> EndResult {
        let result = lock.withLock { () -> EndResult? in
            switch phase {
            case .prepared:
                phase = .ended
                policy.remove(policyEntry)
                return .ended
            case .starting:
                endRequested = true
                return .pendingStart
            case .held:
                phase = .ending
                return nil
            case .ending: return .pendingEnd
            case .ended: return .ended
            case .retainedFault: return .retainedFault
            }
        }
        if let result { return result }
        return await release()
    }

    /// Join actual backend work, including work initiated by another caller.
    /// Cancellation does not manufacture proof that a ticket was restored.
    func waitForSettlement() async {
        await withCheckedContinuation { continuation in
            let waiting = lock.withLock {
                guard phase == .starting || phase == .ending else { return false }
                settlementWaiters.append(continuation)
                return true
            }
            if !waiting { continuation.resume() }
        }
    }

    private func resumeSettlementWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard phase != .starting && phase != .ending else { return [] }
            defer { settlementWaiters.removeAll() }
            return settlementWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    @discardableResult
    private func release() async -> EndResult {
        guard await endTicket() else {
            lock.withLock { phase = .retainedFault }
            resumeSettlementWaiters()
            return .retainedFault
        }
        policy.remove(policyEntry)
        lock.withLock { phase = .ended }
        resumeSettlementWaiters()
        return .ended
    }
}
