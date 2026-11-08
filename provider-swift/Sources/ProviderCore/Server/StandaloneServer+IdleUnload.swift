import Foundation

/// StandaloneServer -- the memory setting for Only me: models idle past `[backend] idle_timeout_mins` are unloaded,
/// as the network provider's idle monitor does (`ProviderLoop+IdleTimeout`); 0 keeps them loaded. The unload is the
/// eviction a load that needs memory runs, under the same load gate, so a model with a request in flight, a
/// reservation or a load never goes; the next request loads it again.
extension StandaloneServer {
    /// Checks once a minute; does nothing for 0 minutes, or once started.
    public func startIdleUnload(minutes: UInt64, every interval: Duration = .seconds(60)) {
        guard minutes > 0, idleUnloadTask == nil else { return }
        let idleFor = Duration.seconds(Int64(clamping: minutes) * 60)
        idleUnloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.unloadIdleModels(idleFor: idleFor)
            }
        }
    }

    /// One pass, while no load holds the gate: every model last used `idleFor` ago or earlier is unloaded. Returns how
    /// many.
    @discardableResult
    func unloadIdleModels(idleFor: Duration, now: ContinuousClock.Instant = .now) async -> Int {
        guard lifecycleState != .stopping, !lifecycleDraining, !isLoadingAny, modelsLoading.isEmpty else { return 0 }
        isLoadingAny = true
        defer {
            isLoadingAny = false
            releaseLoadGateWaiters()
        }
        var unloaded = 0
        while await evictLRUIdleSlot(usedBefore: now - idleFor) {
            unloaded += 1
        }
        if unloaded > 0 {
            standaloneLogger.info("Idle unload: \(unloaded) model(s) unused for \(idleFor.components.seconds / 60) min unloaded")
        }
        return unloaded
    }
}
