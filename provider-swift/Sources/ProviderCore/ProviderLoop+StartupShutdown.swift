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
        guard await stopAppAttestWorkerAndWait() else {
            writeDaemonState()
            return false
        }

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
        await unloadAllModelsForShutdown()
        powerAssertion.releaseAll()
        if nativeMiMoAllowsReclamation() { MLX.Memory.clearCache() }
        writeDaemonState()
        return true
    }

    /// How long shutdown waits for an unload already in progress.
    static let shutdownUnloadWait: Duration = .seconds(15)

    /// Shutdown teardown: unloads every slot, each within a bounded wait. A
    /// slot whose native retirement is unproven stays resident and unloading
    /// for the rest of the process (`GLM5NextRetirement.retainUnpublished`),
    /// and nothing resumes a wait for it; a native shutdown can also outlive
    /// any bound. Process exit releases that memory, so shutdown stops
    /// waiting for such a slot (or one whose unload refuses) instead of never
    /// exiting, which left only `--force` to stop the provider.
    internal func unloadAllModelsForShutdown() async {
        var abandoned = Set<String>()
        while let modelID = modelSlots.keys.sorted().first(where: { !abandoned.contains($0) }) {
            // Another task may own this unload; then only the slot's removal ends the wait.
            let ownUnload = !modelsUnloading.contains(modelID)
            let finished = ShutdownUnloadFlag(set: !ownUnload)
            if ownUnload { Task { _ = await self.unloadModel(modelID); finished.set() } }
            let deadline = ContinuousClock.now.advanced(by: Self.shutdownUnloadWait)
            while ContinuousClock.now < deadline {
                if finished.isSet && (modelSlots[modelID] == nil || ownUnload) { break }
                // Detached: a cancelled caller must not turn this into a spin.
                await Task.detached { try? await Task.sleep(nanoseconds: 50_000_000) }.value
            }
            if modelSlots[modelID] != nil { abandoned.insert(modelID) }
        }
        if !abandoned.isEmpty {
            logger.warning("Shutdown left \(abandoned.sorted().joined(separator: ", ")) resident: its retirement "
                + "did not finish; process exit releases the memory")
        }
    }
}

/// Set once a shutdown unload task returns; read by the bounded wait.
private final class ShutdownUnloadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(set: Bool) { value = set }
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
