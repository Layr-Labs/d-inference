// Copyright © 2026 Eigen Labs.
//
// LIVE cold-load stage report (T4-04): the only non-vacuous full-path test.
// `loadModelContainer` has no seam, so a real checkpoint is the only way to
// exercise every stage mark on the production load path. Gated like the
// other multi-GB suites (DARKBLOOM_LIVE_MLX_TESTS + gpt-oss in the local HF
// cache); skips cleanly otherwise.

import Foundation
import MLX
import Testing

@testable import ProviderCore

@Suite("Model load stage report (live)", .serialized)
struct ModelLoadStageTelemetryLiveTests {

    static let gptossID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    private static let gib: UInt64 = 1024 * 1024 * 1024

    private func makeLiveLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: ProcessInfo.processInfo.physicalMemory / Self.gib,
                memoryAvailableGb: max(1, ProcessInfo.processInfo.physicalMemory / Self.gib - 4),
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [
                ModelInfo(
                    id: Self.gptossID, modelType: "gpt_oss",
                    sizeBytes: 13 * Self.gib, estimatedMemoryGb: 14.0)
            ],
            config: ProviderConfig(
                provider: ProviderSettings(name: "load-stages-live", memoryReserveGB: 8),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test("a real cold load reports every stage with the documented invariants")
    func coldLoadReportsEveryStage() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else {
            return  // env-gated (multi-GB weights)
        }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gptossID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * 1024 * 1024 * 1024)

        let loop = try makeLiveLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        defer {
            Task {
                await loop.unloadModel(Self.gptossID)
                MLX.Memory.clearCache()
            }
        }

        try await loop.ensureModelLoaded(modelId: Self.gptossID)
        let report = try #require(await loop.loadStageReportForTesting(modelId: Self.gptossID))
        // Surface the measured stages on stdout so a quiet re-run of this
        // test IS the before/after measurement (the log line goes to the
        // unified log, not the test output).
        print("MODEL_LOAD_STAGES \(Self.gptossID): \(report.logSummary)")

        // Timing invariants: the heartbeat window covers container load +
        // engine build; every stage ran.
        #expect(report.totalMs >= report.containerLoadMs + report.buildMs)
        #expect(report.containerLoadMs > 0)
        #expect(report.buildMs > 0)
        #expect(report.postLoadProbeMs >= 0)
        #expect(report.evictMs >= 0)
        #expect(report.hashMs >= 0)
        #expect(report.hashPasses >= 0 && report.hashPasses <= 2)

        // Residency: the weights are resident after the post-load clearCache.
        // The peak is THIS load's — `ModelLoadTransientProbe.begin()` resets
        // MLX's counter right before shard staging (T3-08), so an earlier
        // suite's higher peak in this process cannot mask it — and the ratio
        // is the per-load footprint over the pre-load baseline, on the disk
        // scale the 1.2 admit padding uses.
        #expect(report.steadyActiveGb > 8)
        #expect(report.diskGb > 10)
        #expect(report.estimatedGb == 14.0)
        let peak = try #require(report.peakActiveGb)
        #expect(!report.peakMasked)
        #expect(peak >= report.steadyActiveGb * 0.9)
        #expect(report.peakBaselineGb <= report.steadyActiveGb)
        #expect(report.steadyDeltaGb > 8, "this load's own residency: \(report.steadyDeltaGb)")
        let ratio = try #require(report.transientRatio)
        #expect(ratio > 0.5 && ratio < 2.0, "per-load peak over disk: \(ratio)")
        // The telemetry payload carries every field the log line does.
        let fields = report.telemetryFields
        #expect(fields["total_ms"] != nil && fields["container_load_ms"] != nil && fields["build_ms"] != nil)
    }
}
