import Foundation
import Testing
@testable import ProviderCore

/// The crash-recovery policy: the exact rules that decide whether to relaunch a
/// downed provider. Pure, so every branch is pinned here.
@Suite("Watchdog decision")
struct WatchdogDecisionTests {
    let now: Double = 1_000_000
    let grace: Double = 300

    @Test("config opt-out wins over everything")
    func disabledOptsOut() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: false, providerLoaded: true, providerRunning: false,
            downSince: now - 9_999, now: now, graceSeconds: grace
        )
        #expect(d == .disabled)
    }

    @Test("an unloaded provider (stopped / uninstalled) is never restarted")
    func notManagedWhenUnloaded() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: false, providerRunning: false,
            downSince: now - 9_999, now: now, graceSeconds: grace
        )
        #expect(d == .notManaged)
    }

    @Test("a running provider is healthy")
    func healthyWhenRunning() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: true,
            downSince: now - 100, now: now, graceSeconds: grace
        )
        #expect(d == .healthy)
    }

    @Test("first observation of a down provider arms the grace window")
    func startsGraceOnFirstDown() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: nil, now: now, graceSeconds: grace
        )
        #expect(d == .startGrace)
    }

    @Test("within the grace window the watchdog waits")
    func waitsInsideGrace() {
        let d = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: now - 100, now: now, graceSeconds: grace
        )
        #expect(d == .waiting(remaining: 200))
    }

    @Test("at or past the grace window the watchdog restarts")
    func restartsAtGraceBoundary() {
        let exactly = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: now - 300, now: now, graceSeconds: grace
        )
        #expect(exactly == .restart)

        let past = WatchdogPolicy.decide(
            autoRestartEnabled: true, providerLoaded: true, providerRunning: false,
            downSince: now - 600, now: now, graceSeconds: grace
        )
        #expect(past == .restart)
    }

    @Test("default grace period is five minutes")
    func defaultGraceIsFiveMinutes() {
        #expect(WatchdogPolicy.defaultGraceSeconds == 300)
    }
}

/// The reboot guard: a downSince armed in a previous uptime must not survive to
/// trigger an instant post-reboot restart.
@Suite("Watchdog reboot guard")
struct WatchdogEffectiveDownSinceTests {
    @Test("a downSince from before boot is discarded")
    func staleAcrossBootDropped() {
        #expect(WatchdogPolicy.effectiveDownSince(50, bootTime: 100) == nil)
    }

    @Test("a downSince after boot is kept")
    func freshKept() {
        #expect(WatchdogPolicy.effectiveDownSince(150, bootTime: 100) == 150)
    }

    @Test("unknown boot time passes the value through unchanged")
    func unknownBootPassesThrough() {
        #expect(WatchdogPolicy.effectiveDownSince(150, bootTime: nil) == 150)
        #expect(WatchdogPolicy.effectiveDownSince(nil, bootTime: 100) == nil)
    }
}

/// The pure persistence mapping the watchdog command uses after deciding.
@Suite("Watchdog persistence")
struct WatchdogNextStateTests {
    let now: Double = 1_000_000

    @Test("restart records the attempt and clears the window")
    func restartState() {
        let s = WatchdogPolicy.nextState(for: .restart, current: WatchdogState(downSince: now - 400), now: now)
        #expect(s == WatchdogState(downSince: nil, lastRestartAt: now))
    }

    @Test("startGrace arms downSince, preserving lastRestartAt")
    func startGraceState() {
        let s = WatchdogPolicy.nextState(for: .startGrace, current: WatchdogState(lastRestartAt: 42), now: now)
        #expect(s == WatchdogState(downSince: now, lastRestartAt: 42))
    }

    @Test("waiting writes nothing")
    func waitingState() {
        let s = WatchdogPolicy.nextState(for: .waiting(remaining: 60), current: WatchdogState(downSince: now - 60), now: now)
        #expect(s == nil)
    }

    @Test("healthy clears an armed window but no-ops when already clear")
    func healthyState() {
        let cleared = WatchdogPolicy.nextState(for: .healthy, current: WatchdogState(downSince: now - 10, lastRestartAt: 7), now: now)
        #expect(cleared == WatchdogState(downSince: nil, lastRestartAt: 7))
        #expect(WatchdogPolicy.nextState(for: .healthy, current: WatchdogState(), now: now) == nil)
    }

    @Test("disabled / notManaged clear an armed window, else no-op")
    func disabledNotManagedState() {
        #expect(WatchdogPolicy.nextState(for: .disabled, current: WatchdogState(downSince: 1), now: now) == WatchdogState(downSince: nil))
        #expect(WatchdogPolicy.nextState(for: .notManaged, current: WatchdogState(), now: now) == nil)
    }
}

/// `launchctl print` parsing — the signal that tells a *crashed* (loaded but
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
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 7)
        let state = DaemonState(
            pid: 42,
            processIdentity: identity,
            version: "1.0.0",
            writtenAt: 100,
            startedAt: 10
        )
        #expect(!WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            readIdentity: { _ in identity }
        ))
    }

    @Test("fresh matching heartbeat or identity-less old state preserves launchd activity")
    func freshOrUnrelatedState() {
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 7)
        let state = DaemonState(
            pid: 42,
            processIdentity: identity,
            version: "1.0.0",
            writtenAt: 480,
            startedAt: 10
        )
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            readIdentity: { _ in identity }
        ))
        let legacyState = DaemonState(
            pid: 42,
            version: "1.0.0",
            writtenAt: 100,
            startedAt: 10
        )
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: legacyState,
            now: 1_000
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
            readIdentity: { _ in ProcessIdentity(pid: 42, startTimeMicros: 99) }
        ))
        // Same kernel identity → the stale record demotes, as before.
        #expect(!WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 500,
            readIdentity: { _ in recorded }
        ))
        // Fresh record from the matching identity stays active.
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: 150,
            readIdentity: { _ in recorded }
        ))
    }
}

@Suite("Watchdog re-arm action")
struct WatchdogRearmActionTests {
    @Test("auto_restart=true always arms")
    func armWhenEnabled() {
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: true, isLoaded: false) == .arm)
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: true, isLoaded: true) == .arm)
    }

    @Test("auto_restart=false disarms a loaded watchdog instead of leaving the stale job")
    func disarmWhenOptedOutAndLoaded() {
        // Pre-fix, an opted-out config left a previously armed watchdog
        // running on its OLD plist config, which could keep relaunching the
        // provider after crashes despite the opt-out.
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: false, isLoaded: true) == .disarm)
    }

    @Test("auto_restart=false with nothing loaded does nothing")
    func noopWhenOptedOutAndUnloaded() {
        #expect(WatchdogAgent.rearmAction(autoRestartEnabled: false, isLoaded: false) == nil)
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

/// The watchdog launchd plist shape.
@Suite("Watchdog agent plist")
struct WatchdogAgentPlistTests {
    @Test("plist keeps one persistent watchdog alive and delegates cadence internally")
    func plistShape() {
        let plist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: ["/usr/local/bin/darkbloom", "watchdog"],
            logPath: "/tmp/watchdog.log"
        )
        #expect(plist["Label"] as? String == "io.darkbloom.watchdog")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/darkbloom", "watchdog"])
        #expect(plist["StartInterval"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["StandardOutPath"] as? String == "/tmp/watchdog.log")
        #expect(plist["StandardErrorPath"] as? String == "/tmp/watchdog.log")
    }

    @Test("re-arm preserves the installed plist config when no override is given")
    func rearmPreservesInstalledConfig() {
        let installedArguments = [
            "/opt/darkbloom",
            "watchdog",
            "--config",
            "/tmp/custom-provider.toml",
        ]
        let installed = WatchdogAgent.configPathArgument(in: installedArguments)
        #expect(installed?.path == "/tmp/custom-provider.toml")

        // No explicit --config on `darkbloom restart`: the previously
        // installed custom config MUST survive the plist rewrite.
        let preserved = WatchdogAgent.rearmConfigPath(
            explicit: nil,
            installed: installed
        )
        #expect(preserved?.path == "/tmp/custom-provider.toml")

        // An explicit override wins over the installed value.
        let overridden = WatchdogAgent.rearmConfigPath(
            explicit: "/tmp/other.toml",
            installed: installed
        )
        #expect(overridden?.path == "/tmp/other.toml")

        // Short flag parses too; missing value or absent flag yields nil.
        #expect(
            WatchdogAgent.configPathArgument(
                in: ["/opt/darkbloom", "watchdog", "-c", "/tmp/short.toml"]
            )?.path == "/tmp/short.toml"
        )
        #expect(WatchdogAgent.configPathArgument(
            in: ["/opt/darkbloom", "watchdog", "--config"]
        ) == nil)
        #expect(WatchdogAgent.configPathArgument(
            in: ["/opt/darkbloom", "watchdog"]
        ) == nil)
    }

    @Test("plist propagates custom config and update opt-out environment")
    func configAndEnvironment() {
        let arguments = [
            "/opt/darkbloom",
            "watchdog",
            "--config",
            "/tmp/provider.toml",
        ]
        let plist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: arguments,
            logPath: "/tmp/watchdog.log",
            environment: [
                "DARKBLOOM_NO_UPDATE_CHECK": "1",
                "UNRELATED_SECRET": "no",
            ]
        )
        #expect(plist["ProgramArguments"] as? [String] == arguments)
        let environment = plist["EnvironmentVariables"] as? [String: String]
        #expect(environment == ["DARKBLOOM_NO_UPDATE_CHECK": "1"])
    }

    @Test("the watchdog label is distinct from the provider label")
    func distinctLabel() {
        #expect(WatchdogAgent.label != LaunchAgent.label)
        #expect(LaunchAgent.supportedLabels.contains(LaunchAgent.label))
    }
}

@Suite("Watchdog persistent cadence", .serialized)
struct WatchdogSchedulerTests {
    @Test("real monotonic timer repeats and cancels without spinning")
    func cadenceAndCancellation() async throws {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let task = Task {
            await WatchdogScheduler(interval: .milliseconds(20)).run {
                continuation.yield(ProcessInfo.processInfo.systemUptime)
            }
        }
        var times: [Double] = []
        for await time in stream {
            times.append(time)
            if times.count == 3 { break }
        }
        task.cancel()
        await task.value
        continuation.finish()

        #expect(times.count == 3)
        for pair in zip(times, times.dropFirst()) {
            #expect(pair.1 - pair.0 >= 0.012)
        }
    }
}

/// The cross-tick timer state persistence.
@Suite("Watchdog state")
struct WatchdogStateTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-state-\(UUID().uuidString).json")
    }

    @Test("state round-trips through disk")
    func roundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = WatchdogState(downSince: 123.5, lastRestartAt: 456.75)
        WatchdogStateStore.write(original, to: url)
        let read = WatchdogStateStore.read(from: url)
        #expect(read == original)
    }

    @Test("reading a missing file yields empty state, not an error")
    func missingFileIsEmpty() {
        let read = WatchdogStateStore.read(from: tempURL())
        #expect(read == WatchdogState())
        #expect(read.downSince == nil)
        #expect(read.lastRestartAt == nil)
    }

    @Test("write reports success, and failure on an unwritable path")
    func writeReportsOutcome() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WatchdogStateStore.write(WatchdogState(downSince: 1), to: url))
        // /dev/null is a file, so it can never become a parent directory.
        #expect(!WatchdogStateStore.write(WatchdogState(), to: URL(fileURLWithPath: "/dev/null/watchdog/state.json")))
    }
}

/// The `auto_restart` config flag.
@Suite("Provider auto_restart config")
struct ProviderAutoRestartConfigTests {
    @Test("auto_restart defaults to true when absent")
    func defaultsTrue() {
        let config = ConfigManager.parse("""
        [provider]
        name = "test-provider"
        """)
        #expect(config.provider.autoRestart)
    }

    @Test("auto_restart = false is honoured")
    func explicitFalse() {
        let config = ConfigManager.parse("""
        [provider]
        name = "test-provider"
        auto_restart = false
        """)
        #expect(!config.provider.autoRestart)
    }

    @Test("auto_restart survives a serialize round-trip")
    func roundTrips() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider", autoRestart: false)
        )
        let decoded = ConfigManager.parse(ConfigManager.serialize(original))
        #expect(!decoded.provider.autoRestart)
    }
}
