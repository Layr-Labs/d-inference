import Foundation
import ProviderCore

/// CLI presentation of `GLM5NextWiredLimit`: the `doctor` check, the `start`
/// notice and the `status` hint. Each applies only when GLM-5.3-Flash is in use
/// on a Mac with a validated recommendation. Below the GPU use GLM plans at
/// full KV the provider holds GLM's KV grant to the limit
/// (`GLM5NextGPULimitKVBudget`), so the advice says so and how to raise it.
enum GLMWiredLimitAdvice {
    static let checkName = "glm wired limit"
    static let actionHeading = "GLM-5.3-FLASH GPU WIRED-MEMORY LIMIT — ACTION RECOMMENDED"

    struct DoctorResult {
        let check: DoctorCheck
        /// Printed after the detailed checks while a limit is below the recommendation.
        let actionGuide: String?
    }

    /// GLM is downloaded, selected in the config, or served by the daemon.
    static func glmInUse(snapshot: RuntimeSnapshot, daemonState: DaemonState?) -> Bool {
        let backend = snapshot.config.backend
        let named = [backend.model].compactMap { $0 } + backend.enabledModels + backend.preloadModels
            + (daemonState?.advertisedModels ?? []) + (daemonState?.warmModels ?? [])
        return snapshot.models.contains(where: GLM5NextWiredLimit.isGLM5Next)
            || named.contains(where: GLM5NextWiredLimit.isGLM5Next(modelID:))
    }

    static func doctorCheck(
        hardware: HardwareInfo?, glmInUse: Bool, limits: GLM5NextWiredLimit.Limits,
        cliName: String = BuildEnvironment.current.cliName,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DoctorResult? {
        guard glmInUse, let recommendation = recommendation(for: hardware) else { return nil }
        let current = describe(limits)
        guard !recommendation.isMet(by: limits) else {
            return DoctorResult(
                check: DoctorCheck(
                    name: checkName, status: .pass,
                    detail: "\(current); meets the GLM-5.3-Flash recommendation for "
                        + "\(recommendation.memoryGiB) GB"),
                actionGuide: nil)
        }
        let planned = String(format: "%.0f", Double(recommendation.plannedGPUBytes) / 1e9)
        // Below the GPU limit the provider holds GLM's KV grant to it (`GLM5NextGPULimitKVBudget`).
        let effect = heldToTheLimit(recommendation, limits: limits, environment: environment)
            ? "so the provider holds GLM's KV cache to the lower GPU limit and serves fewer long requests at once"
            : "so Metal command buffers can fail with \"Insufficient Memory\""
        let detail = "GLM-5.3-Flash plans about \(planned) GB of GPU memory at full KV on this "
            + "\(recommendation.memoryGiB) GB Mac, and the macOS wired-memory limits are below the "
            + "recommendation, \(effect). "
            + "Fix: \(recommendation.sysctlCommand) (to keep it after reboot, see below)"
        let guide = [
            "Current: \(current)",
            "Apply now (until reboot), then restart the provider so MLX reads the new limit:",
            "  \(recommendation.sysctlCommand)",
            "  \(cliName) restart",
            "Or both in one step: \(cliName) cluster gpu-limit, then \(cliName) restart "
                + "(it asks once, then for an administrator; --undo takes it back).",
            "Keep it after reboot with this LaunchDaemon (paste the whole block; bootstrap also applies it now):",
        ] + recommendation.launchDaemonInstallCommands
        return DoctorResult(
            check: DoctorCheck(name: checkName, status: .warn, detail: detail),
            actionGuide: guide.joined(separator: "\n"))
    }

    /// `start` prints this when it would serve GLM below the recommendation.
    static func startNotice(
        hardware: HardwareInfo, servedModels: [ModelInfo], limits: GLM5NextWiredLimit.Limits,
        cliName: String = BuildEnvironment.current.cliName,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard servedModels.contains(where: GLM5NextWiredLimit.isGLM5Next),
            let recommendation = recommendation(for: hardware), !recommendation.isMet(by: limits)
        else { return nil }
        guard heldToTheLimit(recommendation, limits: limits, environment: environment) else {
            return recommendation.notice(cliName: cliName)
        }
        return "GLM-5.3-Flash: this Mac's GPU memory limit holds GLM's KV cache below what the Mac can give it, "
            + "so it serves fewer long requests at once. To raise the limit and keep it after reboot: "
            + "`\(cliName) cluster gpu-limit`, then `\(cliName) restart` (`--undo` takes it back; "
            + "`\(cliName) doctor` shows the details)."
    }

    /// The provider holds GLM's KV grant to this GPU limit (`GLM5NextGPULimitKVBudget`), so the plan stays within
    /// it, unless the owner turned that off.
    static func heldToTheLimit(
        _ recommendation: GLM5NextWiredLimit.Recommendation, limits: GLM5NextWiredLimit.Limits,
        environment: [String: String]
    ) -> Bool {
        limits.gpuLimitBytes < recommendation.plannedGPUBytes
            && GLM5NextGPULimitKVBudget.enabled(environment: environment)
    }

    /// `status` prints this under a GLM load error that reports a Metal
    /// out-of-memory command buffer.
    static func statusNotice(
        loadError: DaemonState.ModelLoadError, hardware: HardwareInfo?,
        limits: GLM5NextWiredLimit.Limits, cliName: String = BuildEnvironment.current.cliName
    ) -> String? {
        GLM5NextWiredLimitNotice.notice(
            modelID: loadError.model,
            isMetalOutOfMemory: GLM5NextWiredLimit.isMetalOutOfMemory(loadError.message),
            recommendation: recommendation(for: hardware), limits: limits, cliName: cliName)
    }

    private static func recommendation(for hardware: HardwareInfo?) -> GLM5NextWiredLimit.Recommendation? {
        hardware.flatMap {
            GLM5NextWiredLimit.recommendation(chipFamily: $0.chipFamily, memoryGiB: $0.memoryGb)
        }
    }

    private static func describe(_ limits: GLM5NextWiredLimit.Limits) -> String {
        let workingSet = String(format: "%.1f GiB", Double(limits.metalWorkingSetBytes) / 1_073_741_824)
        let gpu: String
        switch limits.gpuWiredLimitMB {
        case nil: gpu = "iogpu.wired_limit_mb unreadable (Metal working set \(workingSet))"
        case 0?: gpu = "iogpu.wired_limit_mb=0 (macOS default: Metal working set \(workingSet))"
        case let megabytes?: gpu = "iogpu.wired_limit_mb=\(megabytes)"
        }
        func wire(_ name: String, _ value: UInt64?) -> String {
            value.map { "\(name)=\($0)" } ?? "\(name) unreadable"
        }
        return [
            gpu,
            wire("vm.global_user_wire_limit", limits.globalUserWireLimitBytes),
            wire("vm.user_wire_limit", limits.userWireLimitBytes),
        ].joined(separator: ", ")
    }
}
