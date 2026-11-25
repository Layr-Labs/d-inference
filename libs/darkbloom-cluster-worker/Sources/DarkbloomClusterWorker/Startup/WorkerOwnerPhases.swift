import DarkbloomClusterRuntime
import Foundation

/// How long each phase of one worker start took, from the end of its start-up
/// hardening (`main`'s first statements, which stay first) to the published
/// readiness, on the uptime clock (`DispatchTime`, never the wall clock). A
/// re-formed pair waited 15 to 19 s from its keys to its first call
/// (drill 2026-11-20); this record splits that wait. A record only: nothing
/// reads it to make a decision. It carries a rank, the epoch, the generation,
/// the model, the mode, the stage cut and durations, and nothing else: no key,
/// credential or request.
///
/// `mark` closes a phase: its duration is the time since the previous mark
/// (the first since `started`). The runtime load's own phases
/// (`ClusterLoadPhaseClock`) are what they added between `beginRuntime` and
/// `endRuntime`; `runtime_other` is the rest of the load.
final class WorkerOwnerPhases: @unchecked Sendable {
    static let schema = "darkbloom-owner-phases-v1"
    private let lock = NSLock()
    private let started: UInt64
    private var last: UInt64
    private var phases: [(name: String, nanoseconds: UInt64)] = []
    private var runtimeBefore: [ClusterLoadPhaseClock.Phase: ClusterLoadPhaseClock.Total]?
    private var runtimePhases: [(name: String, nanoseconds: UInt64)] = []
    private var readyAt: UInt64?

    init(started: UInt64 = DispatchTime.now().uptimeNanoseconds) { self.started = started; last = started }

    func mark(_ name: String, at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock { phases.append((name: name, nanoseconds: now &- last)); last = now }
    }

    func beginRuntime(_ totals: [ClusterLoadPhaseClock.Phase: ClusterLoadPhaseClock.Total] = ClusterLoadPhaseClock.totals,
                      at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        mark("bootstrap_attach", at: now)
        lock.withLock { runtimeBefore = totals }
    }

    /// Closes `runtime_load` and records the load's own phases in it.
    func endRuntime(_ totals: [ClusterLoadPhaseClock.Phase: ClusterLoadPhaseClock.Total] = ClusterLoadPhaseClock.totals,
                    at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        mark("runtime_load", at: now)
        lock.withLock {
            guard let before = runtimeBefore, let load = phases.last?.nanoseconds else { return }
            var inside: UInt64 = 0
            runtimePhases = ClusterLoadPhaseClock.Phase.allCases.compactMap { phase -> (name: String, nanoseconds: UInt64)? in
                let after = totals[phase] ?? .init(), earlier = before[phase] ?? .init()
                guard after.count > earlier.count else { return nil }
                let spent = after.nanoseconds &- earlier.nanoseconds
                inside &+= spent
                return (name: phase.rawValue, nanoseconds: spent)
            }
            runtimePhases.append((name: "runtime_other", nanoseconds: load > inside ? load - inside : 0))
        }
    }

    /// Closes `ready_publish`: the readiness event was written to the owner.
    func ready(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        mark("ready_publish", at: now)
        lock.withLock { readyAt = now }
    }

    /// Each phase closed so far in milliseconds, in order, the load's own after
    /// `runtime_load`, and `total` once ready.
    var durations: [(name: String, milliseconds: UInt64)] {
        lock.withLock {
            var values: [(name: String, milliseconds: UInt64)] = []
            for phase in phases {
                values.append((name: phase.name, milliseconds: phase.nanoseconds / 1_000_000))
                if phase.name == "runtime_load" {
                    values += runtimePhases.map { (name: $0.name, milliseconds: $0.nanoseconds / 1_000_000) }
                }
            }
            if let readyAt { values.append((name: "total", milliseconds: (readyAt &- started) / 1_000_000)) }
            return values
        }
    }

    /// The fields the load's `darkbloom-load-memory-v1` lines carry after
    /// their own (new keys only; a reader ignores keys it does not know).
    var loadMemoryFields: String {
        durations.map { "phase_\($0.name)_ms=\($0.milliseconds)" }.joined(separator: " ")
    }

    /// The one line per worker start, written once its readiness is published.
    func line(rank: Int, epoch: UUID, generation: UInt64?, modelID: String, mode: String, stageCut: Int) -> String {
        let named = generation.map { "\($0)" } ?? "none"
        let head: [String] = [Self.schema, "rank=\(rank)", "epoch=\(epoch.uuidString.lowercased())",
                              "generation=\(named)", "model=\(modelID)", "mode=\(mode)", "stage_cut=\(stageCut)"]
        let times: [String] = durations.map { "\($0.name)_ms=\($0.milliseconds)" }
        return (head + times).joined(separator: " ")
    }
}
