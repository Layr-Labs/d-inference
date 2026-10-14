import ArgumentParser
import Foundation
import ProviderCore

extension ServiceDrain {
    static func publishWithRecoveryRollback(disable: () throws -> Void,
                                            publish: () throws -> Void,
                                            restore: () throws -> Void) throws {
        do { try disable(); try publish() }
        catch {
            let setupError = error
            do { try restore() }
            catch { throw ValidationError("Drain setup failed: \(setupError). Restoring previous recovery also failed: \(error)") }
            throw setupError
        }
    }

    /// Restore configured crash recovery after a successful CLI restart/update.
    /// An explicit config wins; otherwise retain the watchdog's installed path.
    static func rearmWatchdog(explicitConfig: String? = nil) {
        let watchdogConfig = WatchdogAgent.rearmConfigPath(
            explicit: explicitConfig,
            installed: WatchdogAgent.installedConfigPath()
        )
        switch WatchdogAgent.rearmAction(
            autoRestartEnabled: Watchdog.autoRestartEnabled(configPath: watchdogConfig?.path),
            isLoaded: WatchdogAgent.isLoaded()
        ) {
        case .arm:
            try? WatchdogAgent.installAndStart(configPath: watchdogConfig)
        case .disarm:
            try? WatchdogAgent.stop()
        case nil:
            break
        }

    }

    /// Run a drained relaunch and restore crash recovery on every exit after the
    /// drain has committed. A relaunch that stopped the old instance but failed
    /// to start the new one otherwise propagates without re-arming, leaving the
    /// provider down with automatic recovery disabled. Re-arm runs on both the
    /// success and failure path, before the caller waits on startup. The
    /// drain-timeout fence in `prepare` is unaffected: it throws before any
    /// relaunch is attempted.
    static func relaunchDrainedProvider(
        explicitConfig: String?,
        rearm: (String?) -> Void = { ServiceDrain.rearmWatchdog(explicitConfig: $0) },
        relaunch: () async throws -> Void
    ) async throws {
        defer { rearm(explicitConfig) }
        try await relaunch()
    }
}
