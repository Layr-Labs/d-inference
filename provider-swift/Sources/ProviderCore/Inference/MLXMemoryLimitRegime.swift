// Copyright © 2026 Eigen Labs.
//
// MLX active-over-limit regime (T13-05).
//
// MLX's `eval_impl` (mlx/transforms.cpp) commits every open stream and
// waits for one outstanding task after EVERY primitive while
// `get_active_memory() > get_memory_limit() && n_active_tasks > 0`. Above
// the limit a ~1,760-dispatch decode step therefore becomes ~1,760 GPU
// round-trips — a silent, large slowdown with no log, counter or heartbeat
// trace, indistinguishable from the "wedged slot" class. The allocator
// itself never throttles or throws on bytes (`set_memory_limit` only moves
// `block_limit_`/`gc_limit_`; only the resource COUNT throws), so the limit
// is a pure eval-scheduling threshold. Reachable whenever the provider's
// effective cap exceeds the MLX limit, i.e. 0.9 × physical > physical −
// reserve: every box below 60 GB with the historical 6 GiB reserve.
//
// This is the pure transition function the capacity tick samples; it is
// edge-triggered with hysteresis so a value hovering at the limit does not
// emit one event per tick.

import Foundation

enum MLXMemoryLimitRegime {
    enum Transition: Equatable {
        case enter
        case exit
        case none
    }

    /// Once over, the regime is left only when active falls below this
    /// fraction of the limit.
    static let exitFraction = 0.95

    /// `limitBytes` nil (no limit configured in this process) or ≤ 0 never
    /// enters; a stale over-state exits so the counter cannot run forever
    /// on a limit that went away. The enter predicate is the engine's own:
    /// strict `active > limit`.
    static func transition(activeBytes: Int, limitBytes: Int?, wasOver: Bool) -> Transition {
        guard let limitBytes, limitBytes > 0 else { return wasOver ? .exit : .none }
        if wasOver {
            return Double(activeBytes) < Double(limitBytes) * exitFraction ? .exit : .none
        }
        return activeBytes > limitBytes ? .enter : .none
    }
}
