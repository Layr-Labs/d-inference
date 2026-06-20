// Copyright © 2026 Eigen Labs.
//
// Backend-liveness watchdog for `BatchScheduler` (DAR-337 / DAR-338).
//
// A loaded model can stop serving while the process stays up and the engine
// loop never crashes — a wedged engine (a request admitted but producing 0
// tokens) or a pinned KV pool (the global budget collapsed to its floor). In
// both cases the node would otherwise keep advertising slot_state=idle/healthy
// and the coordinator would keep routing to it.
//
// This watchdog:
//   1. periodically drives the off-actor proactive KV-pool sweep (DAR-338), then
//   2. assesses backend liveness via the pure `BackendLivenessPolicy`, and on a
//      degraded verdict makes the heartbeat slot_state TRUTHFUL (see
//      `BatchScheduler+Telemetry`) AND self-restarts the engine/model slot
//      (reusing the normal `stopCurrentEngine` + `loadModel` path) to recover.
//
// The blocking work it can trigger (a model reload) happens via `loadModel`,
// which is already epoch-guarded and off the admission hot path.

import Foundation
import os

let livenessLogger = Logger(subsystem: "dev.darkbloom.provider", category: "backend-liveness")

extension BatchScheduler {

    /// Spawn the detached liveness watchdog. Called from `loadModel`; cancelled
    /// (and re-spawned) on every `stopCurrentEngine` / `loadModel` cycle.
    func startLivenessWatchdog() {
        livenessWatchdogTask?.cancel()
        let scheduler = self
        let interval = livenessWatchdogInterval
        livenessWatchdogTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await scheduler.tickLivenessWatchdog()
            }
        }
    }

    /// One watchdog tick: proactively trim the reclaimable KV pool (off-actor,
    /// non-blocking) then assess + recover backend liveness.
    func tickLivenessWatchdog() async {
        // Proactive, rate-limited, threshold-gated pool sweep. Non-blocking and
        // nonisolated — it never touches/awaits the budget actor (DAR-338).
        kvBudget?.proactiveReclaimSweep()
        await assessBackendLiveness()
    }

    /// Assess backend liveness from live scheduler state and, on a degraded
    /// verdict, mark the slot degraded (truthful heartbeat) and — outside the
    /// restart cooldown — self-restart the engine to recover.
    func assessBackendLiveness() async {
        // Nothing to assess (or to reload) without a live engine + container.
        guard engine != nil, modelContainer != nil else { return }
        // A recovery reload is already in flight; don't launch a second.
        guard !isReloadingForRecovery else { return }

        let now = ContinuousClock.now

        // Maintain the continuous-collapse window using the policy's single
        // threshold definition.
        let budget = tokenBudgetMax
        if budget <= livenessPolicy.collapsedBudgetTokens {
            if budgetCollapsedSince == nil { budgetCollapsedSince = now }
        } else {
            budgetCollapsedSince = nil
        }

        let longestStall = longestAdmittedZeroTokenStallSeconds(now: now)
        let hasDemand = !activeBridges.isEmpty || pendingRequestCount > 0
        let verdict = livenessPolicy.assess(
            longestAdmittedZeroTokenSeconds: longestStall,
            budgetCollapsedForSeconds: budgetCollapsedSince.map { Self.seconds(now - $0) },
            secondsSinceLastSuccess: lastSuccessAt.map { Self.seconds(now - $0) },
            hasDemand: hasDemand)

        switch verdict {
        case .healthy:
            if livenessState != .healthy {
                livenessState = .healthy
                let model = modelId
                livenessLogger.info("backend liveness recovered to healthy for \(model, privacy: .public)")
            }
        case .wedged, .pinned:
            // Report the truth on the heartbeat REGARDLESS of the restart cooldown
            // so the coordinator stops routing here even between restart attempts.
            livenessState = verdict
            if let last = lastSelfRestartAt, now - last < livenessRestartCooldown {
                logDegraded(verdict, longestStall: longestStall, budget: budget,
                            note: "within restart cooldown — not restarting yet")
                return
            }
            logDegraded(verdict, longestStall: longestStall, budget: budget,
                        note: "self-restarting engine to recover")
            lastSelfRestartAt = now
            await selfRestartForRecovery()
        }
    }

    /// Longest time (seconds) that any ADMITTED request has been producing 0
    /// tokens, or nil if no admitted request is currently at 0 tokens. A request
    /// is "admitted" once the engine emits its first `RequestOutput`
    /// (`admittedAt != nil`); 0 tokens means no first token AND no completion
    /// tokens observed — i.e. the engine took it but isn't decoding it.
    func longestAdmittedZeroTokenStallSeconds(now: ContinuousClock.Instant) -> Double? {
        var longest: Double?
        for bridge in activeBridges.values {
            guard let admittedAt = bridge.admittedAt,
                bridge.firstTokenAt == nil,
                bridge.completionTokens == 0 else { continue }
            let stall = Self.seconds(now - admittedAt)
            if longest == nil || stall > longest! { longest = stall }
        }
        return longest
    }

    /// Self-restart the engine/model slot to clear a wedge or a pinned KV pool.
    /// Captures the resident container (the slot still holds a strong ref, so the
    /// local binding keeps it alive across `stopCurrentEngine`'s nil-out) and
    /// reloads via the normal `loadModel` path, which tears down the stalled
    /// engine + flushes the pool and brings a fresh one up. `isReloadingForRecovery`
    /// keeps the heartbeat reporting "reloading" for the whole window and is the
    /// sole owner of that flag.
    func selfRestartForRecovery() async {
        guard let container = modelContainer else { return }
        let id = modelId
        let hash = currentWeightHash
        isReloadingForRecovery = true
        livenessLogger.error("self-restarting model \(id, privacy: .public) to recover backend liveness")
        await loadModel(container: container, modelId: id, weightHash: hash)
        // Single owner of the flag: clear it whether the reload succeeded, was
        // superseded, or bailed early, so a later tick can re-detect + retry.
        isReloadingForRecovery = false
        livenessLogger.info("self-restart of \(id, privacy: .public) complete (engine reloaded)")
    }

    /// ContinuousClock.Duration → seconds (Double).
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private func logDegraded(
        _ verdict: BackendLiveness, longestStall: Double?, budget: Int, note: String
    ) {
        let kind = verdict == .wedged ? "WEDGED" : "PINNED"
        let stallStr = longestStall.map { String(format: "%.0f", $0) } ?? "n/a"
        // Lightweight diagnostics: enough to tell wedge from pin and to see the
        // collapsed budget / stall without a GPU probe.
        let model = modelId
        let active = activeBridges.count
        let pending = pendingRequestCount
        livenessLogger.error(
            "backend \(kind, privacy: .public) for \(model, privacy: .public): tokenBudgetMax=\(budget) activeBridges=\(active) pending=\(pending) longestZeroTokenStallSec=\(stallStr, privacy: .public) — \(note, privacy: .public)")
    }
}
