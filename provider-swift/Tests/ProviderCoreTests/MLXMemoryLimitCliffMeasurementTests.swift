// Copyright © 2026 Eigen Labs.
//
// Measurement, not a gate (T3-04 / T13-05): how much slower MLX evaluates
// once `Memory.activeMemory` exceeds `Memory.memoryLimit`. In the vendored
// mlx (`transforms.cpp` eval_impl) every primitive is followed by
// `if (n_active_tasks > MAX_ACTIVE_TASKS || (active > limit && n_active_tasks
// > 0)) { finalize open streams; wait_for_one; while (active > limit &&
// n_active_tasks > 0) wait_for_one; }` — so above the limit, whenever a
// command buffer is in flight (the Metal backend commits one every 20–50
// ops, `device.cpp max_ops_per_buffer_`, and on every eval boundary), the
// next primitive commits and DRAINS the GPU: CPU encode / GPU execute
// overlap is lost and each in-flight buffer becomes a round-trip.
//
// Two shapes are timed: one long lazy chain evaluated once (buffers commit
// only every max_ops_per_buffer ops, so the regime bites at most every few
// dozen primitives) and a step loop of small evals (a buffer is in flight at
// every primitive, the decode-step shape). Opt-in behind its OWN switch
// (`DARKBLOOM_MLX_CLIFF_MEASUREMENT=1`, on top of `DARKBLOOM_LIVE_MLX_TESTS`)
// and documented as RUN ALONE: it mutates the process-global MLX limit for
// a short window (restored in `defer`), and any other suite evaluating in
// parallel — the live suites do — would run inside the regime it induces.
// Prints the ratios; asserts nothing tight, because a loaded machine makes
// timing noisy — the numbers are the deliverable.
//
//   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_MLX_CLIFF_MEASUREMENT=1 \
//     swift test --skip-build --filter MLXMemoryLimitCliffMeasurementTests

import Foundation
import MLX
import Testing

@testable import ProviderCore

@Suite("MLX over-limit eval serialization (measurement, live-gated)", .serialized)
struct MLXMemoryLimitCliffMeasurementTests {

    @Test("lazy chain of 400 primitives and a 200-step eval loop: limit above vs below active")
    func perPrimitiveSerializationAboveTheLimit() {
        guard LiveInferenceFixtures.liveTestsEnabled,
            ProcessInfo.processInfo.environment["DARKBLOOM_MLX_CLIFF_MEASUREMENT"] == "1"
        else { return }
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let originalLimit = MLX.Memory.memoryLimit
        defer { MLX.Memory.memoryLimit = originalLimit }

        let held = MLXArray.zeros([4096, 4096], dtype: .float32)  // 64 MiB, keeps active > 1 B
        eval(held)
        let clock = ContinuousClock()
        func chain(_ primitives: Int) -> Duration {
            clock.measure {
                var x = held
                for _ in 0 ..< primitives { x = x + 1 }
                eval(x)
            }
        }
        func steps(_ count: Int) -> Duration {
            clock.measure {
                var x = held
                for _ in 0 ..< count {
                    x = x * 1.0001 + 1
                    eval(x)
                }
            }
        }
        _ = chain(50)  // warm the kernels
        _ = steps(10)
        let chainAbove = chain(400)
        let stepsAbove = steps(200)
        MLX.Memory.memoryLimit = 1
        #expect(MLX.Memory.activeMemory > MLX.Memory.memoryLimit)
        let chainBelow = chain(400)
        let stepsBelow = steps(200)
        MLX.Memory.memoryLimit = originalLimit
        func ratio(_ below: Duration, _ above: Duration) -> String {
            String(
                format: "%.2f",
                Double(below.components.attoseconds) / max(1, Double(above.components.attoseconds)))
        }
        print(
            "MLX over-limit cliff (loaded machine): 400-primitive lazy chain — limit above active: "
                + "\(chainAbove), below: \(chainBelow), slowdown ×\(ratio(chainBelow, chainAbove)); "
                + "200-step eval loop (64 MiB rows) — above: \(stepsAbove), below: \(stepsBelow), "
                + "slowdown ×\(ratio(stepsBelow, stepsAbove))")
        #expect(chainBelow > .zero)
        #expect(stepsBelow > .zero)
    }
}
