import Foundation

extension ProviderLoop {
    internal enum StartupPreloadGateOutcome: Sendable, Equatable {
        case disabled
        case nothingToPreload
        case warm
        case timedOut
    }

    internal static let preloadLivenessRefreshInterval:
        Duration = .seconds(30)

    internal func startPreloadLivenessRefresh() -> Task<Void, Never> {
        let loop = self
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await taskSleep(Self.preloadLivenessRefreshInterval)
                } catch {
                    return
                }
                await loop.writeDaemonState()
            }
        }
    }

    internal func loadedModelsFileURL() -> URL {
        loadedModelsFileOverride ?? LoadedModelsStore.path()
    }

    internal func persistLoadedModelSet() {
        // Loaded-model ownership lives in the worker. The supervisor persists
        // only worker-authoritative capacity snapshots.
    }

    internal func startupPreloadPlan()
        -> [StartupPreloader.Candidate]
    {
        let backend = loopConfig.config.backend
        let configured = backend.preloadModels.isEmpty
            ? LoadedModelsStore.read(from: loadedModelsFileURL())
            : backend.preloadModels
        let cap = max(1, Int(backend.maxModelSlots))
        var seen = Set<String>()
        return configured.compactMap { identifier in
            guard seen.insert(identifier).inserted,
                  advertisedModels[identifier] != nil
            else { return nil }
            return StartupPreloader.Candidate(
                modelId: identifier, requiredGb: 0)
        }.prefix(cap).map { $0 }
    }

    @discardableResult
    internal func runStartupPreloadGate()
        async -> StartupPreloadGateOutcome
    {
        let backend = loopConfig.config.backend
        guard backend.startupPreload else { return .disabled }
        let plan = startupPreloadPlan()
        guard !plan.isEmpty else { return .nothingToPreload }
        let client = inferenceWorkerClient
        let loadOverride = startupPreloadLoadOverride
        let loadTask = Task {
            for candidate in plan {
                if Task.isCancelled { return }
                do {
                    if let loadOverride {
                        try await loadOverride(candidate.modelId)
                    } else {
                        try await client.preloadModel(
                            identifier: candidate.modelId)
                    }
                } catch {
                    return
                }
            }
        }
        startupPreloadTask = loadTask
        let timeout = Duration.seconds(
            Int64(max(1, backend.startupPreloadTimeoutSecs)))
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await loadTask.value
                return true
            }
            group.addTask {
                do {
                    try await taskSleep(timeout)
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        return completed ? .warm : .timedOut
    }
}
