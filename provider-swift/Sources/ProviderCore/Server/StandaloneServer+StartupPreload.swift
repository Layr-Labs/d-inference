import Foundation

extension StandaloneServer {
    /// Preload the selected local models before the HTTP listener starts.
    /// An explicit list keeps operator order; otherwise use the selected
    /// catalog order. The existing load gate remains authoritative, and
    /// preloading never evicts a model it already warmed.
    func startupPreloadPlan(configuredModelIDs: [String]) -> [StartupPreloader.Candidate] {
        let ids = configuredModelIDs.isEmpty ? models.map(\.id) : configuredModelIDs
        var seen = Set<String>()
        var plan: [StartupPreloader.Candidate] = []
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            guard let requiredGb = startupPreloadRequiredGb(for: id) else {
                standaloneLogger.warning("Startup preload: '\(id)' is not in the selected local model set — skipping")
                continue
            }
            plan.append(.init(modelId: id, requiredGb: requiredGb))
        }
        return plan
    }

    private func startupPreloadRequiredGb(for modelID: String) -> Double? {
        guard let info = models.first(where: { $0.id == modelID }) else { return nil }
        let headroomGb = Double(UnifiedMemoryCap.loadHeadroomBytes(
            activationReserveBytes: resolvedActivationReserveBytes))
            / (1024.0 * 1024.0 * 1024.0)
        return ModelLoadAdmission.requiredToLoadGb(
            weightsGb: info.estimatedMemoryGb, headroomGb: headroomGb)
    }

    /// A failed or oversized model remains advertised for a later request;
    /// the preloader records the skip and continues to the next candidate.
    public func preloadSelectedModels(
        configuredModelIDs: [String] = []
    ) async -> StartupPreloader.Summary {
        let plan = startupPreloadPlan(configuredModelIDs: configuredModelIDs)
        let owner = self
        let preloader = StartupPreloader(deps: .init(
            freeMemoryGb: { await owner.availableMemoryGb() },
            load: { id in try await owner.ensureModelLoaded(id, allowEviction: false) },
            shapeWarmup: { id in await owner.startupShapeWarmup(id) },
            log: { line in standaloneLogger.info("\(line)") },
            currentRequiredGb: { id in await owner.startupPreloadRequiredGb(for: id) },
            canLoadMore: { await owner.startupPreloadHasFreeSlot() }
        ))
        return await preloader.run(candidates: plan)
    }

    /// Before the listener opens nothing preempts the excluded shape warmup,
    /// so the first local prompt finds its kernels compiled.
    private func startupShapeWarmup(_ modelID: String) async {
        guard let bridge = slots[modelID]?.bridge else { return }
        await bridge.runShapeWarmupBeforeServing()
    }

    /// Excluded first-use shapes for each resident engine, one Mac-wide
    /// session at a time; any request preempts it. The sweep tick retries
    /// sessions a request, device work or posture deferred, and warms a lazy
    /// load or an MTP replacement engine once the server is idle.
    func scheduleShapeWarmups() async {
        for key in slots.keys.sorted() {
            guard let bridge = slots[key]?.bridge else { continue }
            if await bridge.startShapeWarmupIfNeeded(onRetired: { [weak self] in
                await self?.scheduleShapeWarmups()
            }) { return }
        }
    }

    /// Sweep-tick entry: a draining or stopping server starts no session.
    func retryShapeWarmups() async {
        guard lifecycleState == .running, !lifecycleDraining else { return }
        await scheduleShapeWarmups()
    }

    private func startupPreloadHasFreeSlot() -> Bool {
        slots.count < config.maxCachedModels
    }
}
