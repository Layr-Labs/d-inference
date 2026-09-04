// Copyright © 2026 Eigen Labs.
//
// T3-08: the model-load transient probe — reset-before-load, measure-after —
// pure arithmetic plus one case over real MLX counters (no model weights).

import Foundation
import MLX
import Testing

@testable import ProviderCore

private let mib: UInt64 = 1024 * 1024

@Suite("ModelLoadTransientProbe")
struct ModelLoadTransientProbeTests {

    @Test("summary arithmetic: overshoot, this load's residency, and the ratio against disk bytes")
    func summaryArithmetic() {
        let probe = ModelLoadTransientProbe(activeAtResetBytes: 1_000 * mib)
        let summary = probe.end(
            diskBytes: 10_000 * mib,
            steadyActiveBytes: 12_250 * mib,   // 11.25 GiB of weights on top of 1000 MiB
            peakBytes: 14_500 * mib)
        #expect(summary.residentDeltaBytes == 11_250 * mib)
        #expect(summary.peakOverSteadyBytes == 2_250 * mib)
        #expect(abs(summary.peakOverSteadyDiskRatio - 0.225) < 1e-9)
        let line = summary.logLine(modelId: "gpt-oss-20b")
        #expect(line.contains("model=gpt-oss-20b"))
        #expect(line.contains("disk=10000MiB"))
        #expect(line.contains("steady_delta=11250MiB"))
        #expect(line.contains("peak_over_steady=2250MiB"))
        #expect(line.contains("22.5% of disk"))
        #expect(line.contains("active_at_reset=1000MiB"))
    }

    @Test("a peak below steady (counters moved under us) clamps to zero, never traps; zero disk bytes yields ratio 0")
    func clamps() {
        let summary = ModelLoadTransientProbe(activeAtResetBytes: 5 * mib).end(
            diskBytes: 0, steadyActiveBytes: 4 * mib, peakBytes: 3 * mib)
        #expect(summary.residentDeltaBytes == 0)
        #expect(summary.peakOverSteadyBytes == 0)
        #expect(summary.peakOverSteadyDiskRatio == 0)
    }

    @Test("begin() resets the peak exactly once and records what was already resident")
    func beginResets() {
        var resets = 0
        let probe = ModelLoadTransientProbe.begin(activeBytes: 42, resetPeak: { resets += 1 })
        #expect(resets == 1)
        #expect(probe.activeAtResetBytes == 42)
    }

    @Test("live: over real MLX counters the peak since reset covers everything held at once, and steady ≤ peak")
    func liveCountersAreOrdered() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let probe = ModelLoadTransientProbe.begin()
        // "Weights": 16 MiB held through the whole window.
        let weights = MLXArray.zeros([4, 1024, 1024], dtype: .float32)
        eval(weights)
        // "Shard staging": another 32 MiB that is live only briefly.
        do {
            let staging = MLXArray.zeros([8, 1024, 1024], dtype: .float32)
            eval(staging)
            withExtendedLifetime(staging) {}
        }
        let summary = probe.end(diskBytes: 16 * mib)
        // Both were live at once after the reset, so the recorded peak
        // covers them — whatever other tests allocate or free meanwhile.
        #expect(summary.peakBytes >= 48 * mib)
        #expect(summary.peakBytes >= summary.steadyActiveBytes)
        #expect(summary.logLine(modelId: "live").hasPrefix("Model load transient: model=live "))
        withExtendedLifetime(weights) {}
    }
}
