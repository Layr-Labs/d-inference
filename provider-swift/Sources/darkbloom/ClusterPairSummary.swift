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
    var startsAtLogin: Bool = false
    var state: State = .unknown
    /// Why it does not serve, in the screens' words.
    var reason: String?
    /// The status as `darkbloom cluster` shows it (`cluster status` only; empty elsewhere).
    var lines: [String] = []

    static let notPaired = ClusterPairSummary(paired: false, state: .notPaired)

    /// Where the summary starts from what this Mac holds: not in a cluster, or in one (it holds a pairing, or its
    /// cluster service runs or has a login agent). A pairing record that can't be read is never "not in a cluster"
    /// (as `ClusterService.holdsNoPairing`): the commands act as if this Mac were in one, and say why.
    static func membership(_ pairing: PairingRead, serviceRunning: Bool, loginAgentInstalled: Bool,
                           startsAtLogin: Bool) -> ClusterPairSummary {
        var summary: ClusterPairSummary
        switch pairing {
        case .unreadable(let reason):
            summary = ClusterPairSummary(paired: true, state: .pairingUnreadable)
            summary.reason = reason
        case .held, .none:
            guard pairing == .held || serviceRunning || loginAgentInstalled else { return .notPaired }
            summary = ClusterPairSummary(paired: true)
        }
        summary.serviceRunning = serviceRunning
        summary.startsAtLogin = startsAtLogin
        return summary
    }

    var pairingUnreadable: Bool { state == .pairingUnreadable }

    /// What to do when the pairing record couldn't be read.
    static let checkPairingLine = "Run `darkbloom cluster` on this Mac to check it."

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

    var servesWords: String { localOnly ? "locally only" : "through Darkbloom" }

    /// The mode and each Mac's share, from the leader's deployment line ("pipeline", "M3 Ultra 40 layers / M5 Ultra 24
    /// layers"). The mode is matched against the words `ClusterOnboardingDeployment.modeWords` says, longest first.
    var modeAndSplit: (mode: String, split: String?)? {
        guard let deployment, let colon = deployment.range(of: ": ") else { return nil }
        let rest = String(deployment[colon.upperBound...])
        let modes = ["prefill_tensor_decode", "tensor", "pipeline_mtp", "pipeline", "phase_split", "unknown"]
            .map(ClusterOnboardingDeployment.modeWords).sorted { $0.count > $1.count }
        guard let mode = modes.first(where: { rest.hasPrefix($0) }) else { return nil }
        let split = rest.dropFirst(mode.count).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return (mode, split.isEmpty ? nil : split)
    }

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
        "Stopped on both Macs. They stay stopped after a restart; `darkbloom start` on either Mac starts the pair again."
    static let alreadyStoppedLine = "The pair is already stopped; `darkbloom start` on either Mac starts it again."
    static let unreachableLine = "This Mac's cluster can't be reached from this command; run `darkbloom cluster` on this Mac to see it."
    static let noModelLine = "No model was chosen for the pair yet: run `darkbloom start` in a terminal to choose one."

    /// After a stop, what each Mac has left running (`cluster verify-teardown`'s lines): one line when nothing is.
    static func memoryLines(_ lines: [String]) -> [String] {
        if lines.count >= 2, lines.allSatisfy({ $0.hasSuffix(": nothing left running") }) { return ["Memory freed on both Macs \u{2713}"] }
        return ["Memory:"] + lines.map { "  " + $0 }
    }

    /// `darkbloom stop` or `restart` without `--solo` (and `cluster stop` without `--service`) while this Mac's pairing
    /// record can't be read: it can't tell which pair to act on, so nothing changes, and `--solo` acts on single-Mac
    /// serving alone.
    func unsureRefusal(_ command: String, _ done: String) -> [String] {
        [pairSentence, "`darkbloom \(command)` can't tell which pair to \(command), so nothing was \(done).",
         "To \(command) single-Mac serving on this Mac only: `darkbloom \(command) --solo`. " + Self.checkPairingLine]
    }

    /// `darkbloom start` without `--solo` while this Mac's pairing record can't be read: refused, since single-Mac
    /// serving would compete with a cluster this Mac may be in.
    var startRefusal: [String] {
        [pairSentence,
         "Single-Mac serving next to a cluster would compete for this Mac's memory. To serve on this Mac alone, run "
            + "`darkbloom cluster` on this Mac to check the pairing first, or pass --solo."]
    }

    /// `darkbloom start` with single-Mac options (`--model`, `--local`, …) but no `--solo` on a Mac in a cluster:
    /// nothing starts, since they would otherwise be ignored. `--local` has a pair form (`darkbloom cluster local`).
    func singleMacOptionsRefusal(_ options: [String]) -> [String] {
        let named = options.map { "`\($0)`" }
        let list = named.count < 2 ? named.joined() : named.dropLast().joined(separator: ", ") + " and " + named.last!
        var lines = ["This Mac is in a two-Mac cluster with \(otherMac): \(list) \(named.count == 1 ? "is" : "are") for "
                        + "single-Mac serving, so nothing was started.",
                     "To choose the pair's model, run `darkbloom start` in a terminal; to serve this Mac alone with "
                        + "\(named.count == 1 ? "it" : "them"), add --solo."]
        if options.contains(where: { $0 == "--local" || $0 == "--local-endpoint" }) {
            lines.append("To serve the pair on the leading Mac's own API only: `darkbloom cluster local`.")
        }
        return lines
    }

    /// `darkbloom start --solo` on a Mac in a cluster: one line, and single-Mac serving starts.
    var startNote: String {
        if pairingUnreadable {
            return "Starting single-Mac serving (--solo) although this Mac's pairing record couldn't be read: if it is in a "
                + "two-Mac cluster, both use this Mac's memory."
        }
        return started
            ? "Starting single-Mac serving beside the two-Mac cluster with \(otherMac) (--solo): both use this Mac's memory."
            : "This Mac is in a two-Mac cluster with \(otherMac), which is stopped. Stop single-Mac serving (`darkbloom stop "
                + "--solo`) before you start the pair again (`darkbloom start`)."
    }

    /// `darkbloom stop --solo` where no single-Mac serving runs on a Mac in a cluster.
    var soloStopNothing: [String] {
        ["`darkbloom stop --solo` stops single-Mac serving, and none runs on this Mac: nothing was stopped.", soloLeftPair("stop")]
    }

    /// After `darkbloom stop --solo` (or `--uninstall`) stopped single-Mac serving on a Mac in a cluster.
    var stopAddendum: [String] { [pairSentence, soloLeftPair("stop")] }

    /// `darkbloom restart --solo` where no single-Mac serving is installed.
    var restartRefusal: [String] {
        [pairSentence, "`darkbloom restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
         soloLeftPair("restart")]
    }

    /// After `darkbloom restart --solo` restarted single-Mac serving on a Mac in a cluster.
    var restartAddendum: String {
        pairSentence + (pairingUnreadable ? " No cluster was restarted." : " " + soloLeftPair("restart"))
    }

    /// `--solo` left the pair alone: "The pair was not stopped; `darkbloom stop` stops both Macs."
    private func soloLeftPair(_ command: String) -> String {
        if pairingUnreadable { return Self.checkPairingLine }
        return "The pair was not \(command == "stop" ? "stopped" : "restarted"); `darkbloom \(command)` \(command)s both Macs."
    }

    /// The end of `darkbloom start` and `restart` on a Mac in a cluster, shaped like single-Mac start's block.
    var resultLines: [String] {
        var out = stateLines
        if out.isEmpty { out = ["\u{2026} Not serving yet."] }
        out.append("  Model:   " + modelWords)
        out.append("  Macs:    " + rolesWords)
        out.append("  Serves:  " + servesWords)
        if state != .serving, let next { out.append("  Next:    " + next) }
        out += ["", "  darkbloom stop     Stop both Macs", "  darkbloom restart  Restart with the current model",
                "  darkbloom status   Check status"]
        return out
    }

    // MARK: - darkbloom status and doctor (no network)

    /// One line for `darkbloom status --solo` and `darkbloom doctor`, from what this Mac knows by itself.
    var statusLine: String {
        guard paired else { return "Cluster: not in a cluster" }
        if pairingUnreadable {
            return "Cluster: this Mac's pairing record couldn't be read" + (reason.map { " (\($0))" } ?? "")
                + " · run `darkbloom cluster` to check it (details: `darkbloom cluster status`)"
        }
        var parts = [role.map { $0 == .leader ? "this Mac leads" : "this Mac follows" } ?? "this Mac is paired", otherMac]
        if let model { parts.append("\(model) \(servesWords)") }
        let now: String
        switch state {
        case .serving: now = "serving"
        case .loading: now = "loading"
        case .notServing: now = "not serving" + (reason.map { ": " + $0 } ?? "")
        case .stopped: now = "stopped"
        case .otherMacAway: now = reason ?? "the other Mac isn't answering"
        case .notPaired, .unknown, .pairingUnreadable: now = started ? "started" : "stopped"
        }
        parts.append(now)
        return "Cluster: " + parts.joined(separator: " · ") + " (details: `darkbloom cluster status`)"
    }

    /// `darkbloom status --solo` instead of "Daemon: not running (run `darkbloom start`)" on a Mac in a cluster.
    static let singleMacServingOffLine =
        "Single-Mac serving: off (this Mac serves in its two-Mac cluster: `darkbloom cluster status`)"
    /// The same when this Mac's pairing record couldn't be read.
    static let singleMacServingOffUnsureLine =
        "Single-Mac serving: off (this Mac may be in a two-Mac cluster: `darkbloom cluster status`)"
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

    /// The state the status lines of `darkbloom cluster` say, read as the other Mac's window reads them
    /// (`ClusterOnboardingDriver.showOutcome`): "Serving …" serves, "<model> is not serving yet: <reason>." does not.
    /// `leaderMode`: this Mac's own control mode when it leads (the lines are its own then).
    static func state(ofStatus lines: [String], started: Bool, leaderMode: String?) -> (state: State, reason: String?) {
        guard let first = lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }), !first.isEmpty else {
            return (started ? .unknown : .stopped, nil)
        }
        if first.hasPrefix("Serving ") { return (.serving, nil) }
        if let reason = ClusterOnboardingNotServing.reason(inStatusLine: first) {
            return (reason == "the coordinator paired both Macs" ? .loading : .notServing, reason)
        }
        if first.hasPrefix("Stopped") { return (.stopped, nil) }
        if first.hasPrefix("Loading ") || first.hasPrefix("Starting ") || first == ClusterOnboardingUpdate.statusLine {
            return (.loading, nil)
        }
        if let leaderMode, otherMacAwayModes.contains(leaderMode) {
            return (.otherMacAway, first.hasSuffix(".") ? String(first.dropLast()) : first)
        }
        if saysOtherMacSilent(first) { return (.otherMacAway, nil) }
        return (started ? .unknown : .stopped, nil)
    }

    /// What to do next, in commands.
    var next: String? {
        switch state {
        case .notPaired: return "To set up a cluster: `darkbloom cluster` on each Mac."
        case .serving: return "To stop or change it: `darkbloom cluster` on \(leadingMac)."
        case .loading: return "Loading takes a few minutes for a large model; check again with `darkbloom cluster status`."
        case .stopped:
            return "`darkbloom start` on either Mac starts the pair again."
                + (serviceRunning ? "" : " This Mac's cluster service is off; `darkbloom start` here turns it back on.")
        case .otherMacAway:
            return "\(ClusterOnboardingMacName.sentence(otherMac)) isn't answering over the cable. Its cluster service may "
                + "have been turned off with `darkbloom cluster stop --service`, or that Mac is asleep, off, or waiting for "
                + "someone to log in. On that Mac, run `darkbloom start` (or `darkbloom cluster`)."
        case .notServing:
            let reason = reason ?? ""
            if ClusterOnboardingNotServing.isMissingLogin(reason) {
                return "Run `darkbloom login` on each Mac named, then `darkbloom cluster` on \(leadingMac). Or serve "
                    + "locally only: `darkbloom cluster local` on \(leadingMac)."
            }
            if reason.contains("isn't verified by Apple yet") {
                return "Leave both Macs running: Darkbloom retries by itself. Or serve locally only: `darkbloom cluster local` "
                    + "on \(leadingMac)."
            }
            if reason.contains("lacks free memory") {
                return "Quit apps on that Mac; the cluster starts again by itself. Or choose a smaller model: "
                    + "`darkbloom cluster` on \(leadingMac)."
            }
            return "Both Macs keep trying by themselves; `darkbloom cluster` on \(leadingMac) shows more."
        case .unknown: return "`darkbloom cluster` on \(leadingMac) shows more."
        case .pairingUnreadable: return Self.checkPairingLine
        }
    }

    /// Reads the status lines `darkbloom cluster` shows (on the Mac that follows, the leading Mac's): the state, its
    /// reason, and whether the other Mac answered, which follows the state so the two never disagree.
    mutating func read(status: [String], leaderMode: String?) {
        lines = status.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        (state, reason) = Self.state(ofStatus: lines, started: started, leaderMode: leaderMode)
        if role == .member {
            // The lines came from the leading Mac unless they say it didn't answer (`saysOtherMacSilent`).
            otherMacAnswers = state != .otherMacAway
        } else if state == .otherMacAway {
            otherMacAnswers = false
        }
    }

    /// `darkbloom cluster status`: who leads, the model and its split, how it serves, whether it serves now (the
    /// screens' words) and what to do.
    var clusterStatusLines: [String] {
        if pairingUnreadable { return [pairSentence, "Next: " + Self.checkPairingLine] }
        guard paired else { return ["This Mac isn't in a cluster.", "Next: " + (next ?? "")] }
        var out = ["Cluster: " + rolesWords, "Model: " + modelWords]
        out.append("Serves: " + servesWords + (localOnly ? " (API key: `darkbloom local` on the Mac that serves it)" : ""))
        out.append(contentsOf: stateLines)
        if let next { out.append("Next: " + next) }
        return out
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
        case .stopped: return ["\u{25A0} " + (first ?? "Stopped" + (model.map { "; last model " + $0 } ?? "") + ".")] + rest
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
                + "Macs until the port is set up again with `darkbloom cluster` (or `darkbloom cluster link --fix`)."]
        }
        return ["This Mac is paired with \(otherMac), and the cable carries their cluster.",
         "--remove undoes the cable port setup that works now: the cluster stops serving on both Macs until the port is "
            + "set up again with `darkbloom cluster` (or `darkbloom cluster link --fix`)."]
    }

    static let linkRemoveQuestion = "Remove it? [y/N] "
    static let linkRemoveNeedsYes = "Nothing changed. To remove it anyway without a question, add --yes."
    static let nothingChanged = "Nothing changed."

    /// `darkbloom cluster stop` on the Mac that follows a started cluster: the leading Mac stops both Macs, as the
    /// menu's Stop does (it no longer leaves the leader waiting for a member that went away).
    static func memberStopNote(leader: String) -> String {
        "This Mac follows \(leader), which leads: `darkbloom cluster stop` stops the cluster on both Macs."
    }

    /// When the leading Mac could not stop the cluster: nothing changed here, and how to stop this Mac alone.
    /// What the Mac that follows says after its forwarded stop failed.
    static func memberStopFailureLines(_ failure: [String]) -> [String] { [memberStopFailedLine] }

    static let memberStopFailedLine =
        "Nothing was stopped on this Mac. To stop only this Mac: `darkbloom cluster stop --local-only` (the other Mac then "
            + "serves alone, or waits for this one)."
}
