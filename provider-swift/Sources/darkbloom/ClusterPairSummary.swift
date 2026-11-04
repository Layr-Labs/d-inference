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

    /// Single-Mac serving here needs `--solo` (`darkbloom start` and `restart`): the cluster service runs, or this Mac
    /// may be in a cluster (its pairing record couldn't be read).
    var singleMacServingNeedsSolo: Bool { serviceRunning || pairingUnreadable }

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

    /// How to stop the cluster, or that it is stopped.
    var stopClusterLine: String {
        if pairingUnreadable { return "Run `darkbloom cluster` on this Mac to check it; `darkbloom cluster stop` stops a cluster on both Macs." }
        return started ? "To stop the cluster: `darkbloom cluster stop` (both Macs stop), or Stop in `darkbloom cluster` on \(leadingMac)."
            : "The cluster is stopped; `darkbloom cluster` on \(leadingMac) starts it again."
    }

    /// `darkbloom stop` where no single-Mac serving runs: nothing is drained or disabled (the end user's session 2:
    /// "Provider service is not running" while his pair kept serving). Exit 1 while the cluster is started, or may be.
    var stopRefusal: (lines: [String], exitCode: Int32) {
        ([pairSentence, "`darkbloom stop` stops single-Mac serving, and none runs on this Mac: nothing was stopped.", stopClusterLine],
         started || pairingUnreadable ? 1 : 0)
    }

    /// After `darkbloom stop` stopped single-Mac serving on a Mac that is also in a cluster.
    var stopAddendum: [String] {
        [pairSentence, started ? "The cluster was not stopped. " + stopClusterLine : stopClusterLine]
    }

    /// `darkbloom start` (and `restart`) while this Mac's cluster service runs: refused unless `--solo` asks for
    /// single-Mac serving beside it by name.
    var startRefusal: [String] {
        if pairingUnreadable {
            return [pairSentence,
                    "Single-Mac serving next to a cluster would compete for this Mac's memory. To serve on this Mac alone, run "
                        + "`darkbloom cluster` on this Mac to check the pairing first, or pass --solo."]
        }
        return [pairSentence,
                "Single-Mac serving next to it would compete for this Mac's memory. To serve on this Mac alone, stop the cluster "
                    + "first (`darkbloom cluster stop`), or pass --solo."]
    }

    /// `darkbloom start --solo`, or a start while the cluster service is off: one line, and the start goes on.
    var startNote: String {
        if pairingUnreadable {
            return "Starting single-Mac serving (--solo) although this Mac's pairing record couldn't be read: if it is in a "
                + "two-Mac cluster, both use this Mac's memory."
        }
        return serviceRunning
            ? "Starting single-Mac serving beside the two-Mac cluster with \(otherMac) (--solo): both use this Mac's memory."
            : "This Mac is in a two-Mac cluster with \(otherMac), which is stopped. Stop single-Mac serving (`darkbloom stop`) "
                + "before you start the cluster again."
    }

    /// `darkbloom restart` where no single-Mac serving is installed.
    var restartRefusal: [String] {
        [pairSentence, "`darkbloom restart` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
         pairingUnreadable ? Self.checkPairingLine
            : "To restart the cluster: Stop, then start the model again in `darkbloom cluster` on \(leadingMac)."]
    }

    /// After `darkbloom restart --solo` restarted single-Mac serving on a Mac in a cluster.
    var restartAddendum: String {
        pairSentence + (pairingUnreadable ? " No cluster was restarted." : " The cluster was not restarted.")
    }

    // MARK: - darkbloom status and doctor (no network)

    /// One line for `darkbloom status` and `darkbloom doctor`, from what this Mac knows by itself.
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

    /// `darkbloom status` instead of "Daemon: not running (run `darkbloom start`)" on a Mac in a cluster.
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
            return "To start it again: `darkbloom cluster` on \(leadingMac), then choose the model."
                + (serviceRunning ? "" : " This Mac's cluster service is off; `darkbloom cluster` starts it again.")
        case .otherMacAway:
            return "\(ClusterOnboardingMacName.sentence(otherMac)) isn't answering over the cable. Its cluster service is "
                + "probably off (it was stopped with `darkbloom cluster stop`), or that Mac is asleep, off, or waiting for "
                + "someone to log in. On that Mac, run `darkbloom cluster`."
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
        let this = thisMacName.map { "this Mac (\($0))" } ?? ClusterOnboardingMacName.this
        let roles: String
        switch role {
        case .leader: roles = "\(this) leads · \(otherMac) follows"
        case .member: roles = "\(this) follows · \(otherMac) leads"
        case nil: roles = "\(this) is paired with \(otherMac)"
        }
        var out = ["Cluster: " + roles]
        if let model {
            let split = modeAndSplit.map { " · " + $0.mode + ($0.split.map { " · " + $0 } ?? "") } ?? ""
            out.append("Model: " + model + split)
        } else {
            out.append("Model: none chosen yet")
        }
        out.append("Serves: " + servesWords + (localOnly ? " (API key: `darkbloom local` on the Mac that serves it)" : ""))
        out.append(contentsOf: stateLines)
        if let next { out.append("Next: " + next) }
        return out
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
    static let memberStopFailedLine =
        "Nothing was stopped on this Mac. To stop only this Mac: `darkbloom cluster stop --local-only` (the other Mac then "
            + "serves alone, or waits for this one)."
}
