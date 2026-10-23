import Foundation

extension ProviderLoop {
    var modelAutopilotEnabled: Bool {
        autopilotControlIsValid && autopilotControl?.observeOnly == false
    }

    var autopilotControlIsValid: Bool {
        guard autopilotConsented, !autopilotNeedsInventoryRefresh, !autopilotSettings.paused, let control = autopilotControl else { return false }
        return control.enabled && control.revision == autopilotSettings.revision
            && control.expiresAtMs > Int64(Date().timeIntervalSince1970 * 1_000)
    }

    var autopilotPinnedModels: Set<String> {
        var pins = Set(autopilotSettings.pinnedModels)
        if let model = loopConfig.config.backend.model, !model.isEmpty { pins.insert(model) }
        return pins
    }

    func publishModelAutopilotSnapshot() {
        reconcileAutopilotPlacements()
        state.autopilotInventory = autopilotInventoryModels.values.sorted { $0.id < $1.id }
        loadAutopilotTimingHistory()
        let now = ContinuousClock.now
        autopilotResidentSince = autopilotResidentSince.filter { modelSlots[$0.key] != nil }
        autopilotLeaseUntil = autopilotLeaseUntil.filter { modelSlots[$0.key] != nil }
        for id in modelSlots.keys where autopilotResidentSince[id] == nil {
            autopilotResidentSince[id] = now
        }
        var snapshot = ModelAutopilotSnapshot(
            enabled: autopilotConsented && !autopilotNeedsInventoryRefresh,
            consentEnabled: autopilotSettings.hasConsent,
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
        snapshot.active = modelAutopilotEnabled
        snapshot.observeOnly = autopilotControlIsValid && autopilotControl?.observeOnly == true
        snapshot.paused = autopilotSettings.paused
        snapshot.sessionId = autopilotControl?.sessionId
        snapshot.revision = autopilotSettings.revision
        snapshot.selectedModels = autopilotSettings.selectedModels
        snapshot.minIdleSeconds = autopilotSettings.effectiveMinIdleSeconds
        snapshot.loadHistory = autopilotTimingHistory.loads
        snapshot.lastElapsedMs = autopilotLastElapsedMs
        snapshot.lastReleaseMs = autopilotLastReleaseMs
        snapshot.lastLoadMs = autopilotLastLoadMs
        if autopilotConsented {
            attachAutopilotProviderReport(to: &snapshot, now: now)
        } else {
            // Busy reasons go unobserved without consent; restart their
            // continuity so `busy_since_ms` never spans that gap.
            autopilotBusyClock = ContinuityClock()
        }
        state.modelAutopilot = snapshot
    }

    /// Fields beyond protocol 3, attached only with saved consent so that a
    /// provider without it publishes an unchanged protocol-3 snapshot.
    private func attachAutopilotProviderReport(to snapshot: inout ModelAutopilotSnapshot,
                                               now: ContinuousClock.Instant) {
        let reasons = reportedAutopilotBusyReasons()
        autopilotBusyClock.observe(reasons, at: Self.autopilotNowMs)
        let placements = autopilotPlacementReport(now: now)
        snapshot.capabilities = ModelAutopilotCapability.allCases.map(\.rawValue)
        snapshot.adoptedModels = placements.adopted
        snapshot.heldModels = placements.held
        snapshot.busyReasons = reasons.isEmpty ? nil : reasons.map(\.rawValue)
        snapshot.busyReason = reasons.first?.rawValue
        snapshot.busySinceMs = reasons.first.flatMap { autopilotBusyClock.since($0) }
        snapshot.transitionStalls = transitionWatchdog.report
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

    static var autopilotNowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    func handleModelAutopilot(_ command: ModelAutopilotCommand, send: SendHandle) {
        refreshAutopilotSettings()
        publishModelAutopilotSnapshot()
        if let previous = autopilotHistory[command.commandId] {
            if previous.command == command {
                emitModelAutopilotStatus(command, status: previous.status, error: previous.error,
                    detail: previous.detail, send: send)
            } else {
                emitModelAutopilotStatus(command, status: .failed, error: "command_id_reused", send: send)
            }
            return
        }
        if let active = autopilotCommand {
            if active == command {
                emitModelAutopilotStatus(command, status: .started, send: send)
            } else {
                emitModelAutopilotStatus(command, status: .failed, error: "provider_busy",
                    detail: ModelAutopilotBusyReason.autopilotOperation.rawValue, send: send)
            }
            return
        }
        if let rejection = autopilotRejection(command) {
            autopilotLastElapsedMs = 0; autopilotLastReleaseMs = 0; autopilotLastLoadMs = 0
            finishModelAutopilot(command, status: .failed, error: rejection.message,
                detail: rejection.detail, send: send)
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

    /// A `provider_busy` rejection carries its first busy reason as `detail`.
    private func autopilotRejection(_ command: ModelAutopilotCommand) -> AutopilotFailure? {
        refreshAutopilotSettings()
        publishModelAutopilotSnapshot()
        guard let snapshot = state.modelAutopilot else { return AutopilotFailure("not_opted_in") }
        let busyReasons = autopilotBusyReasons()
        if let code = ModelAutopilotPolicy.rejection(command: command, snapshot: snapshot,
            busy: !busyReasons.isEmpty, nowMs: Self.autopilotNowMs) {
            return AutopilotFailure(code, detail: code == "provider_busy" ? busyReasons.first?.rawValue : nil)
        }
        if command.unloadModelIds.contains(where: {
            autopilotLeaseUntil[$0].map { ContinuousClock.now < $0 } ?? false
        }) { return AutopilotFailure("active_lease") }
        if let target = command.loadModelId {
            guard autopilotModelInfo(target) != nil,
                  ModelScanner.resolveLocalPath(modelID: target) != nil
            else { return AutopilotFailure("model_not_cached") }
            guard ModelRuntimeRequirements.isEligible(modelID: target,
                available: loopConfig.runtimeCapabilities) else { return AutopilotFailure("hardware_ineligible") }
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
            if let rejection = autopilotRejection(command) { throw rejection }
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
                defer { autopilotLastReleaseMs = (ContinuousClock.now - releaseStart).autopilotMilliseconds }
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
                defer { autopilotLastLoadMs = (ContinuousClock.now - loadStart).autopilotMilliseconds }
                try Task.checkCancellation()
                try await prepareAutopilotTarget(command)
                try await ensureModelLoaded(modelId: target, allowEviction: false,
                    autopilotCommandId: command.commandId)
                guard modelSlots[target] != nil, !modelsUnloading.contains(target),
                      advertisedModels[target] != nil else { throw AutopilotFailure("load_did_not_settle") }
                autopilotLeaseUntil[target] = .now.advanced(by: .seconds(command.leaseSeconds))
                recordAutopilotPlacement(command)
            }
            autopilotLastElapsedMs = (ContinuousClock.now - operationStart).autopilotMilliseconds
            finishModelAutopilot(command, status: .succeeded, send: send)
        } catch {
            autopilotLastElapsedMs = (ContinuousClock.now - operationStart).autopilotMilliseconds
            let stalled = autopilotStalledCommandId == command.commandId && error is CancellationError
            finishModelAutopilot(command, status: .failed,
                error: stalled ? Self.transitionStalledError : error.localizedDescription,
                detail: (error as? AutopilotFailure)?.detail, send: send)
        }
        // Terminal snapshot is rebuilt WITH backend capacity before the forced
        // heartbeat; coordinator must reconcile the pair, not trust status alone.
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
        await resumeAutopilotDeferredModelChanges(send: send)
        await retryReserveDeferredPrefetches()
    }

    private func finishModelAutopilot(_ command: ModelAutopilotCommand,
        status: ModelAutopilotStatus.State, error: String? = nil, detail: String? = nil, send: SendHandle) {
        if autopilotCommand?.commandId == command.commandId {
            autopilotCommand = nil
            withdrawInactiveAutopilotModels()
            autopilotMutationStarted = false
            autopilotTask = nil
            state.refusingNewWork = isShuttingDown || isDraining || isReconnectingAfterRetirement
            if !autopilotManagesResidency { startIdleMonitor() }
        }
        if autopilotStalledCommandId == command.commandId { autopilotStalledCommandId = nil }
        autopilotHistory[command.commandId] = (command, status, error, detail)
        autopilotHistoryOrder.append(command.commandId)
        if autopilotHistoryOrder.count > 64 {
            autopilotHistory.removeValue(forKey: autopilotHistoryOrder.removeFirst())
        }
        logger.info("Model autopilot command=\(command.commandId) status=\(status.rawValue) error=\(error ?? "none") detail=\(detail ?? "none")")
        autopilotGeneration &+= 1
        autopilotLastCommandId = command.commandId
        autopilotLastCommandStatus = status
        publishModelAutopilotSnapshot()
        emitModelAutopilotStatus(command, status: status, error: error, detail: detail, send: send)
    }

    /// `detail` is consented detail: an operation that outlived revoked
    /// consent, or a replayed result, answers exactly as before it.
    private func emitModelAutopilotStatus(_ command: ModelAutopilotCommand,
        status: ModelAutopilotStatus.State, error: String? = nil, detail: String? = nil, send: SendHandle) {
        guard let snapshot = state.modelAutopilot else { return }
        send.send(.modelAutopilotStatus(ModelAutopilotStatus(commandId: command.commandId,
            status: status, error: error, detail: autopilotConsented ? detail : nil, modelAutopilot: snapshot)))
    }
}

private struct AutopilotFailure: LocalizedError {
    let message: String
    let detail: String?
    init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }
    var errorDescription: String? { message }
}
