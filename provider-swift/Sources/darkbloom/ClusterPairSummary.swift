import Foundation
import ProviderCore

/// What a Mac's everyday commands know and say about the two-Mac cluster it is in: `darkbloom stop`, `start`,
/// `restart`, `status` and `doctor`, and `darkbloom cluster status`, `cluster link --remove` and `cluster stop`. The
/// words are the onboarding screens' own: the Macs as `ClusterOnboardingMacName` names them, the reasons as
/// `ClusterOnboardingNotServing` says them and, for `cluster status`, the status lines `darkbloom cluster` shows.
/// Built by `ClusterPairSummary.local` / `.live` (`ClusterPairSummary+Live.swift`).
struct ClusterPairSummary: Sendable, Equatable {
    enum Role: String, Sendable, Codable { case leader, member }

    /// Whether the cluster serves, as `darkbloom cluster status` reports it (`exitCode`).
    enum State: String, Sendable, Codable {
        case serving
        case loading
        case notServing = "not_serving"
        case stopped
        case otherMacAway = "other_mac_away"
        case notPaired = "not_paired"
        case unknown
        /// This Mac's pairing record couldn't be read: it may be in a cluster, so the commands act as if it were.
        case pairingUnreadable = "pairing_unreadable"
    }

    /// How this Mac's pairing record reads (`ClusterSetupLinkExchange.pairing()`).
    enum PairingRead: Equatable {
        case held
        case none
        /// The store or its secret couldn't be read; the reason in plain words, when it has some.
        case unreadable(String?)
    }

    var paired: Bool
    var role: Role?
    /// This Mac's own name (System Settings), for its own screen only.
    var thisMacName: String?
    /// The other Mac's name as pairing showed it ("Apple M5 Max, 128 GB"): its hardware, never a host name.
    var otherMacName: String?
    /// Whether the other Mac answered over the cable when it was asked; nil when it was not asked.
    var otherMacAnswers: Bool?
    var modelID: String?
    /// The catalog name ("Qwen 3.8 27B"); nil when the catalog gave none.
    var modelName: String?
    /// The leader's deployment line for the model ("Serving … across both Macs: pipeline, M3 Ultra 40 layers / …").
    var deployment: String?
    var localOnly: Bool = false
    /// The leader asked the cluster to serve (kept across restarts; `darkbloom cluster` → Stop clears it).
    var started: Bool = false
    var serviceRunning: Bool = false
    /// Whether the pair actually runs on this Mac, as its cluster service decided (`ClusterPairWatch`): the start above
    /// may be left from a pair whose other Mac stopped taking part. Nil when no service said (one from before 0.10.9):
    /// `started` decides then.
    var pairRunning: Bool?
    /// Why the started pair doesn't run here, with the command to serve this Mac alone (`ClusterPairWatch.line`).
    var pairNotRunning: String?
    /// The other Mac answered this Mac's cluster service lately (its control isn't waiting for it).
    var otherMacReachable: Bool = false
    var startsAtLogin: Bool = false
    /// Which Mac's link follower macOS keeps off the local network, when that keeps the pair from serving.
    var localNetworkRefused: ClusterLocalNetworkAccess.Refused?
    var state: State = .unknown
    /// Why it does not serve, in the screens' words.
    var reason: String?
    /// The status as `darkbloom cluster` shows it (`cluster status` only; empty elsewhere).
    var lines: [String] = []
    /// Not in a cluster, yet a cluster service runs or has a login agent here: left from an earlier pairing.
    var leftoverService: Bool = false
    /// Why the leader's adopted plan serves without the model's speculative assistant (`ClusterOnboardingLeadership.speculationNote`).
    var speculationNote: String?
    /// The pair serves Both, me first: its local API beside Darkbloom, as this Mac sees it; nil for any other way.
    var localAPI: ClusterPairLocalAPI?

    static let notPaired = ClusterPairSummary(paired: false, state: .notPaired)

    /// Where the summary starts from what this Mac holds: in a cluster when it holds a pairing; a cluster service
    /// without one is a leftover (`leftoverService`). A pairing record that can't be read is never "not in a cluster"
    /// (as `ClusterService.holdsNoPairing`): the commands act as if this Mac were in one, and say why.
    static func membership(_ pairing: PairingRead, serviceRunning: Bool, loginAgentInstalled: Bool,
                           startsAtLogin: Bool) -> ClusterPairSummary {
        var summary: ClusterPairSummary
        switch pairing {
        case .unreadable(let reason):
            summary = ClusterPairSummary(paired: true, state: .pairingUnreadable)
            summary.reason = reason
        case .none:
            // A cluster service without any pairing serves no pair: it is left from an earlier pairing.
            summary = .notPaired
            summary.leftoverService = serviceRunning || loginAgentInstalled
        case .held:
            summary = ClusterPairSummary(paired: true)
        }
        summary.serviceRunning = serviceRunning
        summary.startsAtLogin = startsAtLogin
        return summary
    }

    var pairingUnreadable: Bool { state == .pairingUnreadable }

    /// The command this build answers to (`BuildEnvironment.current.cliName`: `darkbloom-dev` in the DevNet app), in every
    /// command the summary prints (the candidate on pair-2, c3 B13). ProviderCore's texts and live operations read the same
    /// `ClusterOnboardingCommand.name`, so all of them say one name.
    static var cli: String { ClusterOnboardingCommand.name }

    /// What to do when the pairing record couldn't be read.
    static let checkPairingLine = "Run `\(Self.cli) cluster` on this Mac to check it."

    /// "This Mac's pairing record couldn't be read (pairings.json is malformed; …), so it may be in a two-Mac cluster."
    private var unsureSentence: String {
        "This Mac's pairing record couldn't be read" + (reason.map { " (\($0))" } ?? "") + ", so it may be in a two-Mac cluster."
    }

    // MARK: - Names

    var otherMac: String { ClusterOnboardingMacName.other(named: otherMacName) }
    var model: String? { modelName ?? modelID }
    var leads: Bool { role == .leader }
    /// "this Mac" or "the other Mac (…)": where the cluster is started, stopped and changed.
    var leadingMac: String { role == .member ? otherMac : ClusterOnboardingMacName.this }

    /// How the pair is set to serve; "not offered" while Darkbloom can't have it (never read as serving through it), and
    /// with Both, me first its local API too.
    var servesWords: String {
        guard !localOnly else { return "locally only" }
        return "through Darkbloom" + (ClusterOnboardingReady.isNotOffered(reason) ? " (not offered)" : "")
            + (localAPI == nil ? "" : ", and on its local API with you first")
    }

    /// The mode and each Mac's share, from the leader's deployment line ("pipeline", "M3 Ultra 40 layers / M5 Ultra 24
    /// layers"); without a line that names them, the mode the ✓ line marks, with no split (`servingMarker`).
    var modeAndSplit: (mode: String, split: String?)? {
        Self.modeAndSplit(deployment: deployment) ?? servingMarker.map { ($0, nil) }
    }

    /// One raw mode of each kind `ClusterOnboardingDeployment.modeWords` tells apart, the last one it doesn't know.
    private static let rawModes = ["prefill_tensor_decode", "tensor", "pipeline_mtp", "pipeline", "phase_split", "unknown"]

    /// The words `ClusterOnboardingDeployment.modeWords` says for every mode, longest first.
    private static let modeWordsList = rawModes.map(ClusterOnboardingDeployment.modeWords).sorted { $0.count > $1.count }

    /// A deployment line's mode and split ("Serving … across both Macs: pipeline, M3 Ultra 40 layers / …"): the mode's
    /// words follow the line's ": ", and a model's own name may hold one first ("Z.ai: GLM-5.3-Flash").
    static func modeAndSplit(deployment: String?) -> (mode: String, split: String?)? {
        guard let deployment else { return nil }
        var from = deployment.startIndex
        while let colon = deployment.range(of: ": ", range: from..<deployment.endIndex) {
            let rest = deployment[colon.upperBound...]
            if let mode = modeWordsList.first(where: { rest.hasPrefix($0) }) {
                let split = rest.dropFirst(mode.count).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                return (mode, split.isEmpty ? nil : split)
            }
            from = colon.upperBound
        }
        return nil
    }

    /// The mode the ✓ line marks ("Serving Z.ai: GLM-5.3-Flash (pipeline) at http://…", `ClusterOnboardingReady.summary`
    /// from the saved setup's mode), when it is a marker the serving line writes (`ClusterOnboardingDeployment.splitMarker`).
    private var servingMarker: String? {
        guard let first = lines.first, first.hasPrefix("Serving "), let at = first.range(of: ") at http"),
              let open = first[..<at.lowerBound].range(of: " (", options: .backwards) else { return nil }
        let marker = String(first[open.upperBound..<at.lowerBound])
        return Self.servingMarkers.contains(marker) ? marker : nil
    }

    private static let servingMarkers = Set(rawModes.compactMap(ClusterOnboardingDeployment.splitMarker))

    // MARK: - The pair in one sentence (stop, start, restart)

    /// "This Mac serves in a two-Mac cluster with the other Mac (Apple M5 Max, 128 GB): it leads; Qwen 3.8 27B through
    /// Darkbloom."
    var pairSentence: String {
        if pairingUnreadable { return unsureSentence }
        guard let role else { return "This Mac is paired with \(otherMac) for a two-Mac cluster." }
        let part = role == .leader ? "it leads" : "it follows"
        guard let model else { return "This Mac is in a two-Mac cluster with \(otherMac): \(part); no model chosen yet." }
        if started { return "This Mac serves in a two-Mac cluster with \(otherMac): \(part); \(model) \(servesWords)." }
        return "This Mac is in a two-Mac cluster with \(otherMac): \(part); stopped (last model \(model))."
    }

    // MARK: - darkbloom stop, start and restart control the pair

    /// The line `darkbloom stop`, `start` and `restart` say first on a Mac in a cluster: they act on the pair.
    /// "This Mac is in a two-Mac cluster with the other Mac (Apple M5 Max, 128 GB): stopping both Macs."
    func actingLine(_ action: String) -> String { "This Mac is in a two-Mac cluster with \(otherMac): \(action)." }

    static let stoppedLine =
        "Stopped on both Macs. They stay stopped after a restart; `\(Self.cli) start` on either Mac starts the pair again."
    /// A stop both Macs accepted whose parts haven't all ended yet (`stop` waits for them, bounded).
    static let stopAskedLine =
        "Asked both Macs to stop; they stay stopped after a restart, and `\(Self.cli) start` on either Mac starts the pair again."
    static let memoryFreedLine = "Memory freed on both Macs \u{2713}"
    static let restartNotStartedLine = "Not started again: run `\(Self.cli) restart` once both parts have ended (`\(Self.cli) status`)."

    /// Both Macs report nothing left running (`cluster verify-teardown`'s lines).
    static func bothFreed(_ lines: [String]) -> Bool {
        lines.count >= 2 && lines.allSatisfy { $0.hasSuffix(": nothing left running") }
    }

    /// The memory check didn't answer: said, never left out.
    static func memoryNotCheckedLine(_ failure: [String]) -> String {
        "Memory: not checked (" + (failure.first ?? "no answer") + ")"
    }
    static let unreachableLine = "This Mac's cluster can't be reached from this command; run `\(Self.cli) cluster` on this Mac to see it."
    static let noModelLine = "No model was chosen for the pair yet: run `\(Self.cli) start` in a terminal to choose one."

    /// After a stop, what each Mac has left running (`cluster verify-teardown`'s lines): one line when nothing is.
    static func memoryLines(_ lines: [String]) -> [String] {
        if bothFreed(lines) { return [memoryFreedLine] }
        return ["Memory:"] + lines.map { "  " + $0 }
    }

    /// `darkbloom stop` or `restart` without `--solo` (and `cluster stop` without `--service`) while this Mac's pairing
    /// record can't be read: it can't tell which pair to act on, so nothing changes, and `--solo` acts on single-Mac
    /// serving alone.
    func unsureRefusal(_ command: String, _ done: String) -> [String] {
        [pairSentence, "`\(Self.cli) \(command)` can't tell which pair to \(command), so nothing was \(done).",
         "To \(command) single-Mac serving on this Mac only: `\(Self.cli) \(command) --solo`. " + Self.checkPairingLine]
    }

    /// `darkbloom start` without `--solo` while this Mac's pairing record can't be read: refused, since single-Mac
    /// serving would compete with a cluster this Mac may be in.
    var startRefusal: [String] {
        [pairSentence,
         "Single-Mac serving next to a cluster would compete for this Mac's memory. To serve on this Mac alone, run "
            + "`\(Self.cli) cluster` on this Mac to check the pairing first, or pass --solo."]
    }

    /// `darkbloom start` with single-Mac options (`--model`, `--local`, …) but no `--solo` on a Mac in a cluster:
    /// nothing starts, since they would otherwise be ignored. `--local` has a pair form (`darkbloom cluster local`).
    func singleMacOptionsRefusal(_ options: [String]) -> [String] {
        let named = options.map { "`\($0)`" }
        let list = named.count < 2 ? named.joined() : named.dropLast().joined(separator: ", ") + " and " + named.last!
        var lines = ["This Mac is in a two-Mac cluster with \(otherMac): \(list) \(named.count == 1 ? "is" : "are") for "
                        + "single-Mac serving, so nothing was started.",
                     "To choose the pair's model, run `\(Self.cli) start` in a terminal; to serve this Mac alone with "
                        + "\(named.count == 1 ? "it" : "them"), add --solo."]
        if options.contains(where: { $0 == "--local" || $0 == "--local-endpoint" }) {
            lines.append("To serve the pair on the leading Mac's own API only: `\(Self.cli) cluster local`.")
        }
        return lines
    }

    /// `darkbloom start --solo` on a Mac in a stopped cluster: one line, and single-Mac serving starts.
    var startNote: String {
        if pairingUnreadable {
            return "Starting single-Mac serving (--solo) although this Mac's pairing record couldn't be read: if it is in a "
                + "two-Mac cluster, both use this Mac's memory."
        }
        return "This Mac is in a two-Mac cluster with \(otherMac), which is stopped. Stop single-Mac serving (`\(Self.cli) stop "
            + "--solo`) before you start the pair again (`\(Self.cli) start`)."
    }

    /// This Mac's part serves: single-Mac serving can't run beside it (both take this Mac's one serving lock,
    /// `provider.pid.lock`).
    var partServes: Bool { (pairRunning ?? started) && serviceRunning && !pairingUnreadable }

    /// The pair doesn't run on this Mac (stopped, or started but not running: `pairNotRunning`): `darkbloom start --solo`
    /// serves this Mac alone.
    var pairIdle: Bool { paired && !pairingUnreadable && !partServes }

    /// The pair doesn't run here, yet its saved start and this Mac's cluster service are left: its part may still run and
    /// hold this Mac's serving lock. `stop`, and `start --solo`, `restart` and `update` before they serve this Mac alone,
    /// stop that part and clear the start first (`Start.releaseLeftoverPart`).
    var leftoverPartHere: Bool { pairIdle && started && serviceRunning }

    /// A plain `darkbloom restart` restarts the pair (`Restart.pairRestart`): it runs here, or it is started and the other
    /// Mac answers (it may still be loading). Otherwise, stopped or with the other Mac gone, a restart never starts it.
    var restartRestartsPair: Bool { paired && !pairingUnreadable && (partServes || (started && otherMacReachable)) }

    /// `darkbloom start --solo` on a Mac whose pair doesn't run and where no leftover part runs: one line. Where one runs
    /// (`leftoverPartHere`), `leftoverStopLine` and `leftoverReleasedLine` say it instead. The other Mac's silence is said
    /// only when this Mac's cluster service runs, and so asked it (`otherMacReachable` is false when nothing asked).
    var servingAloneLine: String {
        if started {
            return "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here"
                + (serviceRunning && !otherMacReachable ? " (\(otherMac) isn't answering)" : "")
                + ": serving this Mac alone (`\(Self.cli) start` starts the pair again)."
                + (role == .member ? followerRestartNote : "")
        }
        return "This Mac is in a two-Mac cluster with \(otherMac), which is stopped: serving this Mac alone "
            + "(`\(Self.cli) start` starts the pair again)."
    }

    /// A following Mac records its leader's start from the leader's next accepted lease, so a start cleared here comes
    /// back while the leader keeps the pair started; its part then waits for single-Mac serving to stop here.
    private var followerRestartNote: String {
        " While \(otherMac) leads with the pair started, it may start this Mac's part again once single-Mac serving stops "
            + "here: `\(Self.cli) stop` on \(otherMac) stops the pair."
    }

    /// The desktop app's Start on a paired Mac named `models` (`start --model <id>`); the pair started with its own. One
    /// line the app shows when that isn't the one model named; nil when it is, or when no model was named.
    func appStartModelLine(named models: [String]) -> String? {
        guard !models.isEmpty, let saved = modelID, models != [saved] else { return nil }
        return "This Mac serves in a pair: started the pair with \(modelName ?? saved); `\(Self.cli) cluster` changes its model."
    }

    /// `darkbloom stop`, `start --solo`, `restart` and `update` on a Mac whose pair doesn't run, before its leftover part
    /// stops: what they do, said while nothing has changed yet.
    var leftoverStopLine: String {
        "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here: stopping this Mac's leftover part "
            + "and clearing its saved start (`\(Self.cli) start` starts the pair again)."
    }

    /// Once that part stopped and its saved start is cleared, before single-Mac serving (`start --solo`, `restart`,
    /// `update`); never before, since a running cluster command can make the stop wait and end with nothing changed.
    var leftoverReleasedLine: String {
        "This Mac's leftover part of the pair stopped, and its saved start is cleared: serving this Mac alone."
            + (role == .member ? followerRestartNote : "")
    }

    /// `darkbloom restart` on a Mac where neither the pair nor single-Mac serving runs.
    var idleRestartRefusal: [String] {
        [pairNotRunning ?? restartPairSentence,
         "Nothing serves on this Mac, so nothing was restarted: `\(Self.cli) start` starts the pair again; "
            + "`\(Self.cli) start --solo` serves this Mac alone."]
    }

    /// The pair's part couldn't be stopped for single-Mac serving: why, and the one step that always works.
    var releaseFailedLines: [String] {
        ["This Mac's part of the pair didn't stop in time, so single-Mac serving can't start yet.",
         "To leave the pair on this Mac: `\(Self.cli) cluster pair --status`, then `\(Self.cli) cluster pair --forget <pin>`, "
            + "then `\(Self.cli) start`."]
    }

    /// Said at once when stopping this Mac's leftover part waits for a cluster command that runs (it holds the command
    /// lock): nothing has been read or written yet.
    static let releaseWaitLine = "Waiting for the pair's running command to finish (up to 10 minutes; ^C stops waiting and "
        + "leaves the pair as it is)."

    /// That command still ran after the 10 minutes: nothing was stopped, and the pair needn't be left.
    static var releaseBusyLines: [String] {
        ["The pair's command was still running after 10 minutes, so nothing was stopped or started. Try again, or run "
            + "`\(cli) cluster` to see what's running."]
    }

    /// `darkbloom start --solo` while this Mac's part of the pair serves.
    var soloBesideServingRefusal: [String] {
        [pairSentence, "This Mac's part of the pair holds its serving lock, so single-Mac serving can't start beside it. Stop "
            + "the pair first (`\(Self.cli) stop`), then `\(Self.cli) start --solo`."]
    }

    /// `darkbloom stop --solo` where no single-Mac serving runs on a Mac in a cluster.
    var soloStopNothing: [String] {
        ["`\(Self.cli) stop --solo` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
         pairingUnreadable ? Self.checkPairingLine
            : "The pair keeps running. If single-Mac serving blocks it, it runs on \(otherMac): run `\(Self.cli) stop --solo` there."]
    }

    /// After `darkbloom stop --solo` (or `--uninstall`) stopped single-Mac serving on a Mac in a cluster.
    var stopAddendum: [String] { [pairSentence, soloLeftPair("stop")] }

    /// `darkbloom restart --solo` where no single-Mac serving is installed.
    var restartRefusal: [String] {
        [restartPairSentence,
         "`\(Self.cli) restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
         soloLeftPair("restart")]
    }

    /// After `darkbloom restart` restarted single-Mac serving on a Mac in a cluster: with --solo, or while the pair doesn't
    /// run here.
    var restartAddendum: String {
        restartPairSentence + (pairingUnreadable ? " No cluster was restarted." : " " + soloLeftPair("restart"))
    }

    /// The pair as `restart`'s words name it: `pairSentence`, except a started pair that a restart doesn't restart. That pair
    /// doesn't run here (its other Mac gone, or this Mac's cluster service down), so it never reads "This Mac serves".
    private var restartPairSentence: String {
        guard started, !pairingUnreadable, !restartRestartsPair else { return pairSentence }
        return "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here"
            + (serviceRunning ? " (\(otherMac) isn't answering)." : ".")
    }

    /// `--solo` left the pair alone: "The pair was not stopped; `darkbloom stop` stops both Macs." A pair that a plain
    /// restart wouldn't restart (`restartRestartsPair`) is named with the command that starts it.
    private func soloLeftPair(_ command: String) -> String {
        if pairingUnreadable { return Self.checkPairingLine }
        if command == "restart", !restartRestartsPair { return "The pair was not started; `\(Self.cli) start` starts it." }
        return "The pair was not \(command == "stop" ? "stopped" : "restarted"); `\(Self.cli) \(command)` \(command)s both Macs."
    }

    /// The end of `darkbloom start` and `restart` on a Mac in a cluster, shaped like single-Mac start's block.
    var resultLines: [String] {
        var out = stateLines
        if out.isEmpty { out = ["\u{2026} Not serving yet."] }
        out.append("  Model:   " + modelWords)
        out.append("  Macs:    " + rolesWords)
        out.append("  Serves:  " + servesWords)
        if state != .serving, let next { out.append("  Next:    " + next) }
        out += ["", "  \(Self.cli) stop     Stop both Macs", "  \(Self.cli) restart  Restart with the current model",
                "  \(Self.cli) status   Check status"]
        return out
    }

    // MARK: - darkbloom status and doctor (no network)

    /// One line for `darkbloom status --solo` and `darkbloom doctor`, from what this Mac knows by itself.
    var statusLine: String {
        guard paired else { return "Cluster: not in a cluster" }
        if pairingUnreadable {
            return "Cluster: this Mac's pairing record couldn't be read" + (reason.map { " (\($0))" } ?? "")
                + " · run `\(Self.cli) cluster` to check it (details: `\(Self.cli) cluster status`)"
        }
        if let idle = startedButNotRunningLine { return "Cluster: " + idle }
        var parts = [role.map { $0 == .leader ? "this Mac leads" : "this Mac follows" } ?? "this Mac is paired", otherMac]
        if let model { parts.append("\(model) \(servesWords)") }
        let now: String
        switch state {
        case .serving: now = "serving"
        case .loading: now = "loading" + (reason.map { ": " + $0 } ?? "")
        case .notServing: now = "not serving" + (reason.map { ": " + $0 } ?? "")
        case .stopped: now = "stopped"
        case .otherMacAway: now = reason ?? "the other Mac isn't answering"
        case .notPaired, .unknown, .pairingUnreadable: now = started ? "started" : "stopped"
        }
        parts.append(now)
        return "Cluster: " + parts.joined(separator: " · ") + " (details: `\(Self.cli) cluster status`)"
    }

    /// `darkbloom status --solo` instead of "Daemon: not running (run `darkbloom start`)" on a Mac in a cluster.
    static let singleMacServingOffLine =
        "Single-Mac serving: off (this Mac serves in its two-Mac cluster: `\(Self.cli) cluster status`)"
    /// The same when this Mac's pairing record couldn't be read.
    static let singleMacServingOffUnsureLine =
        "Single-Mac serving: off (this Mac may be in a two-Mac cluster: `\(Self.cli) cluster status`)"
}

// MARK: - darkbloom cluster status

extension ClusterPairSummary {
    /// Exit status of `darkbloom cluster status` (documented in its help and docs/provider/cli-reference.md).
    var exitCode: Int32 {
        switch state {
        case .serving: return 0
        case .loading, .notServing, .unknown: return 3
        case .stopped: return 4
        case .otherMacAway: return 5
        case .notPaired: return 6
        case .pairingUnreadable: return 7
        }
    }

    /// A status line saying the other Mac didn't answer over the cable (the leading Mac's forward failed, or its own
    /// view of the other Mac). The one test for both the away state and `otherMacAnswers`.
    static func saysOtherMacSilent(_ line: String) -> Bool {
        line.contains("did not answer over the cable") || line.contains("doesn't answer over the cable")
    }

    /// The leading Mac's control modes while the other Mac isn't answering: waiting for it, serving alone, or unable
    /// to serve alone (`ClusterServiceStatus.control.mode`).
    static let otherMacAwayModes: Set<String> = ["waiting", "alone", "cannotServe"]

    /// The leading Mac's control modes in which every other Mac of the plan answered within its time-to-live
    /// (`ClusterControlNode.mode`: running the cluster, or confirming its claim).
    static let otherMacPresentModes: Set<String> = ["cluster", "confirming"]

    /// The coordinator's pairing, in the status line's reason place: progress, not a reason (`pairLook`'s wait).
    static let pairingProgress: Set<String> = ["the coordinator paired both Macs", "waiting for the coordinator to pair both Macs"]

    /// A reason that ends a start's wait: one that needs a person (a login, the clock, a coordinator rule, matching
    /// builds, a pair not offered to Darkbloom, which only a new plan or approval changes, single-Mac serving on a Mac). Others (Apple verification
    /// retrying, memory freeing, a busy or reconnecting Mac, the coordinator retrying) are waited through, as the setup
    /// screen does, within the bounded wait.
    static func isFinalReason(_ reason: String?) -> Bool {
        guard let reason else { return true }
        if reason.contains(ClusterOnboardingVersionSplit.reasonMarker) { return true }
        return ClusterOnboardingNotServing.isMissingLogin(reason) || reason.contains("The clock of")
            || reason.contains("doesn't let") || reason.contains("run different Darkbloom builds")
            || ClusterOnboardingReady.isNotOffered(reason) || ClusterOnboardingSoloServing.isBlock(reason)
    }

    /// The state the status lines of `darkbloom cluster` say, read as the other Mac's window reads them
    /// (`ClusterOnboardingDriver.showOutcome`): "Serving …" serves, "<model> is not serving yet: <reason>." does not.
    /// `leaderMode`: this Mac's own control mode when it leads (the lines are its own then).
    static func state(ofStatus lines: [String], started: Bool, leaderMode: String?) -> (state: State, reason: String?) {
        guard let first = lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }), !first.isEmpty else {
            return (started ? .unknown : .stopped, nil)
        }
        if first.hasPrefix("Serving ") { return (.serving, nil) }
        if let reason = ClusterOnboardingNotServing.reason(inStatusLine: first) {
            return (Self.pairingProgress.contains(reason) ? .loading : .notServing, reason)
        }
        if first.hasPrefix("Stopped") { return (.stopped, nil) }
        if first.hasPrefix("Loading ") || first.hasPrefix("Starting ") || first == ClusterOnboardingUpdate.statusLine
            || first.contains("registering both Macs with the coordinator") {
            return (.loading, partEnded(inLoadingLine: first))
        }
        // A stopped pair reads stopped whatever the other Mac's presence: a stop it asked for before it left.
        if let leaderMode, otherMacAwayModes.contains(leaderMode) {
            guard started else { return (.stopped, nil) }
            return (.otherMacAway, first.hasSuffix(".") ? String(first.dropLast()) : first)
        }
        if saysOtherMacSilent(first) { return (started ? .otherMacAway : .stopped, nil) }
        return (started ? .unknown : .stopped, nil)
    }

    /// A loading line's part that keeps ending ("this Mac's part ended (exit 1: deadline) and starts again by itself",
    /// `OnboardingLive.endedClause`), as the reason; nil while no part has ended.
    static func partEnded(inLoadingLine line: String) -> String? {
        guard let marker = line.range(of: "'s part ended ("),
              let start = line[..<marker.lowerBound].range(of: "; ", options: .backwards) else { return nil }
        var reason = String(line[start.upperBound...])
        if reason.hasSuffix(".") { reason.removeLast() }
        return reason
    }

    /// What to do next, in commands.
    var next: String? {
        switch state {
        case .notPaired:
            return (leftoverService ? "To remove it: `\(Self.cli) cluster stop --service`. " : "")
                + "To set up a cluster: `\(Self.cli) cluster` on each Mac."
        case .serving: return "To stop or change it: `\(Self.cli) cluster` on \(leadingMac)."
        case .loading:
            if reason != nil { return "Both Macs keep trying by themselves; `\(Self.cli) cluster` on \(leadingMac) shows more." }
            return "Loading takes a few minutes for a large model; check again with `\(Self.cli) cluster status`."
        case .stopped:
            return "`\(Self.cli) start` on either Mac starts the pair again."
                + (serviceRunning ? "" : " This Mac's cluster service is off; `\(Self.cli) start` here turns it back on.")
        case .otherMacAway:
            return "\(ClusterOnboardingMacName.sentence(otherMac)) isn't answering over the cable. Its cluster service may "
                + "have been turned off with `\(Self.cli) cluster stop --service`, or that Mac is asleep, off, or waiting for "
                + "someone to log in. On that Mac, run `\(Self.cli) start` (or `\(Self.cli) cluster`)."
        case .notServing:
            if let words = localNetworkWords { return words.next }
            let reason = reason ?? ""
            // Different versions: the Mac to update, named for this window, before anything else.
            if let split = ClusterOnboardingVersionSplit.next(reason: reason, thisVersion: ProviderCore.version,
                                                              other: otherMac, cli: Self.cli) { return split }
            if ClusterOnboardingNotServing.isMissingLogin(reason) {
                return "Run `\(Self.cli) login` on each Mac named, then `\(Self.cli) cluster` on \(leadingMac). Or serve "
                    + "locally only: `\(Self.cli) cluster local` on \(leadingMac)."
            }
            if reason.contains("isn't verified by Apple yet") {
                return "Leave both Macs running: Darkbloom retries by itself. Or serve locally only: `\(Self.cli) cluster local` "
                    + "on \(leadingMac)."
            }
            if reason.contains("lacks free memory") {
                return "Quit apps on that Mac; the cluster starts again by itself. Or choose a smaller model: "
                    + "`\(Self.cli) cluster` on \(leadingMac)."
            }
            // Single-Mac serving never stops by itself: what to run, never "keep trying" (0.10.9 DevNet f1).
            if ClusterOnboardingSoloServing.isBlock(reason) {
                return ClusterOnboardingSoloServing.next(cli: Self.cli, leadingMac: leadingMac)
            }
            if ClusterOnboardingReady.isNotOffered(reason) {
                return "To offer it to Darkbloom: `\(Self.cli) cluster` on \(leadingMac), then choose the model again (it is "
                    + "planned for Darkbloom). Or serve locally only: `\(Self.cli) cluster local` on \(leadingMac)."
            }
            return "Both Macs keep trying by themselves; `\(Self.cli) cluster` on \(leadingMac) shows more."
        case .unknown: return "`\(Self.cli) cluster` on \(leadingMac) shows more."
        case .pairingUnreadable: return Self.checkPairingLine
        }
    }

    /// Reads the status lines `darkbloom cluster` shows (on the Mac that follows, the leading Mac's): the state, its
    /// reason, and whether the other Mac answered, which follows the state so the two never disagree.
    mutating func read(status: [String], leaderMode: String?) {
        lines = status.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        (state, reason) = Self.state(ofStatus: lines, started: started, leaderMode: leaderMode)
        let away = leaderMode.map(Self.otherMacAwayModes.contains) == true || lines.first.map(Self.saysOtherMacSilent) == true
        if state == .stopped, away {
            // Stopped, then the other Mac's absence: not its countdown to serving alone, which a stopped pair never does.
            lines = [stoppedLine, "\(ClusterOnboardingMacName.sentence(otherMac)) isn't answering over the cable."]
        }
        if role == .member {
            // The lines came from the leading Mac unless they say it didn't answer (`saysOtherMacSilent`).
            otherMacAnswers = !away
        } else if away {
            otherMacAnswers = false
        } else if let leaderMode, Self.otherMacPresentModes.contains(leaderMode) {
            otherMacAnswers = true
        }
    }

    /// "Stopped; last model Qwen 3.8 27B.", as the leading Mac's status says a stopped pair.
    var stoppedLine: String { "Stopped" + (model.map { "; last model " + $0 } ?? "") + "." }

    /// Reads a Local Network refusal over the status lines: a start that can't go on until someone turns the setting on
    /// reads not serving, in the setup screens' words (`localNetworkWords`), instead of a load that never ends. A pair
    /// that serves or stopped reads as it did.
    mutating func read(localNetworkRefused refused: ClusterLocalNetworkAccess.Refused?) {
        guard let refused, started, [.loading, .unknown, .otherMacAway].contains(state) else { return }
        localNetworkRefused = refused
        state = .notServing
        reason = localNetworkWords?.reason
        // The lines say what the state says, as the plain output's ✗ line does in place of the first one ("Starting …").
        if let reason { lines = [ClusterOnboardingNotServing.title(reason: reason)] + lines.dropFirst() }
    }

    /// The setup screens' words for `localNetworkRefused` (`ClusterLocalNetworkAccess.statusWords`).
    var localNetworkWords: (reason: String, next: String)? {
        localNetworkRefused.map {
            ClusterLocalNetworkAccess.statusWords($0, otherMac: ClusterOnboardingMacName.sentence(otherMac), app: ClusterService.appName,
                                                  cli: Self.cli)
        }
    }

    /// `darkbloom cluster status`: who leads, the model and its split, how it serves, whether it serves now (the
    /// screens' words) and what to do.
    var clusterStatusLines: [String] {
        if pairingUnreadable { return [pairSentence, "Next: " + Self.checkPairingLine] }
        guard paired else {
            return [leftoverService ? "This Mac isn't in a cluster, but a cluster service is still set up on it (left from an earlier pairing)."
                        : "This Mac isn't in a cluster.", "Next: " + (next ?? "")]
        }
        var out = ["Cluster: " + rolesWords, "Model: " + modelWords]
        out.append("Serves: " + servesWords + (localOnly ? " (API key: `\(Self.cli) local` on the Mac that serves it)" : ""))
        if let speculationNote { out.append(speculationNote) }
        if let idle = startedButNotRunningLine {
            out.append(idle)
            out.append("Next: `\(Self.cli) start --solo` serves this Mac alone; `\(Self.cli) start` starts the pair again.")
            return out
        }
        out.append(contentsOf: stateLines)
        out.append(contentsOf: localAPILines())
        if let next { out.append("Next: " + next) }
        return out
    }

    /// The pair is started but doesn't run here (its cluster service said why): the one line `status` gives.
    var startedButNotRunningLine: String? {
        guard paired, !pairingUnreadable, started, pairRunning == false else { return nil }
        return pairNotRunning ?? "The pair isn't running on this Mac (\(otherMac) isn't taking part)."
    }

    /// "this Mac (Mac Studio) leads · the other Mac (Apple M5 Max, 128 GB) follows"
    private var rolesWords: String {
        let this = thisMacName.map { "this Mac (\($0))" } ?? ClusterOnboardingMacName.this
        switch role {
        case .leader: return "\(this) leads · \(otherMac) follows"
        case .member: return "\(this) follows · \(otherMac) leads"
        case nil: return "\(this) is paired with \(otherMac)"
        }
    }

    /// "Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%"
    private var modelWords: String {
        guard let model else { return "none chosen yet" }
        return model + (modeAndSplit.map { " · " + $0.mode + ($0.split.map { " · " + $0 } ?? "") } ?? "")
    }

    /// The state as the outcome block marks it (✓ serving, ✗ not serving, ■ stopped), then the remaining status lines.
    private var stateLines: [String] {
        let rest = lines.dropFirst().map { "  " + $0 }
        let first = lines.first
        switch state {
        case .serving: return ["\(ClusterOnboardingDriver.done) " + (first ?? "Serving")] + rest
        case .notServing:
            return ["\(ClusterOnboardingDriver.failed) " + ClusterOnboardingNotServing.title(reason: reason ?? "no reason known")]
                + rest.filter { $0.trimmingCharacters(in: .whitespaces) != ClusterOnboardingNotServing.remedy(forReason: reason ?? "") }
        case .stopped: return ["\u{25A0} " + (first ?? stoppedLine)] + rest
        case .loading: return ["\u{2026} " + (first ?? "Loading")] + rest
        case .otherMacAway: return [ClusterOnboardingDriver.failed + " " + (first ?? "\(ClusterOnboardingMacName.sentence(otherMac)) isn't answering.")] + rest
        case .unknown, .notPaired, .pairingUnreadable: return lines
        }
    }
}

// MARK: - --json (schema 1)

extension ClusterPairSummary {
    /// `darkbloom cluster status --json`. Stable: fields are only ever added; documented in docs/provider/cli-reference.md.
    /// Every key, nested ones too, is written (null when unknown), so a reader never has to tell a missing key from an
    /// unknown value: hence the hand-written `encode(to:)`s, as the synthesized ones leave nil keys out.
    struct JSON: Encodable, Equatable {
        struct OtherMac: Encodable, Equatable {
            var name: String?
            var answers: Bool?
            enum CodingKeys: String, CodingKey { case name, answers }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(answers, forKey: .answers)
            }
        }
        struct Model: Encodable, Equatable {
            var id: String
            var name: String?
            enum CodingKeys: String, CodingKey { case id, name }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
            }
        }
        struct Service: Encodable, Equatable {
            var running: Bool
            var startsAtLogin: Bool
            enum CodingKeys: String, CodingKey { case running, startsAtLogin = "starts_at_login" }
        }
        let schema = 1
        var paired: Bool?
        var role: String?
        var thisMac: String?
        var otherMac: OtherMac?
        var model: Model?
        var mode: String?
        var split: String?
        var serves: String?
        var state: String
        var reason: String?
        var next: String?
        var lines: [String]
        var service: Service
        var exitCode: Int32

        enum CodingKeys: String, CodingKey {
            case schema, paired, role, thisMac = "this_mac", otherMac = "other_mac", model, mode, split, serves, state, reason,
                 next, lines, service, exitCode = "exit_code"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schema, forKey: .schema)
            try container.encode(paired, forKey: .paired)
            try container.encode(role, forKey: .role)
            try container.encode(thisMac, forKey: .thisMac)
            try container.encode(otherMac, forKey: .otherMac)
            try container.encode(model, forKey: .model)
            try container.encode(mode, forKey: .mode)
            try container.encode(split, forKey: .split)
            try container.encode(serves, forKey: .serves)
            try container.encode(state, forKey: .state)
            try container.encode(reason, forKey: .reason)
            try container.encode(next, forKey: .next)
            try container.encode(lines, forKey: .lines)
            try container.encode(service, forKey: .service)
            try container.encode(exitCode, forKey: .exitCode)
        }
    }

    var json: JSON {
        let modeAndSplit = self.modeAndSplit
        // An unreadable pairing record: whether this Mac holds a pairing, with which Mac and how it serves is unknown.
        let known = paired && !pairingUnreadable
        return JSON(paired: pairingUnreadable ? nil : paired,
                    role: role?.rawValue,
                    thisMac: thisMacName,
                    otherMac: known ? .init(name: otherMacName, answers: otherMacAnswers) : nil,
                    model: modelID.map { .init(id: $0, name: modelName) },
                    mode: modeAndSplit?.mode,
                    split: modeAndSplit?.split,
                    serves: known ? (localOnly ? "local" : "darkbloom") : nil,
                    state: state.rawValue,
                    reason: reason,
                    next: next,
                    lines: lines,
                    service: .init(running: serviceRunning, startsAtLogin: startsAtLogin),
                    exitCode: exitCode)
    }
}

// MARK: - cluster link --remove and cluster stop

extension ClusterPairSummary {
    /// `darkbloom cluster link --remove` on a paired Mac, before anything changes (the end user removed a working
    /// setup because of a false doctor warning).
    var linkRemoveWarning: [String] {
        if pairingUnreadable {
            return [pairSentence, "--remove undoes this Mac's cable port setup: a cluster that uses it stops serving on both "
                + "Macs until the port is set up again with `\(Self.cli) cluster` (or `\(Self.cli) cluster link --fix`)."]
        }
        return ["This Mac is paired with \(otherMac), and the cable carries their cluster.",
         "--remove undoes the cable port setup that works now: the cluster stops serving on both Macs until the port is "
            + "set up again with `\(Self.cli) cluster` (or `\(Self.cli) cluster link --fix`)."]
    }

    static let linkRemoveQuestion = "Remove it? [y/N] "
    static let linkRemoveNeedsYes = "Nothing changed. To remove it anyway without a question, add --yes."
    /// Beside another app that still uses the port: only the person at a terminal answers for it, never `--yes`.
    static let linkRemoveOtherAppNeedsTerminal = "Nothing changed. --yes doesn't answer for the other app: run it in a "
        + "terminal and confirm there."
    static let nothingChanged = "Nothing changed."

    /// `darkbloom cluster stop` on the Mac that follows a started cluster: the leading Mac stops both Macs, as the
    /// menu's Stop does (it no longer leaves the leader waiting for a member that went away).
    static func memberStopNote(leader: String) -> String {
        "This Mac follows \(leader), which leads: `\(Self.cli) cluster stop` stops the cluster on both Macs."
    }

    /// When the leading Mac could not stop the cluster: nothing changed here, and how to stop this Mac alone.
    /// What the Mac that follows says after its forwarded stop failed.
    static func memberStopFailureLines(_ failure: [String]) -> [String] {
        let first = failure.first ?? ""
        // The leading Mac never got it (refused, unreachable): nothing stopped anywhere.
        if first.contains("did not answer over the cable"), !first.contains("timed out") { return [memberStopFailedLine] }
        // It may have got it and still be draining (its stop can outlast the forward's wait).
        if first.contains("timed out") {
            return ["The leading Mac didn't confirm the stop in time; it may still be finishing. `\(Self.cli) status` shows where "
                + "both Macs stand.", stopThisMacAloneLine]
        }
        // The leading Mac answered with its own reason (it may have stopped, without reaching this Mac): as it said.
        return [stopThisMacAloneLine]
    }

    static let stopThisMacAloneLine =
        "To stop only this Mac: `\(Self.cli) cluster stop --local-only` (the other Mac then serves alone, or waits for this one)."

    static let memberStopFailedLine = "Nothing was stopped on this Mac. " + stopThisMacAloneLine
}
