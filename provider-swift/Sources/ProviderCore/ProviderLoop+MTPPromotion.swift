import Foundation
import MLX

private struct SpecDecPromotionFailure: Error {
    let reason: MTPFallbackReason
}

extension ProviderLoop {
    static let specDecPromotionIdleTimeout: Duration = .seconds(300)
    static let specDecPromotionPollInterval: Duration = .milliseconds(250)

    func runSpecDecPromotion(
        modelId: String,
        artifact: SpecDecArtifact,
        generation: UInt64,
        attempt: Int,
        taskID: UUID
    ) async {
        let started = ContinuousClock.now
        logger.info(
            "mtp: promotion model=\(modelId) attempt=\(attempt) result=waiting_for_idle "
                + "source=\(artifact.source.rawValue) revision=\(artifact.revision) "
                + "assistant_bytes=\(artifact.residentBytes)")

        while true {
            guard promotionMayContinue(
                modelId: modelId, generation: generation, taskID: taskID)
            else {
                restoreCancelledPromotionAttempt(
                    modelId: modelId, artifact: artifact)
                finishSpecDecPromotionTask(modelId: modelId, taskID: taskID)
                return
            }
            let observedBridge = modelSlots[modelId]?.engineV2
            let engineBusy: Bool
            if let observedBridge {
                engineBusy = !(await observedBridge.isQuiescentForReplacement())
            } else {
                engineBusy = true
            }
            // Re-read actor-owned admission state AFTER the bridge await. A
            // request may have entered while the actor was reentrant.
            let remoteBusy = requestToModel.values.contains(modelId)
            let localBusy = hasLocalReservation(modelId)
            if !remoteBusy, !localBusy, !engineBusy, !isLoadingAny,
                modelSlots[modelId]?.engineV2 === observedBridge
            {
                break
            }
            if ContinuousClock.now - started >= Self.specDecPromotionIdleTimeout {
                logSpecDecPromotionResult(
                    modelId: modelId, artifact: artifact,
                    result: "fallback",
                    reason: .promotionBusyTimeout,
                    attempt: attempt,
                    started: started)
                finishSpecDecPromotionTask(modelId: modelId, taskID: taskID)
                return
            }
            do {
                try await taskSleep(Self.specDecPromotionPollInterval)
            } catch {
                restoreCancelledPromotionAttempt(
                    modelId: modelId, artifact: artifact)
                finishSpecDecPromotionTask(modelId: modelId, taskID: taskID)
                return
            }
        }

        guard promotionMayContinue(
            modelId: modelId, generation: generation, taskID: taskID),
            let originalSlot = modelSlots[modelId]
        else {
            restoreCancelledPromotionAttempt(
                modelId: modelId, artifact: artifact)
            finishSpecDecPromotionTask(modelId: modelId, taskID: taskID)
            return
        }
        let originalBridge = originalSlot.engineV2
        modelsPromotingSpecDec.insert(modelId)
        isLoadingAny = true
        await originalBridge.beginRecoveryReload()
        let reservationID = "mtp-promotion:\(modelId)"
        var gateHeld = false
        var replacementBundle: ProviderEngineBundle?
        var previousGrants: [ExistingSlotGrant] = []
        var preparedAssistant: ProviderMTPAssistantHandle?
        var replacementRegistered = false

        do {
            guard await kvBudget.reserveBytes(
                requestID: reservationID,
                bytes: artifact.residentBytes)
            else {
                throw SpecDecPromotionFailure(reason: .assistantMemoryUnavailable)
            }

            let slotLogger = logger
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: modelId,
                isVLM: originalSlot.isVLM,
                modelDirectory: ModelScanner.resolveLocalPath(modelID: modelId),
                container: originalSlot.container,
                specDecPreparation: .init(
                    artifact: artifact, status: .candidate(artifact)),
                assistantLoader: engineV2SlotHooks?.assistantLoader
                    ?? Gemma4ProviderMTPAssistantLoader(),
                emitTelemetry: engineV2SlotHooks?.emitTelemetry,
                logInfo: { slotLogger.info($0) },
                logWarning: { slotLogger.warning($0) })
            guard let assistant = prepared.assistant, prepared.mtpStatus.active else {
                throw SpecDecPromotionFailure(
                    reason: prepared.mtpStatus.reason ?? .assistantLoadFailed)
            }
            preparedAssistant = assistant

            guard promotionMayContinue(
                modelId: modelId, generation: generation, taskID: taskID),
                modelSlots[modelId]?.engineV2 === originalBridge
            else { throw CancellationError() }

            await acquireResliceGate()
            gateHeld = true
            guard promotionMayContinue(
                modelId: modelId, generation: generation, taskID: taskID),
                modelSlots[modelId]?.engineV2 === originalBridge
            else { throw CancellationError() }

            let sizing = originalSlot.sizing.replacingAuxiliaryWeightBytes(
                prepared.assistantBytes)
            previousGrants = await existingSlotGrants(excludingModelId: "")
            let budget = fleetKVBudgetBytes(
                extraWeightBytes: sizing.weightsBytes,
                replacingModelId: modelId)
            let targets = EngineV2KVSizing.resliceGrants(
                existing: previousGrants.map(\.slot),
                newcomer: nil,
                fleetKVBudgetBytes: budget)
            guard EngineV2KVSizing.resliceMeetsServiceabilityFloor(
                targets, fixedCarveBytes: [:])
            else {
                throw SpecDecPromotionFailure(reason: .assistantResliceFloor)
            }
            for entry in previousGrants {
                if let target = targets[entry.slot.modelId],
                    target < entry.previousGrant
                {
                    await entry.bridge.updateKVBytesCapacity(target)
                }
            }

            let replacement = try await makeEngineV2BundleForSlot(
                modelId: modelId,
                modelType: originalSlot.modelType,
                isVLM: originalSlot.isVLM,
                modelDirectory: ModelScanner.resolveLocalPath(modelID: modelId),
                container: originalSlot.container,
                tokenizer: originalSlot.tokenizer,
                sizing: sizing,
                kvBytesCapacity: targets[modelId] ?? 0,
                specDecPreparation: .init(
                    artifact: artifact, status: .candidate(artifact)),
                preparedModel: prepared,
                cacheEligibleWeightHash: originalSlot.cacheEligibleWeightHash,
                registerRuntime: false,
                logConstruction: false)
            replacementBundle = replacement

            MLX.Memory.clearCache()
            let postBuildServeable = KVHeadroomProbe.postBuildServeable(
                kvBackendKind: replacement.bridge.kvBackendKind,
                pagedPoolBytes: await replacement.bridge.kvBackendPoolBytes())
            let runtimeActive = engineV2SlotHooks != nil
                ? replacement.mtpStatus.active
                : await replacement.bridge.mtpStatusSnapshot().active
            guard runtimeActive else {
                throw SpecDecPromotionFailure(reason: .engineInactive)
            }
            guard postBuildServeable else {
                throw SpecDecPromotionFailure(reason: .assistantPostBuildHeadroom)
            }
            await replacement.bridge.beginRecoveryReload()
            guard promotionMayContinue(
                modelId: modelId, generation: generation, taskID: taskID),
                modelSlots[modelId]?.engineV2 === originalBridge
            else { throw CancellationError() }

            await engineV2Runtime.register(
                modelId: modelId, bridge: replacement.bridge)
            replacementRegistered = true
            guard promotionMayContinue(
                modelId: modelId, generation: generation, taskID: taskID),
                modelSlots[modelId]?.engineV2 === originalBridge
            else { throw CancellationError() }

            modelSlots[modelId] = ModelSlot(
                engineBundle: replacement,
                container: originalSlot.container,
                tokenizer: originalSlot.tokenizer,
                sizing: sizing,
                cacheEligibleWeightHash: originalSlot.cacheEligibleWeightHash,
                isVLM: originalSlot.isVLM,
                modelType: originalSlot.modelType,
                lastInferenceAt: originalSlot.lastInferenceAt)
            replacementBundle = nil
            preparedAssistant = nil
            await originalBridge.shutdown()
            originalSlot.engineBundle.releaseAssistant()
            MLX.Memory.clearCache()
            await kvBudget.release(requestID: reservationID)
            for entry in previousGrants {
                if let target = targets[entry.slot.modelId],
                    target > entry.previousGrant,
                    entry.slot.modelId != modelId
                {
                    await entry.bridge.updateKVBytesCapacity(target)
                }
            }
            await replacement.bridge.endRecoveryReload()
            releaseResliceGate()
            gateHeld = false
            syncWarmModelState()
            await updateAggregateCapacity()
            logSpecDecPromotionResult(
                modelId: modelId, artifact: artifact,
                result: "active", reason: nil, attempt: attempt,
                started: started)
            specDecPromotionAttempts.removeValue(forKey: modelId)
        } catch {
            if replacementRegistered {
                if modelSlots[modelId]?.engineV2 === originalBridge,
                    !modelsUnloading.contains(modelId)
                {
                    await engineV2Runtime.register(
                        modelId: modelId, bridge: originalBridge)
                } else {
                    await engineV2Runtime.unregister(modelId: modelId)
                }
            }
            if let replacementBundle {
                await replacementBundle.bridge.shutdown()
                replacementBundle.releaseAssistant()
            } else {
                preparedAssistant?.release()
            }
            MLX.Memory.clearCache()
            for entry in previousGrants {
                await entry.bridge.updateKVBytesCapacity(entry.previousGrant)
            }
            await kvBudget.release(requestID: reservationID)
            if modelSlots[modelId]?.engineV2 === originalBridge {
                await originalBridge.endRecoveryReload()
            }
            if gateHeld {
                releaseResliceGate()
            }
            let reason: MTPFallbackReason
            if let failure = error as? SpecDecPromotionFailure {
                reason = failure.reason
            } else if error is CancellationError {
                reason = .downloadCancelled
            } else {
                reason = .promotionConstructionFailed
            }
            if !(error is CancellationError) {
                logSpecDecPromotionResult(
                    modelId: modelId, artifact: artifact,
                    result: "fallback", reason: reason, attempt: attempt,
                    started: started)
            } else {
                restoreCancelledPromotionAttempt(
                    modelId: modelId, artifact: artifact)
            }
        }

        modelsPromotingSpecDec.remove(modelId)
        isLoadingAny = false
        releaseLoadGateWaiters()
        finishSpecDecPromotionTask(modelId: modelId, taskID: taskID)
    }

}
