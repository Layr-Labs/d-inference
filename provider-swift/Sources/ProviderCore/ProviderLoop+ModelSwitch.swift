import Foundation

extension ProviderLoop {
    /// The daemon owns this task: closing the CLI must not cancel accepted work
    /// or leave a half-applied selection. Stop/signal still takes precedence.
    public func switchModels(request: ProviderModelSwitchRequest) async -> ProviderModelSwitchStatus {
        guard let identity = ProcessIdentity.current(), request.isValid(for: identity) else {
            return .init(requestID: request.id, outcome: .failed, message: "Invalid or stale model-switch request.")
        }
        if let task = modelSwitchTask {
            if modelSwitchStatus.requestID == request.id { return await task.value }
            let busy = ProviderModelSwitchStatus(requestID: request.id, outcome: .busy,
                message: "Another model switch is still running.")
            writeModelSwitchReceipt(busy)
            return busy
        }
        guard !isShuttingDown, updatePhase == .idle,
              servingDrain.owner == nil || servingDrain.owner == .modelSwitch,
              pendingRetirementReconnect == nil,
              plannedReconnectRevision == issuedReconnectRevision,
              let client = coordinatorClient, await client.hasRegisteredConnection() else {
            let busy = ProviderModelSwitchStatus(requestID: request.id, outcome: .busy,
                message: "Provider is starting, disconnected, updating, or draining for another operation. Retry when it is serving.")
            writeModelSwitchReceipt(busy)
            return busy
        }
        // Recheck after the client hop, before claiming exclusive ownership.
        guard modelSwitchTask == nil, !isShuttingDown, updatePhase == .idle,
              pendingRetirementReconnect == nil, plannedReconnectRevision == issuedReconnectRevision,
              servingDrain.owner == nil || servingDrain.owner == .modelSwitch else {
            let busy = ProviderModelSwitchStatus(requestID: request.id, outcome: .busy,
                message: "Provider lifecycle changed; retry the switch.")
            writeModelSwitchReceipt(busy)
            return busy
        }
        modelSwitchStatus = .init(requestID: request.id, outcome: .validating, models: request.models)
        publishModelSwitchStatus()
        let task = Task { await self.performModelSwitch(request: request) }
        modelSwitchTask = task
        let result = await task.value
        modelSwitchTask = nil
        if !servingDrain.refusing, plannedReconnectRevision > issuedReconnectRevision {
            requestPlannedReconnect()
        }
        return result
    }

    private func performModelSwitch(request: ProviderModelSwitchRequest) async -> ProviderModelSwitchStatus {
        do {
            let selection = try await ProviderModelSwitchValidation.scanCancellable(
                request.models, capabilities: loopConfig.runtimeCapabilities,
                resolveSnapshot: modelSwitchSnapshotResolver, hashSnapshot: modelSwitchWeightHasher)
            let models = selection.models
            try Task.checkCancellation()
            try checkModelSwitchOwnership(allowServing: true)
            let physical = UInt64(loopConfig.hardware.memoryGb) * 1_073_741_824
            let reserve = UnifiedMemoryCap.loadReserveBytes(physicalBytes: physical,
                configReserveBytes: Self.memoryReserveBytes(forGiB: loopConfig.config.provider.memoryReserveGB))
            let headroom = Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: request.models)) / 1_073_741_824
            for model in models {
                guard ModelLoadAdmission.requiredToLoadGb(weightsGb: model.estimatedMemoryGb, headroomGb: headroom)
                        <= Double(physical - min(physical, reserve)) / 1_073_741_824 else {
                    throw ModelSelectionFailure("Model '\(model.id)' cannot fit this Mac's memory cap with activation and KV headroom.")
                }
            }
            try validateModelSwitchSelfTests(models)
            beginServingDrain(owner: .modelSwitch)
            modelSelectionRevision &+= 1
            setModelSwitchPhase(.draining)
            let deadline = request.timeoutSeconds == 0 ? nil : ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
            let oldPrefetch = prefetchCoordinator
            prefetchCoordinator = nil
            await oldPrefetch?.shutdown(timeout: .seconds(min(request.timeoutSeconds, 10)))
            await coordinatorClient?.sendEventHeartbeat()
            let drainID = try await drainForModelSwitch(deadline: deadline)
            try checkModelSwitchOwnership()
            setModelSwitchPhase(.switching)
            try await commitModelSelection(selection, drainID: drainID)
            try checkModelSwitchOwnership()
            await resumeAfterModelSwitch()
            guard servingDrain.owner == nil, !isShuttingDown, !Task.isCancelled else {
                throw ModelSelectionFailure("Model selection applied, but shutdown superseded resuming service.")
            }
            modelSwitchStatus.outcome = .switched
            modelSwitchStatus.remaining = 0
            modelSwitchStatus.message = "Selection applied without restarting or reconnecting. New models load on demand."
        } catch {
            // Unknown receipts and drain deadlines keep admission closed. A
            // fresh switch can reconcile the intended set on the same socket.
            modelSwitchStatus.outcome = servingDrain.owner == .modelSwitch ? .timedOut : .failed
            modelSwitchStatus.remaining = lifecycleRemaining
            modelSwitchStatus.message = "\(error)"
            if servingDrain.owner == .modelSwitch {
                modelSwitchStatus.message? += " Admission remains closed; repeat darkbloom switch to reconcile, or use darkbloom restart."
            }
        }
        publishModelSwitchStatus()
        return modelSwitchStatus
    }

    /// Drain inference AND background model mutations. The receive-side ack is
    /// processed behind earlier inference frames, closing the last-dispatch race.
    /// A nil deadline means no waiting for unfinished work, not skipping the
    /// coordinator barrier: an already-settled provider gets one 30s wire wait.
    internal func drainForModelSwitch(deadline: ContinuousClock.Instant?) async throws -> String {
        while true {
            try Task.checkCancellation()
            try checkModelSwitchOwnership()
            if let deadline, ContinuousClock.now >= deadline {
                throw ModelSelectionFailure("Model-switch drain deadline expired; no accepted request was cancelled.")
            }
            modelSwitchStatus.remaining = lifecycleRemaining
            publishModelSwitchStatus()
            if lifecycleRemaining == 0, modelSwitchMutationsSettled {
                guard let client = coordinatorClient,
                      let id = await client.prepareModelSwitch(timeout: deadline.map { ContinuousClock.now.duration(to: $0) } ?? .seconds(30)) else {
                    throw ModelSelectionFailure("Coordinator did not acknowledge the model-switch drain.")
                }
                try Task.checkCancellation()
                try checkModelSwitchOwnership()
                if lifecycleRemaining == 0, modelSwitchMutationsSettled { return id }
            }
            guard let deadline, ContinuousClock.now < deadline else {
                throw ModelSelectionFailure("Model-switch drain deadline expired; no accepted request was cancelled.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    internal var modelSwitchMutationsSettled: Bool {
        !isLoadingAny && modelsLoading.isEmpty && modelsUnloading.isEmpty && !isReslicing
            && pendingAdvertise.isEmpty && retiringModels.isEmpty && preloadTasks.isEmpty
            && startupPreloadTask == nil && modelAdvertisementsInFlight == 0
            && mtpUpgradeTransitions.isEmpty && mtpStagingBytes == 0
    }
    internal func checkModelSwitchOwnership(allowServing: Bool = false) throws {
        guard !isShuttingDown, !Task.isCancelled,
              servingDrain.owner == .modelSwitch || (allowServing && servingDrain.owner == nil) else {
            throw ModelSelectionFailure("Model switch superseded by provider shutdown or another lifecycle operation.")
        }
    }

    /// Read-only validation abandons its result on cancellation. Once mutation
    /// starts, still await the transaction's cleanup before lifecycle proceeds.
    internal func cancelModelSwitchAndWait() async {
        let switching = modelSwitchTask
        switching?.cancel()
        _ = await switching?.value
    }

    internal func resumeAfterModelSwitch() async {
        guard servingDrain.owner == .modelSwitch, !isShuttingDown, !Task.isCancelled else { return }
        prefetchCoordinator = makePrefetchCoordinator()
        servingDrain.resumeModelSwitch()
        lifecycleStatus = .init()
        localResponseTracker.setAccepting(true)
        state.refusingNewWork = false
        await coordinatorClient?.sendEventHeartbeat()
    }

    private func setModelSwitchPhase(_ phase: ProviderModelSwitchStatus.Outcome) {
        modelSwitchStatus.outcome = phase
        modelSwitchStatus.remaining = lifecycleRemaining
        publishModelSwitchStatus()
    }

    internal func publishModelSwitchStatus() {
        if servingDrain.owner == .modelSwitch {
            lifecycleStatus.remaining = lifecycleRemaining
            lifecycleStatus.outcome = modelSwitchStatus.outcome == .timedOut ? .timedOut : .draining
        }
        writeModelSwitchReceipt(modelSwitchStatus)
        writeDaemonState()
    }

    private func writeModelSwitchReceipt(_ status: ProviderModelSwitchStatus) {
        guard let identity = ProcessIdentity.current() else { return }
        let directory = (daemonStateFileOverride ?? DaemonStateFile.path())
            .deletingLastPathComponent().appendingPathComponent("lifecycle")
        try? LifecycleMailbox(identity: identity, directory: directory).writeSwitchStatus(status)
    }
}

struct ModelSelectionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
