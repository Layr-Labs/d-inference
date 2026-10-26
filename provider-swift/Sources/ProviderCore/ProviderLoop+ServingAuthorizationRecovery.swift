import Foundation

extension ProviderLoop {
    internal func noteCoordinatorConnection(connected: Bool, now: Double = Date().timeIntervalSince1970) {
        let previous = coordinatorConnection
        coordinatorConnection = DaemonState.CoordinatorConnection(
            connected: connected, since: now,
            connections: (previous?.connections ?? 0) + (connected ? 1 : 0))
        unauthorizedSince = nil
    }

    /// Runs every capacity tick. Logs when the coordinator stops or resumes
    /// routing this connection, and re-registers a connection it keeps
    /// refusing (`UnauthorizedConnectionRecovery`).
    internal func superviseServingAuthorization(now: Double = Date().timeIntervalSince1970) {
        guard let connection = coordinatorConnection, connection.connected, !isShuttingDown else {
            unauthorizedSince = nil
            return
        }
        if let authorization = lastTrustStatus?.authorization,
           authorization.hasCurrentAppAttestAuthorization(now: now) || authorization.path == "legacy" {
            unauthorizedReconnectAttempts = 0
        }
        guard !advertisedModels.isEmpty,
              UnauthorizedConnectionRecovery.connectionLacksAuthorization(
                connectedAt: connection.since, trust: lastTrustStatus, now: now)
        else {
            if unauthorizedSince != nil { logger.info(.coordinatorRoutingConnection) }
            unauthorizedSince = nil
            return
        }
        guard let since = unauthorizedSince else {
            unauthorizedSince = now
            logger.warning(.coordinatorNotRoutingConnection)
            return
        }
        let workInProgress = hasInflightWork || isLoadingAny || servingDrain.refusing
            || updatePhase != .idle || modelSwitchTask != nil
        guard UnauthorizedConnectionRecovery.shouldReconnect(
            unauthorizedSince: since, lastReconnectAt: lastUnauthorizedReconnectAt,
            attempts: unauthorizedReconnectAttempts, workInProgress: workInProgress,
            jitter: unauthorizedReconnectJitter, now: now) else { return }
        lastUnauthorizedReconnectAt = now
        unauthorizedReconnectAttempts += 1
        unauthorizedSince = nil
        logger.warning(.unauthorizedConnectionReregistering)
        requestPlannedReconnect()
    }
}

extension CoordinatorEvent {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
