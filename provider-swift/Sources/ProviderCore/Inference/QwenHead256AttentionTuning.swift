import Foundation
import MLXLMCommon

enum QwenHead256AttentionTuning {
    static let qualifiedQueryBlockSize = 512
    static let qualifiedMachineModel = "Mac16,5"
    static let qualifiedMemoryGB: UInt64 = 128
    static let qualifiedGPUCores: UInt32 = 40

    static let currentMachineQualifiesForWideComposedPrefill: Bool = {
        guard
            (try? sysctlString("hw.model")) == qualifiedMachineModel,
            (try? sysctlString("machdep.cpu.brand_string")) == "Apple M4 Max"
        else { return false }
        let bytesPerGB = UInt64(1024 * 1024 * 1024)
        return ProcessInfo.processInfo.physicalMemory / bytesPerGB >= qualifiedMemoryGB
    }()

    static func policy(
        isQwen35: Bool,
        environment: [String: String],
        hardware: HardwareInfo?
    ) -> CBv2AttentionExecutionPolicy {
        policy(
            isQwen35: isQwen35,
            environment: environment,
            wideComposedPrefillQualified: hardware.map(qualifiesForWideComposedPrefill) == true)
    }

    static func currentMachinePolicy(
        isQwen35: Bool,
        environment: [String: String]
    ) -> CBv2AttentionExecutionPolicy {
        policy(
            isQwen35: isQwen35,
            environment: environment,
            wideComposedPrefillQualified:
                isQwen35 && currentMachineQualifiesForWideComposedPrefill)
    }

    private static func policy(
        isQwen35: Bool,
        environment: [String: String],
        wideComposedPrefillQualified: Bool
    ) -> CBv2AttentionExecutionPolicy {
        let control = environment[CBv2AttentionExecutionPolicy.environmentVariable]
            .flatMap {
                CBv2AttentionExecutionControl(
                    rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            } ?? .fallback

        let queryBlockSize: Int
        if let raw = environment[CBv2AttentionExecutionPolicy.queryBlockEnvironmentVariable] {
            queryBlockSize = Int(raw).flatMap { $0 >= 0 ? $0 : nil } ?? 128
        } else if isQwen35, wideComposedPrefillQualified {
            queryBlockSize = qualifiedQueryBlockSize
        } else {
            queryBlockSize = 128
        }

        // No architecture has qualified the fused D256 kernel as a speed route.
        // Explicit `fused` remains available as the bounded-memory A/B arm;
        // `auto` therefore fails closed until a future hardware qualification.
        return CBv2AttentionExecutionPolicy(
            control: control,
            hardwareQualification: nil,
            fallbackQueryBlockSize: queryBlockSize)
    }

    static func qualifiesForWideComposedPrefill(_ hardware: HardwareInfo) -> Bool {
        hardware.machineModel == qualifiedMachineModel
            && hardware.chipFamily == .m4
            && hardware.chipTier == .max
            && hardware.memoryGb == qualifiedMemoryGB
            && hardware.gpuCores == qualifiedGPUCores
    }
}
