import Foundation

/// The wizard's whole behaviour as one function of state and event. It starts
/// nothing itself: it returns the work to do, and the run loop reports each
/// result back as another event. Everything that changes the Mac waits for a
/// key and a `y` on a question that has been on screen long enough to read.
extension ClusterSetupState {
    /// The test request the check sends: short, so the check stays quick.
    static let checkPrompt = "Reply with one short sentence: what is RDMA?"
    static let checkTokens = 8
    static let promptTokens = 128

    /// The first refresh. Call once, before any event.
    public mutating func begin() -> [ClusterSetupEffect] {
        refreshing = true
        return [.refresh]
    }

    /// `time` stamps activity entries; `uptime` is the run loop's clock in nanoseconds.
    public mutating func handle(_ event: ClusterSetupEvent, at time: String, uptime: UInt64 = 0) -> [ClusterSetupEffect] {
        guard exit == nil else { return [] }
        now = max(now, uptime)
        switch event {
        case .key(let key): return handle(key, at: time)
        case .resized(let size):
            self.size = size
            if let question = asking, !ClusterSetupScreen.canShow(question, at: size) {
                withdrawQuestion()
                notice = "The window became too small to show the question, so it was withdrawn. Nothing was changed."
            }
            return []
        case .tick: return tick(at: time)
        case .snapshot(let snapshot): return observed(snapshot, at: time)
        case .peer(let result): return observed(result, at: time)
        case .plans(let result):
            plans = { if case .ready(let options) = result { return .ready(options) }; if case .failed(let reason) = result { return .failed(reason) }; return .notRun }()
            if case .ready(let options) = plans {
                // The first model that can be chosen, unless the one picked still can.
                if !(options.indices.contains(selectedModel) && options[selectedModel].blocker == nil) {
                    selectedModel = options.firstIndex { $0.blocker == nil } ?? 0
                }
            }
            return []
        case .linkFix(let result): return linkFixed(result, at: time)
        case .actionFinished(let action, let result): return finished(action, result, at: time)
        case .sessionObserved(let observation): return sessionObserved(observation, at: time)
        case .session(let event): return handle(event, at: time)
        case .prompt(let event): return handle(event, at: time)
        case .linkPairing(let event): return linkPairingObserved(event, at: time)
        case .terminationSignal(let number): return close(code: 128 + number, at: time)
        case .inputClosed: return close(code: 1, at: time)
        }
    }

    // MARK: - Observations

    private mutating func observed(_ snapshot: ClusterSetupSnapshot, at time: String) -> [ClusterSetupEffect] {
        let first = self.snapshot == nil
        self.snapshot = snapshot
        refreshing = false
        var effects = [ClusterSetupEffect]()
        if refreshQueued {
            refreshQueued = false
            effects += requestRefresh()
        }
        // A question about a setup is good only for the setup it was asked about.
        if case .approveInbox(let expected) = asking, snapshot.local.inbox?.configurationSHA256 != expected {
            withdrawQuestion()
            notice = "The setup in this Mac's inbox changed while its approval was open. Review it again."
        }
        if !resumed {
            resumed = true
            step = firstUnfinished
        } else {
            followFirstUnfinished()
        }
        if first, pair?.canReachPeer == true { effects += reachPeer() }
        effects += checkObserved(snapshotArrived: true, at: time)
        effects += cleanupObserved(snapshotArrived: true)
        effects += entered(step)
        return effects
    }

    private mutating func observed(_ result: ClusterSetupPeerResult, at time: String) -> [ClusterSetupEffect] {
        switch result {
        case .reached(let report, let seconds): peer = .reached(report, seconds: seconds, at: now)
        case .failed(let reason): peer = .failed(reason)
        }
        var effects = checkObserved(peerArrived: true, at: time)
        effects += cleanupObserved(peerArrived: true)
        if followFirstUnfinished() { effects += entered(step) }
        // A plan needs the other Mac's profile: it is made once that arrived.
        if step == .model, plans == .notRun, peerReport != nil, mayPlan, !hasClusterSetup { effects += requestPlans() }
        if replanRequested {
            replanRequested = false
            if step == .model, peerReport != nil, mayPlan { effects += requestPlans() }
        }
        return effects
    }

    /// Before the first key: when a reading finishes the step on screen, the
    /// screen moves on to the first step that is not done. True when it moved.
    @discardableResult
    private mutating func followFirstUnfinished() -> Bool {
        guard followResume, resumed, snapshot != nil, status(of: step) == .done, firstUnfinished != step else { return false }
        step = firstUnfinished
        return true
    }

    /// What entering a step starts by itself: only readings, never a change.
    private mutating func entered(_ step: ClusterSetupStep) -> [ClusterSetupEffect] {
        guard snapshot != nil else { return [] }
        var effects = [ClusterSetupEffect]()
        switch step {
        case .pair, .model, .check:
            if pair?.canReachPeer == true, peer == .unknown { effects += reachPeer() }
            if step == .model, plans == .notRun, peerReport != nil, mayPlan, !hasClusterSetup { effects += requestPlans() }
        case .thisMac, .cable, .serve: break
        }
        return effects
    }

    /// This Mac already saved a setup for this pair: plans are made again only on `r`.
    var hasClusterSetup: Bool { savedSetup != nil && savedSetup?.clusterID == pair?.clusterID }

    /// A plan can be made here: this Mac holds the pair description it plans from, or it leads a pair it paired over
    /// the link (S17), whose other Mac its wizard asks over the paired link, also to plan another model later.
    var mayPlan: Bool {
        pair?.source == .description || (snapshot?.record.pair != nil || linkPaired) && pair?.canReachPeer == true
    }

    private mutating func requestRefresh() -> [ClusterSetupEffect] {
        guard !refreshing else {
            refreshQueued = true
            return []
        }
        refreshing = true
        return [.refresh]
    }

    private mutating func reachPeer() -> [ClusterSetupEffect] {
        guard pair?.canReachPeer == true else { return [] }
        if case .reaching = peer { return [] }
        peer = .reaching(since: now)
        peerPollAt = now
        return [.reachPeer]
    }

    private mutating func requestPlans() -> [ClusterSetupEffect] {
        guard plans != .planning else { return [] }
        plans = .planning
        return [.planModels]
    }

    private mutating func tick(at time: String) -> [ClusterSetupEffect] {
        var effects = [ClusterSetupEffect]()
        guard let snapshot else { return effects }
        // Waiting for a cable: the link is read again until one is in. Nothing else is polled
        // while idle; r reads everything again.
        if step == .cable, snapshot.local.link.state == ClusterLinkReadinessState.noActivePort.rawValue, !refreshing, inFlight == nil,
           linkFix != .applying {
            effects += requestRefresh()
        }
        if session.isActive, !sessionPollInFlight {
            sessionPollInFlight = true
            effects.append(.pollSession)
        }
        if case .running = session, pair?.canReachPeer == true,
           now >= peerPollAt + UInt64(options.peerPollSeconds) * 1_000_000_000 {
            effects += reachPeer()
        }
        if case .running(.cleanup, _) = check, let at = cleanupRereadAt, now >= at, !refreshing {
            cleanupRereadAt = nil
            effects += requestRefresh()
            if pair?.canReachPeer == true { peer = .reaching(since: now); effects.append(.reachPeer) }
        }
        if case .running(.ranks, let since) = check, now >= since + UInt64(options.readyTimeoutSeconds) * 1_000_000_000 {
            effects += failCheck(.ranks, "Both ranks were not ready \(options.readyTimeoutSeconds) s after the start (\(checkReadyRanks) of 2 ranks ready). The session is being stopped; its last output is under Serve.", at: time)
        }
        return effects
    }

    // MARK: - Keys

    private mutating func handle(_ key: ClusterConsoleKey, at time: String) -> [ClusterSetupEffect] {
        // From the first key on, the person decides which step is on screen.
        followResume = false
        resumed = true
        if let question = asking { return answer(question, with: key, at: time) }
        if case .editing(let text) = prompt { return edit(text, key, at: time) }
        if case .enteringAddress(let text) = linkPairing { return editAddress(text, key, at: time) }
        clearNotice()
        switch key {
        case .character("q"), .character("Q"), .interrupt, .endOfInput: return requestQuit(at: time)
        default: if leaving == .confirmStop { leaving = nil }
        }
        switch key {
        case .character("?"): showsHelp.toggle(); scroll = 0
        case .escape:
            showsHelp = false
            leaving = nil
        case .character("r"), .character("R"):
            var effects = requestRefresh()
            // On step 4 the plans are made again from both Macs' memory now, also over a saved setup:
            // the other Mac is read first, and the plans follow its answer.
            if step == .model, mayPlan, plans != .planning { replanRequested = true }
            if step >= .pair { effects += reachPeer() }
            if replanRequested, peerReport != nil { replanRequested = false; effects += requestPlans() }
            return effects
        case .left: return go(to: ClusterSetupStep(rawValue: step.rawValue - 1))
        case .right, .tab: return go(to: ClusterSetupStep(rawValue: step.rawValue + 1))
        case .character(let c) where ("1"..."6").contains(c): return go(to: ClusterSetupStep(rawValue: Int(String(c))! - 1))
        case .up:
            if step == .model, !showsHelp { select(by: -1) } else { scroll(by: -1) }
        case .down:
            if step == .model, !showsHelp { select(by: 1) } else { scroll(by: 1) }
        case .pageUp: scroll(by: -max(1, bodyRows - 1))
        case .pageDown: scroll(by: max(1, bodyRows - 1))
        case .home: scroll = 0
        case .end: scroll = maximumScroll
        case .enter: return primary(at: time)
        case .character(let c): return stepKey(Character(c.lowercased()), at: time)
        case .backspace, .unknown, .interrupt, .endOfInput: break
        }
        return []
    }

    private mutating func go(to target: ClusterSetupStep?) -> [ClusterSetupEffect] {
        guard let target, target != step else { return [] }
        step = target
        scroll = 0
        showsHelp = false
        return entered(target)
    }

    private mutating func select(by offset: Int) {
        guard case .ready(let options) = plans, !options.isEmpty else { return }
        selectedModel = min(max(selectedModel + offset, 0), options.count - 1)
    }

    /// Enter: the step's one action, or the next step once this one is done.
    private mutating func primary(at time: String) -> [ClusterSetupEffect] {
        guard snapshot != nil else {
            say("This Mac's state is still being read.")
            return []
        }
        switch step {
        case .thisMac:
            if status(of: .thisMac) == .blocked { return requestRefresh() }
        case .cable:
            if status(of: .cable) == .todo { return stepKey("f", at: time) }
            if status(of: .cable) != .done { return requestRefresh() }
        case .pair:
            if !pairingConfirmed {
                if pair?.canReachPeer == true, peerReport == nil { return stepKey("p", at: time) }
                // No pair yet: enter pairs over the link (no SSH host-key code in the user path).
                if pair == nil { return linkPaired || linkPairing.running ? requestRefresh() : startLinkPairing(connect: nil) }
                if pairingCode != nil { return askConfirmCode() }
                return requestRefresh()
            }
        case .model:
            if local?.inbox != nil, status(of: .model) == .todo { return stepKey("a", at: time) }
            // A list of plans on screen: enter adopts the one chosen.
            if case .ready = plans, mayPlan { return adopt(at: time) }
            if savedSetup?.isLeader == true, peerHasItsSetup != true, status(of: .model) != .done { return stepKey("p", at: time) }
            if status(of: .model) != .done { return adopt(at: time) }
        case .check:
            if status(of: .check) != .done { return stepKey("c", at: time) }
        case .serve:
            if case .running = session { return stepKey("t", at: time) }
            return stepKey("s", at: time)
        }
        return go(to: ClusterSetupStep(rawValue: step.rawValue + 1))
    }

    /// The keys each step offers, and only on that step.
    private mutating func stepKey(_ key: Character, at time: String) -> [ClusterSetupEffect] {
        switch (step, key) {
        case (.cable, "f"): return requestLinkFix()
        case (.pair, "p"), (.model, "p"), (.check, "p"):
            guard pair?.canReachPeer == true else {
                say("This Mac does not reach the other one: the leader reaches its follower, and this Mac follows.")
                return []
            }
            return reachPeer()
        case (.pair, "y"):
            guard pair != nil else { say("Press l on both Macs to pair over the link."); return [] }
            return askConfirmCode()
        case (.pair, "l"): return startLinkPairing(connect: nil)
        case (.pair, "c"):
            if linkPairing.running { say("The pairing over the link is already running."); return [] }
            if let refusal = changeBlocker("pairing") { say(refusal); return [] }
            linkPairing = .enteringAddress("")
            return []
        case (.model, "a"):
            guard let inbox = local?.inbox else {
                say("No setup is waiting in this Mac's inbox. The leader sends it from its own step 4.")
                return []
            }
            if let refusal = changeBlocker("approving a setup") { say(refusal); return [] }
            if let error = inboxError { say("The setup in the inbox cannot be approved: \(error)"); return [] }
            return ask(.approveInbox(expectedSHA256: inbox.configurationSHA256))
        case (.check, "c"): return requestCheck()
        case (.serve, "s"): return requestStart()
        case (.serve, "x"): return requestStop(at: time)
        case (.serve, "t"):
            guard case .running = session, live?.ready == true else {
                say(session.isActive ? "Wait until both ranks are ready; the test prompt opens then." : "Start serving first with s.")
                return []
            }
            prompt = .editing("")
            return []
        default:
            return []
        }
    }

    /// Why the inbox's setup cannot be approved; nil when it can.
    private var inboxError: String? { local?.inboxError }

    private mutating func askConfirmCode() -> [ClusterSetupEffect] {
        guard let code = pairingCode else {
            say("No pairing code: this Mac could not read the host key it would be computed from.")
            return []
        }
        if pair?.canReachPeer == true, peerReport == nil {
            say("Reach the other Mac first with p: the code is confirmed only after the pinned connection succeeded.")
            return []
        }
        return ask(.confirmCode(code: code.code))
    }

    private mutating func adopt(at time: String) -> [ClusterSetupEffect] {
        guard mayPlan else {
            if savedSetup == nil {
                say("This Mac has no pair description to plan from. Open the wizard on the leader with --pair, or approve the setup it sends here.")
            }
            return []
        }
        guard peerReport != nil else { return reachPeer() }
        guard case .ready(let options) = plans else { return plans == .planning ? [] : requestPlans() }
        guard options.indices.contains(selectedModel) else { return [] }
        let option = options[selectedModel]
        if let blocker = option.blocker {
            say("\(option.model.modelID) cannot be chosen: \(blocker)")
            return []
        }
        guard let plan = option.plan else { return [] }
        if let refusal = changeBlocker("saving a new setup") { say(refusal); return [] }
        if !pairingConfirmed {
            say("Confirm the pairing code in step 3 first: a setup trusts the other Mac's key.")
            return []
        }
        return ask(.adoptPlan(folder: option.model.folder, planKey: Self.planKey(option.model, plan)))
    }

    /// Names one plan, so a question is answered only for the plan it showed.
    static func planKey(_ model: ClusterSetupLocalModel, _ plan: ClusterSetupPlanSummary) -> String {
        "\(model.artifactSHA256.prefix(16)):\(plan.leaderID):\(plan.cut):\(plan.mode)"
    }

    private mutating func requestLinkFix() -> [ClusterSetupEffect] {
        if let refusal = changeBlocker("changing the link") { say(refusal); return [] }
        if linkFix == .previewing || linkFix == .applying { return [] }
        linkFix = .previewing
        return [.linkFix(dryRun: true)]
    }

    private mutating func requestCheck() -> [ClusterSetupEffect] {
        guard let saved = savedSetup else {
            say("There is no saved setup to check yet: finish step 4.")
            return []
        }
        guard saved.isLeader else {
            say("This Mac follows: the leader runs the check, and this Mac's worker takes part in it.")
            return []
        }
        if case .running = check { return [] }
        if session.isActive {
            say("A session from this screen is running. Stop it in step 6 first.")
            return []
        }
        if let refusal = changeBlocker("running the check", allowOwnSession: false) { say(refusal); return [] }
        if saved.overLink == true { say("The other Mac takes part over the paired link: start it there first (its step 6, s).") }
        return ask(.runCheck)
    }

    private mutating func requestStart() -> [ClusterSetupEffect] {
        guard let saved = savedSetup else {
            say("There is no saved setup to start yet: finish step 4.")
            return []
        }
        // A follower reached over the paired link serves its rank itself (no SSH reaches it).
        guard saved.isLeader || saved.overLink == true else {
            say("This Mac follows: the leader starts serving and reaches this Mac itself.")
            return []
        }
        if session.isActive { say("Serving is already started from this screen."); return [] }
        if case .running = check { say("The check is running; it ends by itself in a moment."); return [] }
        if local?.memoryGuard.decision == .refused {
            say("This Mac holds memory an earlier run left wired; a worker refuses to start over it. Restart this Mac first (step 1 says why).")
            return []
        }
        return ask(.startSession)
    }

    /// Why something that changes the link, the setup or the journal cannot
    /// run now; nil when it can. None of them runs beside a session.
    private func changeBlocker(_ what: String, allowOwnSession: Bool = false) -> String? {
        if inFlight != nil { return "\(inFlight!.title) is still being done. Wait for it before \(what)." }
        if session.isActive, !allowOwnSession { return "Serving is running from this screen. Stop it with x in step 6 before \(what)." }
        if case .running = check { return "The check is running. Wait for it before \(what)." }
        if local?.journal == .ownershipUnproven {
            return "This Mac's device journal is not empty: a session may be using it. Stop that session, or run `darkbloom cluster recover`, before \(what)."
        }
        return nil
    }

    // MARK: - Questions

    private mutating func ask(_ question: Question) -> [ClusterSetupEffect] {
        guard ClusterSetupScreen.canShow(question, at: size) else {
            say("The window is too narrow to ask. Widen it to \(ClusterSetupScreen.text(of: question, dryRun: options.dryRun).count) columns and try again.")
            return []
        }
        asking = question
        questionShown = false
        questionShownAt = nil
        return []
    }

    private mutating func withdrawQuestion() {
        asking = nil
        questionShown = false
        questionShownAt = nil
    }

    /// `y` acts, once the question has been on screen long enough to read;
    /// any other key withdraws it and changes nothing.
    private mutating func answer(_ question: Question, with key: ClusterConsoleKey, at time: String) -> [ClusterSetupEffect] {
        if case .confirmLinkCode = question { return answerLinkCode(key, at: time) }
        let yes = key == .character("y") || key == .character("Y")
        if yes {
            let dwell = UInt64(max(options.questionDwellMilliseconds, 0)) * 1_000_000
            guard questionShown, let since = questionShownAt, now >= since, now - since >= dwell else { return [] }
        }
        withdrawQuestion()
        clearNotice()
        if key == .interrupt || key == .endOfInput { return requestQuit(at: time) }
        guard yes else {
            if case .confirmCode = question, key == .character("n") || key == .character("N") {
                notice = "Codes differ: do not continue. The Mac that answered is not the one whose screen you read. Check the cable and the setup's pinned host key, then press p."
            } else {
                notice = "Cancelled. Nothing was changed."
            }
            return []
        }
        switch question {
        case .applyLinkFix:
            if options.dryRun { notice = "Dry run: nothing is applied from this screen."; return [] }
            if let refusal = changeBlocker("changing the link") { notice = refusal; return [] }
            linkFix = .applying
            return [.linkFix(dryRun: false)]
        case .confirmCode(let code):
            inFlight = .recordConfirmation
            return [.recordConfirmation(code: code, clusterID: pair?.clusterID)]
        case .confirmLinkCode:
            return []
        case .adoptPlan(let folder, let key):
            if let refusal = changeBlocker("saving a new setup") { notice = refusal; return [] }
            inFlight = .adoptPlan
            return [.adoptPlan(folder: folder, planKey: key)]
        case .approveInbox(let expected):
            if let refusal = changeBlocker("approving a setup") { notice = refusal; return [] }
            inFlight = .approveInbox
            return [.approveInbox(expectedSHA256: expected)]
        case .runCheck:
            if session.isActive { notice = "A session from this screen is running. Stop it first."; return [] }
            return startCheck(at: time)
        case .startSession:
            if session.isActive { return [] }
            return launch(at: time)
        }
    }

    // MARK: - Pairing over the link (S17)

    /// Starts the ceremony: this Mac listens, or dials the address the other Mac shows.
    private mutating func startLinkPairing(connect: String?) -> [ClusterSetupEffect] {
        if linkPairing.running { say("The pairing over the link is already running."); return [] }
        if let refusal = changeBlocker("pairing") { say(refusal); return [] }
        linkPeerConfirmed = false
        linkPairing = .waiting(connect == nil ? "Looking for the other Mac on the link\u{2026}" : "Dialing the other Mac over the link\u{2026}")
        return [.pairOverLink(connect: connect)]
    }

    /// The other Mac's link address, typed: digits and dots, enter dials, escape cancels.
    private mutating func editAddress(_ text: String, _ key: ClusterConsoleKey, at time: String) -> [ClusterSetupEffect] {
        switch key {
        case .interrupt, .endOfInput:
            linkPairing = .idle
            return requestQuit(at: time)
        case .escape: linkPairing = .idle
        case .backspace: linkPairing = .enteringAddress(String(text.dropLast()))
        case .enter:
            guard Self.isIPv4(text) else { notice = "Type the address the other Mac shows, such as 10.219.4.7."; return [] }
            linkPairing = .idle
            return startLinkPairing(connect: text)
        case .character(let c) where c.isNumber || c == ".":
            if text.count < 15 { linkPairing = .enteringAddress(text + String(c)) }
        case .unknown: notice = "Pasted text is not taken here: type the address."
        default: break
        }
        return []
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isNumber) && (part.count == 1 || part.first != "0") && Int(part).map { $0 <= 255 } == true
        }
    }

    /// Only `y` (after the dwell) or `n` answers the ceremony's code; any other
    /// key leaves the question up, since the other Mac is waiting on this one.
    private mutating func answerLinkCode(_ key: ClusterConsoleKey, at time: String) -> [ClusterSetupEffect] {
        let yes = key == .character("y") || key == .character("Y")
        let no = key == .character("n") || key == .character("N") || key == .interrupt || key == .endOfInput
        if yes {
            let dwell = UInt64(max(options.questionDwellMilliseconds, 0)) * 1_000_000
            guard questionShown, let since = questionShownAt, now >= since, now - since >= dwell else { return [] }
        }
        guard yes || no else { return [] }
        withdrawQuestion()
        clearNotice()
        if yes {
            linkPairing = .confirmedHere(peerConfirmed: linkPeerConfirmed)
            notice = "Confirmed here. Waiting for the other Mac to confirm\u{2026}"
            return [.answerLinkCode(accept: true)]
        }
        notice = "Codes differ or not confirmed: nothing was paired. The Mac that answered over the cable is not trusted."
        var effects: [ClusterSetupEffect] = [.answerLinkCode(accept: false)]
        if key == .interrupt || key == .endOfInput { effects += requestQuit(at: time) }
        return effects
    }

    private mutating func linkPairingObserved(_ event: ClusterSetupLinkPairingEvent, at time: String) -> [ClusterSetupEffect] {
        switch event {
        case .waiting(let text):
            if case .waiting = linkPairing { linkPairing = .waiting(text) }
        case .code(let code, let peer):
            linkPairing = .code(code, peer: peer)
            return ask(.confirmLinkCode(code: code))
        case .peerDecided(let accepted):
            if accepted {
                linkPeerConfirmed = true
                if case .confirmedHere = linkPairing { linkPairing = .confirmedHere(peerConfirmed: true) }
                notice = "The other Mac confirmed the code."
            } else {
                if case .confirmLinkCode = asking { withdrawQuestion() }
                notice = "The other Mac did not confirm the code. Nothing was paired."
            }
        case .finished(let succeeded, let lines):
            if case .confirmLinkCode = asking { withdrawQuestion() }
            linkPairing = .finished(succeeded: succeeded, lines: lines)
            record(.init(time: time, title: "Pairing over the link", failed: !succeeded, lines: lines))
            notice = succeeded ? "Paired over the link. Next: step 4." : (lines.first ?? "The pairing over the link did not finish.")
            return requestRefresh()
        }
        return []
    }

    // MARK: - Prompt box

    private mutating func edit(_ text: String, _ key: ClusterConsoleKey, at time: String) -> [ClusterSetupEffect] {
        switch key {
        case .interrupt, .endOfInput:
            prompt = .closed
            return requestQuit(at: time)
        case .escape:
            prompt = .closed
        case .backspace:
            prompt = .editing(String(text.dropLast()))
        case .enter:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { prompt = .closed; return [] }
            guard case .running = session, live?.ready == true else {
                prompt = .failed(trimmed, reason: "Serving is not ready, so nothing was sent.")
                return []
            }
            prompt = .sending(trimmed, reply: "")
            return [.sendPrompt(text: trimmed, maxTokens: Self.promptTokens)]
        case .character(let c):
            if text.count < Self.promptLimit { prompt = .editing(text + String(c)) }
        case .unknown:
            notice = "Pasted text is not taken here: type the prompt."
        case .tab, .up, .down, .left, .right, .pageUp, .pageDown, .home, .end: break
        }
        return []
    }

    private mutating func handle(_ event: ClusterSetupPromptEvent, at time: String) -> [ClusterSetupEffect] {
        if case .running(.generate, _) = check {
            switch event {
            case .text: return []
            case .finished(let result):
                checkPrompt = result
                guard result.completionTokens > 0 else {
                    return failCheck(.generate, "The test request ended without a token (finish reason \(result.finishReason ?? "none")).", at: time)
                }
                advanceCheck(to: .stop)
                if case .running(let pid, _) = session { session = .stopping(processIdentifier: pid) }
                return [.interruptSession]
            case .failed(let reason):
                return failCheck(.generate, "The test request failed: \(reason)", at: time)
            }
        }
        switch (prompt, event) {
        case (.sending(let text, let reply), .text(let more)):
            prompt = .sending(text, reply: String((reply + more).suffix(Self.replyLimit)))
        case (.sending(let text, let reply), .finished(let result)):
            prompt = .answered(text, reply: reply, result)
            record(.init(time: time, title: "Test prompt", failed: false, lines: [Self.describe(result)]))
        case (.sending(let text, _), .failed(let reason)):
            prompt = .failed(text, reason: reason)
            record(.init(time: time, title: "Test prompt", failed: true, lines: [reason]))
        default: break
        }
        return []
    }

    static func describe(_ result: ClusterSetupPromptResult) -> String {
        var parts = ["\(result.completionTokens) token\(result.completionTokens == 1 ? "" : "s")"]
        if let first = result.firstTokenMilliseconds { parts.append(String(format: "first token %.2f s", Double(first) / 1000)) }
        if let rate = result.tokensPerSecond { parts.append(String(format: "%.1f tok/s", rate)) }
        if let reason = result.finishReason { parts.append("finished: \(reason)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Link fix

    private mutating func linkFixed(_ result: ClusterSetupLinkFixResult, at time: String) -> [ClusterSetupEffect] {
        record(.init(time: time, title: result.dryRun ? "Link fix preview" : "Link fix", failed: !result.succeeded, lines: result.lines))
        if result.dryRun {
            linkFix = .previewed(result)
            // Only a preview with commands to run is offered for approval.
            if result.succeeded, result.outcome == "dryRun", !result.commands.isEmpty, !options.dryRun {
                _ = ask(.applyLinkFix)
            }
            return []
        }
        linkFix = .applied(result)
        return requestRefresh()
    }

    // MARK: - Results

    private mutating func finished(_ action: ClusterSetupAction, _ result: ClusterConsoleActionResult, at time: String) -> [ClusterSetupEffect] {
        if inFlight == action { inFlight = nil }
        record(.init(time: time, title: action.title, failed: !result.succeeded, lines: result.lines))
        if !result.succeeded { notice = result.lines.first.map { "\(action.title) failed: \($0)" } ?? "\(action.title) failed." }
        if leaving == .afterAction { return close(code: 0, at: time) }
        var effects = requestRefresh()
        switch action {
        case .adoptPlan, .approveInbox:
            plans = result.succeeded ? .notRun : plans
            // What to do next, on the other Mac or here, stays on the status line.
            if result.succeeded, action == .adoptPlan, let next = result.lines.last { notice = next }
            if result.succeeded, action == .approveInbox {
                notice = "Saved. Next, on \(pair?.peerMemberID ?? "the leader"): `darkbloom cluster` runs the check and starts serving."
            }
            effects += reachPeer()
        case .recordConfirmation:
            if result.succeeded { notice = "Pairing confirmed. Next: step 4." }
        case .recordCheck: break
        }
        return effects
    }

    // MARK: - Check

    /// The check: the cable on both Macs, a start, both ranks ready, a few
    /// tokens through the local API, a stop, and the memory released on both.
    private mutating func startCheck(at time: String) -> [ClusterSetupEffect] {
        check = .running(.cable, since: now)
        checkReadyRanks = 0
        checkReadySeconds = nil
        checkPrompt = nil
        checkSaw = (false, false)
        sessionOutput.removeAll()
        record(.init(time: time, title: "Check", failed: false, lines: ["Started."]))
        var effects = requestRefresh()
        if pair?.canReachPeer == true {
            peer = .reaching(since: now)
            effects.append(.reachPeer)
        }
        return effects
    }

    private mutating func advanceCheck(to stage: CheckStage) {
        check = .running(stage, since: now)
        cleanupRereadAt = nil
        if stage == .cleanup { checkSaw = (false, false) }
    }

    /// How long after the stop both Macs may take to clear their journals and memory.
    static let cleanupSettleNanoseconds: UInt64 = 20_000_000_000
    static let cleanupRereadNanoseconds: UInt64 = 2_000_000_000

    private mutating func checkObserved(snapshotArrived: Bool = false, peerArrived: Bool = false, at time: String) -> [ClusterSetupEffect] {
        guard case .running(let stage, _) = check, stage == .cable || stage == .cleanup else { return [] }
        if snapshotArrived { checkSaw.snapshot = true }
        if peerArrived { checkSaw.peer = true }
        guard checkSaw.snapshot, checkSaw.peer || pair?.canReachPeer != true else { return [] }
        guard let local else { return [] }
        if stage == .cable {
            guard local.link.ready else {
                return failCheck(.cable, "This Mac's link is not ready (\(local.link.state)). Step 2 says what to do.", at: time)
            }
            guard let report = peerReport else {
                return failCheck(.cable, "The other Mac did not answer over the pinned route. Step 3 says why; press p there to try again.", at: time)
            }
            guard report.link.ready else {
                return failCheck(.cable, "The other Mac's link is not ready (\(report.link.state)). Run `darkbloom cluster` there: its step 2 says what to do.", at: time)
            }
            if local.memoryGuard.decision == .refused {
                return failCheck(.cable, "This Mac holds memory an earlier run left wired, so its worker would refuse to start. Restart this Mac.", at: time)
            }
            if report.memoryGuard.decision == .refused {
                return failCheck(.cable, "The other Mac holds memory an earlier run left wired, so its worker would refuse to start. Restart the other Mac.", at: time)
            }
            wiredBefore = (local.memoryGuard.wiredBytes, report.memoryGuard.wiredBytes)
            advanceCheck(to: .start)
            return launch(at: time)
        }
        // Cleanup: no journal left and wired memory back under the guard on both Macs.
        var problems = [String]()
        if local.journal == .ownershipUnproven { problems.append("this Mac's device journal is not empty") }
        if local.memoryGuard.decision == .refused { problems.append("this Mac holds more wired memory than its idle baseline") }
        if let report = peerReport {
            if report.journal == .ownershipUnproven { problems.append("the other Mac's device journal is not empty") }
            if report.memoryGuard.decision == .refused { problems.append("the other Mac holds more wired memory than its idle baseline") }
        } else if pair?.canReachPeer == true {
            problems.append("the other Mac did not answer, so its memory was not read")
        }
        guard problems.isEmpty else {
            // Each Mac's owner clears its journal and lets go of its memory as its own process ends, which
            // can be a moment after the leader's exit: both are read again until the settle time is over.
            if case .running(_, let since) = check, now < since + Self.cleanupSettleNanoseconds {
                checkSaw = (false, false)
                cleanupRereadAt = now + Self.cleanupRereadNanoseconds
                return []
            }
            return failCheck(.cleanup, "After the stop, " + problems.joined(separator: "; ") + ". `darkbloom cluster recover` clears a stranded journal; memory left wired comes back only with a restart.", at: time)
        }
        let pass = ClusterSetupRecord.CheckPass(configurationSHA256: savedSetup?.configurationSHA256 ?? "", at: time,
            readySeconds: checkReadySeconds ?? 0, firstTokenMilliseconds: checkPrompt?.firstTokenMilliseconds,
            tokensPerSecond: checkPrompt?.tokensPerSecond)
        check = .passed(pass)
        cleanup = cleanupLines()
        record(.init(time: time, title: "Check", failed: false, lines: ["Passed."] + cleanup))
        inFlight = .recordCheck
        return [.recordCheck(pass)]
    }

    private mutating func failCheck(_ stage: CheckStage, _ reason: String, at time: String) -> [ClusterSetupEffect] {
        check = .failed(stage, reason)
        record(.init(time: time, title: "Check", failed: true, lines: [reason]))
        if case .running(let pid, _) = session {
            session = .stopping(processIdentifier: pid)
            return [.interruptSession]
        }
        return []
    }

    // MARK: - Session

    private mutating func launch(at time: String) -> [ClusterSetupEffect] {
        session = .launching
        live = nil
        cleanup = []
        cleanupPending = false
        sessionOutput.removeAll()
        if case .running = check {} else { wiredBefore = (local?.memoryGuard.wiredBytes, peerReport?.memoryGuard.wiredBytes) }
        return [.launchSession]
    }

    private mutating func sessionObserved(_ observation: ClusterSetupLive, at time: String) -> [ClusterSetupEffect] {
        sessionPollInFlight = false
        guard session.isActive else { return [] }
        live = observation
        if case .running(.ranks, let since) = check {
            checkReadyRanks = observation.readyRanks
            if observation.ready, observation.members.count >= 2, observation.readyRanks == observation.members.count {
                checkReadySeconds = Double(now - since) / 1e9
                advanceCheck(to: .generate)
                return [.sendPrompt(text: Self.checkPrompt, maxTokens: Self.checkTokens)]
            }
        }
        return []
    }

    private mutating func requestStop(at time: String) -> [ClusterSetupEffect] {
        switch session {
        case .running(let identifier, _):
            session = .stopping(processIdentifier: identifier)
            prompt = .closed
            record(.init(time: time, title: "Stop", failed: false, lines: ["Asked process \(identifier) to stop with an interrupt; it ends once both Macs released their workers."]))
            return [.interruptSession]
        case .stopping: say("Stop was already asked for. It ends once both Macs have released their workers.")
        case .launching: say("Serving is still being started.")
        case .none, .ended: say("Nothing was started from this screen.")
        }
        return []
    }

    private mutating func handle(_ event: ClusterConsoleSessionEvent, at time: String) -> [ClusterSetupEffect] {
        switch event {
        case .launched(let identifier):
            session = .running(processIdentifier: identifier, since: now)
            record(.init(time: time, title: "Start", failed: false, lines: ["Started `darkbloom start --local --distributed` as process \(identifier)."]))
            if case .running(.start, _) = check { advanceCheck(to: .ranks) }
            return []
        case .launchFailed(let reason):
            session = .ended("could not be started", clean: false)
            record(.init(time: time, title: "Start", failed: true, lines: [reason]))
            if case .running = check { return failCheck(.start, "The session could not be started: \(reason)", at: time) }
            notice = "Serving could not be started: \(reason)"
            return []
        case .output(let line):
            sessionOutput.append(line)
            if sessionOutput.count > Self.sessionOutputLimit { sessionOutput.removeFirst(sessionOutput.count - Self.sessionOutputLimit) }
            return []
        case .ended(let description, let clean):
            session = .ended(description, clean: clean)
            live = nil
            sessionPollInFlight = false
            if case .sending(let text, _) = prompt { prompt = .failed(text, reason: "Serving ended before the reply was complete.") }
            record(.init(time: time, title: "Session ended", failed: !clean, lines: [description] + sessionOutput.suffix(4)))
            var effects = [ClusterSetupEffect]()
            if case .running(let stage, _) = check {
                if stage == .stop, clean {
                    advanceCheck(to: .cleanup)
                    effects += requestRefresh()
                    if pair?.canReachPeer == true { peer = .reaching(since: now); effects.append(.reachPeer) }
                    return effects
                }
                let tail = sessionOutput.suffix(2).joined(separator: " ")
                effects += failCheck(stage, "The session \(description) during “\(stage.title)”." + (tail.isEmpty ? "" : " Its last output: \(tail)"), at: time)
            } else {
                // What a stop leaves behind is read again, not assumed.
                cleanupPending = true
                cleanupSaw = (false, false)
                effects += requestRefresh()
                if pair?.canReachPeer == true { peer = .reaching(since: now); effects.append(.reachPeer) }
            }
            if leaving == .afterSession {
                guard inFlight == nil else { leaving = .afterAction; return effects }
                return effects + close(code: 0, at: time)
            }
            return effects
        }
    }

    private mutating func cleanupObserved(snapshotArrived: Bool = false, peerArrived: Bool = false) -> [ClusterSetupEffect] {
        guard cleanupPending else { return [] }
        if snapshotArrived { cleanupSaw.snapshot = true }
        if peerArrived { cleanupSaw.peer = true }
        guard cleanupSaw.snapshot, cleanupSaw.peer || pair?.canReachPeer != true else { return [] }
        cleanupPending = false
        cleanup = cleanupLines()
        return []
    }

    /// What a stop left on each Mac, in plain words, from fresh readings.
    func cleanupLines() -> [String] {
        var lines = [String]()
        if let local {
            lines.append("This Mac: device journal \(Self.journalWords(local.journal)); " + Self.wiredWords(local.memoryGuard, before: wiredBefore.local))
        }
        if let report = peerReport {
            lines.append("The other Mac: device journal \(Self.journalWords(report.journal)); " + Self.wiredWords(report.memoryGuard, before: wiredBefore.peer))
        } else if pair?.canReachPeer == true {
            lines.append("The other Mac did not answer, so what it holds was not read. Press r to read it again.")
        }
        return lines
    }

    static func journalWords(_ journal: ClusterDeviceJournalObservation) -> String {
        switch journal {
        case .absent, .emptyJournal: return "empty"
        case .ownershipUnproven: return "NOT empty (a worker may still hold the device)"
        case .unsafeOrChanging: return "not safely readable"
        }
    }

    static func wiredWords(_ guardReading: ClusterSetupMemoryGuard, before: Int?) -> String {
        guard let wired = guardReading.wiredBytes else { return "wired memory not read" }
        // One decimal, so that a change of a few hundred megabytes shows.
        let now = ClusterSetupScreen.gibTenths(wired)
        let was = before.map { " (was \(ClusterSetupScreen.gibTenths($0)) before)" } ?? ""
        switch guardReading.decision {
        case .clear: return "wired memory \(now)\(was), under the \(ClusterSetupScreen.gib(guardReading.baselineBytes ?? 0)) idle baseline"
        case .refused: return "wired memory \(now)\(was), ABOVE the \(ClusterSetupScreen.gib(guardReading.baselineBytes ?? 0)) idle baseline with no Darkbloom process running"
        case .skipped: return "wired memory \(now)\(was) (not compared: \(guardReading.detail ?? "another Darkbloom process runs"))"
        }
    }

    // MARK: - Leaving

    private mutating func requestQuit(at time: String) -> [ClusterSetupEffect] {
        switch session {
        case .running(let identifier, _):
            guard leaving == .confirmStop else {
                leaving = .confirmStop
                notice = "Serving runs from this screen (process \(identifier)). Press q again to stop it and close once it has stopped; any other key stays."
                return []
            }
            leaving = .afterSession
            session = .stopping(processIdentifier: identifier)
            return [.interruptSession]
        case .stopping:
            guard leaving == .afterSession else {
                leaving = .afterSession
                notice = "Serving is stopping; the screen closes when it has ended. Press q again to close now; it keeps stopping by itself."
                return []
            }
            return close(code: 0, at: time)
        case .launching:
            notice = "Serving is still being started. Try again in a moment."
            return []
        case .none, .ended:
            break
        }
        if let action = inFlight, leaving != .afterAction {
            leaving = .afterAction
            notice = "\(action.title) is still being done. The screen closes when it reports. Press q again to close now."
            return []
        }
        return close(code: 0, at: time)
    }

    private mutating func close(code: Int32, at time: String) -> [ClusterSetupEffect] {
        var effects = [ClusterSetupEffect](), farewell = [String]()
        switch session {
        case .running(let identifier, _):
            effects = [.interruptSession]
            farewell.append(Self.leftStopping(identifier))
        case .stopping(let identifier):
            farewell.append(Self.leftStopping(identifier))
        case .none, .launching, .ended: break
        }
        if let action = inFlight {
            farewell.append("Closed before “\(action.title.lowercased())” reported. Run `darkbloom cluster` again to see where things are.")
        }
        if linkFix == .applying {
            farewell.append("Closed while the link fix was running. If a macOS prompt is open, answering it completes or cancels the change; `darkbloom cluster link` shows the result.")
        }
        exit = .init(code: code, farewell: farewell)
        return effects
    }

    static func leftStopping(_ identifier: Int32) -> String {
        "Serving started from this screen (process \(identifier)) was asked to stop and is finishing by itself. `darkbloom cluster status` shows it; `darkbloom cluster recover` reports a journal it leaves behind."
    }

    // MARK: - Small helpers

    private mutating func clearNotice() { notice = nil }
    private mutating func say(_ text: String) { notice = text }
    private mutating func scroll(by lines: Int) { scroll = min(max(scroll + lines, 0), max(maximumScroll, 0)) }

    mutating func record(_ entry: ClusterDiagnosticExport.Activity) {
        activity.append(entry)
        if activity.count > Self.activityLimit { activity.removeFirst(activity.count - Self.activityLimit) }
    }
}
