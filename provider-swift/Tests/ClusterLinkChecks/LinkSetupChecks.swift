import Foundation

/// The guided `darkbloom cluster` flow as a state machine: reports and fix
/// results in, lines and the next action out. No terminal, probe or prompt.
extension ClusterLinkCheck {
    private typealias Flow = ClusterLinkSetupFlow

    private struct Transcript: Equatable {
        var lines = [String]()
        var actions = [Flow.Action]()
        var exitCode: Int32?
        var state: ClusterLinkReadinessState?
    }

    /// Drives the flow the way the command does. Each inspection or wait takes
    /// the next report; a wait with no report left is an interrupt.
    private static func run(mayPrompt: Bool, _ reports: [FakeLinkTools], fix: ClusterLinkRepairOutcome? = nil,
                            temporary: Bool = false, dryRun: Bool = false,
                            recorded: ClusterLinkAliasRecord = ClusterLinkAliasRecord()) -> Transcript {
        var flow = Flow(mayPrompt: mayPrompt, temporary: temporary, dryRun: dryRun), pending = reports[...], transcript = Transcript()
        func report(_ tools: FakeLinkTools) -> ClusterLinkReadinessReport {
            ClusterLinkReadinessProbe.inspect(run: tools.outcome(of:), recorded: recorded)
        }
        var step = flow.begin()
        for _ in 0..<32 {
            transcript.lines += step.lines
            transcript.actions.append(step.action)
            switch step.action {
            case .inspect, .awaitConnection, .awaitKeeper:
                step = pending.popFirst().map { flow.observed(report($0)) } ?? flow.interrupted()
            case .fix(let device):
                let outcome = dryRun ? ClusterLinkRepairOutcome.dryRun : fix ?? .approvalUnavailable
                step = flow.repaired(.init(operation: .fix, outcome: outcome, device: device,
                    interface: ClusterLinkName.interface(ofDevice: device), durable: !temporary,
                    plannedCommands: outcome == .dryRun ? plannedCommands : [],
                    manualCommands: ["sudo /sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias"]))
            case .finish(let exitCode):
                transcript.exitCode = exitCode
                transcript.state = flow.linkState
                return transcript
            }
        }
        return transcript
    }

    /// What a dry run of the fix would report as the commands to run.
    private static let plannedCommands = ["/bin/launchctl bootout system/io.darkbloom.cluster-link.en6 2>/dev/null || true",
        "/bin/launchctl bootstrap system /Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist"]

    static func setupFlow() {
        let rdma = "RDMA setup detected: RDMA over Thunderbolt is enabled on this Mac."
        let about = "Thunderbolt port en6 has no IPv4 address of its own, which RDMA needs, so Darkbloom will give it a link-local one and install a small system job that keeps it there; approve the macOS prompt to continue."
        let kept = "A system job (io.darkbloom.cluster-link.en6) puts the address back whenever macOS removes it, also after a restart; `darkbloom cluster link --remove` removes both."
        let ready = ["This Mac's link is ready.", "Run `darkbloom cluster` on the other Mac too."]
        var down = FakeLinkTools.macB, disabled = FakeLinkTools.macA, missing = FakeLinkTools.macA, unread = FakeLinkTools.macA
        var unpublished = FakeLinkTools.macA
        down.deviceList = .output(LinkFixtures.deviceList(active: nil))
        disabled.controlStatus = .output("disabled\n")
        missing.controlStatus = .unavailable
        unread.interfaces = .timedOut
        unpublished.details["rdma_en7"] = .output(LinkFixtures.detailWithoutMappedGID("rdma_en7"))

        // A Mac that is already ready walks every step, asks for nothing, and
        // reads the same whether or not a prompt would be allowed.
        for mayPrompt in [true, false] {
            let already = run(mayPrompt: mayPrompt, [.macA])
            expectEqual(already.lines, [rdma, "Connection detected: rdma_en7 (en7) is active.",
                "Address ready: rdma_en7 (en7) has its own IPv4 address and publishes the GID RDMA needs."] + ready,
                "ready Mac transcript (prompt allowed: \(mayPrompt))")
            expectEqual(already.actions, [.inspect, .finish(exitCode: 0)], "ready Mac is inspected once and never fixed")
            expectEqual(already.state, .ready, "ready Mac state")
        }
        // The GID alone decides readiness. A port that publishes it without
        // an IPv4 address of its own is ready, and no address is claimed for it.
        var mapped = FakeLinkTools.macB
        mapped.details["rdma_en6"] = .output(LinkFixtures.detailWithMappedGID("rdma_en6"))
        let addressless = run(mayPrompt: true, [mapped], fix: .fixed)
        expectEqual(addressless.lines, [rdma, "Connection detected: rdma_en6 (en6) is active.",
            "Address ready: rdma_en6 (en6) publishes the GID RDMA needs."] + ready, "ready without an address of its own")
        expectEqual(addressless.actions, [.inspect, .finish(exitCode: 0)], "ready without an address of its own is never fixed")

        // The bridged Mac, approved at the macOS prompt.
        let approved = run(mayPrompt: true, [.macB], fix: .fixed)
        expectEqual(approved.lines, [rdma, "Connection detected: rdma_en6 (en6) is active.", about,
            "Address assigned: rdma_en6 (en6) now publishes the GID RDMA needs.",
            kept] + ready,
            "bridged Mac, approved")
        expectEqual(approved.actions, [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "bridged Mac actions")
        expectEqual(approved.state, .ready, "bridged Mac ends ready")

        // The same Mac, prompt cancelled.
        let declined = run(mayPrompt: true, [.macB], fix: .approvalDeclined)
        expectEqual(declined.lines, [rdma, "Connection detected: rdma_en6 (en6) is active.", about,
            "The macOS prompt was cancelled, so this link cannot be used yet.",
            "Run `darkbloom cluster` again and approve the prompt to finish; `darkbloom cluster --temporary` adds the address without installing anything, until macOS next removes it."],
            "bridged Mac, declined")
        expectEqual(declined.exitCode, 2, "declined exit status")
        expectEqual(declined.state, .portBridgedWithoutAddress, "declined leaves the state as it was")

        // Without a terminal, or with --json, the flow never asks: it says what is next.
        let unattended = run(mayPrompt: false, [.macB], fix: .fixed)
        expectEqual(unattended.lines, [rdma, "Connection detected: rdma_en6 (en6) is active.",
            "Thunderbolt port en6 has no IPv4 address of its own, which RDMA needs.",
            "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt, or add `--yes` to allow the prompt from here."],
            "bridged Mac, unattended")
        expectEqual(unattended.actions, [.inspect, .finish(exitCode: 1)], "an unattended run never reaches the fix")

        // No cable yet: an attended run waits, says so once, and goes on when the port comes up.
        let plugged = run(mayPrompt: true, [down, down, .macB], fix: .fixed)
        expectEqual(plugged.lines, [rdma, "Waiting for a Thunderbolt 5 connection to another Mac…",
            "Connection detected: rdma_en6 (en6) is active.", about,
            "Address assigned: rdma_en6 (en6) now publishes the GID RDMA needs.",
            kept] + ready,
            "cable plugged in while waiting")
        expectEqual(plugged.actions, [.inspect, .awaitConnection, .awaitConnection, .fix(device: "rdma_en6"), .finish(exitCode: 0)],
            "waiting actions")
        expectEqual(run(mayPrompt: true, [down, .macA]).lines, [rdma, "Waiting for a Thunderbolt 5 connection to another Mac…",
            "Connection detected: rdma_en7 (en7) is active.",
            "Address ready: rdma_en7 (en7) has its own IPv4 address and publishes the GID RDMA needs."] + ready,
            "a port that comes up ready needs no prompt")

        let interrupted = run(mayPrompt: true, [down])
        expectEqual(interrupted.lines, [rdma, "Waiting for a Thunderbolt 5 connection to another Mac…",
            "Stopped before a connection was detected; run `darkbloom cluster` again once the cable is connected."],
            "interrupted while waiting")
        expectEqual(interrupted.exitCode, 1, "interrupted exit status")

        let unplugged = run(mayPrompt: false, [down])
        expectEqual(unplugged.lines, [rdma, "No Thunderbolt 5 connection to another Mac is active.",
            "Next: connect the two Macs with a Thunderbolt 5 cable, then run `darkbloom cluster` again."], "no cable, unattended")
        expectEqual(unplugged.actions, [.inspect, .finish(exitCode: 1)], "an unattended run does not wait")

        // The wait hands a reading back only when something changed, and no
        // change out of a cable-less reading leads into the wait again, so the
        // flow and the wait cannot spin between each other.
        let cableless = down.inspect().report
        expectEqual(ClusterLinkWatch.events(previous: cableless, current: cableless), [], "a cable-less reading repeated is no change")
        for (label, next) in [("a port coming up ready", FakeLinkTools.macA), ("a port coming up without an address", .macB),
                              ("RDMA turned off", disabled), ("RDMA tools gone", missing), ("an unreadable state", unread)] {
            expect(!ClusterLinkWatch.events(previous: cableless, current: next.inspect().report).isEmpty, "\(label) ends the wait")
            let after = run(mayPrompt: true, [down, next], fix: .fixed)
            expectEqual(Array(after.actions.prefix(2)), [.inspect, .awaitConnection], "\(label) is reached from the wait")
            expect(!after.actions.dropFirst(2).contains(.awaitConnection), "\(label) does not lead into the wait again")
        }

        // RDMA itself is not usable: the guidance, and nothing claimed that was not seen.
        for (label, tools, state) in [("RDMA disabled", disabled, ClusterLinkReadinessState.rdmaDisabled),
                                      ("RDMA tools missing", missing, .rdmaUnavailable), ("state unreadable", unread, .probeFailed)] {
            for mayPrompt in [true, false] {
                let stopped = run(mayPrompt: mayPrompt, [tools], fix: .fixed)
                expectEqual(stopped.lines, [state.guidance ?? "?"], "\(label) transcript")
                expectEqual(stopped.actions, [.inspect, .finish(exitCode: 1)], "\(label) stops at once")
                expectEqual(stopped.state, state, "\(label) state")
            }
        }
        let lost = run(mayPrompt: true, [down, disabled])
        expectEqual(lost.lines, [rdma, "Waiting for a Thunderbolt 5 connection to another Mac…",
            ClusterLinkReadinessState.rdmaDisabled.guidance ?? "?"], "RDMA turned off while waiting")
        expectEqual(lost.exitCode, 1, "RDMA turned off while waiting exit status")

        // An active port that adding an address does not cure.
        let stuck = run(mayPrompt: true, [unpublished], fix: .fixed)
        expectEqual(stuck.lines, [rdma, "Connection detected: rdma_en7 (en7) is active.",
            ClusterLinkReadinessState.gidNotPublished.guidance ?? "?"], "GID not published")
        expectEqual(stuck.actions, [.inspect, .finish(exitCode: 1)], "GID not published is never fixed")

        // Two ports that both lack an address: the flow does not choose.
        let two = FakeLinkTools(
            deviceList: .output(LinkFixtures.deviceBlock("rdma_en5", active: true) + LinkFixtures.deviceBlock("rdma_en6", active: true)),
            interfaces: .output(LinkFixtures.port("en5", active: true, ipv4: nil) + LinkFixtures.port("en6", active: true, ipv4: nil)),
            details: ["rdma_en5": .output(LinkFixtures.detailWithoutMappedGID("rdma_en5")),
                      "rdma_en6": .output(LinkFixtures.detailWithoutMappedGID("rdma_en6"))])
        let undecided = run(mayPrompt: true, [two], fix: .fixed)
        expectEqual(undecided.lines, [rdma, "Connection detected: rdma_en5 (en5), rdma_en6 (en6) are active.",
            "More than one active port lacks an address (rdma_en5, rdma_en6); choose one with `darkbloom cluster link --fix --device rdma_en5`."],
            "two candidate ports")
        expectEqual(undecided.actions, [.inspect, .finish(exitCode: 1)], "two candidate ports are never fixed unasked")

        // Every way the fix can end is reported in its own words and exit status.
        for outcome in [ClusterLinkRepairOutcome.approvalUnavailable, .commandFailed, .appliedButNotReady([.deviceNotReady]),
                        .machineIdentityUnavailable, .recordUnavailable, .nothingFixable(.probeFailed),
                        // The cable was pulled before the fix looked.
                        .nothingFixable(.noActivePort), .deviceNotListed] {
            let ended = run(mayPrompt: true, [.macB], fix: outcome)
            let result = ClusterLinkRepairResult(operation: .fix, outcome: outcome, device: "rdma_en6", interface: "en6", durable: true)
            expectEqual(Array(ended.lines.suffix(1)), [result.message], "\(outcome.code) is reported with the fix's own message")
            expectEqual(ended.exitCode, outcome.exitCode, "\(outcome.code) exit status")
            expect(!ended.lines.contains("This Mac's link is ready."), "\(outcome.code) claims no readiness")
            expect(ended.state != .ready, "\(outcome.code) reports no ready state")
            expectNoAddress(ended.lines.joined(separator: "\n"), "\(outcome.code) transcript")
        }
        // Status 0 is readiness and nothing else: an outcome that is not a
        // fix's, and whose own status is 0, is never taken for it.
        for outcome in [ClusterLinkRepairOutcome.removed, .alreadyAbsent, .nothingRecorded] {
            let ended = run(mayPrompt: true, [.macB], fix: outcome)
            expectEqual(outcome.exitCode, 0, "\(outcome.code) has status 0 as a removal")
            expectEqual(ended.exitCode, 1, "\(outcome.code) does not end the setup with status 0")
            expect(!ended.lines.contains("This Mac's link is ready."), "\(outcome.code) claims no readiness")
            expect(ended.state != .ready, "\(outcome.code) reports no ready state")
        }
        let raced = run(mayPrompt: true, [.macB], fix: .alreadyReady)
        expectEqual(Array(raced.lines.suffix(3)), ["Address ready: rdma_en6 (en6) publishes the GID RDMA needs."] + ready,
            "ready by the time the fix looked")
        expectEqual(raced.exitCode, 0, "ready by the time the fix looked exit status")
        expectEqual(raced.state, .ready, "ready by the time the fix looked state")

        // When the prompt is part of the flow.
        for (terminal, json, yes, expected) in [(true, false, false, true), (true, true, false, false), (false, false, false, false),
                                                (false, true, false, false), (false, false, true, true), (true, true, true, true),
                                                (false, true, true, true), (true, false, true, true)] {
            expectEqual(Flow.mayPrompt(standardOutputIsTerminal: terminal, json: json, yes: yes), expected,
                "prompt allowed for terminal \(terminal), json \(json), yes \(yes)")
        }

        let summary = ClusterLinkSetupResult(ready: false, state: declined.state, narration: declined.lines)
        let encoded = compactJSON(summary)
        expect(encoded.contains("\"schema\":\"darkbloom_cluster_setup_v1\"") && encoded.contains("\"ready\":false")
            && encoded.contains("\"state\":\"portBridgedWithoutAddress\"") && encoded.contains("\"narration\":["), "setup JSON identity")
        for transcript in [approved, declined, unattended, plugged, undecided] {
            expectNoAddress(transcript.lines.joined(separator: "\n"), "setup transcript")
        }
        expectNoAddress(encoded, "setup JSON")
    }

    /// The durable install is the default; these are the other ways through
    /// the address step.
    static func setupFlowModes() {
        let rdma = "RDMA setup detected: RDMA over Thunderbolt is enabled on this Mac."
        let connection = "Connection detected: rdma_en6 (en6) is active."
        let ready = ["This Mac's link is ready.", "Run `darkbloom cluster` on the other Mac too."]
        let assigned = "Address assigned: rdma_en6 (en6) now publishes the GID RDMA needs."
        let kept = "A system job (io.darkbloom.cluster-link.en6) puts the address back whenever macOS removes it, also after a restart; `darkbloom cluster link --remove` removes both."

        // --temporary: the address alone, and said to be so.
        let temporary = run(mayPrompt: true, [.macB], fix: .fixed, temporary: true)
        expectEqual(temporary.lines, [rdma, connection,
            "Thunderbolt port en6 has no IPv4 address of its own, which RDMA needs, so Darkbloom will give it a link-local one that lasts until macOS next removes it; approve the macOS prompt to continue.",
            assigned,
            "The address is temporary: macOS removes it when it next reconfigures the port, and at a restart; run `darkbloom cluster` to keep it."] + ready,
            "bridged Mac, temporary address approved")
        let temporaryDeclined = run(mayPrompt: true, [.macB], fix: .approvalDeclined, temporary: true)
        expectEqual(Array(temporaryDeclined.lines.suffix(2)), ["The macOS prompt was cancelled, so this link cannot be used yet.",
            "Run `darkbloom cluster --temporary` again and approve the prompt to finish."], "temporary address declined")
        expectEqual(temporaryDeclined.exitCode, 2, "temporary address declined exit status")

        // An address Darkbloom assigned to the port before is missing: said plainly, and repaired by the same one approval.
        guard let earlier = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20") else { expect(false, "fixture address"); return }
        let record = ClusterLinkAliasRecord(aliases: [.init(interface: "en6", address: earlier)])
        let lost = "Thunderbolt port en6 does not have the address Darkbloom has on record for it, which RDMA needs"
        let repaired = run(mayPrompt: true, [.macB], fix: .fixed, recorded: record)
        expectEqual(repaired.lines, [rdma, connection,
            lost + ", so Darkbloom will put it there and install a small system job that keeps it there; approve the macOS prompt to continue.",
            assigned, kept] + ready, "lost address repaired")
        expectEqual(repaired.actions, [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "one fix for a lost address")
        let lostUnattended = run(mayPrompt: false, [.macB], fix: .fixed, recorded: record)
        expectEqual(lostUnattended.lines, [rdma, connection, lost + ".",
            "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt, or add `--yes` to allow the prompt from here."],
            "lost address, unattended")
        expectEqual(lostUnattended.actions, [.inspect, .finish(exitCode: 1)], "a lost address is never repaired unattended")
        let lostTemporary = run(mayPrompt: true, [.macB], fix: .fixed, temporary: true, recorded: record)
        expectEqual(lostTemporary.lines[2], lost + ", so Darkbloom will put it there until macOS next removes it; approve the macOS prompt to continue.",
            "lost address, temporary again")

        // The address is missing but its job is running: the job is about to
        // put it back, so the flow waits for that once and asks for nothing.
        var strippedKept = FakeLinkTools.macB
        strippedKept.installKeeper(interface: "en6", address: "169.254.10.20")
        var restored = FakeLinkTools.macBFixed(address: "169.254.10.20")
        restored.installKeeper(interface: "en6", address: "169.254.10.20")
        let waiting = lost + "; its system job (io.darkbloom.cluster-link.en6) puts it there within about 10 seconds. Waiting for it…"
        let addressBack = ["Address ready: rdma_en6 (en6) has its own IPv4 address and publishes the GID RDMA needs.",
            "A system job (io.darkbloom.cluster-link.en6) keeps that address there."]
        for mayPrompt in [true, false] {
            let selfHealed = run(mayPrompt: mayPrompt, [strippedKept, restored], fix: .fixed, recorded: record)
            expectEqual(selfHealed.lines, [rdma, connection, waiting] + addressBack + ready, "a running keeper is waited for (prompt allowed: \(mayPrompt))")
            expectEqual(selfHealed.actions, [.inspect, .awaitKeeper, .finish(exitCode: 0)], "no prompt while the keeper is about to act")
        }
        // It did not: the same one approval installs it afresh, and the wait is not repeated.
        let stuckKeeper = run(mayPrompt: true, [strippedKept, strippedKept], fix: .fixed, recorded: record)
        expectEqual(stuckKeeper.lines, [rdma, connection, waiting,
            lost + ", so Darkbloom will put it there and install its system job afresh; approve the macOS prompt to continue.", assigned, kept] + ready,
            "a keeper that does not restore the address is installed afresh")
        expectEqual(stuckKeeper.actions, [.inspect, .awaitKeeper, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "one wait, then one fix")
        let stuckUnattended = run(mayPrompt: false, [strippedKept, strippedKept], fix: .fixed, recorded: record)
        expectEqual(stuckUnattended.actions, [.inspect, .awaitKeeper, .finish(exitCode: 1)], "unattended: one wait, then what is next")
        expectEqual(Array(stuckUnattended.lines.suffix(2)), [lost + ".",
            "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt, or add `--yes` to allow the prompt from here."],
            "unattended wording after the wait")
        expectEqual(run(mayPrompt: false, [strippedKept], dryRun: true, recorded: record).actions,
            [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "a dry run does not wait for the keeper")
        // A port that is ready on some other address is not said to be kept by a job for the recorded one.
        var otherAddress = FakeLinkTools.macBFixed(address: "169.254.10.21")
        otherAddress.installKeeper(interface: "en6", address: "169.254.10.20")
        expectEqual(run(mayPrompt: true, [otherAddress], fix: .fixed, recorded: record).lines, [rdma, connection,
            "Address ready: rdma_en6 (en6) has its own IPv4 address and publishes the GID RDMA needs."] + ready,
            "nothing is claimed about a job when the port is ready on another address")

        // The address is still there and its job is running: nothing is missing, and nothing is asked.
        let present = FakeLinkTools.macBFixed(address: "169.254.10.20")
        var keptTools = present
        keptTools.installKeeper(interface: "en6", address: "169.254.10.20")
        let addressReady = "Address ready: rdma_en6 (en6) has its own IPv4 address and publishes the GID RDMA needs."
        for mayPrompt in [true, false] {
            let settled = run(mayPrompt: mayPrompt, [keptTools], fix: .fixed, recorded: record)
            expectEqual(settled.lines, [rdma, connection, addressReady,
                "A system job (io.darkbloom.cluster-link.en6) keeps that address there."] + ready, "a kept address is said to be kept")
            expectEqual(settled.actions, [.inspect, .finish(exitCode: 0)], "a kept address needs no prompt")
        }

        // The address is still there but nothing would put it back: the link
        // is ready, and the same one approval adds the job that keeps it.
        let temporaryFound = "Address ready: rdma_en6 (en6) publishes the GID RDMA needs, but nothing keeps its address there and macOS removes it when it next reconfigures the port"
        let keeping = run(mayPrompt: true, [present], fix: .fixed, recorded: record)
        expectEqual(keeping.lines, [rdma, connection,
            temporaryFound + ", so Darkbloom will install a small system job that keeps it there; approve the macOS prompt to continue.",
            kept] + ready, "a temporary address is made to last")
        expectEqual(keeping.actions, [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "one fix for a temporary address")
        expect(!keeping.lines.contains(assigned), "nothing is said to be assigned to a port that had its address")
        // Cancelled: nothing was taken away, so the link is still ready.
        let keepingDeclined = run(mayPrompt: true, [present], fix: .approvalDeclined, recorded: record)
        expectEqual(Array(keepingDeclined.lines.suffix(3)),
            ["The macOS prompt was cancelled, so nothing keeps the address yet; run `darkbloom cluster` in a terminal on this Mac and approve the prompt to keep it."] + ready,
            "keeping declined")
        expectEqual([keepingDeclined.exitCode, keepingDeclined.state == .ready ? 0 : 1], [0, 0], "a declined keeper leaves a ready link ready")
        // No prompt could be shown: the same, since nothing was taken away either.
        let keepingUnasked = run(mayPrompt: true, [present], fix: .approvalUnavailable, recorded: record)
        expectEqual(Array(keepingUnasked.lines.suffix(3)),
            ["The macOS prompt could not be shown or was not answered here, so nothing keeps the address yet; run `darkbloom cluster` in a terminal on this Mac and approve the prompt to keep it."] + ready,
            "keeping without a prompt")
        expectEqual([keepingUnasked.exitCode, keepingUnasked.state == .ready ? 0 : 1], [0, 0], "a keeper that could not be asked for leaves a ready link ready")
        // The port stopped being ready after an approved change: the last reading is not repeated as the state.
        let keepingBroke = run(mayPrompt: true, [present], fix: .appliedButNotReady([.deviceNotReady]), recorded: record)
        expectEqual([keepingBroke.exitCode == 4, keepingBroke.state == nil], [true, true], "a port that is no longer ready is not reported ready")
        // Unattended: ready, with what to run to keep it so.
        let keepingUnattended = run(mayPrompt: false, [present], fix: .fixed, recorded: record)
        expectEqual(keepingUnattended.lines, [rdma, connection, temporaryFound + ".",
            "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt, or add `--yes` to allow the prompt from here."]
            + ready, "a temporary address, unattended")
        expectEqual(keepingUnattended.actions, [.inspect, .finish(exitCode: 0)], "a temporary address is never kept unattended")
        // The keeper could not be installed: the fix's own words and status, whatever the link is.
        let keepingFailed = run(mayPrompt: true, [present], fix: .appliedButNotReady([.addressKeeperNotRunning]), recorded: record)
        expectEqual(keepingFailed.exitCode, 4, "a keeper that did not start is not a success")
        expect(!keepingFailed.lines.contains("This Mac's link is ready."), "and claims nothing")
        // --temporary asks for nothing on a port that has its address, and says what that address is.
        let leftTemporary = run(mayPrompt: true, [present], fix: .fixed, temporary: true, recorded: record)
        expectEqual(leftTemporary.lines, [rdma, connection, addressReady,
            "The address is temporary: macOS removes it when it next reconfigures the port, and at a restart; run `darkbloom cluster` to keep it."]
            + ready, "--temporary on a port with a temporary address")
        expectEqual(leftTemporary.actions, [.inspect, .finish(exitCode: 0)], "--temporary installs nothing")
        // A dry run plans the keeper for it.
        let keepingPlan = run(mayPrompt: false, [present], dryRun: true, recorded: record)
        expectEqual(Array(keepingPlan.lines.prefix(4)), [rdma, connection, temporaryFound + ".",
            "Dry run: nothing was changed. With your approval in the macOS prompt, these commands would run as an administrator, in this order."],
            "dry run for a temporary address")
        expectEqual(keepingPlan.actions, [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "a dry run plans the keeper and stops")
        for transcript in [keeping, keepingDeclined, keepingUnattended, leftTemporary] {
            expectNoAddress(transcript.lines.joined(separator: "\n"), "temporary address transcript")
        }

        // --dry-run: the plan, wherever it runs, and never a wait or a prompt.
        for mayPrompt in [true, false] {
            let planned = run(mayPrompt: mayPrompt, [.macB], dryRun: true)
            expectEqual(planned.lines, [rdma, connection, "Thunderbolt port en6 has no IPv4 address of its own, which RDMA needs.",
                "Dry run: nothing was changed. With your approval in the macOS prompt, these commands would run as an administrator, in this order."]
                + plannedCommands.map { "  " + $0 }, "dry run on the bridged Mac (prompt allowed: \(mayPrompt))")
            expectEqual(planned.actions, [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "a dry run plans the fix and stops")
            expectEqual(planned.state, .portBridgedWithoutAddress, "a dry run leaves the link as it found it")
            expect(!planned.lines.contains("This Mac's link is ready."), "a dry run claims no readiness")

            var down = FakeLinkTools.macB
            down.deviceList = .output(LinkFixtures.deviceList(active: nil))
            let unplugged = run(mayPrompt: mayPrompt, [down], dryRun: true)
            expectEqual(unplugged.actions, [.inspect, .finish(exitCode: 1)], "a dry run does not wait for a cable")
            expectEqual(unplugged.lines, [rdma, "No Thunderbolt 5 connection to another Mac is active.",
                "Next: connect the two Macs with a Thunderbolt 5 cable, then run `darkbloom cluster` again."], "dry run without a cable")
            expectEqual(run(mayPrompt: mayPrompt, [.macA], dryRun: true).actions, [.inspect, .finish(exitCode: 0)], "dry run on a ready Mac")
        }
        let lostPlan = run(mayPrompt: false, [.macB], dryRun: true, recorded: record)
        expectEqual(lostPlan.lines[2], lost + ".", "dry run names a lost address")
    }
}
