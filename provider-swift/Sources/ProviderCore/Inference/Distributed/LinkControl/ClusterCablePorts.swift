import DarkbloomClusterRemote

/// The TCP and UDP ports a two-Mac pair uses on the cable, for one install. Production's are the numbers the cluster
/// has always used; another install adds its `BuildEnvironment.clusterPortOffset` (DevNet: 10), so a DevNet pair and a
/// production pair on the same two Macs never find, answer or block each other. Both Macs of a pair run the same
/// install, so they agree on every port.
public struct ClusterCablePorts: Sendable, Equatable {
    /// The pairing ceremony's listener and the probes that find it.
    public let pairing: UInt16
    /// The setup exchange and the leader's commands to the member's cluster service, and the probes that find it.
    public let exchange: UInt16
    /// The derived control lease between the two cluster services.
    public let control: UInt16
    /// The GLM calibration's paired control channel.
    public let glmCalibration: UInt16
    /// The link control channel a setup names, when it is free on the leader (`ClusterSetupPorts`).
    public let linkControl: UInt16
    /// Where the native ranks meet, when it is free on the leader (`ClusterSetupPorts`).
    public let coordinator: UInt16

    public init(environment: BuildEnvironment = .current) {
        let offset = environment.clusterPortOffset
        pairing = ClusterLinkPairing.defaultPort + offset
        exchange = 47_422 + offset
        control = 47_423 + offset
        glmCalibration = 47_424 + offset
        linkControl = ClusterLinkControlListener.defaultPort + offset
        coordinator = 52_420 + offset
    }

    /// This build's ports.
    public static let current = ClusterCablePorts()

    /// Every port, for checks.
    public var all: [UInt16] { [pairing, exchange, control, glmCalibration, linkControl, coordinator] }
}
