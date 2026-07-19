import Foundation

extension SpecDecArtifactFunnel {
    func notifyReady(
        modelId: String,
        artifact: SpecDecArtifact,
        generation: UInt64
    ) async {
        guard isCurrentCatalogGeneration(
            modelId: modelId, generation: generation)
        else { return }
        guard let handler = artifactReadyHandler, !isShutdown else { return }
        await handler(modelId, artifact, generation)
    }

    func scheduleReevaluation(for request: Request) {
        guard !isShutdown, reevaluations[request.modelId] == nil else { return }
        let attempt = reevaluationAttempts[request.modelId, default: 0]
        guard attempt < reevaluationDelays.count else {
            scheduleSteadyRefresh(for: request)
            return
        }
        reevaluationAttempts[request.modelId] = attempt + 1
        scheduleReevaluation(for: request, after: reevaluationDelays[attempt])
    }

    func scheduleSteadyRefresh(for request: Request) {
        guard !isShutdown, reevaluations[request.modelId] == nil,
            steadyRefreshInterval > .zero
        else { return }
        scheduleReevaluation(for: request, after: steadyRefreshInterval)
    }

    private func scheduleReevaluation(for request: Request, after delay: Duration) {
        let id = UUID()
        let task = Task { [weak self] in
            do {
                try await taskSleep(delay)
            } catch {
                await self?.finishReevaluation(
                    modelId: request.modelId, id: id)
                return
            }
            await self?.runReevaluation(request: request, id: id)
        }
        reevaluations[request.modelId] = Reevaluation(id: id, task: task)
    }

    private func runReevaluation(request: Request, id: UUID) async {
        guard !isShutdown, reevaluations[request.modelId]?.id == id,
            let catalog
        else { return }
        let generation = beginCatalogGeneration(modelId: request.modelId)

        let resolution: SpecDecResolution
        do {
            guard let model = try await catalog.freshModel(id: request.modelId) else {
                finishReevaluation(modelId: request.modelId, id: id)
                guard isCurrentCatalogGeneration(
                    modelId: request.modelId, generation: generation),
                    !isShutdown
                else { return }
                prefetchFailures[request.modelId] = .catalogModelMissing
                scheduleReevaluation(for: request)
                return
            }
            guard isCurrentCatalogGeneration(
                modelId: request.modelId, generation: generation),
                !isShutdown
            else {
                finishReevaluation(modelId: request.modelId, id: id)
                return
            }
            let cached = await resolver.resolve(model: model, allowDownload: false)
            if cached.reason == .artifactNotCached {
                resolution = await resolver.prefetch(model: model)
            } else {
                resolution = cached
            }
        } catch {
            finishReevaluation(modelId: request.modelId, id: id)
            guard isCurrentCatalogGeneration(
                modelId: request.modelId, generation: generation),
                !isShutdown
            else { return }
            prefetchFailures[request.modelId] = .catalogUnavailable
            scheduleReevaluation(for: request)
            return
        }
        finishReevaluation(modelId: request.modelId, id: id)
        guard !isShutdown,
            isCurrentCatalogGeneration(
                modelId: request.modelId, generation: generation)
        else { return }
        if let artifact = resolution.artifact {
            prefetchFailures.removeValue(forKey: request.modelId)
            reevaluationAttempts.removeValue(forKey: request.modelId)
            await notifyReady(
                modelId: request.modelId,
                artifact: artifact,
                generation: generation)
            scheduleSteadyRefresh(for: request)
        } else {
            if let reason = resolution.reason {
                prefetchFailures[request.modelId] = reason
            }
            scheduleReevaluation(for: request)
        }
    }

    private func finishReevaluation(modelId: String, id: UUID) {
        guard reevaluations[modelId]?.id == id else { return }
        reevaluations.removeValue(forKey: modelId)
    }
}
