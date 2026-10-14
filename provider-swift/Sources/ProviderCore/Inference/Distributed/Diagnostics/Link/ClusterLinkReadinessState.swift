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

    /// Whether the port only lacks an IPv4 address of its own, which is the one
    /// thing `darkbloom cluster link --fix` adds.
    public var fixableByAddingAddress: Bool {
        self == .portWithoutIPv4Address || self == .portBridgedWithoutAddress
    }

    /// One sentence saying what the operator can do. Darkbloom changes nothing
    /// unasked: where `cluster link --fix` can make the change after approval
    /// the sentence offers it, and everywhere else it says Darkbloom will not.
    public var guidance: String? {
        switch self {
        case .ready:
            return nil
        case .rdmaDisabled:
            return "RDMA over Thunderbolt is turned off on this Mac; an administrator must start the Mac in macOS Recovery and run `rdma_ctl enable` there (Darkbloom will not change that setting for you), then restart and run `darkbloom cluster` again."
        case .rdmaUnavailable:
            return "The macOS RDMA tools are missing or list no RDMA device, so this Mac cannot use RDMA over Thunderbolt as it is; use a Mac with Thunderbolt 5 on macOS 26.2 or later, because Darkbloom cannot add RDMA support for you."
        case .noActivePort:
            return "No Thunderbolt RDMA port is active; connect this Mac directly to the other Mac with a Thunderbolt 5 cable and wait for the port to come up, because Darkbloom cannot do that for you."
        case .portWithoutIPv4Address:
            return "The active Thunderbolt port is not set up for the cluster yet: run `darkbloom cluster` again; it fixes the port after one macOS approval, with no network setting to type."
        case .portBridgedWithoutAddress:
            return "The active Thunderbolt port belongs to the Thunderbolt Bridge and is not set up for the cluster yet: run `darkbloom cluster` again; it fixes the port after one macOS approval."
        case .gidNotPublished:
            return "The Thunderbolt cable is connected but not ready for the cluster yet: reconnect the cable, then run `darkbloom cluster` again."
        case .probeFailed:
            return "Darkbloom could not read this Mac's cable state: check the cable, restart this Mac, then run `darkbloom cluster` again."
        }
    }
}
