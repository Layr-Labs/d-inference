import Testing
@testable import ProviderCore

@Test func deadlineRuntimeEnvironmentAllowsOnlyExactOperationalExceptions() {
    #expect(DeadlineRuntimeEnvironment.permitsQualification([:]))
    #expect(DeadlineRuntimeEnvironment.permitsQualification([
        "PATH": "/usr/bin", "HOME": "/tmp/provider",
        "DARKBLOOM_AUTH_TOKEN_PATH": "/tmp/auth",
        "DARKBLOOM_KEYCHAIN_ACCESS_GROUP": "test.group",
        "DARKBLOOM_LOCAL_DIR": "/tmp/local",
        "DARKBLOOM_LOADED_MODELS_FILE": "/tmp/models",
        "DARKBLOOM_NO_UPDATE_CHECK": "1",
        "DARKBLOOM_PID_FILE": "/tmp/pid",
        "DARKBLOOM_STATE_FILE": "/tmp/state",
        "DARKBLOOM_WATCHDOG_STATE": "/tmp/watchdog",
    ]))
    for key in ["DARKBLOOM_FUTURE_TUNING", "DARKBLOOM_STATE_FILE_TUNING", "DARKBLOOM_CBV2_COMPILED"] {
        #expect(!DeadlineRuntimeEnvironment.permitsQualification([key: "0"]))
    }
}

@Test func deadlineProfileRejectsUnmeasuredRuntimeOverrides() {
    let profile = deadlineCalibrationProfileFixture()
    let hardware = HardwareInfo(machineModel: "test", chipName: profile.chipName,
        chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 100,
        cpuCores: .init(total: 16, performance: 12, efficiency: 4), gpuCores: 40,
        memoryBandwidthGbs: 0)
    func resolve(_ environment: [String: String]) -> DeadlinePerformanceProfile? {
        DeadlinePerformanceProfiles.resolve(modelID: profile.modelId,
            artifactSHA256: profile.artifactSha256, kvBackend: profile.kvBackend,
            runtime: profile.runtimeConfiguration, hardware: hardware,
            environment: environment, providerVersion: profile.providerVersion, profiles: [profile])
    }
    #expect(resolve([:]) == profile)
    #expect(resolve(["DARKBLOOM_STATE_FILE": "/tmp/state"]) == profile)
    for key in [
        "MLX_METAL_FAST_SYNCH", "MTPLX_KERNEL_MODE", "QWEN_MTP_SERIAL",
        "MLX_FUTURE_TUNING", "MTPLX_FUTURE_TUNING", "QWEN_FUTURE_TUNING",
        "DARKBLOOM_CBV2_MIXED_PREFILL_CAP", "DARKBLOOM_QWEN4_DECODE_PROFILE",
        "DARKBLOOM_BF16_WEIGHTS", "DARKBLOOM_FUTURE_TUNING",
    ] {
        for value in ["1", "0", ""] {
            #expect(resolve([key: value]) == nil)
        }
    }
    // Normal CLI startup projects these kernel controls. Until that execution
    // environment is part of reviewed evidence, it also keeps the fallback.
    let projected = GemmaOptimizationEnvironment.projection(for: .init(), getenv: { _ in nil })
    #expect(resolve(projected) == nil)
}
