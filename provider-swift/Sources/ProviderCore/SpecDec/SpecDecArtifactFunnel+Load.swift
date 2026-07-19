import Foundation

extension SpecDecArtifactFunnel {
    func prepareForLoad(_ request: Request) async -> SpecDecPreparation {
        guard !isShutdown else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogUnavailable, configured: request.enabled))
        }
        let id = UUID()
        let task = Task { await self.performLoadPreparation(request) }
        loadPreparations[id] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        loadPreparations.removeValue(forKey: id)
        return result
    }

    /// Initial/cold-load path. Network and file I/O happen before the provider's
    /// model-load and re-slice gates are acquired. A verified warm artifact is
    /// returned without network access after the fresh catalog identity is read;
    /// an empty cache waits for one bounded verified download so one ordinary
    /// start can publish an MTP-active slot.
    private func performLoadPreparation(
        _ request: Request
    ) async -> SpecDecPreparation {
        guard !isShutdown else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogUnavailable, configured: request.enabled))
        }
        guard request.enabled else {
            return .init(artifact: nil, status: .disabled(.configDisabled, configured: false))
        }
        guard Self.killSwitchEnabled(environment: request.environment) else {
            return .init(artifact: nil, status: .disabled(.killSwitchDisabled, configured: true))
        }
        guard Self.isGemma4Target(modelType: request.modelType) else {
            return .init(artifact: nil, status: .disabled(.targetUnsupported, configured: true))
        }
        if let rawPath = request.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        {
            guard let artifact = SpecDecStore.inspectLocalArtifact(path: rawPath) else {
                return .init(
                    artifact: nil,
                    status: .disabled(.localArtifactInvalid, configured: true))
            }
            return .init(artifact: artifact, status: .candidate(artifact))
        }
        guard request.allowDownload, let catalog else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogDisabled, configured: true))
        }

        knownRequests[request.modelId] = request
        if reevaluations[request.modelId] != nil,
            let previousReason = prefetchFailures[request.modelId]
        {
            return .init(
                artifact: nil,
                status: .disabled(previousReason, configured: true))
        }
        let generation = beginCatalogGeneration(modelId: request.modelId)
        let model: CatalogModel
        do {
            guard let fresh = try await catalog.freshModel(id: request.modelId) else {
                guard isCurrentCatalogGeneration(
                    modelId: request.modelId, generation: generation)
                else {
                    return .init(
                        artifact: nil,
                        status: .disabled(.catalogUnavailable, configured: true))
                }
                prefetchFailures[request.modelId] = .catalogModelMissing
                scheduleReevaluation(for: request)
                return .init(
                    artifact: nil,
                    status: .disabled(.catalogModelMissing, configured: true))
            }
            model = fresh
        } catch {
            guard isCurrentCatalogGeneration(
                modelId: request.modelId, generation: generation)
            else {
                return .init(
                    artifact: nil,
                    status: .disabled(.catalogUnavailable, configured: true))
            }
            prefetchFailures[request.modelId] = .catalogUnavailable
            scheduleReevaluation(for: request)
            return .init(
                artifact: nil,
                status: .disabled(.catalogUnavailable, configured: true))
        }
        guard !isShutdown,
            isCurrentCatalogGeneration(
                modelId: request.modelId, generation: generation)
        else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogUnavailable, configured: true))
        }

        let cached = await resolver.resolve(model: model, allowDownload: false)
        let resolution: SpecDecResolution
        if cached.reason == .artifactNotCached {
            resolution = await resolver.prefetch(model: model)
        } else {
            resolution = cached
        }
        guard !isShutdown,
            isCurrentCatalogGeneration(
                modelId: request.modelId, generation: generation)
        else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogUnavailable, configured: true))
        }
        guard let artifact = resolution.artifact else {
            prefetchFailures[request.modelId] =
                resolution.reason ?? .publicationFailed
            scheduleReevaluation(for: request)
            return .init(
                artifact: nil,
                status: .disabled(
                    resolution.reason ?? .publicationFailed, configured: true))
        }
        prefetchFailures.removeValue(forKey: request.modelId)
        reevaluationAttempts.removeValue(forKey: request.modelId)
        await notifyReady(
            modelId: request.modelId,
            artifact: artifact,
            generation: generation)
        scheduleSteadyRefresh(for: request)
        return .init(artifact: artifact, status: .candidate(artifact))
    }
}
