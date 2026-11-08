import Foundation
import ProviderCore

extension DaemonState {
    /// Whether the provider that wrote this state serves only its owner: the coordinator-less server (`--local`,
    /// "Only me") is the only one that writes neither runtime capabilities nor a coordinator. A network provider
    /// waiting for its schedule's window writes a coordinator alone (`Start.waitOutsideSchedule`).
    var servesOnlyItsOwner: Bool { runtimeCapabilities == nil && coordinatorUrl == nil }
}

extension LocalFirstWords.LocalAPIServer {
    /// Whose API the provider that wrote `state` serves: on a Mac in a two-Mac cluster, the pair's when the cluster's
    /// part wrote it (`ServiceDrain.soloProviderState`), else single-Mac serving's.
    static func of(_ state: DaemonState, paired: Bool,
                   clusterPart: @autoclosure () -> Int32? = ClusterPairSummary.runningPartPID()) -> Self {
        guard paired else { return .singleMac(paired: false) }
        return ServiceDrain.soloProviderState(state, clusterPart: clusterPart()) == nil ? .pair : .singleMac(paired: true)
    }
}

extension Status {
    /// How this Mac serves now, from the running provider: a `Serving:` line (and one more while Darkbloom requests
    /// finish under a pause), then, with a local API, where your requests go. A local API the provider couldn't open
    /// says why, never "network only"; `nextFreePort` gives the port its line suggests, and `server` whose API it is.
    /// `accountKeySaved` is asked only for a local API with a key. No key and no speed.
    static func servingLines(state: DaemonState, liveEndpoint: LocalEndpoint.Info?, route: LocalSettings.Route?,
                             accountKeySaved: () -> Bool,
                             nextFreePort: (UInt16) -> UInt16? = { LocalAPIPort.nextFree(besides: $0) },
                             server: LocalFirstWords.LocalAPIServer = .singleMac(paired: false),
                             now: Date = Date()) -> [String] {
        guard let liveEndpoint, liveEndpoint.pid == state.pid else {
            // Only me's server reports itself from the start of its first load, before its local API listens.
            if state.servesOnlyItsOwner { return [onlyMeStartingLine] }
            guard let failure = state.localAPIFailure else {
                return ["Serving: Darkbloom network only — this Mac has no local API"]
            }
            return ["Serving: Darkbloom and you, \(state.meFirst == nil ? "shared" : "me first") — "
                + "the local API isn't up: "
                + LocalFirstWords.whyNotUp(failure, nextFree: nextFreePort(failure.port), server: server)]
        }
        var lines: [String]
        if state.servesOnlyItsOwner {
            lines = ["Serving: only you, on this Mac — Darkbloom never contacts this Mac"]
        } else if let meFirst = state.meFirst {
            lines = meFirstLines(meFirst, now: now)
        } else {
            lines = ["Serving: Darkbloom and you, shared — Darkbloom keeps serving while you use this Mac (me first is off)"]
        }
        // Without a local key (`--no-auth`) the router passes nothing on (`LocalRouterConfig.localKeyRequired`).
        lines.append(liveEndpoint.apiKey.isEmpty ? noLocalKeyRequestsLine
                     : requestsLine(route: route, accountKeySaved: accountKeySaved()))
        return lines
    }

    static let onlyMeStartingLine = "Serving: only you, on this Mac — starting: its local API opens once its models are loaded"

    static let noLocalKeyRequestsLine = "Your requests: this Mac only · no local key (--no-auth), so nothing is passed on"

    /// Me first, open or paused, from the running provider's snapshot, in words said from now (`MeFirstWords`).
    static func meFirstLines(_ snapshot: MeFirstSnapshot, now: Date = Date()) -> [String] {
        MeFirstWords.lines(snapshot, prefix: "Serving: ", now: now)
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
}
