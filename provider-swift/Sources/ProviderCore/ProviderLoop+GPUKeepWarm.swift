import Foundation

extension ProviderLoop {
    /// Starts the opt-in `GPUKeepWarm` for this session; with both modes off
    /// (the default) nothing is created and no task runs.
    internal func startGPUKeepWarm(
        policy: GPUKeepWarm.Policy = .init(environment: ProcessInfo.processInfo.environment),
        submitter suppliedSubmitter: (any GPUWakeSubmitting)? = nil
    ) {
        stopGPUKeepWarm()
        guard policy.isEnabled else { return }
        guard let submitter = suppliedSubmitter ?? Self.makeGPUWakeSubmitter() else {
            logger.warning("GPU keep-warm requested but no Metal queue is available; leaving it off")
            return
        }
        let serviceBudget = kvBudget.serviceBudget
        let state = self.state
        let keepWarm = GPUKeepWarm(
            policy: policy,
            signals: .init(
                busy: { !serviceBudget.isIdle },
                idleFor: { serviceBudget.isIdle(for: $0) },
                modelLoaded: { !state.warmModels.isEmpty }),
            submitter: submitter)
        gpuKeepWarm = keepWarm
        logger.info("GPU keep-warm on: wake-on-accept=\(policy.wakeOnAccept), idle heartbeat=\(policy.idleHeartbeat)")
        if policy.idleHeartbeat {
            gpuKeepWarmTask = Task.detached(priority: .background) { await keepWarm.runHeartbeat() }
        }
    }

    internal func stopGPUKeepWarm() {
        gpuKeepWarmTask?.cancel()
        gpuKeepWarmTask = nil
        gpuKeepWarm = nil
    }

    private static func makeGPUWakeSubmitter() -> (any GPUWakeSubmitting)? {
        #if canImport(Metal)
        MetalGPUWakeSubmitter()
        #else
        nil
        #endif
    }
}
