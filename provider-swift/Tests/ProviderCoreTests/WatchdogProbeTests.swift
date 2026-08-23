import Foundation
import Testing

@testable import ProviderCore

/// dead) provider apart from a *running* one.
@Suite("Watchdog launchctl parse")
struct WatchdogProbeParseTests {
    @Test("a running job (state + pid) parses as running")
    func runningJob() {
        let out = """
        gui/501/io.darkbloom.provider = {
        \tactive count = 1
        \tstate = running
        \tpid = 4242
        }
        """
        #expect(WatchdogProbe.parseRunning(out))
    }

    @Test("a crashed job (state = not running) parses as not running")
    func crashedJob() {
        let out = """
        gui/501/io.darkbloom.provider = {
        \tactive count = 0
        \tstate = not running
        \tlast exit code = 1
        }
        """
        #expect(!WatchdogProbe.parseRunning(out))
    }

    @Test("a bare non-zero pid line counts as running")
    func barePid() {
        #expect(WatchdogProbe.parseRunning("\tpid = 1"))
    }

    @Test("pid = 0 and empty output are not running")
    func notRunningEdges() {
        #expect(!WatchdogProbe.parseRunning("\tpid = 0"))
        #expect(!WatchdogProbe.parseRunning(""))
    }

    @Test("stale heartbeat from the live daemon marks it inactive")
    func staleLiveDaemonIsInactive() {
        let state = DaemonState(
            pid: 42,
            version: "1.0.0",
            writtenAt: 100,
            startedAt: 10
        )
        #expect(!WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            processAlive: { $0 == 42 }
        ))
    }

    @Test("fresh heartbeat or unrelated old state preserves activity")
    func freshOrUnrelatedState() {
        let state = DaemonState(
            pid: 42,
            version: "1.0.0",
            writtenAt: 480,
            startedAt: 10
        )
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            processAlive: { $0 == 42 }
        ))
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 1_000,
            processAlive: { _ in false }
        ))
    }

    @Test("stale record whose PID the kernel reused cannot demote launchd liveness")
    func pidReuseCannotDemoteLiveness() {
        let recorded = ProcessIdentity(pid: 42, startTimeMicros: 7)
        let state = DaemonState(
            pid: 42,
            processIdentity: recorded,
            version: "1.0.0",
            writtenAt: 100,
            startedAt: 10
        )
        // PID 42 is alive but belongs to a DIFFERENT process (start time
        // differs): the record came from a dead provider, so the stale
        // heartbeat must not override launchd's "running" — pre-fix this
        // returned false and the watchdog could restart or charge a candidate
        // failure against a healthy provider.
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            processAlive: { $0 == 42 },
            readIdentity: { _ in ProcessIdentity(pid: 42, startTimeMicros: 99) }
        ))
        // Same kernel identity → the stale record demotes, as before.
        #expect(!WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            processAlive: { $0 == 42 },
            readIdentity: { _ in recorded }
        ))
        // Fresh record from the matching identity stays active.
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 150,
            processAlive: { $0 == 42 },
            readIdentity: { _ in recorded }
        ))
    }
}
@Suite("Provider launch receipt")
struct ProviderLaunchSnapshotTests {
    @Test("launchctl runs and PID produce crash-safe launch proof")
    func parsesAndCompares() {
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 7)
        let baseline = LaunchAgent.parseLaunchSnapshot(
            label: LaunchAgent.label,
            output: "runs = 10\npid = 42",
            identityReader: { _ in identity }
        )
        let advanced = LaunchAgent.parseLaunchSnapshot(
            label: LaunchAgent.label,
            output: "runs = 11\npid = 42",
            identityReader: { _ in identity }
        )
        #expect(baseline.runs == 10)
        #expect(baseline.process == identity)
        #expect(advanced.provesLaunch(after: baseline))
        #expect(!baseline.provesLaunch(after: baseline))
    }
}

@Suite("Watchdog provider identity (PID reuse)")
struct WatchdogProviderIdentityTests {
    private func stateWithIdentity(_ identity: ProcessIdentity?) -> DaemonState {
        DaemonState(
            pid: 4242,
            processIdentity: identity,
            version: "2.0.0",
            writtenAt: 100,
            startedAt: 50
        )
    }

    @Test("a reused daemon-state PID whose start time differs is NOT the provider identity")
    func reusedPidIsNotProviderIdentity() {
        let recorded = ProcessIdentity(pid: 4242, startTimeMicros: 111)
        let state = stateWithIdentity(recorded)
        // The PID is live again but with a DIFFERENT start time — the kernel
        // reused it (e.g. for a manual `darkbloom update` holding the lock). It
        // must NOT be treated as the provider (which would force-kill it); we
        // fall back to the launchd snapshot (nil here).
        let reused = ProcessIdentity(pid: 4242, startTimeMicros: 999)
        #expect(
            WatchdogProbe.providerIdentity(
                daemonState: state,
                launchSnapshotProcess: nil,
                readIdentity: { _ in reused }
            ) == nil
        )
        // A MATCHING live start time IS trusted.
        #expect(
            WatchdogProbe.providerIdentity(
                daemonState: state,
                launchSnapshotProcess: nil,
                readIdentity: { _ in recorded }
            ) == recorded
        )
    }

    @Test("a dead daemon-state PID falls back to the launchd snapshot")
    func deadPidFallsBackToSnapshot() {
        let state = stateWithIdentity(ProcessIdentity(pid: 4242, startTimeMicros: 111))
        let fallback = ProcessIdentity(pid: 77, startTimeMicros: 3)
        #expect(
            WatchdogProbe.providerIdentity(
                daemonState: state,
                launchSnapshotProcess: fallback,
                readIdentity: { _ in nil }
            ) == fallback
        )
    }

    @Test("a daemon-state without a recorded identity uses the launchd snapshot")
    func missingRecordedIdentityUsesSnapshot() {
        let state = stateWithIdentity(nil)
        let fallback = ProcessIdentity(pid: 77, startTimeMicros: 3)
        #expect(
            WatchdogProbe.providerIdentity(
                daemonState: state,
                launchSnapshotProcess: fallback,
                readIdentity: { _ in ProcessIdentity(pid: 4242, startTimeMicros: 5) }
            ) == fallback
        )
    }

    @Test("ProcessIdentity.read returns nil for a nonexistent pid")
    func readReturnsNilForDeadPid() throws {
        // Deterministic: PIDs never reach Int32.max on macOS; proc_pidinfo
        // returns a zero-length read, which the size guard rejects.
        #expect(ProcessIdentity.read(pid: Int32.max) == nil)
        #expect(ProcessIdentity.read(pid: 0) == nil)
        #expect(ProcessIdentity.read(pid: -1) == nil)

        // A real, reaped process is the realistic "nonexistent pid" case.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(ProcessIdentity.read(pid: process.processIdentifier) == nil)
    }
}

