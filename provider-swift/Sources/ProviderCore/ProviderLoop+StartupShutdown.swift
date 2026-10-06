import Foundation
import MLX

extension ProviderLoop {
    /// Before the coordinator exists, the ordinary event-loop teardown has no
    /// chance to run. Coalesce signal and schedule cancellation into one owned
    /// cleanup task so a cancelled serve caller cannot abandon loaded bridges.
    internal func shutdownBeforeRegistration() async -> Bool {
        if let task = preRegistrationCleanupTask {
            return await task.value
        }
        let task = Task.detached(priority: .userInitiated) {
            await self.performPreRegistrationShutdown()
        }
        preRegistrationCleanupTask = task
        let finished = await task.value
        // An incomplete native owner stays retained and a later caller may
        // retry after actual progress. Do not cache false completion forever.
        if !finished { preRegistrationCleanupTask = nil }
        return finished
    }

    private func performPreRegistrationShutdown() async -> Bool {
        isShuttingDown = true
        closeNativeMiMoLifecycle()
        if !servingDrain.refusing { beginServingDrain(owner: .lifecycle) }
        stopLocalEndpoint()
        startupPreloadTask?.cancel()
        startupPreloadGateWaiter?.cancel()
        cancelLoadWaiters()

        // Give an owned load time to unwind, but do not let an unresponsive
        // loader hold a termination signal indefinitely. The load-install
        // guard rejects any slot that finishes after shutdown begins.
        let startupTask = startupPreloadTask
        if let startupTask {
            let finished = await waitForPreloads([startupTask], timeout: Self.preloadShutdownTimeout)
            if !finished { logger.warning("Timed out waiting for startup preload to cancel during shutdown") }
        }
        startupPreloadTask = nil
        startupPreloadPendingModels = []

        let upgradeTask = mtpUpgradeMonitorTask
        mtpUpgradeMonitorTask = nil
        upgradeTask?.cancel()
        await specDecFunnel.shutdown()
        await upgradeTask?.value

        let drained = await waitForInflightDrain(timeout: Self.shutdownDrainTimeout)
        if !drained { await cancelAllInflight() }
        await coordinatorClient?.shutdown()
        guard await drainNativeMiMoOwners() else {
            writeDaemonState()
            return false
        }
        while !modelSlots.isEmpty {
            if let unloading = modelsUnloading.first {
                await waitForModelUnload(unloading)
                continue
            }
            for modelID in Array(modelSlots.keys) {
                await unloadModel(modelID)
            }
        }
        powerAssertion.releaseAll()
        if nativeMiMoAllowsReclamation() { MLX.Memory.clearCache() }
        writeDaemonState()
        return true
    }
}
