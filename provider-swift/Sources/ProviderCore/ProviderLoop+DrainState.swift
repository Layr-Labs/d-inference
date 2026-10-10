extension ProviderLoop {
    /// Keep the heartbeat/quote admission mirror raised for the whole
    /// retirement reconnect barrier, including the late in-flight drain.
    internal func setRetirementReconnectBarrier(_ active: Bool) {
        isReconnectingAfterRetirement = active
        // A control-only member never admits ordinary work: an accepted
        // connection lifts this barrier but must not reopen its mirror, or the
        // member would report idle where it refuses every request.
        state.refusingNewWork = isClusterMember || active || isDraining || isShuttingDown || autopilotCommand != nil
        if let client = coordinatorClient {
            Task { await client.sendEventHeartbeat() }
        }
    }
}
