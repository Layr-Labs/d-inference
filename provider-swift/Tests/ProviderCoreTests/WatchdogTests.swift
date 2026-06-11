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
}

/// The watchdog launchd plist shape.
@Suite("Watchdog agent plist")
struct WatchdogAgentPlistTests {
    @Test("plist runs `darkbloom watchdog` on a one-minute interval at load")
    func plistShape() {
        let plist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: ["/usr/local/bin/darkbloom", "watchdog"],
            logPath: "/tmp/watchdog.log",
            intervalSeconds: 60
        )
        #expect(plist["Label"] as? String == "io.darkbloom.watchdog")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/darkbloom", "watchdog"])
        #expect(plist["StartInterval"] as? Int == 60)
        #expect(plist["RunAtLoad"] as? Bool == true)
        // Cadence is StartInterval's job; the watchdog must not KeepAlive.
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["StandardOutPath"] as? String == "/tmp/watchdog.log")
        #expect(plist["StandardErrorPath"] as? String == "/tmp/watchdog.log")
    }

    @Test("the watchdog label is distinct from the provider label")
    func distinctLabel() {
        #expect(WatchdogAgent.label != LaunchAgent.label)
        #expect(LaunchAgent.supportedLabels.contains(LaunchAgent.label))
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
