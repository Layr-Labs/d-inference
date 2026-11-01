import Foundation
@testable import InstalledContract

/// The reducer alone: no terminal, no thread, no operation. Each check feeds
/// events and reads the state and the effects.
extension ClusterConsoleCheck {
    private typealias State = ClusterConsoleState
    private static let time = "06:00:00"
    private static let digest = ConsoleFixtures.candidateSHA256

    private static func state(_ snapshot: ClusterConsoleSnapshot? = ConsoleFixtures.snapshot(),
                              options: State.Options = .init(onboarding: false, questionDwellMilliseconds: 0)) -> State {
        var state = State(size: .init(columns: 100, rows: 30), options: options)
        expectEqual(state.begin(), [.refresh], "opening the screen reads the state once")
        if let snapshot { _ = state.handle(.snapshot(snapshot), at: time) }
        return state
    }

    @discardableResult
    private static func press(_ state: inout State, _ text: String) -> [ClusterConsoleEffect] {
        text.flatMap { state.handle(.key(.character($0)), at: time) }
    }

    /// What the run loop does after each batch of events: draw, and tell the
    /// state what was drawn. An open question can be answered only after this.
    private static func draw(_ state: inout State) {
        state.drew(ClusterConsoleRenderer.frame(state))
    }

    /// A key that opens a question, the frame that shows it, and the answer.
    @discardableResult
    private static func ask(_ state: inout State, _ key: Character, answer: Character) -> [ClusterConsoleEffect] {
        press(&state, String(key))
        draw(&state)
        return press(&state, String(answer))
    }

    /// What a key may change, as one comparable value.
    private static func fingerprint(_ state: State) -> String {
        "\(state.refreshing)|\(String(describing: state.inFlight))|\(String(describing: state.asking))|\(state.session)|\(state.activity.count)|\(state.scroll)|\(state.showsHelp)|\(String(describing: state.exit))|\(state.sessionOutput.count)"
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

        // Resizing and scrolling. The furthest line is what the last frame could show.
        var scrolling = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, saved: ConsoleFixtures.savedSetup()))
        _ = scrolling.handle(.resized(.init(columns: 60, rows: 12)), at: time)
        expectEqual(scrolling.size, .init(columns: 60, rows: 12), "the new size is kept")
        draw(&scrolling)
        let furthest = scrolling.maximumScroll, page = scrolling.bodyRows - 1
        expect(furthest > 2 * page && page == 8, "the body does not fit twelve rows: \(furthest) lines beyond, \(page) to a page")
        for key in [ClusterConsoleKey.down, .down, .pageDown] { _ = scrolling.handle(.key(key), at: time) }
        expectEqual(scrolling.scroll, 2 + page, "down moves a line and page down a page")
        _ = scrolling.handle(.key(.end), at: time); expectEqual(scrolling.scroll, furthest, "end")
        for key in [ClusterConsoleKey.down, .pageDown] { _ = scrolling.handle(.key(key), at: time) }
        expectEqual(scrolling.scroll, furthest, "scrolling stops at the end")
        _ = scrolling.handle(.key(.pageUp), at: time); expectEqual(scrolling.scroll, furthest - page, "page up")
        _ = scrolling.handle(.key(.home), at: time); expectEqual(scrolling.scroll, 0, "home")
        _ = scrolling.handle(.key(.up), at: time); expectEqual(scrolling.scroll, 0, "and stops at the start")
        press(&scrolling, "jjG"); expectEqual(scrolling.scroll, furthest, "j and G scroll")
        press(&scrolling, "kg"); expectEqual(scrolling.scroll, 0, "k and g scroll")
        // A window that now shows everything is not left scrolled.
        press(&scrolling, "G")
        _ = scrolling.handle(.resized(.init(columns: 200, rows: 300)), at: time)
        draw(&scrolling)
        expectEqual(scrolling.scroll, 0, "a larger window pulls the view back inside the body")
        press(&s, "?"); expect(s.showsHelp, "? opens help")
        _ = s.handle(.key(.escape), at: time); expect(!s.showsHelp, "Escape closes help")

        // Keys with no meaning change nothing.
        let before = fingerprint(s)
        for key in [ClusterConsoleKey.unknown, .tab, .enter, .backspace, .left, .right, .character("z"), .character("1"),
                    .character(" "), .character("~"), .character("Z"), .character("y"), .character("Y")] {
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

        // The port is ready on an address nothing keeps: the step installs the job that keeps it.
        var unkept = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = unkept.begin()
        expectEqual(unkept.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.temporaryLink)), at: time),
            [.fixLink(device: "rdma_en7", dryRun: false)], "a ready port whose address nothing keeps is offered the same one step")
        var keptAlready = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = keptAlready.begin()
        expectEqual(keptAlready.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.keptLink)), at: time), [], "a kept address needs nothing")

        // macOS took the address and its system job is loaded: the job is given
        // its readings first, as `darkbloom cluster setup` gives it, and only then is the fix asked for.
        let readings = ClusterConsoleLinkSetup.keeperReadings
        expect(readings == max(1, ClusterLinkSetupFlow.keeperWaitSeconds / ClusterLinkWatch.pollIntervalSeconds) && readings > 1,
            "the wait is the guided setup's own: \(readings) readings")
        var keeper = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = keeper.begin()
        let lostKept = ConsoleFixtures.snapshot(link: ConsoleFixtures.lostKeptLink)
        expectEqual(keeper.handle(.snapshot(lostKept), at: time), [], "no prompt while the system job is about to put the address back")
        expect(keeper.snapshot?.setup.next == .awaitKeeper && keeper.snapshot?.setup.fixDevice == "rdma_en6", "the flow is waiting for the job")
        for reading in 1..<readings {
            expectEqual(keeper.handle(.tick, at: time), [.pollLink], "the link is read again while the job is waited for")
            expectEqual(keeper.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time), [], "reading \(reading) of \(readings): still waiting")
        }
        // A full refresh of the same link in between does not start the count again.
        _ = press(&keeper, "r")
        expectEqual(keeper.handle(.snapshot(lostKept), at: time), [], "a refresh that finds the same link changes nothing")
        _ = keeper.handle(.tick, at: time)
        expectEqual(keeper.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time), [.fixLink(device: "rdma_en6", dryRun: false)],
            "after the job's readings the fix is asked for, for the planned device")
        _ = keeper.handle(.actionFinished(.fixLink, .init(succeeded: false, lines: ["Link fix: approvalDeclined"])), at: time)
        _ = keeper.handle(.snapshot(lostKept), at: time)
        for _ in 0..<(2 * readings) {
            _ = keeper.handle(.tick, at: time)
            expectEqual(keeper.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time), [], "and never a second time by itself")
        }
        // The job does its work: the address is back and nothing is asked.
        var restored = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = restored.begin()
        _ = restored.handle(.snapshot(lostKept), at: time)
        _ = restored.handle(.tick, at: time)
        expectEqual(restored.handle(.linkObserved(ConsoleFixtures.keptLink), at: time), [.refresh], "the address came back: read in full")
        expectEqual(restored.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.keptLink)), at: time), [], "and nothing was asked for")
        for _ in 0..<(2 * readings) { expectEqual(restored.handle(.linkObserved(ConsoleFixtures.keptLink), at: time), [], "nor is anything later") }
        // A link that changes during the wait starts the count again.
        var flapping = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = flapping.begin()
        _ = flapping.handle(.snapshot(lostKept), at: time)
        for _ in 1..<readings { _ = flapping.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time) }
        _ = flapping.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink)), at: time)
        _ = flapping.handle(.snapshot(lostKept), at: time)
        expectEqual(flapping.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time), [], "the job gets its full wait again after a change")
        // With no job to wait for, the lost address is the plain case.
        var unkeptLoss = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = unkeptLoss.begin()
        expectEqual(unkeptLoss.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.lostLink)), at: time),
            [.fixLink(device: "rdma_en6", dryRun: false)], "a lost address nothing would put back is fixed like a missing one")
        // Without onboarding the wait never turns into a fix.
        var watching = state(lostKept)
        for _ in 0..<(2 * readings) { expectEqual(watching.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time), [], "no fix unasked without onboarding") }
        expectEqual(press(&watching, "f"), [.fixLink(device: nil, dryRun: false)], "f asks for it at once")

        // The operator asks for the fix by key during the wait and cancels the prompt: the screen does not ask again by itself.
        var asked = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = asked.begin()
        _ = asked.handle(.snapshot(lostKept), at: time)
        for _ in 1..<readings { _ = asked.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time) }
        expectEqual(press(&asked, "f"), [.fixLink(device: nil, dryRun: false)], "f during the wait runs the fix now")
        _ = asked.handle(.actionFinished(.fixLink, .init(succeeded: false, lines: ["Link fix: approvalDeclined"])), at: time)
        _ = asked.handle(.snapshot(lostKept), at: time)
        for _ in 0..<(2 * readings) {
            expectEqual(asked.handle(.linkObserved(ConsoleFixtures.lostKeptLink), at: time), [], "a fix asked for by key spends the automatic one")
        }

        // RDMA off: nothing to fix, nothing asked, and the automatic step is spent.
        var disabled = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = disabled.begin()
        expectEqual(disabled.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.disabledLink)), at: time), [], "RDMA off plans no fix")
        expectEqual(disabled.snapshot?.setup.next, .stopped, "the flow stopped with its guidance")
        _ = press(&disabled, "r")
        expectEqual(disabled.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time), [],
            "a link that becomes fixable long after the screen opened raises no prompt by itself")
        expect(!disabled.mayStartLinkFixUnasked, "and the screen knows it will not")
        // A session serving elsewhere when the fix was planned: not started then, and not later either.
        var blocked = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = blocked.begin()
        expectEqual(blocked.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, live: try ConsoleFixtures.live())), at: time), [],
            "no automatic fix beside a serving session")
        expectEqual(blocked.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink)), at: time), [],
            "nor once that session has gone: the moment was spent")
        // Only waiting keeps it: for a cable, or for the system job.
        var patient = State(size: .init(columns: 100, rows: 30), options: attended)
        _ = patient.begin()
        _ = patient.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink)), at: time)
        expect(patient.mayStartLinkFixUnasked, "while waiting for a cable the step is still the screen's")

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
        expect(s.asking == nil, "and no question was opened behind it")
        expectEqual(press(&s, "r"), [.refresh], "reading the state again is allowed while an action runs")
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        let result = ClusterConsoleActionResult(succeeded: true, lines: ["Link fix: alreadyReady", "The link is already ready; nothing was changed."])
        expectEqual(s.handle(.actionFinished(.fixLink, result), at: time), [.refresh], "the state is read again after an action")
        expect(s.inFlight == nil, "nothing is in flight afterwards")
        expectEqual(s.activity.last, .init(time: time, title: "Fix link", failed: false, lines: result.lines), "the result shown is the operation's own")

        var dry = state(options: .init(dryRun: true, onboarding: false))
        expectEqual(press(&dry, "f"), [.fixLink(device: nil, dryRun: true)], "a dry run asks for the dry run")

        // Recovery always asks: what the journal holds is read when it runs, not assumed from the screen.
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        expectEqual(press(&s, "c"), [], "recover asks first")
        expectEqual(s.asking, .recoverJournal, "the question is open")
        draw(&s)
        expectEqual(press(&s, "n"), [], "any other key cancels")
        expect(s.asking == nil && s.notice?.contains("Cancelled") == true, "nothing ran")
        expectEqual(ask(&s, "c", answer: "y"), [.recoverJournal], "y recovers")
        // An error is shown as the error it was.
        _ = s.handle(.actionFinished(.recoverJournal, .init(succeeded: false, lines: ["Configuration directory permissions differ"])), at: time)
        expect(s.activity.last?.failed == true && s.activity.last?.lines == ["Configuration directory permissions differ"],
            "a failure carries the operation's error text")
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)

        // Export needs something observed, and takes what the screen holds.
        expectEqual(press(&s, "e"), [.exportDiagnostics], "e exports")
        expectEqual(s.inFlight, .exportDiagnostics, "export is in flight")
        _ = s.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: ["Wrote x.json"])), at: time)
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)

        // While a session runs, nothing that touches the link, the saved setup or the journal starts.
        var serving = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), candidate: ConsoleFixtures.candidate()))
        ask(&serving, "s", answer: "y")
        _ = serving.handle(.session(.launched(processIdentifier: 51)), at: time)
        for key in "fca" {
            expectEqual(press(&serving, String(key)), [], "\(key) starts nothing while the session runs")
            expect(serving.notice?.contains("Stop it with x") == true && serving.asking == nil && serving.inFlight == nil, "\(key): and says why")
        }
        expectEqual(press(&serving, "e"), [.exportDiagnostics], "an export, which only reads, is allowed")
        _ = serving.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: [])), at: time)
        press(&serving, "x")
        expectEqual(press(&serving, "f"), [], "nor while it is stopping")
        _ = serving.handle(.session(.ended(description: "exited with status 0", clean: true)), at: time)
        _ = serving.handle(.snapshot(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())), at: time)
        expectEqual(press(&serving, "f"), [.fixLink(device: nil, dryRun: false)], "afterwards the actions are back")
        // The same holds for a session another process is serving.
        var elsewhere = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), live: try ConsoleFixtures.live()))
        for key in "fca" {
            expectEqual(press(&elsewhere, String(key)), [], "\(key) starts nothing while another process serves")
            expect(elsewhere.notice?.contains("another process") == true, "\(key): and says so")
        }
        // A follower reads no status; a journal that is not empty is what shows a session on it.
        var owned = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(role: .follower), candidate: ConsoleFixtures.candidate(),
            journal: .ownershipUnproven))
        for key in "fa" {
            expectEqual(press(&owned, String(key)), [], "\(key) starts nothing while the device journal is not empty")
            expect(owned.notice?.contains("device journal is not empty") == true && owned.asking == nil, "\(key): and says why: \(owned.notice ?? "")")
        }
        expectEqual(press(&owned, "c"), [], "recovery is what clears a stranded journal, so it may be asked for")
        expectEqual(owned.asking, .recoverJournal, "and it asks")
        var ownedAtOpen = State(size: .init(columns: 100, rows: 30), options: .init(onboarding: true))
        _ = ownedAtOpen.begin()
        expectEqual(ownedAtOpen.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, journal: .ownershipUnproven)), at: time), [],
            "no automatic link fix under a journal that is not empty")
        // A notice about something that is running goes when that thing ends, not only at the next key.
        var told = state()
        press(&told, "f"); press(&told, "e")
        expect(told.notice?.contains("Fix link is still running") == true, "told to wait")
        _ = told.handle(.actionFinished(.fixLink, .init(succeeded: true, lines: [])), at: time)
        expect(told.notice == nil, "the notice goes when the action has reported")
        press(&told, "r")
        expect(told.notice == "A refresh is already running.", "told a refresh is running")
        _ = told.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        expect(told.notice == nil, "and that goes when the reading arrives")

        // And the automatic step is not taken beside a session either.
        var beside = State(size: .init(columns: 100, rows: 30), options: .init(onboarding: true))
        _ = beside.begin()
        expectEqual(beside.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, live: try ConsoleFixtures.live())), at: time), [],
            "no automatic link fix while a session is serving")

        // The activity list is bounded.
        for index in 0..<(State.activityLimit + 20) {
            press(&s, "e")
            _ = s.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: ["entry \(index)"])), at: time)
            _ = s.handle(.snapshot(ConsoleFixtures.snapshot()), at: time)
        }
        expectEqual(s.activity.count, State.activityLimit, "the activity list keeps a bounded tail")
        expectEqual(s.activity.last?.lines, ["entry \(State.activityLimit + 19)"], "and it is the newest end")
    }

    static func reducerTrust() throws {
        // No setup was passed in: there is nothing to approve.
        var none = state()
        expectEqual(press(&none, "a"), [], "nothing to approve")
        expect(none.notice?.contains("No setup is waiting") == true && none.asking == nil, "and the screen says so")
        expectEqual(press(&none, "y"), [], "a stray y approves nothing")

        var unreadable = state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate(error: "Capability input digest differs")))
        expectEqual(press(&unreadable, "a"), [], "an unreadable setup cannot be approved")
        expect(unreadable.notice?.contains("Capability input digest differs") == true, "the reason is the reader's own")

        var saved = state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate(alreadySaved: true)))
        expectEqual(press(&saved, "a"), [], "the saved setup is not approved again")

        // A readable setup is approved by a, then y, and by nothing else.
        let waiting = ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate())
        let approve = ClusterConsoleEffect.approveSetup(expectedSHA256: digest)
        var s = state(waiting)
        expect(s.inFlight == nil && s.asking == nil, "showing a setup approves nothing")
        for event in [ClusterConsoleEvent.tick, .snapshot(waiting), .resized(.init(columns: 80, rows: 24)),
                      .linkObserved(ConsoleFixtures.readyLink), .key(.enter), .key(.character("y")), .key(.character("r"))] {
            expect(!s.handle(event, at: time).contains(approve), "no event but a then y approves")
        }
        _ = s.handle(.snapshot(waiting), at: time)
        expectEqual(press(&s, "a"), [], "a asks; it does not approve")
        expectEqual(s.asking, .approveSetup(expectedSHA256: digest), "the question is about the setup that is shown, by its digest")

        // A y that arrives before the question has been drawn is not an answer:
        // "ay" typed ahead, or the tail of a word, cannot approve.
        expect(!s.questionShown, "the question has not been drawn yet")
        for key in "yYyy" { expectEqual(press(&s, String(key)), [], "\(key) before the question is on screen approves nothing") }
        expect(s.asking != nil && s.inFlight == nil, "and the question is still open")
        var typedAhead = state(waiting)
        expectEqual(press(&typedAhead, "ay"), [], "a and y in one breath approve nothing")
        expect(typedAhead.asking != nil && typedAhead.inFlight == nil, "the question is still waiting to be drawn and answered")
        var pasted = state(waiting)
        expect(!press(&pasted, "today say yay, ayayay").contains(approve) && pasted.inFlight != .approveSetup, "nor does any run of text")
        // Any other key before the question is drawn cancels it: nothing waits unseen.
        var hasty = state(waiting)
        expectEqual(press(&hasty, "an"), [], "a then another key")
        expect(hasty.asking == nil && hasty.notice?.contains("Cancelled") == true, "the question is gone and the screen says so")
        expectEqual(press(&hasty, "y"), [], "and a y after that approves nothing")

        // Once it is on screen, every key but y cancels it.
        for cancel in [ClusterConsoleKey.enter, .character("n"), .character(" "), .escape, .unknown, .character("a")] {
            draw(&s)
            expect(s.questionShown, "the question is on screen")
            expectEqual(s.handle(.key(cancel), at: time), [], "\(cancel) does not approve")
            expect(s.asking == nil && !s.questionShown, "the question is closed by \(cancel)")
            press(&s, "a")
        }
        draw(&s)
        expectEqual(press(&s, "y"), [approve], "y approves exactly the setup that was shown")
        expectEqual(s.inFlight, .approveSetup, "the save is in flight")
        expectEqual(press(&s, "y"), [], "a second y does not approve twice")
        _ = s.handle(.actionFinished(.approveSetup, .init(succeeded: true, lines: ["Saved cluster setup eeeeeeeeeeee."])), at: time)
        expectEqual(s.activity.last?.title, "Approve setup", "the approval is in the activity list")

        // The question must have been on the screen for a moment before y counts.
        var dwelling = State(size: .init(columns: 100, rows: 30), options: .init(onboarding: false))
        _ = dwelling.begin()
        _ = dwelling.handle(.snapshot(waiting), at: time)
        expectEqual(dwelling.options.questionDwellMilliseconds, 500, "the installed dwell is half a second")
        let second: UInt64 = 1_000_000_000
        _ = dwelling.handle(.key(.character("a")), at: time, uptime: 10 * second)
        dwelling.drew(ClusterConsoleRenderer.frame(dwelling), uptime: 10 * second)
        expectEqual(dwelling.handle(.key(.character("y")), at: time, uptime: 10 * second + 80_000_000), [], "a y 80 ms after the question appeared approves nothing")
        expectEqual(dwelling.handle(.key(.character("y")), at: time, uptime: 10 * second + 499_000_000), [], "nor just short of the dwell")
        expect(dwelling.asking != nil, "the question is still open")
        // Drawing it again does not start the wait over.
        dwelling.drew(ClusterConsoleRenderer.frame(dwelling), uptime: 10 * second + 499_500_000)
        expectEqual(dwelling.handle(.key(.character("y")), at: time, uptime: 10 * second + 500_000_000), [approve], "once it has been readable for the dwell, y approves")
        // A question withdrawn and asked again must be read again.
        var reasked = State(size: .init(columns: 100, rows: 30), options: .init(onboarding: false))
        _ = reasked.begin()
        _ = reasked.handle(.snapshot(waiting), at: time)
        _ = reasked.handle(.key(.character("a")), at: time, uptime: second)
        reasked.drew(ClusterConsoleRenderer.frame(reasked), uptime: second)
        _ = reasked.handle(.key(.character("n")), at: time, uptime: 5 * second)
        _ = reasked.handle(.key(.character("a")), at: time, uptime: 5 * second)
        reasked.drew(ClusterConsoleRenderer.frame(reasked), uptime: 5 * second)
        expectEqual(reasked.handle(.key(.character("y")), at: time, uptime: 5 * second + 100_000_000), [], "the dwell is counted from when this question appeared")
        expectEqual(reasked.handle(.key(.character("y")), at: time, uptime: 6 * second), [approve], "and then y approves")

        // What stood in the way when a was pressed is checked again when y is.
        var overtaken = state(waiting)
        press(&overtaken, "a"); draw(&overtaken)
        _ = overtaken.handle(.sessionObserved(.init(status: ConsoleFixtures.diagnostics(link: ConsoleFixtures.readyLink, live: try ConsoleFixtures.live()))), at: time)
        expectEqual(press(&overtaken, "y"), [], "a session that appeared while the question was open stops the approval")
        expect(overtaken.notice?.contains("another process") == true && overtaken.inFlight == nil, "and the screen says why")
        // A setup whose trust files do not check out is not offered for approval.
        let untrusted = ClusterConsoleTrust(knownHostsPinSHA256: String(repeating: "a", count: 64), knownHostsPinMatches: false, hostKeys: [],
            hostKeysNotShown: 0, identityFileUsable: true, error: nil)
        let doubtful = ClusterConsoleCandidateSetup(error: nil, pairing: .init(clusterID: "fixture-cluster", memberID: "peer-0", role: .leader, localRank: 0,
            peerID: "peer-1", peerRank: 1, linkDevice: "rdma_en7", trust: untrusted, pairApproval: nil), publicModelID: "fixture/public-model",
            runtimeModelID: "registered_fixture", configurationSHA256: digest, alreadySaved: false)
        var refusing = state(ConsoleFixtures.snapshot(candidate: doubtful))
        expectEqual(press(&refusing, "a"), [], "a setup whose pinned file no longer matches is not asked about")
        expect(refusing.asking == nil && refusing.notice?.contains("cannot be approved as it is") == true, "and the screen says it cannot be approved")

        // The setup changes while its question is open: the question is withdrawn.
        var changed = state(waiting)
        press(&changed, "a"); draw(&changed)
        _ = changed.handle(.snapshot(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate(sha256: String(repeating: "7", count: 64)))), at: time)
        expect(changed.asking == nil && changed.notice?.contains("changed") == true, "a different setup is not approved on the old question")
        expectEqual(press(&changed, "y"), [], "and y now approves nothing")
        var vanished = state(waiting)
        press(&vanished, "a"); draw(&vanished)
        _ = vanished.handle(.snapshot(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate(error: "Configuration input does not exist"))), at: time)
        expectEqual(press(&vanished, "y"), [], "nor when the setup can no longer be read")
        // The same setup read again keeps the question.
        var steady = state(waiting)
        press(&steady, "a"); draw(&steady)
        _ = steady.handle(.snapshot(waiting), at: time)
        expectEqual(press(&steady, "y"), [approve], "an unchanged setup is still the one asked about")

        // A window that cannot show every word of a question does not ask it.
        let needed = ClusterConsoleRenderer.text(of: .approveSetup(expectedSHA256: digest)).count
        for size in [ClusterConsoleSize(columns: 20, rows: 4), .init(columns: ClusterConsoleRenderer.minimumColumns, rows: ClusterConsoleRenderer.minimumRows),
                     .init(columns: needed - 1, rows: 30)] {
            var small = state(waiting)
            _ = small.handle(.resized(size), at: time)
            press(&small, "a"); draw(&small)
            expect(small.asking == nil && !small.questionShown, "no question is opened at \(size.columns)x\(size.rows), where it cannot be read in full")
            expect(small.notice == "Window too narrow to ask. Widen it to \(needed) columns and press a again.", "and the screen says what it needs: \(small.notice ?? "")")
            expectEqual(press(&small, "y"), [], "so nothing can be approved there")
        }
        var exact = state(waiting)
        _ = exact.handle(.resized(.init(columns: needed, rows: ClusterConsoleRenderer.minimumRows)), at: time)
        expectEqual(ask(&exact, "a", answer: "y"), [approve], "a window exactly wide enough asks and is answered")
        // A question open when the window shrinks is withdrawn, drawn or not, and does not come back by itself.
        for drawn in [true, false] {
            var shrunk = state(waiting)
            press(&shrunk, "a")
            if drawn { draw(&shrunk) }
            _ = shrunk.handle(.resized(.init(columns: needed - 1, rows: 30)), at: time)
            expect(shrunk.asking == nil && shrunk.notice?.contains("too small to show the question") == true, "a question the window can no longer show is withdrawn")
            draw(&shrunk)
            expectEqual(press(&shrunk, "y"), [], "and y approves nothing")
            _ = shrunk.handle(.resized(.init(columns: 100, rows: 30)), at: time)
            draw(&shrunk)
            expectEqual(press(&shrunk, "y"), [], "nor after the window is wide again")
            expectEqual(ask(&shrunk, "a", answer: "y"), [approve], "it is asked again, read, and only then answered")
        }
        // A frame from before the question, or of another question, is not this question shown.
        var stale = state(waiting)
        let before = ClusterConsoleRenderer.frame(stale)
        press(&stale, "a")
        stale.drew(before)
        expectEqual(press(&stale, "y"), [], "a frame drawn before the question does not make it answerable")

        // Every other key, at length, with every frame drawn: nothing reaches the save without y.
        var fuzzed = state(waiting), seed: UInt64 = 7
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let alphabet = Array("abcdefghijklmnopqrstuvwxz0123456789 ?GJK")  // every key but y
        for _ in 0..<3000 {
            let effects = fuzzed.handle(.key(.character(alphabet[Int(next() % UInt64(alphabet.count))])), at: time)
            expect(!effects.contains(approve), "a key other than y approved a setup")
            draw(&fuzzed)
            if let action = fuzzed.inFlight { _ = fuzzed.handle(.actionFinished(action, .init(succeeded: true, lines: [])), at: time) }
            if fuzzed.refreshing { _ = fuzzed.handle(.snapshot(waiting), at: time) }
            if fuzzed.exit != nil { fuzzed = state(waiting) }
        }
        // And every key including y, with no frame ever drawn: still nothing.
        var blind = state(waiting)
        let everything = alphabet + Array("yY")
        for _ in 0..<3000 {
            let effects = blind.handle(.key(.character(everything[Int(next() % UInt64(everything.count))])), at: time)
            expect(!effects.contains(approve) && !effects.contains(.launchSession) && !effects.contains(.recoverJournal),
                "a question was answered before it was drawn")
            if let action = blind.inFlight { _ = blind.handle(.actionFinished(action, .init(succeeded: true, lines: [])), at: time) }
            if blind.refreshing { _ = blind.handle(.snapshot(waiting), at: time) }
            if blind.exit != nil { blind = state(waiting) }
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

        var elsewhere = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), live: try ConsoleFixtures.live()))
        expectEqual(press(&elsewhere, "s"), [], "no second session beside one that is serving")
        expect(elsewhere.notice?.contains("already serving from another process") == true, "and says where it is")
        expectEqual(press(&elsewhere, "x"), [], "another process's session is not stopped from here")
        expect(elsewhere.notice?.contains("Stop it where it was started") == true, "and says what to do")

        var s = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
        expectEqual(press(&s, "s"), [], "start asks first")
        expectEqual(s.asking, .startSession, "the question is open")
        expectEqual(press(&s, "y"), [], "a y before the question is drawn starts nothing")
        draw(&s)
        expectEqual(press(&s, "n"), [], "any other key cancels the start")
        expectEqual(s.session, .none, "nothing was started")
        expectEqual(ask(&s, "s", answer: "y"), [.launchSession], "y starts the session process")
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
        expect(s.activity.last?.lines.first?.contains("Asked process 4242 to stop") == true, "the request is recorded as a request")
        expectEqual(press(&s, "x"), [], "a second x sends nothing more")
        expect(s.notice?.contains("already asked") == true, "and says the stop is under way")
        expectEqual(press(&s, "s"), [], "no start while it is stopping")
        expectEqual(s.handle(.session(.ended(description: "exited with status 0", clean: true)), at: time), [.refresh], "the end is read back")
        expectEqual(s.session, .ended("exited with status 0"), "the session ended as the process reported")
        expect(s.activity.last?.title == "Session ended" && s.activity.last?.failed == false, "a clean end is recorded as one")
        _ = s.handle(.snapshot(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())), at: time)
        expectEqual(ask(&s, "s", answer: "y"), [.launchSession], "a new session can be started after the last one ended")
        expect(s.sessionOutput.isEmpty, "a new session starts with no output shown")

        // A start that fails, and a process that dies.
        _ = s.handle(.session(.launchFailed("The file does not exist.")), at: time)
        expect(s.activity.last?.failed == true && s.activity.last?.lines == ["The file does not exist."], "a failed start shows its error")
        expectEqual(s.session, .ended("could not be started"), "nothing is running after a failed start")
        ask(&s, "s", answer: "y")
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
            ask(&s, "s", answer: "y")
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

        // A session and an action together: the session comes first, on every way out.
        var both = running()
        press(&both, "e")
        expectEqual(press(&both, "q"), [], "q with a session running and an action out asks about the session")
        expect(both.notice?.contains("Press q again to stop it") == true, "the session is what is asked about")
        expectEqual(press(&both, "q"), [.interruptSession], "and it is stopped, not left behind")
        _ = both.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: [])), at: time)
        expect(both.exit == nil, "the action reporting does not close the screen while the session is still stopping")
        _ = both.handle(.session(.ended(description: "exited with status 0", clean: true)), at: time)
        expectEqual(both.exit, .init(code: 0, farewell: []), "it closes when both are done")
        var actionLast = running()
        press(&actionLast, "e"); press(&actionLast, "qq")
        _ = actionLast.handle(.session(.ended(description: "exited with status 0", clean: true)), at: time)
        expect(actionLast.exit == nil, "the session ended but the action is still out")
        _ = actionLast.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: [])), at: time)
        expectEqual(actionLast.exit, .init(code: 0, farewell: []), "and the screen closes when it reports")
        var abandon = running()
        press(&abandon, "e"); press(&abandon, "qq")
        expectEqual(press(&abandon, "q"), [], "q while the session stops and an action is out")
        expectEqual(press(&abandon, "q"), [], "q again closes now")
        expect(abandon.exit?.farewell.count == 2 && abandon.exit?.farewell[0].contains("process 99") == true
            && abandon.exit?.farewell[1].contains("export diagnostics") == true, "and names both things left running: \(String(describing: abandon.exit?.farewell))")

        // Ctrl-C inside a question cancels the question and then leaves, drawn or not.
        for drawn in [true, false] {
            var asked = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
            press(&asked, "s")
            if drawn { draw(&asked) }
            expectEqual(asked.handle(.key(.interrupt), at: time), [], "Ctrl-C inside a question starts nothing")
            expect(asked.session == .none && asked.exit?.code == 0, "the start was not confirmed and the screen closed")
        }

        // A signal to the process: the session is asked to stop, and the screen closes.
        var signalled = running()
        expectEqual(signalled.handle(.terminationSignal(15), at: time), [.interruptSession], "SIGTERM forwards one interrupt")
        expectEqual(signalled.exit?.code, 143, "and the status is the signal's")
        expect(signalled.exit?.farewell.first?.contains("process 99") == true, "with a line about the session")
        var signalledBusy = running()
        press(&signalledBusy, "e")
        expectEqual(signalledBusy.handle(.terminationSignal(1), at: time), [.interruptSession], "a signal with an action out still stops the session")
        expectEqual(signalledBusy.exit?.farewell.count, 2, "and names the action too")
        var bare = state()
        expectEqual(bare.handle(.terminationSignal(2), at: time), [], "SIGINT with nothing running")
        expectEqual(bare.exit, .init(code: 130, farewell: []), "closes with the signal's status")
        var closed = running()
        expectEqual(closed.handle(.inputClosed, at: time), [.interruptSession], "a terminal that went away stops the session too")
        expectEqual(closed.exit?.code, 1, "and closes the screen")
    }
}
