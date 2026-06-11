import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

/// `darkbloom watchdog` -- one crash-recovery check, then exit.
///
/// Run once a minute by `WatchdogAgent` (launchd `StartInterval`). It is the
/// thin I/O shell around `WatchdogPolicy.decide`: probe launchd, read the
/// cross-tick timer, decide, act. Hidden from `--help` because it is a
/// machine-invoked maintenance command, not a user-facing verb.
///
/// Why a 5-minute delay instead of an instant relaunch (e.g. launchd
/// `KeepAlive`): it sidesteps the self-updater's brief kill+relaunch, gives a
/// transient fault (thermal throttle, a network blip, a wedged GPU clearing)
/// time to settle, and bounds a crash-looping binary to one attempt per window
/// instead of a tight respawn storm.
struct Watchdog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watchdog",
        abstract: "Internal: one provider crash-recovery check (run by launchd).",
        shouldDisplay: false
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        let now = Date().timeIntervalSince1970
        let enabled = Self.autoRestartEnabled(configPath: configOptions.config)
        let liveness = WatchdogProbe.probeProvider(now: now)
        let state = WatchdogStateStore.read()
        // Ignore a downSince left over from a previous boot so every outage gets
        // a fresh grace window rather than an instant post-reboot restart.
        let downSince = WatchdogPolicy.effectiveDownSince(state.downSince, bootTime: Self.systemBootTime())

        let decision = WatchdogPolicy.decide(
            autoRestartEnabled: enabled,
            providerLoaded: liveness.loaded,
            providerRunning: liveness.running,
            downSince: downSince,
            now: now
        )

        let grace = Int(WatchdogPolicy.defaultGraceSeconds)

        // Side effects (log + restart). Persistence is computed purely below.
        switch decision {
        case .restart:
            // `kickstartIfLoaded` re-confirms the job is still loaded right before
            // acting: if `darkbloom stop` landed since the probe it is a no-op, so
            // we never revive a provider the user intentionally stopped.
            do {
                if try LaunchAgent.kickstartIfLoaded() {
                    log("provider down > \(grace)s — restart issued")
                } else {
                    log("provider no longer loaded — skipping restart")
                }
            } catch {
                log("restart failed: \(error)")
            }
        case .startGrace:
            log("provider appears down — will restart in \(grace)s if it stays down")
        case .waiting(let remaining):
            log("provider still down — restart in ~\(Int(remaining))s")
        case .healthy:
            if downSince != nil { log("provider recovered — cancelling pending restart") }
        case .disabled, .notManaged:
            break // opted out, stopped, or uninstalled — nothing to do
        }

        if let newState = WatchdogPolicy.nextState(for: decision, current: state, now: now) {
            WatchdogStateStore.write(newState)
        }
    }

    /// System boot time as epoch seconds, or nil if it can't be read. Used to
    /// discard a stale `downSince` from a previous uptime (see effectiveDownSince).
    static func systemBootTime() -> Double? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        let rc = mib.withUnsafeMutableBufferPointer { ptr in
            sysctl(ptr.baseAddress, UInt32(ptr.count), &boot, &size, nil, 0)
        }
        guard rc == 0, boot.tv_sec > 0 else { return nil }
        return Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        #else
        return nil
        #endif
    }

    /// Read just the `auto_restart` flag, cheaply — no hardware detection or
    /// model scan (this runs every minute). Fails open to enabled so a missing
    /// or malformed config never silently disables crash recovery.
    static func autoRestartEnabled(configPath: String?) -> Bool {
        let path: URL
        if let configPath {
            path = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
        } else if let resolved = try? ConfigManager.defaultConfigPath() {
            path = resolved
        } else {
            return true
        }
        guard FileManager.default.fileExists(atPath: path.path),
              let config = try? ConfigManager.load(from: path)
        else {
            return true
        }
        return config.provider.autoRestart
    }

    /// Append a timestamped line; launchd routes our stdout to
    /// `~/.darkbloom/watchdog.log`. We log only state transitions and actions,
    /// so quiet ticks (the overwhelming majority) write nothing.
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] watchdog: \(message)")
    }
}
