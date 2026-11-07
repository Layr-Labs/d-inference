import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Fixtures for `status` and `local`: the running provider's state, as each serving mode writes it.
enum LocalFirstStatusFixtures {
    static let utc = TimeZone(identifier: "UTC")!

    /// 2026-11-06 14:12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_974_320)
    static func ms(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Int64 {
        Int64(1_793_923_200 + hour * 3_600 + minute * 60 + second) * 1_000
    }

    /// A coordinator-connected provider writes its capabilities; the coordinator-less server (`--local`) writes none.
    static func state(pid: Int32 = 4_242, connected: Bool = true, meFirst: MeFirstSnapshot? = nil) -> DaemonState {
        DaemonState(pid: pid, version: "test", writtenAt: 0, startedAt: 0,
                    runtimeCapabilities: connected ? [] : nil, meFirst: meFirst)
    }

    /// The running local API; `apiKey: ""` is one started with `--no-auth`.
    static func endpoint(pid: Int32 = 4_242, apiKey: String = "dk-local-fixture-secret") -> LocalEndpoint.Info {
        LocalEndpoint.Info(host: "127.0.0.1", port: 8001, apiKey: apiKey, version: "test", pid: pid,
                           updatedAt: "2026-11-06T14:00:00Z")
    }

    static let open = MeFirstSnapshot(idleMs: 120_000, paused: false, lastUseMs: ms(13, 50))
    static let paused = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: ms(14, 2), lastUseMs: ms(14, 11),
                                        resumesAtMs: ms(14, 13))

    /// Every line `status` and `local` can say about how this Mac serves.
    static func everyLine() -> [String] {
        var snapshots = [open, paused, MeFirstSnapshot(idleMs: 60_000, paused: false)]
        for running in [1, 3] {
            snapshots.append(MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: ms(14, 2), lastUseMs: ms(14, 11),
                                             localRequestsInFlight: running, darkbloomRequestsFinishing: running))
        }
        snapshots.append(MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: ms(14, 2), lastUseMs: ms(14, 11, 50),
                                         resumesAtMs: ms(14, 10)))
        var lines = snapshots.flatMap { Status.meFirstLines($0, now: now, timeZone: utc) }
        for state in [state(connected: false), state(meFirst: paused), state()] {
            for key in [true, false] {
                lines += Status.servingLines(state: state, liveEndpoint: endpoint(), route: .myMacsFirst,
                                             accountKeySaved: { key }, now: now, timeZone: utc)
                lines += Local.servingLines(info: endpoint(), state: state, route: nil, accountKeySaved: { key })
            }
            lines += Status.servingLines(state: state, liveEndpoint: endpoint(apiKey: ""), route: .myMacsFirst,
                                         accountKeySaved: { true }, now: now, timeZone: utc)
            lines += Local.servingLines(info: endpoint(apiKey: ""), state: state, route: .myMacsFirst,
                                        accountKeySaved: { true })
        }
        lines += Status.servingLines(state: state(), liveEndpoint: nil, route: nil, accountKeySaved: { false })
        return lines + Local.notRunningHint
    }
}

@Suite("Status and local: how this Mac serves, in plain words")
struct LocalFirstStatusTests {
    typealias F = LocalFirstStatusFixtures

    @Test("me first, open to Darkbloom")
    func open() {
        #expect(Status.meFirstLines(F.open, now: F.now, timeZone: F.utc) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
        ])
        #expect(Status.meFirstLines(MeFirstSnapshot(idleMs: 60_000, paused: false), now: F.now, timeZone: F.utc) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last minute)",
        ])
    }

    @Test("you first: paused since, your last request, and when Darkbloom comes back")
    func paused() {
        #expect(Status.meFirstLines(F.paused, now: F.now, timeZone: F.utc) == [
            "Serving: you first — Darkbloom paused since 14:02 (your last request 1 minute ago; back at about 14:13 "
                + "if you stay idle)",
        ])
        let late = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11, 50),
                                   resumesAtMs: F.ms(14, 10))
        #expect(Status.meFirstLines(late, now: F.now, timeZone: F.utc) == [
            "Serving: you first — Darkbloom paused since 14:02 (your last request under a minute ago; back any moment now)",
        ])
    }

    @Test("you first while your requests run, and the Darkbloom requests still finishing")
    func pausedWithRequestsRunning() {
        let one = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11),
                                  localRequestsInFlight: 1, darkbloomRequestsFinishing: 2)
        #expect(Status.meFirstLines(one, now: F.now, timeZone: F.utc) == [
            "Serving: you first — Darkbloom paused since 14:02 (your request is running; back 2 minutes after it ends)",
            "         2 Darkbloom requests are finishing",
        ])
        let three = MeFirstSnapshot(idleMs: 60_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11),
                                    localRequestsInFlight: 3, darkbloomRequestsFinishing: 1)
        #expect(Status.meFirstLines(three, now: F.now, timeZone: F.utc) == [
            "Serving: you first — Darkbloom paused since 14:02 (3 of your requests are running; back 1 minute after "
                + "the last one ends)",
            "         1 Darkbloom request is finishing",
        ])
    }

    @Test("status names each way of serving, then where your requests go, from the running provider")
    func servingLinesForEachState() {
        var keyLookups = 0
        let keySaved: () -> Bool = { keyLookups += 1; return true }
        #expect(Status.servingLines(state: F.state(connected: false), liveEndpoint: F.endpoint(), route: nil,
                                    accountKeySaved: keySaved, now: F.now, timeZone: F.utc) == [
            "Serving: only you, on this Mac — Darkbloom never contacts this Mac",
            "Your requests: this Mac first, then your other Macs (free) · account key saved",
        ])
        #expect(Status.servingLines(state: F.state(meFirst: F.open), liveEndpoint: F.endpoint(), route: .myMacsFirst,
                                    accountKeySaved: keySaved, now: F.now, timeZone: F.utc) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
            "Your requests: this Mac first, then your other Macs (free), then the Darkbloom network (billed) · account key saved",
        ])
        #expect(Status.servingLines(state: F.state(), liveEndpoint: F.endpoint(), route: nil,
                                    accountKeySaved: { false }, now: F.now, timeZone: F.utc) == [
            "Serving: Darkbloom and you, shared — Darkbloom keeps serving while you use this Mac (me first is off)",
            "Your requests: this Mac only · no account key (`darkbloom route key` saves one)",
        ])
        #expect(keyLookups == 2)
        // The Darkbloom network only, or another program's endpoint: no route line, and the Keychain isn't asked.
        for endpoint in [nil, F.endpoint(pid: 9_999)] {
            #expect(Status.servingLines(state: F.state(meFirst: F.open), liveEndpoint: endpoint, route: nil,
                                        accountKeySaved: { Issue.record("Keychain read"); return false }) == [
                "Serving: Darkbloom network only — this Mac has no local API",
            ])
        }
    }

    @Test("the requests line says whether a key is saved, never the key")
    func requestsLine() {
        #expect(Status.requestsLine(route: .thisMac, accountKeySaved: true)
            == "Your requests: this Mac only ([local] route = \"this-mac\") · account key saved")
        #expect(Status.requestsLine(route: .myMacs, accountKeySaved: false)
            == "Your requests: this Mac only · no account key (`darkbloom route key` saves one)")
        #expect(Status.ago(milliseconds: 59_999) == "under a minute ago")
        #expect(Status.ago(milliseconds: 60_000) == "1 minute ago")
        #expect(Status.ago(milliseconds: 600_000) == "10 minutes ago")
    }

    @Test("local adds how its server serves and where your requests go, and names --me-first beside --local")
    func localCommandLines() {
        #expect(Local.servingLines(info: F.endpoint(), state: F.state(meFirst: F.paused), route: nil,
                                   accountKeySaved: { true }) == [
            "  serving:  Both, me first — Darkbloom pauses while you use this Mac, back after 2 idle minutes",
            "  requests: this Mac first, then your other Macs (free)",
        ])
        #expect(Local.servingLines(info: F.endpoint(), state: F.state(), route: .myMacs, accountKeySaved: { false }) == [
            "  serving:  Both — Darkbloom keeps serving while you use this Mac (me first is off)",
            "  requests: this Mac only (`darkbloom route key` adds your other Macs)",
        ])
        #expect(Local.servingLines(info: F.endpoint(), state: F.state(connected: false), route: .thisMac,
                                   accountKeySaved: { true }) == [
            "  serving:  Only me, on this Mac — Darkbloom never contacts this Mac",
            "  requests: this Mac only",
        ])
        #expect(Local.servingLines(info: F.endpoint(pid: 1), state: F.state(), route: nil,
                                   accountKeySaved: { Issue.record("Keychain read"); return true }).isEmpty)
        #expect(Local.servingLines(info: F.endpoint(), state: nil, route: nil, accountKeySaved: { true }).isEmpty)
        #expect(Local.notRunningHint == [
            "Start one with:  darkbloom start --me-first   (Darkbloom and you, you first)",
            "             or: darkbloom start --local      (only you, on this Mac)",
        ])
    }

    @Test("no line of status or local carries a key")
    func noKeyInAnyLine() {
        let text = F.everyLine().joined(separator: "\n")
        #expect(!text.contains("dk-local-fixture-secret"))
        #expect(!text.contains("dk-"))
    }
}
