import Foundation

/// Every tool invocation the link inspection and its fix may make to read
/// state. All are read-only and run by absolute path without a shell; none
/// takes operator-supplied text. Privileged changes are a separate type,
/// `ClusterLinkPrivilegedRequest`.
enum ClusterLinkToolCommand: Equatable, Sendable {
    case rdmaControlStatus
    case rdmaDeviceList
    /// `device` is a name already validated by `ClusterRDMAToolOutput.devices`.
    case rdmaDeviceDetail(device: String)
    case interfaceList
    case defaultRoute
    /// Whether the address keeper for this interface is loaded in launchd.
    case keeperJob(interface: String)
    /// The address keeper's job definition for this interface, as JSON.
    case keeperJobFile(interface: String)
    /// The names in the directory that holds every keeper's job definition.
    case keeperJobFileList
    // What isolating a port reads (link setup v2). All read-only as well.
    /// `networksetup -listallhardwareports`: the hardware port name of each interface.
    case hardwarePorts
    /// `networksetup -listnetworkserviceorder`: every network service, its
    /// interface and whether it is enabled.
    case networkServiceOrder
    /// One service's configuration. `service` is a name already validated by
    /// `ClusterLinkServiceName.isSafe`.
    case networkServiceInfo(service: String)
    /// The bridges macOS keeps in its network preferences and their members.
    case bridgePreferences
    /// Whether Internet Sharing is turned on (`com.apple.nat` NAT.Enabled).
    case internetSharingEnabled
    /// The devices Internet Sharing shares to (`com.apple.nat` NAT.SharingDevices).
    case internetSharingDevices
    /// `netstat -rn -f inet`: every IPv4 route, to find default routes by interface.
    case routeTable
    /// `scutil --dns`: the resolvers and the interfaces they are reached through.
    case dnsConfiguration
    /// `ipconfig getpacket <interface>`: exits 0 only when the port holds a DHCP lease.
    case dhcpPacket(interface: String)

    var executable: String {
        switch self {
        case .rdmaControlStatus: return "/usr/bin/rdma_ctl"
        case .rdmaDeviceList, .rdmaDeviceDetail: return "/usr/bin/ibv_devinfo"
        case .interfaceList: return "/sbin/ifconfig"
        case .defaultRoute: return "/sbin/route"
        case .keeperJob: return "/bin/launchctl"
        case .keeperJobFile: return "/usr/bin/plutil"
        case .keeperJobFileList: return "/bin/ls"
        case .hardwarePorts, .networkServiceOrder, .networkServiceInfo: return "/usr/sbin/networksetup"
        case .bridgePreferences, .internetSharingEnabled, .internetSharingDevices: return "/usr/bin/plutil"
        case .routeTable: return "/usr/sbin/netstat"
        case .dnsConfiguration: return "/usr/sbin/scutil"
        case .dhcpPacket: return "/usr/sbin/ipconfig"
        }
    }

    var arguments: [String] {
        switch self {
        case .rdmaControlStatus: return ["status"]
        case .rdmaDeviceList: return []
        case .rdmaDeviceDetail(let device): return ["-v", "-d", device]
        case .interfaceList: return ["-a"]
        case .defaultRoute: return ["-n", "get", "default"]
        case .keeperJob(let interface):
            return ["print", "system/" + ClusterLinkAddressKeeper.label(forInterface: interface)]
        case .keeperJobFile(let interface):
            return ["-convert", "json", "-o", "-", ClusterLinkAddressKeeper.plistPath(forInterface: interface)]
        case .keeperJobFileList: return [ClusterLinkAddressKeeper.directory]
        case .hardwarePorts: return ["-listallhardwareports"]
        case .networkServiceOrder: return ["-listnetworkserviceorder"]
        case .networkServiceInfo(let service): return ["-getinfo", service]
        case .bridgePreferences:
            return ["-extract", "VirtualNetworkInterfaces.Bridge", "json", "-o", "-", ClusterLinkIsolationPlan.networkPreferences]
        case .internetSharingEnabled:
            return ["-extract", "NAT.Enabled", "raw", "-o", "-", ClusterLinkIsolationPlan.internetSharingPreferences]
        case .internetSharingDevices:
            return ["-extract", "NAT.SharingDevices", "json", "-o", "-", ClusterLinkIsolationPlan.internetSharingPreferences]
        case .routeTable: return ["-rn", "-f", "inet"]
        case .dnsConfiguration: return ["--dns"]
        case .dhcpPacket(let interface): return ["getpacket", interface]
        }
    }
}

/// Runs one tool. The live one starts a bounded child; checks supply canned results.
typealias ClusterLinkToolRunner = (ClusterLinkToolCommand) -> ClusterLinkToolOutcome

enum ClusterLinkToolOutcome: Equatable, Sendable {
    case output(String)
    /// The tool is missing, could not be started or did not exit with status 0.
    case unavailable
    case timedOut
    case outputTooLarge
}
