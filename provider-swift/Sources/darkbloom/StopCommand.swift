import ArgumentParser
import Foundation
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the provider launchd service.",
        discussion: """
        By default waits for any in-flight inference to finish before stopping, \
        so active requests are not cut off mid-generation. Use --force to stop \
        immediately without waiting, or --timeout to customize how long to wait.

        The wait polls the daemon's state file for an idle moment; the \
        coordinator may keep routing new requests meanwhile, so a busy provider \
        can reach the timeout. Re-run with --force in that case.
        """
    )

    @Flag(help: "Also remove the launchd plist (full uninstall).")
    var uninstall = false

    @Flag(name: .long, help: "Force stop immediately without waiting for in-flight requests to finish.")
    var force = false

    @Option(name: .long, help: "Maximum seconds to wait for in-flight requests to finish before stopping (default 60). Ignored with --force.")
    var timeout: Int = 60

    mutating func validate() throws {
        guard timeout >= 0 else {
            throw ValidationError("--timeout must be >= 0")
        }
    }

    mutating func run() async throws {

        let wasLoaded = LaunchAgent.isLoaded()

        // Guard: wait for in-flight work BEFORE disarming the watchdog or
        // booting out the service. Disarming first would leave an aborted
        // guard (timeout without --force) with side effects even though the
        // provider was not stopped.
        if !force, wasLoaded {
            try await waitForDrainIfNeeded(timeoutSeconds: timeout)
        }

        // Disarm crash recovery so the watchdog can't relaunch what we're
        // stopping, and drop its timer so the next start gets a fresh grace
        // window (uninstall additionally deletes its plist). Best-effort.
        if uninstall {
            try? WatchdogAgent.uninstall()
        } else {
            try? WatchdogAgent.stop()
        }
        try? FileManager.default.removeItem(at: WatchdogStateStore.path())

        if uninstall {
            try LaunchAgent.uninstall()
            print("Provider service uninstalled.")
        } else {
            try LaunchAgent.stop()
            if wasLoaded {
                print("Provider service stopped. (Won't auto-start at login/reboot until you run `darkbloom start` again.)")
            } else {
                print("Provider service is not running. (Auto-start at login/reboot is now disabled.)")
            }
        }
    }

    /// Poll the daemon state file until no inference is active or the timeout
    /// expires. Throws `ExitCode.failure` if the timeout is reached while work
    /// is still in flight, so the caller must retry with --force or a longer
    /// --timeout. No-ops when the daemon is not running, the state file is
    /// missing/stale, or no work is active.
    internal func waitForDrainIfNeeded(timeoutSeconds: Int) async throws {
        try await Self.waitForDrain(
            timeoutSeconds: timeoutSeconds,
            readState: { DaemonStateFile.read() },
            sleep: { try await Task.sleep(nanoseconds: 1_000_000_000) },
            now: { Date().timeIntervalSince1970 }
        )
    }

    /// Testable core: injectable state reader, sleeper, and clock.
    internal static func waitForDrain(
        timeoutSeconds: Int,
        readState: () -> DaemonState?,
        sleep: () async throws -> Void,
        now: () -> Double
    ) async throws {
        guard let initial = readState() else { return }
        guard StopDrainGuard.shouldWait(state: initial, now: now()) else { return }

        if timeoutSeconds == 0 {
            printError(
                "Active inference in progress — refusing to stop without --force "
                    + "(use --force to stop immediately or --timeout <seconds> to wait)."
            )
            throw ExitCode.failure
        }

        printError(
            "Active inference in progress — waiting up to \(timeoutSeconds)s for requests to finish "
                + "(use --force to stop immediately)..."
        )

        let deadline = now() + Double(timeoutSeconds)
        var elapsed = 0

        while now() < deadline {
            do {
                try await sleep()
            } catch {
                // Task cancelled (e.g. Ctrl-C) — abort the stop, leave the
                // provider running so the in-flight request is not cut off.
                printError("Wait cancelled — provider still running.")
                throw ExitCode.failure
            }

            guard let state = readState() else { return }
            if !StopDrainGuard.shouldWait(state: state, now: now()) {
                print("All in-flight requests finished — stopping provider.")
                return
            }

            elapsed += 1
            if elapsed % 5 == 0 {
                let remaining = max(0, Int((deadline - now()).rounded(.up)))
                printError("  still active after \(elapsed)s (\(remaining)s remaining)...")
            }
        }

        // Final check after deadline.
        if let final = readState(), StopDrainGuard.shouldWait(state: final, now: now()) {
            printError(
                "Timed out after \(timeoutSeconds)s with active requests still in progress. "
                    + "Use --force to stop immediately, or --timeout <seconds> to wait longer."
            )
            throw ExitCode.failure
        }
    }
}
