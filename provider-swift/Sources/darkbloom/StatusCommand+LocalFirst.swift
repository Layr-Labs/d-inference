import Foundation
import ProviderCore

extension DaemonState {
    /// Whether the provider that wrote this state serves only its owner: the coordinator-less server (`--local`,
    /// "Only me") is the only one that writes no runtime capabilities.
    var servesOnlyItsOwner: Bool { runtimeCapabilities == nil }
}

extension Status {
    /// How this Mac serves now, from the running provider: a `Serving:` line (and one more while Darkbloom requests
    /// finish under a pause), then, with a local API, where your requests go. `accountKeySaved` is asked only for a
    /// local API with a key. No key and no speed.
    static func servingLines(state: DaemonState, liveEndpoint: LocalEndpoint.Info?, route: LocalSettings.Route?,
                             accountKeySaved: () -> Bool,
                             nextFreePort: (UInt16) -> UInt16? = { LocalAPIPort.nextFree(besides: $0) },
                             now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        guard let liveEndpoint, liveEndpoint.pid == state.pid else {
            return ["Serving: Darkbloom network only — this Mac has no local API"]
        }
        var lines: [String]
        if state.servesOnlyItsOwner {
            lines = ["Serving: only you, on this Mac — Darkbloom never contacts this Mac"]
        } else if let meFirst = state.meFirst {
            lines = meFirstLines(meFirst, now: now, timeZone: timeZone)
        } else {
            lines = ["Serving: Darkbloom and you, shared — Darkbloom keeps serving while you use this Mac (me first is off)"]
        }
        // Without a local key (`--no-auth`) the router passes nothing on (`LocalRouterConfig.localKeyRequired`).
        lines.append(liveEndpoint.apiKey.isEmpty ? noLocalKeyRequestsLine
                     : requestsLine(route: route, accountKeySaved: accountKeySaved()))
        return lines
    }

    static let noLocalKeyRequestsLine = "Your requests: this Mac only · no local key (--no-auth), so nothing is passed on"

    /// Me first, open or paused, from the running provider's snapshot.
    static func meFirstLines(_ snapshot: MeFirstSnapshot, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        let idle = LocalFirstWords.idleMinutes(milliseconds: snapshot.idleMs)
        guard snapshot.paused, let since = snapshot.sinceMs else {
            return ["Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last "
                + (idle == 1 ? "minute" : "\(idle) minutes") + ")"]
        }
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let detail: String
        switch snapshot.localRequestsInFlight {
        case 1:
            detail = "your request is running; back \(LocalFirstWords.minutes(idle)) after it ends"
        case let running where running > 1:
            detail = "\(running) of your requests are running; back \(LocalFirstWords.minutes(idle)) after the last one ends"
        default:
            let last = snapshot.lastUseMs.map { "your last request \(ago(milliseconds: nowMs - $0))" }
            let back = snapshot.resumesAtMs.map {
                $0 <= nowMs ? "back any moment now" : "back at about \(clock($0, timeZone: timeZone)) if you stay idle"
            }
            detail = [last, back].compactMap { $0 }.joined(separator: "; ")
        }
        var lines = ["Serving: you first — Darkbloom paused since \(clock(since, timeZone: timeZone))"
            + (detail.isEmpty ? "" : " (\(detail))")]
        switch snapshot.darkbloomRequestsFinishing {
        case 0: break
        case 1: lines.append("         1 Darkbloom request is finishing")
        case let finishing: lines.append("         \(finishing) Darkbloom requests are finishing")
        }
        return lines
    }

    /// Where your requests go when this Mac can't take them, and whether an account key is saved (never the key).
    static func requestsLine(route: LocalSettings.Route?, accountKeySaved: Bool) -> String {
        let words = LocalFirstWords.requests(route: route, accountKeySaved: accountKeySaved)
        guard accountKeySaved else {
            return "Your requests: \(words) · no account key (`\(BuildEnvironment.current.cliName) route key` saves one)"
        }
        let pinned = route == .thisMac ? " ([local] route = \"this-mac\")" : ""
        return "Your requests: \(words)\(pinned) · account key saved"
    }

    /// "under a minute ago", "1 minute ago", "3 minutes ago".
    static func ago(milliseconds: Int64) -> String {
        let minutes = max(0, milliseconds) / 60_000
        return minutes == 0 ? "under a minute ago" : minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
    }

    /// A Unix-milliseconds time as the hour and minute on this Mac's clock.
    static func clock(_ milliseconds: Int64, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
