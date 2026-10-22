import Foundation

/// The durable fix: the address together with the launchd job that keeps it,
/// dry runs of it, and what a removal finds left behind. All over a scripted
/// Mac; nothing is installed, loaded or prompted for.
extension ClusterLinkCheck {
    private typealias Request = ClusterLinkPrivilegedRequest
    private typealias Remnants = ClusterLinkFixRemnants

    private static var derivedAddress: ClusterLinkLocalAddress? {
        ClusterLinkLocalAddress(dottedDecimal: FakeRepairWorld.en6Address)
    }

    static func fixRemnants() {
        guard let address = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20") else { expect(false, "fixture address"); return }
        func observed(_ tools: FakeLinkTools) -> Remnants? {
            Remnants.observed(interface: "en6", address: address, run: tools.outcome(of:))
        }
        expectEqual(observed(.macB), Remnants(), "nothing of a fix on an untouched port")
        expectEqual(observed(.macB)?.isEmpty, true, "nothing left is empty")
        var tools = FakeLinkTools.macBFixed(address: "169.254.10.20")
        expectEqual(observed(tools), Remnants(address: true), "the address alone")
        tools.installKeeper(interface: "en6", address: "169.254.10.20")
        expectEqual(observed(tools), Remnants(address: true, keeperJob: true, keeperFile: true), "the address and its keeper")
        tools.interfaces = FakeLinkTools.macB.interfaces
        expectEqual(observed(tools), Remnants(keeperJob: true, keeperFile: true), "the keeper while macOS has stripped the port")
        tools.keeperJobs = [:]
        expectEqual(observed(tools), Remnants(keeperFile: true), "a job definition that is not loaded")
        expectEqual(observed(.macBFixed(address: "169.254.10.21")), Remnants(), "another address on the port is not a remnant")
        var otherPort = FakeLinkTools.macB
        otherPort.installKeeper(interface: "en5", address: "169.254.10.20")
        expectEqual(observed(otherPort), Remnants(), "another port's keeper is not this port's remnant")

        var commands = [ClusterLinkToolCommand]()
        _ = Remnants.observed(interface: "en6", address: address) { commands.append($0); return FakeLinkTools.macB.outcome(of: $0) }
        expectEqual(commands, [.interfaceList, .keeperJob(interface: "en6"), .keeperJobFileList], "three read-only tools")

        // A tool that could not answer leaves the question open: nothing is assumed gone.
        for failure in [ClusterLinkToolOutcome.timedOut, .outputTooLarge] {
            var listing = FakeLinkTools.macB, job = FakeLinkTools.macB, file = FakeLinkTools.macB
            listing.interfaces = failure; job.keeperJobs["en6"] = failure; file.keeperDirectory = failure
            expect(observed(listing) == nil && observed(job) == nil && observed(file) == nil, "\(failure) leaves remnants unknown")
        }
        var unlisted = FakeLinkTools.macB
        unlisted.keeperDirectory = .unavailable
        expect(observed(unlisted) == nil, "a directory that cannot be listed leaves remnants unknown")
        // A job definition that cannot be read or converted is still a file to remove.
        for unreadable in [ClusterLinkToolOutcome.unavailable, .timedOut, .output("not a property list\n")] {
            var opaque = FakeLinkTools.macB
            opaque.keeperJobFiles["en6"] = unreadable
            expectEqual(observed(opaque), Remnants(keeperFile: true), "a job definition that reads as \(unreadable) is still there")
        }
        var garbled = FakeLinkTools.macB
        garbled.interfaces = .output("unexpected text\n")
        expect(observed(garbled) == nil, "a garbled listing leaves remnants unknown")
    }

    static func durableFixOutcomes() {
        guard let address = derivedAddress, let keep = Request(.keepAddress, interface: "en6", address: address) else {
            expect(false, "fixture request"); return
        }

        // Mac B, approved: one prompt installs the keeper, whose first run adds the address.
        let fixed = FakeRepairWorld(.macB)
        fixed.approval = FakeRepairWorld.applying
        let fixedResult = fixed.fix()
        expectEqual(fixedResult.outcome, .fixed, "Mac B fixed durably")
        expectEqual(fixedResult.durable, true, "a durable fix says so")
        expectEqual(fixed.approvalRequests, [keep], "one prompt, for exactly the keeper of the derived address")
        expectEqual(fixed.record.aliases.map { [$0.interface, $0.address.dottedDecimal] }, [["en6", FakeRepairWorld.en6Address]],
            "what was installed is recorded")
        expect(fixed.commands.contains(.keeperJob(interface: "en6")) && fixed.commands.contains(.keeperJobFile(interface: "en6")),
            "the keeper is verified after the prompt")
        expect(fixedResult.message.contains("io.darkbloom.cluster-link.en6") && fixedResult.message.contains("restart")
            && fixedResult.message.contains("within about 10 seconds") && fixedResult.message.contains("--remove"),
            "success names the job, what it does and how to undo it")
        expect(compactJSON(fixedResult).contains("\"durable\":true"), "durable in JSON")
        expectNoAddress(compactJSON(fixedResult) + fixedResult.summaryLines.joined(), "durable fix output")

        // macOS strips the port while the keeper is between runs, or the job was
        // switched off: running the fix again installs it afresh.
        fixed.takeAddress()
        fixed.tools.keeperJobs = [:]
        expectEqual(fixed.fix().outcome, .fixed, "repair of a stripped port")
        expectEqual(fixed.approvalRequests, [keep, keep], "the same keeper is installed again")
        expectEqual(fixed.record.aliases.count, 1, "one record entry per port")
        expectEqual(fixed.fix().outcome, .alreadyReady, "nothing to do while the address is there")
        expectEqual(fixed.approvalRequests.count, 2, "no prompt while the address is there")

        // An address Darkbloom gave the port before, and macOS removed, comes back as it was.
        guard let earlier = ClusterLinkLocalAddress(dottedDecimal: "169.254.77.7") else { expect(false, "fixture address"); return }
        let lost = FakeRepairWorld(.macB)
        lost.record.aliases = [.init(interface: "en6", address: earlier)]
        lost.machineIdentifier = nil
        lost.approval = FakeRepairWorld.applying
        expectEqual(lost.fix().outcome, .fixed, "a lost address is put back")
        expectEqual(lost.approvalRequests.map(\.address), [earlier], "with the recorded address, not a new one")
        expectEqual(lost.approvalRequests.map(\.purpose), [.keepAddress], "and kept this time")
        expectEqual(lost.record.aliases, [.init(interface: "en6", address: earlier)], "the record still names it once")

        // Cancelled while repairing: the entry from the earlier fix stays, so the address is still reported missing.
        let lostDeclined = FakeRepairWorld(.macB)
        lostDeclined.record.aliases = [.init(interface: "en6", address: address)]
        lostDeclined.approval = { _, _ in .declined }
        expectEqual(lostDeclined.fix().outcome, .approvalDeclined, "repair declined")
        expectEqual(lostDeclined.record.aliases, [.init(interface: "en6", address: address)], "a declined repair keeps the earlier entry")

        // A temporary address is still in place: the durable fix adds only the
        // job that keeps it, under the same one approval, and takes nothing away.
        let upgraded = FakeRepairWorld.temporary(.macB)
        upgraded.approval = FakeRepairWorld.applying
        expectEqual(upgraded.fix().durable, false, "a temporary fix first")
        expectEqual(upgraded.fix().outcome, .alreadyReady, "a temporary fix leaves a ready port alone")
        upgraded.mode = .durable
        let upgradePlan = upgraded.fix(dryRun: true)
        expectEqual(upgradePlan.outcome, .dryRun, "keeping a temporary address is planned")
        expectEqual(upgradePlan.plannedCommands, keep.commands, "with the same commands as a first install")
        let upgradeResult = upgraded.fix()
        expectEqual(upgradeResult.outcome, .fixed, "a temporary address is made to last")
        expectEqual(upgradeResult.durable, true, "and reported as kept")
        expectEqual(upgraded.approvalRequests.map(\.purpose), [.addAddress, .keepAddress], "one more prompt, for the keeper")
        expectEqual(upgraded.approvalRequests.map(\.address), [address, address], "the keeper is for the address already there")
        expectEqual(upgraded.fix().outcome, .alreadyReady, "nothing more to do once it is kept")
        expectEqual(upgraded.fix(device: "rdma_en6").outcome, .alreadyReady, "also when the port is named")
        expectEqual(upgraded.approvalRequests.count, 2, "no prompt once it is kept")
        // Declined: the address and its record stay as they were.
        let upgradeDeclined = FakeRepairWorld.temporary(.macB)
        upgradeDeclined.approval = FakeRepairWorld.applying
        _ = upgradeDeclined.fix()
        upgradeDeclined.mode = .durable
        upgradeDeclined.approval = { _, _ in .declined }
        expectEqual(upgradeDeclined.fix(device: "rdma_en6").outcome, .approvalDeclined, "keeping declined, port named")
        expectEqual(upgradeDeclined.record.aliases.count, 1, "the temporary address stays recorded")
        expectEqual(Remnants.observed(interface: "en6", address: address, run: upgradeDeclined.tools.outcome(of:)), Remnants(address: true),
            "and stays on the port")
        // A ready port whose address is not Darkbloom's is never given a keeper.
        let foreign = FakeRepairWorld(.macA)
        foreign.approval = FakeRepairWorld.applying
        expectEqual(foreign.fix().outcome, .alreadyReady, "a port with its own address is left alone")
        expectEqual(foreign.fix(device: "rdma_en7").outcome, .alreadyReady, "also when named")
        let replaced = FakeRepairWorld(.macBFixed(address: "169.254.10.21"))
        replaced.record.aliases = [.init(interface: "en6", address: address)]
        expectEqual(replaced.fix().outcome, .alreadyReady, "a port that now has some other address is left alone")
        expectEqual(foreign.approvalRequests.count + replaced.approvalRequests.count, 0, "no prompt for an address that is not Darkbloom's")

        // An address added with --temporary on a port whose keeper is still running is not called temporary.
        let stillKept = FakeRepairWorld(.macB)
        stillKept.approval = FakeRepairWorld.applying
        _ = stillKept.fix()
        stillKept.takeAddress()
        stillKept.mode = .temporary
        let readded = stillKept.fix()
        expectEqual(readded.outcome, .fixed, "the address is added again by hand")
        expectEqual(readded.durable, true, "and reported as kept, because its job is running")
        expect(!readded.message.contains("temporary"), "a kept address is not called temporary")

        // Approved, the address is there, but the keeper is not what was written.
        typealias Unmet = ClusterLinkRepairOutcome.Unmet
        let cases: [(String, (Request, FakeRepairWorld) -> Void, [Unmet])] = [
            ("no keeper at all", { request, world in world.giveAddress(request.address.dottedDecimal) }, [.addressKeeperNotRunning]),
            ("a job definition that is not loaded", { request, world in
                world.giveAddress(request.address.dottedDecimal)
                world.tools.installKeeper(interface: "en6", address: request.address.dottedDecimal)
                world.tools.keeperJobs = [:]
            }, [.addressKeeperNotRunning]),
            ("a loaded job without its definition", { request, world in
                world.giveAddress(request.address.dottedDecimal)
                world.tools.installKeeper(interface: "en6", address: request.address.dottedDecimal)
                world.tools.keeperJobFiles = [:]
            }, [.addressKeeperNotRunning]),
            ("a job definition that differs", { request, world in
                world.giveAddress(request.address.dottedDecimal)
                world.tools.installKeeper(interface: "en6", address: request.address.dottedDecimal)
                world.tools.keeperJobFiles["en6"] = .output(LinkFixtures.keeperJobJSON(interface: "en6",
                    address: request.address.dottedDecimal, interval: 3600))
            }, [.addressKeeperNotRunning]),
            ("a keeper whose address never appears", { request, world in
                world.tools.installKeeper(interface: "en6", address: request.address.dottedDecimal)
            }, [.deviceNotReady]),
            ("neither the address nor the keeper", { _, _ in }, [.deviceNotReady, .addressKeeperNotRunning]),
        ]
        for (label, effect, unmet) in cases {
            let world = FakeRepairWorld(.macB)
            world.approval = { request, world in effect(request, world); return .applied }
            let result = world.fix()
            expectEqual(result.outcome, .appliedButNotReady(unmet), label)
            expectEqual(world.record.aliases.count, 1, "\(label): what was done stays recorded")
            expectEqual(result.outcome.exitCode, 4, "\(label): exit status")
        }
        let unkept = ClusterLinkRepairResult(operation: .fix, outcome: .appliedButNotReady([.addressKeeperNotRunning]),
            device: "rdma_en6", interface: "en6", durable: true)
        expect(unkept.message.contains("system job") && unkept.message.contains("--remove"), "an unkept address is explained")
        expect(compactJSON(unkept).contains("\"unmet\":[\"addressKeeperNotRunning\"]"), "the keeper condition is encoded")
        // A failed durable fix names the one setting that makes macOS refuse the job; other failures do not.
        func failure(_ operation: ClusterLinkRepairResult.Operation, durable: Bool?) -> String {
            ClusterLinkRepairResult(operation: operation, outcome: .commandFailed, device: "rdma_en6", interface: "en6", durable: durable).message
        }
        expect(failure(.fix, durable: true).contains("Login Items") && failure(.fix, durable: true).contains("--remove"),
            "a failed keeper install names Login Items")
        expect(!failure(.fix, durable: false).contains("Login Items") && !failure(.remove, durable: nil).contains("Login Items"),
            "a failed temporary fix or removal does not")

        // Cancelled: nothing was installed, so nothing stays recorded.
        let declined = FakeRepairWorld(.macB)
        declined.approval = { _, _ in .declined }
        expectEqual(declined.fix().outcome, .approvalDeclined, "durable fix declined")
        expectEqual(declined.record.aliases.count, 0, "a declined install leaves no record")
        expect(declined.commands.suffix(3) == [.interfaceList, .keeperJob(interface: "en6"), .keeperJobFileList],
            "the record goes only after the port is seen with nothing on it")

        // Commands that failed part-way may have left the job definition: it stays
        // recorded, and removal takes exactly that away.
        let partial = FakeRepairWorld(.macB)
        partial.approval = { request, world in
            world.tools.keeperJobFiles["en6"] = .output(LinkFixtures.keeperJobJSON(interface: "en6", address: request.address.dottedDecimal))
            return .commandFailed
        }
        expectEqual(partial.fix().outcome, .commandFailed, "install failed part-way")
        expectEqual(partial.record.aliases.count, 1, "a partial install stays recorded")
        partial.approval = FakeRepairWorld.applying
        expectEqual(partial.remove().outcome, .removed, "a partial install can be removed")
        expectEqual(partial.approvalRequests.last?.purpose, .remove(Remnants(keeperFile: true)), "removal names only what is left")
        expectEqual(partial.record.aliases.count, 0, "nothing stays recorded once nothing is left")

        // No prompt possible: the manual lines are the same commands under sudo.
        let unavailable = FakeRepairWorld(.macB)
        unavailable.approval = { _, _ in .unavailable }
        let unavailableResult = unavailable.fix()
        expectEqual(unavailableResult.outcome, .approvalUnavailable, "durable fix without a prompt")
        expectEqual(unavailableResult.manualCommands, keep.manualCommands, "manual commands for the durable fix")
        expectNoAddress(compactJSON(unavailableResult) + unavailableResult.summaryLines.joined(), "unavailable durable output")

        // Removal after a durable fix: the job first, then the address it would put back.
        let removed = FakeRepairWorld(.macB)
        removed.approval = FakeRepairWorld.applying
        expectEqual(removed.fix().outcome, .fixed, "durable fix before removal")
        let removedResult = removed.remove()
        expectEqual(removedResult.outcome, .removed, "durable fix removed")
        expectEqual(removed.approvalRequests.last, Request(.remove(Remnants(address: true, keeperJob: true, keeperFile: true)),
            interface: "en6", address: address), "one prompt removes the job, its definition and the address")
        expectEqual(removed.record.aliases.count, 0, "record cleared after a full removal")
        expectEqual(Remnants.observed(interface: "en6", address: address, run: removed.tools.outcome(of:)), Remnants(),
            "nothing is left after removal")
        expect(removedResult.message.contains("system job"), "removal says the job went too")

        // The address is momentarily gone but the keeper is there: removal
        // still has work, and prompts. The job may put the address back while
        // the prompt is open, so the same approval takes the address away too.
        let stripped = FakeRepairWorld(.macB)
        stripped.approval = FakeRepairWorld.applying
        _ = stripped.fix()
        stripped.takeAddress()
        stripped.approval = { request, world in
            world.giveAddress(request.address.dottedDecimal)
            return FakeRepairWorld.applying(request, world)
        }
        expectEqual(stripped.remove().outcome, .removed, "keeper removed although it put the address back meanwhile")
        expectEqual(stripped.approvalRequests.last?.purpose, .remove(Remnants(keeperJob: true, keeperFile: true)),
            "removal of what was found: the keeper")
        expect(stripped.approvalRequests.last?.commands.last?.hasSuffix(" -alias") == true, "its commands take the address away as well")
        expectEqual(stripped.record.aliases.count, 0, "one removal is enough")

        // An exit status alone does not decide a removal: what is left does.
        let noisy = FakeRepairWorld(.macB)
        noisy.approval = FakeRepairWorld.applying
        _ = noisy.fix()
        noisy.approval = { request, world in
            _ = FakeRepairWorld.applying(request, world)
            return .commandFailed
        }
        expectEqual(noisy.remove().outcome, .removed, "a removal that reported an error but left nothing")
        let stubborn = FakeRepairWorld(.macB)
        stubborn.approval = FakeRepairWorld.applying
        _ = stubborn.fix()
        stubborn.approval = { request, world in
            world.takeAddress()
            world.tools.keeperJobs = [:]
            return .applied
        }
        expectEqual(stubborn.remove().outcome, .removalNotVerified, "a removal that left the job definition")
        expectEqual(stubborn.record.aliases.count, 1, "the record is kept while something is left")

        // Everything went, but one of the three readings cannot be made
        // afterwards: nothing is reported removed, and the record stays.
        let unreadable: [(String, (FakeRepairWorld) -> Void)] = [
            ("the interface listing", { $0.tools.interfaces = .timedOut }),
            ("the loaded job", { $0.tools.keeperJobs["en6"] = .timedOut }),
            ("the job definitions' directory", { $0.tools.keeperDirectory = .outputTooLarge }),
        ]
        for (answer, outcome) in [(ClusterLinkApprovalResult.applied, ClusterLinkRepairOutcome.removalNotVerified),
                                  (.commandFailed, .commandFailed)] {
            for (reading, lose) in unreadable {
                let unseen = FakeRepairWorld(.macB)
                unseen.approval = FakeRepairWorld.applying
                _ = unseen.fix()
                unseen.approval = { request, world in
                    _ = FakeRepairWorld.applying(request, world)
                    lose(world)
                    return answer
                }
                expectEqual(unseen.remove().outcome, outcome, "a removal (\(answer)) after which \(reading) cannot be read")
                expectEqual(unseen.record.aliases.count, 1, "the record is kept while \(reading) cannot be read (\(answer))")
            }
        }
    }

    static func dryRuns() {
        guard let address = derivedAddress, let keeper = ClusterLinkAddressKeeper(interface: "en6", address: address) else {
            expect(false, "fixture keeper"); return
        }
        func neverAsked(_ world: FakeRepairWorld, _ label: String) {
            expectEqual(world.approvalRequests, [], "\(label): no prompt")
            expectEqual(world.recordSaves, 0, "\(label): the record is not touched")
        }

        // The durable fix on Mac B: the exact commands, and nothing done.
        let durable = FakeRepairWorld(.macB)
        durable.approval = FakeRepairWorld.applying
        let planned = durable.fix(dryRun: true)
        expectEqual(planned.outcome, .dryRun, "durable dry run")
        expectEqual(planned.plannedCommands, keeper.installCommands, "the commands an approval would run")
        expectEqual([planned.device, planned.interface], ["rdma_en6", "en6"], "dry run target")
        expectEqual(planned.durable, true, "dry run mode")
        expectEqual(planned.outcome.exitCode, 0, "dry run exit status")
        expectEqual(planned.summaryLines, ["Link fix: dryRun", planned.message] + keeper.installCommands.map { "  " + $0 },
            "dry run text: the outcome, the explanation, then one command per line")
        expect(compactJSON(planned).contains("\"plannedCommands\":[\"/bin/launchctl bootout") && compactJSON(planned).contains("\"outcome\":\"dryRun\""),
            "dry run JSON carries the commands")
        expect(planned.message.contains("nothing was changed") && planned.message.contains("approval"), "dry run explanation")
        neverAsked(durable, "durable dry run")
        expectEqual(durable.tools.keeperJobFiles.count, 0, "a dry run installs nothing")

        let temporary = FakeRepairWorld.temporary(.macB)
        let plannedTemporary = temporary.fix(dryRun: true)
        expectEqual(plannedTemporary.plannedCommands, ["/sbin/ifconfig en6 inet \(FakeRepairWorld.en6Address) netmask 255.255.0.0 alias"],
            "temporary dry run")
        expectEqual(plannedTemporary.durable, false, "temporary dry run mode")
        neverAsked(temporary, "temporary dry run")

        // A lost address is planned with the recorded address, which is the one this Mac derives.
        guard let earlier = ClusterLinkLocalAddress(dottedDecimal: "169.254.77.7") else { expect(false, "fixture address"); return }
        let lost = FakeRepairWorld(.macB)
        lost.record.aliases = [.init(interface: "en6", address: address)]
        expectEqual(lost.fix(dryRun: true).plannedCommands, keeper.installCommands, "a repair is planned with the recorded address")
        neverAsked(lost, "repair dry run")
        // A record that names another address, as after a home directory copied
        // from another Mac: with nothing of it on this Mac, this Mac's own
        // address is used, so the two Macs do not end up with the same one.
        let copied = FakeRepairWorld(.macB)
        copied.record.aliases = [.init(interface: "en6", address: earlier)]
        expectEqual(copied.fix(dryRun: true).plannedCommands, keeper.installCommands, "a foreign record does not choose the address")
        copied.approval = FakeRepairWorld.applying
        expectEqual(copied.fix().outcome, .fixed, "fix over a foreign record")
        expectEqual(copied.record.aliases, [.init(interface: "en6", address: address)], "the record then names what is on this Mac")
        // While its keeper is still installed here, the recorded address stays the one in use.
        let installedElsewhere = FakeRepairWorld(.macB)
        installedElsewhere.record.aliases = [.init(interface: "en6", address: earlier)]
        installedElsewhere.tools.installKeeper(interface: "en6", address: "169.254.77.7")
        installedElsewhere.tools.keeperJobs = [:]
        expectEqual(installedElsewhere.fix(dryRun: true).plannedCommands,
            ClusterLinkAddressKeeper(interface: "en6", address: earlier)?.installCommands ?? [], "a recorded address with something left is kept")

        // Where the fix would not act, a dry run says the same thing and plans nothing.
        let ready = FakeRepairWorld(.macA)
        let readyPlan = ready.fix(dryRun: true)
        expectEqual(readyPlan.outcome, .alreadyReady, "dry run on a ready Mac")
        expectEqual(readyPlan.plannedCommands, [], "nothing to run on a ready Mac")
        neverAsked(ready, "ready dry run")
        var down = FakeLinkTools.macB
        down.deviceList = .output(LinkFixtures.deviceList(active: nil))
        expectEqual(FakeRepairWorld(down).fix(dryRun: true).outcome, .nothingFixable(.noActivePort), "dry run without a cable")
        expectEqual(FakeRepairWorld(.macB).fix(device: "rdma_en9", dryRun: true).outcome, .deviceNotListed, "dry run for an unlisted device")
        var blind = FakeLinkTools.macB
        blind.defaultRoute = .timedOut
        expectEqual(FakeRepairWorld(blind).fix(dryRun: true).outcome, .nothingFixable(.probeFailed), "dry run without a readable baseline")
        let anonymous = FakeRepairWorld(.macB)
        anonymous.machineIdentifier = nil
        expectEqual(anonymous.fix(dryRun: true).outcome, .machineIdentityUnavailable, "dry run without a machine value")

        // Removal: what it would undo, and a record that is left alone.
        let installed = FakeRepairWorld(.macB)
        installed.approval = FakeRepairWorld.applying
        _ = installed.fix()
        let saves = installed.recordSaves
        let removal = installed.remove(dryRun: true)
        expectEqual(removal.outcome, .dryRun, "removal dry run")
        expectEqual(removal.plannedCommands, ["/bin/launchctl bootout system/io.darkbloom.cluster-link.en6",
            "/bin/rm -f /Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist",
            "/sbin/ifconfig en6 inet \(FakeRepairWorld.en6Address) -alias"], "the commands a removal would run")
        expectEqual(installed.approvalRequests.count, 1, "removal dry run: no prompt")
        expectEqual(installed.recordSaves, saves, "removal dry run: the record is not touched")
        expectEqual(removal.summaryLines.first, "Link remove: dryRun", "removal dry run headline")

        // A keeper whose record is gone is found by its file and removed in full.
        let orphaned = FakeRepairWorld(.macBFixed(address: FakeRepairWorld.en6Address))
        orphaned.tools.installKeeper(interface: "en6", address: FakeRepairWorld.en6Address)
        orphaned.approval = FakeRepairWorld.applying
        expectEqual(orphaned.remove(device: "rdma_en5").outcome, .nothingRecorded, "another port has neither a record nor a keeper")
        let orphanPlan = orphaned.remove(dryRun: true)
        expectEqual(orphanPlan.outcome, .dryRun, "an unrecorded keeper is found")
        expectEqual(orphanPlan.plannedCommands, removal.plannedCommands, "and planned for removal like a recorded one")
        expectEqual(orphaned.remove(device: "rdma_en6").outcome, .removed, "an unrecorded keeper is removed")
        expectEqual(orphaned.approvalRequests.last, ClusterLinkPrivilegedRequest(.remove(.init(address: true, keeperJob: true, keeperFile: true)),
            interface: "en6", address: address), "with the address its job definition names")
        expectEqual(orphaned.remove().outcome, .nothingRecorded, "after which nothing is left to find")
        // A file with a keeper's name that is not one Darkbloom writes is not taken for its own.
        let foreign = FakeRepairWorld(.macB)
        foreign.tools.keeperJobFiles["en6"] = .output(LinkFixtures.keeperJobJSON(interface: "en6", address: FakeRepairWorld.en6Address, interval: 60))
        expectEqual(foreign.remove().outcome, .nothingRecorded, "a job definition that differs is left alone")
        expectEqual(foreign.approvalRequests.count, 0, "and nothing is asked")

        let spent = FakeRepairWorld(.macB)
        spent.record.aliases = [.init(interface: "en6", address: earlier)]
        let spentPlan = spent.remove(dryRun: true)
        expectEqual(spentPlan.outcome, .alreadyAbsent, "removal dry run with nothing left")
        expectEqual(spent.record.aliases.count, 1, "a dry run does not clear a spent entry")
        expect(spentPlan.message.contains("nothing to undo") && !spentPlan.message.contains("was cleared"),
            "a dry run does not say that it cleared the record")
        expectEqual(spent.remove().outcome, .alreadyAbsent, "a real removal with nothing left")
        expectEqual(spent.record.aliases.count, 0, "a real removal clears the spent entry")
    }
}
