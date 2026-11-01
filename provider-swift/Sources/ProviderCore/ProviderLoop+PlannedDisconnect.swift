import Foundation

extension ProviderLoop {
    /// Shared fence for healthy intentional disconnects (updates and metadata
    /// reconnects). A deadline is never permission to interrupt accepted work.
    /// An add-on hold that took over the drain keeps its connection, so during
    /// a hold only a planned reconnect may send the barrier: its fresh
    /// registration replaces the fenced connection.
    internal func waitForSafeDisconnect(
        timeout: Duration, reason: String, underAddonHold: Bool = false
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        func fenceAllowed() -> Bool { underAddonHold || servingDrain.owner != .addonHold }
        guard fenceAllowed(), await waitForInflightDrain(timeout: timeout, reason: reason), !Task.isCancelled,
              fenceAllowed() else { return false }
        guard let client = coordinatorClient else { return true }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        let generation = connectionGeneration
        disconnectBarrierPending = true
        let acknowledged = await client.acknowledgeDrain(timeout: remaining)
        return acknowledged && generation == connectionGeneration && !Task.isCancelled
    }

    internal func refreshAPNsAfterDrain(_ token: String) async {
        guard let client = coordinatorClient else { return }
        if await client.updateAPNsTokenForNextRegistration(token) { requestPlannedReconnect() }
    }

    internal func requestPlannedReconnect() {
        guard !isShuttingDown, servingDrain.owner != .lifecycle, coordinatorClient != nil else { return }
        plannedReconnectRevision &+= 1
        startPlannedReconnectIfNeeded()
    }

    /// A planned reconnect runs under its own drain or beneath an add-on hold
    /// that already refuses work. The hold keeps ownership, so the fresh
    /// registration cannot reopen admission.
    private var ownsPlannedReconnect: Bool {
        servingDrain.owner == .reconnect || servingDrain.owner == .addonHold
    }

    private func startPlannedReconnectIfNeeded() {
        guard pendingRetirementReconnect == nil, modelSwitchTask == nil, updatePhase == .idle,
              servingDrain.owner != .lifecycle, servingDrain.owner != .modelSwitch, !isShuttingDown,
              plannedReconnectRevision > issuedReconnectRevision else { return }
        beginServingDrain(owner: .reconnect)
        setRetirementReconnectBarrier(true)
        plannedReconnectTaskGeneration &+= 1
        let taskGeneration = plannedReconnectTaskGeneration
        pendingRetirementReconnect = Task { [weak self] in
            guard let self else { return }
            await self.performPlannedReconnect(taskGeneration: taskGeneration)
        }
    }

    private func performPlannedReconnect(taskGeneration: UInt64) async {
        defer {
            if plannedReconnectTaskGeneration == taskGeneration {
                pendingRetirementReconnect = nil
                startPlannedReconnectIfNeeded()
            }
        }
        while !Task.isCancelled, ownsPlannedReconnect, !isShuttingDown {
            let revision = plannedReconnectRevision
            guard let client = coordinatorClient, await client.hasRegisteredConnection() else {
                // No registration was sent on the current connection. The
                // client's next automatic registration carries the updated
                // token/model set; no drain or second reconnect is needed.
                issuedReconnectRevision = revision
                servingDrain.resumeReconnect()
                setRetirementReconnectBarrier(false)
                localResponseTracker.setAccepting(!servingDrain.refusing && !isShuttingDown)
                if !servingDrain.refusing { lifecycleStatus = .init() }
                return
            }
            if await waitForSafeDisconnect(timeout: .seconds(ProviderTermination.timeoutSeconds),
                                           reason: "planned reconnect", underAddonHold: true) {
                guard !Task.isCancelled, ownsPlannedReconnect, !isShuttingDown else { return }
                issuedReconnectRevision = plannedReconnectRevision
                await coordinatorClient?.reconnectAfterDrain()
                return
            }
            guard !Task.isCancelled, ownsPlannedReconnect, !isShuttingDown else { return }
            logger.warning("Planned reconnect deferred: accepted work or terminal acknowledgement is still pending; admission remains closed")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    internal func finishPlannedReconnect() {
        connectionGeneration &+= 1
        disconnectBarrierPending = false
        pendingRetirementReconnect?.cancel()
        pendingRetirementReconnect = nil
        if servingDrain.owner == .reconnect { deferredDesiredModels = nil }
        servingDrain.resumeReconnect()
        setRetirementReconnectBarrier(false)
        localResponseTracker.setAccepting(!servingDrain.refusing && !isShuttingDown)
        if !servingDrain.refusing { lifecycleStatus = .init() }
        reassertAddonHoldAfterReconnect()
        // A model-store rollback during the old close may need another fresh
        // registration. Do not lose it to coalescing with the earlier request.
        startPlannedReconnectIfNeeded()
    }

    internal func resumeAfterUpdateDrain() {
        if disconnectBarrierPending {
            // The coordinator may have committed a permanent fence even when
            // its ack was lost. Keep admission closed until a fresh connection.
            requestPlannedReconnect()
        } else {
            servingDrain.resumeUpdate()
            startPlannedReconnectIfNeeded()
        }
    }

    /// Release counterpart of `resumeAfterUpdateDrain`. A reconnect begun
    /// beneath the hold, or a barrier it may have committed, keeps admission
    /// closed until the fresh registration.
    internal func resumeAfterAddonHold() {
        servingDrain.resumeAddonHold()
        if pendingRetirementReconnect != nil {
            beginServingDrain(owner: .reconnect)
        } else if disconnectBarrierPending {
            requestPlannedReconnect()
        } else {
            startPlannedReconnectIfNeeded()
        }
    }
}
