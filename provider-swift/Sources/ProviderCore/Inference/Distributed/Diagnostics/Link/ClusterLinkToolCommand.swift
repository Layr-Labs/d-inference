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

    var executable: String {
        switch self {
        case .rdmaControlStatus: return "/usr/bin/rdma_ctl"
        case .rdmaDeviceList, .rdmaDeviceDetail: return "/usr/bin/ibv_devinfo"
        case .interfaceList: return "/sbin/ifconfig"
        case .defaultRoute: return "/sbin/route"
        case .keeperJob: return "/bin/launchctl"
        case .keeperJobFile: return "/usr/bin/plutil"
        case .keeperJobFileList: return "/bin/ls"
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
