import Foundation

extension ProviderLoop {
    func specDecArtifactBecameReady(
        modelId: String,
        artifact: SpecDecArtifact,
        generation: UInt64 = 0
    ) {
        let identity = Self.specDecIdentity(artifact)
        if generation > 0 {
            let latest = specDecPromotionGenerations[modelId] ?? 0
            guard generation >= latest else { return }
            specDecPromotionGenerations[modelId] = generation
        }
        guard !isShuttingDown,
            updatePhase == .idle,
            !modelsUnloading.contains(modelId),
            loopConfig.config.backend.mtp,
            SpecDecArtifactFunnel.killSwitchEnabled(
                environment: ProcessInfo.processInfo.environment),
            let slot = modelSlots[modelId],
            EngineV2SupportedModels.isGemma4Target(modelType: slot.modelType),
            !Self.sameSpecDecIdentity(slot.engineBundle.mtpArtifact, artifact)
        else { return }
        if specDecPromotionTasks[modelId] != nil {
            let pending = pendingSpecDecPromotions[modelId]
            if pending == nil || generation >= pending?.generation ?? 0 {
                pendingSpecDecPromotions[modelId] = .init(
                    artifact: artifact, generation: generation)
            }
            return
        }
        var attemptState = specDecPromotionAttempts[modelId]
        if attemptState?.identity != identity {
            attemptState = .init(
                identity: identity, attempts: 0)
        }
        guard var attemptState, attemptState.attempts < 3 else { return }
        attemptState.attempts += 1
        specDecPromotionAttempts[modelId] = attemptState
        let attempt = attemptState.attempts

        let id = UUID()
        specDecPromotionTaskIDs[modelId] = id
        specDecPromotionTasks[modelId] = Task { [weak self] in
            await self?.runSpecDecPromotion(
                modelId: modelId,
                artifact: artifact,
                generation: generation,
                attempt: attempt,
                taskID: id)
        }
    }

    func cancelSpecDecPromotions() {
        for task in specDecPromotionTasks.values { task.cancel() }
    }

    static func sameSpecDecIdentity(
        _ lhs: SpecDecArtifact?,
        _ rhs: SpecDecArtifact
    ) -> Bool {
        guard let lhs else { return false }
        return specDecIdentity(lhs) == specDecIdentity(rhs)
    }

    static func specDecIdentity(_ artifact: SpecDecArtifact) -> String {
        var components = [
            artifact.source.rawValue,
            artifact.revision,
            String(artifact.artifactBytes),
            artifact.manifestSHA256 ?? "local",
            artifact.localConfigSHA256 ?? "catalog",
        ]
        if let weights = artifact.localWeightSHA256 {
            components.append(contentsOf: weights.sorted { $0.key < $1.key }
                .flatMap { [$0.key, $0.value] })
        }
        return components.joined(separator: ":")
    }

    func promotionMayContinue(
        modelId: String,
        generation: UInt64,
        taskID: UUID
    ) -> Bool {
        !Task.isCancelled
            && !isShuttingDown
            && updatePhase == .idle
            && specDecPromotionTaskIDs[modelId] == taskID
            && (generation == 0
                || specDecPromotionGenerations[modelId] == generation)
            && modelSlots[modelId] != nil
            && !modelsUnloading.contains(modelId)
    }

    func finishSpecDecPromotionTask(modelId: String, taskID: UUID) {
        guard specDecPromotionTaskIDs[modelId] == taskID else { return }
        specDecPromotionTaskIDs.removeValue(forKey: modelId)
        specDecPromotionTasks.removeValue(forKey: modelId)
        if let pending = pendingSpecDecPromotions.removeValue(forKey: modelId) {
            specDecArtifactBecameReady(
                modelId: modelId,
                artifact: pending.artifact,
                generation: pending.generation)
        }
    }

    func restoreCancelledPromotionAttempt(
        modelId: String,
        artifact: SpecDecArtifact
    ) {
        let identity = Self.specDecIdentity(artifact)
        guard var state = specDecPromotionAttempts[modelId],
            state.identity == identity,
            state.attempts > 0
        else { return }
        state.attempts -= 1
        specDecPromotionAttempts[modelId] = state
    }

    func logSpecDecPromotionResult(
        modelId: String,
        artifact: SpecDecArtifact,
        result: String,
        reason: MTPFallbackReason?,
        attempt: Int,
        started: ContinuousClock.Instant
    ) {
        let elapsed = ContinuousClock.now - started
        let durationMs = Int64(max(
            0,
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15))
        logger.info(
            "mtp: promotion model=\(modelId) attempt=\(attempt) result=\(result) "
                + "reason=\(reason?.rawValue ?? "none") "
                + "source=\(artifact.source.rawValue) "
                + "revision=\(artifact.revision) "
                + "assistant_bytes=\(artifact.residentBytes) "
                + "duration_ms=\(durationMs)")
    }
}
