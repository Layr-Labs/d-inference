import Foundation

/// The rounds a tensor-parallel share probe times (`QwenTensorParallelShareProbe`, `Gemma4TensorParallelShareProbe`):
/// every warm-up round, then timed rounds until `timed` ran or the budget is spent. The budget counts from the first
/// timed round, so a rank whose throwaway request was slow to set up, prefill or warm up (first-use kernel compiles,
/// a GPU the desktop shares) still gives its share step instead of `skipped=budget`; slow timed rounds still stop at the
/// budget. Pair-2's M3 Ultra (2026-11-04) never recorded a share probe for this reason, so the planner had no measured
/// step for it.
public enum ClusterShareProbeRounds {
    /// Each timed round's duration in nanoseconds, in order. A round starts only while the timed rounds so far took
    /// less than `budgetNanoseconds`.
    public static func run(warmup: Int, timed: Int, budgetNanoseconds: UInt64, clock: () -> UInt64,
                           round: () throws -> Void) rethrows -> [UInt64] {
        for _ in 0 ..< max(0, warmup) { try round() }
        var times: [UInt64] = []
        let started = clock()
        for _ in 0 ..< max(0, timed) {
            let roundStarted = clock()
            guard roundStarted &- started < budgetNanoseconds else { break }
            try round()
            times.append(clock() &- roundStarted)
        }
        return times
    }
}
