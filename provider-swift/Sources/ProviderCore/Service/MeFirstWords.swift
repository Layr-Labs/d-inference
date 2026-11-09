import Foundation

/// Me first in words: whether Darkbloom is paused for its owner, for how long, and when it comes back. `darkbloom status`
/// says it for one Mac ("Serving: …"), and the leading Mac's status for a pair ("Pair: …", `OnboardingLive.pauseLines`),
/// which both Macs show. Times are said from now: a clock time read on another Mac, or over SSH, is in a zone the reader
/// doesn't see (journey 2a on pair-2, J2-i: "paused since 21:41", read at 05:41 UTC). The words are made on the Mac whose
/// part wrote the snapshot, with its clock (`now`), so two Macs' clocks are never mixed. No speed.
public enum MeFirstWords {
    /// The start of the pair's line.
    public static let pairPrefix = "Pair: "

    /// Me first, open or paused, from a running provider's snapshot, after `prefix` ("Serving: ", `pairPrefix`). A second
    /// line, while Darkbloom requests finish under the pause, keeps its words under the first one's.
    public static func lines(_ snapshot: MeFirstSnapshot, prefix: String, now: Date) -> [String] {
        let idle = idleMinutes(milliseconds: snapshot.idleMs)
        guard snapshot.paused, let since = snapshot.sinceMs else {
            return [prefix + "Darkbloom and you, me first — open to Darkbloom (none of your requests in the last "
                + (idle == 1 ? "minute" : "\(idle) minutes") + ")"]
        }
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let detail: String
        switch snapshot.localRequestsInFlight {
        case 1:
            detail = "your request is running; back \(minutes(idle)) after it ends"
        case let running where running > 1:
            detail = "\(running) of your requests are running; back \(minutes(idle)) after the last one ends"
        default:
            let last = snapshot.lastUseMs.map { "your last request " + ago(milliseconds: nowMs - $0) }
            let comesBack = snapshot.resumesAtMs.map { back(inMilliseconds: $0 - nowMs) }
            detail = [last, comesBack].compactMap { $0 }.joined(separator: "; ")
        }
        var lines = [prefix + "you first — Darkbloom paused for " + span(milliseconds: nowMs - since)
            + (detail.isEmpty ? "" : " (\(detail))")]
        let under = String(repeating: " ", count: prefix.count)
        switch snapshot.darkbloomRequestsFinishing {
        case 0: break
        case 1: lines.append(under + "1 Darkbloom request is finishing")
        case let finishing: lines.append(under + "\(finishing) Darkbloom requests are finishing")
        }
        return lines
    }

    /// The pair's lines: me first as the part that runs the pair's API reports it, or, with me first off there
    /// (`[local] me_first = false`), that Darkbloom keeps serving.
    public static func pairLines(_ snapshot: MeFirstSnapshot?, now: Date) -> [String] {
        guard let snapshot else {
            return [pairPrefix + "Darkbloom and you, shared — Darkbloom keeps serving while you use the pair (me first is off)"]
        }
        return lines(snapshot, prefix: pairPrefix, now: now)
    }

    /// "1 minute", "2 minutes".
    public static func minutes(_ count: UInt64) -> String { count == 1 ? "1 minute" : "\(count) minutes" }

    /// A running provider's idle time (`MeFirstSnapshot.idleMs`) in whole minutes, at least one.
    public static func idleMinutes(milliseconds: Int64) -> UInt64 { UInt64(max(1, (milliseconds + 59_999) / 60_000)) }

    /// A time that has passed, in whole minutes: "under a minute", "1 minute", "1 hour 5 minutes".
    static func span(milliseconds: Int64) -> String {
        let total = max(0, milliseconds) / 60_000
        return total == 0 ? "under a minute" : span(minutes: total)
    }

    /// "under a minute ago", "1 minute ago", "3 minutes ago".
    static func ago(milliseconds: Int64) -> String { span(milliseconds: milliseconds) + " ago" }

    /// When Darkbloom comes back if the owner stays idle, `left` from now, to the nearest minute: "back any moment now"
    /// once it is due, "back in under a minute if you stay idle", "back in about 2 minutes if you stay idle".
    static func back(inMilliseconds left: Int64) -> String {
        guard left > 0 else { return "back any moment now" }
        guard left >= 60_000 else { return "back in under a minute if you stay idle" }
        return "back in about " + span(minutes: (left + 30_000) / 60_000) + " if you stay idle"
    }

    /// "1 minute", "12 minutes", "1 hour", "2 hours 1 minute".
    private static func span(minutes total: Int64) -> String {
        let hours = total / 60, rest = total % 60
        let restWords = rest == 1 ? "1 minute" : "\(rest) minutes"
        guard hours > 0 else { return restWords }
        return (hours == 1 ? "1 hour" : "\(hours) hours") + (rest == 0 ? "" : " " + restWords)
    }
}
