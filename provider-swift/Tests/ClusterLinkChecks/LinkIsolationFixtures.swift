import Foundation

/// What link setup v2 reads, as canned tool results. Default: every tool is
/// unavailable, which a first-version check never asks for anyway.
struct FakeIsolationTools {
    var hardwarePorts = ClusterLinkToolOutcome.unavailable
    var serviceOrder = ClusterLinkToolOutcome.unavailable
    var serviceInfo: [String: ClusterLinkToolOutcome] = [:]
    var bridgePreferences = ClusterLinkToolOutcome.unavailable
    var sharingEnabled = ClusterLinkToolOutcome.unavailable
    var sharingDevices = ClusterLinkToolOutcome.unavailable
    var routes = ClusterLinkToolOutcome.unavailable
    var dns = ClusterLinkToolOutcome.unavailable
    var dhcpPackets: [String: ClusterLinkToolOutcome] = [:]
    /// `NetworkServices`, `CurrentSet` and the set's IPv4 order from the network preferences (a removal of a port's
    /// only service reads them).
    var servicePreferences = ClusterLinkToolOutcome.unavailable
    var currentSet = ClusterLinkToolOutcome.unavailable
    var serviceOrderPreferences: [String: ClusterLinkToolOutcome] = [:]
}

/// Tool text captured on the two Macs on 2026-10-09 with read-only commands
/// (evidence/link-v2-20261009/captures), shortened, with every address
/// replaced by a documentation placeholder (192.0.2.0/24 for Wi-Fi,
/// 198.51.100.0/24 for Internet Sharing's subnet on the cable, 203.0.113.0/24
/// for name servers, 2001:db8::/32) and every MAC address by 02:00:5e:00:53:xx.
/// Two service names of the owner's earlier tools are renamed. The cluster
/// addresses are the ones derived for the made-up machine value of the
/// first version's fixtures.
enum IsolationFixtures {
    static let machine = FakeRepairWorld.machine
    static let macAAddress = ClusterLinkClusterAddress.derived(machineIdentifier: machine, interface: "en7")
    static let macBAddress = ClusterLinkClusterAddress.derived(machineIdentifier: machine, interface: "en6")
    /// The first version's address on Mac B's port (its keeper puts it back).
    static let macBLinkLocal = FakeRepairWorld.en6Address
    static let sharingIPv4 = "198.51.100.1"
    static let macALeaseIPv4 = "198.51.100.7"

    // MARK: networksetup

    static let macAHardwarePorts = """

        Hardware Port: Ethernet
        Device: en0
        Ethernet Address: 02:00:5e:00:53:00

        Hardware Port: Ethernet Adapter (en8)
        Device: en8
        Ethernet Address: 02:00:5e:00:53:08

        Hardware Port: Wi-Fi
        Device: en1
        Ethernet Address: 02:00:5e:00:53:01

        Hardware Port: Thunderbolt 1
        Device: en2
        Ethernet Address: 02:00:5e:00:53:02

        Hardware Port: Thunderbolt 2
        Device: en3
        Ethernet Address: 02:00:5e:00:53:03

        Hardware Port: Thunderbolt 3
        Device: en4
        Ethernet Address: 02:00:5e:00:53:04

        Hardware Port: Thunderbolt 4
        Device: en5
        Ethernet Address: 02:00:5e:00:53:05

        Hardware Port: Thunderbolt 5
        Device: en6
        Ethernet Address: 02:00:5e:00:53:06

        Hardware Port: Thunderbolt 6
        Device: en7
        Ethernet Address: 02:00:5e:00:53:07

        VLAN Configurations
        ===================

        """

    static let macBHardwarePorts = """

        Hardware Port: Ethernet Adapter (en3)
        Device: en3
        Ethernet Address: 02:00:5e:00:53:13

        Hardware Port: USB 10/100/1000 LAN
        Device: en10
        Ethernet Address: 02:00:5e:00:53:1a

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 02:00:5e:00:53:20

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 02:00:5e:00:53:10

        Hardware Port: Thunderbolt 1
        Device: en1
        Ethernet Address: 02:00:5e:00:53:11

        Hardware Port: Thunderbolt 2
        Device: en6
        Ethernet Address: 02:00:5e:00:53:16

        Hardware Port: Thunderbolt 3
        Device: en2
        Ethernet Address: 02:00:5e:00:53:12

        VLAN Configurations
        ===================

        """

    /// One `-listnetworkserviceorder` entry.
    static func service(_ number: Int?, _ name: String, port: String, device: String) -> String {
        "(\(number.map(String.init) ?? "*")) \(name)\n(Hardware Port: \(port), Device: \(device))\n\n"
    }

    static let serviceOrderHeader = "An asterisk (*) denotes that a network service is disabled.\n"

    /// Mac A: one service per Thunderbolt port, including the cable's port en7 (DHCP).
    static func macAServiceOrder(thunderbolt6Enabled: Bool = true, clusterService: Bool = false) -> String {
        serviceOrderHeader + service(1, "Ethernet", port: "Ethernet", device: "en0")
            + service(2, "Wi-Fi", port: "Wi-Fi", device: "en1")
            + service(3, "Earlier Cluster Bridge", port: "Thunderbolt 3", device: "en4")
            + service(4, "Thunderbolt 1", port: "Thunderbolt 1", device: "en2")
            + service(5, "Thunderbolt 2", port: "Thunderbolt 2", device: "en3")
            + service(6, "Thunderbolt 3", port: "Thunderbolt 3", device: "en4")
            + service(7, "Earlier Cluster Link", port: "Thunderbolt 4", device: "en5")
            + service(8, "Thunderbolt 5", port: "Thunderbolt 5", device: "en6")
            + service(thunderbolt6Enabled ? 9 : nil, "Thunderbolt 6", port: "Thunderbolt 6", device: "en7")
            + service(10, "iPhone USB", port: "iPhone USB", device: "en15")
            + service(11, "Tailscale", port: "io.tailscale.ipn.macsys", device: "")
            + (clusterService ? service(12, "Darkbloom Cluster Link (en7)", port: "Thunderbolt 6", device: "en7") : "")
    }

    /// Mac B: the Thunderbolt ports have no services of their own; the bridge has one.
    static func macBServiceOrder(clusterService: Bool = false) -> String {
        serviceOrderHeader + service(1, "USB Dock", port: "USB Dock", device: "en8")
            + service(2, "USB 10/100/1000 LAN", port: "USB 10/100/1000 LAN", device: "en10")
            + service(3, "Thunderbolt Bridge", port: "Thunderbolt Bridge", device: "bridge0")
            + service(4, "Wi-Fi", port: "Wi-Fi", device: "en0")
            + service(5, "iPhone USB", port: "iPhone USB", device: "en9")
            + service(6, "Tailscale", port: "io.tailscale.ipn.macos", device: "")
            + service(7, "Tailscale 2", port: "io.tailscale.ipn.macsys", device: "")
            + (clusterService ? service(8, "Darkbloom Cluster Link (en6)", port: "Thunderbolt 2", device: "en6") : "")
    }

    /// `networksetup -getinfo "Thunderbolt 6"` on Mac A: DHCP from the other Mac.
    static let dhcpServiceInfo = """
        DHCP Configuration
        IP address: \(macALeaseIPv4)
        Subnet mask: 255.255.255.0
        Router: \(sharingIPv4)
        Client ID:
        IPv6: Automatic
        IPv6 IP address: none
        IPv6 Router: none
        Ethernet Address: 02:00:5e:00:53:07

        """

    /// `networksetup -getinfo` of a manual service, as Darkbloom writes it.
    static func manualServiceInfo(address: String, mask: String = "255.255.0.0", router: String = "(null)",
                                  ipv6: String = "Link Local") -> String {
        """
        Manual Configuration
        IP address: \(address)
        Subnet mask: \(mask)
        Router: \(router)
        IPv6: \(ipv6)
        IPv6 IP address: none
        IPv6 Router: none
        Ethernet Address: 02:00:5e:00:53:07

        """
    }

    // MARK: plutil

    static let macBBridgePreferences = "{\"bridge0\":{\"Options\":{\"__AUTO__\":\"thunderbolt-bridge\"},\"Interfaces\":[\"en1\",\"en6\",\"en2\"]}}\n"
    static let macBBridgePreferencesWithoutPort = "{\"bridge0\":{\"Options\":{\"__AUTO__\":\"thunderbolt-bridge\"},\"Interfaces\":[\"en1\",\"en2\"]}}\n"
    /// Mac A's Thunderbolt Bridge was deleted long ago.
    static let emptyBridgePreferences = "{}\n"
    /// Internet Sharing's devices on Mac B: three that no longer exist, the
    /// cluster port itself and the Thunderbolt Bridge.
    static let macBSharingDevices = "[\"en7\",\"en14\",\"en6\",\"bridge0\",\"en12\"]\n"
    /// After the owner turned off the cluster port under Internet Sharing.
    static let macBSharingDevicesWithoutPort = "[\"en7\",\"en14\",\"bridge0\",\"en12\"]\n"

    // MARK: netstat, scutil, ipconfig

    static func routeTable(_ rows: [String]) -> String {
        """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        \(rows.joined(separator: "\n"))

        """
    }

    static let macARoutes = routeTable([
        "default            192.0.2.1          UGScg                 en1       ",
        "default            \(sharingIPv4)       UGScIg                en7       ",
        "default            link#33            UCSIg               utun4       ",
        "100.64/10          link#33            UCS                 utun4       ",
        "127                127.0.0.1          UCS                   lo0       ",
        "169.254            link#25            UCS                   en1      !",
        "169.254            link#22            UCSI                  en7      !",
        "192.0.2            link#25            UCS                   en1      !",
        "198.51.100         link#22            UCS                   en7      !",
        "198.51.100.1/32    link#22            UCS                   en7      !",
        "224.0.0/4          link#22            UmCSI                 en7      !",
    ])

    static func macAIsolatedRoutes(address: String) -> String {
        routeTable([
            "default            192.0.2.1          UGScg                 en1       ",
            "default            link#33            UCSIg               utun4       ",
            "100.64/10          link#33            UCS                 utun4       ",
            "127                127.0.0.1          UCS                   lo0       ",
            "10.219             link#22            UCS                   en7      !",
            "\(address)/32      link#22            UCS                   en7      !",
            "169.254            link#25            UCS                   en1      !",
            "192.0.2            link#25            UCS                   en1      !",
        ])
    }

    static let macBRoutes = routeTable([
        "default            192.0.2.1          UGScg                 en0       ",
        "default            link#13            UCSIg             bridge0      !",
        "default            link#23            UCSIg               utun2       ",
        "100.64/10          link#23            UCS                 utun2       ",
        "169.254            link#15            UCS                   en0      !",
        "169.254            link#13            UCSI              bridge0      !",
        "198.51.100         link#13            UC                bridge0      !",
        "192.0.2            link#15            UCS                   en0      !",
    ])

    static func macBIsolatedRoutes(address: String) -> String {
        routeTable([
            "default            192.0.2.1          UGScg                 en0       ",
            "default            link#13            UCSIg             bridge0      !",
            "10.219             link#11            UCS                   en6      !",
            "\(address)/32      link#11            UCS                   en6      !",
            "169.254            link#15            UCS                   en0      !",
            "198.51.100         link#13            UC                bridge0      !",
            "192.0.2            link#15            UCS                   en0      !",
        ])
    }

    static func resolver(_ number: Int, servers: [String], interface: String?, scoped: Bool) -> String {
        var lines = ["resolver #\(number)"]
        lines += servers.enumerated().map { "  nameserver[\($0)] : \($1)" }
        if let interface { lines.append("  if_index : \(number + 20) (\(interface))") }
        lines.append("  flags    : \(scoped ? "Scoped, " : "")Request A records, Request AAAA records")
        lines.append("  reach    : 0x00000002 (Reachable)")
        return lines.joined(separator: "\n") + "\n\n"
    }

    static let mdnsResolver = """
        resolver #2
          domain   : local
          options  : mdns
          timeout  : 5
          flags    : Request A records, Request AAAA records
          reach    : 0x00000000 (Not Reachable)
          order    : 300000


        """

    /// Mac A: the scoped resolver through en7 is the other Mac's Internet
    /// Sharing, by router advertisement (IPv6) and DHCP (IPv4).
    static func macADNS(viaPort: Bool = true) -> String {
        "DNS configuration\n\n" + resolver(1, servers: ["2001:db8::1", "203.0.113.53"], interface: "en1", scoped: false)
            + mdnsResolver + "DNS configuration (for scoped queries)\n\n"
            + resolver(1, servers: ["2001:db8::1", "203.0.113.53"], interface: "en1", scoped: true)
            + (viaPort ? resolver(2, servers: ["fe80::200:5eff:fe00:5316%en7", sharingIPv4], interface: "en7", scoped: true) : "")
            + resolver(3, servers: ["2001:db8::53", "100.100.100.100"], interface: "utun4", scoped: true)
    }

    static let macBDNS = "DNS configuration\n\n" + resolver(1, servers: ["2001:db8::1", "203.0.113.53"], interface: "en0", scoped: false)
        + mdnsResolver + "DNS configuration (for scoped queries)\n\n"
        + resolver(1, servers: ["fd00:db8::1"], interface: "bridge0", scoped: true)
        + resolver(2, servers: ["2001:db8::1", "203.0.113.53"], interface: "en0", scoped: true)

    /// `ipconfig getpacket en7` on Mac A: the lease from the other Mac.
    static let macALeasePacket = """
        op = BOOTREPLY
        htype = 1
        flags = 0x0
        hlen = 6
        hops = 0
        xid = 0x1
        secs = 0
        ciaddr = \(macALeaseIPv4)
        yiaddr = \(macALeaseIPv4)
        siaddr = 0.0.0.0
        giaddr = 0.0.0.0
        chaddr = 02:00:5e:00:53:07
        sname = peer.local
        file =
        options:
        Options count is 7
        dhcp_message_type (uint8): ACK 0x5
        server_identifier (ip): \(sharingIPv4)
        lease_time (uint32): 0xe10
        subnet_mask (ip): 255.255.255.0
        router (ip_mult): {\(sharingIPv4)}
        domain_name_server (ip_mult): {\(sharingIPv4)}
        end (none):

        """

    // MARK: ifconfig

    /// `ifconfig <port>` with any number of IPv4 addresses (/16 for the
    /// cluster subnet and link-local, /24 otherwise).
    static func port(_ name: String, active: Bool, addresses: [String]) -> String {
        var lines = ["\(name): flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500",
            "\toptions=460<TSO4,TSO6,CHANNEL_IO>", "\tether \(LinkFixtures.mac)"]
        if active { lines.append("\tinet6 \(LinkFixtures.linkLocalIPv6)%\(name) prefixlen 64 secured scopeid 0x16 ") }
        for address in addresses {
            let wide = address.hasPrefix("10.219.") || address.hasPrefix("169.254.")
            lines.append("\tinet \(address) netmask \(wide ? "0xffff0000" : "0xffffff00") broadcast 192.0.2.255")
        }
        lines += ["\tnd6 options=201<PERFORMNUD,DAD>", "\tmedia: autoselect <full-duplex>", "\tstatus: \(active ? "active" : "inactive")"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func macAInterfaces(en7: [String]) -> String {
        LinkFixtures.loopback + port("en0", active: false, addresses: []) + port("en1", active: true, addresses: [LinkFixtures.wifiIPv4])
            + (2...6).map { port("en\($0)", active: false, addresses: []) }.joined() + port("en7", active: true, addresses: en7)
    }

    static func macBInterfaces(en6: [String], bridgeMembers: [String]) -> String {
        LinkFixtures.loopback + port("en0", active: true, addresses: [LinkFixtures.wifiIPv4])
            + port("en1", active: false, addresses: []) + port("en2", active: false, addresses: [])
            + port("en6", active: true, addresses: en6) + LinkFixtures.bridge(members: bridgeMembers)
    }

    static let macBDevices = ["rdma_en1", "rdma_en6", "rdma_en2"]

    // MARK: whole Macs

    /// Mac A as captured: ready on Internet Sharing's DHCP address.
    static var macA: FakeLinkTools {
        var tools = FakeLinkTools(deviceList: .output(LinkFixtures.deviceList(active: "rdma_en7")),
            interfaces: .output(macAInterfaces(en7: [macALeaseIPv4])),
            details: ["rdma_en7": .output(LinkFixtures.detailWithMappedGID("rdma_en7"))])
        tools.isolation = FakeIsolationTools(hardwarePorts: .output(macAHardwarePorts),
            serviceOrder: .output(macAServiceOrder()), serviceInfo: ["Thunderbolt 6": .output(dhcpServiceInfo)],
            bridgePreferences: .output(emptyBridgePreferences),
            // No com.apple.nat file on Mac A: plutil exits non-zero.
            sharingEnabled: .unavailable, sharingDevices: .unavailable,
            routes: .output(macARoutes), dns: .output(macADNS()), dhcpPackets: ["en7": .output(macALeasePacket)])
        return tools
    }

    /// Mac A once the approval ran: its own service, the DHCP service off.
    static func macAIsolated(address: ClusterLinkClusterAddress = macAAddress) -> FakeLinkTools {
        var tools = macA
        tools.interfaces = .output(macAInterfaces(en7: [address.dottedDecimal]))
        tools.isolation.serviceOrder = .output(macAServiceOrder(thunderbolt6Enabled: false, clusterService: true))
        tools.isolation.serviceInfo["Darkbloom Cluster Link (en7)"] = .output(manualServiceInfo(address: address.dottedDecimal))
        tools.isolation.routes = .output(macAIsolatedRoutes(address: address.dottedDecimal))
        tools.isolation.dns = .output(macADNS(viaPort: false))
        tools.isolation.dhcpPackets = [:]
        return tools
    }

    /// Mac B as captured: the port in the Thunderbolt Bridge, Internet Sharing
    /// over the bridge and to the port, the first version's keeper running.
    static var macB: FakeLinkTools {
        var tools = FakeLinkTools(deviceList: .output(macBDevices.map { LinkFixtures.deviceBlock($0, active: $0 == "rdma_en6") }.joined()),
            interfaces: .output(macBInterfaces(en6: [macBLinkLocal], bridgeMembers: ["en1", "en6", "en2"])),
            details: ["rdma_en6": .output(LinkFixtures.detailWithMappedGID("rdma_en6"))])
        tools.installKeeper(interface: "en6", address: macBLinkLocal)
        tools.isolation = FakeIsolationTools(hardwarePorts: .output(macBHardwarePorts), serviceOrder: .output(macBServiceOrder()),
            bridgePreferences: .output(macBBridgePreferences), sharingEnabled: .output("1\n"),
            sharingDevices: .output(macBSharingDevices), routes: .output(macBRoutes), dns: .output(macBDNS),
            dhcpPackets: [:])
        return tools
    }

    /// Mac B after the owner turned the cluster port off under Internet Sharing.
    static var macBUnshared: FakeLinkTools {
        var tools = macB
        tools.isolation.sharingDevices = .output(macBSharingDevicesWithoutPort)
        return tools
    }

    /// Mac B once the approval ran: out of the bridge, own service, keeper gone.
    static func macBIsolated(address: ClusterLinkClusterAddress = macBAddress) -> FakeLinkTools {
        var tools = macBUnshared
        tools.interfaces = .output(macBInterfaces(en6: [address.dottedDecimal], bridgeMembers: ["en1", "en2"]))
        tools.keeperJobs = [:]
        tools.keeperJobFiles = [:]
        tools.isolation.serviceOrder = .output(macBServiceOrder(clusterService: true))
        tools.isolation.serviceInfo["Darkbloom Cluster Link (en6)"] = .output(manualServiceInfo(address: address.dottedDecimal))
        tools.isolation.bridgePreferences = .output(macBBridgePreferencesWithoutPort)
        tools.isolation.routes = .output(macBIsolatedRoutes(address: address.dottedDecimal))
        // Darkbloom's service is the only one on Thunderbolt 2 (the ports start in the bridge): its ID in the preferences.
        tools.isolation.servicePreferences = .output(servicePreferences([(serviceID("e6"), "Darkbloom Cluster Link (en6)", "en6"),
                                                                         (serviceID("b0"), "Thunderbolt Bridge", "bridge0")]))
        tools.isolation.currentSet = .output("/Sets/\(networkSet)\n")
        tools.isolation.serviceOrderPreferences[networkSet] = .output("[\"\(serviceID("b0"))\",\"\(serviceID("e6"))\"]")
        return tools
    }

    /// The network set and service IDs of the fixtures' preferences.
    static let networkSet = "D8185C32-7BC9-46CB-BDF8-FB71374DDB40"
    static func serviceID(_ tag: String) -> String { "00000000-0000-4000-8000-0000000000" + tag.uppercased() }

    /// `plutil -extract NetworkServices json` for these services.
    static func servicePreferences(_ services: [(id: String, name: String, device: String)]) -> String {
        "{" + services.map { "\"\($0.id)\":{\"UserDefinedName\":\"\($0.name)\",\"Interface\":{\"DeviceName\":\"\($0.device)\",\"Type\":\"Ethernet\"}}" }
            .joined(separator: ",") + "}"
    }

    // MARK: three isolated Macs after pairing

    /// An isolated Mac captured read-only on 2026-11-03 after its port paired
    /// and carried traffic. `routes` are the captured `netstat -rn -f inet`
    /// rows for the default routes, the cluster subnet and the loopback, the
    /// port carries its captured cluster address and the service order is the
    /// captured one where there is one; MAC addresses, the Wi-Fi gateway and
    /// its address are placeholders. The rest of each Mac is what Darkbloom
    /// leaves on an isolated port.
    struct PairedMac {
        let name: String
        let port: String
        let address: String
        let hardwarePort: String
        let wifi: String
        let devices: [String]
        let otherPorts: [String]
        let bridgeMembers: [String]
        let routes: [String]
        let serviceOrder: String

        var device: String { ClusterLinkName.device(ofInterface: port) }

        var interfaceListing: String {
            LinkFixtures.loopback + IsolationFixtures.port(wifi, active: true, addresses: [LinkFixtures.wifiIPv4])
                + otherPorts.map { IsolationFixtures.port($0, active: false, addresses: []) }.joined()
                + IsolationFixtures.port(port, active: true, addresses: [address])
                + (bridgeMembers.isEmpty ? "" : LinkFixtures.bridge(members: bridgeMembers))
        }

        func tools(extraRoutes: [String] = [], extraInterfaces: String = "") -> FakeLinkTools {
            var tools = FakeLinkTools(
                deviceList: .output(devices.map { LinkFixtures.deviceBlock($0, active: $0 == device) }.joined()),
                interfaces: .output(interfaceListing + extraInterfaces),
                details: [device: .output(LinkFixtures.detailWithMappedGID(device))])
            let bridges = bridgeMembers.isEmpty ? IsolationFixtures.emptyBridgePreferences
                : "{\"bridge0\":{\"Interfaces\":[\(bridgeMembers.map { "\"\($0)\"" }.joined(separator: ","))]}}\n"
            tools.isolation = FakeIsolationTools(hardwarePorts: .output("Hardware Port: \(hardwarePort)\nDevice: \(port)\n"),
                serviceOrder: .output(serviceOrder),
                serviceInfo: [ClusterLinkServiceName.cluster(interface: port): .output(IsolationFixtures.manualServiceInfo(address: address))],
                bridgePreferences: .output(bridges), routes: .output(IsolationFixtures.routeTable(routes + extraRoutes)),
                dns: .output("DNS configuration\n\n" + IsolationFixtures.resolver(1, servers: ["192.0.2.1"], interface: wifi, scoped: false)))
            // Darkbloom's services in the preferences, each the only one on its port (pair-2's MacBook).
            let ours = ([port] + otherPorts).map { (id: IsolationFixtures.serviceID("a" + String($0.last!)), name: ClusterLinkServiceName.cluster(interface: $0), device: $0) }
            tools.isolation.servicePreferences = .output(IsolationFixtures.servicePreferences(ours))
            tools.isolation.currentSet = .output("/Sets/\(IsolationFixtures.networkSet)\n")
            tools.isolation.serviceOrderPreferences[IsolationFixtures.networkSet] = .output("[\"\(IsolationFixtures.serviceID("f0"))\","
                + ours.map { "\"\($0.id)\"" }.joined(separator: ",") + "]")
            return tools
        }
    }

    /// `ifconfig` of a VPN tunnel with one IPv4 address.
    static func tunnel(_ name: String, address: String) -> String {
        "\(name): flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n\tinet \(address) --> \(address) netmask 0xffffffff\n"
            + "\tnd6 options=201<PERFORMNUD,DAD>\n"
    }

    /// Mac A, port en3, paired with 10.219.165.133. macOS reaches its own
    /// address through `lo0`, as it does the Wi-Fi address.
    static let pairedMacA = PairedMac(name: "Mac A", port: "en3", address: "10.219.13.112", hardwarePort: "Thunderbolt 3",
        wifi: "en1", devices: ["rdma_en2", "rdma_en13", "rdma_en3", "rdma_en4", "rdma_en5", "rdma_en6"],
        otherPorts: ["en2", "en13", "en4", "en5", "en6"], bridgeMembers: ["en2", "en13", "en5", "en6"],
        routes: [
            "default            192.0.2.1          UGScg                 en1       ",
            "default            link#38            UCSIg               utun8       ",
            "10.219/16          link#19            UCS                   en3      !",
            "10.219.13.112/32   link#19            UCS                   en3      !",
            "10.219.13.112      0:0:5e:0:53:3      UHLWIi                lo0       ",
            "10.219.165.133     0:0:5e:0:53:33     UHLWIi                en3   1150",
            "10.219.255.255     ff:ff:ff:ff:ff:ff  UHLWbI                en3      !",
            "127                127.0.0.1          UCS                   lo0       ",
            "127.0.0.1          127.0.0.1          UH                    lo0       ",
            "\(LinkFixtures.wifiIPv4)         0:0:5e:0:53:1      UHLWI                 lo0       ",
        ],
        serviceOrder: serviceOrderHeader + service(1, "Ethernet", port: "Ethernet", device: "en0")
            + service(2, "USB 10/100/1000 LAN", port: "USB 10/100/1000 LAN", device: "en14")
            + service(3, "Thunderbolt Bridge", port: "Thunderbolt Bridge", device: "bridge0")
            + service(4, "Wi-Fi", port: "Wi-Fi", device: "en1")
            + service(5, "Darkbloom Cluster Link (en4)", port: "Thunderbolt 4", device: "en4")
            + service(6, "Darkbloom Cluster Link (en3)", port: "Thunderbolt 3", device: "en3")
            + service(7, "Tailscale", port: "io.tailscale.ipn.macsys", device: ""))

    /// The M5 Max, port en6, paired with the M3 Ultra. Darkbloom's services
    /// on en1 and en2 are left from earlier cables; those ports are down.
    static let pairedM5Max = PairedMac(name: "M5 Max", port: "en6", address: "10.219.129.164", hardwarePort: "Thunderbolt 2",
        wifi: "en0", devices: ["rdma_en1", "rdma_en6", "rdma_en2"], otherPorts: ["en1", "en2"], bridgeMembers: [],
        routes: [
            "default            192.0.2.1          UGScg                 en0       ",
            "default            link#40            UCSIg              utun15       ",
            "10.219/16          link#11            UCS                   en6      !",
            "10.219.21.80       0:0:5e:0:53:26     UHLWIi                en6   1128",
            "10.219.129.164/32  link#11            UCS                   en6      !",
            "10.219.129.164     0:0:5e:0:53:16     UHLWI                 lo0       ",
            "10.219.255.255     ff:ff:ff:ff:ff:ff  UHLWbI                en6      !",
            "127                127.0.0.1          UCS                   lo0       ",
            "127.0.0.1          127.0.0.1          UH                    lo0       ",
        ],
        serviceOrder: serviceOrderHeader + service(1, "Dell D3100 USB3.0 Dock", port: "Dell D3100 USB3.0 Dock", device: "en8")
            + service(2, "USB 10/100/1000 LAN", port: "USB 10/100/1000 LAN", device: "en10")
            + service(3, "Thunderbolt Bridge", port: "Thunderbolt Bridge", device: "bridge0")
            + service(4, "Thunderbolt Bridge 2", port: "Thunderbolt Bridge", device: "bridge0")
            + service(5, "Wi-Fi", port: "Wi-Fi", device: "en0")
            + service(6, "Darkbloom Cluster Link (en2)", port: "Thunderbolt 3", device: "en2")
            + service(7, "Darkbloom Cluster Link (en1)", port: "Thunderbolt 1", device: "en1")
            + service(8, "Darkbloom Cluster Link (en6)", port: "Thunderbolt 2", device: "en6")
            + service(9, "iPhone USB", port: "iPhone USB", device: "en9")
            + service(10, "Tailscale 2", port: "io.tailscale.ipn.macsys", device: ""))

    /// The M3 Ultra, port en6, paired with the M5 Max: only its route table
    /// was captured, so its hardware port and services are assumed.
    static let pairedM3Ultra = PairedMac(name: "M3 Ultra", port: "en6", address: "10.219.21.80", hardwarePort: "Thunderbolt 5",
        wifi: "en1", devices: ["rdma_en2", "rdma_en3", "rdma_en4", "rdma_en5", "rdma_en7", "rdma_en6"],
        otherPorts: ["en2", "en3", "en4", "en5", "en7"], bridgeMembers: [],
        routes: [
            "default            192.0.2.1          UGScg                 en1       ",
            "default            link#29            UCSIg               utun2       ",
            "10.219/16          link#21            UCS                   en6      !",
            "10.219.21.80/32    link#21            UCS                   en6      !",
            "10.219.21.80       0:0:5e:0:53:26     UHLWIi                lo0       ",
            "10.219.129.164     0:0:5e:0:53:16     UHLWIi                en6   1186",
            "10.219.255.255     ff:ff:ff:ff:ff:ff  UHLWbI                en6      !",
            "127                127.0.0.1          UCS                   lo0       ",
            "127.0.0.1          127.0.0.1          UH                    lo0       ",
        ],
        serviceOrder: serviceOrderHeader + service(1, "Wi-Fi", port: "Wi-Fi", device: "en1")
            + service(2, "Thunderbolt Bridge", port: "Thunderbolt Bridge", device: "bridge0")
            + service(3, "Darkbloom Cluster Link (en6)", port: "Thunderbolt 5", device: "en6"))

    static let pairedMacs = [pairedMacA, pairedM5Max, pairedM3Ultra]
}

/// A scripted Mac for link setup v2: the first version's world with the
/// network readings, its own record, and an approval that may swap the tools.
final class FakeIsolationWorld {
    var base: FakeRepairWorld
    var isolationRecord = ClusterLinkIsolationRecord()
    var isolationRecordFails = false
    /// The other app's record on this Mac (production's beside DevNet's), which this app only reads.
    var otherInstallRecord = ClusterLinkIsolationRecord()
    var isolationApproval: (ClusterLinkIsolationRequest, FakeIsolationWorld) -> ClusterLinkApprovalResult = { _, _ in .unavailable }
    private(set) var isolationRequests = [ClusterLinkIsolationRequest]()
    private(set) var isolationRecordSaves = 0

    init(_ tools: FakeLinkTools) { base = FakeRepairWorld(tools) }

    var tools: FakeLinkTools {
        get { base.tools }
        set { base.tools = newValue }
    }

    var environment: ClusterLinkRepair.Environment {
        var environment = base.environment
        environment.readsIsolation = true
        environment.requestIsolationApproval = { [self] request in
            isolationRequests.append(request)
            return isolationApproval(request, self)
        }
        environment.loadIsolationRecord = { [self] in
            if isolationRecordFails { throw FakeRepairWorld.RecordFailure() }
            return isolationRecord
        }
        environment.updateIsolationRecord = { [self] change in
            if isolationRecordFails { throw FakeRepairWorld.RecordFailure() }
            isolationRecordSaves += 1
            change(&isolationRecord)
        }
        environment.otherInstallsIsolationEntries = { [self] interface in otherInstallRecord.entry(on: interface).map { [$0] } ?? [] }
        return environment
    }

    func fix(device: String? = nil, dryRun: Bool = false) -> ClusterLinkRepairResult {
        ClusterLinkRepair.fix(device: device, mode: .durable, dryRun: dryRun, in: environment)
    }

    func remove(device: String? = nil, dryRun: Bool = false) -> ClusterLinkRepairResult {
        ClusterLinkRepair.remove(device: device, dryRun: dryRun, in: environment)
    }

    /// The report `darkbloom cluster link` would print on this Mac now.
    func report() -> ClusterLinkReadinessReport {
        ClusterLinkReadinessProbe.inspect(run: tools.outcome(of:), recorded: base.record, readingIsolation: true,
            isolationRecord: isolationRecord)
    }
}
