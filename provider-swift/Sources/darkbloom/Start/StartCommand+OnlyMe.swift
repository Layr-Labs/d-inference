// Only me in the background, as the other two choices serve: the same model picker (with downloads) and memory
// question, then the provider LaunchAgent the app's local mode runs (`start --foreground --local` on this Mac's one
// port), which starts at login and has the watchdog and the update loop. `start --local --here` serves in a terminal
// instead (`runLocalStandalone`).
import ArgumentParser
import Foundation
import ProviderCore

extension Start {
    /// Whether Only me serves in this process: for `--here` (this terminal, this session) and for a service's child
    /// (`--foreground`, launchd's); every other Only me start installs or restarts the background service.
    static func servesOnlyMeInThisProcess(here: Bool, foreground: Bool) -> Bool { here || foreground }

    /// Sets Only me up in the background and returns. Its job serves on `serving.port`, this Mac's one port as every
    /// start resolves it, so a local API already on 8000 stays on 8000.
    internal func launchOnlyMeService(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        coordinatorURL: String,
        configPath: URL?,
        runtimeCapabilities: Set<ProviderRuntimeCapability>,
        serving: StartServing
    ) async throws {
        try Self.requireMemoryForAnyModel(snapshot.hardware)
        let selected = try await onlyMeModels(snapshot: snapshot, config: config, coordinatorURL: coordinatorURL,
                                              runtimeCapabilities: runtimeCapabilities)
        // Saved only once the models are chosen, as for the other two choices.
        try saveServingChoice(serving)
        var idleMinutes = config.backend.idleTimeoutMins
        if model.isEmpty, !all, idleTimeout == nil {
            idleMinutes = try promptIdleUnloadPolicy(current: idleMinutes, selectedModelIDs: selected,
                                                     snapshot: snapshot)
        }

        // A cancelled picker never disturbs the running provider; the drain comes after it.
        try Task.checkCancellation()
        let running = ServiceDrain.soloProviderState()
        if let line = Self.onlyMeReplacesLine(running) { print(line) }
        let look = DarkbloomCommandLook.forCommand()
        let replacement = try await look.working("Draining accepted requests") {
            try await ServiceDrain.prepare(options: drain, state: running, withConfigurationChange: { setup in
                try ProviderModelSelection.withReplacement(selected, configPath: snapshot.configPath,
                                                           fallbackConfig: config, body: setup)
            })
        }
        defer { replacement.release() }
        try await look.working("Starting Only me in the background") {
            try await ServiceDrain.stopDrainedProvider(daemonState: ServiceDrain.soloProviderState())
            try LaunchAgent.installLocalAndStart(models: selected, configPath: configPath, port: serving.port,
                                                 bind: serving.bind, noAuth: serving.noAuth)
        }
        Self.armRecoveryWatchdog(autoRestart: config.provider.autoRestart, configPath: snapshot.configPath)
        for line in Self.onlyMeServiceSummary(models: selected, idleMinutes: idleMinutes, serving: serving,
                                              autoRestart: config.provider.autoRestart,
                                              autoUpdate: config.provider.autoUpdate) {
            print(line)
        }
    }

    /// Only me's models, picked as the other two choices pick theirs: `--model` or `--all` as given; in a terminal, the
    /// picker with downloads (the models already on this Mac when Darkbloom's catalog can't be read); without one,
    /// nothing is asked, so a script or the app's Start never waits (`onlyMeModelsWithoutAsking`). Only the ones this
    /// Mac's own server serves are kept; with none, the start ends with the commands that get one.
    func onlyMeModels(snapshot: RuntimeSnapshot, config: ProviderConfig, coordinatorURL: String,
                      runtimeCapabilities: Set<ProviderRuntimeCapability>,
                      terminal: Bool = ClusterPairCommands.isTerminal()) async throws -> [String] {
        let onThisMac = Self.locallyServable(
            advertisedModels(from: snapshot.models, config: config, includeDisabled: true,
                             runtimeCapabilities: runtimeCapabilities),
            mtpMode: config.backend.mtpMode).servable.map(\.id)
        let asks = model.isEmpty && !all
        let picked: [String]
        if asks, !terminal {
            picked = Self.onlyMeModelsWithoutAsking(lastSelection: config.backend.enabledModels, onThisMac: onThisMac)
        } else {
            picked = try await selectStartupModels(snapshot: snapshot, config: config, coordinatorURL: coordinatorURL,
                                                   runtimeCapabilities: runtimeCapabilities, autopilot: false,
                                                   whenCatalogUnreachable: { onThisMac })
            if asks, picked.isEmpty { throw ValidationError("No models selected.") }
        }
        let byID = Dictionary(snapshot.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (servable, skipped) = Self.locallyServable(picked.compactMap { byID[$0] }, mtpMode: config.backend.mtpMode)
        for line in skipped { printError(line) }
        guard !servable.isEmpty else {
            printError(Self.noModelToServe)
            throw ExitCode.failure
        }
        return servable.map(\.id)
    }

    /// Without a terminal: the last selection still on this Mac, else every model this Mac's own server serves.
    static func onlyMeModelsWithoutAsking(lastSelection: [String], onThisMac: [String]) -> [String] {
        let last = lastSelection.filter(onThisMac.contains)
        return last.isEmpty ? onThisMac : last
    }

    /// What an Only me start stops: Darkbloom serving, when the provider running now serves the network; nil otherwise.
    static func onlyMeReplacesLine(_ state: DaemonState?,
                                   alive: (Int32) -> Bool = { daemonProcessAlive(pid: $0) }) -> String? {
        guard let state, !state.servesOnlyItsOwner, alive(state.pid) else { return nil }
        return "Darkbloom network serving stops: this Mac serves only you from now on (`"
            + "\(BuildEnvironment.current.cliName) start --me-first` serves Darkbloom and you)."
    }

    /// What a start that set Only me up in the background says.
    static func onlyMeServiceSummary(models: [String], idleMinutes: UInt64, serving: StartServing, autoRestart: Bool,
                                     autoUpdate: Bool) -> [String] {
        let cli = BuildEnvironment.current.cliName
        let keeps = [autoRestart ? "restarts after a crash" : nil, autoUpdate ? "updates itself" : nil]
            .compactMap { $0 }
        var lines = ["Only me serves in the background: it starts at login"
            + (keeps.isEmpty ? "." : ", \(keeps.joined(separator: " and ")).")]
        lines.append("  Models:  \(models.count)")
        lines += models.map { "    \($0)" }
        lines.append("  Memory:  \(IdleUnloadPolicy.describe(minutes: idleMinutes)) - `\(cli) idle` to change")
        lines += serving.summaryLines
        lines.append("  Logs:    \(LaunchAgent.logPath().path)")
        lines += ["", "  \(cli) stop     Stop it", "  \(cli) restart  Restart with the current selection",
                  "  \(cli) status   Check status"]
        return lines
    }
}
