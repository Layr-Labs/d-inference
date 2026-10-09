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
    private static func run(mayPrompt: Bool, _ reports: [FakeLinkTools], fix: ClusterLinkRepairOutcome? = nil) -> Transcript {
        var flow = Flow(mayPrompt: mayPrompt), pending = reports[...], transcript = Transcript()
        var step = flow.begin()
        for _ in 0..<32 {
            transcript.lines += step.lines
            transcript.actions.append(step.action)
            switch step.action {
            case .inspect, .awaitConnection:
                step = pending.popFirst().map { flow.observed($0.inspect().report) } ?? flow.interrupted()
            case .fix(let device):
                step = flow.repaired(.init(operation: .fix, outcome: fix ?? .approvalUnavailable, device: device,
                    interface: ClusterLinkName.interface(ofDevice: device),
                    manualCommand: "sudo /sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias"))
            case .finish(let exitCode):
                transcript.exitCode = exitCode
                transcript.state = flow.linkState
                return transcript
            }
        }
        return transcript
    }

    static func setupFlow() {
        let rdma = "RDMA setup detected: RDMA over Thunderbolt is enabled on this Mac."
        let about = "Thunderbolt port en6 has no IPv4 address of its own, which RDMA needs, so Darkbloom will give it a link-local one; approve the macOS prompt to continue."
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
            "The address is lost at a restart or when the cable is replugged; run `darkbloom cluster` again then."] + ready,
            "bridged Mac, approved")
        expectEqual(approved.actions, [.inspect, .fix(device: "rdma_en6"), .finish(exitCode: 0)], "bridged Mac actions")
        expectEqual(approved.state, .ready, "bridged Mac ends ready")

        // The same Mac, prompt cancelled.
        let declined = run(mayPrompt: true, [.macB], fix: .approvalDeclined)
        expectEqual(declined.lines, [rdma, "Connection detected: rdma_en6 (en6) is active.", about,
            "The macOS prompt was cancelled, so this link cannot be used yet.",
            "Run `darkbloom cluster` again and approve the prompt to finish."], "bridged Mac, declined")
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
            "The address is lost at a restart or when the cable is replugged; run `darkbloom cluster` again then."] + ready,
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
            let result = ClusterLinkRepairResult(operation: .fix, outcome: outcome, device: "rdma_en6", interface: "en6")
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
}
