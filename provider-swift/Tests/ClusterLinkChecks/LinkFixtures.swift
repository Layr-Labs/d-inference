import Foundation

/// Tool text modelled on two observed Macs: one whose Thunderbolt port has its
/// own IPv4 address ("Mac A") and one whose port is only a Thunderbolt Bridge
/// member ("Mac B"). Every address, MAC address and GUID is a documentation
/// placeholder (192.0.2.0/24, 2001:db8::/32, 02:00:5e:00:53:xx); none belongs
/// to a real machine.
enum LinkFixtures {
    static let portIPv4 = "192.0.2.10"
    static let bridgeIPv4 = "192.0.2.20"
    static let wifiIPv4 = "192.0.2.50"
    static let mac = "02:00:5e:00:53:07"
    static let guid = "0200:5eff:fe00:5307"
    static let linkLocalIPv6 = "fe80::200:5eff:fe00:5307"
    static let globalIPv6 = "2001:db8::7"
    static let mappedGID = "::ffff:192.0.2.10"

    /// Every placeholder that must never survive into a report or summary.
    static let sensitive = [portIPv4, bridgeIPv4, wifiIPv4, "192.0.2.255", "127.0.0.1", mac, guid,
        linkLocalIPv6, globalIPv6, mappedGID, "ffff", "0xffffff00"]

    static let deviceNames = (2...7).map { "rdma_en\($0)" }

    static func deviceBlock(_ name: String, active: Bool, transport: String = "Thunderbolt (100)") -> String {
        """
        hca_id:\t\(name)
        \ttransport:\t\t\t\(transport)
        \tnode_guid:\t\t\t\(guid)
        \tsys_image_guid:\t\t\t\(guid)
        \tvendor_id:\t\t\t0x0000
        \tvendor_part_id:\t\t\t0
        \thw_ver:\t\t\t\t0x0
        \tphys_port_cnt:\t\t\t1
        \t\tport:\t1
        \t\t\tstate:\t\t\t\(active ? "PORT_ACTIVE (4)" : "PORT_DOWN (1)")
        \t\t\tmax_mtu:\t\t4096 (5)
        \t\t\tactive_mtu:\t\t4096 (5)
        \t\t\tsm_lid:\t\t\t1
        \t\t\tport_lid:\t\t1
        \t\t\tport_lmc:\t\t0x00
        \t\t\tlink_layer:\t\tThunderbolt


        """
    }

    /// `ibv_devinfo`: six Thunderbolt devices, at most one of them active.
    static func deviceList(active: String?) -> String {
        deviceNames.map { deviceBlock($0, active: $0 == active) }.joined()
    }

    /// `ibv_devinfo -v -d <name>`: capability lines, then the port and its GID table.
    static func deviceDetail(_ name: String, active: Bool = true, gids: [String]) -> String {
        let table = gids.enumerated().map { "\t\t\tGID[\(String(repeating: " ", count: 3 - String($0).count))\($0)]:\t\t\($1)" }
        return """
        hca_id:\t\(name)
        \ttransport:\t\t\tThunderbolt (100)
        \tnode_guid:\t\t\t\(guid)
        \tsys_image_guid:\t\t\t\(guid)
        \tphys_port_cnt:\t\t\t1
        \tmax_mr_size:\t\t\t0xfa0000
        \tmax_qp:\t\t\t\t3
        \tatomic_cap:\t\t\tATOMIC_NONE (0)
        \tnum_comp_vectors:\t\t1
        \t\tport:\t1
        \t\t\tstate:\t\t\t\(active ? "PORT_ACTIVE (4)" : "PORT_DOWN (1)")
        \t\t\tmax_mtu:\t\t4096 (5)
        \t\t\tlink_layer:\t\tThunderbolt
        \t\t\tgid_tbl_len:\t\t1024
        \t\t\tactive_width:\t\t8X (4)
        \t\t\tactive_speed:\t\t10.0 Gbps (4)
        \(table.joined(separator: "\n"))


        """
    }

    static func detailWithMappedGID(_ name: String) -> String {
        deviceDetail(name, gids: ["fe80:0000:0000:0000:\(guid)", linkLocalIPv6, mappedGID, linkLocalIPv6, globalIPv6])
    }

    static func detailWithoutMappedGID(_ name: String) -> String {
        deviceDetail(name, gids: ["fe80:0000:0000:0000:\(guid)", linkLocalIPv6])
    }

    /// `ifconfig <name>` for a Thunderbolt port.
    static func port(_ name: String, active: Bool, ipv4: String?) -> String {
        var lines = ["\(name): flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500",
            "\toptions=460<TSO4,TSO6,CHANNEL_IO>", "\tether \(mac)"]
        if active { lines.append("\tinet6 \(linkLocalIPv6)%\(name) prefixlen 64 secured scopeid 0x15 ") }
        if let ipv4 { lines.append("\tinet \(ipv4) netmask 0xffffff00 broadcast 192.0.2.255") }
        lines += ["\tnd6 options=201<PERFORMNUD,DAD>", "\tmedia: autoselect <full-duplex>",
            "\tstatus: \(active ? "active" : "inactive")"]
        return lines.joined(separator: "\n") + "\n"
    }

    static let loopback = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \toptions=1203<RXCSUM,TXCSUM,TXSTATUS,SW_TIMESTAMP>
        \tinet 127.0.0.1 netmask 0xff000000
        \tinet6 ::1 prefixlen 128
        \tnd6 options=201<PERFORMNUD,DAD>

        """

    /// Administratively down: no UP flag, no status line.
    static let downInterface = """
        nan0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
        \toptions=400<CHANNEL_IO>
        \tether \(mac)

        """

    /// `ifconfig bridge0`: the Thunderbolt Bridge holds the address and lists
    /// the Thunderbolt ports as members.
    static func bridge(members: [String]) -> String {
        var lines = ["bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500",
            "\toptions=63<RXCSUM,TXCSUM,TSO4,TSO6>", "\tether \(mac)",
            "\tinet \(bridgeIPv4) netmask 0xffffff00 broadcast 192.0.2.255", "\tConfiguration:",
            "\t\tid 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0",
            "\t\tmaxage 0 holdcnt 0 proto stp maxaddr 100 timeout 1200",
            "\t\troot id 0:0:0:0:0:0 priority 0 ifcost 0 port 0", "\t\tipfilter disabled flags 0x0"]
        for (index, member) in members.enumerated() {
            lines.append("\tmember: \(member) flags=3<LEARNING,DISCOVER>")
            lines.append("\t        ifmaxaddr 0 port \(index + 9) priority 0 path cost 0")
        }
        lines += ["\tnd6 options=201<PERFORMNUD,DAD>", "\tmedia: <unknown type>", "\tstatus: active"]
        return lines.joined(separator: "\n") + "\n"
    }

    static let interfaceNames = (2...7).map { "en\($0)" }

    /// `ifconfig -a` on Mac A: `en7` carries its own address and no bridge exists.
    static let macAInterfaces = loopback + port("en0", active: true, ipv4: wifiIPv4)
        + interfaceNames.map { port($0, active: $0 == "en7", ipv4: $0 == "en7" ? portIPv4 : nil) }.joined()
        + downInterface

    /// `ifconfig -a` on Mac B: `en6` is active but only a `bridge0` member.
    static let macBInterfaces = loopback + port("en0", active: true, ipv4: wifiIPv4)
        + interfaceNames.map { port($0, active: $0 == "en6", ipv4: nil) }.joined()
        + bridge(members: interfaceNames)
}

/// Canned tool results standing in for the real children.
struct FakeLinkTools {
    var controlStatus = ClusterLinkToolOutcome.output("enabled\n")
    var deviceList: ClusterLinkToolOutcome
    var interfaces: ClusterLinkToolOutcome
    var details: [String: ClusterLinkToolOutcome] = [:]

    static let macA = FakeLinkTools(deviceList: .output(LinkFixtures.deviceList(active: "rdma_en7")),
        interfaces: .output(LinkFixtures.macAInterfaces),
        details: ["rdma_en7": .output(LinkFixtures.detailWithMappedGID("rdma_en7"))])

    static let macB = FakeLinkTools(deviceList: .output(LinkFixtures.deviceList(active: "rdma_en6")),
        interfaces: .output(LinkFixtures.macBInterfaces),
        details: ["rdma_en6": .output(LinkFixtures.detailWithoutMappedGID("rdma_en6"))])

    /// Runs the inspection and returns the report with the commands it issued.
    func inspect() -> (report: ClusterLinkReadinessReport, commands: [ClusterLinkToolCommand]) {
        var commands = [ClusterLinkToolCommand]()
        let report = ClusterLinkReadinessProbe.inspect { command in
            commands.append(command)
            switch command {
            case .rdmaControlStatus: return controlStatus
            case .rdmaDeviceList: return deviceList
            case .interfaceList: return interfaces
            case .rdmaDeviceDetail(let device): return details[device] ?? .unavailable
            }
        }
        return (report, commands)
    }
}
