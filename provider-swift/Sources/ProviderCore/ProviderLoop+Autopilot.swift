import Foundation

extension ProviderLoop {
    var modelAutopilotEnabled: Bool {
        loopConfig.config.backend.modelAutopilot.enabled && !loopConfig.config.coordinator.privateOnly
    }

    var autopilotPinnedModels: Set<String> {
        var pins = Set(loopConfig.config.backend.modelAutopilot.pinnedModels)
        if let model = loopConfig.config.backend.model, !model.isEmpty { pins.insert(model) }
        return pins
    }

    func publishModelAutopilotSnapshot() {
        let now = ContinuousClock.now
        autopilotResidentSince = autopilotResidentSince.filter { modelSlots[$0.key] != nil }
        autopilotLeaseUntil = autopilotLeaseUntil.filter { modelSlots[$0.key] != nil }
        for id in modelSlots.keys where autopilotResidentSince[id] == nil {
            autopilotResidentSince[id] = now
        }
        state.modelAutopilot = ModelAutopilotSnapshot(
            enabled: modelAutopilotEnabled,
            minDwellSeconds: loopConfig.config.backend.modelAutopilot.effectiveMinDwellSeconds,
            pinnedModels: autopilotPinnedModels.sorted(), maxModelSlots: maxModelSlots,
            residentModels: modelSlots.keys.sorted().map { id in
                ModelAutopilotResident(modelId: id,
                    residentSeconds: Self.autopilotSeconds(now - (autopilotResidentSince[id] ?? now)),
                    idleSeconds: Self.autopilotSeconds(now - (modelSlots[id]?.lastInferenceAt ?? now)),
                    weightsGb: advertisedModels[id]?.estimatedMemoryGb
                        ?? Double(modelSlots[id]?.sizing.weightsBytes ?? 0) / 1_073_741_824,
                    residentGb: modelSlots[id].map { Double(max(0, $0.sizing.weightsBytes)) / 1_073_741_824 })
            },
            freeForLoadNoEvictGb: autopilotCommand == nil ? autopilotFreeNoEvictGb : nil,
            activeCommandId: autopilotCommand?.commandId,
            lastCommandId: autopilotLastCommandId, lastCommandStatus: autopilotLastCommandStatus)
    }

    private static func autopilotSeconds(_ duration: Duration) -> Int {
        Int(max(0, min(31_536_000, duration.components.seconds)))
    }

    func checkAutopilotLoadOwnership(_ commandId: String?) throws {
        if let command = autopilotCommand {
            guard !isShuttingDown, !isDrainingForUpdate else {
                throw InferenceError.modelLoadFailed("provider_draining")
            }
            guard commandId == command.commandId else {
                throw InferenceError.modelLoadFailed("model autopilot placement in progress")
            }
            guard autopilotMutationStarted || Self.autopilotNowMs < command.expiresAtMs else {
                throw InferenceError.modelLoadFailed("expired_command")
            }
        } else if commandId != nil {
            throw InferenceError.modelLoadFailed("model autopilot command ownership lost")
        }
    }

    private static var autopilotNowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    func handleModelAutopilot(_ command: ModelAutopilotCommand, send: SendHandle) {
        publishModelAutopilotSnapshot()
        if let previous = autopilotHistory[command.commandId] {
            let matches = previous.0 == command
            emitModelAutopilotStatus(command, status: matches ? previous.1 : .failed,
                error: matches ? previous.2 : "command_id_reused", send: send)
            return
        }
        if let active = autopilotCommand {
            emitModelAutopilotStatus(command,
                status: active == command ? .started : .failed,
                error: active == command ? nil : "provider_busy", send: send)
            return
        }
        if let rejection = autopilotRejection(command) {
            finishModelAutopilot(command, status: .failed, error: rejection, send: send)
            return
        }
        // No suspension between the all-idle validation and this reservation.
        // Admission, load, idle and MTP paths all consult this same owner.
        logger.info("Model autopilot starting command=\(command.commandId) load=\(command.loadModelId ?? "none") victims=\(command.unloadModelIds.count)")
        autopilotGeneration &+= 1
        autopilotCommand = command
        autopilotMutationStarted = false
        state.refusingNewWork = true
        publishModelAutopilotSnapshot()
        emitModelAutopilotStatus(command, status: .started, send: send)
        autopilotTask = Task { [weak self] in
            guard let self else { return }
            await self.runModelAutopilot(command, send: send)
        }
    }

    private func autopilotRejection(_ command: ModelAutopilotCommand) -> String? {
        publishModelAutopilotSnapshot()
        guard let snapshot = state.modelAutopilot else { return "not_opted_in" }
        let busy = isShuttingDown || isDrainingForUpdate || isReconnectingAfterRetirement || hasInflightWork || isLoadingAny || isReslicing
            || !modelsLoading.isEmpty || !modelsUnloading.isEmpty || !retiringModels.isEmpty
            || startupPreloadTask != nil || !preloadTasks.isEmpty
            || !pendingAdvertise.isEmpty || mtpStagingReservations.hasRetainedTargets
            || !mtpUpgradeTransitions.isEmpty || !engineV2RecoveryInProgress.isEmpty
        if let error = ModelAutopilotPolicy.rejection(command: command, snapshot: snapshot,
            busy: busy, nowMs: Self.autopilotNowMs) { return error }
        if command.unloadModelIds.contains(where: {
            autopilotLeaseUntil[$0].map { ContinuousClock.now < $0 } ?? false
        }) { return "active_lease" }
        if let target = command.loadModelId {
            guard advertisedModels[target] != nil,
                  ModelScanner.resolveLocalPath(modelID: target) != nil else { return "model_not_cached" }
            guard ModelRuntimeRequirements.isEligible(modelID: target,
                available: loopConfig.runtimeCapabilities) else { return "hardware_ineligible" }
        }
        return nil
    }

    func validateAutopilotAssistant(_ preparation: SpecDecPreparation) throws {
        guard preparation.status.configured, preparation.artifact == nil else { return }
        switch preparation.status.reason {
        case .configDisabled, .killSwitchDisabled, .targetUnsupported: return
        default: throw AutopilotFailure("assistant_not_cached_or_invalid")
        }
    }

    private func runModelAutopilot(_ command: ModelAutopilotCommand, send: SendHandle) async {
        do {
            await updateAggregateCapacity()
            // Resolve only VERIFIED LOCAL assistant artifacts before victims.
            // Optional MTP must not add unplanned downloads or memory costs.
            var assistantBytes: UInt64 = 0
            if let target = command.loadModelId, modelSlots[target] == nil,
               let info = advertisedModels[target], let path = ModelScanner.resolveLocalPath(modelID: target) {
                let preparation = await specDecPreparation(modelId: target, modelInfo: info,
                    modelDirectory: path, allowDownload: false)
                try validateAutopilotAssistant(preparation)
                assistantBytes = preparation.artifact?.additionalWeightBytes ?? 0
            }
            let available = await availableMemoryGb()
            if let error = autopilotRejection(command) { throw AutopilotFailure(error) }
            // Validate TOTAL victim feasibility before removing even one model.
            // Use actual resident weights here, never the padded load estimate
            // as reclaim credit. The subsequent load re-samples OS memory.
            if let target = command.loadModelId, modelSlots[target] == nil {
                guard let info = advertisedModels[target], info.estimatedMemoryGb.isFinite,
                      info.estimatedMemoryGb > 0 else { throw AutopilotFailure("unknown_model_size") }
                let reclaimable = command.unloadModelIds.reduce(0.0) {
                    $0 + Double(max(0, modelSlots[$1]?.sizing.weightsBytes ?? 0)) / 1_073_741_824
                }
                guard ModelLoadAdmission.evictionCanReach(availableGb: available,
                    reclaimableGb: reclaimable,
                    requiredGb: ModelLoadAdmission.requiredToLoadGb(
                        weightsGb: info.estimatedMemoryGb + Double(assistantBytes) / 1_073_741_824,
                        headroomGb: loadHeadroomGb))
                else { throw AutopilotFailure("insufficient_memory_without_other_victims") }
            }
            // expires_at_ms bounds acceptance / first mutation, not completion.
            // Never abandon ownership halfway through a multi-victim change.
            try checkAutopilotLoadOwnership(command.commandId)
            autopilotMutationStarted = true
            for victim in command.unloadModelIds {
                try Task.checkCancellation()
                try checkAutopilotLoadOwnership(command.commandId)
                guard !isShuttingDown, !isDrainingForUpdate,
                      await unloadModel(victim, forEviction: true, autopilotCommandId: command.commandId) else {
                    throw AutopilotFailure("victim_became_busy")
                }
            }
            if let target = command.loadModelId {
                try Task.checkCancellation()
                try await ensureModelLoaded(modelId: target, allowEviction: false,
                    autopilotCommandId: command.commandId)
                guard modelSlots[target] != nil, !modelsUnloading.contains(target),
                      advertisedModels[target] != nil else { throw AutopilotFailure("load_did_not_settle") }
                autopilotLeaseUntil[target] = .now.advanced(by: .seconds(command.leaseSeconds))
            }
            finishModelAutopilot(command, status: .succeeded, send: send)
        } catch {
            finishModelAutopilot(command, status: .failed, error: error.localizedDescription, send: send)
        }
        // Terminal snapshot is rebuilt WITH backend capacity before the forced
        // heartbeat; coordinator must reconcile the pair, not trust status alone.
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
        await resumeAutopilotDeferredModelChanges(send: send)
        await retryReserveDeferredPrefetches()
    }

    private func finishModelAutopilot(_ command: ModelAutopilotCommand,
        status: ModelAutopilotStatus.State, error: String? = nil, send: SendHandle) {
        if autopilotCommand?.commandId == command.commandId {
            autopilotCommand = nil
            autopilotMutationStarted = false
            autopilotTask = nil
            state.refusingNewWork = isShuttingDown || isDrainingForUpdate || isReconnectingAfterRetirement
        }
        autopilotHistory[command.commandId] = (command, status, error)
        autopilotHistoryOrder.append(command.commandId)
        if autopilotHistoryOrder.count > 64 {
            autopilotHistory.removeValue(forKey: autopilotHistoryOrder.removeFirst())
        }
        logger.info("Model autopilot command=\(command.commandId) status=\(status.rawValue) error=\(error ?? "none")")
        autopilotGeneration &+= 1
        autopilotLastCommandId = command.commandId
        autopilotLastCommandStatus = status
        publishModelAutopilotSnapshot()
        emitModelAutopilotStatus(command, status: status, error: error, send: send)
    }

    private func emitModelAutopilotStatus(_ command: ModelAutopilotCommand,
        status: ModelAutopilotStatus.State, error: String? = nil, send: SendHandle) {
        guard let snapshot = state.modelAutopilot else { return }
        send.send(.modelAutopilotStatus(ModelAutopilotStatus(commandId: command.commandId,
            status: status, error: error, modelAutopilot: snapshot)))
    }
}

private struct AutopilotFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
