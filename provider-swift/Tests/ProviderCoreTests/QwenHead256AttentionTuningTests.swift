import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Qwen head-256 attention tuning")
struct QwenHead256AttentionTuningTests {
    @Test("qualified M4 Max uses the measured wide composed-prefill block")
    func qualifiedM4Max() {
        let policy = QwenHead256AttentionTuning.policy(
            isQwen35: true,
            environment: [:],
            hardware: hardware(
                machineModel: "Mac16,5", family: .m4, tier: .max,
                memoryGB: 128, gpuCores: 40))

        #expect(policy.control == .fallback)
        #expect(policy.fallbackQueryBlockSize == 512)
        #expect(policy.hardwareQualification == nil)
    }

    @Test("unqualified hardware keeps the historical 128-token block")
    func unqualifiedHardware() {
        let candidates = [
            hardware(family: .m3, tier: .max, memoryGB: 128, gpuCores: 40),
            hardware(family: .m4, tier: .pro, memoryGB: 128, gpuCores: 40),
            hardware(family: .m4, tier: .max, memoryGB: 64, gpuCores: 40),
            hardware(family: .m4, tier: .max, memoryGB: 128, gpuCores: 32),
            hardware(
                machineModel: "Mac16,1", family: .m4, tier: .max,
                memoryGB: 128, gpuCores: 40),
        ]

        for candidate in candidates {
            let policy = QwenHead256AttentionTuning.policy(
                isQwen35: true, environment: [:], hardware: candidate)
            #expect(policy.fallbackQueryBlockSize == 128)
        }
        #expect(
            QwenHead256AttentionTuning.policy(
                isQwen35: false,
                environment: [:],
                hardware: hardware(
                    machineModel: "Mac16,5", family: .m4, tier: .max,
                    memoryGB: 128, gpuCores: 40)
            ).fallbackQueryBlockSize == 128)
    }

    @Test("operator query-block overrides win and malformed values fail closed")
    func operatorOverrides() {
        let key = CBv2AttentionExecutionPolicy.queryBlockEnvironmentVariable
        let qualified = hardware(
            machineModel: "Mac16,5", family: .m4, tier: .max,
            memoryGB: 128, gpuCores: 40)

        #expect(
            QwenHead256AttentionTuning.policy(
                isQwen35: true, environment: [key: "0"], hardware: qualified
            ).fallbackQueryBlockSize == 0)
        #expect(
            QwenHead256AttentionTuning.policy(
                isQwen35: true, environment: [key: "256"], hardware: qualified
            ).fallbackQueryBlockSize == 256)
        #expect(
            QwenHead256AttentionTuning.policy(
                isQwen35: true, environment: [key: "invalid"], hardware: qualified
            ).fallbackQueryBlockSize == 128)
        #expect(
            QwenHead256AttentionTuning.policy(
                isQwen35: true, environment: [key: "-1"], hardware: qualified
            ).fallbackQueryBlockSize == 128)
    }

    @Test("fused is explicit while auto remains unqualified")
    func fusedControl() {
        let key = CBv2AttentionExecutionPolicy.environmentVariable
        let qualified = hardware(
            machineModel: "Mac16,5", family: .m4, tier: .max,
            memoryGB: 128, gpuCores: 40)

        let fused = QwenHead256AttentionTuning.policy(
            isQwen35: true, environment: [key: "fused"], hardware: qualified)
        #expect(fused.control == .fused)
        #expect(fused.hardwareQualification == nil)

        let automatic = QwenHead256AttentionTuning.policy(
            isQwen35: true, environment: [key: "auto"], hardware: qualified)
        #expect(automatic.control == .auto)
        #expect(automatic.hardwareQualification == nil)
    }

    private func hardware(
        machineModel: String = "test",
        family: ChipFamily,
        tier: ChipTier,
        memoryGB: UInt64,
        gpuCores: UInt32
    ) -> HardwareInfo {
        HardwareInfo(
            machineModel: machineModel,
            chipName: "Apple \(family.rawValue) \(tier.rawValue)",
            chipFamily: family,
            chipTier: tier,
            memoryGb: memoryGB,
            memoryAvailableGb: memoryGB > 4 ? memoryGB - 4 : 0,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: gpuCores,
            memoryBandwidthGbs: 500)
    }
}
