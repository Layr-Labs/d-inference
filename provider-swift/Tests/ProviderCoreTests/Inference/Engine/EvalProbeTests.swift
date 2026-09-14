import Foundation
import MLX
import Testing

@testable import ProviderCore

/// Integration test for the mlx-swift `EvalProbe` (#2): a real blocking `eval`
/// must flow through the instrumented `evalLock.withLock` and update the probe.
/// Assertions are monotonic (cumulative counters only) so they stay robust under
/// Swift Testing's parallel execution + other tests issuing concurrent evals.
@Suite("EvalProbe wiring")
struct EvalProbeTests {

    @Test func aCompletedEvalAdvancesTheProbe() {
        let before = MLX.EvalProbe.evalsCompleted
        // Force a tiny blocking eval through the instrumented chokepoint.
        let a = MLXArray([1, 2, 3]) + MLXArray([4, 5, 6])
        MLX.eval(a)
        // The probe must have counted at least our eval (cumulative, monotonic).
        #expect(MLX.EvalProbe.evalsCompleted > before)
        // longest is non-negative and the elapsed read never traps.
        #expect(MLX.EvalProbe.longestEvalMs >= 0)
        #expect(MLX.EvalProbe.currentEvalElapsedMs >= 0)
    }
}
