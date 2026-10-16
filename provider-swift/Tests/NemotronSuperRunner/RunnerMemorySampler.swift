import Foundation
import MLX
@testable import ProviderCore

/// Periodic process/MLX/ledger sampling. Keeps maxima since the last reset and
/// logs each charge's lifetime (opened/retired, with the maxima seen while it
/// was held). Kernel interval footprint and MLX peak catch spikes between samples;
/// the sampled maxima attribute peaks to ledger state.
actor RunnerMemorySampler {
    static let ballastID = "nemotron-super-runner-ballast"

    private struct Window {
        var start: Duration
        var samples = 0
        var footprint: UInt64 = 0
        var mlxActive: UInt64 = 0
        var mlxActivePlusCache: UInt64 = 0
        var charged: UInt64 = 0
        var byKind: [RunnerChargeKind: UInt64] = [:]
        /// Max over samples of media_ingress + media + kv held at the same time.
        var requestHeld: UInt64 = 0
    }

    private struct LiveCharge {
        let kind: RunnerChargeKind
        let openedAt: Duration
        var maxBytes: UInt64
        var maxFootprint: UInt64 = 0
        var maxMLXActive: UInt64 = 0
    }

    private struct Sample {
        let footprint: RunnerProcessMemory.Footprint?
        let mlx: Memory.Snapshot
        let ledger: GlobalKVCacheBudget.HeadroomSnapshot
        let rows: [RunnerChargeRow]
    }

    private let budget: GlobalKVCacheBudget
    private let log: RunnerEventLog
    private let interval: Duration
    private var window: Window
    private var windowEpoch = 0
    private var issuedSamples = 0
    private var appliedSample = 0
    private var live: [String: LiveCharge] = [:]
    private var loop: Task<Void, Never>?
    private var context: @Sendable () async -> [String: RunnerJSON] = { [:] }

    init(budget: GlobalKVCacheBudget, log: RunnerEventLog, interval: Duration) {
        self.budget = budget
        self.log = log
        self.interval = interval
        window = Window(start: log.elapsed)
    }

    func setContext(_ provider: @escaping @Sendable () async -> [String: RunnerJSON]) {
        context = provider
    }

    func start() {
        guard loop == nil else { return }
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.observe()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Fresh sample plus the window since the last reset.
    func snapshot() async -> RunnerJSON {
        let sample = await observe()
        return .object([
            "memory": RunnerProcessMemory.snapshot(),
            "ledger": Self.ledger(sample.ledger),
            "charges": Self.charges(sample.rows, ledgerCharged: sample.ledger.totalOwnedBytes),
            "window": windowJSON(),
            "context": .object(await context()),
            "t_s": .seconds(log.elapsed),
        ])
    }

    /// Returns the closing window, then restarts kernel, MLX and sampled maxima.
    func resetPeaks() async -> RunnerJSON {
        _ = await observe()
        let closing = windowJSON()
        let kernelReset = RunnerProcessMemory.resetPeaks()
        window = Window(start: log.elapsed)
        windowEpoch += 1
        _ = await observe()
        return .object(["closed_window": closing, "kernel_interval_reset": .bool(kernelReset)])
    }

    private func observe() async -> Sample {
        issuedSamples += 1
        let sequence = issuedSamples, epoch = windowEpoch
        // Rows first: the synchronous reads below then describe the same moment.
        let rows = await budget.runnerChargeRows(ballastID: Self.ballastID)
        let sample = Sample(footprint: RunnerProcessMemory.footprint(), mlx: Memory.snapshot(),
            ledger: budget.memoryHeadroomSnapshot(), rows: rows)
        // Reentrant observers can resume out of order; a stale or pre-reset
        // sample must not reopen a retired charge or leak into a new window.
        guard sequence > appliedSample, epoch == windowEpoch else { return sample }
        appliedSample = sequence
        let footprint = sample.footprint?.current ?? 0
        let active = UInt64(max(0, sample.mlx.activeMemory))
        let cache = UInt64(max(0, sample.mlx.cacheMemory))
        window.samples += 1
        window.footprint = max(window.footprint, footprint)
        window.mlxActive = max(window.mlxActive, active)
        window.mlxActivePlusCache = max(window.mlxActivePlusCache, active + cache)
        window.charged = max(window.charged, sample.ledger.totalOwnedBytes)
        let sums = Self.sums(sample.rows)
        for (kind, bytes) in sums {
            window.byKind[kind] = max(window.byKind[kind] ?? 0, bytes)
        }
        let held = [RunnerChargeKind.mediaIngress, .media, .kv, .prefillLane]
            .reduce(UInt64(0)) { $0 &+ (sums[$1] ?? 0) }
        window.requestHeld = max(window.requestHeld, held)
        trackLifetimes(sample.rows, footprint: footprint, active: active)
        return sample
    }

    private func trackLifetimes(_ rows: [RunnerChargeRow], footprint: UInt64, active: UInt64) {
        let now = log.elapsed
        var seen = Set<String>()
        for row in rows {
            seen.insert(row.id)
            if var charge = live[row.id] {
                charge.maxBytes = max(charge.maxBytes, row.bytes)
                charge.maxFootprint = max(charge.maxFootprint, footprint)
                charge.maxMLXActive = max(charge.maxMLXActive, active)
                live[row.id] = charge
            } else {
                live[row.id] = LiveCharge(kind: row.kind, openedAt: now, maxBytes: row.bytes,
                    maxFootprint: footprint, maxMLXActive: active)
                log.emit("charge.opened", ["id": .string(row.id), "kind": .string(row.kind.rawValue),
                    "bytes": .bytes(row.bytes), "phys_footprint": .bytes(footprint),
                    "mlx_active": .bytes(active)])
            }
        }
        for (id, charge) in live where !seen.contains(id) {
            live[id] = nil
            log.emit("charge.retired", ["id": .string(id), "kind": .string(charge.kind.rawValue),
                "max_bytes": .bytes(charge.maxBytes), "held_s": .seconds(now - charge.openedAt),
                "max_phys_footprint_while_held": .bytes(charge.maxFootprint),
                "max_mlx_active_while_held": .bytes(charge.maxMLXActive)])
        }
    }

    private func windowJSON() -> RunnerJSON {
        let footprint = RunnerProcessMemory.footprint()
        return .object([
            "seconds": .seconds(log.elapsed - window.start), "samples": .count(window.samples),
            "sampled_max_phys_footprint": .bytes(window.footprint),
            "kernel_max_phys_footprint": .optional(footprint?.intervalMax),
            "mlx_peak": .bytes(Memory.peakMemory),
            "sampled_max_mlx_active": .bytes(window.mlxActive),
            "sampled_max_mlx_active_plus_cache": .bytes(window.mlxActivePlusCache),
            "sampled_max_ledger_charged": .bytes(window.charged),
            "sampled_max_charge_by_kind": .object(Dictionary(uniqueKeysWithValues:
                window.byKind.map { ($0.key.rawValue, RunnerJSON.bytes($0.value)) })),
            "sampled_max_request_charges_held": .bytes(window.requestHeld),
        ])
    }

    private static func sums(_ rows: [RunnerChargeRow]) -> [RunnerChargeKind: UInt64] {
        rows.reduce(into: [:]) { totals, row in
            totals[row.kind, default: 0] &+= row.bytes
        }
    }

    /// `unattributed` is ledger charge outside these rows (e.g. native engine owners).
    private static func charges(_ rows: [RunnerChargeRow], ledgerCharged: UInt64) -> RunnerJSON {
        let attributed = rows.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return .object([
            "unattributed_bytes": ledgerCharged >= attributed
                ? .bytes(ledgerCharged - attributed) : .null,
            "rows": .array(rows.map {
                ["id": .string($0.id), "kind": .string($0.kind.rawValue), "bytes": .bytes($0.bytes)]
            }),
            "by_kind": .object(Dictionary(uniqueKeysWithValues:
                sums(rows).map { ($0.key.rawValue, RunnerJSON.bytes($0.value)) })),
        ])
    }

    static func ledger(_ value: GlobalKVCacheBudget.HeadroomSnapshot) -> RunnerJSON {
        [
            "physical_total": .bytes(value.totalBytes), "cap": .bytes(value.capBytes),
            "charged": .bytes(value.totalOwnedBytes), "materialized": .bytes(value.materializedBytes),
            "unmaterialized": .bytes(value.unmaterializedCommittedBytes),
            "remaining": .bytes(value.runtimeRemainingBytes),
            "activation_reserve": .bytes(value.activationReserveBytes),
            "system_available": .bytes(value.systemAvailableBytes),
            "commitment_debt": .bytes(value.commitmentDebtBytes),
            "owners": .count(value.ownerCount), "closing_owners": .count(value.closingOwnerCount),
            "usage_mlx_active": .bytes(value.activeBytes), "usage_mlx_cache": .bytes(value.cacheBytes),
        ]
    }
}
