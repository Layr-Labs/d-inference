import Foundation

/// What this Mac's own RDMA devices and network interfaces look like before any
/// cluster process starts. Device and interface names only: no IPv4 or IPv6
/// address, MAC address, GID, host name or serial number is ever stored here.
public struct ClusterLinkReadinessReport: Encodable, Sendable, Equatable {
    public enum Transport: String, Encodable, Sendable { case thunderbolt, other }
    /// Whether the address Darkbloom has assigned to a port is on it now.
    public enum AssignedAddress: String, Encodable, Sendable { case present, missing }

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
        /// Nil when Darkbloom has no record of assigning this port an address.
        /// `missing` means it has one on record and the port does not carry it.
        public internal(set) var assignedAddress: AssignedAddress? = nil
        /// Nil with no such record, or when it could not be read. Otherwise
        /// whether the system job that puts that address back is installed and
        /// loaded as Darkbloom writes it.
        public internal(set) var addressKept: Bool? = nil
        /// Nil unless the network around the port was read (link setup v2):
        /// whether the port belongs to the cluster alone, and if not, why.
        public internal(set) var isolation: ClusterLinkIsolationStatus? = nil

        /// The address is Darkbloom's and nothing would put it back.
        var addressIsTemporary: Bool { assignedAddress == .present && addressKept == false }

        /// A port the approval of link setup v2 could isolate, or one that
        /// needs it but has something in the way: ready, or lacking only an address.
        var isolationApplies: Bool {
            guard portActive, let isolation, !isolation.isolated else { return false }
            return verdict == .ready || verdict.fixableByAddingAddress
        }

        /// What to do about this port: the verdict's guidance, unless what it
        /// lacks, or is about to lose, is an address Darkbloom assigned to it.
        /// Where the network around the port was read, what isolating it
        /// takes comes first, because that is what keeps an address there.
        var guidance: String? {
            if isolationApplies, let interface, let advice = isolation?.guidance(interface: interface) { return advice }
            if assignedAddress == .missing, verdict.fixableByAddingAddress { return ClusterLinkReadinessReport.addressLostGuidance }
            if verdict == .ready, addressIsTemporary { return ClusterLinkReadinessReport.addressTemporaryGuidance }
            return verdict.guidance
        }
    }

    /// For a port without the address on record for it. True whether macOS
    /// removed the address or an earlier attempt never got it there.
    static let addressLostGuidance = "The active Thunderbolt port does not have the address Darkbloom has on record for it, as happens when macOS reconfigures the port; run `darkbloom cluster` to put it there and keep it there, which asks for your approval in a macOS prompt."

    /// For a ready port whose address nothing would put back: no job was
    /// installed for it, or the job is not loaded as written.
    static let addressTemporaryGuidance = "Nothing keeps the address Darkbloom added to the active Thunderbolt port, because the system job for it is not installed and running, so macOS will remove the address when it next reconfigures the port; run `darkbloom cluster` to keep it there, which asks for your approval in a macOS prompt."

    public let schema = "darkbloom_cluster_link_readiness_v1"
    public let state: ClusterLinkReadinessState
    public let guidance: String?
    public let devices: [Device]
    /// Local interface state was read. No peer was contacted, no collective ran
    /// and no setting was changed.
    public let physicalProbePerformed = false

    init(state: ClusterLinkReadinessState, devices: [Device] = []) {
        self.state = state
        // The port that names the state also names what to do about it.
        self.guidance = devices.first { $0.portActive && $0.verdict == state }?.guidance ?? state.guidance
        self.devices = devices
    }
}
