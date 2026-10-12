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
            return "RDMA over Thunderbolt is turned off on this Mac; an administrator must start the Mac in macOS Recovery and run `rdma_ctl enable` there, because Darkbloom will not run that command or change the setting for you."
        case .rdmaUnavailable:
            return "The macOS RDMA tools are missing or list no RDMA device, so this Mac cannot use RDMA over Thunderbolt as it is; use a Mac with Thunderbolt 5 on macOS 26.2 or later, because Darkbloom cannot add RDMA support for you."
        case .noActivePort:
            return "No Thunderbolt RDMA port is active; connect this Mac directly to the other Mac with a Thunderbolt 5 cable and wait for the port to come up, because Darkbloom cannot do that for you."
        case .portWithoutIPv4Address:
            return "The active Thunderbolt port has no IPv4 address of its own; press f in step 2 of `darkbloom cluster` (or run `darkbloom cluster link --fix`) to give it Darkbloom's own address after one approval in a macOS prompt, with no network setting to type."
        case .portBridgedWithoutAddress:
            return "The active Thunderbolt port belongs to the Thunderbolt Bridge and has no IPv4 address of its own; press f in step 2 of `darkbloom cluster` (or run `darkbloom cluster link --fix`) to take it out of the bridge with Darkbloom's own address after one approval in a macOS prompt."
        case .gidNotPublished:
            return "The active Thunderbolt port has not published the IPv4-mapped GID that cluster serving needs; reconnect the cable and look at step 2 of `darkbloom cluster` again, because Darkbloom will not change that port beyond its one approved link fix."
        case .probeFailed:
            return "Darkbloom could not read this Mac's RDMA or network interface state within its time and output limits; run `ibv_devinfo` and `ifconfig` in Terminal to see what they report, because Darkbloom will not retry with broader access or change anything for you."
        }
    }
}
