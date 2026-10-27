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

    /// A request the coordinator routes here is newer evidence than a refusal
    /// it sent earlier (`ServingReadiness`). The next state write persists it.
    internal func noteCoordinatorRequest(now: Double = Date().timeIntervalSince1970) {
        guard coordinatorConnection?.connected == true else { return }
        coordinatorConnection?.lastRequestAt = now
    }

    /// Runs every capacity tick on the verdict `status` and `doctor` show.
    /// Logs when the coordinator starts or stops refusing this connection,
    /// and re-registers a connection it keeps refusing
    /// (`UnauthorizedConnectionRecovery`).
    internal func superviseServingAuthorization(now: Double = Date().timeIntervalSince1970) {
        guard let connection = coordinatorConnection, connection.connected, !isShuttingDown else {
            unauthorizedSince = nil
            return
        }
        switch ServingReadiness.verdict(connection: connection, trust: lastTrustStatus, now: now) {
        case .blocked? where !advertisedModels.isEmpty:
            superviseRefusedConnection(now: now)
        case .blocked?:
            unauthorizedSince = nil
        case .authorized?:
            unauthorizedReconnectAttempts = 0
            if unauthorizedSince != nil { logger.info(.coordinatorRoutingConnection) }
            unauthorizedSince = nil
        case .pending?, .unconfirmed?, nil:
            // A refusal the coordinator stopped repeating says nothing about
            // the connection now; it is not evidence of routing either.
            if unauthorizedSince != nil { logger.info(.coordinatorRefusalUnconfirmed) }
            unauthorizedSince = nil
        }
    }

    private func superviseRefusedConnection(now: Double) {
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
