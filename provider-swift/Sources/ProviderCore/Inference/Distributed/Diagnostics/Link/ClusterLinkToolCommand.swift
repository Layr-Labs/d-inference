import Foundation

/// Every tool invocation the link inspection may make. All are read-only and
/// run by absolute path without a shell; none takes operator-supplied text.
enum ClusterLinkToolCommand: Equatable, Sendable {
    case rdmaControlStatus
    case rdmaDeviceList
    /// `device` is a name already validated by `ClusterRDMAToolOutput.devices`.
    case rdmaDeviceDetail(device: String)
    case interfaceList

    var executable: String {
        switch self {
        case .rdmaControlStatus: return "/usr/bin/rdma_ctl"
        case .rdmaDeviceList, .rdmaDeviceDetail: return "/usr/bin/ibv_devinfo"
        case .interfaceList: return "/sbin/ifconfig"
        }
    }

    var arguments: [String] {
        switch self {
        case .rdmaControlStatus: return ["status"]
        case .rdmaDeviceList: return []
        case .rdmaDeviceDetail(let device): return ["-v", "-d", device]
        case .interfaceList: return ["-a"]
        }
    }
}

enum ClusterLinkToolOutcome: Equatable, Sendable {
    case output(String)
    /// The tool is missing, could not be started or did not exit with status 0.
    case unavailable
    case timedOut
    case outputTooLarge
}
