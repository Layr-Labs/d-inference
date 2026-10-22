import Foundation
import DarkbloomClusterProtocol

public enum ClusterOwnerTermination: Equatable, Sendable {
    /// Foundation.Process.run failed without creating a child.
    case launchFailed
    /// Supplied only after the local supervisor actually observed/reaped this child.
    case exited(status: Int32)
    case signalled(signal: Int32)
    /// The owner closed before ever attempting a native launch.
    case neverLaunched
}

public struct ClusterOwnerNativeTerminal: Equatable, Sendable {
    public let launchID: UUID?
    public let termination: ClusterOwnerTermination
}

/// Value-only local-owner assertion. An authenticated transport may forward it;
/// this DTO is neither a signature nor hardware attestation nor proof of remote EOF.
public struct ClusterOwnerTerminal: Equatable, Sendable {
    public let route: ClusterOwnerRoute
    public let native: ClusterOwnerNativeTerminal
    public let releasedRequestCount: Int
    public let lastAcceptedControlSequence: UInt64?
}

public struct ClusterOwnerStatus: Sendable {
    public let route: ClusterOwnerRoute
    public let nextControlSequence: UInt64
    public let ready: Bool
    public let quarantined: Bool
    public let recoveredUnresolved: Bool
    public let nativeLaunchID: UUID?
    public let activeRequestID: UUID?
    /// Unknown for recovered unresolved ownership. Otherwise includes pending admission's entire offered ceiling until actual admission.
    /// Retained through disconnect/timeout and until observed resource release.
    public let chargedRequestBytes: Int?
    public let nativeTerminal: ClusterOwnerNativeTerminal?
    public let deviceLeaseReleased: Bool
}
