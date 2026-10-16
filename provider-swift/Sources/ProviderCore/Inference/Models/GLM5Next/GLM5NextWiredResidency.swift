import Foundation
import MLX

/// Standing residency for a published GLM engine: acceleration only, never a
/// model-memory permit or a promise that specific buffers are wired.
///
/// Without a standing residency set every command buffer must make the
/// ~165 GiB NVFP4 payload resident again. On a 256 GiB host prefill then runs
/// at a quarter of its speed (measured 263–367 versus 1,246 tok/s for
/// 512-token chunks on an M5 Ultra); decode is unaffected. The ticket requests
/// the shared safe ceiling, not the payload size: the residency walk over
/// already-allocated buffers is unordered, so a payload-sized request could
/// leave weight banks out while it wires the KV pool. The ceiling still leaves
/// max(16 GiB, 10%) of physical memory unwired.
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

    enum Phase: Equatable, Sendable { case prepared, held, ended, unsupported }

    private let ticket: WiredMemoryTicket
    private let policy: MiMoV26WiredResidency.Policy
    private let lock = NSLock()
    private var phase = Phase.prepared

    private init(ceiling: Int, readCeiling: @escaping @Sendable () -> Int) {
        policy = .shared
        ticket = WiredMemoryTicket(size: ceiling, policy: policy, manager: .shared, kind: .active)
        policy.register(ticket.id, ceiling: readCeiling)
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
        return GLM5NextWiredResidency(ceiling: ceiling, readCeiling: readCeiling)
    }

    var currentPhase: Phase { lock.withLock { phase } }

    /// Installs the ticket on the GPU device. An MLX refusal leaves the engine
    /// serving without standing residency; it never fails the load.
    func start() async {
        guard lock.withLock({ phase == .prepared }) else { return }
        do {
            try await Device.withDefaultDevice(.gpu) {
                try await withError { errors in
                    _ = await ticket.start()
                    try errors.check()
                }
            }
            lock.withLock { phase = .held }
        } catch {
            lock.withLock { phase = .unsupported }
        }
    }

    /// Called only after the engine's native retirement is proven.
    func end() async {
        let held = lock.withLock { () -> Bool in
            defer { if phase != .ended { phase = .ended } }
            return phase == .held || phase == .unsupported
        }
        if held {
            _ = try? await Device.withDefaultDevice(.gpu) {
                try await withError { _ in _ = await ticket.end() }
            }
        }
        policy.remove(ticket.id)
    }
}
