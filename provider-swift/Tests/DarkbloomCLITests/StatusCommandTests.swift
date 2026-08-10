import ArgumentParser
import ProviderCore
import Testing
@testable import darkbloom

@Test("status compresses local posture and avoids a Secure Boot verdict")
func bootSecurityStatusLine() throws {
    let status = try Status.parse([])
    let warning = status.bootSecurityStatusLine(
        .init(macOSMajorVersion: 25, sip: .unavailable(reason: "csrutil missing"))
    )
    #expect(warning.contains("[WARN]"))
    #expect(warning.contains("csrutil missing"))
    #expect(warning.contains("Secure Boot has no local public check"))

    let passing = status.bootSecurityStatusLine(.init(macOSMajorVersion: 26, sip: .enabled))
    #expect(passing.contains("[PASS]"))
}

/// The daemon line has been wrong in both directions: once calling a
/// 30-second-old snapshot healthy while the slot-posture block fourteen
/// lines below called the same file STALE, and once calling an 11-second
/// delay a wedge. Both bars are pinned here, from both sides.
@Suite("status daemon health line")
struct StatusDaemonHealthLineTests {
    private let now: Double = 10_000

    /// Uptime is a flat 10m wherever the age allows it, so the pinned lines
    /// carry one moving part; a snapshot cannot predate the process that
    /// wrote it, so a longer age drags `startedAt` back with it.
    private func state(age: Double, slots: [DaemonState.SlotPosture]? = nil) -> DaemonState {
        DaemonState(
            pid: 4711, version: "0.8.0", writtenAt: now - age,
            startedAt: now - max(600, age + 1), slots: slots)
    }

    private func line(age: Double, heartbeatIntervalSecs: UInt64 = 5) throws -> String {
        try Status.parse([]).daemonHealthLine(
            state: state(age: age), now: now,
            heartbeatIntervalSecs: heartbeatIntervalSecs)
    }

    @Test("a fresh snapshot reports uptime and nothing else")
    func freshSnapshot() throws {
        #expect(try line(age: 3) == "Daemon: running (pid 4711, up 10m)")
        // 10 s is the bar itself, and `statusLines` is fresh at exactly the
        // bar; crossing here and not there is the contradiction, inverted.
        #expect(try line(age: 10) == "Daemon: running (pid 4711, up 10m)")
    }

    @Test("a stale snapshot discounts the fields below without accusing the daemon")
    func staleButNotWedged() throws {
        #expect(
            try line(age: 30) == "Daemon: running (pid 4711, up 10m) but last update 30s ago "
                + "(expected every ~2s) — snapshot stale, the fields below may be out of date")
        // The finding: a healthy daemon delayed 11–89 s is not a wedge, and
        // neither is one sitting exactly on the 90 s bar.
        for age: Double in [11, 89, 90] {
            let delayed = try line(age: age)
            #expect(!delayed.contains("wedged"), "\(Int(age))s: \(delayed)")
            #expect(delayed.contains("snapshot stale"), "\(Int(age))s: \(delayed)")
        }
    }

    @Test("only eight missed writes, floored at 90 s, accuse the daemon")
    func wedged() throws {
        #expect(
            try line(age: 91) == "Daemon: running (pid 4711) but last update 91s ago "
                + "(expected within 90s) — possibly wedged")
        #expect(try line(age: 400).contains("possibly wedged"))
    }

    @Test("both bars follow the configured cadence, not a fixed 10 s and 90 s")
    func barsFollowConfiguredHeartbeat() throws {
        // heartbeat 200 s ⇒ the daemon legitimately rewrites every 100 s, so
        // 150 s is not even one missed write.
        #expect(try line(age: 150, heartbeatIntervalSecs: 200)
            == "Daemon: running (pid 4711, up 10m)")
        let stale = try line(age: 500, heartbeatIntervalSecs: 200)
        #expect(stale.contains("expected every ~100s"))
        #expect(!stale.contains("wedged"))
        #expect(try line(age: 801, heartbeatIntervalSecs: 200)
            .contains("(expected within 800s) — possibly wedged"))
    }

    @Test("the daemon line and the slot-posture block never disagree about staleness")
    func agreesWithSlotPosture() throws {
        let slots: [DaemonState.SlotPosture] = [
            .init(model: "m", kvBackend: "paged", kvBackendRequested: "paged")
        ]
        let status = try Status.parse([])
        for age: Double in [3, 10, 11, 30, 90, 91, 400] {
            let snapshot = state(age: age, slots: slots)
            let daemon = status.daemonHealthLine(
                state: snapshot, now: now, heartbeatIntervalSecs: 5)
            let posture = KVBackendPosture.statusLines(
                state: snapshot, now: now, heartbeatIntervalSecs: 5)[0]
            let doubted = daemon.contains("snapshot stale") || daemon.contains("wedged")
            #expect(
                doubted == posture.contains("STALE"),
                "age \(Int(age))s: \"\(daemon)\" vs \"\(posture)\"")
        }
    }
}
