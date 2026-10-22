import Foundation
import Darwin
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// The guided flow's setups name ports chosen on the leader: the
    /// conventional ones when free, else free ones the kernel gives; never a
    /// fixed number that may be taken.
    static func wizardPorts() throws {
        expectEqual(ClusterSetupPorts.choose(linkAddress: "192.0.2.9") { preferred, _, _ in preferred }, .conventional,
                    "free conventional ports are kept")
        expectEqual(ClusterSetupPorts.choose(linkAddress: "not-an-address"), .conventional,
                    "an address that cannot be probed keeps the conventional ports")
        // Hold a port on the loopback address: the probe moves off it, to a port that binds.
        let held = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(held) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(held, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(held, $0, &length) } }
        let taken = UInt16(bigEndian: address.sin_port)
        expect(bound == 0 && taken != 0, "the check holds a loopback port")
        let moved = ClusterSetupPorts.freeTCPPort(preferred: taken, address: "127.0.0.1", avoid: [])
        expect(moved != nil && moved != taken, "a taken port is replaced by a free one: \(String(describing: moved)) for \(taken)")
        if let moved { expect(ClusterSetupPorts.freeTCPPort(preferred: moved, address: "127.0.0.1", avoid: []) == moved, "the replacement binds") }
        let avoided = ClusterSetupPorts.freeTCPPort(preferred: 52_420, address: "127.0.0.1", avoid: [52_420])
        expect(avoided != nil && avoided != 52_420, "a port already chosen for the other listener is not chosen again")
        // The two ports of one choice differ even when the probe would hand out the same one.
        let choice = ClusterSetupPorts.choose(linkAddress: "127.0.0.1") { preferred, _, avoid in avoid.contains(preferred) ? preferred &+ 1 : preferred }
        expect(choice.coordinator != choice.linkControl, "one setup's two listeners never share a port")
    }
}
