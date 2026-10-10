import Foundation

/// The console's whole behaviour as one function of state and event. It starts
/// nothing itself: it returns the work to do, and the run loop reports each
/// result back as another event. One action runs at a time, and every result
/// that reaches the screen is the operation's own.
extension ClusterConsoleState {
    /// The first refresh. Call once, before any event.
    public mutating func begin() -> [ClusterConsoleEffect] {
        refreshing = true
        return [.refresh]
    }

    /// `time` stamps whatever this event adds to the activity list; `uptime`
    /// is the run loop's clock in nanoseconds, the one `drew` is told.
    public mutating func handle(_ event: ClusterConsoleEvent, at time: String, uptime: UInt64 = 0) -> [ClusterConsoleEffect] {
        guard exit == nil else { return [] }
        switch event {
        case .key(let key): return handle(key, at: time, uptime: uptime)
        case .resized(let size):
            self.size = size
            // A question exists only where all of it can be read.
            if let question = asking, !ClusterConsoleRenderer.canShow(question, at: size) {
                withdrawQuestion()
                notice = "The window became too small to show the question, so it was withdrawn. Nothing was changed."
            }
            return []
        case .snapshot(let snapshot): return observed(snapshot)
        case .linkObserved(let report):
            linkPollInFlight = false
            guard let shown = snapshot?.link else { return [] }
            // The wait for a cable ends when the link differs from what is shown.
            if shown != report { return requestRefresh() }
            return keeperWaited()
        case .sessionObserved(let observation):
            sessionPollInFlight = false
            latestStatus = observation.status
            return []
        case .actionFinished(let action, let result): return finished(action, result, at: time)
        case .session(let event): return handle(event, at: time)
        case .tick: return poll()
        case .terminationSignal(let number): return close(code: 128 + number, at: time)
        case .inputClosed: return close(code: 1, at: time)
        }
    }

    // MARK: - Observations

    private mutating func observed(_ snapshot: ClusterConsoleSnapshot) -> [ClusterConsoleEffect] {
        // The system job's wait is counted over one unchanged link only.
        if snapshot.setup.next != .awaitKeeper || snapshot.link != self.snapshot?.link { keeperReadings = 0 }
        self.snapshot = snapshot
        latestStatus = nil
        refreshing = false
        if noticeEnds == .withRefresh { clearNotice() }
        // A question about a setup is good only for the setup it was asked about.
        if case .approveSetup(let expected) = asking, snapshot.candidate?.configurationSHA256 != expected {
            withdrawQuestion()
            notice = "The setup passed in changed while its approval was open. Review it again."
        }
        var effects = [ClusterConsoleEffect]()
        if refreshQueued {
            refreshQueued = false
            effects += requestRefresh()
        }
        // The guided setup's one automatic step. It stays this screen's only
        // while the flow is waiting for a cable or for the system job; any
        // other reading spends it, so a link that changes hours later never
        // raises a prompt nobody asked for.
        switch snapshot.setup.next {
        case .fix: effects += onboardingFix(device: snapshot.setup.fixDevice)
        case .ready, .stopped: onboardingFixSpent = true
        case .awaitConnection, .awaitKeeper: break
        }
        return effects
    }

    /// Whether the guided setup's fix would be started without a key when
    /// its moment comes: it has not been spent and nothing stands in its way.
    var mayStartLinkFixUnasked: Bool {
        options.onboarding && !onboardingFixSpent && inFlight == nil && asking == nil && blocker(for: .fixLink) == nil
    }

    /// Starts the guided setup's fix if it is still this screen's to start.
    /// Its moment is spent whether or not it could be taken: with something
    /// else running or a session beside it, the fix is the operator's to ask for.
    private mutating func onboardingFix(device: String?) -> [ClusterConsoleEffect] {
        guard options.onboarding, !onboardingFixSpent else { return [] }
        let may = mayStartLinkFixUnasked
        onboardingFixSpent = true
        guard may else { return [] }
        inFlight = .fixLink
        return [.fixLink(device: device, dryRun: options.dryRun)]
    }

    /// One more unchanged reading while the system job was given its chance
    /// to put the address back. After as many as `darkbloom cluster setup`
    /// allows it, the fix that flow would ask for is asked for here.
    private mutating func keeperWaited() -> [ClusterConsoleEffect] {
        guard let snapshot, snapshot.setup.next == .awaitKeeper else { return [] }
        keeperReadings += 1
        guard keeperReadings >= ClusterConsoleLinkSetup.keeperReadings, let device = snapshot.setup.fixDevice else { return [] }
        return onboardingFix(device: device)
    }

    private mutating func requestRefresh() -> [ClusterConsoleEffect] {
        guard !refreshing else {
            refreshQueued = true
            return []
        }
        refreshing = true
        return [.refresh]
    }

    /// Re-runs a probe only where something is being waited for: the link
    /// while it is not ready, the session while this Mac leads a saved
    /// cluster or started a session from here.
    private mutating func poll() -> [ClusterConsoleEffect] {
        guard let snapshot, !refreshing else { return [] }
        var effects = [ClusterConsoleEffect]()
        if snapshot.link.state != .ready, !linkPollInFlight {
            linkPollInFlight = true
            effects.append(.pollLink)
        }
        if session.isActive || snapshot.saved.pairing?.role == .leader, !sessionPollInFlight {
            sessionPollInFlight = true
            effects.append(.pollSession)
        }
        return effects
    }

    // MARK: - Keys

    private mutating func handle(_ key: ClusterConsoleKey, at time: String, uptime: UInt64) -> [ClusterConsoleEffect] {
        if let question = asking { return answer(question, with: key, at: time, uptime: uptime) }
        clearNotice()
        switch key {
        case .character("q"), .character("Q"), .interrupt, .endOfInput:
            return requestQuit(at: time)
        default:
            // Any other key answers "stay" to a question about leaving.
            if leaving == .confirmStop { leaving = nil }
        }
        switch key {
        case .character(let character):
            if let action = ClusterConsoleAction.allCases.first(where: { String($0.key) == character.lowercased() }) {
                return request(action, at: time)
            }
            switch character {
            case "r", "R":
                if refreshing { say("A refresh is already running.", until: .withRefresh) }
                return requestRefresh()
            case "?", "h", "H": showsHelp.toggle()
            case "k": scroll(by: -1)
            case "j": scroll(by: 1)
            case "g": scroll(to: 0)
            case "G": scroll(to: maximumScroll)
            default: break
            }
        case .up: scroll(by: -1)
        case .down: scroll(by: 1)
        case .pageUp: scroll(by: -max(1, bodyRows - 1))
        case .pageDown: scroll(by: max(1, bodyRows - 1))
        case .home: scroll(to: 0)
        case .end: scroll(to: maximumScroll)
        case .escape:
            showsHelp = false
            // Escape answers "stay" to any pending request to close.
            leaving = nil
        case .enter, .tab, .backspace, .left, .right, .unknown, .interrupt, .endOfInput: break
        }
        return []
    }

    /// `y` runs the action; any other key cancels it. A `y` counts only
    /// while the last frame drawn shows the whole question and has shown it
    /// for the dwell time, so one typed or pasted ahead of the question, or
    /// before it could be read, is not an answer to it. What stood in the
    /// action's way when it was asked for is checked again when it is answered.
    private mutating func answer(_ question: Question, with key: ClusterConsoleKey, at time: String,
                                 uptime: UInt64) -> [ClusterConsoleEffect] {
        let yes = key == .character("y") || key == .character("Y")
        if yes {
            let dwell = UInt64(max(options.questionDwellMilliseconds, 0)) * 1_000_000
            guard questionShown, let since = questionShownAt, uptime >= since, uptime - since >= dwell else { return [] }
        }
        withdrawQuestion()
        clearNotice()
        if key == .interrupt || key == .endOfInput { return requestQuit(at: time) }
        guard yes else {
            notice = "Cancelled. Nothing was changed."
            return []
        }
        let refusal: String?
        if question == .startSession { refusal = snapshot.flatMap { startRefusal($0) } } else { refusal = blocker(for: question.action) }
        if let refusal {
            notice = refusal
            return []
        }
        switch question {
        case .approveSetup(let expected):
            inFlight = .approveSetup
            return [.approveSetup(expectedSHA256: expected)]
        case .recoverJournal:
            inFlight = .recoverJournal
            return [.recoverJournal]
        case .startSession:
            session = .launching
            sessionOutput.removeAll()
            return [.launchSession]
        }
    }

    private mutating func ask(_ question: Question) {
        // A question that cannot be read in full is not asked.
        guard ClusterConsoleRenderer.canShow(question, at: size) else {
            notice = "Window too narrow to ask. Widen it to \(ClusterConsoleRenderer.text(of: question).count) columns and press \(question.action.key) again."
            return
        }
        asking = question
        questionShown = false
    }

    private mutating func withdrawQuestion() {
        asking = nil
        questionShown = false
        questionShownAt = nil
    }

    private mutating func clearNotice() {
        notice = nil
        noticeEnds = nil
    }

    /// A notice about something that will stop being true by itself.
    private mutating func say(_ text: String, until end: NoticeEnds) {
        notice = text
        noticeEnds = end
    }

    private mutating func scroll(by lines: Int) { scroll(to: scroll + lines) }
    private mutating func scroll(to line: Int) { scroll = min(max(line, 0), max(maximumScroll, 0)) }

    // MARK: - Actions

    /// Decides whether `action` may start now. An action that cannot start
    /// says why in the notice line and changes nothing else.
    private mutating func request(_ action: ClusterConsoleAction, at time: String) -> [ClusterConsoleEffect] {
        if action == .stopSession { return requestStop(at: time) }
        if let running = inFlight {
            say("\(running.title) is still running. Wait for its result before starting another action.", until: .withAction)
            return []
        }
        guard let snapshot else {
            say("This Mac's state is still being read.", until: .withRefresh)
            return []
        }
        if action == .exportDiagnostics {
            inFlight = action
            return [.exportDiagnostics]
        }
        if action == .startSession {
            if let refusal = startRefusal(snapshot) { notice = refusal } else { ask(.startSession) }
            return []
        }
        if let refusal = blocker(for: action) {
            notice = refusal
            return []
        }
        switch action {
        case .fixLink:
            // The fix decides for itself whether anything needs fixing, and
            // says so. Asked for by key, it is no longer the screen's to start.
            onboardingFixSpent = true
            inFlight = action
            return [.fixLink(device: nil, dryRun: options.dryRun)]
        case .recoverJournal:
            ask(.recoverJournal)
        case .approveSetup:
            guard let candidate = snapshot.candidate else {
                notice = "No setup is waiting for approval. Pass one with --input, --capability and --capability-sha256."
                return []
            }
            if let error = candidate.error {
                notice = "The setup passed in cannot be approved: \(error)"
            } else if let trust = candidate.pairing?.trust, trust.knownHostsPinMatches != true || !trust.identityFileUsable {
                notice = "The setup passed in cannot be approved as it is: its pinned known-hosts file or its identity file does not check out."
            } else if candidate.alreadySaved {
                notice = "That setup is already the saved one."
            } else if let digest = candidate.configurationSHA256 {
                ask(.approveSetup(expectedSHA256: digest))
            }
        case .startSession, .stopSession, .exportDiagnostics:
            break
        }
        return []
    }

    /// Why an action that touches the link, the saved setup or the journal
    /// cannot run now; nil when it can. They are a serving session's own:
    /// none of them is touched while one runs, or may be running.
    private func blocker(for action: ClusterConsoleAction) -> String? {
        let what = action.title.lowercased()
        if session.isActive {
            return "The session this screen started is still there. Stop it with x and wait for it to end before \(what)."
        }
        if status?.live != nil {
            return "A session is serving from another process on this Mac. Stop it where it was started before \(what)."
        }
        // A follower has no status to read; its journal is what shows a session on it.
        if action != .recoverJournal, status?.deviceJournal == .ownershipUnproven {
            return "The device journal is not empty, so a session may be using this Mac. Stop it, or clear a stranded journal with c, before \(what)."
        }
        return nil
    }

    /// Why a start cannot be asked for from this screen right now; nil when
    /// it can. Everything else a start checks is the start command's own to
    /// refuse, and its refusal is shown as it prints it.
    private func startRefusal(_ snapshot: ClusterConsoleSnapshot) -> String? {
        switch session {
        case .launching, .running: return "The session this screen started is already running."
        case .stopping: return "The session this screen started is still stopping."
        case .none, .ended: break
        }
        guard let pairing = snapshot.saved.pairing else {
            return snapshot.saved.state == .unreadable ? "The saved setup cannot be read, so there is nothing to start."
                : "No cluster setup is saved on this Mac, so there is nothing to start."
        }
        guard pairing.role == .leader else { return "This Mac is the follower. The leader starts the session and reaches this Mac itself." }
        if status?.live != nil { return "A session is already serving from another process on this Mac." }
        return nil
    }

    private mutating func requestStop(at time: String) -> [ClusterConsoleEffect] {
        switch session {
        case .running(let identifier): return interruptSession(identifier, at: time)
        case .stopping:
            notice = "Stop was already asked for. The session ends when both owners have released their workers."
        case .launching:
            notice = "The session is still being started."
        case .none, .ended:
            notice = status?.live != nil
                ? "That session was started by another process. Stop it where it was started."
                : "No session was started from this screen."
        }
        return []
    }

    private mutating func interruptSession(_ identifier: Int32, at time: String) -> [ClusterConsoleEffect] {
        session = .stopping(processIdentifier: identifier)
        record(.init(time: time, title: ClusterConsoleAction.stopSession.title, failed: false,
            lines: ["Asked process \(identifier) to stop, with an interrupt. It ends when both owners have released their workers."]))
        return [.interruptSession]
    }

    private mutating func finished(_ action: ClusterConsoleAction, _ result: ClusterConsoleActionResult,
                                   at time: String) -> [ClusterConsoleEffect] {
        if inFlight == action { inFlight = nil }
        if noticeEnds == .withAction { clearNotice() }
        record(.init(time: time, title: action.title, failed: !result.succeeded, lines: result.lines))
        if leaving == .afterAction { return close(code: 0, at: time) }
        // Whatever the action did or did not change is read again, not assumed.
        return requestRefresh()
    }

    // MARK: - Session process

    private mutating func handle(_ event: ClusterConsoleSessionEvent, at time: String) -> [ClusterConsoleEffect] {
        switch event {
        case .launched(let identifier):
            session = .running(processIdentifier: identifier)
            record(.init(time: time, title: ClusterConsoleAction.startSession.title, failed: false,
                lines: ["Started `darkbloom start --local --distributed` as process \(identifier)."]))
            return []
        case .launchFailed(let reason):
            session = .ended("could not be started")
            record(.init(time: time, title: ClusterConsoleAction.startSession.title, failed: true, lines: [reason]))
            return []
        case .output(let line):
            sessionOutput.append(line)
            if sessionOutput.count > Self.sessionOutputLimit {
                sessionOutput.removeFirst(sessionOutput.count - Self.sessionOutputLimit)
            }
            return []
        case .ended(let description, let clean):
            session = .ended(description)
            record(.init(time: time, title: "Session ended", failed: !clean, lines: [description] + sessionOutput.suffix(6)))
            if leaving == .afterSession || leaving == .closeNow {
                // An action still out is waited for like any other.
                guard inFlight == nil else {
                    leaving = .afterAction
                    return []
                }
                return close(code: 0, at: time)
            }
            if leaving == .confirmStop { leaving = nil }
            return requestRefresh()
        }
    }

    // MARK: - Leaving

    /// A session this screen started comes first: it is stopped and waited
    /// for, never left running unasked. Then an action in flight is waited
    /// for. A second request skips the wait, and says what is left behind.
    private mutating func requestQuit(at time: String) -> [ClusterConsoleEffect] {
        switch session {
        case .running(let identifier):
            guard leaving == .confirmStop else {
                leaving = .confirmStop
                notice = "This screen started the session (process \(identifier)). Press q again to stop it and close once it has stopped. Any other key stays."
                return []
            }
            leaving = .afterSession
            return interruptSession(identifier, at: time)
        case .stopping:
            guard leaving == .closeNow else {
                leaving = .closeNow
                notice = "The session is stopping. The screen closes when it has ended. Press q again to close now; it keeps stopping by itself."
                return []
            }
            return close(code: 0, at: time)
        case .launching:
            notice = "The session is still being started. Try again in a moment."
            return []
        case .none, .ended:
            break
        }
        if let action = inFlight, leaving != .afterAction {
            leaving = .afterAction
            notice = "\(action.title) is still running. The screen closes when it reports. Press q again to close now, Esc to stay."
            return []
        }
        return close(code: 0, at: time)
    }

    /// The one way the screen ends. A session this screen started and has not
    /// yet asked to stop is asked now, and whatever is left running is named
    /// on the restored terminal.
    private mutating func close(code: Int32, at time: String) -> [ClusterConsoleEffect] {
        var effects = [ClusterConsoleEffect](), farewell = [String]()
        switch session {
        case .running(let identifier):
            effects = interruptSession(identifier, at: time)
            farewell.append(Self.leftStopping(identifier))
        case .stopping(let identifier):
            farewell.append(Self.leftStopping(identifier))
        case .none, .launching, .ended:
            break
        }
        if let action = inFlight {
            farewell.append(action == .fixLink && !options.dryRun
                ? "Closed while the link fix was running. If a macOS prompt is open, answering it completes or cancels the change; `darkbloom cluster link` shows the result."
                : "Closed before \(action.title.lowercased()) reported. Run `darkbloom cluster` again to see the current state.")
        }
        exit = .init(code: code, farewell: farewell)
        return effects
    }

    private static func leftStopping(_ identifier: Int32) -> String {
        "The session this screen started (process \(identifier)) was asked to stop and is finishing by itself. `darkbloom cluster status` shows it; `darkbloom cluster recover` reports a journal it leaves behind."
    }

    private mutating func record(_ entry: ClusterDiagnosticExport.Activity) {
        activity.append(entry)
        if activity.count > Self.activityLimit { activity.removeFirst(activity.count - Self.activityLimit) }
    }
}
