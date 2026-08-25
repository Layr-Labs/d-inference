import Foundation

/// Authoritative provider↔coordinator connection state persisted in
/// `daemon-state.json`.
///
/// A successful trust status belongs to one live transport session. Once that
/// transport disconnects it must not remain usable as proof that the provider
/// is online. Reconnection changes the transport posture only; a new
/// coordinator `trust_status` is required before verified trust is restored.
public struct CoordinatorConnectionTruth: Sendable, Equatable {
    public private(set) var trust: DaemonState.Trust?
    public private(set) var connectivity: DaemonState.Connectivity

    public init(
        trust: DaemonState.Trust? = nil,
        connectivity: DaemonState.Connectivity = .init(
            reconnectCount: 0,
            lastError: nil
        )
    ) {
        self.trust = trust
        self.connectivity = connectivity
    }

    public mutating func recordConnected(at timestamp: Double) {
        connectivity.status = .connected
        connectivity.lastError = nil
        connectivity.changedAt = timestamp
        // Deliberately retain an offline trust verdict from the preceding
        // disconnect. Registration and transport readiness are not trust
        // verification; only a fresh trust_status may replace it.
    }

    public mutating func recordDisconnected(
        reason: String,
        at timestamp: Double,
        incrementsReconnectCount: Bool = true
    ) {
        if incrementsReconnectCount {
            let (next, overflow) = connectivity.reconnectCount.addingReportingOverflow(1)
            connectivity.reconnectCount = overflow ? Int.max : next
        }
        connectivity.status = .disconnected
        connectivity.lastError = reason
        connectivity.changedAt = timestamp
        trust = DaemonState.Trust(
            trustLevel: trust?.trustLevel ?? "none",
            status: "offline",
            reason: reason,
            receivedAt: timestamp
        )
    }

    /// Accept a coordinator trust status only while its transport session is
    /// live. This makes a delayed event from a torn-down session fail closed.
    @discardableResult
    public mutating func recordTrustStatus(
        trustLevel: String,
        status: String,
        reason: String,
        at timestamp: Double
    ) -> Bool {
        guard connectivity.status == .connected else {
            return false
        }
        trust = DaemonState.Trust(
            trustLevel: trustLevel,
            status: status,
            reason: reason,
            receivedAt: timestamp
        )
        return true
    }
}
