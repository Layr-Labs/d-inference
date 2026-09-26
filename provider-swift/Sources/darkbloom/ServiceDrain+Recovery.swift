import ArgumentParser
import Foundation
import ProviderCore

extension ServiceDrain {
    static func publishWithRecoveryRollback(prepare: () throws -> Void = {},
                                            disable: () throws -> Void,
                                            publish: () throws -> Void,
                                            restore: () throws -> Void) throws {
        // Persistence failure must leave the current provider and recovery
        // untouched. Only failures after disabling need recovery rollback.
        try prepare()
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
}
