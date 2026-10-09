import Foundation

/// What this Mac's own RDMA devices and network interfaces look like before any
/// cluster process starts. Device and interface names only: no IPv4 or IPv6
/// address, MAC address, GID, host name or serial number is ever stored here.
public struct ClusterLinkReadinessReport: Encodable, Sendable, Equatable {
    public enum Transport: String, Encodable, Sendable { case thunderbolt, other }

    public struct Device: Encodable, Sendable, Equatable {
        public let device: String
        /// The network interface behind the device; nil when the device name
        /// does not follow the `rdma_<interface>` convention.
        public let interface: String?
        public let transport: Transport
        public let portActive: Bool
        /// Interface facts are nil when the interface was not listed.
        public let interfaceActive: Bool?
        public let interfaceHasIPv4Address: Bool?
        /// The bridge this interface is a member of, if any.
        public let bridge: String?
        /// Nil when the GID table was not read: only active ports are inspected.
        public let ipv4MappedGIDPresent: Bool?
        public let verdict: ClusterLinkReadinessState
    }

    public let schema = "darkbloom_cluster_link_readiness_v1"
    public let state: ClusterLinkReadinessState
    public let guidance: String?
    public let devices: [Device]
    /// Local interface state was read. No peer was contacted, no collective ran
    /// and no setting was changed.
    public let physicalProbePerformed = false

    init(state: ClusterLinkReadinessState, devices: [Device] = []) {
        self.state = state
        self.guidance = state.guidance
        self.devices = devices
    }
}
