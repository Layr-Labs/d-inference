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
            log: { line in standaloneLogger.info("\(line)") },
            currentRequiredGb: { id in await owner.startupPreloadRequiredGb(for: id) },
            canLoadMore: { await owner.startupPreloadHasFreeSlot() }
        ))
        return await preloader.run(candidates: plan)
    }

    private func startupPreloadHasFreeSlot() -> Bool {
        slots.count < config.maxCachedModels
    }
}
