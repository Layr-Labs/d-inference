import Foundation

/// `cluster link --fix` and `--remove` over a scripted Mac. The approval step
/// is a closure, so no prompt, `osascript` or `ifconfig` change is involved.
extension ClusterLinkCheck {
    private typealias Device = ClusterLinkReadinessReport.Device

    private static func device(_ number: Int, _ verdict: ClusterLinkReadinessState) -> Device {
        let active = verdict != .noActivePort
        return .init(device: "rdma_en\(number)", interface: "en\(number)", transport: .thunderbolt, portActive: active,
            interfaceActive: active, interfaceHasIPv4Address: verdict == .ready || verdict == .gidNotPublished,
            bridge: verdict == .portBridgedWithoutAddress ? "bridge0" : nil,
            ipv4MappedGIDPresent: active ? verdict == .ready : nil, verdict: verdict)
    }

    private static func report(_ devices: [Device]) -> ClusterLinkReadinessReport {
        let active = devices.filter(\.portActive)
        let state = active.contains { $0.verdict == .ready } ? ClusterLinkReadinessState.ready : active.first?.verdict ?? .noActivePort
        return .init(state: state, devices: devices)
    }

    /// Two active ports that both lack an address.
    private static var twoBlockedPorts: FakeLinkTools {
        FakeLinkTools(
            deviceList: .output(LinkFixtures.deviceBlock("rdma_en5", active: true) + LinkFixtures.deviceBlock("rdma_en6", active: true)),
            interfaces: .output(LinkFixtures.port("en5", active: true, ipv4: nil) + LinkFixtures.port("en6", active: true, ipv4: nil)
                + LinkFixtures.bridge(members: ["en6"])),
            details: ["rdma_en5": .output(LinkFixtures.detailWithoutMappedGID("rdma_en5")),
                      "rdma_en6": .output(LinkFixtures.detailWithoutMappedGID("rdma_en6"))])
    }

    static func topologyText() {
        expectEqual(ClusterLinkTopology.defaultRouteInterface(inRouteText: LinkFixtures.defaultRoute(interface: "en0")), "en0",
            "default route interface")
        expectEqual(ClusterLinkTopology.defaultRouteInterface(inRouteText: LinkFixtures.defaultRoute(interface: "en13")), "en13",
            "another default route interface")
        for garbled in ["", "route: writing to routing socket: not in table\n", "  interface: \n", "  interface: en0; id\n",
                        "  interface: 192.0.2.1\n", "  interface: en0\n  interface: en1\n"] {
            expectEqual(ClusterLinkTopology.defaultRouteInterface(inRouteText: garbled), nil, "garbled route text \(garbled.debugDescription)")
        }

        var commands = [ClusterLinkToolCommand]()
        let macB = ClusterLinkTopology.observe { commands.append($0); return FakeLinkTools.macB.outcome(of: $0) }
        expectEqual(macB, ClusterLinkTopology(bridgeMembers: ["bridge0": LinkFixtures.interfaceNames], defaultRouteInterface: "en0"),
            "Mac B topology")
        expectEqual(commands, [.interfaceList, .defaultRoute], "topology reads two listings and nothing else")
        expectEqual(ClusterLinkTopology.observe(run: FakeLinkTools.macA.outcome(of:)),
            ClusterLinkTopology(bridgeMembers: [:], defaultRouteInterface: "en0"), "Mac A has no bridge")

        // `route` exits non-zero when there is no default route: that is a fact, not a failure.
        var noRoute = FakeLinkTools.macB
        noRoute.defaultRoute = .unavailable
        expectEqual(ClusterLinkTopology.observe(run: noRoute.outcome(of:))?.defaultRouteInterface, .some(nil), "no default route")
        for failure in [ClusterLinkToolOutcome.timedOut, .outputTooLarge, .output("unexpected text\n")] {
            var route = FakeLinkTools.macB, interfaces = FakeLinkTools.macB
            route.defaultRoute = failure; interfaces.interfaces = failure
            expect(ClusterLinkTopology.observe(run: route.outcome(of:)) == nil, "route \(failure) leaves the topology unknown")
            expect(ClusterLinkTopology.observe(run: interfaces.outcome(of:)) == nil, "ifconfig \(failure) leaves the topology unknown")
        }
        var missingInterfaces = FakeLinkTools.macB
        missingInterfaces.interfaces = .unavailable
        expect(ClusterLinkTopology.observe(run: missingInterfaces.outcome(of:)) == nil, "ifconfig unavailable leaves the topology unknown")

        guard let address = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20"),
              let other = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.2") else { expect(false, "fixture addresses"); return }
        let listing = LinkFixtures.macBInterfaceListing(en6Address: "169.254.10.20")
        expectEqual(ClusterNetworkInterfaces.lists(address, on: "en6", inListing: listing), true, "alias present on its port")
        expectEqual(ClusterNetworkInterfaces.lists(other, on: "en6", inListing: listing), false, "a different address is not the alias")
        expectEqual(ClusterNetworkInterfaces.lists(address, on: "en5", inListing: listing), false, "the alias is on another port")
        expectEqual(ClusterNetworkInterfaces.lists(address, on: "en99", inListing: listing), false, "an unlisted port has no alias")
        expectEqual(ClusterNetworkInterfaces.lists(address, on: "en6", inListing: LinkFixtures.macBInterfaces), false, "no address at all")
        expectEqual(ClusterNetworkInterfaces.lists(address, on: "en6", inListing: "unexpected text\n"), nil, "garbled listing")
    }

    static func fixGating() {
        func plan(_ devices: [Device], _ device: String? = nil) -> ClusterLinkFixPlan {
            ClusterLinkFixPlan.make(for: report(devices), device: device)
        }
        let act = ClusterLinkFixPlan.act(device: "rdma_en6", interface: "en6")
        expectEqual(plan([device(2, .noActivePort), device(6, .portBridgedWithoutAddress)]), act, "one bridged port")
        expectEqual(plan([device(6, .portWithoutIPv4Address)]), act, "one port without an address")
        expectEqual(plan([device(7, .ready)]), .stop(.alreadyReady), "ready")
        expectEqual(plan([device(6, .portBridgedWithoutAddress), device(7, .ready)]), .stop(.alreadyReady),
            "ready through another port: nothing is fixed unasked")
        for state in [ClusterLinkReadinessState.noActivePort, .gidNotPublished, .probeFailed] {
            expectEqual(plan([device(6, state)]), .stop(.nothingFixable(state)), "\(state) is not fixable")
        }
        for state in [ClusterLinkReadinessState.rdmaDisabled, .rdmaUnavailable, .probeFailed, .noActivePort] {
            expectEqual(ClusterLinkFixPlan.make(for: .init(state: state), device: nil), .stop(.nothingFixable(state)),
                "machine-level \(state) is not fixable")
            expectEqual(ClusterLinkFixPlan.make(for: .init(state: state), device: "rdma_en6"), .stop(.nothingFixable(state)),
                "machine-level \(state) is not fixable for a named device")
        }
        expectEqual(plan([device(5, .portWithoutIPv4Address), device(6, .portBridgedWithoutAddress)]),
            .choose(among: ["rdma_en5", "rdma_en6"]), "two fixable ports need a choice")
        expectEqual(plan([device(5, .gidNotPublished), device(6, .portBridgedWithoutAddress)]), act,
            "exactly one of two active ports is fixable")

        let two = [device(5, .portWithoutIPv4Address), device(6, .portBridgedWithoutAddress), device(7, .ready), device(2, .noActivePort)]
        expectEqual(plan(two, "rdma_en6"), act, "a named fixable port")
        expectEqual(plan(two, "rdma_en5"), .act(device: "rdma_en5", interface: "en5"), "the other named fixable port")
        expectEqual(plan(two, "rdma_en7"), .stop(.alreadyReady), "a named ready port")
        expectEqual(plan(two, "rdma_en2"), .stop(.nothingFixable(.noActivePort)), "a named port that is down")
        expectEqual(plan(two, "rdma_en9"), .stop(.deviceNotListed), "a named port this Mac does not list")
        // Naming a port never widens what the fix may act on.
        for state in [ClusterLinkReadinessState.gidNotPublished, .probeFailed] {
            expectEqual(plan([device(5, state), device(6, .portBridgedWithoutAddress)], "rdma_en5"), .stop(.nothingFixable(state)),
                "a named port that is \(state)")
        }
        let inactive = Device(device: "rdma_en6", interface: "en6", transport: .thunderbolt, portActive: false, interfaceActive: false,
            interfaceHasIPv4Address: false, bridge: nil, ipv4MappedGIDPresent: nil, verdict: .portWithoutIPv4Address)
        expectEqual(plan([inactive], "rdma_en6"), .stop(.nothingFixable(.portWithoutIPv4Address)),
            "a named port that is not active, whatever its verdict says")
        expectEqual(plan([inactive]), .stop(.nothingFixable(.noActivePort)), "a port that is not active, whatever its verdict says")
        for hostile in hostileNames {
            expectEqual(plan(two, hostile), .stop(.deviceNotListed), "hostile --device \(hostile.debugDescription)")
            expectEqual(plan(two, "rdma_en6" + (hostile.isEmpty ? " " : hostile)), .stop(.deviceNotListed),
                "hostile suffix \(hostile.debugDescription)")
        }

        // A report that names an interface no parser would accept still cannot
        // yield a target: the plan re-validates what it is given.
        let forged = Device(device: "rdma_en6", interface: "en6\"; do shell script \"id", transport: .thunderbolt, portActive: true,
            interfaceActive: true, interfaceHasIPv4Address: false, bridge: nil, ipv4MappedGIDPresent: false,
            verdict: .portWithoutIPv4Address)
        expectEqual(plan([forged]), .stop(.nothingFixable(.portWithoutIPv4Address)), "forged interface name")
        var unnamed = device(6, .portWithoutIPv4Address)
        unnamed = Device(device: unnamed.device, interface: nil, transport: .thunderbolt, portActive: true, interfaceActive: nil,
            interfaceHasIPv4Address: nil, bridge: nil, ipv4MappedGIDPresent: false, verdict: .portWithoutIPv4Address)
        expectEqual(plan([unnamed]), .stop(.nothingFixable(.portWithoutIPv4Address)), "no interface to address")
    }

    static func fixOutcomes() {
        let expectedAdd = ClusterLinkLocalAddress(dottedDecimal: FakeRepairWorld.en6Address)
            .flatMap { ClusterLinkAliasCommand(action: .add, interface: "en6", address: $0) }
        expect(expectedAdd != nil, "fixture command")

        // Already ready: nothing is asked, read beyond the probe, or written.
        let ready = FakeRepairWorld(.macA)
        ready.approval = FakeRepairWorld.applying
        let readyResult = ready.fix()
        expectEqual(readyResult.outcome, .alreadyReady, "ready Mac")
        expectEqual(readyResult.outcome.exitCode, 0, "ready exit status")
        expectEqual(ready.approvalRequests, [], "ready Mac is never prompted")
        expectEqual(ready.recordSaves, 0, "ready Mac writes no record")
        expectEqual(ready.commands, [.rdmaControlStatus, .rdmaDeviceList, .interfaceList, .rdmaDeviceDetail(device: "rdma_en7")],
            "ready Mac is only probed")

        // Every state that is not a missing address stops before any prompt.
        var disabled = FakeLinkTools.macA, unavailable = FakeLinkTools.macA, down = FakeLinkTools.macA
        var unpublished = FakeLinkTools.macA, failed = FakeLinkTools.macA
        disabled.controlStatus = .output("disabled\n")
        unavailable.controlStatus = .unavailable
        down.deviceList = .output(LinkFixtures.deviceList(active: nil))
        unpublished.details["rdma_en7"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en7"))
        failed.interfaces = .timedOut
        for (state, tools) in [(ClusterLinkReadinessState.rdmaDisabled, disabled), (.rdmaUnavailable, unavailable),
                               (.noActivePort, down), (.gidNotPublished, unpublished), (.probeFailed, failed)] {
            let world = FakeRepairWorld(tools)
            world.approval = FakeRepairWorld.applying
            let result = world.fix()
            expectEqual(result.outcome, .nothingFixable(state), "\(state) outcome")
            expectEqual(world.approvalRequests, [], "\(state) is never prompted")
            expectEqual(world.recordSaves, 0, "\(state) writes no record")
            expectEqual(result.outcome.exitCode, 1, "\(state) exit status")
            // Naming the port changes none of that.
            let named = FakeRepairWorld(tools)
            named.approval = FakeRepairWorld.applying
            expectEqual(named.fix(device: "rdma_en7").outcome, .nothingFixable(state), "\(state) outcome for a named port")
            expectEqual(named.approvalRequests, [], "\(state) is never prompted for a named port")
            expectEqual(named.recordSaves, 0, "\(state) writes no record for a named port")
        }
        // A stop about a named port says which port and gives that port's own
        // verdict; a stop about the link as a whole names none.
        let namedStop = FakeRepairWorld(unpublished).fix(device: "rdma_en7")
        expectEqual([namedStop.device, namedStop.interface], ["rdma_en7", "en7"], "a stop about a named port names it")
        expect(namedStop.message.contains("rdma_en7 is gidNotPublished"), "a stop about a named port gives its verdict")
        let linkStop = FakeRepairWorld(unpublished).fix()
        expectEqual([linkStop.device, linkStop.interface], [nil, nil], "a stop about the link names no port")
        expect(linkStop.message.contains("the link state is gidNotPublished"), "a stop about the link gives the link state")

        // Mac B: one bridged port, approved.
        let fixed = FakeRepairWorld(.macB)
        fixed.approval = FakeRepairWorld.applying
        let fixedResult = fixed.fix()
        expectEqual(fixedResult.outcome, .fixed, "Mac B fixed")
        expectEqual([fixedResult.device, fixedResult.interface], ["rdma_en6", "en6"], "Mac B target")
        expectEqual(fixed.approvalRequests, expectedAdd.map { [$0] } ?? [], "one prompt for exactly the derived alias")
        expectEqual(fixed.record.aliases.map { [$0.interface, $0.address.dottedDecimal] }, [["en6", FakeRepairWorld.en6Address]],
            "the applied alias is recorded")
        expectEqual(fixed.pauses, 0, "no wait when the port is ready at once")
        expectEqual(fixedResult.outcome.exitCode, 0, "fixed exit status")
        expectEqual(fixedResult.manualCommand, nil, "no manual command after a fix")
        expect(fixed.commands.contains(.defaultRoute), "the default route is read")
        expect(fixedResult.message.contains("restart") && fixedResult.message.contains("cable")
            && fixedResult.message.contains("darkbloom cluster link --fix") && fixedResult.message.contains("--remove"),
            "success says the address does not last and how to undo it")

        // The same Mac with a port that has no bridge at all.
        var plain = FakeLinkTools.macB
        plain.interfaces = .output(LinkFixtures.loopback + LinkFixtures.port("en6", active: true, ipv4: nil))
        let plainWorld = FakeRepairWorld(plain)
        plainWorld.approval = { command, world in
            world.tools.interfaces = .output(LinkFixtures.loopback
                + LinkFixtures.port("en6", active: true, ipv4: command.address.dottedDecimal))
            world.tools.details["rdma_en6"] = .output(LinkFixtures.detailWithMappedGID("rdma_en6"))
            return .applied
        }
        expectEqual(plainWorld.fix().outcome, .fixed, "port without an address fixed")

        // Idempotent: ready afterwards means no second prompt; after a restart
        // the address is gone and the same one is applied again.
        expectEqual(fixed.fix().outcome, .alreadyReady, "second run")
        expectEqual(fixed.approvalRequests.count, 1, "second run is not prompted")
        fixed.tools = .macB
        expectEqual(fixed.fix().outcome, .fixed, "run after a restart")
        expectEqual(fixed.approvalRequests, expectedAdd.map { [$0, $0] } ?? [], "the same alias is requested again")
        expectEqual(fixed.record.aliases.count, 1, "one record entry per port")

        // While the prompt is open another command can clear the entry as
        // spent, as a second prompt that is cancelled or a `--remove` does on
        // not seeing the address yet. An approved alias is recorded all the same.
        let cleared = FakeRepairWorld(.macB)
        cleared.approval = { command, world in
            world.record = ClusterLinkAliasRecord()
            return FakeRepairWorld.applying(command, world)
        }
        expectEqual(cleared.fix().outcome, .fixed, "entry cleared by another command during the prompt")
        expectEqual(cleared.record.aliases.map { [$0.interface, $0.address.dottedDecimal] }, [["en6", FakeRepairWorld.en6Address]],
            "an approved alias is recorded whatever happened to its entry meanwhile")

        // The GID can take a moment to appear: the probe is repeated, bounded.
        let slow = FakeRepairWorld(.macB)
        slow.approval = { _, _ in .applied }
        slow.onPause = { world in
            if world.pauses == 2 { world.tools = .macBFixed(address: FakeRepairWorld.en6Address) }
        }
        expectEqual(slow.fix().outcome, .fixed, "ready on a later probe")
        expectEqual(slow.pauses, 2, "waited only until ready")

        for (answer, outcome, exit) in [(ClusterLinkApprovalResult.declined, ClusterLinkRepairOutcome.approvalDeclined, Int32(2)),
                                        (.unavailable, .approvalUnavailable, 3), (.commandFailed, .commandFailed, 4)] {
            let world = FakeRepairWorld(.macB)
            world.approval = { _, _ in answer }
            let result = world.fix()
            expectEqual(result.outcome, outcome, "\(answer) outcome")
            expectEqual(result.outcome.exitCode, exit, "\(answer) exit status")
            expectEqual(world.approvalRequests.count, 1, "\(answer) after one prompt")
            // Where no prompt could be shown the entry stays, so that an address the
            // administrator adds with the printed command can still be removed.
            expectEqual(world.record.aliases.count, answer == .unavailable ? 1 : 0, "\(answer) record")
            expectEqual(world.pauses, 0, "\(answer) is not verified")
            expectEqual(result.manualCommand, answer == .unavailable ? expectedAdd?.manualCommand : nil, "\(answer) manual command")
            expectNoAddress(compactJSON(result), "\(answer) JSON")
            expectNoAddress(result.summaryLines.joined(separator: "\n"), "\(answer) summary")
        }

        // The administrator runs the printed command by hand: the link is then
        // ready, and the address is still Darkbloom's to remove.
        let manual = FakeRepairWorld(.macB)
        manual.approval = { _, _ in .unavailable }
        expectEqual(manual.fix().outcome, .approvalUnavailable, "no prompt possible")
        manual.tools = .macBFixed(address: FakeRepairWorld.en6Address)
        manual.approval = FakeRepairWorld.applying
        expectEqual(manual.fix().outcome, .alreadyReady, "ready after the manual command")
        expectEqual(manual.remove().outcome, .removed, "the manually added address can be removed")
        expectEqual(manual.approvalRequests.last?.action, .remove, "the removal names the recorded address")
        expectEqual(manual.approvalRequests.last?.address.dottedDecimal, FakeRepairWorld.en6Address, "the recorded address")

        // A command that reported an error but added the address anyway stays
        // recorded, so that `--remove` can still take it away.
        let halfApplied = FakeRepairWorld(.macB)
        halfApplied.approval = { command, world in
            world.tools.interfaces = .output(LinkFixtures.macBInterfaceListing(en6Address: command.address.dottedDecimal))
            return .commandFailed
        }
        expectEqual(halfApplied.fix().outcome, .commandFailed, "command failed after adding the address")
        expectEqual(halfApplied.record.aliases.map(\.interface), ["en6"], "an address that is present stays recorded")
        let unseen = FakeRepairWorld(.macB)
        unseen.approval = { _, world in
            world.tools.interfaces = .timedOut
            return .declined
        }
        expectEqual(unseen.fix().outcome, .approvalDeclined, "declined, then unreadable")
        expectEqual(unseen.record.aliases.map(\.interface), ["en6"], "the record is kept until the port is seen without the address")

        // Approved and run, yet one of the three conditions does not hold.
        typealias Unmet = ClusterLinkRepairOutcome.Unmet
        let attempts = ClusterLinkRepair.verificationAttempts
        let unchanged = FakeRepairWorld(.macB)
        unchanged.approval = { _, _ in .applied }
        let unchangedResult = unchanged.fix()
        expectEqual(unchangedResult.outcome, .appliedButNotReady([.deviceNotReady]), "port still not ready")
        expectEqual(unchanged.pauses, attempts - 1, "bounded verification")
        expectEqual(unchanged.record.aliases.count, 1, "an applied alias stays recorded so it can be removed")
        expectEqual(unchangedResult.outcome.exitCode, 4, "not-ready exit status")
        expect(unchangedResult.message.contains("--remove"), "not-ready says how to undo")

        let unbridged = FakeRepairWorld(.macB)
        unbridged.approval = { command, world in
            world.tools = .macBFixed(address: command.address.dottedDecimal)
            world.tools.interfaces = .output(LinkFixtures.macBInterfaceListing(en6Address: command.address.dottedDecimal,
                bridgeMembers: LinkFixtures.interfaceNames.filter { $0 != "en6" }))
            return .applied
        }
        expectEqual(unbridged.fix().outcome, .appliedButNotReady([.bridgeMembersChanged]), "bridge member list changed")

        let rerouted = FakeRepairWorld(.macB)
        rerouted.approval = { command, world in
            world.tools = .macBFixed(address: command.address.dottedDecimal)
            world.tools.defaultRoute = .output(LinkFixtures.defaultRoute(interface: "en6"))
            return .applied
        }
        expectEqual(rerouted.fix().outcome, .appliedButNotReady([.defaultRouteChanged]), "default route changed")

        let routeLost = FakeRepairWorld(.macB)
        routeLost.approval = { command, world in
            world.tools = .macBFixed(address: command.address.dottedDecimal)
            world.tools.defaultRoute = .unavailable
            return .applied
        }
        expectEqual(routeLost.fix().outcome, .appliedButNotReady([.defaultRouteChanged]), "default route disappeared")

        let everything = FakeRepairWorld(.macB)
        everything.approval = { _, world in
            world.tools.interfaces = .output(LinkFixtures.macBInterfaceListing(bridgeMembers: ["en2"]))
            world.tools.defaultRoute = .output(LinkFixtures.defaultRoute(interface: "en6"))
            return .applied
        }
        expectEqual(everything.fix().outcome, .appliedButNotReady([.deviceNotReady, .bridgeMembersChanged, .defaultRouteChanged]),
            "every unmet condition is named, in a fixed order")

        let unreadable = FakeRepairWorld(.macB)
        unreadable.approval = { command, world in
            world.tools = .macBFixed(address: command.address.dottedDecimal)
            world.tools.defaultRoute = .timedOut
            return .applied
        }
        expectEqual(unreadable.fix().outcome, .appliedButNotReady([.stateUnreadable]), "state unreadable afterwards")

        // Preconditions that fail before any prompt.
        let anonymous = FakeRepairWorld(.macB)
        anonymous.machineIdentifier = nil
        anonymous.approval = FakeRepairWorld.applying
        expectEqual(anonymous.fix().outcome, .machineIdentityUnavailable, "no machine value to derive from")
        expectEqual(anonymous.approvalRequests, [], "no prompt without an address")

        let unwritable = FakeRepairWorld(.macB)
        unwritable.recordFailsToSave = true
        unwritable.approval = FakeRepairWorld.applying
        expectEqual(unwritable.fix().outcome, .recordUnavailable, "record cannot be written")
        expectEqual(unwritable.approvalRequests, [], "no prompt for an alias that could not be recorded")

        let unreadableRecord = FakeRepairWorld(.macB)
        unreadableRecord.recordFailsToLoad = true
        unreadableRecord.approval = FakeRepairWorld.applying
        expectEqual(unreadableRecord.fix().outcome, .recordUnavailable, "record cannot be read before a fix")
        expectEqual(unreadableRecord.approvalRequests, [], "no prompt over a record that cannot be read")
        expectEqual(unreadableRecord.recordSaves, 0, "a record that cannot be read is not replaced")

        var routeUnknown = FakeLinkTools.macB
        routeUnknown.defaultRoute = .timedOut
        let blind = FakeRepairWorld(routeUnknown)
        blind.approval = FakeRepairWorld.applying
        let blindResult = blind.fix()
        expectEqual(blindResult.outcome, .nothingFixable(.probeFailed), "topology unreadable beforehand")
        expectEqual(blind.approvalRequests, [], "no prompt without a baseline to verify against")
        expectEqual(blind.recordSaves, 0, "no record without a baseline")
        // The port itself was read and is fixable: what could not be read is not reported as its state.
        expectEqual([blindResult.device, blindResult.interface], ["rdma_en6", "en6"], "an unreadable baseline still names the port")
        expect(blindResult.message.contains("could not read") && blindResult.message.contains("rdma_en6")
            && !blindResult.message.contains("is probeFailed") && !blindResult.message.contains("does not cure"),
            "an unreadable baseline is not reported as the port's own state")

        // Several candidate ports, and names that do not belong.
        let ambiguous = FakeRepairWorld(twoBlockedPorts)
        ambiguous.approval = { _, _ in .declined }
        let ambiguousResult = ambiguous.fix()
        expectEqual(ambiguousResult.outcome, .ambiguousPorts, "two candidate ports")
        expectEqual(ambiguous.approvalRequests, [], "no prompt while the port is ambiguous")
        expect(ambiguousResult.message.contains("rdma_en5") && ambiguousResult.message.contains("rdma_en6")
            && ambiguousResult.message.contains("--device"), "ambiguity names the candidates and the option")
        expectEqual(ambiguous.fix(device: "rdma_en5").outcome, .approvalDeclined, "a named candidate is used")
        expectEqual(ambiguous.approvalRequests.map(\.interface), ["en5"], "the named port is the one prompted for")
        for hostile in hostileNames + ["rdma_en9", "rdma_en6; id", "rdma_en6\" with administrator privileges"] {
            let world = FakeRepairWorld(.macB)
            world.approval = FakeRepairWorld.applying
            let result = world.fix(device: hostile)
            expectEqual(result.outcome, .deviceNotListed, "--device \(hostile.debugDescription)")
            expectEqual(world.approvalRequests, [], "--device \(hostile.debugDescription) is never prompted")
            expect(hostile.trimmingCharacters(in: .whitespaces).isEmpty
                || !(compactJSON(result) + result.summaryLines.joined()).contains(hostile),
                "--device \(hostile.debugDescription) is not echoed")
        }

        // Tool output that puts hostile text where a name belongs never yields a target.
        var poisoned = FakeLinkTools.macB
        poisoned.deviceList = .output(LinkFixtures.deviceBlock("rdma_en6\"; do shell script \"id", active: true))
        let poisonedWorld = FakeRepairWorld(poisoned)
        poisonedWorld.approval = FakeRepairWorld.applying
        expectEqual(poisonedWorld.fix().outcome, .nothingFixable(.probeFailed), "hostile device listing")
        expectEqual(poisonedWorld.approvalRequests, [], "hostile device listing is never prompted")
    }

    static func removeOutcomes() {
        guard let recorded = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20"),
              let foreign = ClusterLinkLocalAddress(dottedDecimal: "169.254.77.7"),
              let expectedRemove = ClusterLinkAliasCommand(action: .remove, interface: "en6", address: recorded) else {
            expect(false, "fixture addresses"); return
        }
        let entry = ClusterLinkAliasRecord.Alias(interface: "en6", address: recorded)
        func world(present: Bool = true, record: [ClusterLinkAliasRecord.Alias]? = nil) -> FakeRepairWorld {
            let world = FakeRepairWorld(present ? .macBFixed(address: recorded.dottedDecimal) : .macB)
            world.record.aliases = record ?? [entry]
            return world
        }

        let empty = world(record: [])
        empty.approval = FakeRepairWorld.applying
        let emptyResult = empty.remove()
        expectEqual(emptyResult.outcome, .nothingRecorded, "nothing recorded")
        expectEqual(empty.approvalRequests, [], "nothing recorded is never prompted")
        expectEqual(empty.commands, [], "nothing recorded reads nothing")
        expectEqual(emptyResult.outcome.exitCode, 0, "nothing recorded exit status")

        let removed = world()
        removed.approval = FakeRepairWorld.applying
        let removedResult = removed.remove()
        expectEqual(removedResult.outcome, .removed, "recorded alias removed")
        expectEqual(removed.approvalRequests, [expectedRemove], "one prompt for exactly the recorded alias")
        expectEqual(removed.record.aliases.count, 0, "record cleared after removal")
        expectEqual([removedResult.device, removedResult.interface], ["rdma_en6", "en6"], "removal target")
        expectEqual(removedResult.outcome.exitCode, 0, "removed exit status")
        expectNoAddress(compactJSON(removedResult) + removedResult.summaryLines.joined(), "removed output")

        // After a restart or replug the alias is already gone: no prompt.
        let gone = world(present: false)
        gone.approval = FakeRepairWorld.applying
        expectEqual(gone.remove().outcome, .alreadyAbsent, "alias already absent")
        expectEqual(gone.approvalRequests, [], "an absent alias is never prompted for")
        expectEqual(gone.record.aliases.count, 0, "record cleared when the alias is gone")
        expectEqual(ClusterLinkRepairOutcome.alreadyAbsent.exitCode, 0, "already-absent exit status")

        // Only what the record names: an address the port got some other way is left alone.
        let otherAddress = FakeRepairWorld(.macBFixed(address: foreign.dottedDecimal))
        otherAddress.record.aliases = [entry]
        otherAddress.approval = FakeRepairWorld.applying
        expectEqual(otherAddress.remove().outcome, .alreadyAbsent, "a different address on the port")
        expectEqual(otherAddress.approvalRequests, [], "an address Darkbloom did not record is never removed")

        for (answer, outcome, exit) in [(ClusterLinkApprovalResult.declined, ClusterLinkRepairOutcome.approvalDeclined, Int32(2)),
                                        (.unavailable, .approvalUnavailable, 3), (.commandFailed, .commandFailed, 4),
                                        (.applied, .removalNotVerified, 4)] {
            let kept = world()
            kept.approval = { _, _ in answer }
            let result = kept.remove()
            expectEqual(result.outcome, outcome, "remove \(answer) outcome")
            expectEqual(result.outcome.exitCode, exit, "remove \(answer) exit status")
            expectEqual(kept.record.aliases, [entry], "remove \(answer) keeps the record")
            expectEqual(result.manualCommand, answer == .unavailable ? expectedRemove.manualCommand : nil, "remove \(answer) manual command")
            expectNoAddress(compactJSON(result) + result.summaryLines.joined(), "remove \(answer) output")
        }

        // Two recorded aliases that both still exist need a choice.
        let second = ClusterLinkAliasRecord.Alias(interface: "en5", address: foreign)
        func twoPorts(en6Address: String?) -> ClusterLinkToolOutcome {
            .output(LinkFixtures.loopback + LinkFixtures.port("en5", active: true, ipv4: foreign.dottedDecimal)
                + LinkFixtures.port("en6", active: true, ipv4: en6Address) + LinkFixtures.bridge(members: ["en6"]))
        }
        let both = world(record: [second, entry])
        both.tools.interfaces = twoPorts(en6Address: recorded.dottedDecimal)
        both.approval = { _, world in
            world.tools.interfaces = twoPorts(en6Address: nil)
            return .applied
        }
        let choice = both.remove()
        expectEqual(choice.outcome, .ambiguousPorts, "two recorded aliases need a choice")
        expectEqual(choice.candidates, ["rdma_en5", "rdma_en6"], "the choice names both devices")
        expectEqual(both.approvalRequests, [], "no prompt while the alias is ambiguous")
        expectEqual(both.remove(device: "rdma_en6").outcome, .removed, "a named recorded alias")
        expectEqual(both.record.aliases, [second], "only the named alias leaves the record")
        expectEqual(both.remove(device: "rdma_en7").outcome, .nothingRecorded, "a named port without a recorded alias")
        for hostile in hostileNames {
            expectEqual(both.remove(device: hostile).outcome, .nothingRecorded, "remove --device \(hostile.debugDescription)")
        }
        expectEqual(both.approvalRequests, [expectedRemove], "only the one legitimate removal was prompted for")

        // An entry whose address is gone, say after the cable moved to another
        // port, is cleared rather than left to demand a choice.
        let moved = world(record: [second, entry])
        moved.approval = FakeRepairWorld.applying
        expectEqual(moved.remove().outcome, .removed, "one live alias among stale entries")
        expectEqual(moved.approvalRequests, [expectedRemove], "the live alias is the one removed")
        expectEqual(moved.record.aliases, [], "stale entries are cleared")
        let allStale = world(present: false, record: [second, entry])
        allStale.approval = FakeRepairWorld.applying
        expectEqual(allStale.remove().outcome, .alreadyAbsent, "every recorded alias already gone")
        expectEqual(allStale.approvalRequests, [], "no prompt when nothing is left to remove")
        expectEqual(allStale.record.aliases, [], "every stale entry is cleared")

        let unreadableRecord = world()
        unreadableRecord.recordFailsToLoad = true
        unreadableRecord.approval = FakeRepairWorld.applying
        expectEqual(unreadableRecord.remove().outcome, .recordUnavailable, "record cannot be read")
        expectEqual(unreadableRecord.approvalRequests, [], "no prompt without a readable record")

        let blind = world()
        blind.tools.interfaces = .timedOut
        blind.approval = FakeRepairWorld.applying
        let blindResult = blind.remove()
        expectEqual(blindResult.outcome, .nothingFixable(.probeFailed), "interfaces unreadable before removal")
        expectEqual(blind.approvalRequests, [], "no prompt when presence is unknown")
        expectEqual(blind.record.aliases, [entry], "record kept when presence is unknown")
        expect(blindResult.message.contains("could not read") && !blindResult.message.contains("adding an address"),
            "a removal that could not look says so, and nothing about adding an address")
        expectNoAddress(compactJSON(blindResult) + blindResult.summaryLines.joined(), "unreadable removal output")
    }

    static func repairVocabulary() {
        typealias Outcome = ClusterLinkRepairOutcome
        let outcomes: [(Outcome, String, Int32)] = [
            (.alreadyReady, "alreadyReady", 0), (.fixed, "fixed", 0), (.removed, "removed", 0), (.alreadyAbsent, "alreadyAbsent", 0),
            (.nothingRecorded, "nothingRecorded", 0), (.nothingFixable(.noActivePort), "nothingFixable", 1),
            (.ambiguousPorts, "ambiguousPorts", 1), (.deviceNotListed, "deviceNotListed", 1),
            (.machineIdentityUnavailable, "machineIdentityUnavailable", 1), (.recordUnavailable, "recordUnavailable", 1),
            (.approvalDeclined, "approvalDeclined", 2), (.approvalUnavailable, "approvalUnavailable", 3),
            (.commandFailed, "commandFailed", 4), (.appliedButNotReady([.deviceNotReady]), "appliedButNotReady", 4),
            (.removalNotVerified, "removalNotVerified", 4)]
        for (outcome, code, exit) in outcomes {
            expectEqual(outcome.code, code, "\(code) code")
            expectEqual(outcome.exitCode, exit, "\(code) exit status")
            for operation in [ClusterLinkRepairResult.Operation.fix, .remove] {
                let result = ClusterLinkRepairResult(operation: operation, outcome: outcome, device: "rdma_en6", interface: "en6",
                    manualCommand: "sudo /sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias")
                let encoded = compactJSON(result)
                expect(encoded.contains("\"outcome\":\"\(code)\"") && encoded.contains("\"operation\":\"\(operation.rawValue)\"")
                    && encoded.contains("\"schema\":\"darkbloom_cluster_link_repair_v1\""), "\(code) JSON identity")
                expectNoAddress(encoded, "\(code) JSON")
                expect(!encoded.contains("sudo") && !encoded.contains("manualCommand"), "\(code) JSON omits the manual command")
                expect(!result.message.isEmpty && result.message.hasSuffix("."), "\(code) has a message")
                expectNoAddress(result.summaryLines.joined(separator: "\n"), "\(code) summary")
                expectEqual(result.summaryLines.first, "Link \(operation.rawValue): \(code)", "\(code) headline")
            }
        }
        let blocked = ClusterLinkRepairResult(operation: .fix, outcome: .nothingFixable(.rdmaDisabled))
        expect(compactJSON(blocked).contains("\"state\":\"rdmaDisabled\""), "the blocking state is encoded")
        expect(blocked.message.contains(ClusterLinkReadinessState.rdmaDisabled.guidance ?? "?"), "the blocking state's guidance is given")
        let unmet = ClusterLinkRepairResult(operation: .fix, outcome: .appliedButNotReady([.bridgeMembersChanged, .defaultRouteChanged]),
            device: "rdma_en6", interface: "en6")
        expect(compactJSON(unmet).contains("\"unmet\":[\"bridgeMembersChanged\",\"defaultRouteChanged\"]"), "unmet conditions are encoded")
        expect(unmet.message.contains("bridge") && unmet.message.contains("default route"), "unmet conditions are explained")
        expectEqual(ClusterLinkRepairOutcome.Unmet.allCases.map(\.rawValue),
            ["deviceNotReady", "bridgeMembersChanged", "defaultRouteChanged", "stateUnreadable"], "stable unmet codes")
        expect(ClusterLinkRepairResult(operation: .fix, outcome: .approvalUnavailable).message.contains("SSH"),
            "unavailable approval explains the usual cause")
    }
}
