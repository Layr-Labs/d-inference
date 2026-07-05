import Foundation
import Testing
@testable import ProviderCore

@Suite("Adaptive prefill roofline seed")
struct AdaptivePrefillSeedTests {

    private func hardware(
        _ family: ChipFamily,
        _ tier: ChipTier,
        gpuCores: UInt32,
        bandwidth: UInt32,
        memoryGb: UInt64 = 128,
        memoryAvailableGb: UInt64 = 124,
        chipName: String = "Apple Silicon"
    ) -> HardwareInfo {
        HardwareInfo(
            machineModel: "Test",
            chipName: chipName,
            chipFamily: family,
            chipTier: tier,
            memoryGb: memoryGb,
            memoryAvailableGb: memoryAvailableGb,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: gpuCores,
            memoryBandwidthGbs: bandwidth
        )
    }

    private func gptOSS20b() -> ModelArchitecture {
        ModelArchitecture(
            numLayers: 24, kvHeads: 8, headDim: 64,
            numKvSharedLayers: 0, globalHeadDim: nil, numGlobalKvHeads: nil,
            slidingWindowPattern: nil, layerTypes: nil, maxContextLength: 131_072,
            numLocalExperts: 32, numExpertsPerTok: 4,
            hiddenSize: 2880, intermediateSize: 2880
        )
    }

    private func denseModel() -> ModelArchitecture {
        ModelArchitecture(
            numLayers: 32, kvHeads: 8, headDim: 128,
            numKvSharedLayers: 0, globalHeadDim: nil, numGlobalKvHeads: nil,
            slidingWindowPattern: nil, layerTypes: nil, maxContextLength: 8192,
            numLocalExperts: nil, numExpertsPerTok: nil,
            hiddenSize: 4096, intermediateSize: 14_336
        )
    }

    // MARK: - Hardware roofline table anchors

    @Test("M4 Max roofline matches the verified anchor (36.9 TFLOPS, ridge ≈68)")
    func m4MaxRoofline() {
        let hw = hardware(.m4, .max, gpuCores: 40, bandwidth: 546)
        #expect(abs(hw.estimatedPeakFp16Flops - 3.6864e13) < 1e10)
        #expect(abs(hw.rooflineRidgeFlopPerByte - 67.5) < 1.0)
    }

    @Test("unknown family has no peak FLOPS (seed skipped)")
    func unknownNoPeak() {
        let hw = hardware(.unknown, .unknown, gpuCores: 40, bandwidth: 546)
        #expect(hw.estimatedPeakFp16Flops == 0)
        #expect(hw.rooflineRidgeFlopPerByte == 0)
    }

    // MARK: - Seed plan

    @Test("M4 Max + gpt-oss-20b seeds the measured 1536 optimum")
    func m4MaxGptOSSSeed() {
        let plan = AdaptivePrefillSeed.plan(
            hardware: hardware(.m4, .max, gpuCores: 40, bandwidth: 546),
            model: gptOSS20b()
        )
        #expect(plan?.initialChunkSize == 1536)
        #expect(plan?.ladder.contains(1536) == true)
        #expect(plan?.ladder.max() == 4096)        // M4 Max stays in the safe band
        #expect(plan?.ladder.contains(8192) == false)
    }

    @Test("a dense model seeds small (smallest rung)")
    func denseSeedsSmall() {
        let plan = AdaptivePrefillSeed.plan(
            hardware: hardware(.m4, .max, gpuCores: 40, bandwidth: 546),
            model: denseModel()
        )
        #expect(plan?.initialChunkSize == 512)
    }

    @Test("the M1–M4 fleet clusters in the 1024–2048 band for gpt-oss-20b")
    func fleetClusters() {
        let fleet: [(ChipFamily, ChipTier, UInt32, UInt32)] = [
            (.m1, .max, 32, 400),
            (.m2, .ultra, 76, 800),
            (.m3, .max, 40, 400),
            (.m3, .ultra, 80, 819),
            (.m4, .pro, 20, 273),
            (.m4, .max, 40, 546),
        ]
        for (family, tier, cores, bw) in fleet {
            let plan = AdaptivePrefillSeed.plan(
                hardware: hardware(family, tier, gpuCores: cores, bandwidth: bw),
                model: gptOSS20b())
            let seed = plan?.initialChunkSize ?? 0
            #expect((1024...2048).contains(seed), "\(family)/\(tier) seeded \(seed)")
            #expect(plan?.ladder.contains(8192) == false, "\(family)/\(tier) must not expose 8192")
        }
    }

    @Test("synthetic M5 Max fingerprint seeds larger (≈4096)")
    func m5MaxSeed() {
        let hw = hardware(.m5, .max, gpuCores: 40, bandwidth: 614, chipName: "Apple M5 Max")
        // M5 ridge is in matrix-unit territory, well above the M1–M4 band.
        #expect(hw.rooflineRidgeFlopPerByte > 120)
        let plan = AdaptivePrefillSeed.plan(hardware: hw, model: gptOSS20b())
        #expect(plan?.initialChunkSize == 4096)
    }

    @Test("M5 8192 rung is gated behind the env flag, but the seed stays at 4096")
    func m5GatedTopRung() {
        let hw = hardware(.m5, .max, gpuCores: 40, bandwidth: 614)
        let model = gptOSS20b()

        let gatedOff = AdaptivePrefillSeed.plan(
            hardware: hw, model: model,
            guardrails: .init(allow8192: false))
        #expect(gatedOff?.ladder.contains(8192) == false)

        let gatedOn = AdaptivePrefillSeed.plan(
            hardware: hw, model: model,
            guardrails: .init(allow8192: true))
        #expect(gatedOn?.ladder.contains(8192) == true)
        #expect(gatedOn?.initialChunkSize == 4096)  // climb to 8192, never seed it
    }

    @Test("unknown chip ⇒ no seed; policy falls back to the empirical 512 start")
    func unknownChipFallback() {
        let hw = hardware(.unknown, .unknown, gpuCores: 40, bandwidth: 546)
        #expect(AdaptivePrefillSeed.plan(hardware: hw, model: gptOSS20b()) == nil)
        let policy = AdaptivePrefillSeed.policy(hardware: hw, model: gptOSS20b(), environment: [:])
        #expect(policy.initialState().currentChunkSize == 512)
    }

    @Test("a tight memory budget clamps the ladder ceiling")
    func memoryClampReducesLadder() {
        // 1 GB available ⇒ the per-token activation estimate caps the chunk well
        // below the high rungs.
        let hw = hardware(.m4, .max, gpuCores: 40, bandwidth: 546,
                          memoryGb: 8, memoryAvailableGb: 1)
        let plan = AdaptivePrefillSeed.plan(hardware: hw, model: gptOSS20b())
        #expect((plan?.ladder.max() ?? .max) < 2048)
        #expect((plan?.initialChunkSize ?? .max) <= (plan?.ladder.max() ?? 0))
    }
}
