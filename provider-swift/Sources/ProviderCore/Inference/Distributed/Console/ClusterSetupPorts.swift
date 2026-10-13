import Foundation
import Darwin
import DarkbloomClusterRemote

/// The ports a guided-flow setup names, chosen on the Mac that will listen on
/// them instead of fixed: the conventional port when it is free on this Mac's
/// link address, else a free one the kernel gives. The leader listens on both
/// (the native ranks meet on the coordinator port; the follower's link edge
/// connects to the link control port), so the choice is made on the leader;
/// a plan that makes the other Mac lead keeps the conventional ports
/// (`ClusterSetupPlanning`). The discovery ports of pairing and of the setup
/// exchange stay well-known: they are how two Macs find each other before
/// anything can be agreed.
enum ClusterSetupPorts {
    /// The conventional ports, tried first.
    static let conventionalCoordinator: UInt16 = 52_420
    static var conventionalLinkControl: UInt16 { ClusterLinkControlListener.defaultPort }

    struct Choice: Equatable, Sendable {
        let coordinator: UInt16
        let linkControl: UInt16
        static var conventional: Choice { .init(coordinator: conventionalCoordinator, linkControl: conventionalLinkControl) }
    }

    /// Both ports for a leader whose link address is `address`; the
    /// conventional ones when the address cannot be probed.
    static func choose(linkAddress address: String, probe: (UInt16, String, Set<UInt16>) -> UInt16? = freeTCPPort) -> Choice {
        guard let coordinator = probe(conventionalCoordinator, address, []) else { return .conventional }
        let linkControl = probe(conventionalLinkControl, address, [coordinator]) ?? conventionalLinkControl
        return .init(coordinator: coordinator, linkControl: linkControl)
    }

    /// `preferred` when a TCP socket can bind it on `address` now, else a port
    /// the kernel assigns there (not in `avoid`); nil when `address` is not an
    /// IPv4 address of this Mac. The probe socket is closed before returning.
    static func freeTCPPort(preferred: UInt16, address: String, avoid: Set<UInt16>) -> UInt16? {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else { return nil }
        func bound(_ port: UInt16) -> UInt16? {
            let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else { return nil }
            defer { close(socketDescriptor) }
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.bigEndian
            socketAddress.sin_addr = target
            let result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { return nil }
            var assigned = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
            }
            return named == 0 ? UInt16(bigEndian: assigned.sin_port) : nil
        }
        if !avoid.contains(preferred), let port = bound(preferred) { return port }
        for _ in 0..<4 {
            if let port = bound(0), !avoid.contains(port) { return port }
        }
        return nil
    }
}
