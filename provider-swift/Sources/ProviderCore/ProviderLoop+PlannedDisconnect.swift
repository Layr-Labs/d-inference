import Foundation

extension ProviderLoop {
    /// Shared fence for healthy intentional disconnects (updates and metadata
    /// reconnects). A deadline is never permission to interrupt accepted work.
    internal func waitForSafeDisconnect(timeout: Duration, reason: String) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard await waitForInflightDrain(timeout: timeout, reason: reason), !Task.isCancelled else { return false }
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

    private func startPlannedReconnectIfNeeded() {
        guard pendingRetirementReconnect == nil, updatePhase == .idle,
              servingDrain.owner != .lifecycle, !isShuttingDown,
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
        while !Task.isCancelled, servingDrain.owner == .reconnect, !isShuttingDown {
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
            if await waitForSafeDisconnect(timeout: .seconds(ProviderTermination.timeoutSeconds), reason: "planned reconnect") {
                guard !Task.isCancelled, servingDrain.owner == .reconnect, !isShuttingDown else { return }
                issuedReconnectRevision = plannedReconnectRevision
                await coordinatorClient?.reconnectAfterDrain()
                return
            }
            guard !Task.isCancelled, servingDrain.owner == .reconnect, !isShuttingDown else { return }
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
}
