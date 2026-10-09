import Foundation

extension ClusterLinkCheck {
    private typealias Device = ClusterLinkReadinessReport.Device

    private static func inactive(_ number: Int, bridge: String? = nil) -> Device {
        .init(device: "rdma_en\(number)", interface: "en\(number)", transport: .thunderbolt, portActive: false,
            interfaceActive: false, interfaceHasIPv4Address: false, bridge: bridge,
            ipv4MappedGIDPresent: nil, verdict: .noActivePort)
    }

    static func commandSet() {
        let commands: [ClusterLinkToolCommand] = [.rdmaControlStatus, .rdmaDeviceList, .rdmaDeviceDetail(device: "rdma_en7"), .interfaceList]
        expectEqual(commands.map(\.executable), ["/usr/bin/rdma_ctl", "/usr/bin/ibv_devinfo", "/usr/bin/ibv_devinfo", "/sbin/ifconfig"],
            "fixed absolute tool paths")
        expectEqual(commands.map(\.arguments), [["status"], [], ["-v", "-d", "rdma_en7"], ["-a"]], "read-only arguments")
    }

    static func macAReport() {
        let (report, commands) = FakeLinkTools.macA.inspect()
        expectEqual(report.state, .ready, "Mac A state")
        expectEqual(report.guidance, nil, "ready carries no guidance")
        expectEqual(report.schema, "darkbloom_cluster_link_readiness_v1", "schema")
        expectEqual(report.physicalProbePerformed, false, "no physical probe")
        let ready = Device(device: "rdma_en7", interface: "en7", transport: .thunderbolt, portActive: true,
            interfaceActive: true, interfaceHasIPv4Address: true, bridge: nil, ipv4MappedGIDPresent: true, verdict: .ready)
        expectEqual(report.devices, (2...6).map { inactive($0) } + [ready], "Mac A devices")
        // GID tables are read for active ports only, after one interface listing.
        expectEqual(commands, [.rdmaControlStatus, .rdmaDeviceList, .interfaceList, .rdmaDeviceDetail(device: "rdma_en7")],
            "Mac A commands")
    }

    static func macBReport() {
        let (report, commands) = FakeLinkTools.macB.inspect()
        expectEqual(report.state, .portBridgedWithoutAddress, "Mac B state")
        expectEqual(report.guidance, ClusterLinkReadinessState.portBridgedWithoutAddress.guidance, "Mac B guidance")
        let blocked = Device(device: "rdma_en6", interface: "en6", transport: .thunderbolt, portActive: true,
            interfaceActive: true, interfaceHasIPv4Address: false, bridge: "bridge0", ipv4MappedGIDPresent: false,
            verdict: .portBridgedWithoutAddress)
        expectEqual(report.devices, (2...5).map { inactive($0, bridge: "bridge0") } + [blocked, inactive(7, bridge: "bridge0")],
            "Mac B devices")
        expectEqual(commands.last, .rdmaDeviceDetail(device: "rdma_en6"), "Mac B reads only the active port's GID table")
        expectEqual(commands.count, 4, "Mac B command count")
    }

    static func machineStates() {
        var disabled = FakeLinkTools.macA
        disabled.controlStatus = .output("disabled\n")
        let (disabledReport, disabledCommands) = disabled.inspect()
        expectEqual(disabledReport.state, .rdmaDisabled, "disabled RDMA")
        expectEqual(disabledReport.devices, [], "disabled RDMA lists no device")
        expectEqual(disabledCommands, [.rdmaControlStatus], "nothing further runs once RDMA is disabled")

        var missingControl = FakeLinkTools.macA
        missingControl.controlStatus = .unavailable
        let (missingReport, missingCommands) = missingControl.inspect()
        expectEqual(missingReport.state, .rdmaUnavailable, "rdma_ctl missing")
        expectEqual(missingCommands, [.rdmaControlStatus], "nothing further runs without rdma_ctl")

        var noDevices = FakeLinkTools.macA
        noDevices.deviceList = .unavailable
        expectEqual(noDevices.inspect().report.state, .rdmaUnavailable, "ibv_devinfo missing or reporting no device")

        var down = FakeLinkTools.macA
        down.deviceList = .output(LinkFixtures.deviceList(active: nil))
        let (downReport, downCommands) = down.inspect()
        expectEqual(downReport.state, .noActivePort, "no active port")
        expectEqual(downReport.devices.map(\.verdict), Array(repeating: .noActivePort, count: 6), "every port down")
        expectEqual(downCommands, [.rdmaControlStatus, .rdmaDeviceList, .interfaceList], "no GID table is read without an active port")
    }

    static func portStates() {
        var unaddressed = FakeLinkTools.macA
        unaddressed.interfaces = .output(LinkFixtures.loopback + LinkFixtures.port("en7", active: true, ipv4: nil))
        unaddressed.details["rdma_en7"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en7"))
        let unaddressedDevice = unaddressed.inspect().report.devices.last
        expectEqual(unaddressed.inspect().report.state, .portWithoutIPv4Address, "active port without an address")
        expectEqual(unaddressedDevice?.interfaceHasIPv4Address, false, "no address fact")
        expectEqual(unaddressedDevice?.bridge, nil, "not bridged")

        var unpublished = FakeLinkTools.macA
        unpublished.details["rdma_en7"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en7"))
        expectEqual(unpublished.inspect().report.state, .gidNotPublished, "address present, GID missing")

        // A bridge member that also has its own address is not the bridge case.
        var bridgedWithAddress = FakeLinkTools.macB
        bridgedWithAddress.interfaces = .output(LinkFixtures.port("en6", active: true, ipv4: LinkFixtures.portIPv4)
            + LinkFixtures.bridge(members: ["en6"]))
        expectEqual(bridgedWithAddress.inspect().report.state, .gidNotPublished, "bridged port with its own address")

        // The GID is what JACCL needs; a published GID is ready whatever else is listed.
        var bridgedButPublished = FakeLinkTools.macB
        bridgedButPublished.details["rdma_en6"] = .output(LinkFixtures.detailWithMappedGID("rdma_en6"))
        expectEqual(bridgedButPublished.inspect().report.state, .ready, "published GID decides readiness")

        let foreign = FakeLinkTools(deviceList: .output(LinkFixtures.deviceBlock("mlx5_0", active: true, transport: "InfiniBand (0)")),
            interfaces: .output(LinkFixtures.macAInterfaces),
            details: ["mlx5_0": .output(LinkFixtures.detailWithoutMappedGID("mlx5_0"))])
        let foreignDevice = foreign.inspect().report.devices.first
        expectEqual(foreignDevice?.interface, nil, "no interface is guessed for an unconventional device name")
        expectEqual(foreignDevice?.interfaceHasIPv4Address, nil, "unknown interface facts stay unknown")
        expectEqual(foreignDevice?.verdict, .gidNotPublished, "unconventional device without a GID")

        var unlisted = FakeLinkTools.macA
        unlisted.interfaces = .output(LinkFixtures.loopback)
        unlisted.details["rdma_en7"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en7"))
        let unlistedDevice = unlisted.inspect().report.devices.last
        expectEqual(unlistedDevice?.interface, "en7", "interface name is still derived")
        expectEqual(unlistedDevice?.interfaceActive, nil, "unlisted interface has no facts")
        expectEqual(unlistedDevice?.verdict, .gidNotPublished, "unlisted interface without a GID")
    }

    static func toolFailures() {
        var garbledStatus = FakeLinkTools.macA
        garbledStatus.controlStatus = .output("maybe\n")
        expectEqual(garbledStatus.inspect().report.state, .probeFailed, "garbled rdma_ctl status")

        for failure in [ClusterLinkToolOutcome.timedOut, .outputTooLarge] {
            var status = FakeLinkTools.macA, list = FakeLinkTools.macA, interfaces = FakeLinkTools.macA, detail = FakeLinkTools.macA
            status.controlStatus = failure; list.deviceList = failure; interfaces.interfaces = failure
            detail.details["rdma_en7"] = failure
            expectEqual(status.inspect().report.state, .probeFailed, "rdma_ctl \(failure)")
            expectEqual(status.inspect().commands.count, 1, "rdma_ctl \(failure) stops the inspection")
            expectEqual(list.inspect().report.state, .probeFailed, "ibv_devinfo \(failure)")
            expectEqual(list.inspect().report.devices, [], "ibv_devinfo \(failure) lists no device")
            expectEqual(interfaces.inspect().report.state, .probeFailed, "ifconfig \(failure)")
            expectEqual(interfaces.inspect().commands.count, 3, "ifconfig \(failure) stops before any GID table")
            let detailReport = detail.inspect().report
            expectEqual(detailReport.state, .probeFailed, "device detail \(failure)")
            expectEqual(detailReport.devices.last?.verdict, .probeFailed, "device detail \(failure) verdict")
            expectEqual(detailReport.devices.last?.ipv4MappedGIDPresent, nil, "device detail \(failure) leaves the GID fact unknown")
            expectEqual(detailReport.devices.count, 6, "device detail \(failure) still lists every device")
        }

        var garbledList = FakeLinkTools.macA
        garbledList.deviceList = .output("unexpected text\n")
        expectEqual(garbledList.inspect().report.state, .probeFailed, "garbled device list")

        var missingInterfaces = FakeLinkTools.macA
        missingInterfaces.interfaces = .unavailable
        expectEqual(missingInterfaces.inspect().report.state, .probeFailed, "ifconfig unavailable")
        var garbledInterfaces = FakeLinkTools.macA
        garbledInterfaces.interfaces = .output("unexpected text\n")
        expectEqual(garbledInterfaces.inspect().report.state, .probeFailed, "garbled ifconfig")

        var missingDetail = FakeLinkTools.macA
        missingDetail.details = [:]
        expectEqual(missingDetail.inspect().report.state, .probeFailed, "device detail unavailable")
        var wrongDetail = FakeLinkTools.macA
        wrongDetail.details["rdma_en7"] = .output(LinkFixtures.detailWithMappedGID("rdma_en2"))
        expectEqual(wrongDetail.inspect().report.state, .probeFailed, "device detail for another device")

        let crowd = (0..<33).map { LinkFixtures.deviceBlock("rdma_en\($0)", active: true) }.joined()
        var crowded = FakeLinkTools.macA
        crowded.deviceList = .output(crowd)
        let (crowdedReport, crowdedCommands) = crowded.inspect()
        expectEqual(crowdedReport.state, .probeFailed, "more devices than the inspection bound")
        expectEqual(crowdedCommands.count, 2, "an oversized listing spawns no per-device child")
    }

    static func severalActivePorts() {
        let twoActive = LinkFixtures.deviceBlock("rdma_en6", active: true) + LinkFixtures.deviceBlock("rdma_en7", active: true)
        let interfaces = LinkFixtures.port("en6", active: true, ipv4: nil)
            + LinkFixtures.port("en7", active: true, ipv4: LinkFixtures.portIPv4) + LinkFixtures.bridge(members: ["en6"])
        var tools = FakeLinkTools(deviceList: .output(twoActive), interfaces: .output(interfaces), details: [
            "rdma_en6": .output(LinkFixtures.detailWithoutMappedGID("rdma_en6")),
            "rdma_en7": .output(LinkFixtures.detailWithMappedGID("rdma_en7"))])
        let (mixed, commands) = tools.inspect()
        expectEqual(mixed.state, .ready, "one ready port is enough")
        expectEqual(mixed.devices.map(\.verdict), [.portBridgedWithoutAddress, .ready], "each port keeps its own verdict")
        expectEqual(Array(commands.suffix(2)), [.rdmaDeviceDetail(device: "rdma_en6"), .rdmaDeviceDetail(device: "rdma_en7")],
            "one GID read per active port")

        tools.details["rdma_en7"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en7"))
        let blocked = tools.inspect().report
        expectEqual(blocked.devices.map(\.verdict), [.portBridgedWithoutAddress, .gidNotPublished], "two blocked ports")
        expectEqual(blocked.state, .portBridgedWithoutAddress, "the first active port names the overall state")
    }

    static func stateVocabulary() {
        expectEqual(ClusterLinkReadinessState.allCases.map(\.rawValue), ["ready", "rdmaDisabled", "rdmaUnavailable", "noActivePort",
            "portWithoutIPv4Address", "portBridgedWithoutAddress", "gidNotPublished", "probeFailed"], "stable state codes")
        expectEqual(ClusterLinkReadinessState.ready.guidance, nil, "ready needs no guidance")
        for state in ClusterLinkReadinessState.allCases where state != .ready {
            guard let guidance = state.guidance else { expect(false, "\(state) has no guidance"); continue }
            expect(guidance.hasSuffix(".") && !guidance.dropLast().contains(". ") && !guidance.contains("\n"),
                "\(state) guidance is one sentence")
            expect(guidance.contains("Darkbloom will not") || guidance.contains("Darkbloom cannot"),
                "\(state) guidance says Darkbloom does not make the change")
            expect((40...320).contains(guidance.count), "\(state) guidance length")
        }
        let disabled = ClusterLinkReadinessState.rdmaDisabled.guidance ?? ""
        expect(disabled.contains("macOS Recovery") && disabled.contains("rdma_ctl enable"), "disabled guidance names the Recovery command")
        let bridged = ClusterLinkReadinessState.portBridgedWithoutAddress.guidance ?? ""
        expect(bridged.contains("Thunderbolt Bridge") && bridged.contains("System Settings → Network") && bridged.contains("bridge"),
            "bridged guidance names the bridge and where to change it")
        expect((ClusterLinkReadinessState.portWithoutIPv4Address.guidance ?? "").contains("IPv4 address"), "unaddressed guidance")
        expect((ClusterLinkReadinessState.noActivePort.guidance ?? "").contains("Thunderbolt 5 cable"), "no-port guidance")
    }

    private static func json(_ report: ClusterLinkReadinessReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func namesOnlyOutput() {
        let patterns = [
            "IPv4 address": #"[0-9]{1,3}(\.[0-9]{1,3}){3}"#,
            "MAC address": #"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}"#,
            "GID or IPv6 address": #"[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,}"#,
        ]
        func expectNamesOnly(_ text: String, _ label: String) {
            expect(!text.isEmpty, "\(label) is not empty")
            for (kind, pattern) in patterns {
                expect(text.range(of: pattern, options: .regularExpression) == nil, "\(label) contains no \(kind)")
            }
            for secret in LinkFixtures.sensitive {
                expect(!text.contains(secret), "\(label) does not contain fixture value \(secret)")
            }
        }
        for (label, tools) in [("Mac A", FakeLinkTools.macA), ("Mac B", FakeLinkTools.macB)] {
            let report = tools.inspect().report
            let encoded = json(report)
            expectNamesOnly(encoded, "\(label) JSON")
            expectNamesOnly(report.summaryLines.joined(separator: "\n"), "\(label) summary")
            expect(encoded.contains("\"schema\" : \"darkbloom_cluster_link_readiness_v1\""), "\(label) JSON schema")
            expect(encoded.contains("\"physicalProbePerformed\" : false"), "\(label) JSON states no physical probe")
        }
        let encodedA = json(FakeLinkTools.macA.inspect().report)
        expect(encodedA.contains("\"device\" : \"rdma_en7\"") && encodedA.contains("\"interface\" : \"en7\""), "names are reported")
        expect(encodedA.contains("\"ipv4MappedGIDPresent\" : true") && encodedA.contains("\"state\" : \"ready\""), "facts are reported")
        let encodedB = json(FakeLinkTools.macB.inspect().report)
        expect(encodedB.contains("\"bridge\" : \"bridge0\"") && encodedB.contains("\"verdict\" : \"portBridgedWithoutAddress\""),
            "bridge membership is reported")

        // A tool that printed an address where a name belongs yields no device at all.
        var hostile = FakeLinkTools.macA
        hostile.deviceList = .output(LinkFixtures.deviceBlock(LinkFixtures.portIPv4, active: true))
        let hostileReport = hostile.inspect().report
        expectEqual(hostileReport.state, .probeFailed, "address-shaped device name")
        expectNamesOnly(json(hostileReport), "address-shaped device name JSON")
    }

    static func operatorSummary() {
        let macA = FakeLinkTools.macA.inspect().report.summaryLines
        expectEqual(macA.first, "Local link: ready", "Mac A headline")
        expectEqual(macA.count, 8, "Mac A: headline, six devices, scope")
        expectEqual(macA.dropFirst().first, "  rdma_en2 (en2): noActivePort · port down", "inactive device line")
        expectEqual(macA.dropFirst(6).first, "  rdma_en7 (en7): ready · port active · own IPv4 address · IPv4-mapped GID published",
            "ready device line")
        expectEqual(macA.last, "Local interface state only: no peer was contacted and no collective ran.", "scope line")

        let report = FakeLinkTools.macB.inspect().report
        let macB = report.summaryLines
        expectEqual(macB.first, "Local link: portBridgedWithoutAddress", "Mac B headline")
        expectEqual(macB.dropFirst(5).first,
            "  rdma_en6 (en6): portBridgedWithoutAddress · port active · member of bridge0 · no IPv4 address of its own · no IPv4-mapped GID",
            "blocked device line")
        expectEqual(macB.dropFirst().first, "  rdma_en2 (en2): noActivePort · port down · member of bridge0", "inactive bridge member line")
        expectEqual(macB.last, report.guidance, "guidance closes a not-ready summary")
        expectEqual(macB.count, 8, "Mac B: headline, six devices, guidance")

        var disabled = FakeLinkTools.macA
        disabled.controlStatus = .output("disabled\n")
        let disabledReport = disabled.inspect().report
        expectEqual(disabledReport.summaryLines, ["Local link: rdmaDisabled", disabledReport.guidance ?? ""], "machine-level summary")

        var failedDetail = FakeLinkTools.macA
        failedDetail.details["rdma_en7"] = .timedOut
        expectEqual(failedDetail.inspect().report.summaryLines.dropFirst(6).first,
            "  rdma_en7 (en7): probeFailed · port active · own IPv4 address · GID table not read", "unread GID table line")

        let foreign = FakeLinkTools(deviceList: .output(LinkFixtures.deviceBlock("mlx5_0", active: true, transport: "InfiniBand (0)")),
            interfaces: .output(LinkFixtures.macAInterfaces),
            details: ["mlx5_0": .output(LinkFixtures.detailWithoutMappedGID("mlx5_0"))])
        expectEqual(foreign.inspect().report.summaryLines.dropFirst().first,
            "  mlx5_0: gidNotPublished · port active · interface not identified · no IPv4-mapped GID", "unconventional device line")
    }
}
