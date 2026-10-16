import Foundation
import DarkbloomClusterRemote
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// A fixed interface table: the Thunderbolt ports a check says exist, and nothing else.
    struct CablePortTable: ClusterLinkInterfaceInspecting {
        let ports: [String: ClusterLinkInterfaceFacts]
        func facts(forInterface name: String) throws -> ClusterLinkInterfaceFacts {
            guard let facts = ports[name] else { throw ClusterSetupFailure("no interface \(name)") }
            return facts
        }
    }

    /// The cable moved to another Thunderbolt port (owner pair, 2026-10-15: en3, then en1, then en2): a cluster service
    /// listener started on the old port is started again on the new one, and only then. Failing first on 06fe95998
    /// (no such rule: the listeners stayed on the port they started on, and the Macs stopped reaching each other).
    static func cableMovesToAnotherPort() throws {
        func port(_ name: String, _ index: UInt32, _ address: String) throws -> ClusterLinkInterfaceSelection {
            let facts = ClusterLinkInterfaceFacts(name: name, index: index, kind: .thunderbolt, bridgeMembers: nil,
                addresses: [.init(address: ClusterLinkIPv4Address(address)!, netmask: 0xFFFF_0000)])
            return try ClusterLinkInterfaceAdmission.select(interface: name, localAddress: nil, peerAddress: nil,
                policy: .thunderboltOnly, inspector: CablePortTable(ports: [name: facts]))
        }
        typealias X = ClusterSetupLinkExchange
        let first = try port("en1", 11, "10.219.1.2"), moved = try port("en2", 12, "10.219.1.2")
        let readdressed = try port("en1", 11, "10.219.7.2")
        expect(!X.cableMoved(bound: first, current: try port("en1", 11, "10.219.1.2")), "the same port and address: kept")
        expect(X.cableMoved(bound: first, current: moved), "another port: started again there")
        expect(X.cableMoved(bound: first, current: readdressed), "the same port with another address: started again")
        expect(!X.cableMoved(bound: first, current: nil), "no cable now: kept (it may come back on the same port)")
        expect(!X.cableMoved(bound: nil, current: moved), "no listener yet: nothing to move")
    }
}
