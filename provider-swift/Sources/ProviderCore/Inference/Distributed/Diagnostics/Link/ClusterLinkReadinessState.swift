import Foundation

/// Stable machine-readable result of a local link inspection, used both for
/// one RDMA device and for the Mac as a whole. Raw values are an output
/// contract; add cases rather than renaming them.
public enum ClusterLinkReadinessState: String, Encodable, Sendable, CaseIterable {
    /// An active port publishes the IPv4-mapped GID that JACCL requires.
    case ready
    case rdmaDisabled
    /// The macOS RDMA tools are missing or report no RDMA device.
    case rdmaUnavailable
    case noActivePort
    case portWithoutIPv4Address
    case portBridgedWithoutAddress
    /// The port has an IPv4 address, yet no IPv4-mapped GID is published.
    case gidNotPublished
    /// A tool timed out, overflowed its output bound or printed unrecognized text.
    case probeFailed

    /// One sentence saying what the operator must change. Darkbloom never
    /// changes it for them, so every sentence says so.
    public var guidance: String? {
        switch self {
        case .ready:
            return nil
        case .rdmaDisabled:
            return "RDMA over Thunderbolt is turned off on this Mac; an administrator must start the Mac in macOS Recovery and run `rdma_ctl enable` there, because Darkbloom will not run that command or change the setting for you."
        case .rdmaUnavailable:
            return "The macOS RDMA tools are missing or list no RDMA device, so this Mac cannot use RDMA over Thunderbolt as it is; use a Mac with Thunderbolt 5 on macOS 26.2 or later, because Darkbloom cannot add RDMA support for you."
        case .noActivePort:
            return "No Thunderbolt RDMA port is active; connect this Mac directly to the other Mac with a Thunderbolt 5 cable and wait for the port to come up, because Darkbloom will not change cabling or network settings for you."
        case .portWithoutIPv4Address:
            return "The active Thunderbolt port has no IPv4 address of its own; give that port an IPv4 address in System Settings → Network, because Darkbloom will not change network settings for you."
        case .portBridgedWithoutAddress:
            return "The active Thunderbolt port belongs to the Thunderbolt Bridge and has no IPv4 address of its own; give that port its own IPv4 address in System Settings → Network or remove it from the bridge, because Darkbloom will not change network settings for you."
        case .gidNotPublished:
            return "The active Thunderbolt port has not published the IPv4-mapped GID that cluster serving needs; check that port's IPv4 configuration in System Settings → Network and reconnect the cable, because Darkbloom will not change network settings for you."
        case .probeFailed:
            return "Darkbloom could not read this Mac's RDMA or network interface state within its time and output limits; run `ibv_devinfo` and `ifconfig` in Terminal to see what they report, because Darkbloom will not retry with broader access or change anything for you."
        }
    }
}
