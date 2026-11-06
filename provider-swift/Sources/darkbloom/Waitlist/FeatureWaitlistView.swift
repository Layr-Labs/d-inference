import Foundation

/// The lines that tell an account which waitlists there are and where it
/// stands on them. A waitlist is named by the coordinator's `title` and
/// started with its `start_command`; every text of the coordinator goes
/// through `printable` on its way to the terminal.
struct FeatureWaitlistView: Sendable {
    /// The installed command, `darkbloom` or the DevNet `darkbloom-dev`.
    let cli: String
    /// The coordinator asked, for the problems that name it.
    let coordinator: String
    var day: @Sendable (Date) -> String = FeatureWaitlistView.mediumDate

    /// `darkbloom waitlist`: each waitlist and where the account stands on
    /// it, then how to join one it has not joined.
    func list(_ waitlists: [FeatureWaitlistPlace]) -> [String] {
        guard !waitlists.isEmpty else { return [noWaitlists] }
        var lines: [String] = []
        for waitlist in waitlists {
            if !lines.isEmpty { lines.append("") }
            lines.append("\(Self.printable(waitlist.title)) (\(Self.printable(waitlist.feature))): \(standing(waitlist))")
            if let summary = waitlist.summary, !summary.isEmpty { lines.append("  \(Self.printable(summary))") }
            if waitlist.status == .approved, let start = start(waitlist) { lines.append("  Start: \(start)") }
        }
        if waitlists.contains(where: { $0.status == .none }) {
            lines += ["", "Join one: \(cli) waitlist <name>"]
        }
        return lines
    }

    /// The account's place, after `darkbloom waitlist <name>` or the
    /// `sandbox setup` gate. `name` is the waitlist as the command named it,
    /// for the command these lines suggest.
    func lines(_ place: FeatureWaitlistPlace, name: String) -> [String] {
        let title = Self.printable(place.title)
        switch place.status {
        case .none:
            return ["You're not on the \(title) waitlist.", joinLine(name)]
        case .waitlisted:
            var line = "You're on the \(title) waitlist"
            if let position = place.position { line += ": #\(position) in line" }
            if let requestedAt = place.requestedAt { line += " (joined \(day(requestedAt)))" }
            return [
                line + ".",
                "  Darkbloom reviews accounts in the order they joined and approves them by hand.",
                "  Check again: \(cli) waitlist \(name)",
            ]
        case .approved:
            let since = place.decidedAt.map { " since \(day($0))" } ?? ""
            return ["Your account is approved for \(title)\(since)."] + (start(place).map { ["  Start: \($0)"] } ?? [])
        case .revoked:
            let since = place.decidedAt.map { " on \(day($0))" } ?? ""
            return [
                "Darkbloom revoked your account's access to \(title)\(since).",
                "  Joining again does not restore it; contact Darkbloom if you think this is a mistake.",
            ]
        }
    }

    /// How to join the waitlist `name`; `sandbox setup` prints it too.
    func joinLine(_ name: String) -> String { "  Join it: \(cli) waitlist \(name)" }

    /// Why a waitlist call has no answer to show. `title` names the waitlist
    /// the call was about, and is nil for the list of waitlists.
    func problem(_ problem: FeatureWaitlistProblem, title: String? = nil) -> [String] {
        let title = title.map(Self.printable)
        switch problem {
        case .notOffered:
            guard let title else { return [noWaitlists] }
            return ["\(coordinator) has no \(title) waitlist."]
        case .needsLogin:
            return ["Link this Mac to your Darkbloom account first: \(cli) login"]
        case .refused(let reason):
            return ["\(coordinator) refused this account: HTTP 403: \(Self.printable(reason))",
                    "  Link this Mac to your Darkbloom account again: \(cli) login"]
        case .unavailable(let reason):
            let waitlist = title.map { "the \($0) waitlist" } ?? "the waitlists"
            // The reason may carry the coordinator's refusal message.
            return ["Could not reach \(waitlist) at \(coordinator): \(Self.printable(reason))"]
        }
    }

    /// No waitlist of the catalog is called `name`.
    func unknown(_ name: String, among waitlists: [FeatureWaitlistPlace]) -> [String] {
        guard !waitlists.isEmpty else { return [noWaitlists] }
        let names = waitlists.map { "\(Self.printable($0.feature)) (\(Self.printable($0.title)))" }
        let known = names.count == 1
            ? "The only waitlist is \(names[0])."
            : "The waitlists are \(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])."
        return ["Unknown waitlist '\(Self.printable(name))'. \(known)", "  See where you stand on each: \(cli) waitlist"]
    }

    private var noWaitlists: String { "\(coordinator) has no waitlists yet, so there is nothing to join there." }

    /// Where the account stands, in the list.
    private func standing(_ place: FeatureWaitlistPlace) -> String {
        switch place.status {
        case .none:
            return "not joined"
        case .waitlisted:
            let joined = place.requestedAt.map { " (joined \(day($0)))" } ?? ""
            return (place.position.map { "#\($0) in line" } ?? "on the waitlist") + joined
        case .approved:
            return "approved" + (place.decidedAt.map { " since \(day($0))" } ?? "")
        case .revoked:
            return "not approved" + (place.decidedAt.map { " (access revoked on \(day($0)))" } ?? "")
        }
    }

    /// The waitlist's start command for this CLI: a leading `darkbloom` is
    /// the installed command, such as the DevNet `darkbloom-dev`.
    private func start(_ place: FeatureWaitlistPlace) -> String? {
        guard let command = place.startCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        let program = "darkbloom"
        guard command == program || command.hasPrefix(program + " ") else { return Self.printable(command) }
        return Self.printable(cli + command.dropFirst(program.count))
    }

    @Sendable static func mediumDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The characters a line must not hand the terminal: controls (ESC, the
    /// C1 CSI, newlines), format characters (bidirectional overrides,
    /// zero-width marks) and the line and paragraph separators.
    private static let unprintable = CharacterSet.controlCharacters.union(.newlines)

    /// `text` from the coordinator as a line prints it: each unprintable
    /// character becomes U+FFFD, so a title, summary, start command or
    /// refusal cannot recolor, move, hide or reorder what the terminal shows.
    static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { unprintable.contains($0) ? "\u{FFFD}" : $0 }))
    }

    /// `json` with each unprintable character written as a `\u` escape: the
    /// same JSON, but inert in a terminal. JSONEncoder escapes U+0000 to
    /// U+001F itself, so what is left (DEL, the C1 controls, format
    /// characters, separators) lies inside strings.
    static func escapingUnprintable(json: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in json.unicodeScalars {
            guard scalar.value >= 0x7F, unprintable.contains(scalar) else {
                escaped.append(scalar)
                continue
            }
            for unit in String(scalar).utf16 {
                let hex = String(unit, radix: 16)
                escaped.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
            }
        }
        return String(escaped)
    }
}
