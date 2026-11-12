import Foundation

// The Mac that joined keeps its window open through the first setup's start (owner, 2026-11-04: "especially if things
// dont work, it before just ended the tui on both machines which seems odd"). It follows the start from the cluster's
// status the services exchange over the cable (the leading Mac's `localStatus`, the status this Mac shows after setup
// too) and ends with the same ✓/✗ block. Pure (Foundation only): the onboarding checks compile it with plain swiftc.

/// How long the Mac that joined follows the start on its own screen.
public struct ClusterOnboardingFollowTiming: Sendable {
    /// The bound, as the leader's start waits for the pair (`OnboardingLive.pairServingSeconds`): for the leader to
    /// start, then for each stage of the start (`followStage`), each with the whole bound again.
    public var seconds: Double
    /// Between two looks at the cluster's status over the cable.
    public var pollSeconds: Double
    public init(seconds: Double = 900, pollSeconds: Double = 1) {
        self.seconds = seconds; self.pollSeconds = pollSeconds
    }
}

extension ClusterOnboardingDriver {
    /// What the Mac that joined waits for, the Mac that leads named as pairing showed it.
    public static func waitingForStartLine(_ leader: String?) -> String {
        "Waiting for \(ClusterOnboardingMacName.other(named: leader)) to choose the model and start\u{2026}"
    }

    /// Under the ✗ on the Mac that joined when a test request failed: the leading Mac's screen ends the same way
    /// ("Setup saved, but the test failed. To test again, …"), with no choices.
    public static func testAgainOnLeaderLine(_ leader: String?) -> String {
        "To test again, run `darkbloom cluster` on \(ClusterOnboardingMacName.other(named: leader)) and choose the model it serves."
    }

    /// Under the ✗ on the Mac that joined: the choices are on the leading Mac's screen.
    public static func retryOnLeaderLine(_ leader: String?) -> String {
        "Choose Retry on \(ClusterOnboardingMacName.other(named: leader)): its screen shows the choices."
    }

    /// q while the Mac that joined follows the start: nothing stops.
    public static let followLeftLine = "The pair keeps going; run `darkbloom cluster` here to see it."

    /// Nothing started on the leading Mac within the bound: the ✗ block's reason.
    public static func notStartedReason(_ leader: String?, seconds: Double) -> String {
        "\(ClusterOnboardingMacName.sentence(ClusterOnboardingMacName.other(named: leader))) didn't start a model within "
            + "\(minutes(seconds)) minutes"
    }

    /// Under that ✗: what the leading Mac was last seen doing, then what to do on it and how to check both builds.
    public static func notStartedLines(_ leader: String?, step: ClusterOnboardingLeaderStep?, status: String?) -> [String] {
        let other = ClusterOnboardingMacName.other(named: leader)
        return (step?.words.map { ["Last: " + $0 + "."] } ?? status.map { ["Last: " + $0 + "."] } ?? [])
            + ["On \(other): look at its screen and answer what it asks (Allow, the model list, a login), or run `darkbloom cluster` there again.",
               "If it still doesn't start, run `darkbloom --version` on both Macs; if they differ, run `darkbloom update` on the one that's behind."]
    }

    /// After the version split's ✗ on the Mac that joined.
    static func versionSplitAfterLine(_ leader: String?) -> String {
        ClusterOnboardingCommand.named("Once both Macs run the same version, run `darkbloom cluster` on \(ClusterOnboardingMacName.other(named: leader)) again; this Mac follows it by itself.")
    }

    /// After that block: nothing stops here.
    public static let notStartedAfterLine = "When it starts, this Mac runs its part by itself; run `darkbloom cluster` here to see it."

    /// The ✗ when the leading Mac refused every model because the two Macs run different builds: both versions when
    /// known, and which Mac to update when that can be told.
    public static func differentBuildsLines(_ leader: String?, thisVersion: String?, leaderVersion: String?) -> [String] {
        let other = ClusterOnboardingMacName.other(named: leader)
        var lines = [String]()
        if let thisVersion, let leaderVersion {
            lines.append("This Mac runs Darkbloom \(thisVersion); \(other) runs \(leaderVersion).")
        }
        let behindHere = thisVersion.flatMap { mine in leaderVersion.flatMap { ClusterOnboardingLeaderStep.isOlder(mine, than: $0) } }
        let behindThere = thisVersion.flatMap { mine in leaderVersion.flatMap { ClusterOnboardingLeaderStep.isOlder($0, than: mine) } }
        if behindHere == true {
            lines.append("On this Mac, run `darkbloom update`.")
        } else if behindThere == true {
            lines.append("On \(other), run `darkbloom update`.")
        } else {
            lines.append("Run `darkbloom --version` on both Macs, and `darkbloom update` on the one that's behind.")
        }
        lines.append("Then run `darkbloom cluster` on \(other) again; this Mac follows it by itself.")
        return lines
    }

    /// The title of that ✗ (the leading Mac's screen ends with the same).
    public static let differentBuildsTitle = ClusterOnboardingNotServing.title(reason: "The two Macs run different Darkbloom builds")

    /// The live line while the Mac that joined waits for the leading Mac to start: whom it waits for and what that Mac
    /// waits on (its published step; an older leader's generic words), then how long of the bound. Fitted to `width`
    /// columns (nil: whole) by dropping, in order, the key, the hardware name, the long words and the step, so a redraw
    /// never wraps.
    public static func followWaitingLine(_ leader: String?, step: ClusterOnboardingLeaderStep?, waited: Double, bound: Double,
                                         width: Int?) -> String {
        let named = ClusterOnboardingMacName.other(named: leader), plain = ClusterOnboardingMacName.other
        let time = " \u{00B7} " + waitedWords(waited, of: bound)
        func line(_ mac: String, _ doing: String?, generic: String) -> String {
            "Waiting for \(mac)" + (doing.map { ": " + $0 } ?? generic)
        }
        let long = line(named, step?.words, generic: " to choose the model and start")
        return fitted([long + time + " (q leaves)", long + time,
                       line(plain, step?.words, generic: " to choose the model and start") + time,
                       line(plain, step?.shortWords, generic: " to start") + time,
                       "Waiting for \(plain)" + time, "Waiting" + time], width: width)
    }

    /// "40 s of 15 min", "2 of 15 min".
    static func waitedWords(_ waited: Double, of bound: Double) -> String {
        let whole = max(0, Int(waited.rounded(.down)))
        return (whole < 60 ? "\(whole) s" : "\(whole / 60)") + " of \(minutes(bound)) min"
    }

    /// The first of `candidates` that fits `width` columns, else the last one cut to it.
    static func fitted(_ candidates: [String], width: Int?) -> String {
        guard let width else { return candidates.first ?? "" }
        return candidates.first { $0.count <= width } ?? String((candidates.last ?? "").prefix(max(1, width)))
    }

    /// Where the start stands, from the cluster's status as the leading Mac writes it (`OnboardingLive.localStatus`).
    enum FollowedStart: Equatable {
        /// Before the leader started (its status says Stopped), or a status that tells nothing yet.
        case notStarted
        /// Loading, starting, registering both Macs with the coordinator, or serving while the leader's start still asks
        /// Darkbloom whether to offer the pair (its serving line says so, `offerPendingWords`): the start is not over.
        case starting
        /// Serving, as the start's outcome.
        case serving
        /// Offered to Darkbloom and not serving yet: the pair's own wait decides, as on the leading Mac (`pairServing`).
        case offered
        /// The start's test request failed (the leader's note under its not-serving line): the start's outcome.
        case testFailed
        /// Set to serve through Darkbloom, but not offered (`ClusterOnboardingReady.notOfferedReason`): the start's outcome,
        /// never a wait for a coordinator that doesn't have the pair.
        case notOffered
        /// Single-Mac serving blocks the pair (`ClusterOnboardingSoloServing`): never a wait for the coordinator (0.10.9
        /// DevNet, pair-2: this window said "registering with the coordinator" for minutes while its own part waited).
        case soloBlocked
    }

    static func followed(_ status: [String]) -> FollowedStart {
        guard let first = status.first else { return .notStarted }
        if first.hasPrefix("Serving ") { return first.contains(ClusterOnboardingReady.offerPendingWords) ? .starting : .serving }
        if let reason = ClusterOnboardingNotServing.reason(inStatusLine: first) {
            if ClusterOnboardingSoloServing.isBlock(reason) { return .soloBlocked }
            if status.dropFirst().contains(where: ClusterOnboardingReady.isTestFailedNote) { return .testFailed }
            return ClusterOnboardingReady.isNotOffered(reason) ? .notOffered : .offered
        }
        let starting = first.hasPrefix("Loading ") || first.hasPrefix("Starting ") || first.contains(": registering both Macs")
        return starting ? .starting : .notStarted
    }

    /// The stage of the leader's start that `status` shows, after `stage`: 1 loading or starting, 2 its test and check
    /// with Darkbloom, 3 anything after that check (the registration's stop and restart), 4 offered and waiting to serve. Never back, so a status that
    /// goes back and forth inside one stage never starts its bound again.
    static func followStage(_ status: [String], after stage: Int) -> Int {
        guard let first = status.first else { return stage }
        // Offered and not serving yet: the pair's own wait, with the whole bound as on the leading Mac (`pairServing`).
        if followed(status) == .offered { return max(stage, 4) }
        if first.contains(ClusterOnboardingReady.offerPendingWords) { return max(stage, 2) }
        if stage >= 2 { return 3 }
        return followed(status) == .starting ? max(stage, 1) : stage
    }

    /// In the serving line of the pair the coordinator formed (`ClusterOnboardingReady.pairServingLine`).
    static let pairServedMarker = " through Darkbloom on both Macs"

    /// The Mac that joined, once paired: waits for the Mac that leads to start, follows the start, and ends with the same
    /// ✓/✗ block as that Mac's screen. Bounded as the leader's start; q leaves (the pair keeps going). Never silent: the
    /// live line says what the leading Mac waits on and how long of the bound, and each new state is said once, so a
    /// plain transcript has it too.
    static func followStart(leader: String?, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        let timing = operations.followTiming
        console.say("  " + waitingForStartLine(leader))
        let looks = ClusterOnboardingMailbox<ClusterOnboardingLeaderStatus>()
        // Single-Mac serving on either Mac, read before each look of the leading Mac: this Mac's own block wins over the
        // leader's progress or step, and is said here as on the leading Mac's screen.
        let solos = ClusterOnboardingMailbox<[ClusterOnboardingSoloServing]>()
        var soloShown: [ClusterOnboardingSoloServing]?
        var asking = false, asked = Date.distantPast
        var begun = Date()
        var started: Date?, latest: String?, stage = 0, step: ClusterOnboardingLeaderStep?, lastStatus: String?
        // Each line once: a status that goes back and forth between two lines never repeats them.
        var said = Set<String>(), saidBlocked = false
        // Offered to Darkbloom and not serving yet: why, as the leading Mac's status says it. Every such reason may clear
        // by itself (Apple's verification, the coordinator's pairing), so this Mac waits for the leading Mac's outcome.
        var offeredWait: String?, saidOffered = false
        // A ✗ the leading Mac published counts for 30 minutes and outlives a pairing; its new screen's first step clears
        // it. Until this Mac saw a step of that screen, a ✗ is an earlier start's, never this one's outcome.
        var screenSeen = false
        // The start's progress as the leading Mac publishes it (`ClusterOnboardingStartProgress`): its own heading, then
        // its step, a bar of the real bytes and each Mac's part as the live rows; each step done said once. Its time
        // counts from when this Mac first saw the step (the two Macs' clocks may differ).
        var start: ClusterOnboardingStartProgress?, startHeading = false, stepSeen = Date(), lastBytes: Int64?
        var startLog = ClusterOnboardingStartLog(viewerLeads: false, viewerRank: operations.thisRank())
        let darkbloom = operations.servesThroughDarkbloom()
        func sayOnce(_ line: String) {
            guard said.insert(line).inserted else { return }
            console.settle()
            console.say(line)
        }
        // The two Macs' versions, read on the looks' cadence: a split never clears by itself, so the wait ends at once.
        let splits = ClusterOnboardingMailbox<ClusterOnboardingVersionSplit?>()
        var splitAsking = false, splitAsked = Date.distantPast
        // A stop a person asked for since the start began, by the leading Mac's count, never by its status' words. The start
        // began at its first step on the leading Mac (`ClusterOnboardingLeaderStep.startBegun`), as that Mac counts from
        // there too, or at its first progress or started status.
        var stops = ClusterOnboardingFollowedStop(), startBegan = false
        while true {
            if !splitAsking, Date().timeIntervalSince(splitAsked) >= timing.pollSeconds {
                (splitAsking, splitAsked) = (true, Date())
                Thread.detachNewThread { splits.post(operations.versionSplit()) }
            }
            if let read = splits.take().last {
                splitAsking = false
                if let split = read {
                    console.settle()
                    console.result(false, split.title + ".", split.remedies)
                    console.say("  " + versionSplitAfterLine(leader))
                    console.waitForExit()
                    return 1
                }
            }
            if !asking, Date().timeIntervalSince(asked) >= timing.pollSeconds {
                asking = true
                asked = Date()
                Thread.detachNewThread {
                    solos.post(operations.soloServing())
                    looks.post(operations.leaderStatus?() ?? .init(lines: operations.status(), step: nil))
                }
            }
            if let solo = solos.take().last {
                if !solo.isEmpty, solo != soloShown {
                    soloShown = solo
                    console.settle()
                    console.result(false, ClusterOnboardingSoloServing.title(solo) + ".",
                                   ClusterOnboardingSoloServing.remedies(solo) + [ClusterOnboardingSoloServing.leaderOffersLine(leader)])
                } else if solo.isEmpty, soloShown != nil {
                    soloShown = nil
                    console.settle()
                    console.say("  " + ClusterOnboardingSoloServing.followClearedLine)
                }
            }
            // Nothing starts while it runs, so no bound runs out meanwhile: each bound starts again once it stopped.
            if soloShown != nil { begun = Date(); if started != nil { started = Date() } }
            if let look = looks.take().last {
                asking = false
                let status = look.lines
                step = look.step
                if step != nil { screenSeen = true }
                let current = look.start.flatMap { $0.phase == .failed && !screenSeen ? nil : $0 }
                if let published = current, published.phase != .unknown {
                    if !startHeading {
                        startHeading = true
                        console.settle()
                        console.heading("4/4 Start")
                    }
                    // A new step has the whole bound again, and a copy that moves is no silence.
                    if published.phase != start?.phase { stepSeen = Date(); if started != nil { started = Date() } else { begun = Date() } }
                    if let done = published.done, done != lastBytes { lastBytes = done; if started == nil { begun = Date() } }
                    start = published
                    for line in startLog.update(published, now: Date().timeIntervalSince1970, plain: console.liveWidth == nil) {
                        console.settle()
                        console.say("  " + line)
                    }
                }
                if let first = status.first { lastStatus = first.hasSuffix(".") ? String(first.dropLast()) : first }
                // The leading Mac's start ended with ✗ on its screen: the same ✗, in its words, and where its choices are.
                if let ended = current, ended.phase == .failed {
                    console.settle()
                    return followFailed(ended.viewed(leader: leader), leader: leader, console)
                }
                // The leading Mac refused every model and its window ended: nothing will start, so the same ✗ now.
                if let refused = step, refused.kind == .refused {
                    console.settle()
                    return followRefused(refused, leader: leader, thisVersion: operations.thisVersion, console)
                }
                let seen = followed(status)
                if started == nil, seen != .notStarted { started = Date() }
                // A stop from anywhere once the start began ends the wait at once, as on the leading Mac. Its status
                // reading "Stopped" is none: it reads so through a download or copy of the model, until both parts start,
                // and while the start stops them to register.
                startBegan = startBegan || started != nil || start != nil || step?.startBegun == true
                if stops.look(look.stopsAsked, begun: startBegan) {
                    console.settle()
                    console.say(ClusterOnboardingCommand.named(ClusterOnboardingStopped.line))
                    return 1
                }
                // Each stage has the whole bound, as on the leading Mac (its load, its test and check, its restart).
                let next = followStage(status, after: stage)
                if started != nil, next > stage { stage = next; started = Date() }
                if started != nil, let first = status.first { latest = first.hasSuffix(".") ? String(first.dropLast()) : first }
                // macOS keeps this Mac's follower off the local network (the probe passed, the dial didn't): said once,
                // plainly; the start goes on by itself once it's on (P2-1).
                if !saidBlocked, operations.localNetwork(.service) == .blocked {
                    saidBlocked = true
                    console.settle()
                    for line in localNetworkBlockedLines(app: ClusterOnboardingCommand.app) { console.say("  " + line) }
                }
                // What the leading Mac waits on before its start, once per step.
                if started == nil, let words = step?.words {
                    sayOnce("  " + ClusterOnboardingMacName.sentence(ClusterOnboardingMacName.other(named: leader)) + ": " + words + ".")
                }
                // Each new state of the leader's start, as lines a plain window shows too, and where to choose Retry when a
                // part keeps ending there (P2-7: this window showed nothing while the leader sat at ✗).
                // The start's own rows say it where the leading Mac publishes them.
                if let latest, seen == .starting, start == nil || console.liveWidth == nil {
                    sayOnce("  The other Mac: " + latest + ".")
                }
                switch soloShown == nil ? seen : .soloBlocked {
                case .soloBlocked:
                    break
                case .serving:
                    console.settle()
                    return followServed(status, leader: leader, operations, console)
                case .offered:
                    if !saidOffered, let first = status.first {
                        saidOffered = true
                        let model = first.components(separatedBy: ClusterOnboardingNotServing.statusMarker).first ?? "the model"
                        console.settle()
                        console.say("  " + ClusterOnboardingReady.offeredLine(model: model))
                    }
                    offeredWait = status.first.flatMap(ClusterOnboardingNotServing.reason(inStatusLine:)).map(offeredWaitingWords)
                    if let offeredWait, console.liveWidth == nil { sayOnce("  " + offeredWait + ".") }
                case .testFailed:
                    console.settle()
                    return followTestFailed(status, leader: leader, console)
                case .notOffered where current != nil:
                    // R7-1 (DevNet branch.87): the leading Mac's status says "not offered" between its local test and the
                    // registration that starts both parts again as cluster members. While it still publishes its start's
                    // step the start is not over: this Mac follows it, and the leading Mac's own ✗ (`failed`) ends it. The
                    // step is `current`, filtered: an earlier start's ✗ still published is no start running.
                    offeredWait = nil
                case .notOffered:
                    // The leading Mac's ✗, in its words: why, and where the pair answers meanwhile.
                    console.settle()
                    _ = showOutcome(status, console)
                    console.say(retryOnLeaderLine(leader))
                    return 1
                case .starting, .notStarted:
                    offeredWait = nil
                }
            }
            if let started, Date().timeIntervalSince(started) >= timing.seconds {
                console.settle()
                console.result(false, ClusterOnboardingNotServing.title(reason: noOutcomeReason(leader, seconds: timing.seconds)),
                               (latest.map { ["Last: " + $0 + "."] } ?? []) + [noOutcomeLine])
                console.waitForExit()
                return 1
            }
            if started == nil, Date().timeIntervalSince(begun) >= timing.seconds {
                console.settle()
                console.result(false, ClusterOnboardingNotServing.title(reason: notStartedReason(leader, seconds: timing.seconds)),
                               notStartedLines(leader, step: step, status: lastStatus))
                console.say(notStartedAfterLine)
                return 1
            }
            if soloShown != nil {
                console.progress({ _ in ClusterOnboardingSoloServing.followWaitingLine }, logged: false)
            } else if let offeredWait, let started {
                let waited = Date().timeIntervalSince(started)
                console.progress({ width in fitted([offeredWait + " \u{00B7} " + waitedWords(waited, of: timing.seconds) + " (q leaves)",
                                                    offeredWait + " \u{00B7} " + waitedWords(waited, of: timing.seconds)], width: width) },
                                 logged: false)
            } else if let start, let width = console.liveWidth {
                console.workingRows(ClusterOnboardingStartWords.liveRows(start, viewerLeads: false, viewerRank: operations.thisRank(),
                    darkbloom: darkbloom, elapsed: Date().timeIntervalSince(stepSeen), width: width))
            } else if let started, let latest {
                let waited = ClusterOnboardingLoadRows.elapsed(Date().timeIntervalSince(started))
                console.progress({ width in fitted([latest + " \u{00B7} " + waited + " (q leaves)", latest + " \u{00B7} " + waited], width: width) },
                                 logged: false)
            } else {
                let (waited, shown) = (Date().timeIntervalSince(begun), step)
                console.progress({ width in followWaitingLine(leader, step: shown, waited: waited, bound: timing.seconds, width: width) },
                                 logged: false)
            }
            if let key = console.key(milliseconds: 120), leaves(key) { return leftFollow(operations, console) }
            if console.closed { usleep(120_000) }
        }
    }

    /// The leading Mac refused every model (its window ended with the same ✗): why, and the next step on both Macs.
    static func followRefused(_ step: ClusterOnboardingLeaderStep, leader: String?, thisVersion: String?,
                              _ console: ClusterOnboardingConsole) -> Int32 {
        if step.differentBuilds {
            console.result(false, differentBuildsTitle, differentBuildsLines(leader, thisVersion: thisVersion, leaderVersion: step.version))
            console.waitForExit()
            return 1
        }
        let other = ClusterOnboardingMacName.other(named: leader)
        let reason = (step.reason ?? "no approved model can run on these Macs now").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        console.result(false, ClusterOnboardingNotServing.title(reason: ClusterOnboardingMacName.sentence(other) + " can't start a model: " + reason),
                       ["Its screen says why. Once that is fixed, run `darkbloom cluster` on \(other) again; this Mac follows it by itself."])
        console.waitForExit()
        return 1
    }

    /// q or escape.
    static func leaves(_ key: Character) -> Bool { key == "q" || key == "Q" || key == "\u{1B}" || key == "\u{03}" }

    static func leftFollow(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        console.settle()
        console.say(followLeftLine + (operations.serviceOutlivesWindow() ? "" : " " + keepWindowLine))
        return 0
    }

    /// Serving: the outcome block from the status, after a test request through the pair when it serves on the leading
    /// Mac's API (the pair the coordinator formed answered its own first request already).
    static func followServed(_ status: [String], leader: String?, _ operations: ClusterOnboardingOperations,
                             _ console: ClusterOnboardingConsole) -> Int32 {
        var shown = status
        // The leading Mac published its start's passing test: the same ✓ and time, and no test of this Mac's own, which
        // could fail where the leader's passed. Only a leader that publishes nothing (an older build) leaves it to this Mac.
        let published = status.dropFirst().contains { $0.hasSuffix(ClusterOnboardingReady.startTestPassedMarker) }
        if !published, status.first?.contains(pairServedMarker) != true {
            switch busy(console, "Sending a test request", operations.testRequest) {
            case .success(let lines): shown.append("Test response" + (lines.first.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""))
            case .failure(let failure):
                let first = failure.lines.first ?? "The test request failed"
                console.result(false, ClusterOnboardingNotServing.title(reason: first.hasSuffix(".") ? String(first.dropLast()) : first),
                               Array(failure.lines.dropFirst()))
                console.say(testAgainOnLeaderLine(leader))
                console.waitForExit()
                return 1
            }
        }
        // The leading Mac's ending, as its status says it; a line from an older leader that it can't read, as before.
        guard let title = shown.first.flatMap(ClusterOnboardingReady.endingTitle(inStatusLine:)) else {
            _ = showOutcome(shown, console)
            return followServedEnd(operations, console)
        }
        return servedEnding(title, operations, console)
    }

    /// The leading Mac's start ended with a failed test (`ClusterSetupRecord.startTestFailure`): the same ✗ and reason
    /// as its screen, and no test of this Mac's own, which could pass and claim the ✓ the leader did not.
    static func followTestFailed(_ status: [String], leader: String?, _ console: ClusterOnboardingConsole) -> Int32 {
        let reason = status.first.flatMap(ClusterOnboardingNotServing.reason(inStatusLine:)) ?? "The test request failed"
        let note = status.dropFirst().first(where: ClusterOnboardingReady.isTestFailedNote) ?? ClusterOnboardingReady.testFailedNote
        console.result(false, ClusterOnboardingNotServing.title(reason: reason), [note])
        console.say(testAgainOnLeaderLine(leader))
        console.waitForExit()
        return 1
    }

    /// The leading Mac's start ended with ✗ (`ClusterOnboardingStartProgress.failed`, named from this Mac): its title and
    /// lines, then where its choices are when its screen offers Retry.
    static func followFailed(_ ended: ClusterOnboardingStartProgress, leader: String?, _ console: ClusterOnboardingConsole) -> Int32 {
        console.result(false, ended.title ?? ClusterOnboardingNotServing.title(reason: "the start ended"), ended.lines ?? [])
        if ended.retry == true { console.say(retryOnLeaderLine(leader)) }
        console.waitForExit()
        return 1
    }

    /// What this Mac waits for while the pair is offered to Darkbloom and not serving yet: a reason the leading Mac's
    /// status gives, which clears by itself or ends in the leading Mac's ✗.
    static func offeredWaitingWords(_ reason: String) -> String {
        // Apple's check of new parts, going as usual: said as it is ("Checking both Macs with Apple").
        if ClusterOnboardingAppleCheck.isChecking(reason) { return ClusterOnboardingMacName.sentence(reason) }
        if let mac = reason.components(separatedBy: " isn't verified by Apple yet").first, mac != reason {
            return "Waiting for Apple to verify \(mac.prefix(1).lowercased() + mac.dropFirst()) (Darkbloom retries by itself)"
        }
        if reason.lowercased().contains("coordinator") || reason.lowercased().contains("registering") {
            return "Waiting for Darkbloom to pair both Macs"
        }
        return "Waiting for the other Mac's start: " + reason
    }

    /// The ✗ when the leading Mac said no outcome within the bound (an older leader publishes none): what is known.
    static func noOutcomeReason(_ leader: String?, seconds: Double) -> String {
        "\(ClusterOnboardingMacName.sentence(ClusterOnboardingMacName.other(named: leader))) didn't say how its start ended within "
            + "\(minutes(seconds)) minutes"
    }

    /// Under that ✗: where the outcome is.
    public static let noOutcomeLine = "Its screen shows how the start ended and what to do next."

    /// After a ✓ block from an older leader's status line: the hint, and Enter, as `servedEnding`.
    static func followServedEnd(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        console.say("  " + statusHint)
        if !operations.serviceOutlivesWindow() { console.say("  " + keepWindowServiceLine) }
        console.waitForExit()
        return 0
    }

    /// "15" for 900 s.
    static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }
}
