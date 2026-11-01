import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("GLM-5.3-Flash wired-limit doctor, start and status advice")
struct GLMWiredLimitAdviceTests {
    private static let command = "sudo sysctl -w iogpu.wired_limit_mb=245760 "
        + "vm.global_user_wire_limit=261134011596 vm.user_wire_limit=261134011596"
    private static let defaults = GLM5NextWiredLimit.Limits(
        gpuWiredLimitMB: 0, globalUserWireLimitBytes: 241_892_558_110,
        userWireLimitBytes: 241_892_558_110, metalWorkingSetBytes: 239_143_780_352)
    private static let production = GLM5NextWiredLimit.Limits(
        gpuWiredLimitMB: 245_760, globalUserWireLimitBytes: 261_134_011_596,
        userWireLimitBytes: 261_134_011_596, metalWorkingSetBytes: 239_143_780_352)
    private static let glm = ModelInfo(
        id: "glm-5.3-flash", modelType: "glm5_next", sizeBytes: 1, estimatedMemoryGb: 1)
    private static let qwen = ModelInfo(
        id: "qwen3.5-35b-a3b", modelType: "qwen3_5_moe", sizeBytes: 1, estimatedMemoryGb: 1)

    private static func hardware(_ family: ChipFamily, _ tier: ChipTier, memoryGb: UInt64) -> HardwareInfo {
        HardwareInfo(
            machineModel: "Mac", chipName: "Apple \(family.rawValue) \(tier.rawValue)",
            chipFamily: family, chipTier: tier, memoryGb: memoryGb, memoryAvailableGb: memoryGb - 4,
            cpuCores: CpuCores(total: 32, performance: 24, efficiency: 8), gpuCores: 80,
            memoryBandwidthGbs: 1200)
    }

    private static let m5Ultra = hardware(.m5, .ultra, memoryGb: 256)

    private static func snapshot(models: [ModelInfo] = [], enabledModels: [String] = []) -> RuntimeSnapshot {
        var backend = BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1)
        backend.enabledModels = enabledModels
        return RuntimeSnapshot(
            configPath: URL(fileURLWithPath: "/tmp/darkbloom-glm-wired-limit-test.toml"),
            configFileExists: true,
            config: ProviderConfig(
                provider: ProviderSettings(name: "glm-wired-limit-test", memoryReserveGB: 4),
                backend: backend,
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
            hardware: m5Ultra, hardwareError: nil, models: models)
    }

    @Test("256 GB M5 Ultra on the macOS default warns with the exact fix and the LaunchDaemon")
    func defaultLimitWarns() throws {
        let result = try #require(GLMWiredLimitAdvice.doctorCheck(
            hardware: Self.m5Ultra, glmInUse: true, limits: Self.defaults, cliName: "darkbloom"))
        #expect(result.check.name == "glm wired limit")
        #expect(result.check.status == .warn)
        #expect(result.check.detail == "GLM-5.3-Flash plans about 247 GB of GPU memory at full KV on "
            + "this 256 GB Mac, and the macOS wired-memory limits are below the recommendation, so "
            + "Metal command buffers can fail with \"Insufficient Memory\". Fix: \(Self.command) "
            + "(to keep it after reboot, see below)")

        let guide = try #require(result.actionGuide).components(separatedBy: "\n")
        #expect(guide.first == "Current: iogpu.wired_limit_mb=0 (macOS default: Metal working set "
            + "222.7 GiB), vm.global_user_wire_limit=241892558110, vm.user_wire_limit=241892558110")
        #expect(guide.contains("  \(Self.command)"))
        #expect(guide.contains("  darkbloom restart"))
        #expect(guide.contains(
            "sudo tee /Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist >/dev/null <<'EOF'"))
        #expect(guide.contains(#"<?xml version="1.0" encoding="UTF-8"?>"#))
        #expect(guide.contains("\t\t<string>iogpu.wired_limit_mb=245760</string>"))
        #expect(guide.contains("EOF"))
        #expect(guide.last
            == "sudo launchctl bootstrap system /Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist")
    }

    @Test("the production limits pass and show the current values")
    func productionLimitsPass() throws {
        let result = try #require(GLMWiredLimitAdvice.doctorCheck(
            hardware: Self.m5Ultra, glmInUse: true, limits: Self.production))
        #expect(result.check.status == .pass)
        #expect(result.check.detail == "iogpu.wired_limit_mb=245760, "
            + "vm.global_user_wire_limit=261134011596, vm.user_wire_limit=261134011596; "
            + "meets the GLM-5.3-Flash recommendation for 256 GB")
        #expect(result.actionGuide == nil)
    }

    @Test("the check is skipped without GLM, off M5, or at an unvalidated memory size")
    func skippedWhenNotApplicable() {
        #expect(GLMWiredLimitAdvice.doctorCheck(
            hardware: Self.m5Ultra, glmInUse: false, limits: Self.defaults) == nil)
        #expect(GLMWiredLimitAdvice.doctorCheck(
            hardware: Self.hardware(.m3, .ultra, memoryGb: 256), glmInUse: true, limits: Self.defaults) == nil)
        #expect(GLMWiredLimitAdvice.doctorCheck(
            hardware: Self.hardware(.m5, .ultra, memoryGb: 512), glmInUse: true, limits: Self.defaults) == nil)
        #expect(GLMWiredLimitAdvice.doctorCheck(hardware: nil, glmInUse: true, limits: Self.defaults) == nil)
    }

    @Test("GLM counts as in use when downloaded, selected in the config or served")
    func glmInUse() {
        #expect(!GLMWiredLimitAdvice.glmInUse(snapshot: Self.snapshot(models: [Self.qwen]), daemonState: nil))
        #expect(GLMWiredLimitAdvice.glmInUse(snapshot: Self.snapshot(models: [Self.glm]), daemonState: nil))
        #expect(GLMWiredLimitAdvice.glmInUse(
            snapshot: Self.snapshot(enabledModels: ["glm-5.3-flash"]), daemonState: nil))
        let serving = DaemonState(
            pid: 1, version: "test", writtenAt: 0, startedAt: 0, advertisedModels: ["glm-5.3-flash"])
        #expect(GLMWiredLimitAdvice.glmInUse(snapshot: Self.snapshot(), daemonState: serving))
    }

    @Test("start prints the notice only when it would serve GLM below the recommendation")
    func startNotice() {
        let notice = GLMWiredLimitAdvice.startNotice(
            hardware: Self.m5Ultra, servedModels: [Self.qwen, Self.glm], limits: Self.defaults,
            cliName: "darkbloom")
        #expect(notice?.contains("Fix: \(Self.command), then `darkbloom restart`") == true)
        #expect(notice?.contains("`darkbloom doctor`") == true)
        #expect(GLMWiredLimitAdvice.startNotice(
            hardware: Self.m5Ultra, servedModels: [Self.qwen], limits: Self.defaults) == nil)
        #expect(GLMWiredLimitAdvice.startNotice(
            hardware: Self.m5Ultra, servedModels: [Self.glm], limits: Self.production) == nil)
    }

    @Test("status explains a GLM load error that reports a Metal out-of-memory command buffer")
    func statusNotice() {
        let outOfMemory = DaemonState.ModelLoadError(
            model: "glm-5.3-flash",
            message: "Model 'glm-5.3-flash' loaded but its v2 engine construction failed: caught(\"[METAL] "
                + "Command buffer execution failed: Insufficient Memory "
                + "(00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory).\") — unloaded",
            at: 0)
        let notice = GLMWiredLimitAdvice.statusNotice(
            loadError: outOfMemory, hardware: Self.m5Ultra, limits: Self.defaults, cliName: "darkbloom")
        #expect(notice?.contains(Self.command) == true)

        let admission = DaemonState.ModelLoadError(
            model: "glm-5.3-flash", message: "Insufficient memory for 'glm-5.3-flash' at final load admission",
            at: 0)
        #expect(GLMWiredLimitAdvice.statusNotice(
            loadError: admission, hardware: Self.m5Ultra, limits: Self.defaults) == nil)
        #expect(GLMWiredLimitAdvice.statusNotice(
            loadError: outOfMemory, hardware: Self.m5Ultra, limits: Self.production) == nil)
    }
}
