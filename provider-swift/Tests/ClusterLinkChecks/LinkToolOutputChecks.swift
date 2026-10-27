import Foundation

extension ClusterLinkCheck {
    static func controlStateText() {
        expectEqual(ClusterRDMAToolOutput.controlState("enabled\n"), .enabled, "enabled")
        expectEqual(ClusterRDMAToolOutput.controlState("disabled\n"), .disabled, "disabled")
        expectEqual(ClusterRDMAToolOutput.controlState("  enabled \r\n"), .enabled, "surrounding whitespace")
        let usage = "Usage: /usr/bin/rdma_ctl <status|enable|disable>\n  status  - Check if RDMA is enabled\n"
        for garbled in ["", "\n", "not enabled\n", "enabled\ndisabled\n", "ENABLED?", usage] {
            expectEqual(ClusterRDMAToolOutput.controlState(garbled), nil, "garbled status \(garbled.debugDescription)")
        }
    }

    static func deviceListText() {
        let devices = ClusterRDMAToolOutput.devices(LinkFixtures.deviceList(active: "rdma_en7"))
        expectEqual(devices?.map(\.name), LinkFixtures.deviceNames, "device names in listing order")
        expectEqual(devices?.filter(\.portActive).map(\.name), ["rdma_en7"], "exactly one active port")
        expectEqual(devices?.allSatisfy { $0.transport == .thunderbolt }, true, "Thunderbolt transport")

        let none = ClusterRDMAToolOutput.devices(LinkFixtures.deviceList(active: nil))
        expectEqual(none?.count, 6, "all-down listing keeps every device")
        expectEqual(none?.contains(where: \.portActive), false, "all-down listing has no active port")

        let other = ClusterRDMAToolOutput.devices(LinkFixtures.deviceBlock("mlx5_0", active: true, transport: "InfiniBand (0)"))
        expectEqual(other, [.init(name: "mlx5_0", transport: .other, portActive: true)], "non-Thunderbolt transport")

        // The verbose form of one device is a one-entry listing.
        let detail = ClusterRDMAToolOutput.devices(LinkFixtures.detailWithMappedGID("rdma_en7"))
        expectEqual(detail, [.init(name: "rdma_en7", transport: .thunderbolt, portActive: true)], "verbose block as listing")

        let stateless = ClusterRDMAToolOutput.devices("hca_id:\trdma_en2\n\ttransport:\t\t\tThunderbolt (100)\n")
        expectEqual(stateless, [.init(name: "rdma_en2", transport: .thunderbolt, portActive: false)], "missing port state is not active")

        let longName = String(repeating: "a", count: 64)
        for garbled in ["", "No IB devices found\n", "hca_id:\t\n", "hca_id:\t192.0.2.10\n", "hca_id:\t-v\n",
                        "hca_id:\trdma en7\n", "hca_id:\t\(longName)\n", "\tstate:\t\t\tPORT_ACTIVE (4)\n"] {
            expectEqual(ClusterRDMAToolOutput.devices(garbled), nil, "garbled listing \(garbled.debugDescription)")
        }
        expectEqual(ClusterRDMAToolOutput.devices("hca_id:\t\(String(repeating: "a", count: 63))\n")?.count, 1, "63-byte device name")
        let duplicate = LinkFixtures.deviceBlock("rdma_en7", active: true) + LinkFixtures.deviceBlock("rdma_en7", active: false)
        expectEqual(ClusterRDMAToolOutput.devices(duplicate), nil, "duplicate device name")
    }

    static func deviceDetailText() {
        func present(_ text: String, _ device: String = "rdma_en7") -> Bool? {
            ClusterRDMAToolOutput.ipv4MappedGIDPresent(inDetail: text, of: device)
        }
        expectEqual(present(LinkFixtures.detailWithMappedGID("rdma_en7")), true, "IPv4-mapped GID present")
        expectEqual(present(LinkFixtures.detailWithoutMappedGID("rdma_en7")), false, "no IPv4-mapped GID")
        expectEqual(present(LinkFixtures.deviceDetail("rdma_en7", gids: [])), false, "empty GID table")
        let expanded = LinkFixtures.deviceDetail("rdma_en7", gids: ["0000:0000:0000:0000:0000:ffff:c000:020a"])
        expectEqual(present(expanded), true, "fully expanded IPv4-mapped GID")
        // Only the ::ffff:0:0/96 prefix counts, exactly as JACCL tests it.
        for other in ["fe80::ffff:c000:20a", "::c000:20a", "ffff::c000:20a", "64:ff9b::c000:20a", "not-a-gid"] {
            expectEqual(present(LinkFixtures.deviceDetail("rdma_en7", gids: [other])), false, "\(other) is not IPv4-mapped")
        }
        expectEqual(present(LinkFixtures.detailWithMappedGID("rdma_en6")), nil, "detail of another device")
        expectEqual(present(""), nil, "empty detail")
        expectEqual(present("\t\t\tGID[  0]:\t\t::ffff:192.0.2.10\n"), nil, "GID lines without a device")
        let two = LinkFixtures.detailWithMappedGID("rdma_en7") + LinkFixtures.detailWithMappedGID("rdma_en6")
        expectEqual(present(two), nil, "detail describing two devices")
    }

    static func interfaceText() {
        let port = ClusterNetworkInterfaces.parse(LinkFixtures.port("en7", active: true, ipv4: LinkFixtures.portIPv4))
        expectEqual(port?.interfaces, [.init(name: "en7", isUp: true, linkActive: true, hasIPv4Address: true, bridgeMembers: [])],
            "plain interface with an address")

        let member = ClusterNetworkInterfaces.parse(LinkFixtures.port("en6", active: true, ipv4: nil))
        expectEqual(member?.interfaces, [.init(name: "en6", isUp: true, linkActive: true, hasIPv4Address: false, bridgeMembers: [])],
            "bridge member without an address: inet6 is not IPv4")

        let bridge = ClusterNetworkInterfaces.parse(LinkFixtures.bridge(members: ["en5", "en6"]))
        expectEqual(bridge?.interfaces, [.init(name: "bridge0", isUp: true, linkActive: true, hasIPv4Address: true, bridgeMembers: ["en5", "en6"])],
            "bridge0 listing members")

        let macB = ClusterNetworkInterfaces.parse(LinkFixtures.macBInterfaces)
        expectEqual(macB?.interfaces.map(\.name), ["lo0", "en0"] + LinkFixtures.interfaceNames + ["bridge0"], "ifconfig -a interface order")
        expectEqual(macB?.bridge(containing: "en6"), "bridge0", "en6 bridge membership")
        expectEqual(macB?.bridge(containing: "en0"), nil, "en0 is not bridged")
        expectEqual(macB?.interface(named: "en6")?.hasIPv4Address, false, "member has no address of its own")
        expectEqual(macB?.interface(named: "bridge0")?.hasIPv4Address, true, "bridge holds the address")
        expectEqual(macB?.interface(named: "en2")?.linkActive, false, "unplugged port is inactive")
        expectEqual(macB?.interface(named: "lo0")?.hasIPv4Address, true, "loopback")
        expect(macB?.interface(named: "en99") == nil, "unknown interface")

        let macA = ClusterNetworkInterfaces.parse(LinkFixtures.macAInterfaces)
        expectEqual(macA?.bridge(containing: "en7"), nil, "no bridge on Mac A")
        expectEqual(macA?.interface(named: "en7")?.hasIPv4Address, true, "en7 own address")
        expectEqual(macA?.interface(named: "nan0").map { [$0.isUp, $0.linkActive, $0.hasIPv4Address] }, [false, false, false],
            "administratively down interface")

        for garbled in ["", "ifconfig: interface bridge0 does not exist\n", "\tinet 192.0.2.10 netmask 0xffffff00\n",
                        "192.0.2.10: flags=8863<UP> mtu 1500\n", "en7 flags=8863<UP> mtu 1500\n"] {
            expect(ClusterNetworkInterfaces.parse(garbled) == nil, "garbled ifconfig \(garbled.debugDescription)")
        }
        let badMember = "bridge0: flags=8863<UP> mtu 1500\n\tmember: 192.0.2.10 flags=3<LEARNING,DISCOVER>\n"
        expect(ClusterNetworkInterfaces.parse(badMember) == nil, "address-shaped bridge member")
    }
}
