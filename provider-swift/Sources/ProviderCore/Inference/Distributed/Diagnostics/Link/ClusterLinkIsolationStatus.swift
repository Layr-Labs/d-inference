import Foundation

/// One way a cluster port is not set up as link setup v2 requires: a port
/// that belongs to the cluster alone, with its own network service, a fixed
/// address in the cluster subnet, no router, no DNS and no bridge. Raw values
/// are an output contract; add cases rather than renaming them.
public enum ClusterLinkIsolationFinding: String, Encodable, Sendable, CaseIterable {
    /// The port is a member of a bridge in macOS's network settings.
    case portInBridge
    /// Internet Sharing is on and shares over a bridge that contains the port.
    case internetSharingOverPortBridge
    /// Internet Sharing is on and lists the port itself among its devices.
    case internetSharingToPort
    /// The port is a member of a bridge macOS's network settings do not list,
    /// such as the one Internet Sharing makes when it shares to the port directly.
    case portInUnmanagedBridge
    /// A default route leaves through the port.
    case defaultRouteViaPort
    /// A DNS resolver is reached through the port.
    case dnsViaPort
    /// The port holds a DHCP lease; on a direct cable it can only come from the other Mac.
    case dhcpLeaseOnPort
    /// The port has no IPv4 address at all.
    case portAddressMissing
    /// The port has no network service of Darkbloom's.
    case clusterServiceMissing
    /// Darkbloom's service exists but is not manual, has another address, a
    /// router, or automatic IPv6.
    case clusterServiceMisconfigured
    /// Another enabled network service configures the same port.
    case otherServiceOnPort
    /// Another interface or route already uses the cluster subnet.
    case clusterSubnetInUse
    /// A service on the port, or the port's hardware port, has a name Darkbloom
    /// will not place in a command.
    case serviceNameUnsafe
    /// macOS lists no hardware port for the interface, so no service can be made for it.
    case hardwarePortUnknown
    /// A reading the decision needs could not be taken.
    case stateUnreadable

    /// Whether the one approval cannot cure it: these stop the change before
    /// any prompt, with the guidance saying what the owner can do instead.
    public var blocksApproval: Bool {
        switch self {
        case .internetSharingToPort, .portInUnmanagedBridge, .clusterSubnetInUse, .serviceNameUnsafe,
             .hardwarePortUnknown, .stateUnreadable:
            return true
        case .portInBridge, .internetSharingOverPortBridge, .defaultRouteViaPort, .dnsViaPort, .dhcpLeaseOnPort,
             .portAddressMissing, .clusterServiceMissing, .clusterServiceMisconfigured, .otherServiceOnPort:
            return false
        }
    }

    /// What was found, as a short phrase for one line of facts.
    func fact(interface: String, bridge: String?) -> String {
        let bridgeName = bridge ?? "a bridge"
        switch self {
        case .portInBridge: return "member of \(bridgeName) in the network settings"
        case .internetSharingOverPortBridge: return "Internet Sharing shares over \(bridgeName)"
        case .internetSharingToPort: return "Internet Sharing shares to \(interface) directly"
        case .portInUnmanagedBridge: return "member of \(bridgeName), which the network settings do not list"
        case .defaultRouteViaPort: return "a default route leaves through \(interface)"
        case .dnsViaPort: return "a DNS resolver is reached through \(interface)"
        case .dhcpLeaseOnPort: return "\(interface) holds a DHCP lease from the other Mac"
        case .portAddressMissing: return "no IPv4 address"
        case .clusterServiceMissing: return "no network service of Darkbloom's"
        case .clusterServiceMisconfigured: return "Darkbloom's network service is not configured as Darkbloom writes it"
        case .otherServiceOnPort: return "another network service configures \(interface)"
        case .clusterSubnetInUse: return "the cluster subnet \(ClusterLinkClusterAddress.prefix)/16 is already used on this Mac"
        case .serviceNameUnsafe: return "a network service or hardware port name Darkbloom will not put in a command"
        case .hardwarePortUnknown: return "no hardware port listed for \(interface)"
        case .stateUnreadable: return "the network settings could not be read"
        }
    }

    /// What the one approval does about it, or, for a blocking finding, what
    /// the owner can do, because Darkbloom will not.
    func remedy(interface: String, bridge: String?, hardwarePort: String?) -> String {
        let bridgeName = bridge ?? "the bridge"
        let port = hardwarePort.map { "“\($0)” (\(interface))" } ?? interface
        switch self {
        case .portInBridge, .internetSharingOverPortBridge:
            return "the approval takes \(interface) out of \(bridgeName) for good; the bridge keeps its other members and Internet Sharing over it is left as it is"
        case .defaultRouteViaPort, .dnsViaPort, .dhcpLeaseOnPort, .portAddressMissing, .clusterServiceMissing,
             .clusterServiceMisconfigured:
            return "the approval gives \(interface) its own network service (\(ClusterLinkServiceName.cluster(interface: interface))) with a fixed address in \(ClusterLinkClusterAddress.prefix)/16, no router, no DNS and link-local IPv6 only"
        case .otherServiceOnPort:
            return "the approval switches the other service on \(interface) off, keeping its settings, and `darkbloom cluster link --remove` switches it on again"
        case .internetSharingToPort:
            return "Darkbloom does not change Internet Sharing: in System Settings → General → Sharing, click ⓘ next to Internet Sharing and turn off \(port) under “To devices using” (or turn Internet Sharing off), then run `darkbloom cluster` again, because a port taken out of the bridge would otherwise be shared to directly"
        case .portInUnmanagedBridge:
            return "Darkbloom will not change a bridge the network settings do not list; if Internet Sharing made it, turn off \(port) under Internet Sharing's “To devices using” in System Settings → General → Sharing, then run `darkbloom cluster` again"
        case .clusterSubnetInUse:
            return "Darkbloom will not add a second route into \(ClusterLinkClusterAddress.prefix)/16; remove that address or route from the other interface or VPN, then run `darkbloom cluster` again"
        case .serviceNameUnsafe:
            return "rename the network services on \(interface) in System Settings → Network to letters, digits, spaces and ( ) - . _ only, then run `darkbloom cluster` again"
        case .hardwarePortUnknown:
            return "reconnect the cable so macOS lists the port, then run `darkbloom cluster` again"
        case .stateUnreadable:
            return "run `networksetup -listnetworkserviceorder` and `netstat -rn` in Terminal to see what they report, then run `darkbloom cluster` again"
        }
    }
}

/// How far one cluster port is from the isolated setup of link setup v2, and
/// what the one approval would need to know to get it there. Only the
/// finding names and the verdict are encoded: service names and the bridge's
/// member list stay out of every report.
public struct ClusterLinkIsolationStatus: Encodable, Sendable, Equatable {
    public let findings: [ClusterLinkIsolationFinding]
    public var isolated: Bool { findings.isEmpty }

    /// The bridge in the network settings that holds the port, and where.
    struct BridgeMembership: Equatable, Sendable {
        let bridge: String
        let index: Int
        let members: [String]
    }

    /// The bridge the port is in, from the settings or the kernel.
    let bridge: String?
    let preferenceBridge: BridgeMembership?
    let hardwarePort: String?
    /// Enabled services on the port other than Darkbloom's, by name.
    let otherServices: [String]
    /// Darkbloom's own service exists for the port.
    let clusterServicePresent: Bool

    init(findings: [ClusterLinkIsolationFinding], bridge: String? = nil, preferenceBridge: BridgeMembership? = nil,
         hardwarePort: String? = nil, otherServices: [String] = [], clusterServicePresent: Bool = false) {
        self.findings = findings
        self.bridge = bridge
        self.preferenceBridge = preferenceBridge
        self.hardwarePort = hardwarePort
        self.otherServices = otherServices
        self.clusterServicePresent = clusterServicePresent
    }

    var blockers: [ClusterLinkIsolationFinding] { findings.filter(\.blocksApproval) }
    /// The approval would change something and nothing stops it.
    var approvalWouldIsolate: Bool { !findings.isEmpty && blockers.isEmpty }

    private enum CodingKeys: String, CodingKey { case isolated, findings }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isolated, forKey: .isolated)
        try container.encode(findings, forKey: .findings)
    }

    /// The facts on one line, for a port's summary.
    func facts(interface: String) -> String {
        guard !isolated else { return "isolated: own network service, fixed address, no bridge, router or DNS" }
        return "not isolated: " + findings.map { $0.fact(interface: interface, bridge: bridge) }.joined(separator: ", ")
    }

    /// What to do: the blocking findings' remedies when there are any, since
    /// the approval cannot run until they are dealt with; otherwise one
    /// sentence offering the approval.
    func guidance(interface: String) -> String? {
        guard !isolated else { return nil }
        let blocking = blockers
        if !blocking.isEmpty {
            let found = blocking.map { $0.fact(interface: interface, bridge: bridge) }.joined(separator: "; ")
            let remedies = blocking.map { $0.remedy(interface: interface, bridge: bridge, hardwarePort: hardwarePort) }
            return "The cluster port \(interface) cannot be isolated yet (\(found)): " + remedies.joined(separator: "; ") + "."
        }
        let found = findings.map { $0.fact(interface: interface, bridge: bridge) }.joined(separator: ", ")
        return "The cluster port \(interface) is not isolated (\(found)), so macOS or Internet Sharing can take its address away or route other traffic through the cable; run `darkbloom cluster` to give it its own network service with a fixed address, no router and no DNS, outside every bridge, which asks for your approval once in a macOS prompt and lasts across restarts."
    }
}
