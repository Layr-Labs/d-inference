import Foundation

extension ClusterLinkCheck {
    private typealias Device = ClusterLinkReadinessReport.Device

    private static func inactive(_ number: Int, bridge: String? = nil) -> Device {
        .init(device: "rdma_en\(number)", interface: "en\(number)", transport: .thunderbolt, portActive: false,
            interfaceActive: false, interfaceHasIPv4Address: false, bridge: bridge,
            ipv4MappedGIDPresent: nil, verdict: .noActivePort)
    }

    static func commandSet() {
        let commands: [ClusterLinkToolCommand] = [.rdmaControlStatus, .rdmaDeviceList, .rdmaDeviceDetail(device: "rdma_en7"),
            .interfaceList, .defaultRoute]
        expectEqual(commands.map(\.executable),
            ["/usr/bin/rdma_ctl", "/usr/bin/ibv_devinfo", "/usr/bin/ibv_devinfo", "/sbin/ifconfig", "/sbin/route"],
            "fixed absolute tool paths")
        expectEqual(commands.map(\.arguments), [["status"], [], ["-v", "-d", "rdma_en7"], ["-a"], ["-n", "get", "default"]],
            "read-only arguments")
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
            expect((40...320).contains(guidance.count), "\(state) guidance length")
            // Either the fix can add the missing address after approval, or
            // the sentence says plainly that Darkbloom does not do this.
            if state.fixableByAddingAddress {
                expect(guidance.contains("`darkbloom cluster link --fix`") && guidance.contains("approval in a macOS prompt")
                    && guidance.contains("System Settings → Network"), "\(state) guidance offers the fix and the manual way")
                expect(!guidance.contains("will not") && !guidance.contains("cannot"), "\(state) guidance does not deny the fix")
            } else {
                expect(guidance.contains("Darkbloom will not") || guidance.contains("Darkbloom cannot"),
                    "\(state) guidance says Darkbloom does not make the change")
            }
        }
        expectEqual(ClusterLinkReadinessState.allCases.filter(\.fixableByAddingAddress),
            [.portWithoutIPv4Address, .portBridgedWithoutAddress], "the two states the fix can act on")
        let disabled = ClusterLinkReadinessState.rdmaDisabled.guidance ?? ""
        expect(disabled.contains("macOS Recovery") && disabled.contains("rdma_ctl enable"), "disabled guidance names the Recovery command")
        expect((ClusterLinkReadinessState.portBridgedWithoutAddress.guidance ?? "").contains("Thunderbolt Bridge"),
            "bridged guidance names the bridge")
        expect((ClusterLinkReadinessState.portWithoutIPv4Address.guidance ?? "").contains("IPv4 address"), "unaddressed guidance")
        expect((ClusterLinkReadinessState.noActivePort.guidance ?? "").contains("Thunderbolt 5 cable"), "no-port guidance")
        let unpublished = ClusterLinkReadinessState.gidNotPublished.guidance ?? ""
        expect(unpublished.contains("--fix") && unpublished.contains("only adds a missing address"),
            "unpublished guidance says why the fix does not apply")
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

    /// Whether an address Darkbloom gave a port is still there, as the
    /// read-only inspection reports it.
    static func assignedAddressReport() {
        guard let given = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20") else { expect(false, "fixture address"); return }
        let record = ClusterLinkAliasRecord(aliases: [.init(interface: "en6", address: given)])
        func inspect(_ tools: FakeLinkTools, _ recorded: ClusterLinkAliasRecord) -> ClusterLinkReadinessReport {
            ClusterLinkReadinessProbe.inspect(run: tools.outcome(of:), recorded: recorded)
        }
        let lostGuidance = ClusterLinkReadinessReport.addressLostGuidance
        let temporaryGuidance = ClusterLinkReadinessReport.addressTemporaryGuidance
        expect(lostGuidance.contains("does not have the address Darkbloom has on record") && temporaryGuidance.contains("Nothing keeps the address"),
            "what each guidance is about")
        for guidance in [lostGuidance, temporaryGuidance] {
            expect(guidance.contains("run `darkbloom cluster` to") && !guidance.contains("--fix")
                && guidance.contains("approval in a macOS prompt") && guidance.hasSuffix(".") && !guidance.dropLast().contains(". "),
                "guidance about an assigned address is one sentence naming the one command")
        }
        // True also where an earlier attempt never got the address onto the port.
        expect(!lostGuidance.contains("removed it") && !lostGuidance.contains("put it back") && !lostGuidance.contains("earlier"),
            "nothing is claimed about how it went missing")

        // Configured earlier and now missing: said plainly, with the one command to run.
        let lost = inspect(.macB, record)
        expectEqual(lost.state, .portBridgedWithoutAddress, "the state code is unchanged by a lost address")
        expectEqual(lost.devices.map(\.assignedAddress), [nil, nil, nil, nil, .missing, nil], "only the recorded port is marked")
        expectEqual(lost.guidance, lostGuidance, "a lost address has its own guidance")
        expectEqual(lost.summaryLines.dropFirst(5).first,
            "  rdma_en6 (en6): portBridgedWithoutAddress · port active · member of bridge0 · no IPv4 address of its own · no IPv4-mapped GID · its recorded address is missing",
            "lost address in the device line")
        expectEqual(lost.summaryLines.last, lostGuidance, "lost-address guidance closes the summary")
        expect(json(lost).contains("\"assignedAddress\" : \"missing\""), "lost address in JSON")
        for secret in ["169.254", "10.20"] { expect(!json(lost).contains(secret) && !lost.summaryLines.joined().contains(secret), "the address itself is not shown") }

        expectEqual(lost.devices.map(\.addressKept), [nil, nil, nil, nil, false, nil], "and nothing keeps it")

        // Still there, with the job that keeps it: reported as present and kept, nothing to do.
        var keptTools = FakeLinkTools.macBFixed(address: "169.254.10.20")
        keptTools.installKeeper(interface: "en6", address: "169.254.10.20")
        let kept = inspect(keptTools, record)
        expectEqual(kept.state, .ready, "kept address state")
        expectEqual(kept.devices.map(\.assignedAddress), [nil, nil, nil, nil, .present, nil], "kept address is marked present")
        expectEqual(kept.devices.map(\.addressKept), [nil, nil, nil, nil, true, nil], "and marked kept")
        expectEqual(kept.guidance, nil, "a kept address needs no guidance")
        expectEqual(kept.summaryLines.last, ClusterLinkReadinessReport.readyScope, "a kept address reads like any ready link")
        expect(json(kept).contains("\"assignedAddress\" : \"present\"") && json(kept).contains("\"addressKept\" : true"),
            "kept address in JSON")

        // Still there, but nothing would put it back: ready, and said to be at risk before it is lost.
        let temporary = inspect(.macBFixed(address: "169.254.10.20"), record)
        expectEqual([temporary.state, temporary.devices[4].verdict], [.ready, .ready], "a temporary address is still a ready link")
        expectEqual(temporary.devices[4].addressKept, false, "a temporary address is not kept")
        expectEqual(temporary.guidance, temporaryGuidance, "a temporary address has its own guidance")
        expectEqual(Array(temporary.summaryLines.suffix(2)), [temporaryGuidance, ClusterLinkReadinessReport.readyScope],
            "the guidance comes before the scope of a ready result")
        expect(temporary.summaryLines.dropFirst(5).first?.hasSuffix(" · nothing keeps its address") == true, "temporary address in the device line")
        // A keeper reading that could not finish says neither: nothing is claimed about the address.
        var unread = FakeLinkTools.macBFixed(address: "169.254.10.20")
        unread.keeperJobs["en6"] = .timedOut
        expectEqual(inspect(unread, record).devices[4].addressKept, nil, "an unread keeper is not reported either way")
        expectEqual(inspect(unread, record).guidance, nil, "and no guidance is built on it")
        expect(json(temporary).contains("\"addressKept\" : false"), "temporary address in JSON")
        // A job for another address, or one that is not loaded, keeps nothing.
        var otherJob = FakeLinkTools.macBFixed(address: "169.254.10.20"), unloaded = keptTools
        otherJob.installKeeper(interface: "en6", address: "169.254.10.21")
        unloaded.keeperJobs = [:]
        expectEqual([inspect(otherJob, record).guidance, inspect(unloaded, record).guidance], [temporaryGuidance, temporaryGuidance],
            "only the keeper as written, and loaded, counts")
        // The two extra readings are made only for a port on record.
        var commands = [ClusterLinkToolCommand]()
        _ = ClusterLinkReadinessProbe.inspect(run: { commands.append($0); return keptTools.outcome(of: $0) }, recorded: record)
        expectEqual(commands.filter { $0 == .keeperJob(interface: "en6") || $0 == .keeperJobFile(interface: "en6") }.count, 2,
            "the keeper of a recorded port is read once")
        expect(!FakeLinkTools.macB.inspect().commands.contains { if case .keeperJob = $0 { return true } else { return false } },
            "no keeper is looked for without a record")

        // Nothing recorded: the plain guidance and no extra field.
        let never = inspect(.macB, ClusterLinkAliasRecord())
        expectEqual(never.guidance, ClusterLinkReadinessState.portBridgedWithoutAddress.guidance, "no record, plain guidance")
        expect(never.devices.allSatisfy { $0.assignedAddress == nil && $0.addressKept == nil } && !json(never).contains("assignedAddress")
            && !json(never).contains("addressKept"), "no record, no field")
        expectEqual(FakeLinkTools.macB.inspect().report, never, "the default inspection assumes no record")

        // The port has some other address now: Darkbloom's is gone, but the port is ready, so nothing is asked.
        let replaced = inspect(.macBFixed(address: "169.254.10.21"), record)
        expectEqual(replaced.devices[4].assignedAddress, .missing, "another address is not the assigned one")
        expectEqual([replaced.state, replaced.devices[4].verdict], [.ready, .ready], "a ready port stays ready")
        expectEqual(replaced.guidance, nil, "a ready port needs no guidance")

        // The recorded port is down: the cable comes first.
        var down = FakeLinkTools.macB
        down.deviceList = .output(LinkFixtures.deviceList(active: nil))
        let unplugged = inspect(down, record)
        expectEqual(unplugged.guidance, ClusterLinkReadinessState.noActivePort.guidance, "a port that is down asks for the cable")
        expectEqual(unplugged.devices[4].assignedAddress, .missing, "the record still applies to a port that is down")

        // A record for a port this Mac does not list changes nothing.
        let elsewhere = ClusterLinkAliasRecord(aliases: [.init(interface: "en9", address: given)])
        expectEqual(inspect(.macB, elsewhere), never, "a record for another port")
    }
}
