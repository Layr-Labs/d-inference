import Foundation
import MLX

/// Standing residency for a published GLM engine: acceleration only, never a
/// model-memory permit or a promise that specific buffers are wired.
///
/// Without a standing residency set every command buffer must make the
/// ~165 GiB NVFP4 payload resident again. On a 256 GiB host prefill then runs
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

    enum Phase: Equatable, Sendable { case prepared, starting, held, ending, ended, unsupported }

    private let policy: MiMoV26WiredResidency.Policy
    private let policyEntry: UUID
    private let startTicket: @Sendable () async -> Bool
    private let endTicket: @Sendable () async -> Void
    private let lock = NSLock()
    private var phase = Phase.prepared
    private var endRequested = false

    /// Registers `policyEntry` with `policy`; the closures install and remove
    /// the device ticket.
    init(
        policy: MiMoV26WiredResidency.Policy, policyEntry: UUID,
        ceiling: @escaping @Sendable () -> Int,
        startTicket: @escaping @Sendable () async -> Bool,
        endTicket: @escaping @Sendable () async -> Void
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
        guard enabled,
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
                _ = try? await Device.withDefaultDevice(.gpu) {
                    try await withError { _ in _ = await ticket.end() }
                }
            })
    }

    var currentPhase: Phase { lock.withLock { phase } }

    /// Installs the ticket on the GPU device. An MLX refusal leaves the engine
    /// serving without standing residency; it never fails the load. An `end`
    /// that arrives meanwhile releases the ticket as soon as start returns.
    func start() async {
        guard lock.withLock({ () -> Bool in
            guard phase == .prepared else { return false }
            phase = .starting
            return true
        }) else { return }
        let started = await startTicket()
        let endNow = lock.withLock { () -> Bool in
            if endRequested {
                phase = .ending
                return true
            }
            phase = started ? .held : .unsupported
            return false
        }
        if endNow { await release() }
    }

    /// Called only after the engine's native retirement is proven.
    func end() async {
        let releaseNow = lock.withLock { () -> Bool in
            switch phase {
            case .prepared:
                phase = .ended
                policy.remove(policyEntry)
                return false
            case .starting:
                endRequested = true
                return false
            case .held, .unsupported:
                phase = .ending
                return true
            case .ending, .ended:
                return false
            }
        }
        if releaseNow { await release() }
    }

    /// A failed start may still have registered with the manager; end both.
    private func release() async {
        await endTicket()
        policy.remove(policyEntry)
        lock.withLock { phase = .ended }
    }
}
