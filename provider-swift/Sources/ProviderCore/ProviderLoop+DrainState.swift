extension ProviderLoop {
    /// Keep the heartbeat/quote admission mirror raised for the whole
    /// retirement reconnect barrier, including the late in-flight drain.
    internal func setRetirementReconnectBarrier(_ active: Bool) {
        isReconnectingAfterRetirement = active
        state.refusingNewWork = active || isDrainingForUpdate || isShuttingDown
        if let client = coordinatorClient {
            Task { await client.sendEventHeartbeat() }
        }
    }
}
