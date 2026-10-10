import Foundation

/// Link setup v2: the readers for the network tools, the findings for the
/// two captured Macs, the exact commands of one approval and of its undoing,
/// the flows over a scripted Mac, the record, the guided wording and the
/// bounded wait before a rank starts.
extension ClusterLinkCheck {
    static func isolationToolText() {
        typealias Facts = ClusterLinkNetworkFacts
        let portsA = Facts.hardwarePorts(IsolationFixtures.macAHardwarePorts)
        expectEqual(portsA["en7"], "Thunderbolt 6", "Mac A: en7 is Thunderbolt 6")
        expectEqual(portsA["en8"], "Ethernet Adapter (en8)", "Mac A: an adapter port name")
        expectEqual(Facts.hardwarePorts(IsolationFixtures.macBHardwarePorts)["en6"], "Thunderbolt 2", "Mac B: en6 is Thunderbolt 2")
        expectEqual(Facts.hardwarePorts(IsolationFixtures.macBHardwarePorts)["bridge0"], "Thunderbolt Bridge", "Mac B: the bridge")
        expect(Facts.hardwarePorts("Hardware Port: X\nDevice: 192.0.2.1\n").isEmpty, "an address-shaped device is dropped")

        let servicesA = Facts.services(IsolationFixtures.macAServiceOrder())
        expectEqual(servicesA?.count, 11, "Mac A: eleven services")
        expectEqual(servicesA?.first { $0.interface == "en7" }, .init(name: "Thunderbolt 6", interface: "en7", enabled: true),
            "Mac A: the cable's port has its own DHCP service")
        expectEqual(servicesA?.last, .init(name: "Tailscale", interface: nil, enabled: true), "a service without an interface")
        let disabled = Facts.services(IsolationFixtures.macAServiceOrder(thunderbolt6Enabled: false, clusterService: true))
        expectEqual(disabled?.first { $0.name == "Thunderbolt 6" }?.enabled, false, "(*) marks a disabled service")
        expectEqual(disabled?.last, .init(name: "Darkbloom Cluster Link (en7)", interface: "en7", enabled: true), "Darkbloom's service")
        expectEqual(Facts.services(IsolationFixtures.serviceOrderHeader)?.count, 0, "no services is an answer")
        expectEqual(Facts.services("something else\n"), nil, "other text is not a service order")
        expectEqual(Facts.services(IsolationFixtures.macBServiceOrder())?.first { $0.interface == "bridge0" }?.name,
            "Thunderbolt Bridge", "Mac B: the bridge's service")

        expectEqual(Facts.preferenceBridges(IsolationFixtures.macBBridgePreferences), ["bridge0": ["en1", "en6", "en2"]],
            "Mac B: bridge members in order")
        expectEqual(Facts.preferenceBridges(IsolationFixtures.emptyBridgePreferences), [:], "Mac A: no bridge")
        expectEqual(Facts.preferenceBridges("{\"bridge0\":{\"Interfaces\":[\"en1\",\"$(x)\"]}}"), nil, "a hostile member refuses the reading")
        expectEqual(Facts.preferenceBridges("[]"), nil, "not an object")

        for (text, value) in [("1\n", true as Bool?), ("true\n", true), ("0\n", false), ("false", false), ("yes", nil), ("", nil)] {
            expectEqual(Facts.sharingEnabled(text), value, "NAT.Enabled \(text.debugDescription)")
        }
        expectEqual(Facts.sharingDevices(IsolationFixtures.macBSharingDevices), ["en7", "en14", "en6", "bridge0", "en12"], "sharing devices")
        expectEqual(Facts.sharingDevices("[\"en6\",\"a b\",3]"), nil, "a non-string element refuses the reading")
        expectEqual(Facts.sharingDevices("[\"en6\",\"a b\"]"), ["en6"], "a name that is not an interface is dropped")

        expectEqual(Facts.defaultRouteInterfaces(IsolationFixtures.macARoutes), ["en1", "en7", "utun4"], "Mac A: a second default route via en7")
        expectEqual(Facts.defaultRouteInterfaces(IsolationFixtures.macBRoutes), ["en0", "bridge0", "utun2"], "Mac B: none via en6")
        expectEqual(Facts.defaultRouteInterfaces(IsolationFixtures.macAIsolatedRoutes(address: "10.219.1.2")), ["en1", "utun4"],
            "isolated Mac A: no default route via the cable")
        expectEqual(Facts.clusterSubnetRouteInterfaces(IsolationFixtures.macAIsolatedRoutes(address: "10.219.1.2")), ["en7", "en7"],
            "the cluster subnet routes through the port")
        expectEqual(Facts.clusterSubnetRouteInterfaces(IsolationFixtures.macARoutes), [], "no cluster subnet before")
        expectEqual(Facts.defaultRouteInterfaces("default 192.0.2.1 UGScg en1\n"), nil, "rows without the header are not a table")

        expectEqual(Facts.dnsInterfaces(IsolationFixtures.macADNS()), ["en1", "en7", "utun4"], "Mac A: a resolver through en7")
        expectEqual(Facts.dnsInterfaces(IsolationFixtures.macADNS(viaPort: false)), ["en1", "utun4"], "isolated Mac A: none through en7")
        expectEqual(Facts.dnsInterfaces(IsolationFixtures.macBDNS), ["en0", "bridge0"], "Mac B: none through en6")
        expectEqual(Facts.dnsInterfaces("resolver #1\n  if_index : 3 (en7)\n"), nil, "not a DNS configuration")
        expectEqual(Facts.dnsInterfaces("DNS configuration\n\nresolver #1\n  if_index : 3 (en7)\n"), [],
            "an interface without a name server is not DNS through it")

        expect(Facts.holdsDHCPLease(IsolationFixtures.macALeasePacket), "Mac A: a DHCP reply on en7")
        expect(!Facts.holdsDHCPLease("ipconfig_get_packet(en6) failed: interface doesn't exist\n"), "no lease")

        let dhcp = Facts.serviceInfo(IsolationFixtures.dhcpServiceInfo)
        expectEqual(dhcp?.manual, false, "DHCP service")
        expectEqual(dhcp?.router, true, "DHCP router learned")
        expectEqual(dhcp?.ipv6, "automatic", "IPv6 automatic")
        let manual = Facts.serviceInfo(IsolationFixtures.manualServiceInfo(address: "10.219.1.2"))
        expectEqual(manual, .init(manual: true, address: "10.219.1.2", subnetMask: "255.255.0.0", router: false, ipv6: "link local"),
            "manual service without a router")
        expectEqual(Facts.serviceInfo(IsolationFixtures.manualServiceInfo(address: "10.219.1.2", router: "192.0.2.1"))?.router, true,
            "a manual router")
        expectEqual(Facts.serviceInfo("** Error: The parameters were not valid.\n"), nil, "an error is not service info")

        let listing = IsolationFixtures.macAInterfaces(en7: ["10.219.4.5"]) + IsolationFixtures.port("en9", active: true, addresses: ["10.219.9.9"])
        expectEqual(Facts.interfacesInClusterSubnet(listing, except: "en7"), ["en9"], "another interface in the cluster subnet")
        expectEqual(Facts.interfacesInClusterSubnet(IsolationFixtures.macAInterfaces(en7: ["10.219.4.5"]), except: "en7"), [],
            "the port itself does not count")
        expect(Facts.lists("10.219.4.5", on: "en7", inListing: listing), "the port carries the address")
        expect(!Facts.lists("10.219.4.5", on: "en9", inListing: listing), "another port does not")

        // Names that may reach a privileged command.
        for name in ["Thunderbolt 6", "Ethernet Adapter (en8)", "Darkbloom Cluster Link (en7)", "Wi-Fi", "iPhone USB", "My_Link.2"] {
            expect(ClusterLinkServiceName.isSafe(name), "safe name \(name)")
        }
        for name in ["", " leading", "trailing ", "USB 10/100/1000 LAN", "a'b", "a\"b", "a\\b", "$(id)", "a`b`", "a;b", "a|b",
                     "a\nb", "Jonathan’s", String(repeating: "x", count: 65)] {
            expect(!ClusterLinkServiceName.isSafe(name), "unsafe name \(name.debugDescription)")
        }
        expectEqual(ClusterLinkServiceName.cluster(interface: "en6"), "Darkbloom Cluster Link (en6)", "Darkbloom's service name")
        expectEqual(ClusterLinkServiceName.clusterInterface(ofService: "Darkbloom Cluster Link (en6)"), "en6", "recognised")
        expectEqual(ClusterLinkServiceName.clusterInterface(ofService: "Darkbloom Cluster Link (192.0.2.1)"), nil, "not an interface")
        expectEqual(ClusterLinkServiceName.clusterInterface(ofService: "Thunderbolt 6"), nil, "someone else's service")
    }

    static func isolationAddress() {
        let derived = ClusterLinkClusterAddress.derived(machineIdentifier: IsolationFixtures.machine, interface: "en6")
        let linkLocal = ClusterLinkLocalAddress.derived(machineIdentifier: IsolationFixtures.machine, interface: "en6")
        expectEqual(derived.dottedDecimal, "10.219.\(linkLocal.third).\(linkLocal.fourth)", "the host part of the first version")
        expectEqual(derived.dottedDecimal, "10.219.188.90", "the fixture value")
        expectEqual(ClusterLinkClusterAddress(dottedDecimal: "10.219.188.90"), derived, "parsed back")
        for text in ["10.219.0.5", "10.219.5.255", "10.218.1.1", "169.254.1.1", "10.219.01.1", "10.219.1", "10.219.1.1.1", "10.219.a.1", ""] {
            expectEqual(ClusterLinkClusterAddress(dottedDecimal: text), nil, "refused \(text.debugDescription)")
        }
        for (text, inside) in [("10.219", true), ("10.219.4/24", true), ("10.219.4.7", true), ("10.2190", false), ("10.21", false),
                               ("default", false), ("110.219.1.1", false)] {
            expectEqual(ClusterLinkClusterAddress.inSubnet(Substring(text)), inside, "subnet test \(text)")
        }
        expectEqual(ClusterLinkClusterAddress.derived(machineIdentifier: "other", interface: "en6") == derived, false,
            "another machine, another address")
    }

    static func isolationCommandSet() {
        let commands: [ClusterLinkToolCommand] = [.hardwarePorts, .networkServiceOrder, .networkServiceInfo(service: "Thunderbolt 6"),
            .bridgePreferences, .internetSharingEnabled, .internetSharingDevices, .routeTable, .dnsConfiguration, .dhcpPacket(interface: "en7")]
        expectEqual(commands.map(\.executable), ["/usr/sbin/networksetup", "/usr/sbin/networksetup", "/usr/sbin/networksetup",
            "/usr/bin/plutil", "/usr/bin/plutil", "/usr/bin/plutil", "/usr/sbin/netstat", "/usr/sbin/scutil", "/usr/sbin/ipconfig"],
            "fixed absolute tool paths")
        let preferences = "/Library/Preferences/SystemConfiguration/preferences.plist"
        let nat = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"
        expectEqual(commands.map(\.arguments), [["-listallhardwareports"], ["-listnetworkserviceorder"], ["-getinfo", "Thunderbolt 6"],
            ["-extract", "VirtualNetworkInterfaces.Bridge", "json", "-o", "-", preferences],
            ["-extract", "NAT.Enabled", "raw", "-o", "-", nat], ["-extract", "NAT.SharingDevices", "json", "-o", "-", nat],
            ["-rn", "-f", "inet"], ["--dns"], ["getpacket", "en7"]], "read-only arguments")
        // A first-version inspection never reads them.
        let (_, macA) = FakeLinkTools.macA.inspect()
        expect(!macA.contains { commands.contains($0) }, "first-version inspection reads none of them")
    }

    static func isolationMacAFindings() {
        let world = FakeIsolationWorld(IsolationFixtures.macA)
        let report = world.report()
        expectEqual(report.state, .ready, "Mac A is ready")
        let port = report.devices.first { $0.device == "rdma_en7" }
        expectEqual(port?.isolation?.findings, [.defaultRouteViaPort, .dnsViaPort, .dhcpLeaseOnPort, .clusterServiceMissing, .otherServiceOnPort],
            "Mac A findings")
        expectEqual(port?.isolation?.otherServices, ["Thunderbolt 6"], "the DHCP service on the port")
        expectEqual(port?.isolation?.hardwarePort, "Thunderbolt 6", "hardware port")
        expectEqual(port?.isolation?.blockers, [], "nothing blocks the approval")
        expect(report.devices.filter { $0.device != "rdma_en7" }.allSatisfy { $0.isolation == nil }, "only active ports are judged")
        expect(report.guidance?.contains("`darkbloom cluster`") == true && report.guidance?.contains("not isolated") == true,
            "the guidance offers the approval")
        let summary = report.summaryLines.joined(separator: "\n")
        expect(summary.contains("not isolated: a default route leaves through en7, a DNS resolver is reached through en7, en7 holds a DHCP lease from the other Mac"),
            "summary names the findings")
        let json = compactJSON(report)
        expect(json.contains("\"isolation\":{\"findings\":[\"defaultRouteViaPort\",\"dnsViaPort\",\"dhcpLeaseOnPort\",\"clusterServiceMissing\",\"otherServiceOnPort\"],\"isolated\":false}"),
            "JSON names the findings")
        expectNoAddress(json, "Mac A isolation JSON")
        expectNoAddress(summary, "Mac A isolation summary")
        expect(!json.contains("Thunderbolt 6") && !summary.contains("Thunderbolt 6"), "service names stay out of the report")

        let isolated = FakeIsolationWorld(IsolationFixtures.macAIsolated())
        isolated.isolationRecord.set(.init(interface: "en7", address: IsolationFixtures.macAAddress, hardwarePort: "Thunderbolt 6",
            bridge: nil, disabledServices: ["Thunderbolt 6"]))
        let after = isolated.report()
        expectEqual(after.devices.first { $0.device == "rdma_en7" }?.isolation?.findings, [], "isolated Mac A has no findings")
        expectEqual(after.guidance, nil, "an isolated ready Mac needs nothing")
        expect(after.summaryLines.joined().contains("isolated: own network service"), "summary says isolated")
        // The recorded address is the one Darkbloom's service must carry.
        isolated.isolationRecord.set(.init(interface: "en7", address: ClusterLinkClusterAddress(third: 9, fourth: 9)!,
            hardwarePort: "Thunderbolt 6", bridge: nil, disabledServices: []))
        isolated.isolationRecord.forget(interface: "en7")
        isolated.isolationRecord.set(.init(interface: "en7", address: ClusterLinkClusterAddress(third: 9, fourth: 9)!,
            hardwarePort: "Thunderbolt 6", bridge: nil, disabledServices: []))
        expectEqual(isolated.report().devices.first { $0.device == "rdma_en7" }?.isolation?.findings, [.clusterServiceMisconfigured],
            "a service on another address is not Darkbloom's as written")
        var automatic = IsolationFixtures.macAIsolated()
        automatic.isolation.serviceInfo["Darkbloom Cluster Link (en7)"] = .output(IsolationFixtures.manualServiceInfo(
            address: IsolationFixtures.macAAddress.dottedDecimal, ipv6: "Automatic"))
        expectEqual(FakeIsolationWorld(automatic).report().devices.first { $0.device == "rdma_en7" }?.isolation?.findings,
            [.clusterServiceMisconfigured], "automatic IPv6 is not as written")
    }

    static func isolationMacBFindings() {
        let world = FakeIsolationWorld(IsolationFixtures.macB)
        world.base.record.set(.init(interface: "en6", address: ClusterLinkLocalAddress(dottedDecimal: IsolationFixtures.macBLinkLocal)!))
        let report = world.report()
        expectEqual(report.state, .ready, "Mac B is ready on the first version's address")
        let port = report.devices.first { $0.device == "rdma_en6" }
        expectEqual(port?.isolation?.findings, [.portInBridge, .internetSharingOverPortBridge, .internetSharingToPort, .clusterServiceMissing],
            "Mac B findings")
        expectEqual(port?.isolation?.blockers, [.internetSharingToPort], "Internet Sharing to the port blocks the approval")
        expectEqual(port?.isolation?.preferenceBridge, .init(bridge: "bridge0", index: 1, members: ["en1", "en6", "en2"]),
            "the bridge slot")
        expectEqual(port?.addressKept, true, "the first version's keeper is running")
        let guidance = report.guidance ?? ""
        expect(guidance.contains("cannot be isolated yet") && guidance.contains("Internet Sharing")
            && guidance.contains("“Thunderbolt 2” (en6)") && guidance.contains("Darkbloom does not change Internet Sharing"),
            "the guidance says what the owner can do: \(guidance)")
        expectNoAddress(compactJSON(report), "Mac B isolation JSON")
        expectNoAddress(report.summaryLines.joined(separator: "\n"), "Mac B isolation summary")

        let unshared = FakeIsolationWorld(IsolationFixtures.macBUnshared).report().devices.first { $0.device == "rdma_en6" }
        expectEqual(unshared?.isolation?.findings, [.portInBridge, .internetSharingOverPortBridge, .clusterServiceMissing],
            "after the owner turns the port off under Internet Sharing")
        expect(unshared?.isolation?.approvalWouldIsolate == true, "the approval can then isolate it")

        // A port in a bridge the settings do not list: Internet Sharing's own.
        var unmanaged = IsolationFixtures.macBUnshared
        unmanaged.isolation.bridgePreferences = .output(IsolationFixtures.macBBridgePreferencesWithoutPort)
        expectEqual(FakeIsolationWorld(unmanaged).report().devices.first { $0.device == "rdma_en6" }?.isolation?.findings,
            [.portInUnmanagedBridge, .clusterServiceMissing], "a kernel bridge without settings")

        // Readings that fail or are garbled stop everything.
        for broken in [ClusterLinkToolOutcome.timedOut, .outputTooLarge, .output("garbage\n")] {
            var tools = IsolationFixtures.macBUnshared
            tools.isolation.routes = broken
            expectEqual(FakeIsolationWorld(tools).report().devices.first { $0.device == "rdma_en6" }?.isolation?.findings,
                [.stateUnreadable], "an unreadable route table: \(broken)")
        }
        var noPorts = IsolationFixtures.macBUnshared
        noPorts.isolation.hardwarePorts = .output("\nVLAN Configurations\n===================\n")
        expect(FakeIsolationWorld(noPorts).report().devices.first { $0.device == "rdma_en6" }?.isolation?.blockers == [.hardwarePortUnknown],
            "no hardware port, no service")
        var subnet = IsolationFixtures.macBUnshared
        subnet.isolation.routes = .output(IsolationFixtures.routeTable(["default            192.0.2.1          UGScg                 en0",
            "10.219/16          link#23            UCS                 utun2"]))
        expect(FakeIsolationWorld(subnet).report().devices.first { $0.device == "rdma_en6" }?.isolation?.blockers == [.clusterSubnetInUse],
            "a VPN route into the cluster subnet blocks it")
        var hostile = IsolationFixtures.macA
        hostile.isolation.serviceOrder = .output(IsolationFixtures.serviceOrderHeader
            + IsolationFixtures.service(1, "x'; rm -rf / #", port: "Thunderbolt 6", device: "en7"))
        expect(FakeIsolationWorld(hostile).report().devices.first { $0.device == "rdma_en7" }?.isolation?.blockers == [.serviceNameUnsafe],
            "a hostile service name on the port blocks it")
    }

    static func isolationPlans() {
        let addressA = IsolationFixtures.macAAddress.dottedDecimal
        let planA = ClusterLinkIsolationPlan(interface: "en7", address: IsolationFixtures.macAAddress, hardwarePort: "Thunderbolt 6",
            bridge: nil, servicesToDisable: ["Thunderbolt 6"], replaceClusterService: false, linkLocalToRemove: nil, keeperToRemove: false)!
        let expectedA = [
            "/usr/sbin/networksetup -createnetworkservice 'Darkbloom Cluster Link (en7)' 'Thunderbolt 6'",
            "/usr/sbin/networksetup -setmanual 'Darkbloom Cluster Link (en7)' \(addressA) 255.255.0.0",
            "/usr/sbin/networksetup -setdnsservers 'Darkbloom Cluster Link (en7)' Empty",
            "/usr/sbin/networksetup -setv6LinkLocal 'Darkbloom Cluster Link (en7)'",
            "/usr/sbin/networksetup -setnetworkserviceenabled 'Thunderbolt 6' off",
        ]
        expectEqual(planA.commands, expectedA, "Mac A: the exact commands")
        let requestA = ClusterLinkIsolationRequest(.isolate(planA))!
        expectEqual(requestA.shellCommand, "set -e; " + expectedA.joined(separator: "; "), "Mac A: one line under set -e")
        expect(requestA.appleScript.hasPrefix("do shell script \"set -e; ") && requestA.appleScript.hasSuffix("with administrator privileges"),
            "AppleScript wrapper")
        expectEqual(requestA.appleScript.filter { $0 == "\"" }.count, 4, "no double quote inside the script or prompt")
        expect(!requestA.appleScript.contains("\\"), "no backslash")
        expectEqual(requestA.manualCommands.first, "sudo " + expectedA[0], "manual commands")
        expectEqual(requestA.prompt, "Darkbloom wants to give Thunderbolt port en7 its own network service with a fixed address and no router or DNS and switch the other service on that port off, so RDMA can use it.", "Mac A prompt")

        let planB = ClusterLinkIsolationPlan(interface: "en6", address: IsolationFixtures.macBAddress, hardwarePort: "Thunderbolt 2",
            bridge: .init(bridge: "bridge0", index: 1), servicesToDisable: [], replaceClusterService: false,
            linkLocalToRemove: ClusterLinkLocalAddress(dottedDecimal: IsolationFixtures.macBLinkLocal), keeperToRemove: true)!
        let preferences = "/Library/Preferences/SystemConfiguration/preferences.plist"
        let expectedB = [
            "/bin/launchctl bootout system/io.darkbloom.cluster-link.en6 2>/dev/null || true",
            "/bin/rm -f /Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist",
            "/sbin/ifconfig en6 inet \(IsolationFixtures.macBLinkLocal) -alias 2>/dev/null || true",
            "/usr/libexec/PlistBuddy -c 'Print :VirtualNetworkInterfaces:Bridge:bridge0:Interfaces:1' \(preferences) | /usr/bin/grep -qx en6",
            "/usr/libexec/PlistBuddy -c 'Delete :VirtualNetworkInterfaces:Bridge:bridge0:Interfaces:1' \(preferences)",
            "/sbin/ifconfig bridge0 deletem en6 2>/dev/null || true",
            "/usr/sbin/networksetup -createnetworkservice 'Darkbloom Cluster Link (en6)' 'Thunderbolt 2'",
            "/usr/sbin/networksetup -setmanual 'Darkbloom Cluster Link (en6)' 10.219.188.90 255.255.0.0",
            "/usr/sbin/networksetup -setdnsservers 'Darkbloom Cluster Link (en6)' Empty",
            "/usr/sbin/networksetup -setv6LinkLocal 'Darkbloom Cluster Link (en6)'",
        ]
        expectEqual(planB.commands, expectedB, "Mac B: the exact commands")
        expectEqual(ClusterLinkIsolationRequest(.isolate(planB))!.prompt, "Darkbloom wants to give Thunderbolt port en6 its own network service with a fixed address and no router or DNS and take the port out of bridge0, so RDMA can use it.", "Mac B prompt")
        let both = ClusterLinkIsolationPlan(interface: "en6", address: IsolationFixtures.macBAddress, hardwarePort: "Thunderbolt 2",
            bridge: .init(bridge: "bridge0", index: 1), servicesToDisable: ["Thunderbolt 2"], replaceClusterService: false,
            linkLocalToRemove: nil, keeperToRemove: false)!
        expectEqual(ClusterLinkIsolationRequest(.isolate(both))!.prompt, "Darkbloom wants to give Thunderbolt port en6 its own network service with a fixed address and no router or DNS, switch the other service on that port off and take the port out of bridge0, so RDMA can use it.", "a prompt with all three")
        let replaced = ClusterLinkIsolationPlan(interface: "en6", address: IsolationFixtures.macBAddress, hardwarePort: "Thunderbolt 2",
            bridge: nil, servicesToDisable: [], replaceClusterService: true, linkLocalToRemove: nil, keeperToRemove: false)!
        expectEqual(replaced.commands.first, "/usr/sbin/networksetup -removenetworkservice 'Darkbloom Cluster Link (en6)'",
            "an existing service of Darkbloom's is made afresh")

        // Nothing unvalidated reaches a command.
        let address = IsolationFixtures.macAAddress
        expect(ClusterLinkIsolationPlan(interface: "en7;id", address: address, hardwarePort: "Thunderbolt 6", bridge: nil,
            servicesToDisable: [], replaceClusterService: false, linkLocalToRemove: nil, keeperToRemove: false) == nil, "hostile interface")
        expect(ClusterLinkIsolationPlan(interface: "en7", address: address, hardwarePort: "Thunder'bolt", bridge: nil,
            servicesToDisable: [], replaceClusterService: false, linkLocalToRemove: nil, keeperToRemove: false) == nil, "hostile port")
        expect(ClusterLinkIsolationPlan(interface: "en7", address: address, hardwarePort: "Thunderbolt 6", bridge: nil,
            servicesToDisable: ["a\"b"], replaceClusterService: false, linkLocalToRemove: nil, keeperToRemove: false) == nil, "hostile service")
        expect(ClusterLinkIsolationPlan(interface: "en7", address: address, hardwarePort: "Thunderbolt 6", bridge: .init(bridge: "bridge0", index: -1),
            servicesToDisable: [], replaceClusterService: false, linkLocalToRemove: nil, keeperToRemove: false) == nil, "negative index")
        expect(ClusterLinkIsolationPlan(interface: "en7", address: address, hardwarePort: "Thunderbolt 6", bridge: nil,
            servicesToDisable: ["Darkbloom Cluster Link (en7)"], replaceClusterService: false, linkLocalToRemove: nil, keeperToRemove: false) == nil,
            "Darkbloom's own service is never switched off")

        let restore = ClusterLinkIsolationRestore(interface: "en6", removeClusterService: true, servicesToEnable: ["Thunderbolt 6"],
            bridge: .init(bridge: "bridge0", index: 1), addressToRemove: nil, keeperToRemove: false)!
        expectEqual(restore.commands, [
            "/usr/libexec/PlistBuddy -c 'Add :VirtualNetworkInterfaces:Bridge:bridge0:Interfaces:1 string en6' \(preferences)",
            "/usr/sbin/networksetup -removenetworkservice 'Darkbloom Cluster Link (en6)'",
            "/usr/sbin/networksetup -setnetworkserviceenabled 'Thunderbolt 6' on",
            "/sbin/ifconfig bridge0 addm en6",
        ], "the exact restore commands")
        let restoreRequest = ClusterLinkIsolationRequest(.restore(restore))!
        expectEqual(restoreRequest.shellCommand, restore.commands.joined(separator: "; "), "a restore runs every command")
        expect(ClusterLinkIsolationRequest(.restore(ClusterLinkIsolationRestore(interface: "en6", removeClusterService: false,
            servicesToEnable: [], bridge: nil, addressToRemove: nil, keeperToRemove: false)!)) == nil, "nothing to restore, no request")
        expectEqual(ClusterLinkApproval.arguments(for: requestA), ["-e", requestA.appleScript], "osascript arguments")
    }

    static func isolationFixOutcomes() {
        // Mac A: dry run, then the approval.
        let a = FakeIsolationWorld(IsolationFixtures.macA)
        let dry = a.fix(dryRun: true)
        expectEqual(dry.outcome, .dryRun, "Mac A dry run")
        expectEqual(dry.isolated, true, "a v2 dry run")
        expectEqual(dry.plannedCommands.count, 5, "Mac A: five commands")
        expect(a.isolationRequests.isEmpty && a.base.approvalRequests.isEmpty, "a dry run asks nothing")
        expectEqual(a.isolationRecordSaves, 0, "a dry run records nothing")
        a.isolationApproval = { _, world in
            world.tools = IsolationFixtures.macAIsolated()
            return .applied
        }
        let fixed = a.fix()
        expectEqual(fixed.outcome, .fixed, "Mac A fixed: \(fixed.message)")
        expectEqual(fixed.interface, "en7", "the port")
        expectEqual(a.isolationRequests.count, 1, "one approval")
        expectEqual(a.base.approvalRequests.count, 0, "no first-version approval")
        expectEqual(a.isolationRecord.entry(on: "en7"), .init(interface: "en7", address: IsolationFixtures.macAAddress,
            hardwarePort: "Thunderbolt 6", bridge: nil, disabledServices: ["Thunderbolt 6"]), "the record says what to restore")
        expect(fixed.message.contains("Darkbloom Cluster Link (en7)") && fixed.message.contains("--remove"), "the fixed message")
        expectNoAddress(compactJSON(fixed), "fixed JSON")
        expect(compactJSON(fixed).contains("\"isolated\":true"), "JSON says v2")
        expectEqual(a.fix().outcome, .alreadyReady, "a second run changes nothing")
        expectEqual(a.isolationRequests.count, 1, "and asks nothing")

        // Mac B as captured: Internet Sharing to the port stops it before a prompt.
        let b = FakeIsolationWorld(IsolationFixtures.macB)
        b.base.record.set(.init(interface: "en6", address: ClusterLinkLocalAddress(dottedDecimal: IsolationFixtures.macBLinkLocal)!))
        let refused = b.fix()
        expectEqual(refused.outcome, .isolationRefused([.internetSharingToPort]), "refused")
        expectEqual(refused.outcome.exitCode, 1, "refusal exit status")
        expect(b.isolationRequests.isEmpty, "no prompt")
        expect(refused.message.hasPrefix("Nothing was changed: Internet Sharing shares to en6 directly.")
            && refused.message.contains("“Thunderbolt 2” (en6)"), "refusal names the owner's step: \(refused.message)")
        expect(compactJSON(refused).contains("\"findings\":[\"internetSharingToPort\"]"), "refusal JSON")
        expectEqual(b.fix(dryRun: true).outcome, .isolationRefused([.internetSharingToPort]), "a dry run reports the same refusal")

        // After the owner's step: the approval takes it out of the bridge.
        b.tools = IsolationFixtures.macBUnshared
        let planned = b.fix(dryRun: true)
        expectEqual(planned.plannedCommands.first, "/bin/launchctl bootout system/io.darkbloom.cluster-link.en6 2>/dev/null || true",
            "the first version's keeper goes first")
        expect(planned.plannedCommands.contains("/sbin/ifconfig en6 inet \(IsolationFixtures.macBLinkLocal) -alias 2>/dev/null || true"),
            "and its address")
        b.isolationApproval = { request, world in
            guard case .isolate(let plan) = request.purpose, plan.bridge == .init(bridge: "bridge0", index: 1) else { return .commandFailed }
            world.tools = IsolationFixtures.macBIsolated()
            return .applied
        }
        let fixedB = b.fix()
        expectEqual(fixedB.outcome, .fixed, "Mac B fixed: \(fixedB.message)")
        expectEqual(b.isolationRecord.entry(on: "en6")?.bridge, .init(bridge: "bridge0", index: 1), "the bridge slot is recorded")
        expectEqual(b.base.record.alias(on: "en6"), nil, "the first version's entry is spent")

        // Declined, unavailable, failed, and applied without the effect.
        let declined = FakeIsolationWorld(IsolationFixtures.macA)
        declined.isolationApproval = { _, _ in .declined }
        expectEqual(declined.fix().outcome, .approvalDeclined, "declined")
        expectEqual(declined.isolationRecord.entries, [], "a declined first attempt leaves no record")
        let unavailable = FakeIsolationWorld(IsolationFixtures.macA)
        let noPrompt = unavailable.fix()
        expectEqual(noPrompt.outcome, .approvalUnavailable, "unavailable")
        expectEqual(noPrompt.manualCommands.first, "sudo /usr/sbin/networksetup -createnetworkservice 'Darkbloom Cluster Link (en7)' 'Thunderbolt 6'",
            "manual commands for an administrator")
        expect(!compactJSON(noPrompt).contains("sudo"), "manual commands stay out of JSON")
        expect(unavailable.isolationRecord.entry(on: "en7") != nil, "the entry stays for what an administrator may do")
        let partial = FakeIsolationWorld(IsolationFixtures.macA)
        partial.isolationApproval = { _, world in
            // The service was made, then a later command failed.
            world.tools.isolation.serviceOrder = .output(IsolationFixtures.macAServiceOrder(clusterService: true))
            return .commandFailed
        }
        expectEqual(partial.fix().outcome, .commandFailed, "command failed")
        expect(partial.isolationRecord.entry(on: "en7") != nil, "a partial change stays on record for --remove")
        let ineffective = FakeIsolationWorld(IsolationFixtures.macA)
        ineffective.isolationApproval = { _, _ in .applied }
        let unchanged = ineffective.fix()
        expectEqual(unchanged.outcome, .appliedButNotIsolated([.defaultRouteViaPort, .dnsViaPort, .dhcpLeaseOnPort,
            .clusterServiceMissing, .otherServiceOnPort]), "applied without the effect")
        expectEqual(ineffective.base.pauses, ClusterLinkRepair.isolationVerificationAttempts - 1, "bounded verification")
        let noRecord = FakeIsolationWorld(IsolationFixtures.macA)
        noRecord.isolationRecordFails = true
        expectEqual(noRecord.fix().outcome, .recordUnavailable, "an unreadable record stops it")
        let noMachine = FakeIsolationWorld(IsolationFixtures.macA)
        noMachine.base.machineIdentifier = nil
        expectEqual(noMachine.fix().outcome, .machineIdentityUnavailable, "no hardware identifier, no address")
        // --temporary keeps the first version's address-only fix.
        let temporary = FakeIsolationWorld(IsolationFixtures.macBUnshared)
        temporary.base.tools.interfaces = .output(IsolationFixtures.macBInterfaces(en6: [], bridgeMembers: ["en1", "en6", "en2"]))
        temporary.base.tools.details["rdma_en6"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en6"))
        let temporaryResult = ClusterLinkRepair.fix(device: nil, mode: .temporary, dryRun: true, in: temporary.environment)
        expectEqual(temporaryResult.isolated, nil, "--temporary is not v2")
        expectEqual(temporaryResult.plannedCommands, ["/sbin/ifconfig en6 inet 169.254.188.90 netmask 255.255.0.0 alias"], "address only")
    }

    static func isolationRemoveOutcomes() {
        let b = FakeIsolationWorld(IsolationFixtures.macBIsolated())
        b.isolationRecord.set(.init(interface: "en6", address: IsolationFixtures.macBAddress, hardwarePort: "Thunderbolt 2",
            bridge: .init(bridge: "bridge0", index: 1), disabledServices: []))
        let dry = b.remove(dryRun: true)
        expectEqual(dry.outcome, .dryRun, "remove dry run")
        expectEqual(dry.plannedCommands, [
            "/usr/libexec/PlistBuddy -c 'Add :VirtualNetworkInterfaces:Bridge:bridge0:Interfaces:1 string en6' /Library/Preferences/SystemConfiguration/preferences.plist",
            "/usr/sbin/networksetup -removenetworkservice 'Darkbloom Cluster Link (en6)'",
            "/sbin/ifconfig bridge0 addm en6",
        ], "the exact restore of Mac B")
        expect(b.isolationRequests.isEmpty && b.isolationRecord.entry(on: "en6") != nil, "a dry run asks and forgets nothing")
        b.isolationApproval = { _, world in
            var restored = IsolationFixtures.macBUnshared
            restored.keeperJobs = [:]
            restored.keeperJobFiles = [:]
            restored.interfaces = .output(IsolationFixtures.macBInterfaces(en6: [], bridgeMembers: ["en1", "en6", "en2"]))
            world.tools = restored
            return .applied
        }
        let removed = b.remove()
        expectEqual(removed.outcome, .removed, "removed: \(removed.message)")
        expectEqual(b.isolationRecord.entries, [], "the record is cleared")
        expect(removed.message.contains("as they were before"), "removed message")
        expectEqual(b.remove().outcome, .nothingRecorded, "nothing left falls through to the first version, which has nothing either")

        let a = FakeIsolationWorld(IsolationFixtures.macAIsolated())
        a.isolationRecord.set(.init(interface: "en7", address: IsolationFixtures.macAAddress, hardwarePort: "Thunderbolt 6",
            bridge: nil, disabledServices: ["Thunderbolt 6"]))
        expectEqual(a.remove(dryRun: true).plannedCommands, [
            "/usr/sbin/networksetup -removenetworkservice 'Darkbloom Cluster Link (en7)'",
            "/usr/sbin/networksetup -setnetworkserviceenabled 'Thunderbolt 6' on",
        ], "the exact restore of Mac A")
        a.isolationApproval = { _, _ in .applied }
        expectEqual(a.remove().outcome, .removalNotVerified, "an approval without the effect is not taken for a removal")
        expect(a.isolationRecord.entry(on: "en7") != nil, "and the record stays")
        a.isolationApproval = { _, world in
            world.tools = IsolationFixtures.macA
            return .commandFailed
        }
        expectEqual(a.remove().outcome, .removed, "what is left decides, not the exit status")

        // Everything already back: the entry is spent.
        let spent = FakeIsolationWorld(IsolationFixtures.macA)
        spent.isolationRecord.set(.init(interface: "en7", address: IsolationFixtures.macAAddress, hardwarePort: "Thunderbolt 6",
            bridge: nil, disabledServices: ["Thunderbolt 6"]))
        expectEqual(spent.remove().outcome, .alreadyAbsent, "nothing to undo")
        expectEqual(spent.isolationRecord.entries, [], "spent entry forgotten")
        // A service of Darkbloom's without a record.
        let orphan = FakeIsolationWorld(IsolationFixtures.macAIsolated())
        expectEqual(orphan.remove(dryRun: true).plannedCommands, ["/usr/sbin/networksetup -removenetworkservice 'Darkbloom Cluster Link (en7)'"],
            "an orphaned service is removed; nothing else is guessed")
        expectEqual(orphan.remove(device: "rdma_en6", dryRun: true).outcome, .nothingRecorded, "another device has nothing")
        let declined = FakeIsolationWorld(IsolationFixtures.macAIsolated())
        declined.isolationApproval = { _, _ in .declined }
        expectEqual(declined.remove().outcome, .approvalDeclined, "remove declined")
        let unreadable = FakeIsolationWorld(IsolationFixtures.macAIsolated())
        unreadable.isolationRecordFails = true
        expectEqual(unreadable.remove().outcome, .recordUnavailable, "unreadable record")
        // First-version worlds never take this path.
        expectEqual(FakeRepairWorld(IsolationFixtures.macAIsolated()).remove().outcome, .nothingRecorded, "a v1 world reads no services")
    }

    static func isolationRecordFile() {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".link-isolation-record-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        guard let paths = try? ClusterUserPaths(homeDirectory: home) else { return expect(false, "fixture paths") }
        let store = ClusterLinkIsolationStore(paths: paths)
        expectEqual(try? store.load(), ClusterLinkIsolationRecord(), "absent is empty")
        let entry = ClusterLinkIsolationRecord.Entry(interface: "en6", address: IsolationFixtures.macBAddress, hardwarePort: "Thunderbolt 2",
            bridge: .init(bridge: "bridge0", index: 1), disabledServices: [])
        expect((try? store.update { $0.set(entry) }) != nil, "write")
        expectEqual(try? store.load().entry(on: "en6"), entry, "read back")
        var metadata = stat()
        expect(lstat(paths.linkIsolationRecordFile.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600, "mode 0600")
        let text = (try? String(contentsOf: paths.linkIsolationRecordFile, encoding: .utf8)) ?? ""
        expectEqual(text, "{\"entries\":[{\"address\":\"10.219.188.90\",\"bridge\":\"bridge0\",\"bridgeIndex\":1,\"disabledServices\":[],\"hardwarePort\":\"Thunderbolt 2\",\"interface\":\"en6\"}],\"schema\":\"darkbloom_cluster_link_isolation_v1\"}",
            "canonical encoding")
        // A later attempt keeps the state before Darkbloom.
        var record = ClusterLinkIsolationRecord()
        record.set(entry)
        record.set(.init(interface: "en6", address: IsolationFixtures.macBAddress, hardwarePort: "Thunderbolt 2", bridge: nil,
            disabledServices: ["Other"]))
        expectEqual(record.entry(on: "en6")?.bridge, entry.bridge, "the first bridge slot is kept")
        expectEqual(record.entry(on: "en6")?.disabledServices, ["Other"], "services accumulate")
        for tampered in [text.replacingOccurrences(of: "10.219.188.90", with: "169.254.188.90"),
                         text.replacingOccurrences(of: "Thunderbolt 2", with: "Thunder'bolt"),
                         text.replacingOccurrences(of: "\"bridgeIndex\":1,", with: ""),
                         text.replacingOccurrences(of: "isolation_v1", with: "isolation_v2"),
                         text + " "] {
            expect((try? ClusterLinkIsolationRecord.decode(Data(tampered.utf8))) == nil, "tampered record refused")
        }
    }

    static func isolationSetupFlow() {
        // Mac A in a terminal: the approval, then done.
        var flow = ClusterLinkSetupFlow(mayPrompt: true)
        let report = FakeIsolationWorld(IsolationFixtures.macA).report()
        let step = flow.observed(report)
        expectEqual(step.action, .fix(device: "rdma_en7"), "Mac A: the flow asks for the fix")
        expect(step.lines.last?.contains("is not isolated: a default route leaves through en7") == true
            && step.lines.last?.contains("approve the macOS prompt to continue") == true, "Mac A: the reason and the prompt: \(step.lines)")
        let a = FakeIsolationWorld(IsolationFixtures.macA)
        a.isolationApproval = { _, world in
            world.tools = IsolationFixtures.macAIsolated()
            return .applied
        }
        let done = flow.repaired(a.fix())
        expectEqual(done.action, .finish(exitCode: 0), "Mac A done")
        expect(done.lines.first?.hasPrefix("Isolated: Thunderbolt port en7 has its own network service (Darkbloom Cluster Link (en7))") == true,
            "Mac A: what it has now")
        expectEqual(done.lines.last, "Run `darkbloom cluster` on the other Mac too.", "then the other Mac")
        var again = ClusterLinkSetupFlow(mayPrompt: true)
        let isolated = FakeIsolationWorld(IsolationFixtures.macAIsolated())
        isolated.isolationRecord.set(.init(interface: "en7", address: IsolationFixtures.macAAddress, hardwarePort: "Thunderbolt 6",
            bridge: nil, disabledServices: ["Thunderbolt 6"]))
        let readyStep = again.observed(isolated.report())
        expectEqual(readyStep.action, .finish(exitCode: 0), "an isolated Mac is done")
        expect(readyStep.lines.contains { $0.hasPrefix("Isolated:") }, "and says so")

        // Unattended: says what it found and what is next, prompts nothing.
        var unattended = ClusterLinkSetupFlow(mayPrompt: false)
        let quiet = unattended.observed(report)
        expectEqual(quiet.action, .finish(exitCode: 0), "a ready port stays usable while it waits for the owner")
        expect(quiet.lines.contains { $0.hasPrefix("Next: run `darkbloom cluster` in a terminal") }, "next step")
        // Dry run: words the finding, then plans.
        var dry = ClusterLinkSetupFlow(mayPrompt: true, dryRun: true)
        expectEqual(dry.observed(report).action, .fix(device: "rdma_en7"), "a dry run plans the fix")
        let planned = dry.repaired(FakeIsolationWorld(IsolationFixtures.macA).fix(dryRun: true))
        expectEqual(planned.lines.count, 6, "message and five commands")

        // Mac B as captured: the refusal and what the owner can do, with the link still usable.
        var flowB = ClusterLinkSetupFlow(mayPrompt: true)
        let b = FakeIsolationWorld(IsolationFixtures.macB)
        b.base.record.set(.init(interface: "en6", address: ClusterLinkLocalAddress(dottedDecimal: IsolationFixtures.macBLinkLocal)!))
        let stepB = flowB.observed(b.report())
        expectEqual(stepB.action, .fix(device: "rdma_en6"), "Mac B: the fix is tried and refuses before a prompt")
        expect(stepB.lines.last?.contains("approve the macOS prompt") == false, "no prompt is announced")
        let refusedB = flowB.repaired(b.fix())
        expectEqual(refusedB.action, .finish(exitCode: 0), "the link is still ready")
        expect(refusedB.lines.first?.contains("Darkbloom does not change Internet Sharing") == true, "the owner's step")
        expect(b.isolationRequests.isEmpty, "no prompt on Mac B")
        // Declined on a ready port: nothing lost.
        var declinedFlow = ClusterLinkSetupFlow(mayPrompt: true)
        _ = declinedFlow.observed(report)
        let declined = declinedFlow.repaired(.init(operation: .fix, outcome: .approvalDeclined, device: "rdma_en7", interface: "en7",
            durable: true, isolated: true))
        expect(declined.lines.first?.contains("not isolated yet") == true, "declined wording")
        expectEqual(declined.action, .finish(exitCode: 0), "a ready port stays usable")
    }

    static func launchReadiness() {
        typealias Wait = ClusterLinkLaunchReadiness
        let ready = FakeLinkTools.macA.inspect().report
        let bridged = FakeLinkTools.macB.inspect().report
        expectEqual(Wait.decide(ready, device: "rdma_en7", elapsedSeconds: 0), .launch, "ready launches")
        expectEqual(Wait.decide(bridged, device: "rdma_en6", elapsedSeconds: 0), .wait, "a port without its address is waited for")
        expectEqual(Wait.decide(bridged, device: "rdma_en6", elapsedSeconds: 20), .refuse(.portBridgedWithoutAddress), "then refused")
        expectEqual(Wait.decide(ready, device: "rdma_en2", elapsedSeconds: 20), .refuse(.noActivePort), "an inactive configured port")
        expectEqual(Wait.decide(ready, device: "rdma_en9", elapsedSeconds: 3), .wait, "an unlisted device is waited for")
        expectEqual(Wait.decide(ready, device: "rdma_en9", elapsedSeconds: 20), .launch, "and then left to JACCL")
        var disabled = FakeLinkTools.macA
        disabled.controlStatus = .output("disabled\n")
        expectEqual(Wait.decide(disabled.inspect().report, device: "rdma_en7", elapsedSeconds: 0), .refuse(.rdmaDisabled), "RDMA off: at once")
        var broken = FakeLinkTools.macA
        broken.interfaces = .timedOut
        expectEqual(Wait.decide(broken.inspect().report, device: "rdma_en7", elapsedSeconds: 20), .launch, "an unreadable probe does not block")

        // The loop over a fake clock: the address comes back after 4 s.
        var clock: UInt64 = 1_000_000_000, sleeps = 0, readings = 0
        let comesBack: () -> ClusterLinkReadinessReport = {
            readings += 1
            return readings >= 5 ? FakeLinkTools.macBFixed().inspect().report : bridged
        }
        let tick: (Int) -> Void = { seconds in sleeps += 1; clock += UInt64(seconds) * 1_000_000_000 }
        do {
            try Wait.waitForLink(device: "rdma_en6", inspect: comesBack, sleep: tick, uptimeNanoseconds: { clock })
            expectEqual(sleeps, 4, "launched after four one-second waits")
        } catch { expect(false, "unexpected refusal \(error)") }
        clock = 0; sleeps = 0
        do {
            try Wait.waitForLink(device: "rdma_en6", inspect: { bridged }, sleep: tick, uptimeNanoseconds: { clock })
            expect(false, "a port that never comes back is refused")
        } catch let error as ClusterLinkNotReady {
            expectEqual(error.state, .portBridgedWithoutAddress, "refusal state")
            expectEqual(error.waitedSeconds, 20, "after the whole wait")
            expectEqual(sleeps, 20, "twenty polls")
            expect(error.description.contains("rdma_en6 is portBridgedWithoutAddress after waiting 20 s")
                && error.description.contains("IPv4-mapped GID"), "the refusal explains itself")
            expectNoAddress(error.description, "refusal text")
        } catch { expect(false, "unexpected error \(error)") }
        // A slow reading counts against the wait.
        clock = 0; sleeps = 0
        do {
            try Wait.waitForLink(device: "rdma_en6", inspect: { clock += 7_000_000_000; return bridged }, sleep: tick,
                uptimeNanoseconds: { clock })
        } catch let error as ClusterLinkNotReady {
            expect(error.waitedSeconds >= 20 && sleeps <= 3, "slow readings end the wait on time: \(error.waitedSeconds) s, \(sleeps) sleeps")
        } catch { expect(false, "unexpected error \(error)") }
        expectEqual(Wait.waitSeconds, 20, "the bound")
    }

    static func isolationVocabulary() {
        expectEqual(ClusterLinkIsolationFinding.allCases.map(\.rawValue), ["portInBridge", "internetSharingOverPortBridge",
            "internetSharingToPort", "portInUnmanagedBridge", "defaultRouteViaPort", "dnsViaPort", "dhcpLeaseOnPort",
            "portAddressMissing", "clusterServiceMissing", "clusterServiceMisconfigured", "otherServiceOnPort", "clusterSubnetInUse",
            "serviceNameUnsafe", "hardwarePortUnknown", "stateUnreadable"], "stable finding codes")
        expectEqual(ClusterLinkIsolationFinding.allCases.filter(\.blocksApproval), [.internetSharingToPort, .portInUnmanagedBridge,
            .clusterSubnetInUse, .serviceNameUnsafe, .hardwarePortUnknown, .stateUnreadable], "what only the owner can clear")
        for finding in ClusterLinkIsolationFinding.allCases {
            let fact = finding.fact(interface: "en6", bridge: "bridge0")
            let remedy = finding.remedy(interface: "en6", bridge: "bridge0", hardwarePort: "Thunderbolt 2")
            expect(!fact.isEmpty && !remedy.isEmpty, "\(finding) has a fact and a remedy")
            expectNoAddress(fact + remedy, "\(finding) text")
            expect(finding.blocksApproval == !remedy.hasPrefix("the approval"), "\(finding): the remedy says who acts")
        }
        for outcome in [ClusterLinkRepairOutcome.isolationRefused([.internetSharingToPort]), .appliedButNotIsolated([.portInBridge])] {
            for operation in [ClusterLinkRepairResult.Operation.fix, .remove] {
                let result = ClusterLinkRepairResult(operation: operation, outcome: outcome, device: "rdma_en6", interface: "en6",
                    isolated: true, hardwarePort: "Thunderbolt 2", bridge: "bridge0")
                expect(result.message.hasSuffix("."), "\(outcome.code) message")
                expectNoAddress(compactJSON(result) + result.message, "\(outcome.code) text")
                expect(!compactJSON(result).contains("hardwarePort"), "the hardware port is no field of its own")
            }
        }
        expectEqual(ClusterLinkRepairOutcome.isolationRefused([]).code, "isolationRefused", "code")
        expectEqual(ClusterLinkRepairOutcome.appliedButNotIsolated([]).exitCode, 4, "exit status")
    }
}
