import Foundation
@testable import InstalledContract

/// The reducer alone: no terminal, no thread, no operation. Each check feeds
/// events and reads the state and the effects.
extension ClusterConsoleCheck {
    private typealias State = ClusterConsoleState
    private static let time = "06:00:00"

    private static func state(_ snapshot: ClusterConsoleSnapshot? = ConsoleFixtures.snapshot(),
                              options: State.Options = .init(onboarding: false)) -> State {
        var state = State(size: .init(columns: 100, rows: 30), options: options)
        expectEqual(state.begin(), [.refresh], "opening the screen reads the state once")
        if let snapshot { _ = state.handle(.snapshot(snapshot), at: time) }
        return state
    }

    @discardableResult
    private static func press(_ state: inout State, _ text: String) -> [ClusterConsoleEffect] {
        text.flatMap { state.handle(.key(.character($0)), at: time) }
    }

    /// What a key may change, as one comparable value.
    private static func fingerprint(_ state: State) -> String {
        "\(state.refreshing)|\(String(describing: state.inFlight))|\(String(describing: state.confirming))|\(state.session)|\(state.activity.count)|\(state.scroll)|\(state.showsHelp)|\(String(describing: state.exit))|\(state.sessionOutput.count)"
    }

    static func reducerRefresh() throws {
        var opening = State(size: .init(columns: 100, rows: 30))
        expectEqual(opening.begin(), [.refresh], "first refresh")
        expect(opening.refreshing && opening.snapshot == nil, "nothing is shown as observed before the first refresh")
        expectEqual(press(&opening, "f"), [], "no action starts before the first reading")
        expect(opening.notice?.contains("still being read") == true, "an early action key says why nothing happened")
        expectEqual(press(&opening, "r"), [], "a refresh already running is not started again")
        _ = opening.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        expect(opening.refreshing, "the refresh asked for meanwhile runs after the first one")

        var s = state()
        expect(!s.refreshing && s.snapshot != nil, "a snapshot ends the refresh")
        expectEqual(press(&s, "r"), [.refresh], "r reads everything again")
        expectEqual(press(&s, "rrr"), [], "refresh keys during a refresh start nothing more")
        expectEqual(s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time), [.refresh], "exactly one queued refresh follows")
        expectEqual(s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time), [], "and none after it")

        // A ready link and no saved setup: nothing is waited for, so a tick runs nothing.
        expectEqual(s.handle(.tick, at: time), [], "nothing is polled when nothing is waited for")

        // Waiting for a cable: the link is read again, one reading at a time.
        var waiting = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink))
        expectEqual(waiting.handle(.tick, at: time), [.pollLink], "the link is read again while it is not ready")
        expectEqual(waiting.handle(.tick, at: time), [], "a second reading does not start while one is out")
        expectEqual(waiting.handle(.linkObserved(ConsoleFixtures.unpluggedLink), at: time), [], "an unchanged link changes nothing")
        expect(waiting.snapshot?.link == ConsoleFixtures.unpluggedLink, "the shown link is still the observed one")
        expectEqual(waiting.handle(.tick, at: time), [.pollLink], "and it is read again at the next interval")
        expectEqual(waiting.handle(.linkObserved(ConsoleFixtures.bridgedLink), at: time), [.refresh], "a changed link is read in full")

        // A leader with a saved setup: the session is watched too.
        var leader = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
        expectEqual(leader.handle(.tick, at: time), [.pollSession], "a leader's session is observed at each interval")
        expectEqual(leader.handle(.tick, at: time), [], "one observation at a time")
        let observed = ConsoleFixtures.diagnostics(link: ConsoleFixtures.readyLink, journal: .ownershipUnproven)
        _ = leader.handle(.sessionObserved(.init(status: observed)), at: time)
        expect(leader.status?.deviceJournal == .ownershipUnproven, "the newer observation is the one shown")
        _ = leader.handle(.snapshot(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())), at: time)
        expect(leader.status?.deviceJournal == .absent, "a full refresh replaces the earlier observation")
        var follower = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(role: .follower)))
        expectEqual(follower.handle(.tick, at: time), [], "a follower has no local session to observe")

        // Resizing and scrolling.
        _ = s.handle(.resized(.init(columns: 3, rows: 2)), at: time)
        expectEqual(s.size, .init(columns: 3, rows: 2), "the new size is kept")
        s.maximumScroll = 5; s.bodyRows = 4
        for key in [ClusterConsoleKey.down, .down, .pageDown, .pageDown, .down] { _ = s.handle(.key(key), at: time) }
        expectEqual(s.scroll, 5, "scrolling stops at the end")
        for key in [ClusterConsoleKey.up, .pageUp, .pageUp, .up] { _ = s.handle(.key(key), at: time) }
        expectEqual(s.scroll, 0, "and at the start")
        _ = s.handle(.key(.end), at: time); expectEqual(s.scroll, 5, "end")
        _ = s.handle(.key(.home), at: time); expectEqual(s.scroll, 0, "home")
        press(&s, "jjG"); expectEqual(s.scroll, 5, "j and G scroll")
        press(&s, "kg"); expectEqual(s.scroll, 0, "k and g scroll")
        press(&s, "?"); expect(s.showsHelp, "? opens help")
        _ = s.handle(.key(.escape), at: time); expect(!s.showsHelp, "Escape closes help")

        // Keys with no meaning change nothing.
        let before = fingerprint(s)
        for key in [ClusterConsoleKey.unknown, .tab, .enter, .backspace, .left, .right, .character("z"), .character("1"),
                    .character(" "), .character("~"), .character("Z")] {
            expectEqual(s.handle(.key(key), at: time), [], "\(key) starts nothing")
        }
        expectEqual(fingerprint(s), before, "keys with no meaning leave the state as it was")
    }

    static func reducerOnboarding() throws {
        let attended = State.Options(onboarding: true)
        // The port only lacks an address: the guided setup's one automatic step.
        var bridged = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = bridged.begin()
        expectEqual(bridged.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time),
            [.fixLink(device: "rdma_en6", dryRun: false)], "the first reading that plans a fix starts it, for the planned device")
        expectEqual(bridged.inFlight, .fixLink, "the fix is in flight")
        _ = bridged.handle(.actionFinished(.fixLink, .init(succeeded: false, lines: ["Link fix: approvalDeclined", "The macOS prompt was cancelled; nothing was changed."])), at: time)
        expect(bridged.activity.last?.failed == true && bridged.activity.last?.lines.last?.contains("cancelled") == true,
            "a declined prompt is shown as the fix reported it")
        expectEqual(bridged.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time), [],
            "after one attempt the screen never raises the prompt by itself again")
        expectEqual(press(&bridged, "f"), [.fixLink(device: nil, dryRun: false)], "the operator can ask again with f")

        // In a dry run the same step stops where the prompt would be.
        var dry = State(size: .init(columns: 100, rows: 30), options: .init(dryRun: true, onboarding: true))
        _ = dry.begin()
        expectEqual(dry.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time),
            [.fixLink(device: "rdma_en6", dryRun: true)], "a dry run plans the same step as a dry run")

        // A link that was ready and later loses its address is not fixed unasked.
        var lost = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = lost.begin()
        expectEqual(lost.handle(.snapshot(ConsoleFixtures.snapshot()), at: time), [], "a ready link needs nothing")
        _ = press(&lost, "r")
        expectEqual(lost.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time), [],
            "an address lost while the screen is open raises no prompt by itself")

        // No cable at first: the wait ends when a port comes up, and the step runs then.
        var cable = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = cable.begin()
        expectEqual(cable.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink)), at: time), [], "no port, no fix")
        expectEqual(cable.snapshot?.setup.next, .awaitConnection, "the setup flow is waiting for a connection")
        expectEqual(cable.handle(.tick, at: time), [.pollLink], "the wait reads the link again")
        expectEqual(cable.handle(.linkObserved(ConsoleFixtures.bridgedLink), at: time), [.refresh], "a port came up")
        expectEqual(cable.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time),
            [.fixLink(device: "rdma_en6", dryRun: false)], "the step runs once the cable is in")

        // RDMA off: nothing to fix, nothing asked.
        var disabled = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = disabled.begin()
        expectEqual(disabled.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.disabledLink)), at: time), [], "RDMA off plans no fix")
        expectEqual(disabled.snapshot?.setup.next, .stopped, "the flow stopped with its guidance")

        // Without onboarding (a check, or a pipe) nothing is ever started unasked.
        var plain = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink))
        expect(plain.inFlight == nil, "no automatic step without onboarding")
        expectEqual(plain.handle(.tick, at: time), [.pollLink], "it still watches the link")
    }

    static func reducerActions() throws {
        var s = state()
        expectEqual(press(&s, "f"), [.fixLink(device: nil, dryRun: false)], "f runs the link fix")
        expectEqual(s.inFlight, .fixLink, "it is in flight")
        // Re-entrancy: a second key while one action runs starts nothing.
        for key in "feca" {
            expectEqual(press(&s, String(key)), [], "\(key) while the fix runs starts nothing")
            expect(s.notice?.contains("Fix link is still running") == true, "and says what is running")
        }
        expectEqual(s.inFlight, .fixLink, "the first action is still the one in flight")
        expectEqual(press(&s, "r"), [.refresh], "reading the state again is allowed while an action runs")
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        let result = ClusterConsoleActionResult(succeeded: true, lines: ["Link fix: alreadyReady", "The link is already ready; nothing was changed."])
        expectEqual(s.handle(.actionFinished(.fixLink, result), at: time), [.refresh], "the state is read again after an action")
        expect(s.inFlight == nil, "nothing is in flight afterwards")
        expectEqual(s.activity.last, .init(time: time, title: "Fix link", failed: false, lines: result.lines), "the result shown is the operation's own")

        var dry = state(options: .init(dryRun: true, onboarding: false))
        expectEqual(press(&dry, "f"), [.fixLink(device: nil, dryRun: true)], "a dry run asks for the dry run")

        // An error is shown as the error it was.
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        expectEqual(press(&s, "c"), [.recoverJournal], "an absent journal is reported without a question")
        _ = s.handle(.actionFinished(.recoverJournal, .init(succeeded: false, lines: ["Configuration directory permissions differ"])), at: time)
        expect(s.activity.last?.failed == true && s.activity.last?.lines == ["Configuration directory permissions differ"],
            "a failure carries the operation's error text")

        // A journal that names a session is cleared only after a yes.
        var stranded = state(ConsoleFixtures.snapshot(journal: .ownershipUnproven))
        expectEqual(press(&stranded, "c"), [], "recover asks first when the journal names a session")
        expectEqual(stranded.confirming, .recoverJournal, "the question is open")
        expectEqual(press(&stranded, "n"), [], "any other key cancels")
        expect(stranded.confirming == nil && stranded.notice?.contains("Cancelled") == true && stranded.activity.isEmpty, "nothing ran")
        press(&stranded, "c")
        expectEqual(press(&stranded, "y"), [.recoverJournal], "y recovers")

        // Export needs something observed, and takes what the screen holds.
        expectEqual(press(&s, "e"), [.exportDiagnostics], "e exports")
        expectEqual(s.inFlight, .exportDiagnostics, "export is in flight")
        _ = s.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: ["Wrote ~/x.json."])), at: time)

        // The activity list is bounded.
        for index in 0..<(State.activityLimit + 20) {
            press(&s, "c")
            _ = s.handle(.actionFinished(.recoverJournal, .init(succeeded: true, lines: ["entry \(index)"])), at: time)
            _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        }
        expectEqual(s.activity.count, State.activityLimit, "the activity list keeps a bounded tail")
        expectEqual(s.activity.last?.lines, ["entry \(State.activityLimit + 19)"], "and it is the newest end")
    }

    static func reducerTrust() throws {
        // No setup was passed in: there is nothing to approve.
        var none = state()
        expectEqual(press(&none, "a"), [], "nothing to approve")
        expect(none.notice?.contains("No setup is waiting") == true && none.confirming == nil, "and the screen says so")
        expectEqual(press(&none, "y"), [], "a stray y approves nothing")

        var unreadable = state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate(error: "Capability input digest differs")))
        expectEqual(press(&unreadable, "a"), [], "an unreadable setup cannot be approved")
        expect(unreadable.notice?.contains("Capability input digest differs") == true, "the reason is the reader's own")

        var saved = state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate(alreadySaved: true)))
        expectEqual(press(&saved, "a"), [], "the saved setup is not approved again")

        // A readable setup is approved by a, then y, and by nothing else.
        let waiting = ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate())
        var s = state(waiting)
        expect(s.inFlight == nil && s.confirming == nil, "showing a setup approves nothing")
        for event in [ClusterConsoleEvent.tick, .snapshot(waiting), .resized(.init(columns: 80, rows: 24)),
                      .linkObserved(ConsoleFixtures.readyLink), .key(.enter), .key(.character("y")), .key(.character("r"))] {
            expect(!s.handle(event, at: time).contains(.approveSetup), "no event but a then y approves")
        }
        _ = s.handle(.snapshot(waiting), at: time)
        expectEqual(press(&s, "a"), [], "a asks; it does not approve")
        expectEqual(s.confirming, .approveSetup, "the question is open")
        for cancel in [ClusterConsoleKey.enter, .character("n"), .character(" "), .escape, .unknown, .character("a")] {
            expectEqual(s.handle(.key(cancel), at: time), [], "\(cancel) does not approve")
            expect(s.confirming == nil, "the question is closed by \(cancel)")
            press(&s, "a")
        }
        expectEqual(press(&s, "y"), [.approveSetup], "y approves")
        expectEqual(s.inFlight, .approveSetup, "the save is in flight")
        expectEqual(press(&s, "y"), [], "a second y does not approve twice")
        _ = s.handle(.actionFinished(.approveSetup, .init(succeeded: true, lines: ["Saved cluster setup eeeeeeeeeeee."])), at: time)
        expectEqual(s.activity.last?.title, "Approve setup", "the approval is in the activity list")

        // Every other event sequence, at length: nothing reaches the save without the two keys.
        var fuzzed = state(waiting), seed: UInt64 = 7
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let alphabet = Array("abcdefghijklmnopqrstuvwxz0123456789 ?GJK")  // every key but y
        for _ in 0..<3000 {
            let effects = fuzzed.handle(.key(.character(alphabet[Int(next() % UInt64(alphabet.count))])), at: time)
            expect(!effects.contains(.approveSetup), "a key other than y approved a setup")
            if let action = fuzzed.inFlight { _ = fuzzed.handle(.actionFinished(action, .init(succeeded: true, lines: [])), at: time) }
            if fuzzed.refreshing { _ = fuzzed.handle(.snapshot(waiting), at: time) }
            if fuzzed.exit != nil { fuzzed = state(waiting) }
        }
    }

    static func reducerSession() throws {
        var none = state()
        expectEqual(press(&none, "s"), [], "nothing to start without a saved setup")
        expect(none.notice?.contains("No cluster setup is saved") == true, "the refusal says why")
        expectEqual(press(&none, "x"), [], "nothing to stop")
        expect(none.notice?.contains("No session was started from this screen") == true, "and says so")

        var follower = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(role: .follower)))
        expectEqual(press(&follower, "s"), [], "a follower does not start the session")
        expect(follower.notice?.contains("follower") == true, "the refusal names the role")

        var s = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
        expectEqual(press(&s, "s"), [], "start asks first")
        expectEqual(s.confirming, .startSession, "the question is open")
        expectEqual(press(&s, "n"), [], "any other key cancels the start")
        expectEqual(s.session, .none, "nothing was started")
        press(&s, "s")
        expectEqual(press(&s, "y"), [.launchSession], "y starts the session process")
        expectEqual(s.session, .launching, "it is being started")
        _ = s.handle(.session(.launched(processIdentifier: 4242)), at: time)
        expectEqual(s.session, .running(processIdentifier: 4242), "the process is running")
        expect(s.activity.last?.lines.first?.contains("4242") == true, "the start is recorded with its process")
        expectEqual(press(&s, "s"), [], "a second start is refused while one runs")
        expect(s.notice?.contains("already running") == true, "and says why")
        expectEqual(s.handle(.tick, at: time), [.pollSession], "a running session is observed")

        // Output arrives as the process writes it, and is bounded.
        for index in 0..<(State.sessionOutputLimit + 10) { _ = s.handle(.session(.output("line \(index)")), at: time) }
        expectEqual(s.sessionOutput.count, State.sessionOutputLimit, "session output keeps a bounded tail")
        expectEqual(s.sessionOutput.last, "line \(State.sessionOutputLimit + 9)", "the newest line is kept")

        // Stop: one interrupt, then waiting for the real end.
        expectEqual(press(&s, "x"), [.interruptSession], "x interrupts the session")
        expectEqual(s.session, .stopping(processIdentifier: 4242), "it is stopping, not stopped")
        expectEqual(press(&s, "x"), [], "a second x sends nothing more")
        expect(s.notice?.contains("already asked") == true, "and says the stop is under way")
        expectEqual(press(&s, "s"), [], "no start while it is stopping")
        expectEqual(s.handle(.session(.ended(description: "exited with status 0", clean: true)), at: time), [.refresh], "the end is read back")
        expectEqual(s.session, .ended("exited with status 0"), "the session ended as the process reported")
        expect(s.activity.last?.title == "Session ended" && s.activity.last?.failed == false, "a clean end is recorded as one")
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())), at: time)
        press(&s, "s")
        expectEqual(press(&s, "y"), [.launchSession], "a new session can be started after the last one ended")
        expect(s.sessionOutput.isEmpty, "a new session starts with no output shown")

        // A start that fails, and a process that dies.
        _ = s.handle(.session(.launchFailed("The file does not exist.")), at: time)
        expect(s.activity.last?.failed == true && s.activity.last?.lines == ["The file does not exist."], "a failed start shows its error")
        expectEqual(s.session, .ended("could not be started"), "nothing is running after a failed start")
        press(&s, "s"); press(&s, "y")
        _ = s.handle(.session(.launched(processIdentifier: 77)), at: time)
        _ = s.handle(.session(.output("The selected cluster and installed owner's default setup must remain unchanged")), at: time)
        _ = s.handle(.session(.ended(description: "exited with status 1", clean: false)), at: time)
        expect(s.activity.last?.failed == true && s.activity.last?.lines.contains { $0.contains("must remain unchanged") } == true,
            "a session that refuses to start is shown with what it printed")
    }

    static func reducerLeaving() throws {
        var idle = state()
        expectEqual(press(&idle, "q"), [], "q with nothing running")
        expectEqual(idle.exit, .init(code: 0, farewell: []), "closes at once")
        expectEqual(idle.handle(.key(.character("f")), at: time), [], "nothing is handled after the screen closed")

        for key in [ClusterConsoleKey.interrupt, .endOfInput, .character("Q")] {
            var s = state()
            _ = s.handle(.key(key), at: time)
            expect(s.exit?.code == 0, "\(key) closes the screen")
        }

        // An action in flight is waited for, unless the operator insists.
        var busy = state()
        press(&busy, "f")
        expectEqual(press(&busy, "q"), [], "q while an action runs")
        expect(busy.exit == nil && busy.notice?.contains("still running") == true, "waits, and says so")
        _ = busy.handle(.actionFinished(.fixLink, .init(succeeded: true, lines: ["Link fix: fixed"])), at: time)
        expectEqual(busy.exit, .init(code: 0, farewell: []), "and closes when the action reports")

        var insist = state()
        press(&insist, "f"); press(&insist, "q")
        _ = insist.handle(.key(.interrupt), at: time)
        expect(insist.exit?.farewell.first?.contains("macOS prompt") == true, "a second quit closes now and says what may still be open")

        var stay = state()
        press(&stay, "f"); press(&stay, "q")
        _ = stay.handle(.key(.escape), at: time)
        _ = stay.handle(.actionFinished(.fixLink, .init(succeeded: true, lines: [])), at: time)
        expect(stay.exit == nil, "Escape takes back the request to close")

        // A session this screen started is stopped, never abandoned silently and never killed.
        func running() -> State {
            var s = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
            press(&s, "s"); press(&s, "y")
            _ = s.handle(.session(.launched(processIdentifier: 99)), at: time)
            return s
        }
        var s = running()
        expectEqual(press(&s, "q"), [], "q with a session running asks first")
        expect(s.exit == nil && s.notice?.contains("Press q again to stop it") == true, "the question names the consequence")
        _ = s.handle(.key(.down), at: time)
        expectEqual(press(&s, "q"), [], "another key in between takes the question back")
        expectEqual(press(&s, "q"), [.interruptSession], "q twice stops the session")
        expectEqual(s.session, .stopping(processIdentifier: 99), "and waits for it")
        expect(s.exit == nil, "the screen stays until the session has ended")
        _ = s.handle(.session(.ended(description: "exited with status 0", clean: true)), at: time)
        expectEqual(s.exit, .init(code: 0, farewell: []), "it closes when the session has ended")

        var impatient = running()
        press(&impatient, "qq")
        expectEqual(press(&impatient, "q"), [], "q while it stops")
        expect(impatient.exit == nil, "says it is waiting")
        expectEqual(press(&impatient, "q"), [], "q again")
        expect(impatient.exit?.farewell.first?.contains("process 99") == true && impatient.exit?.farewell.first?.contains("cluster recover") == true,
            "closes and says the session is finishing by itself")

        // Ctrl-C inside a question cancels the question and then leaves.
        var asked = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
        press(&asked, "s")
        expectEqual(asked.handle(.key(.interrupt), at: time), [], "Ctrl-C inside a question starts nothing")
        expect(asked.session == .none && asked.exit?.code == 0, "the start was not confirmed and the screen closed")

        // A signal to the process: the session is asked to stop, and the screen closes.
        var signalled = running()
        expectEqual(signalled.handle(.terminationSignal(15), at: time), [.interruptSession], "SIGTERM forwards one interrupt")
        expectEqual(signalled.exit?.code, 143, "and the status is the signal's")
        expect(signalled.exit?.farewell.first?.contains("process 99") == true, "with a line about the session")
        var bare = state()
        expectEqual(bare.handle(.terminationSignal(2), at: time), [], "SIGINT with nothing running")
        expectEqual(bare.exit, .init(code: 130, farewell: []), "closes with the signal's status")
        var closed = running()
        expectEqual(closed.handle(.inputClosed, at: time), [.interruptSession], "a terminal that went away stops the session too")
        expectEqual(closed.exit?.code, 1, "and closes the screen")
    }
}
