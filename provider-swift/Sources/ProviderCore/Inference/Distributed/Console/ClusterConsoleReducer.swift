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

    /// `time` stamps whatever this event adds to the activity list.
    public mutating func handle(_ event: ClusterConsoleEvent, at time: String) -> [ClusterConsoleEffect] {
        guard exit == nil else { return [] }
        switch event {
        case .key(let key): return handle(key, at: time)
        case .resized(let size):
            self.size = size
            return []
        case .snapshot(let snapshot): return observed(snapshot, at: time)
        case .linkObserved(let report):
            linkPollInFlight = false
            // The wait for a cable ends when the link differs from what is shown.
            guard let shown = snapshot?.link, shown != report else { return [] }
            return requestRefresh()
        case .sessionObserved(let observation):
            sessionPollInFlight = false
            latestStatus = observation.status
            return []
        case .actionFinished(let action, let result): return finished(action, result, at: time)
        case .session(let event): return handle(event, at: time)
        case .tick: return poll()
        case .terminationSignal(let number): return terminate(code: 128 + number, at: time)
        case .inputClosed: return terminate(code: 1, at: time)
        }
    }

    // MARK: - Observations

    private mutating func observed(_ snapshot: ClusterConsoleSnapshot, at time: String) -> [ClusterConsoleEffect] {
        self.snapshot = snapshot
        latestStatus = nil
        refreshing = false
        var effects = [ClusterConsoleEffect]()
        if refreshQueued {
            refreshQueued = false
            effects += requestRefresh()
        }
        // The guided setup's one automatic step. It is spent by the first
        // fix it starts and by the first ready link, so a link that later
        // loses its address never raises a prompt nobody asked for.
        if snapshot.setup.next == .ready { onboardingFixSpent = true }
        if options.onboarding, !onboardingFixSpent, snapshot.setup.next == .fix, inFlight == nil, confirming == nil {
            onboardingFixSpent = true
            inFlight = .fixLink
            effects.append(.fixLink(device: snapshot.setup.fixDevice, dryRun: options.dryRun))
        }
        return effects
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

    private mutating func handle(_ key: ClusterConsoleKey, at time: String) -> [ClusterConsoleEffect] {
        notice = nil
        if let action = confirming {
            confirming = nil
            switch key {
            case .character("y"), .character("Y"): return start(action, at: time)
            case .interrupt, .endOfInput: return requestQuit(at: time)
            default:
                notice = "Cancelled. Nothing was changed."
                return []
            }
        }
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
                if refreshing { notice = "A refresh is already running." }
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

    private mutating func scroll(by lines: Int) { scroll(to: scroll + lines) }
    private mutating func scroll(to line: Int) { scroll = min(max(line, 0), max(maximumScroll, 0)) }

    // MARK: - Actions

    /// Decides whether `action` may start now. An action that cannot start
    /// says why in the notice line and changes nothing else.
    private mutating func request(_ action: ClusterConsoleAction, at time: String) -> [ClusterConsoleEffect] {
        if action == .stopSession { return requestStop(at: time) }
        if let running = inFlight {
            notice = "\(running.title) is still running. Wait for its result before starting another action."
            return []
        }
        guard let snapshot else {
            notice = "This Mac's state is still being read."
            return []
        }
        switch action {
        case .fixLink, .exportDiagnostics:
            return start(action, at: time)
        case .recoverJournal:
            // An empty or absent journal is reported as it is; one that names
            // a session is cleared only after the operator confirms.
            guard status?.deviceJournal == .ownershipUnproven else { return start(action, at: time) }
            confirming = action
        case .approveSetup:
            guard let candidate = snapshot.candidate else {
                notice = "No setup is waiting for approval. Pass one with --input, --capability and --capability-sha256."
                return []
            }
            if let error = candidate.error {
                notice = "The setup passed in cannot be approved: \(error)"
            } else if candidate.alreadySaved {
                notice = "That setup is already the saved one."
            } else {
                confirming = action
            }
        case .startSession:
            if let refusal = startRefusal(snapshot) { notice = refusal } else { confirming = action }
        case .stopSession:
            break
        }
        return []
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
            lines: ["Sent the interrupt to the session (process \(identifier)). It ends when both owners have released their workers."]))
        return [.interruptSession]
    }

    private mutating func start(_ action: ClusterConsoleAction, at time: String) -> [ClusterConsoleEffect] {
        switch action {
        case .fixLink:
            inFlight = action
            return [.fixLink(device: nil, dryRun: options.dryRun)]
        case .recoverJournal:
            inFlight = action
            return [.recoverJournal]
        case .approveSetup:
            inFlight = action
            return [.approveSetup]
        case .exportDiagnostics:
            inFlight = action
            return [.exportDiagnostics]
        case .startSession:
            session = .launching
            sessionOutput.removeAll()
            return [.launchSession]
        case .stopSession:
            return requestStop(at: time)
        }
    }

    private mutating func finished(_ action: ClusterConsoleAction, _ result: ClusterConsoleActionResult,
                                   at time: String) -> [ClusterConsoleEffect] {
        if inFlight == action { inFlight = nil }
        record(.init(time: time, title: action.title, failed: !result.succeeded, lines: result.lines))
        if leaving == .afterAction {
            exit = .init(code: 0, farewell: [])
            return []
        }
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
                exit = .init(code: 0, farewell: [])
                return []
            }
            if leaving == .confirmStop { leaving = nil }
            return requestRefresh()
        }
    }

    // MARK: - Leaving

    private mutating func requestQuit(at time: String) -> [ClusterConsoleEffect] {
        if let action = inFlight {
            guard leaving == .afterAction else {
                leaving = .afterAction
                notice = "\(action.title) is still running. The screen closes when it reports. Press q again to close now, Esc to stay."
                return []
            }
            exit = .init(code: 0, farewell: [action == .fixLink && !options.dryRun
                ? "Closed while the link fix was waiting. If the macOS prompt is still open, answering it completes or cancels the change; `darkbloom cluster link` shows the result."
                : "Closed before \(action.title.lowercased()) reported. Run `darkbloom cluster` again to see the current state."])
            return []
        }
        switch session {
        case .running(let identifier):
            guard leaving == .confirmStop else {
                leaving = .confirmStop
                notice = "This screen started the session (process \(identifier)). Press q again to stop it and close once it has stopped. Any other key stays."
                return []
            }
            leaving = .afterSession
            return interruptSession(identifier, at: time)
        case .stopping(let identifier):
            guard leaving == .closeNow else {
                leaving = .closeNow
                notice = "The session is stopping. The screen closes when it has ended. Press q again to close now; it keeps stopping by itself."
                return []
            }
            exit = .init(code: 0, farewell: [Self.leftStopping(identifier)])
        case .launching:
            notice = "The session is still being started. Try again in a moment."
        case .none, .ended:
            exit = .init(code: 0, farewell: [])
        }
        return []
    }

    /// The process was told to end, or its terminal went away. A session this
    /// screen started is asked to stop, and then stops by itself.
    private mutating func terminate(code: Int32, at time: String) -> [ClusterConsoleEffect] {
        var effects = [ClusterConsoleEffect](), farewell = [String]()
        switch session {
        case .running(let identifier):
            effects = interruptSession(identifier, at: time)
            farewell = [Self.leftStopping(identifier)]
        case .stopping(let identifier):
            farewell = [Self.leftStopping(identifier)]
        case .none, .launching, .ended:
            break
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
