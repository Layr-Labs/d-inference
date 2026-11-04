import Foundation

// A pair the coordinator forms (a setup saved with a cluster approval, "offered for pairing") serves only once the
// coordinator committed it and both Macs loaded their share: both members being registered is not serving. On
// 2026-11-03 both screens said "Serving" and "Done" while nothing was loaded (the coordinator refused the pair because
// its rank 0 had no App Attest trust). Pure (Foundation only): the onboarding checks compile it with plain swiftc.

/// How a coordinator-paired part reports its pair's progress in its log (its stderr, the cluster service's
/// `rank.log`): one line per change, the latest one telling where the CURRENT run stands.
public enum ClusterOnboardingPairReport {
    public static let logPrefix = "Pair: "

    /// The coordinator committed a start: both Macs load their share of the model.
    public static let startingLine = logPrefix + "starting"

    /// Both ranks loaded and the pair answered its own first request (the warm-up, `ProviderLoop+ClusterPairWarmup`);
    /// requests from the coordinator reach it now.
    public static func servingLine(warmupSeconds: Double?) -> String {
        logPrefix + "serving" + (warmupSeconds.map { " (first request in \(String(format: "%.2f", $0)) s)" } ?? "")
    }

    /// The committed start ended or never formed. `guidance` is the incident's guidance code (`ClusterGuidance`, such as
    /// `memory_gate_refused`), or a few fixed words.
    public static func stoppedLine(_ guidance: String) -> String { logPrefix + "stopped (" + guidance + ")" }

    public enum State: Sendable, Equatable {
        case starting
        /// The first request's time ("in 0.84 s") when the warm-up ran.
        case serving(test: String?)
        /// Why, as the part wrote it (a guidance code or a few fixed words).
        case stopped(String)
    }

    /// The latest pair line in `log`, nil when there is none.
    public static func latest(inLog log: String) -> State? {
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(logPrefix) }) else { return nil }
        return state(String(line.dropFirst(logPrefix.count)))
    }

    /// The state a pair line's text (after the prefix) says; nil for text no build writes.
    public static func state(_ text: String) -> State? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text == "starting" { return .starting }
        if text.hasPrefix("serving") {
            guard let open = text.range(of: "(first request in "), let close = text.range(of: ")", range: open.upperBound..<text.endIndex)
            else { return .serving(test: nil) }
            return .serving(test: "in " + text[open.upperBound..<close.lowerBound])
        }
        if text.hasPrefix("stopped (") , text.hasSuffix(")") {
            return .stopped(String(text.dropFirst("stopped (".count).dropLast()))
        }
        return nil
    }

    /// The text a status carries for `state` (`ClusterServiceStatus.Child.pair`): the line without its prefix.
    public static func text(_ state: State) -> String {
        switch state {
        case .starting: return String(startingLine.dropFirst(logPrefix.count))
        case .serving(let test):
            return String(servingLine(warmupSeconds: nil).dropFirst(logPrefix.count)) + (test.map { " (first request \($0))" } ?? "")
        case .stopped(let why): return String(stoppedLine(why).dropFirst(logPrefix.count))
        }
    }
}

/// The live rows while the parts load: the first row is the wait itself, then one row per Mac ("This Mac: loading
/// its share"), each with the time since the wait began; a Mac's time stops when it is first seen ready. A progress
/// report carries the Mac rows after its first line, one per line. No bar or percent: no real fraction is reported.
public struct ClusterOnboardingLoadRows: Sendable {
    public let started: Date
    private var readyAt: [String: Date] = [:]

    public init(started: Date) { self.started = started }

    public mutating func rows(_ title: String, report: String?, now: Date) -> [String] {
        let parts = report?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let head = (parts.first.map { "\(title) (\($0))" } ?? title) + " \u{00B7} " + Self.elapsed(now.timeIntervalSince(started))
        return [head] + parts.dropFirst().map { row in
            let mac = row.components(separatedBy: ": ").first ?? row
            if row.hasSuffix(": ready"), readyAt[mac] == nil { readyAt[mac] = now }
            let end = row.hasSuffix(": ready") ? readyAt[mac] ?? now : now
            return row + " \u{00B7} " + Self.elapsed(end.timeIntervalSince(started))
        }
    }

    /// "48 s", "1 min 15 s".
    static func elapsed(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return whole < 60 ? "\(whole) s" : "\(whole / 60) min \(whole % 60) s"
    }
}

/// Why a pair the coordinator forms does not serve, in one plain line for the screens, with what to do. The words come
/// from what the two Macs know: their Darkbloom login, the coordinator's trust status for each member (App Attest),
/// the guidance of the incident a failed start recorded, and a coordinator refusal reason when one reaches them.
public enum ClusterOnboardingNotServing {
    /// `mac` as the screen names it ("this Mac", "the other Mac (Apple M3 Ultra, 256 GB)").
    public static func notLoggedIn(_ macs: [String]) -> String {
        "\(ClusterOnboardingMacName.sentence(joined(macs))) \(macs.count == 1 ? "isn't" : "aren't") logged in to Darkbloom, "
            + "so the coordinator won't pair \(macs.count == 1 ? "it" : "them")"
    }

    /// The coordinator pairs only members Apple has verified (App Attest). `retryAt`: when this Mac's local
    /// key-generation safeguard lets Darkbloom try again, said in local time; unknown, "within minutes". A restart
    /// meanwhile cut an attestation once (an end user's M4 pair, 2026-11-03), so the line asks to leave both Macs alone.
    public static func notVerified(_ mac: String, retryAt: Date? = nil, timeZone: TimeZone = .current) -> String {
        let when = retryAt.map { "at about " + clock($0, timeZone: timeZone) } ?? "within minutes"
        return "\(ClusterOnboardingMacName.sentence(mac)) isn't verified by Apple yet; Darkbloom retries by itself \(when). "
            + "Don't restart either Mac until then"
    }

    /// "00:34": hours and minutes in `timeZone`.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    public static func lacksMemory(_ mac: String) -> String { "\(ClusterOnboardingMacName.sentence(mac)) lacks free memory for its share" }

    /// The plain words for a reason one of the Macs knows: a coordinator refusal word (`liveness:trust_floor`,
    /// `private_text`, `serves_model`, …) or an incident's guidance code (`memory_gate_refused`, …), about `mac`.
    public static func words(reason: String, mac: String) -> String {
        let reason = reason.lowercased()
        let trust = ["trust_floor", "private_text", "app_attest", "no_trust_evidence", "runtime_unverified", "challenge_stale",
                     "attestation", "untrusted", "private_only"]
        if trust.contains(where: reason.contains) { return notVerified(mac) }
        if reason.contains("memory_gate") || reason.contains("free_memory") || reason.contains("no_headroom") { return lacksMemory(mac) }
        if reason.contains("serves_model") || reason.contains("not_serving_model") {
            return "The coordinator doesn't let \(mac) serve this model in a pair"
        }
        if reason.contains("offline") || reason.contains("heartbeat") || reason.contains("not_logged_in") {
            return "\(ClusterOnboardingMacName.sentence(mac)) isn't connected to Darkbloom"
        }
        if reason.contains("idle:") || reason.contains("busy") { return "\(ClusterOnboardingMacName.sentence(mac)) is busy with other work" }
        if reason.contains("release") || reason.contains("build_hash") { return "The two Macs run different Darkbloom builds" }
        if reason.contains("clock") { return "The clock of \(mac) is off; turn on Set time automatically there" }
        let shown = reason.count <= 80 && ClusterOnboardingDeployment.shownPlainly(reason) ? reason : "no reason given"
        return "The coordinator didn't accept the pair (\(shown))"
    }

    /// What to do next, said under the reason (the choices follow it).
    public static func remedy(forReason line: String) -> String? {
        if line.contains("logged in to Darkbloom") { return "Run `darkbloom login` on each Mac named, then Retry; or serve locally only." }
        if line.contains("isn't verified by Apple yet") { return "Then choose Retry, or serve locally only now." }
        if line.contains("lacks free memory") { return "Quit apps on that Mac, then Retry; or change the model." }
        return nil
    }

    static func joined(_ macs: [String]) -> String {
        macs.count <= 1 ? (macs.first ?? ClusterOnboardingMacName.other) : macs.dropLast().joined(separator: ", ") + " and " + macs.last!
    }
}
