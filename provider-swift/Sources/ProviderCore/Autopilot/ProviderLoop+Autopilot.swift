import Foundation

extension ProviderLoop {
    var modelAutopilotEnabled: Bool {
        autopilotControlIsValid && autopilotControl?.observeOnly == false
    }

    var autopilotControlIsValid: Bool {
        guard autopilotConsented, !autopilotSettings.paused, let control = autopilotControl else { return false }
        return control.enabled && control.revision == autopilotSettings.revision
            && control.expiresAtMs > Int64(Date().timeIntervalSince1970 * 1_000)
    }

    var autopilotPinnedModels: Set<String> {
        var pins = Set(autopilotSettings.pinnedModels)
        if let model = loopConfig.config.backend.model, !model.isEmpty { pins.insert(model) }
        return pins
    }

    func publishModelAutopilotSnapshot() {
        state.autopilotInventory = autopilotInventoryModels.values.sorted { $0.id < $1.id }
        loadAutopilotTimingHistory()
        let now = ContinuousClock.now
        autopilotResidentSince = autopilotResidentSince.filter { modelSlots[$0.key] != nil }
        autopilotLeaseUntil = autopilotLeaseUntil.filter { modelSlots[$0.key] != nil }
        for id in modelSlots.keys where autopilotResidentSince[id] == nil {
            autopilotResidentSince[id] = now
        }
        state.modelAutopilot = ModelAutopilotSnapshot(
            enabled: autopilotConsented,
            minDwellSeconds: autopilotSettings.effectiveMinDwellSeconds,
            pinnedModels: autopilotPinnedModels.sorted(), maxModelSlots: autopilotPlanningMaxModelSlots,
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
        state.modelAutopilot?.active = modelAutopilotEnabled
        state.modelAutopilot?.observeOnly = autopilotControlIsValid && autopilotControl?.observeOnly == true
        state.modelAutopilot?.paused = autopilotSettings.paused
        state.modelAutopilot?.sessionId = autopilotControl?.sessionId
        state.modelAutopilot?.revision = autopilotSettings.revision
        state.modelAutopilot?.selectedModels = autopilotSettings.selectedModels
        state.modelAutopilot?.minIdleSeconds = autopilotSettings.effectiveMinIdleSeconds
        state.modelAutopilot?.loadHistory = autopilotTimingHistory.loads
        state.modelAutopilot?.lastElapsedMs = autopilotLastElapsedMs
        state.modelAutopilot?.lastReleaseMs = autopilotLastReleaseMs
        state.modelAutopilot?.lastLoadMs = autopilotLastLoadMs
    }

    private static func autopilotSeconds(_ duration: Duration) -> Int {
        Int(max(0, min(31_536_000, duration.components.seconds)))
    }

    func checkAutopilotLoadOwnership(_ commandId: String?) throws {
        if let command = autopilotCommand {
            guard !isShuttingDown, !isDraining else {
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

    private static func autopilotMilliseconds(_ duration: Duration) -> Int64 {
        max(0, duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static var autopilotNowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    func handleModelAutopilot(_ command: ModelAutopilotCommand, send: SendHandle) {
        refreshAutopilotSettings()
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
            autopilotLastElapsedMs = 0; autopilotLastReleaseMs = 0; autopilotLastLoadMs = 0
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
        refreshAutopilotSettings()
        publishModelAutopilotSnapshot()
        guard let snapshot = state.modelAutopilot else { return "not_opted_in" }
        let busy = modelSwitchTask != nil || modelAdvertisementsInFlight > 0 || isShuttingDown || isDraining || isReconnectingAfterRetirement || hasInflightWork || isLoadingAny || isReslicing
            || !modelsLoading.isEmpty || !modelsUnloading.isEmpty || !retiringModels.isEmpty
            || startupPreloadTask != nil || !preloadTasks.isEmpty
            || !pendingAdvertise.isEmpty || mtpStagingReservations.hasRetainedTargets
            || !mtpUpgradeTransitions.isEmpty || !engineV2RecoveryInProgress.isEmpty
            || modelRevisionActivationID != nil || !revisionUpdatesInProgress.isEmpty
            || !nativeMiMoAllowsReclamation()
        if let error = ModelAutopilotPolicy.rejection(command: command, snapshot: snapshot,
            busy: busy, nowMs: Self.autopilotNowMs) { return error }
        if command.unloadModelIds.contains(where: {
            autopilotLeaseUntil[$0].map { ContinuousClock.now < $0 } ?? false
        }) { return "active_lease" }
        if let target = command.loadModelId {
            guard autopilotModelInfo(target) != nil,
                  ModelScanner.resolveLocalPath(modelID: target) != nil else { return "model_not_cached" }
            guard ModelRuntimeRequirements.isEligible(modelID: target,
                available: loopConfig.runtimeCapabilities) else { return "hardware_ineligible" }
        }
        return nil
    }

    private func runModelAutopilot(_ command: ModelAutopilotCommand, send: SendHandle) async {
        let operationStart = ContinuousClock.now
        autopilotLastReleaseMs = 0; autopilotLastLoadMs = 0
        do {
            await updateAggregateCapacity()
            // The loader handles optional cached MTP with target-only fallback;
            // preflight proves the independently serveable target fits first.
            let available = await availableMemoryGb()
            if let error = autopilotRejection(command) { throw AutopilotFailure(error) }
            // Validate TOTAL victim feasibility before removing even one model.
            // Use actual resident weights here, never the padded load estimate
            // as reclaim credit. The subsequent load re-samples OS memory.
            if let target = command.loadModelId, modelSlots[target] == nil {
                guard let info = autopilotModelInfo(target), info.estimatedMemoryGb.isFinite,
                      info.estimatedMemoryGb > 0 else { throw AutopilotFailure("unknown_model_size") }
                let reclaimable = command.unloadModelIds.reduce(0.0) {
                    $0 + Double(max(0, modelSlots[$1]?.sizing.weightsBytes ?? 0)) / 1_073_741_824
                }
                guard ModelLoadAdmission.evictionCanReach(availableGb: available,
                    reclaimableGb: reclaimable,
                    requiredGb: ModelLoadAdmission.requiredToLoadGb(
                        weightsGb: info.estimatedMemoryGb,
                        headroomGb: Double(UnifiedMemoryCap.loadHeadroomBytes(
                            activationReserveBytes: autopilotTargetReserve(target))) / 1_073_741_824))
                else { throw AutopilotFailure("insufficient_memory_without_other_victims") }
            }
            try await preflightAutopilotTarget(command)
            // expires_at_ms bounds acceptance / first mutation, not completion.
            // Never abandon ownership halfway through a multi-victim change.
            try checkAutopilotLoadOwnership(command.commandId)
            autopilotMutationStarted = true
            do {
                let releaseStart = ContinuousClock.now
                defer { autopilotLastReleaseMs = Self.autopilotMilliseconds(.now - releaseStart) }
                for victim in command.unloadModelIds {
                    try Task.checkCancellation()
                    try checkAutopilotLoadOwnership(command.commandId)
                    guard !isShuttingDown, !isDraining,
                          await unloadModel(victim, forEviction: true, autopilotCommandId: command.commandId) else {
                        throw AutopilotFailure("victim_became_busy")
                    }
                }
            }
            if let target = command.loadModelId {
                let loadStart = ContinuousClock.now
                defer { autopilotLastLoadMs = Self.autopilotMilliseconds(.now - loadStart) }
                try Task.checkCancellation()
                try await prepareAutopilotTarget(command)
                try await ensureModelLoaded(modelId: target, allowEviction: false,
                    autopilotCommandId: command.commandId)
                guard modelSlots[target] != nil, !modelsUnloading.contains(target),
                      advertisedModels[target] != nil else { throw AutopilotFailure("load_did_not_settle") }
                autopilotLeaseUntil[target] = .now.advanced(by: .seconds(command.leaseSeconds))
            }
            autopilotLastElapsedMs = Self.autopilotMilliseconds(.now - operationStart)
            finishModelAutopilot(command, status: .succeeded, send: send)
        } catch {
            autopilotLastElapsedMs = Self.autopilotMilliseconds(.now - operationStart)
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
            withdrawInactiveAutopilotModels()
            autopilotMutationStarted = false
            autopilotTask = nil
            state.refusingNewWork = isShuttingDown || isDraining || isReconnectingAfterRetirement
            if !autopilotManagesResidency { startIdleMonitor() }
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
