import Foundation

// The Mac that joined keeps its window open through the first setup's start (owner, 2026-11-04: "especially if things
// dont work, it before just ended the tui on both machines which seems odd"). It follows the start from the cluster's
// status the services exchange over the cable (the leading Mac's `localStatus`, the status this Mac shows after setup
// too) and ends with the same ✓/✗ block. Pure (Foundation only): the onboarding checks compile it with plain swiftc.

/// How long the Mac that joined follows the start on its own screen.
public struct ClusterOnboardingFollowTiming: Sendable {
    /// The bound, as the leader's start waits for the pair (`OnboardingLive.pairServingSeconds`): for the leader to
    /// start, then for the start's outcome.
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

    /// Under the ✗ on the Mac that joined: the choices are on the leading Mac's screen.
    public static func retryOnLeaderLine(_ leader: String?) -> String {
        "Choose Retry on \(ClusterOnboardingMacName.other(named: leader)): its screen shows the choices."
    }

    /// q while the Mac that joined follows the start: nothing stops.
    public static let followLeftLine = "The pair keeps going; run `darkbloom cluster` here to see it."

    /// Nothing started on the leading Mac within the bound.
    public static func notStartedLine(_ leader: String?, seconds: Double) -> String {
        "\(ClusterOnboardingMacName.sentence(ClusterOnboardingMacName.other(named: leader))) didn't start a model within "
            + "\(minutes(seconds)) minutes. When it does, this Mac runs its part by itself; run `darkbloom cluster` here to see it."
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
    }

    static func followed(_ status: [String]) -> FollowedStart {
        guard let first = status.first else { return .notStarted }
        if first.hasPrefix("Serving ") { return first.contains(ClusterOnboardingReady.offerPendingWords) ? .starting : .serving }
        if ClusterOnboardingNotServing.reason(inStatusLine: first) != nil { return .offered }
        let starting = first.hasPrefix("Loading ") || first.hasPrefix("Starting ") || first.contains(": registering both Macs")
        return starting ? .starting : .notStarted
    }

    /// In the serving line of the pair the coordinator formed (`ClusterOnboardingReady.pairServingLine`).
    static let pairServedMarker = " through Darkbloom on both Macs"

    /// The Mac that joined, once paired: waits for the Mac that leads to start, follows the start, and ends with the same
    /// ✓/✗ block as that Mac's screen. Bounded as the leader's start; q leaves (the pair keeps going). Never silent.
    static func followStart(leader: String?, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        let timing = operations.followTiming
        console.say("  " + waitingForStartLine(leader))
        let looks = ClusterOnboardingMailbox<[String]>()
        var asking = false, asked = Date.distantPast
        let begun = Date()
        var started: Date?, latest: String?
        while true {
            if !asking, Date().timeIntervalSince(asked) >= timing.pollSeconds {
                asking = true
                asked = Date()
                Thread.detachNewThread { looks.post(operations.status()) }
            }
            if let status = looks.take().last {
                asking = false
                let seen = followed(status)
                if started == nil, seen != .notStarted { started = Date() }
                if started != nil, let first = status.first { latest = first.hasSuffix(".") ? String(first.dropLast()) : first }
                switch seen {
                case .serving:
                    console.settle()
                    return followServed(status, leader: leader, operations, console)
                case .offered:
                    console.settle()
                    return followPair(status, leader: leader, operations, console)
                case .starting, .notStarted:
                    break
                }
            }
            if let started, Date().timeIntervalSince(started) >= timing.seconds {
                console.settle()
                console.result(false, ClusterOnboardingNotServing.title(reason: "The pair didn't report serving within \(minutes(timing.seconds)) minutes"),
                               latest.map { ["Last: " + $0 + "."] } ?? [])
                console.say(retryOnLeaderLine(leader))
                return 1
            }
            if started == nil, Date().timeIntervalSince(begun) >= timing.seconds {
                console.settle()
                console.say(notStartedLine(leader, seconds: timing.seconds))
                return 1
            }
            if let started, let latest {
                console.working(latest + " \u{00B7} " + ClusterOnboardingLoadRows.elapsed(Date().timeIntervalSince(started)) + " (q leaves)")
            } else {
                console.working("Waiting for \(ClusterOnboardingMacName.other(named: leader)) to start (q leaves)")
            }
            if let key = console.key(milliseconds: 120), leaves(key) { return leftFollow(operations, console) }
            if console.closed { usleep(120_000) }
        }
    }

    /// q or escape.
    static func leaves(_ key: Character) -> Bool { key == "q" || key == "Q" || key == "\u{1B}" }

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
        if status.first?.contains(pairServedMarker) != true {
            switch busy(console, "Sending a test request", operations.testRequest) {
            case .success(let lines): shown.append("Test response" + (lines.first.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""))
            case .failure(let failure):
                let first = failure.lines.first ?? "The test request failed"
                console.result(false, ClusterOnboardingNotServing.title(reason: first.hasSuffix(".") ? String(first.dropLast()) : first),
                               Array(failure.lines.dropFirst()))
                console.say("To test again, run `darkbloom cluster` on \(ClusterOnboardingMacName.other(named: leader)) and choose the model it serves.")
                return 1
            }
        }
        _ = showOutcome(shown, console)
        return followServedEnd(operations, console)
    }

    /// Offered to Darkbloom: the pair's own wait, as the leading Mac's (`pairServing`: the coordinator pairs both Macs,
    /// both load their share, the pair answers its first request), with its rows per Mac; q leaves it.
    static func followPair(_ status: [String], leader: String?, _ operations: ClusterOnboardingOperations,
                           _ console: ClusterOnboardingConsole) -> Int32 {
        let model = status.first?.components(separatedBy: ClusterOnboardingNotServing.statusMarker).first ?? "the model"
        console.say("  " + ClusterOnboardingReady.offeredLine(model: model))
        guard let result = waitWithRows("Serving \(model) through Darkbloom", console, leaving: leaves, operations.pairServing) else {
            return leftFollow(operations, console)
        }
        switch result {
        case .success(let lines):
            let tested = "Test response" + (lines.first.flatMap { $0.isEmpty ? nil : " " + $0 } ?? "")
            let now = operations.status()
            if case .serving = followed(now), let first = now.first {
                _ = showOutcome([first] + now.dropFirst() + [ClusterOnboardingReady.offeredAPILine, tested], console)
            } else {
                console.result(true, "Serving \(model)" + pairServedMarker, [ClusterOnboardingReady.offeredAPILine, tested])
            }
            return followServedEnd(operations, console)
        case .failure(let failure):
            let first = failure.lines.first ?? "The pair did not report serving"
            let reason = first.hasSuffix(".") ? String(first.dropLast()) : first
            console.result(false, ClusterOnboardingNotServing.title(reason: reason),
                           Array(failure.lines.dropFirst()) + (ClusterOnboardingNotServing.remedy(forReason: reason).map { [$0] } ?? []))
            console.say(retryOnLeaderLine(leader))
            return 1
        }
    }

    /// After ✓: what happens after a restart, and whether this window may close.
    static func followServedEnd(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        if let restart = operations.afterRestart() { console.say(restart) }
        console.say(operations.serviceOutlivesWindow() ? closeWindowLine : keepWindowLine)
        return 0
    }

    /// "15" for 900 s.
    static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }
}
