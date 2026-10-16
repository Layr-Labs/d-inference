import Foundation
@testable import InstalledContract

/// Drives the wizard's reducer with no terminal and no thread: events in,
/// effects out, a frame drawn where a person would have seen it.
struct WizardDrive {
    var state: ClusterSetupState
    var clock: UInt64 = 1_000_000_000

    init(size: ClusterConsoleSize = .init(columns: 80, rows: 24), options: ClusterSetupState.Options = .init()) {
        state = ClusterSetupState(size: size, options: options)
    }

    @discardableResult
    mutating func send(_ event: ClusterSetupEvent, after milliseconds: UInt64 = 10) -> [ClusterSetupEffect] {
        clock += milliseconds * 1_000_000
        return state.handle(event, at: "2026-10-10T15:30:00Z", uptime: clock)
    }

    @discardableResult
    mutating func key(_ key: ClusterConsoleKey) -> [ClusterSetupEffect] { send(.key(key)) }

    @discardableResult
    mutating func type(_ text: String) -> [ClusterSetupEffect] { text.flatMap { key(.character($0)) } }

    /// The frame a person sees now.
    @discardableResult
    mutating func draw() -> ClusterSetupFrame {
        let frame = ClusterSetupScreen.frame(state)
        state.drew(maximumScroll: frame.maximumScroll, bodyRows: frame.bodyRows, question: frame.question, uptime: clock)
        return frame
    }

    /// `y` to the open question, once it has been on screen long enough.
    @discardableResult
    mutating func yes() -> [ClusterSetupEffect] {
        draw()
        clock += 600_000_000
        return key(.character("y"))
    }

    var text: String { ClusterSetupScreen.frame(state).text }
}

extension ClusterConsoleCheck {
    static func wizardProgress() throws {
        typealias F = WizardFixtures
        func state(_ snapshot: ClusterSetupSnapshot, peer: ClusterSetupState.Peer = .unknown) -> ClusterSetupState {
            var value = ClusterSetupState(size: .init(columns: 80, rows: 24))
            value.snapshot = snapshot
            value.peer = peer
            return value
        }
        let reachedB = ClusterSetupState.Peer.reached(F.reportB(), seconds: 0.4, at: 1)

        // A Mac with RDMA turned off opens at step 1, blocked, whatever else holds.
        var off = F.linkA; off.state = "rdmaDisabled"; off.port = nil
        var fresh = state(F.snapshot(F.reportA(link: off)))
        expectEqual(fresh.status(of: .thisMac), .blocked, "RDMA off blocks step 1")
        expectEqual(fresh.firstUnfinished, .thisMac, "RDMA off resumes at step 1")
        expectEqual(fresh.status(of: .cable), .blocked, "RDMA off blocks the cable too")

        // The S00 guard refusing (memory left wired) blocks step 1 as well.
        fresh = state(F.snapshot(F.reportA(memoryGuard: .init(decision: .refused, wiredBytes: 92 * F.gib, baselineBytes: 25 * F.gib, detail: "92 GiB wired"))))
        expectEqual(fresh.status(of: .thisMac), .blocked, "memory left wired blocks step 1")

        // macOS older than 26.2: no RDMA.
        var old = F.mac(F.profileA); old.osMajor = 26; old.osMinor = 1
        expectEqual(state(F.snapshot(F.reportA(mac: old))).status(of: .thisMac), .blocked, "macOS 26.1 blocks step 1")

        // No cable: step 2 waits; a 40 Gb/s link is blocked, honestly.
        var none = F.linkA; none.state = "noActivePort"; none.port = nil
        expectEqual(state(F.snapshot(F.reportA(link: none))).status(of: .cable), .waiting, "no active port waits")
        expectEqual(state(F.snapshot(F.reportA(link: none))).firstUnfinished, .cable, "no cable resumes at step 2")
        var slow = F.linkA; slow.state = "portWithoutIPv4Address"; slow.port?.verdict = "portWithoutIPv4Address"
        var slowReport = F.reportA(link: slow)
        let receptacles = slowReport.link.thunderbolt?.receptacles ?? []
        slowReport.link.thunderbolt?.receptacles = receptacles.map {
            var r = $0; if r.id == 6 { r.speed = "40 Gb/s" }; return r
        }
        expectEqual(state(F.snapshot(slowReport)).status(of: .cable), .blocked, "a Thunderbolt 4 speed blocks the cable")
        expectEqual(state(F.snapshot(F.reportA(link: slow))).status(of: .cable), .todo, "a port without an address is the fix's to cure")
        // A ready link that is not isolated is done: the wizard goes on.
        expectEqual(state(F.snapshot(F.reportA())).status(of: .cable), .done, "a usable link is enough to go on")

        // No pair known: step 3 waits; the code of this Mac's own key still shows.
        let lone = state(F.snapshot(F.reportB(), pair: nil, record: .init()))
        expectEqual(lone.status(of: .pair), .waiting, "no pair waits")
        expectEqual(lone.firstUnfinished, .pair, "no pair resumes at step 3")
        expect(lone.pairingCode?.code == "482913", "the follower's own code is known before any pair")
        expectEqual(state(F.snapshot(F.reportA(), pair: nil, pairError: "bad description")).status(of: .pair), .blocked, "an unreadable description blocks")

        // A pair, not confirmed: to do; failed to reach: blocked; confirmed: done.
        expectEqual(state(F.snapshot(F.reportA())).status(of: .pair), .todo, "an unconfirmed pair is to do")
        expectEqual(state(F.snapshot(F.reportA()), peer: .failed("no answer")).status(of: .pair), .blocked, "an unreachable peer blocks")
        let confirmed = state(F.snapshot(F.reportA(), record: F.confirmed()), peer: reachedB)
        expectEqual(confirmed.status(of: .pair), .done, "a confirmed code is done")
        expectEqual(confirmed.firstUnfinished, .model, "a confirmed pair resumes at step 4")
        expectEqual(state(F.snapshot(F.reportA(), record: F.confirmed(code: "111111"))).status(of: .pair), .todo,
            "a confirmation for another key does not count")

        // Step 4, leader: saved, the other Mac has its matching setup: done; not yet: waiting.
        let savedA = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: true))
        let savedB = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: false, digest: String(repeating: "b", count: 64)))
        var leader = state(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()),
            peer: .reached(F.reportB(saved: savedB), seconds: 0.4, at: 1))
        expectEqual(leader.status(of: .model), .done, "the other Mac saved its matching setup")
        expectEqual(leader.firstUnfinished, .check, "a planned pair resumes at step 5")
        leader.peer = .reached(F.reportB(), seconds: 0.4, at: 1)
        expectEqual(leader.status(of: .model), .waiting, "the other Mac has not saved its setup")
        leader.peer = .unknown
        expectEqual(leader.status(of: .model), .waiting, "unknown peer and nothing sent waits")
        var sentRecord = F.confirmed()
        sentRecord.add(.init(clusterID: "wizard-pair", memberID: "mac-b", configurationSHA256: String(repeating: "b", count: 64), at: "t"))
        leader.snapshot?.record = sentRecord
        expectEqual(leader.status(of: .model), .done, "sent, and the other Mac not read yet, counts as done until it answers")

        // Step 4, follower: a setup in the inbox is to do; saved is done; a newer one in the inbox is to do again.
        let inboxSetup = F.setup(leader: false, digest: String(repeating: "e", count: 64))
        let follower = state(F.snapshot(F.reportB(inbox: inboxSetup), pair: F.inboxFollowerPair, record: F.confirmed()))
        expectEqual(follower.status(of: .model), .todo, "a setup waiting in the inbox is to do")
        expectEqual(follower.firstUnfinished, .model, "the follower resumes at its approval")
        let followerSaved = state(F.snapshot(F.reportB(saved: savedB), pair: F.savedFollowerPair, record: F.confirmed()))
        expectEqual(followerSaved.status(of: .model), .done, "a saved follower setup is done")
        expectEqual(followerSaved.status(of: .check), .done, "the follower has no check of its own")
        expectEqual(followerSaved.firstUnfinished, .serve, "a set-up follower opens on the serve step")
        let newer = state(F.snapshot(F.reportB(saved: savedB, inbox: inboxSetup), pair: F.savedFollowerPair, record: F.confirmed()))
        expectEqual(newer.status(of: .model), .todo, "a newer setup in the inbox is to do again")

        // Step 5: a recorded pass for this setup is done; a pass for another setup is not.
        var passed = sentRecord
        passed.add(.init(configurationSHA256: F.setup(leader: true).configurationSHA256, at: "t", readySeconds: 11, firstTokenMilliseconds: 720, tokensPerSecond: 53))
        let ran = state(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), peer: .reached(F.reportB(saved: savedB), seconds: 0.4, at: 1))
        expectEqual(ran.status(of: .check), .done, "a recorded pass is done")
        expectEqual(ran.firstUnfinished, .serve, "everything done resumes at step 6")
        var other = passed; other.checks = [.init(configurationSHA256: String(repeating: "f", count: 64), at: "t", readySeconds: 1, firstTokenMilliseconds: nil, tokensPerSecond: nil)]
        expectEqual(state(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: other)).status(of: .check), .todo,
            "a pass on another setup does not count")
    }

    static func wizardReducer() throws {
        typealias F = WizardFixtures
        let savedA = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: true))
        let savedB = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: false, digest: String(repeating: "b", count: 64)))

        // The first refresh, then the resume and the reading of the other Mac.
        var d = WizardDrive()
        expectEqual(d.state.begin(), [.refresh], "the wizard starts by reading this Mac")
        var effects = d.send(.snapshot(F.snapshot(F.reportA())))
        expectEqual(d.state.step, .pair, "a usable Mac and cable open at step 3")
        expect(effects.contains(.reachPeer), "the other Mac is asked for its report once a pair is known: \(effects)")
        expect(effects.filter { $0 == .reachPeer }.count == 1, "the other Mac is asked once, not twice: \(effects)")
        expect(d.text.contains("Reaching it over the pinned route"), "the step says it is reaching: \(d.text)")
        // Nothing is confirmed before the pinned connection succeeded.
        d.key(.enter)
        expect(d.state.asking == nil, "enter does not ask for a code before the other Mac answered")
        d.send(.peer(.reached(F.reportB(), seconds: 0.42)))
        expect(d.text.contains("482 913"), "the code shows once the other Mac answered: \(d.text)")
        expect(d.text.contains("Apple M5 Max"), "the other Mac's chip shows: \(d.text)")
        d.key(.enter)
        expectEqual(d.state.asking, .confirmCode(code: "482913"), "enter asks whether both screens show the code")
        // A y typed before the question could be read is not an answer.
        expectEqual(d.key(.character("y")), [], "y before the question was drawn does nothing")
        d.draw()
        expectEqual(d.key(.character("y")), [], "y inside the dwell does nothing")
        d.key(.character("n"))
        expect(d.state.notice?.contains("Codes differ") == true, "n says to stop: \(d.state.notice ?? "")")
        expect(d.state.asking == nil, "n withdraws the question")
        d.key(.enter)
        effects = d.yes()
        expectEqual(effects, [.recordConfirmation(code: "482913", clusterID: "wizard-pair")], "y records the confirmation")
        expectEqual(d.state.inFlight, .recordConfirmation, "the record is in flight")
        effects = d.send(.actionFinished(.recordConfirmation, .init(succeeded: true, lines: ["Recorded."])))
        expect(effects.contains(.refresh), "the record is read back")
        d.send(.snapshot(F.snapshot(F.reportA(), record: F.confirmed())))
        expectEqual(d.state.status(of: .pair), .done, "the pair step is done")

        // Step 4: the plan is asked for once the other Mac answered, never sooner.
        effects = d.key(.right)
        expectEqual(d.state.step, .model, "right moves to step 4")
        expect(effects.contains(.planModels), "entering step 4 plans: \(effects)")
        d.send(.plans(.ready(F.options)))
        expect(d.text.contains("Qwen3.5-9B"), "the 9B is listed: \(d.text)")
        expect(d.state.selectedModel == 0, "the first model that can be chosen is selected")
        d.key(.down)
        d.key(.down)
        expect(d.state.selectedModel == 2, "down moves the choice")
        for _ in 0..<F.models.count { d.key(.down) }
        expect(d.state.selectedModel == F.models.count, "down stops at the last folder, the constructed unread one")
        expect(d.text.contains(ClusterSetupPlanning.notClusterModel), "a blocked model says why: \(d.text)")
        d.key(.enter)
        expect(d.state.asking == nil && d.state.notice?.contains("cannot be chosen") == true, "a blocked model cannot be adopted: \(d.state.notice ?? "")")
        for _ in 0..<F.models.count { d.key(.up) }
        d.key(.enter)
        guard case .adoptPlan(let folder, let key)? = d.state.asking else {
            failures.append("enter on a model that fits asks to adopt it, got \(String(describing: d.state.asking))")
            return
        }
        expectEqual(folder, F.models[0].folder, "the question is about the model on screen")
        effects = d.yes()
        expectEqual(effects, [.adoptPlan(folder: folder, planKey: key)], "y adopts the plan that was on screen")
        effects = d.send(.actionFinished(.adoptPlan, .init(succeeded: true, lines: ["Saved", "Sent"])))
        expect(effects.contains(.refresh) && effects.contains(.reachPeer), "adopting reads both Macs again: \(effects)")

        // Adopting a plan before the code was confirmed is refused.
        var unconfirmed = WizardDrive()
        _ = unconfirmed.state.begin()
        unconfirmed.send(.snapshot(F.snapshot(F.reportA())))
        unconfirmed.send(.peer(.reached(F.reportB(), seconds: 0.4)))
        unconfirmed.key(.right)
        unconfirmed.send(.plans(.ready(F.options)))
        unconfirmed.key(.enter)
        expect(unconfirmed.state.asking == nil && unconfirmed.state.notice?.contains("pairing code") == true,
            "no plan is adopted before the pairing is confirmed: \(unconfirmed.state.notice ?? "")")

        // A peer that cannot be reached: blocked, with the reason and a retry.
        var unreachable = WizardDrive()
        _ = unreachable.state.begin()
        unreachable.send(.snapshot(F.snapshot(F.reportA())))
        unreachable.send(.peer(.failed("the other Mac's host key is not the one the setup pins")))
        expect(unreachable.text.contains("Could not reach mac-b over the pinned route"), "the reason shows: \(unreachable.text)")
        expectEqual(unreachable.state.status(of: .pair), .blocked, "the rail marks the step blocked")
        expectEqual(unreachable.key(.character("p")), [.reachPeer], "p tries again")

        // Over a saved setup, step 4 shows it and plans nothing until r; r reads the other Mac again
        // and plans from its answer (found on the pair 2026-10-10 13:20: r used to re-read only).
        var replan = WizardDrive()
        _ = replan.state.begin()
        replan.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        replan.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        effects = replan.key(.character("4"))
        expect(!effects.contains(.planModels) && replan.text.contains("Saved setup"), "a saved setup is shown, not planned over: \(effects)")
        expect(replan.text.contains("press r"), "the step says how to plan again: \(replan.text)")
        effects = replan.key(.character("r"))
        expect(effects.contains(.reachPeer) && !effects.contains(.planModels), "r reads the other Mac first: \(effects)")
        expect(replan.text.contains("Planning each model from both Macs' memory now"), "the step says it is planning: \(replan.text)")
        effects = replan.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        expect(effects.contains(.planModels), "the plans follow the other Mac's answer: \(effects)")
        replan.send(.plans(.ready(F.options)))
        expect(replan.text.contains("Saved setup") && replan.text.contains("Qwen3.5-9B") && replan.text.contains("fits now"),
            "the fresh plans show under the saved setup: \(replan.text)")
        expect(!replan.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4))).contains(.planModels), "one r plans once")
        replan.key(.character("r"))
        replan.send(.peer(.failed("the other Mac did not answer within 30 s")))
        expect(!replan.state.replanRequested, "a failed answer ends the request; r asks again")

        try wizardLinkFix()
        try wizardFollower(savedB: savedB)
        try wizardCheck(savedA: savedA, savedB: savedB)
        try wizardServe(savedA: savedA, savedB: savedB)
        try wizardLeaving(savedA: savedA)
    }

    static func wizardLinkFix() throws {
        typealias F = WizardFixtures
        // f shows the commands first (a dry run), then asks; y applies.
        var d = WizardDrive()
        _ = d.state.begin()
        d.send(.snapshot(F.snapshot(F.reportA(), pair: nil, record: .init())))
        d.key(.character("2"))
        expectEqual(d.state.step, .cable, "2 moves to step 2")
        expect(d.text.contains("Thunderbolt 5 at 80 Gb/s"), "the cable's speed shows: \(d.text)")
        expect(d.text.contains("Fix link (one approval)"), "the fix is offered: \(d.text)")
        expectEqual(d.key(.character("f")), [.linkFix(dryRun: true)], "f runs the dry run first, never the change")
        d.send(.linkFix(F.wizardPreview))
        expectEqual(d.state.asking, .applyLinkFix, "the preview asks whether to apply")
        expect(d.text.contains("networksetup -createnetworkservice"), "the exact commands show: \(d.text)")
        expectEqual(d.yes(), [.linkFix(dryRun: false)], "y applies, behind macOS's prompt")
        expect(d.text.contains("macOS prompt"), "the screen says the prompt is macOS's: \(d.text)")
        expectEqual(d.send(.linkFix(F.wizardApplied)), [.refresh], "the result is read back")

        // A cancelled preview changes nothing.
        var cancel = WizardDrive()
        _ = cancel.state.begin()
        cancel.send(.snapshot(F.snapshot(F.reportA(), pair: nil, record: .init())))
        cancel.key(.character("2"))
        cancel.key(.character("f"))
        cancel.send(.linkFix(F.wizardPreview))
        cancel.draw()
        expectEqual(cancel.key(.escape), [], "any other key cancels the fix")
        expect(cancel.state.notice?.contains("Nothing was changed") == true, "cancelling says nothing changed")

        // A wizard opened with --dry-run never asks to apply, and never applies.
        var dry = WizardDrive(options: .init(dryRun: true))
        _ = dry.state.begin()
        dry.send(.snapshot(F.snapshot(F.reportA(), pair: nil, record: .init())))
        dry.key(.character("2"))
        dry.key(.character("f"))
        dry.send(.linkFix(F.wizardPreview))
        expect(dry.state.asking == nil, "a dry run asks nothing")
        expect(dry.text.contains("Dry run"), "the screen says it is a dry run: \(dry.text)")
        for _ in 0..<20 { expect(!dry.key(.character("y")).contains(.linkFix(dryRun: false)), "y never applies in a dry run") }

        // Mac B: the fix cannot run yet; the reason is the owner's step, and setup goes on.
        var b = WizardDrive()
        _ = b.state.begin()
        b.send(.snapshot(F.snapshot(F.reportB(), pair: nil, record: .init())))
        b.key(.character("2"))
        expect(b.text.contains("Internet Sharing"), "Mac B's blocker names Internet Sharing: \(b.text)")
        expect(b.text.contains("setup can go on"), "a usable link goes on: \(b.text)")

        // No cable: the link is read again on every tick until it changes.
        var none = F.linkA; none.state = "noActivePort"; none.port = nil
        var wait = WizardDrive()
        _ = wait.state.begin()
        wait.send(.snapshot(F.snapshot(F.reportA(link: none), pair: nil, record: .init())))
        expectEqual(wait.state.step, .cable, "no cable opens at step 2")
        expect(wait.send(.tick).contains(.refresh), "a tick reads the link again while no cable is in")
        expect(wait.text.contains("Connect the two Macs directly"), "the step says what to do: \(wait.text)")
        // A link that is down for another reason is not polled: r reads it again.
        var off2 = F.linkA; off2.state = "rdmaDisabled"; off2.port = nil
        var idle = WizardDrive()
        _ = idle.state.begin()
        idle.send(.snapshot(F.snapshot(F.reportA(link: off2), pair: nil, record: .init())))
        idle.key(.character("2"))
        expect(!idle.send(.tick).contains(.refresh), "only the wait for a cable polls")

        // RDMA off: the exact Recovery steps, and the action to read again.
        var off = F.linkA; off.state = "rdmaDisabled"; off.port = nil
        var rdma = WizardDrive()
        _ = rdma.state.begin()
        rdma.send(.snapshot(F.snapshot(F.reportA(link: off), pair: nil, record: .init())))
        expectEqual(rdma.state.step, .thisMac, "RDMA off opens at step 1")
        let screen = ClusterSetupScreen.frame(withSize(rdma.state, columns: 100, rows: 60)).text
        expect(screen.contains("rdma_ctl enable"), "the Recovery command shows: \(screen)")
        expect(screen.contains("Loading startup options"), "the Recovery steps show")
        expectEqual(rdma.key(.enter), [.refresh], "enter reads again after the change")
    }

    static func wizardFollower(savedB: ClusterSetupSaved) throws {
        typealias F = WizardFixtures
        // The follower: its own code, then the leader's setup in its inbox, approved here.
        let inboxSetup = F.setup(leader: false, digest: String(repeating: "e", count: 64))
        var d = WizardDrive()
        _ = d.state.begin()
        var effects = d.send(.snapshot(F.snapshot(F.reportB(), pair: nil, record: .init())))
        expectEqual(d.state.step, .pair, "a follower with no setup opens at step 3")
        expect(!effects.contains(.reachPeer), "a follower never reaches out")
        expect(!d.text.contains("482 913") && !d.text.contains("SSH host key"), "no SSH host-key code in the user path: \(d.text)")
        expectEqual(d.key(.character("y")), [], "y alone confirms nothing without a pairing")
        expectEqual(d.key(.enter), [.pairOverLink(connect: nil)], "enter pairs over the link (finds the other Mac)")
        d.send(.linkPairing(.finished(succeeded: true, lines: ["Paired."])))
        effects = d.send(.snapshot(F.snapshot(F.reportB(inbox: inboxSetup), pair: F.inboxFollowerPair, record: F.confirmed())))
        d.key(.right)
        expectEqual(d.state.step, .model, "right to step 4")
        expect(d.text.contains("Setup sent by mac-a"), "the inbox setup shows: \(d.text)")
        expect(d.text.contains("this Mac follows"), "its role shows")
        d.key(.character("a"))
        expectEqual(d.state.asking, .approveInbox(expectedSHA256: inboxSetup.configurationSHA256), "a asks to approve that setup")
        // The inbox changing while the question is open withdraws it.
        let replaced = F.setup(leader: false, digest: String(repeating: "9", count: 64))
        d.send(.snapshot(F.snapshot(F.reportB(inbox: replaced), pair: F.inboxFollowerPair, record: F.confirmed())))
        expect(d.state.asking == nil && d.state.notice?.contains("changed") == true, "a changed inbox withdraws the question")
        d.key(.character("a"))
        expectEqual(d.yes(), [.approveInbox(expectedSHA256: replaced.configurationSHA256)], "y approves exactly the setup shown")
        d.send(.actionFinished(.approveInbox, .init(succeeded: true, lines: ["Saved."])))
        d.send(.snapshot(F.snapshot(F.reportB(saved: savedB), pair: F.savedFollowerPair, record: F.confirmed())))
        d.key(.character("6"))
        expect(d.text.contains("This Mac follows"), "the follower's serve step says the leader starts it: \(d.text)")
        expect(d.key(.character("s")).isEmpty && d.state.notice?.contains("follows") == true, "s does not start a follower")
        d.key(.character("5"))
        expect(d.key(.character("c")).isEmpty, "c does not run a check on a follower")
    }

    static func wizardCheck(savedA: ClusterSetupSaved, savedB: ClusterSetupSaved) throws {
        typealias F = WizardFixtures
        func ready() -> WizardDrive {
            var d = WizardDrive()
            _ = d.state.begin()
            d.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
            d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
            return d
        }
        var d = ready()
        expectEqual(d.state.step, .check, "a planned pair opens at the check")
        d.key(.character("c"))
        expectEqual(d.state.asking, .runCheck, "c asks before loading the model")
        var effects = d.yes()
        expect(effects.contains(.refresh) && effects.contains(.reachPeer), "the check reads both cables first: \(effects)")
        effects = d.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        expect(!effects.contains(.launchSession), "the check waits for the other Mac too")
        effects = d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        expectEqual(effects, [.launchSession], "both cables ready: the session starts")
        d.send(.session(.launched(processIdentifier: 4242)))
        guard case .running(.ranks, _) = d.state.check else { failures.append("the check waits for the ranks: \(d.state.check)"); return }
        d.send(.sessionObserved(.init(observed: true, ready: false, members: [
            .init(rank: 0, memberID: "mac-a", ready: false, cleanupObserved: false, releaseAcknowledged: false, termination: nil),
            .init(rank: 1, memberID: "mac-b", ready: false, cleanupObserved: false, releaseAcknowledged: false, termination: nil)])))
        expect(d.text.contains("0 of 2 ranks ready"), "progress counts ranks: \(d.text)")
        d.send(.sessionObserved(.init(observed: true, ready: false, members: [
            .init(rank: 0, memberID: "mac-a", ready: true, cleanupObserved: false, releaseAcknowledged: false, termination: nil),
            .init(rank: 1, memberID: "mac-b", ready: false, cleanupObserved: false, releaseAcknowledged: false, termination: nil)])))
        expect(d.text.contains("1 of 2 ranks ready"), "one rank ready: \(d.text)")
        effects = d.send(.sessionObserved(F.scriptedLive), after: 11_000)
        expectEqual(effects, [.sendPrompt(text: ClusterSetupState.checkPrompt, maxTokens: ClusterSetupState.checkTokens)], "both ready: a short generation")
        d.send(.prompt(.text("RDMA")))
        effects = d.send(.prompt(.finished(.init(completionTokens: 8, firstTokenMilliseconds: 720, tokensPerSecond: 53.1, finishReason: "length"))))
        expectEqual(effects, [.interruptSession], "tokens came back: the session is stopped")
        effects = d.send(.session(.ended(description: "exited with status 0", clean: true)))
        expect(effects.contains(.refresh) && effects.contains(.reachPeer), "the stop is followed by fresh readings of both Macs: \(effects)")
        d.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        effects = d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        guard case .recordCheck(let pass)? = effects.first, case .passed = d.state.check else {
            failures.append("a clean stop with memory released passes and is recorded: \(effects) \(d.state.check)"); return
        }
        expectEqual(pass.configurationSHA256, F.setup(leader: true).configurationSHA256, "the pass names the setup it ran on")
        expectEqual(pass.firstTokenMilliseconds, 720, "the pass keeps the first-token time")
        expect(d.text.contains("Check passed"), "the screen says it passed: \(d.text)")

        // The other Mac's cable not ready: the check stops before loading anything.
        var cable = ready()
        cable.key(.character("c")); cable.yes()
        cable.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        var notReady = F.linkB; notReady.state = "portBridgedWithoutAddress"
        effects = cable.send(.peer(.reached(F.reportB(link: notReady, saved: savedB), seconds: 0.4)))
        expect(!effects.contains(.launchSession), "nothing loads over a cable that is not ready")
        expect(cable.text.contains("other Mac's link is not ready"), "the failure says which Mac: \(cable.text)")
        expectEqual(cable.key(.character("c")), [], "c asks again rather than running at once")
        expectEqual(cable.state.asking, .runCheck, "every failure has a next action: c runs it again")

        // Ranks never ready: stopped at the timeout, with the reason.
        var slow = ready()
        slow.key(.character("c")); slow.yes()
        slow.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        slow.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        slow.send(.session(.launched(processIdentifier: 7)))
        effects = slow.send(.tick, after: UInt64(slow.state.options.readyTimeoutSeconds) * 1000 + 1000)
        expect(effects.contains(.interruptSession), "the timeout stops the session: \(effects)")
        guard case .failed(.ranks, let reason) = slow.state.check else { failures.append("timeout fails at the ranks: \(slow.state.check)"); return }
        expect(reason.contains("not ready"), "the reason says so: \(reason)")

        // The session dying while loading: the failure keeps its last output.
        var dies = ready()
        dies.key(.character("c")); dies.yes()
        dies.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        dies.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        dies.send(.session(.launched(processIdentifier: 8)))
        dies.send(.session(.output("Error: the host memory gate refused rank 1")))
        dies.send(.session(.ended(description: "exited with status 1", clean: false)))
        guard case .failed(.ranks, let died) = dies.state.check else { failures.append("a dead session fails the check: \(dies.state.check)"); return }
        expect(died.contains("memory gate refused"), "the failure carries the session's last output: \(died)")

        // After the stop: a check stopped cleanly and read once on both Macs.
        func stopped() -> WizardDrive {
            var d = ready()
            d.key(.character("c")); d.yes()
            d.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
            d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
            d.send(.session(.launched(processIdentifier: 9)))
            d.send(.sessionObserved(F.scriptedLive))
            d.send(.prompt(.finished(.init(completionTokens: 8, firstTokenMilliseconds: 700, tokensPerSecond: 50, finishReason: "length"))))
            d.send(.session(.ended(description: "exited with status 0", clean: true)))
            d.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
            return d
        }
        let leaked = F.reportB(saved: savedB, journal: .ownershipUnproven,
            memoryGuard: .init(decision: .refused, wiredBytes: 90 * F.gib, baselineBytes: 16 * F.gib, detail: "90 GiB wired"))

        // The other Mac's owner still clearing its journal a moment after the leader's exit: read again,
        // and the check passes once it is clear (seen on the pair 2026-10-10 13:57: failed on one reading).
        var settles = stopped()
        settles.send(.peer(.reached(leaked, seconds: 0.4)))
        guard case .running(.cleanup, _) = settles.state.check else { failures.append("a journal still clearing is read again, not failed at once: \(settles.state.check)"); return }
        expect(!settles.send(.tick, after: 500).contains(.reachPeer), "not read again at once")
        effects = settles.send(.tick, after: 2_000)
        expect(effects.contains(.refresh) && effects.contains(.reachPeer), "both Macs are read again after a moment: \(effects)")
        settles.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        effects = settles.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        expect(effects.first.map { if case .recordCheck = $0 { return true }; return false } == true, "a journal cleared on the next reading passes: \(effects)")

        // Memory and journal still left after the settle time fail the clean-up stage, naming both.
        var leak = stopped()
        leak.send(.peer(.reached(leaked, seconds: 0.4)))
        leak.send(.tick, after: 2_100)
        leak.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())), after: 19_000)
        leak.send(.peer(.reached(leaked, seconds: 0.4)))
        guard case .failed(.cleanup, let left) = leak.state.check else { failures.append("memory left fails clean-up: \(leak.state.check)"); return }
        expect(left.contains("journal") && left.contains("wired"), "both findings are named: \(left)")
    }

    static func wizardServe(savedA: ClusterSetupSaved, savedB: ClusterSetupSaved) throws {
        typealias F = WizardFixtures
        var passed = F.confirmed()
        passed.add(.init(configurationSHA256: F.setup(leader: true).configurationSHA256, at: "t", readySeconds: 11, firstTokenMilliseconds: 720, tokensPerSecond: 53))
        var d = WizardDrive()
        _ = d.state.begin()
        d.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed)))
        d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        expectEqual(d.state.step, .serve, "a checked pair opens at step 6")
        expect(d.text.contains("Left wired"), "the memory an earlier run left is reported before a start: \(d.text)")
        d.key(.enter)
        expectEqual(d.state.asking, .startSession, "enter asks to start serving")
        expectEqual(d.yes(), [.launchSession], "y starts `start --local --distributed`")
        d.send(.session(.launched(processIdentifier: 4242)))
        expect(d.send(.tick).contains(.pollSession), "a running session is polled")
        expect(!d.send(.tick).contains(.pollSession), "one poll at a time")
        // While it starts the leader has no status yet: said as loading, not as the reader's error, and
        // step 6 is not done (seen on the pair 2026-10-10 13:36: "Configuration input does not exist").
        var starting = F.scriptedLive
        starting.observed = false; starting.ready = false; starting.detail = "Configuration input does not exist"
        d.send(.sessionObserved(starting))
        expect(d.text.contains("both Macs are loading the model") && !d.text.contains("Configuration input"),
            "a starting session says it is loading: \(d.text)")
        expectEqual(d.state.status(of: .serve), .todo, "step 6 is not done while the ranks load")
        d.send(.tick, after: 50_000)
        d.send(.sessionObserved(starting))
        expect(d.text.contains("No status from the leader after") && d.text.contains("Configuration input does not exist"),
            "after the grace the reason shows: \(d.text)")
        d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        d.send(.sessionObserved(F.scriptedLive))
        expectEqual(d.state.status(of: .serve), .done, "step 6 is done once both ranks are ready")
        let live = ClusterSetupScreen.frame(withSize(d.state, columns: 100, rows: 40)).text
        expect(live.contains("Serving Qwen3.5-9B"), "the live view says it serves: \(live)")
        expect(live.contains("Rank 1") && live.contains("mac-b"), "both ranks show")
        expect(live.contains("12 GiB wired of 256 GiB"), "this Mac's memory shows: \(live)")
        expect(live.contains("Link ready"), "the link's health shows")
        // The other Mac is read again while serving, every few seconds.
        expect(d.send(.tick, after: 11_000).contains(.reachPeer), "the other Mac is read again while serving")
        // The test prompt: t opens it, typed text goes in (q included), enter sends.
        d.key(.character("t"))
        d.type("Why is the sky blue? quick")
        guard case .editing(let typed) = d.state.prompt else { failures.append("t opens the prompt: \(d.state.prompt)"); return }
        expectEqual(typed, "Why is the sky blue? quick", "q is text inside the prompt, not quit")
        d.key(.backspace)
        d.key(.unknown)
        expect(d.state.notice?.contains("Pasted") == true, "a paste is refused inside the prompt")
        expectEqual(d.key(.enter), [.sendPrompt(text: "Why is the sky blue? quic", maxTokens: ClusterSetupState.promptTokens)], "enter sends it")
        d.send(.prompt(.text("Because")))
        d.send(.prompt(.text(" of scattering.")))
        d.send(.prompt(.finished(.init(completionTokens: 12, firstTokenMilliseconds: 610, tokensPerSecond: 52.4, finishReason: "stop"))))
        let answered = ClusterSetupScreen.frame(withSize(d.state, columns: 100, rows: 40)).text
        expect(answered.contains("Because of scattering."), "the reply shows: \(answered)")
        expect(answered.contains("52.4 tok/s"), "its speed shows: \(answered)")
        // x stops; the clean-up is read from both Macs and said in plain words.
        expectEqual(d.key(.character("x")), [.interruptSession], "x stops with an interrupt")
        var effects = d.send(.session(.ended(description: "exited with status 0", clean: true)))
        expect(effects.contains(.refresh) && effects.contains(.reachPeer), "the stop is followed by fresh readings: \(effects)")
        d.send(.snapshot(F.snapshot(F.reportA(saved: savedA, memoryGuard: F.guardClear(9.9, baseline: 25.6)), pair: F.savedLeaderPair, record: passed)))
        effects = d.send(.peer(.reached(F.reportB(saved: savedB), seconds: 0.4)))
        let after = ClusterSetupScreen.frame(withSize(d.state, columns: 100, rows: 40)).text
        expect(after.contains("Clean up"), "the clean-up shows: \(after)")
        expect(after.contains("device journal empty"), "the journal is said in plain words: \(after)")
        expect(after.contains("under the 26 GiB idle"), "wired memory against its baseline: \(after)")

        // A start refused: never a dead end.
        var refused = WizardDrive()
        _ = refused.state.begin()
        refused.send(.snapshot(F.snapshot(F.reportA(saved: savedA, memoryGuard: .init(decision: .refused, wiredBytes: 92 * F.gib, baselineBytes: 25 * F.gib, detail: "92 GiB")), pair: F.savedLeaderPair, record: passed)))
        refused.key(.character("6"))
        expect(refused.key(.character("s")).isEmpty && refused.state.notice?.contains("Restart this Mac") == true, "left-wired memory refuses a start with the next step")
        var failedLaunch = WizardDrive()
        _ = failedLaunch.state.begin()
        failedLaunch.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed)))
        failedLaunch.key(.character("6")); failedLaunch.key(.character("s")); failedLaunch.yes()
        failedLaunch.send(.session(.launchFailed("The session process could not be started: no such file")))
        expect(failedLaunch.state.notice?.contains("could not be started") == true, "a launch failure is said")
        failedLaunch.key(.escape)
        failedLaunch.key(.character("s"))
        expectEqual(failedLaunch.state.asking, .startSession, "and s asks again")
    }

    static func wizardLeaving(savedA: ClusterSetupSaved) throws {
        typealias F = WizardFixtures
        // q leaves at once when nothing runs.
        var idle = WizardDrive()
        _ = idle.state.begin()
        idle.send(.snapshot(F.snapshot(F.reportA())))
        idle.key(.character("q"))
        expectEqual(idle.state.exit?.code, 0, "q closes an idle wizard")
        // With serving started here: q warns, q again stops it and waits; the screen closes once it ended.
        var serving = WizardDrive()
        _ = serving.state.begin()
        serving.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        serving.key(.character("6")); serving.key(.character("s")); serving.yes()
        serving.send(.session(.launched(processIdentifier: 4242)))
        expectEqual(serving.key(.character("q")), [], "the first q only warns")
        expect(serving.state.notice?.contains("Press q again") == true, "and says what the second does")
        expectEqual(serving.key(.character("q")), [.interruptSession], "the second q stops serving")
        expect(serving.state.exit == nil, "the screen waits for the stop")
        serving.send(.session(.ended(description: "exited with status 0", clean: true)))
        expectEqual(serving.state.exit?.code, 0, "and closes once it ended")
        // A termination signal closes at once and names what is left stopping.
        var signalled = WizardDrive()
        _ = signalled.state.begin()
        signalled.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        signalled.key(.character("6")); signalled.key(.character("s")); signalled.yes()
        signalled.send(.session(.launched(processIdentifier: 4243)))
        expectEqual(signalled.send(.terminationSignal(SIGTERM)), [.interruptSession], "a signal stops serving on the way out")
        expectEqual(signalled.state.exit?.code, 128 + SIGTERM, "with the signal's status")
        expect(signalled.state.exit?.farewell.first?.contains("4243") == true, "and names the process left stopping")
        // A question the window can no longer show is withdrawn.
        var narrow = WizardDrive()
        _ = narrow.state.begin()
        narrow.send(.snapshot(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed())))
        narrow.key(.character("6")); narrow.key(.character("s"))
        expectEqual(narrow.state.asking, .startSession, "s asks")
        narrow.send(.resized(.init(columns: 30, rows: 10)))
        expect(narrow.state.asking == nil, "a window too small withdraws the question")
        expectEqual(narrow.key(.character("y")), [], "and y then does nothing")
    }

    static func withSize(_ state: ClusterSetupState, columns: Int, rows: Int) -> ClusterSetupState {
        var copy = state
        copy.size = .init(columns: columns, rows: rows)
        return copy
    }
}

extension WizardFixtures {
    static let wizardPreview = ClusterSetupLinkFixResult(dryRun: true, succeeded: true, outcome: "dryRun", lines: ["Link fix: dryRun"],
        commands: ["/usr/sbin/networksetup -createnetworkservice 'Darkbloom Cluster Link (en7)' 'Thunderbolt 6'",
                   "/usr/sbin/networksetup -setmanual 'Darkbloom Cluster Link (en7)' 10.219.0.0 255.255.0.0"])
    static let wizardApplied = ClusterSetupLinkFixResult(dryRun: false, succeeded: true, outcome: "fixed", lines: ["Link fix: fixed"], commands: [])
    static let scriptedLive = ClusterSetupLive(observed: true, ready: true, hostPhase: "serving", sessionPhase: "ready", port: 18452,
        members: [.init(rank: 0, memberID: "mac-a", ready: true, cleanupObserved: false, releaseAcknowledged: false, termination: nil),
                  .init(rank: 1, memberID: "mac-b", ready: true, cleanupObserved: false, releaseAcknowledged: false, termination: nil)],
        requestsServed: 3, keepWarmExchanges: 12, localWiredBytes: 12 * gib, localPhysicalBytes: 256 * gib, linkState: "ready")
}
