// Start daemon install: resolve the model selection, then register + kick the
// launchd background service (the interactive-picker -> launchd path).
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    // MARK: - Daemon (interactive picker → launchd)

    internal mutating func launchDaemon(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        coordinatorURL: String,
        configPath: URL?
    ) async throws {
        // Run critical checks before downloading models or prompting.
        try runPreflightChecks(snapshot: snapshot)

        // Offer account linking before the model picker.
        await offerInlineLogin(coordinatorURL: coordinatorURL)

        let selectedModelIDs: [String]

        if !model.isEmpty {
            selectedModelIDs = model
        } else if all {
            selectedModelIDs = snapshot.models.map(\.id)
        } else {
            selectedModelIDs = try await interactiveCatalogPicker(
                snapshot: snapshot,
                config: config,
                coordinatorURL: coordinatorURL
            )
        }

        guard !selectedModelIDs.isEmpty else {
            printError("No models selected.")
            throw ExitCode.failure
        }

        try LaunchAgent.installAndStart(
            coordinatorURL: coordinatorURL,
            models: selectedModelIDs,
            idleTimeout: idleTimeout ?? (config.backend.idleTimeoutMins > 0 ? config.backend.idleTimeoutMins : nil),
            configPath: configPath,
            localEndpoint: LaunchAgent.LocalEndpointOptions(
                enabled: localEndpoint, port: port, bind: bind, noAuth: noAuth
            )
        )

        // Arm the crash-recovery watchdog (relaunches ~5 min after a crash;
        // `stop` disarms, `auto_restart = false` opts out — including
        // disarming a watchdog left loaded by a previous opted-in config).
        // Best-effort.
        let autoRestartOn = config.provider.autoRestart
        switch WatchdogAgent.rearmAction(
            autoRestartEnabled: autoRestartOn,
            isLoaded: WatchdogAgent.isLoaded()
        ) {
        case .arm:
            do {
                try WatchdogAgent.installAndStart(
                    configPath: snapshot.configPath
                )
            } catch {
                printError("note: could not install crash-recovery watchdog: \(error)")
            }
        case .disarm:
            try? WatchdogAgent.stop()
        case nil:
            break
        }

        let logPath = LaunchAgent.logPath().path
        print("Provider started as background service.")
        print("  Models:  \(selectedModelIDs.count)")
        for id in selectedModelIDs {
            print("    \(id)")
        }
        if localEndpoint {
            let shownURL = "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1"
            print("  Local:   \(shownURL) (unified mode — run `darkbloom local` for the API key)")
        }
        print("  Logs:    \(logPath)")
        if autoRestartOn {
            print("  Recovery: auto-restart on (relaunches ~5 min after a crash)")
        }
        print()
        print("  darkbloom stop     Stop the provider")
        print("  darkbloom restart  Restart with the current selection")
        print("  darkbloom status   Check status")
    }

}
