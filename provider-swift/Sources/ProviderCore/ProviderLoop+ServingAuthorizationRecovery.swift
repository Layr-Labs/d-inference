import Foundation

extension ProviderLoop {
    /// A reconnect that keeps failing reports one disconnect per attempt. The
    /// connection has been down since the first, so those keep `since`.
    internal func noteCoordinatorConnection(connected: Bool, now: Double = Date().timeIntervalSince1970) {
        unauthorizedSince = nil
        let previous = coordinatorConnection
        if !connected, previous?.connected == false { return }
        coordinatorConnection = DaemonState.CoordinatorConnection(
            connected: connected, since: now,
            connections: (previous?.connections ?? 0) + (connected ? 1 : 0))
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
        let lacksAuthorization = UnauthorizedConnectionRecovery.connectionLacksAuthorization(
            connectedAt: connection.since, trust: lastTrustStatus, now: now)
        guard !advertisedModels.isEmpty, lacksAuthorization else {
            if unauthorizedSince != nil, !lacksAuthorization { logger.info(.coordinatorRoutingConnection) }
            unauthorizedSince = nil
            return
        }
        guard let since = unauthorizedSince else {
            unauthorizedSince = now
            logger.warning(.coordinatorNotRoutingConnection)
            return
        }
        guard UnauthorizedConnectionRecovery.shouldReconnect(
            unauthorizedSince: since, lastReconnectAt: lastUnauthorizedReconnectAt,
            attempts: unauthorizedReconnectAttempts, busy: !isIdleForReregistration,
            jitter: unauthorizedReconnectJitter, now: now) else { return }
        lastUnauthorizedReconnectAt = now
        unauthorizedReconnectAttempts += 1
        unauthorizedSince = nil
        logger.warning(.unauthorizedConnectionReregistering)
        requestPlannedReconnect()
    }

    /// A re-registration closes admission before it disconnects, which fails
    /// an accepted Autopilot command and cancels a startup preload. Like the
    /// Autopilot inventory re-registration, it waits until nothing is busy,
    /// and it never starts during an update.
    private var isIdleForReregistration: Bool {
        autopilotCommand == nil && autopilotBusyReasons().isEmpty && updatePhase == .idle
    }
}

extension CoordinatorEvent {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
