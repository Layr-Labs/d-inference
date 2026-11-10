import Foundation

// How far the leading Mac's start is, published in its status so the Mac that joined shows the same steps and figures
// as the leading Mac's own screen (owner, 2026-11-04: "The member should show progress throughout each step so it's not
// just in the dark, maybe a progress bar and so on"). Only measured facts: the bytes of a copy or download as the
// sending Mac counts them, and which Mac's part is ready. Loading has no measure (the runtime reports nothing until
// Ready), so it gets a spinner and the time, never a percentage. Pure (Foundation only): the onboarding checks compile it.

/// The leading Mac's start, as both screens show it. Every field is optional on the wire: an older Mac sends none and
/// ignores them, and a later build's phase reads as `unknown`.
public struct ClusterOnboardingStartProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// The leading Mac downloads the model (then copies it to the other Mac).
        case downloading
        /// The model's files cross the cable (`toLeader`: to the leading Mac).
        case copying
        /// A model that served stops on both Macs (each frees its memory) before the new setup.
        case stopping
        /// Both Macs' parts start, link and load their share.
        case loading
        /// The leading Mac sends the test request.
        case testing
        /// The pair registers with Darkbloom's coordinator.
        case registering
        /// The start ended with ✗ on the leading Mac's screen (`title`, `lines`; `retry`: its screen offers Retry). The
        /// Mac that joined ends with the same ✗; it never judges the pair by a wait of its own.
        case failed
        /// A phase a later build adds.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// One Mac's part while the parts load, by its rank (each screen names it "This Mac" or "The other Mac").
    public struct Part: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case starting, loading, ready, ended, unknown

            public init(from decoder: any Decoder) throws {
                self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }
        public var rank: Int
        public var state: State
        /// Its share of the model's layers ("47–93"), when the saved setup says.
        public var layers: String?
        /// `ended`: how it ended ("exit 1"), and the seconds until it starts again.
        public var end: String?
        public var restartIn: Int?

        public init(rank: Int, state: State, layers: String? = nil, end: String? = nil, restartIn: Int? = nil) {
            self.rank = rank; self.state = state; self.layers = layers; self.end = end; self.restartIn = restartIn
        }
    }

    public var phase: Phase
    /// `downloading`/`copying`: the bytes so far, of `total`, as the sending Mac counts them.
    public var done: Int64?
    public var total: Int64?
    /// `copying`: the files go to the leading Mac (from the Mac that joined); nil or false: to the Mac that joined.
    public var toLeader: Bool?
    /// `loading`: every part, by rank.
    public var parts: [Part]?
    /// When this phase began (seconds since 1970), so both screens count from the same moment.
    public var since: Double?
    /// `failed`: the leading Mac's ✗ title and the lines under it, each Mac named by its part (`failed(title:lines:retry:)`),
    /// and whether its screen offers Retry.
    public var title: String?
    public var lines: [String]?
    public var retry: Bool?

    public init(_ phase: Phase, done: Int64? = nil, total: Int64? = nil, toLeader: Bool? = nil, parts: [Part]? = nil,
                since: Double? = nil) {
        self.phase = phase; self.done = done; self.total = total; self.toLeader = toLeader; self.parts = parts; self.since = since
    }

    /// The leading Mac's final ✗, from its screen's words: "this Mac" (the leading Mac) and "the other Mac (…)" (the Mac
    /// that joined) are kept as who they are, so the Mac that joined names each from its side (`viewed(leader:)`).
    public static func failed(title: String, lines: [String], retry: Bool) -> ClusterOnboardingStartProgress {
        var made = ClusterOnboardingStartProgress(.failed)
        made.title = Self.byPart(title)
        made.lines = lines.map(Self.byPart)
        made.retry = retry
        return made
    }

    /// The same, as the Mac that joined says it: the leading Mac named `leader` ("the other Mac (Apple M3 Ultra, …)"),
    /// itself "this Mac".
    public func viewed(leader: String?) -> ClusterOnboardingStartProgress {
        var shown = self
        func view(_ text: String) -> String {
            let other = ClusterOnboardingMacName.other(named: leader)
            return text.replacingOccurrences(of: Self.joinedToken.upper, with: ClusterOnboardingMacName.sentence(ClusterOnboardingMacName.this))
                .replacingOccurrences(of: Self.joinedToken.lower, with: ClusterOnboardingMacName.this)
                .replacingOccurrences(of: Self.leaderToken.upper, with: ClusterOnboardingMacName.sentence(other))
                .replacingOccurrences(of: Self.leaderToken.lower, with: other)
        }
        shown.title = title.map(view)
        shown.lines = lines?.map(view)
        return shown
    }

    static let joinedToken = (upper: "\u{1}J", lower: "\u{1}j")
    static let leaderToken = (upper: "\u{1}L", lower: "\u{1}l")

    /// The leading Mac's words with each Mac as a token: "the other Mac" with or without its name is the Mac that
    /// joined, "this Mac" with or without its name the leading Mac. A name starts with a capital ("(Apple M3 Ultra, …)",
    /// "(Studio A)"); other words in parentheses after it stay ("on this Mac (no Darkbloom traffic)", R7-1).
    static func byPart(_ text: String) -> String {
        var text = text
        for (pattern, upper, lower) in [(#"([Tt])he other Mac( \([A-Z][^)]*\))?"#, joinedToken.upper, joinedToken.lower),
                                        (#"([Tt])his Mac( \([A-Z][^)]*\))?"#, leaderToken.upper, leaderToken.lower)] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let first = Range(match.range(at: 1), in: text) else { continue }
                text.replaceSubrange(range, with: text[first] == "T" ? upper : lower)
            }
        }
        return text
    }

    /// The parts ready, of all of them.
    public var readyParts: (ready: Int, of: Int)? {
        guard let parts, !parts.isEmpty else { return nil }
        return (parts.filter { $0.state == .ready }.count, parts.count)
    }

    /// The same phase again keeps its start; a new phase starts now.
    public func continuing(_ previous: ClusterOnboardingStartProgress?, now: Double) -> ClusterOnboardingStartProgress {
        var next = self
        next.since = previous?.phase == phase ? (previous?.since ?? now) : (since ?? now)
        return next
    }
}

/// The progress as the leading Mac records it: it counts while the process that published it runs (by pid and start
/// time), and a copy's, download's or load's figures only while they are fresh (they are published about once a second).
public struct ClusterOnboardingStartProgressMark: Codable, Sendable, Equatable {
    public var progress: ClusterOnboardingStartProgress
    public var pid: Int32
    /// When that process started (microseconds since 1970).
    public var started: UInt64
    /// When the progress was set (seconds since 1970).
    public var at: Double

    public init(progress: ClusterOnboardingStartProgress, pid: Int32, started: UInt64, at: Double) {
        self.progress = progress; self.pid = pid; self.started = started; self.at = at
    }

    /// Figures older than this are not shown: whoever published them stopped.
    public static let freshSeconds: Double = 30
    /// How long the leading Mac's ✗ counts as the start's outcome.
    public static let outcomeSeconds: Double = 1_800

    public func current(now: Double, started processStarted: (Int32) -> UInt64?) -> ClusterOnboardingStartProgress? {
        // The leading Mac's ✗ outlives its screen for a while (the person may leave it): it is the start's outcome.
        if progress.phase == .failed { return now - at < Self.outcomeSeconds ? progress : nil }
        guard processStarted(pid) == started else { return nil }
        switch progress.phase {
        case .downloading, .copying, .loading: return now - at < Self.freshSeconds ? progress : nil
        default: return progress
        }
    }
}

/// The steps of the start both screens list, in order. Files only when a copy or download runs; Darkbloom only when
/// the pair serves through Darkbloom.
public enum ClusterOnboardingStartStep: String, Sendable, CaseIterable {
    case files, setup, load, test, darkbloom

    public var name: String {
        switch self {
        case .files: return "Files"
        case .setup: return "Setup"
        case .load: return "Load"
        case .test: return "Test"
        case .darkbloom: return "Darkbloom"
        }
    }

    public init?(_ phase: ClusterOnboardingStartProgress.Phase) {
        switch phase {
        case .downloading, .copying: self = .files
        case .stopping: self = .setup
        case .loading: self = .load
        case .testing: self = .test
        case .registering: self = .darkbloom
        case .failed, .unknown: return nil
        }
    }

    /// "Next: test, Darkbloom" (nil when nothing follows).
    public static func nextLine(after step: ClusterOnboardingStartStep, darkbloom: Bool) -> String? {
        let all = allCases.filter { $0 != .files && ($0 != .darkbloom || darkbloom) }
        guard let index = all.firstIndex(of: step) ?? (step == .files ? -1 : nil) else { return nil }
        let rest = all.dropFirst(index + 1).map { $0 == .darkbloom ? $0.name : $0.name.lowercased() }
        return rest.isEmpty ? nil : "Next: " + rest.joined(separator: ", ")
    }
}

/// The words and rows of the start's progress, fitted to a width (the room a live row has: the window's columns less
/// its indent and marks). A nil width is the plain form, whole.
public enum ClusterOnboardingStartWords {
    /// "68.2 GB".
    public static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(max(0, bytes)) / 1e9) }

    /// Rounded down and never 100 before the last byte: a bar that says done is done.
    public static func percent(_ done: Int64, of total: Int64) -> Int {
        guard total > 0 else { return 0 }
        let value = Int(Double(min(max(0, done), total)) / Double(total) * 100)
        return done >= total ? 100 : min(value, 99)
    }

    /// The bar of a copy or download: label, bar, percent and bytes, the parts dropped as room shrinks (bytes, then the
    /// label, then the bar). Plain (nil width): no bar.
    public static func bar(label: String, done: Int64, total: Int64, width: Int?) -> String {
        let percent = percent(done, of: total)
        let figure = (percent < 10 ? "  " : percent < 100 ? " " : "") + "\(percent)%"
        let bytes = gigabytes(done).replacingOccurrences(of: " GB", with: "") + "/" + gigabytes(total)
        guard let width else { return "\(label)  \(percent)%  \(bytes)" }
        func drawn(_ cells: Int) -> String {
            let filled = Int(Double(cells) * Double(min(max(0, done), max(total, 1))) / Double(max(total, 1)))
            return "[" + String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: cells - filled) + "]"
        }
        for (head, tail) in [(label + " ", " " + figure + "  " + bytes), ("", " " + figure + "  " + bytes),
                             (label + " ", " " + figure), ("", " " + figure)] {
            let cells = min(30, width - head.count - tail.count - 2)
            if cells >= 8 { return head + drawn(cells) + tail }
        }
        return fitted([figure.trimmingCharacters(in: .whitespaces) + "  " + bytes, figure.trimmingCharacters(in: .whitespaces)], width: width)
    }

    /// The first of `candidates` that fits `width` (nil: the first), else the last one cut to it.
    public static func fitted(_ candidates: [String], width: Int?) -> String {
        guard let width else { return candidates.first ?? "" }
        return candidates.first { $0.count <= width } ?? String((candidates.last ?? "").prefix(max(1, width)))
    }

    /// One Mac's part, from the viewer's side (`viewerRank`: the rank this screen's Mac runs), long to short.
    public static func partRow(_ part: ClusterOnboardingStartProgress.Part, viewerRank: Int?, width: Int?) -> String {
        let here = part.rank == viewerRank
        let names = here ? ["This Mac"] : ["The other Mac", "Other Mac"]
        let layers = part.layers.map { " (layers \($0))" } ?? ""
        let states: [String]
        switch part.state {
        case .ready: states = ["ready" + layers, "ready"]
        case .loading: states = ["loading its share" + layers, "loading its share", "loading"]
        case .starting: states = ["starting its part", "starting"]
        case .ended:
            let again = part.restartIn.map { "; starts again in \($0) s" } ?? "; starts again by itself"
            states = ["part ended (\(part.end ?? "ended"))" + again, "part ended" + again, "ended"]
        case .unknown: states = ["starting"]
        }
        var candidates = [String]()
        for name in names { for state in states { candidates.append(name + ": " + state) } }
        return fitted(candidates.sorted { $0.count > $1.count }, width: width)
    }

    /// The rows of every part, this Mac's first.
    public static func partRows(_ parts: [ClusterOnboardingStartProgress.Part], viewerRank: Int?, width: Int?) -> [String] {
        parts.sorted { ($0.rank == viewerRank ? 0 : 1, $0.rank) < ($1.rank == viewerRank ? 0 : 1, $1.rank) }
            .map { partRow($0, viewerRank: viewerRank, width: width) }
    }

    /// What the current step waits on, long to short.
    public static func headCandidates(_ progress: ClusterOnboardingStartProgress, viewerLeads: Bool) -> [String] {
        let other = "the other Mac"
        switch progress.phase {
        case .downloading:
            return viewerLeads ? ["Files: downloading the model", "Files: downloading"]
                : ["Files: \(other) downloads the model, then copies it here", "Files: downloading on \(other)", "Files: downloading"]
        case .copying:
            let toHere = viewerLeads == (progress.toLeader == true)
            return [toHere ? "Files: copying from \(other)" : "Files: copying to \(other)", "Files: copying"]
        case .stopping:
            return ["Setup: stopping the model that served (each Mac frees its memory first)", "Setup: stopping the old model",
                    "Setup: stopping"]
        case .loading:
            let count = progress.readyParts.map { " (\($0.ready) of \($0.of) parts ready)" } ?? ""
            return ["Load: both Macs" + count, "Load" + count.replacingOccurrences(of: " parts ready", with: ""), "Load"]
        case .testing:
            return viewerLeads ? ["Test: sending a test request", "Test"] : ["Test: \(other) sends a test request", "Test"]
        case .registering:
            return ["Darkbloom: registering both Macs with the coordinator", "Darkbloom: registering", "Darkbloom"]
        case .failed:
            return [progress.title ?? "Not serving"]
        case .unknown:
            return ["Starting"]
        }
    }

    /// The live rows under the heading: the step and its time, then its bar or its parts, then what comes next.
    public static func liveRows(_ progress: ClusterOnboardingStartProgress, viewerLeads: Bool, viewerRank: Int?,
                                darkbloom: Bool, elapsed: Double, width: Int?) -> [String] {
        let time = " \u{00B7} " + ClusterOnboardingLoadRows.elapsed(elapsed)
        var rows = [fitted(headCandidates(progress, viewerLeads: viewerLeads).map { $0 + time }, width: width)]
        switch progress.phase {
        case .downloading, .copying:
            if let done = progress.done, let total = progress.total, total > 0 {
                rows.append(bar(label: progress.phase == .downloading ? "Downloading" : "Copying", done: done, total: total, width: width))
            }
        case .loading:
            rows += partRows(progress.parts ?? [], viewerRank: viewerRank, width: width)
        default: break
        }
        if let step = ClusterOnboardingStartStep(progress.phase),
           let next = ClusterOnboardingStartStep.nextLine(after: step, darkbloom: darkbloom) {
            rows.append(fitted([next], width: width))
        }
        return rows
    }
}

/// What a screen says once as the start goes on: each step that begins and ends, each Mac's part as it changes, and a
/// copy's bytes about every 10% and 30 s. A live window shows the rest in its live rows; a plain window (a pipe) has
/// only these lines, never the same line twice.
public struct ClusterOnboardingStartLog: Sendable {
    public let viewerLeads: Bool
    public let viewerRank: Int?
    private var phase: ClusterOnboardingStartProgress.Phase?
    private var began: Double?
    private var parts = [Int: ClusterOnboardingStartProgress.Part.State]()
    private var logged: (percent: Int, at: Double)?
    private var said = Set<String>()

    public init(viewerLeads: Bool, viewerRank: Int?) { self.viewerLeads = viewerLeads; self.viewerRank = viewerRank }

    /// The lines to say for `progress` at `now` (seconds since 1970). `plain`: the window has no live rows, so the
    /// part changes and a copy's bytes are said too.
    public mutating func update(_ progress: ClusterOnboardingStartProgress?, now: Double, plain: Bool) -> [String] {
        guard let progress, progress.phase != .unknown, progress.phase != .failed else { return [] }
        var lines = [String]()
        if progress.phase != phase {
            if let phase, let step = ClusterOnboardingStartStep(phase), ClusterOnboardingStartStep(progress.phase) != step {
                lines.append(ClusterOnboardingDriver.done + " " + step.name
                             + (began.map { " (" + ClusterOnboardingLoadRows.elapsed(now - $0) + ")" } ?? ""))
            }
            phase = progress.phase
            began = progress.since ?? now
            logged = nil
            parts = [:]
            if plain { lines.append(ClusterOnboardingStartWords.headCandidates(progress, viewerLeads: viewerLeads)[0]) }
        }
        if plain, let done = progress.done, let total = progress.total, total > 0 {
            let percent = ClusterOnboardingStartWords.percent(done, of: total)
            if logged == nil || (percent >= logged!.percent + 10 && now - logged!.at >= 30) || (percent == 100 && logged!.percent < 100) {
                logged = (percent, now)
                lines.append(ClusterOnboardingStartWords.bar(label: progress.phase == .downloading ? "Downloading" : "Copying",
                                                             done: done, total: total, width: nil))
            }
        }
        if plain {
            let ordered = (progress.parts ?? []).sorted { ($0.rank == viewerRank ? 0 : 1, $0.rank) < ($1.rank == viewerRank ? 0 : 1, $1.rank) }
            for part in ordered where parts[part.rank] != part.state {
                parts[part.rank] = part.state
                lines.append(ClusterOnboardingStartWords.partRow(part, viewerRank: viewerRank, width: nil))
            }
        }
        return lines.filter { said.insert($0).inserted || $0.hasPrefix("Copying") || $0.hasPrefix("Downloading") }
    }

    /// When the start ended (served, or ✗): the step that ran, done, when it ran to its end.
    public mutating func finish(succeeded: Bool, now: Double) -> [String] {
        defer { phase = nil }
        guard succeeded, let phase, let step = ClusterOnboardingStartStep(phase) else { return [] }
        return [ClusterOnboardingDriver.done + " " + step.name + (began.map { " (" + ClusterOnboardingLoadRows.elapsed(now - $0) + ")" } ?? "")]
    }
}
