import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Fixtures for `status` and `local`: the running provider's state, as each serving mode writes it.
enum LocalFirstStatusFixtures {
    /// 2026-11-06 14:12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_974_320)
    static func ms(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Int64 {
        Int64(1_793_923_200 + hour * 3_600 + minute * 60 + second) * 1_000
    }

    /// A coordinator-connected provider writes its capabilities; the coordinator-less server (`--local`) writes none.
    static func state(pid: Int32 = 4_242, connected: Bool = true, meFirst: MeFirstSnapshot? = nil,
                      localAPIFailure: DaemonState.LocalAPIFailure? = nil) -> DaemonState {
        DaemonState(pid: pid, version: "test", writtenAt: 0, startedAt: 0,
                    runtimeCapabilities: connected ? [] : nil, meFirst: meFirst, localAPIFailure: localAPIFailure)
    }

    /// A Both provider's local API that couldn't listen: another program holds its port, or the address isn't there.
    static let portInUse = DaemonState.LocalAPIFailure(host: "127.0.0.1", port: 8001, portInUse: true)
    static let addressGone = DaemonState.LocalAPIFailure(host: "100.64.0.9", port: 8001, portInUse: false,
                                                         reason: "Can't assign requested address")
    /// Whose API couldn't listen: single-Mac serving on a Mac alone or in a two-Mac cluster (`--solo`), or the pair's.
    static let servers: [LocalFirstWords.LocalAPIServer] = [.singleMac(paired: false), .singleMac(paired: true), .pair]

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
        var lines = snapshots.flatMap { Status.meFirstLines($0, now: now) }
        for state in [state(connected: false), state(meFirst: paused), state()] {
            for key in [true, false] {
                lines += Status.servingLines(state: state, liveEndpoint: endpoint(), route: .myMacsFirst,
                                             accountKeySaved: { key }, now: now)
                lines += Local.servingLines(info: endpoint(), state: state, route: nil, accountKeySaved: { key })
            }
            lines += Status.servingLines(state: state, liveEndpoint: endpoint(apiKey: ""), route: .myMacsFirst,
                                         accountKeySaved: { true }, now: now)
            lines += Local.servingLines(info: endpoint(apiKey: ""), state: state, route: .myMacsFirst,
                                        accountKeySaved: { true })
        }
        lines += Status.servingLines(state: state(), liveEndpoint: nil, route: nil, accountKeySaved: { false })
        lines += Status.servingLines(state: state(connected: false), liveEndpoint: nil, route: nil,
                                     accountKeySaved: { false })
        for failure in [portInUse, addressGone] {
            for meFirst in [open, nil] {
                for free in [UInt16(8002), nil] {
                    for server in servers {
                        lines += Status.servingLines(state: state(meFirst: meFirst, localAPIFailure: failure),
                                                     liveEndpoint: nil, route: nil, accountKeySaved: { false },
                                                     nextFreePort: { _ in free }, server: server)
                        lines.append(Local.notUpLine(failure, nextFree: free, server: server))
                    }
                }
            }
        }
        return lines + Local.notRunningHint
    }
}

@Suite("Status and local: how this Mac serves, in plain words")
struct LocalFirstStatusTests {
    typealias F = LocalFirstStatusFixtures

    @Test("me first, open to Darkbloom")
    func open() {
        #expect(Status.meFirstLines(F.open, now: F.now) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
        ])
        #expect(Status.meFirstLines(MeFirstSnapshot(idleMs: 60_000, paused: false), now: F.now) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last minute)",
        ])
    }

    /// Journey 2a (J2-i): the pause said "since 21:41" in the Mac's own time, without a zone, read over SSH at 05:41 UTC.
    /// How long it has lasted and when it ends are said from now, which reads the same in any zone and on another Mac.
    @Test("you first: how long Darkbloom has been paused, your last request, and when it comes back, all from now")
    func paused() {
        #expect(Status.meFirstLines(F.paused, now: F.now) == [
            "Serving: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute "
                + "if you stay idle)",
        ])
        let late = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11, 50),
                                   resumesAtMs: F.ms(14, 10))
        #expect(Status.meFirstLines(late, now: F.now) == [
            "Serving: you first — Darkbloom paused for 10 minutes (your last request under a minute ago; back any moment now)",
        ])
        // The journey's own: a request ended 5 s ago, after a pause of 23 s.
        let justEnded = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(14, 11, 37), lastUseMs: F.ms(14, 11, 55),
                                        resumesAtMs: F.ms(14, 13, 55))
        #expect(Status.meFirstLines(justEnded, now: F.now) == [
            "Serving: you first — Darkbloom paused for under a minute (your last request under a minute ago; back in about "
                + "2 minutes if you stay idle)",
        ])
        let almost = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(13, 7), lastUseMs: F.ms(14, 10, 30),
                                     resumesAtMs: F.ms(14, 12, 30))
        #expect(Status.meFirstLines(almost, now: F.now) == [
            "Serving: you first — Darkbloom paused for 1 hour 5 minutes (your last request 1 minute ago; back in under a "
                + "minute if you stay idle)",
        ])
        // No clock time in any line: nothing to read in a zone.
        let text = F.everyLine().joined(separator: "\n")
        #expect(text.range(of: #"\b[0-9]{1,2}:[0-9]{2}\b"#, options: .regularExpression) == nil, "\(text)")
    }

    @Test("you first while your requests run, and the Darkbloom requests still finishing")
    func pausedWithRequestsRunning() {
        let one = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11),
                                  localRequestsInFlight: 1, darkbloomRequestsFinishing: 2)
        #expect(Status.meFirstLines(one, now: F.now) == [
            "Serving: you first — Darkbloom paused for 10 minutes (your request is running; back 2 minutes after it ends)",
            "         2 Darkbloom requests are finishing",
        ])
        let three = MeFirstSnapshot(idleMs: 60_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11),
                                    localRequestsInFlight: 3, darkbloomRequestsFinishing: 1)
        #expect(Status.meFirstLines(three, now: F.now) == [
            "Serving: you first — Darkbloom paused for 10 minutes (3 of your requests are running; back 1 minute after "
                + "the last one ends)",
            "         1 Darkbloom request is finishing",
        ])
    }

    @Test("status names each way of serving, then where your requests go, from the running provider")
    func servingLinesForEachState() {
        var keyLookups = 0
        let keySaved: () -> Bool = { keyLookups += 1; return true }
        #expect(Status.servingLines(state: F.state(connected: false), liveEndpoint: F.endpoint(), route: nil,
                                    accountKeySaved: keySaved, now: F.now) == [
            "Serving: only you, on this Mac — Darkbloom never contacts this Mac",
            "Your requests: this Mac first, then your other Macs (free) · account key saved",
        ])
        #expect(Status.servingLines(state: F.state(meFirst: F.open), liveEndpoint: F.endpoint(), route: .myMacsFirst,
                                    accountKeySaved: keySaved, now: F.now) == [
            "Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
            "Your requests: this Mac first, then your other Macs (free), then the Darkbloom network (billed) · account key saved",
        ])
        #expect(Status.servingLines(state: F.state(), liveEndpoint: F.endpoint(), route: nil,
                                    accountKeySaved: { false }, now: F.now) == [
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

    /// Only me's background service reports itself from the start of its first load (`Start.startOnlyMeServer`), which
    /// waits for every model it serves, before its local API listens: that is never "network only".
    @Test("Only me loading its models, before its local API listens, is never \"network only\"")
    func onlyMeWhileItLoads() {
        for endpoint in [nil, F.endpoint(pid: 9_999)] {
            #expect(Status.servingLines(state: F.state(connected: false), liveEndpoint: endpoint, route: nil,
                                        accountKeySaved: { Issue.record("Keychain read"); return false }) == [
                "Serving: only you, on this Mac — starting: its local API opens once its models are loaded",
            ])
        }
        // A network provider waiting for its schedule's window writes a coordinator and no capabilities: not Only me.
        let waiting = DaemonState(pid: 4_242, version: "test", writtenAt: 0, startedAt: 0,
                                  coordinatorURL: "wss://coordinator.invalid/ws/provider")
        #expect(!waiting.servesOnlyItsOwner)
        #expect(Status.servingLines(state: waiting, liveEndpoint: nil, route: nil, accountKeySaved: { false })
            == ["Serving: Darkbloom network only — this Mac has no local API"])
    }

    @Test("a local API that couldn't listen is never \"network only\": status and local say why, and the next step")
    func localAPINotUp() {
        let noKeychain: () -> Bool = { Issue.record("Keychain read"); return false }
        #expect(Status.servingLines(state: F.state(meFirst: F.open, localAPIFailure: F.portInUse), liveEndpoint: nil,
                                    route: .myMacs, accountKeySaved: noKeychain, nextFreePort: { _ in 8002 }) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (`darkbloom start "
                + "--port 8002`)",
        ])
        #expect(Status.servingLines(state: F.state(localAPIFailure: F.portInUse), liveEndpoint: nil, route: nil,
                                    accountKeySaved: noKeychain, nextFreePort: { _ in nil }) == [
            "Serving: Darkbloom and you, shared — the local API isn't up: port 8001 is in use (free it, or name another "
                + "with `darkbloom start --port <n>`)",
        ])
        #expect(Status.servingLines(state: F.state(meFirst: F.open, localAPIFailure: F.addressGone), liveEndpoint: nil,
                                    route: nil, accountKeySaved: noKeychain, nextFreePort: { _ in 8002 }) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: it couldn't listen on 100.64.0.9:8001 (Can't "
                + "assign requested address); `darkbloom restart` tries again",
        ])
        // Another process's API, or none asked for: as before.
        #expect(Status.servingLines(state: F.state(meFirst: F.open), liveEndpoint: nil, route: nil,
                                    accountKeySaved: noKeychain) == ["Serving: Darkbloom network only — this Mac has no local API"])
        #expect(Local.notUpLine(F.portInUse, nextFree: 8002)
            == "The local API isn't up: port 8001 is in use (`darkbloom start --port 8002`).")
        #expect(Local.notUpLine(F.addressGone, nextFree: nil) == "The local API isn't up: it couldn't listen on "
            + "100.64.0.9:8001 (Can't assign requested address); `darkbloom restart` tries again.")
    }

    /// A Mac in a two-Mac cluster refuses `start --port` without `--solo`, and the pair's API doesn't take
    /// `[local] port`: the line names a command that works there.
    @Test("on a Mac in a two-Mac cluster, the line names a command that Mac takes")
    func localAPINotUpOnAPairedMac() {
        let state = F.state(meFirst: F.open, localAPIFailure: F.portInUse)
        func line(_ server: LocalFirstWords.LocalAPIServer, free: UInt16?,
                  failure: DaemonState.LocalAPIFailure = F.portInUse) -> [String] {
            Status.servingLines(state: F.state(meFirst: F.open, localAPIFailure: failure), liveEndpoint: nil, route: nil,
                                accountKeySaved: { false }, nextFreePort: { _ in free }, server: server)
        }
        // Single-Mac serving there (`start --solo`): the same commands, with --solo.
        #expect(line(.singleMac(paired: true), free: 8002) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (`darkbloom start --solo "
                + "--port 8002`)",
        ])
        #expect(line(.singleMac(paired: true), free: nil) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (free it, or name another "
                + "with `darkbloom start --solo --port <n>`)",
        ])
        #expect(line(.singleMac(paired: true), free: 8002, failure: F.addressGone) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: it couldn't listen on 100.64.0.9:8001 (Can't "
                + "assign requested address); `darkbloom restart --solo` tries again",
        ])
        // The pair's API takes this Mac's saved port as it is, as every local API here does: free it, or save another.
        #expect(line(.pair, free: 8002) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (free it, or set "
                + "`[local] port = 8002` in provider.toml, then `darkbloom restart`)",
        ])
        #expect(line(.pair, free: nil) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (free it, or set another "
                + "`[local] port` in provider.toml, then `darkbloom restart`)",
        ])
        #expect(line(.pair, free: 8002, failure: F.addressGone) == [
            "Serving: Darkbloom and you, me first — the local API isn't up: it couldn't listen on 100.64.0.9:8001 (Can't "
                + "assign requested address); `darkbloom restart` tries again",
        ])
        #expect(Local.notUpLine(F.portInUse, nextFree: 8002, server: .pair)
            == "The local API isn't up: port 8001 is in use (free it, or set `[local] port = 8002` in provider.toml, then "
                + "`darkbloom restart`).")
        #expect(Local.notUpLine(F.portInUse, nextFree: 8002, server: .singleMac(paired: true))
            == "The local API isn't up: port 8001 is in use (`darkbloom start --solo --port 8002`).")

        // Whose API: the cluster's part wrote the state, or single-Mac serving did.
        #expect(LocalFirstWords.LocalAPIServer.of(state, paired: true, clusterPart: state.pid) == .pair)
        #expect(LocalFirstWords.LocalAPIServer.of(state, paired: true, clusterPart: 7) == .singleMac(paired: true))
        #expect(LocalFirstWords.LocalAPIServer.of(state, paired: true, clusterPart: nil) == .singleMac(paired: true))
        #expect(LocalFirstWords.LocalAPIServer.of(state, paired: false, clusterPart: state.pid) == .singleMac(paired: false))
    }

    @Test("the requests line says whether a key is saved, never the key")
    func requestsLine() {
        #expect(Status.requestsLine(route: .thisMac, accountKeySaved: true)
            == "Your requests: this Mac only ([local] route = \"this-mac\") · account key saved")
        #expect(Status.requestsLine(route: .myMacs, accountKeySaved: false)
            == "Your requests: this Mac only · no account key (`darkbloom route key` saves one)")
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
            "Start one with:  darkbloom local                                (only you, on this Mac)",
            "             or: darkbloom start --local-endpoint --no-me-first  (Darkbloom and you)",
        ])
    }

    @Test("no line of status or local carries a key")
    func noKeyInAnyLine() {
        let text = F.everyLine().joined(separator: "\n")
        #expect(!text.contains("dk-local-fixture-secret"))
        #expect(!text.contains("dk-"))
    }
}
