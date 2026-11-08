import Foundation
import ArgumentParser
import ProviderCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show local provider configuration and hardware status.",
        discussion: "On a Mac in a two-Mac cluster it starts with the pair, in the words of `\(ClusterPairSummary.cli) cluster status` "
            + "(who leads, the model, whether it serves now and what to do), then this Mac's configuration and hardware. "
            + "When this Mac serves alone instead of the pair, it says so under the pair and shows that serving's own lines. "
            + "With --solo it shows single-Mac serving on this Mac instead of the pair."
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(help: "On a Mac in a two-Mac cluster: show single-Mac serving on this Mac (the provider service) instead of the pair.")
    var solo = false

    mutating func run() async throws {
        // Asked first, so the add-on answers while the banner and the config
        // load run; bounded, so the add-on can never hold up or fail status.
        let sandboxLine = Task.detached {
            SandboxStatusView.statusLine(SandboxAddon.live().queryStatus(timeout: Sandbox.statusLineTimeout))
        }
        DarkbloomCommandLook.forCommand().open("Darkbloom status")

        // Best-effort: tell the user if a newer release is published before
        // we dump current status. Bounded by a 2s timeout in UpdateBanner.
        await runUpdateBannerIfEnabled()

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let config = snapshot.config
        let models = advertisedModels(from: snapshot.models, config: config)

        // On a Mac in a cluster the pair comes first, as `darkbloom cluster status` says it, then whether this Mac serves
        // alone instead (`start --solo`), in plain words.
        let pair = ClusterPairSummary.local()
        let showsPair = pair.paired && !solo
        let servingAlone = showsPair ? soloServingHere() : nil
        if showsPair {
            for line in await ClusterPairSummary.live(config: configOptions.config, bounded: ClusterPairCommands.printLine).clusterStatusLines {
                print(line)
            }
            if let state = servingAlone { print(Self.servingAloneLine(pid: state.pid)) }
            print("")
        }

        print("\(BuildEnvironment.current.cliName) \(ProviderCore.version)")
        print("Provider: \(config.provider.name)")
        print("Config: \(describeConfigPath(snapshot))")
        print("Coordinator: \(config.coordinator.url)")
        print("Backend port: \(config.backend.port)")
        print("Configured model: \(config.backend.model ?? "auto-select")")
        print("Memory when idle: \(IdleUnloadPolicy.describe(minutes: config.backend.idleTimeoutMins)) (manage with `\(BuildEnvironment.current.cliName) idle`)")
        if config.backend.modelAutopilot.hasConsent && !config.coordinator.privateOnly {
            print("Autopilot enrollment: Experimental (not live activation; run `\(BuildEnvironment.current.cliName) autopilot status` for the current mode)")
            print("  The saved idle policy applies in shadow mode or while waiting for control.")
        }
        let preloadSource = config.backend.preloadModels.isEmpty
            ? "selected models" : "explicit preload_models (\(config.backend.preloadModels.count))"
        print("Startup preload: \(config.backend.startupPreload ? "on" : "off") "
              + "(\(preloadSource); timeout \(config.backend.startupPreloadTimeoutSecs)s)")
        print("Beta features: \(betaFeaturesStatus(config)) (manage with `\(BuildEnvironment.current.cliName) beta`)")
        print("Auto-restart: \(autoRestartStatus(config: config))")

        if let hardware = snapshot.hardware {
            print("Hardware: \(hardware.chipName), \(hardware.memoryGb) GB RAM, \(hardware.gpuCores) GPU cores")
            print("Inference memory: \(hardware.memoryAvailableGb) GB nominal hardware budget (not live free RAM)")
        } else {
            print("Hardware: unavailable (\(snapshot.hardwareError?.localizedDescription ?? "unknown error"))")
        }

        print(bootSecurityStatusLine(BootSecuritySnapshot.live()))

        if let scheduleConfig = config.schedule,
           let schedule = Schedule.from(config: scheduleConfig) {
            let active = schedule.isActiveNow()
            print("Schedule: \(schedule.describe())")
            print("Availability: \(active ? "active" : "inactive")")
        } else {
            print("Schedule: always available")
        }

        let enabledFilter = config.backend.enabledModels.isEmpty ? "none" : config.backend.enabledModels.joined(separator: ", ")
        print("Enabled model filter: \(enabledFilter)")
        print("Local MLX models: \(models.count)")
        print("Serving concurrency: \(ServingPerformanceProfiles.summary(backend: config.backend))")
        if let line = await sandboxLine.value { print(line) }

        // Live daemon state (from the state file the running daemon writes).
        print("")
        if LaunchAgent.installedJobIsClusterMember(),
           let supervisor = ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self,
                                                         from: ClusterSupervisionFiles.statePath()) {
            print(supervisor.summary(now: Date().timeIntervalSince1970))
        }
        for line in Self.clusterServiceLines() { print(line) }
        if showsPair {
            // The daemon lines are single-Mac serving's only when it runs here; otherwise they would be the cluster's own
            // part's, read as single-Mac serving.
            if servingAlone != nil {
                printDaemonStatus(config: config, models: snapshot.models, hardware: snapshot.hardware, pair: pair)
            }
        } else {
            if pair.paired { print(pair.statusLine) }
            printDaemonStatus(config: config, models: snapshot.models, hardware: snapshot.hardware, pair: pair)
        }

        // Crash-loop KV-backend guard — printed whether or not the daemon is
        // up, because the guard's whole story happens while the daemon is
        // crashing: an operator asking "why is this box on contiguous?" (or
        // "why was it down for 20 minutes?") gets the answer here.
        for line in KVBackendGuardDiagnostics.statusLines(
            record: KVBackendGuardStore.read(),
            now: Date().timeIntervalSince1970,
            runningVersion: ProviderCore.version)
        {
            print(line)
        }
    }

    /// On a Mac in a cluster: single-Mac serving that runs here (`start --solo`), never the cluster's own part; nil when
    /// none runs.
    private func soloServingHere() -> DaemonState? {
        guard let state = ServiceDrain.soloProviderState(), daemonProcessAlive(pid: state.pid) else { return nil }
        return state
    }

    /// Under the pair's block when this Mac serves alone: the pair and single-Mac serving share its one serving lock, so
    /// it serves one or the other, never both.
    static func servingAloneLine(pid: Int32) -> String {
        "This Mac serves alone (single-Mac serving, process \(pid)), not the pair; its status is below."
    }

    /// One-line summary of crash-recovery state: the config opt-out plus whether
    /// the launchd watchdog agent is actually armed.
    private func autoRestartStatus(config: ProviderConfig) -> String {
        guard config.provider.autoRestart else {
            return "off (auto_restart = false)"
        }
        if WatchdogAgent.isLoaded() {
            return "on (watchdog active; relaunches ~5 min after a crash)"
        }
        if WatchdogAgent.isInstalled() {
            return "on (watchdog installed but not loaded)"
        }
        return "on (watchdog not installed — run `\(BuildEnvironment.current.cliName) start` or `restart` to arm)"
    }

    func bootSecurityStatusLine(_ bootSecurity: BootSecuritySnapshot) -> String {
        let status = bootSecurity.issues.isEmpty ? CheckStatus.pass : .warn
        return "Local boot checks: \(status.marker) \(bootSecurity.macOSSummary); "
            + "SIP \(bootSecurity.sip.summary); Secure Boot has no local public check"
    }

    /// Prints the running daemon's live state, including the coordinator's last
    /// trust reason — the answer to "am I earning, and if not, why?".
    private func printDaemonStatus(config: ProviderConfig, models: [ModelInfo], hardware: HardwareInfo?,
                                   pair: ClusterPairSummary) {
        let now = Date().timeIntervalSince1970
        guard let state = DaemonStateFile.read() else {
            print(Self.daemonNotRunningLine(paired: pair.paired, unsure: pair.pairingUnreadable))
            if let line = Self.steppedAsideLine(paired: pair.paired) { print(line) }
            return
        }
        let alive = daemonProcessAlive(pid: state.pid)
        if !alive {
            print(Self.daemonNotRunningLine(paired: pair.paired, unsure: pair.pairingUnreadable, staleStateFile: true))
            if let line = Self.steppedAsideLine(paired: pair.paired) { print(line) }
            return
        }
        print(daemonHealthLine(
            state: state,
            now: now,
            heartbeatIntervalSecs: config.coordinator.heartbeatIntervalSecs))
        // The cluster's part writes this state too: say so, so its lines are not read as single-Mac serving.
        if pair.paired, ServiceDrain.soloProviderState(state) == nil { print(Self.clusterPartLine) }
        if let drain = Self.lifecycleDrainLine(state.lifecycle) { print(drain) }
        if let hold = Self.addonHoldLine(state.addonHold) { print(hold) }
        for line in Self.servingLines(state: state, liveEndpoint: LocalEndpoint.readLiveInfo(), route: config.local?.route,
                                      accountKeySaved: { Start.accountKeySaved() },
                                      server: .of(state, paired: pair.paired)) {
            print(line)
        }
        if state.autopilotPhase != nil {
            let fresh = Autopilot.Status.snapshotIsFresh(state,
                heartbeatIntervalSecs: config.coordinator.heartbeatIntervalSecs, now: now)
            print("Autopilot - Experimental: \(Autopilot.Status.phaseDescription(fresh ? state.autopilotPhase : nil))")
            if fresh && state.autopilot?.revision != config.backend.modelAutopilot.revision {
                print("  Configuration change waiting to apply")
            }
        }
        if let status = state.modelSwitch {
            let stale = state.isStale(now: now) ? " (stale)" : ""
            print("Model switch: \(status.outcome.rawValue)\(stale); \(status.remaining) unfinished request(s)")
            if let requestID = status.requestID { print("  Request: \(requestID)") }
            if let message = status.message { print("  \(message)") }
            print("  Selection: \(status.models.joined(separator: ", "))")
        }

        let authorization = state.displayedProviderAuthorization(
            coordinatorURL: config.coordinator.url, now: now)
        let removalAuthorization = state.currentProviderAuthorization(
            coordinatorURL: config.coordinator.url, now: now)
        if let authorization {
            print("Authorization: \(ProviderAuthorizationReadiness.summary(authorization, removalAuthorization: removalAuthorization, now: now))")
            if !authorization.machineID.isEmpty { print("Machine ID: \(authorization.machineID)") }
        } else if let trust = state.trust {
            let advice = TrustReasonCatalog.advice(level: trust.trustLevel, status: trust.status, reason: trust.reason)
            print("Trust: \(trust.trustLevel) / \(trust.status)")
            print("  → \(advice.message)")
            if let fix = advice.fix { print("  → fix: \(fix)") }
        } else {
            print("Trust: awaiting coordinator status")
        }
        if Self.lifecycleDrainLine(state.lifecycle) == nil, !state.isStale(now: now),
           let verdict = ServingReadiness.verdict(state, now: now) {
            for line in Self.trafficLines(verdict) { print(line) }
        }

        print("Warm models: \(WarmModelsFormat.warmModelsLine(warmModels: state.warmModels, currentModel: state.currentModel))")
        for line in Self.selectionLines(state: state, enabledModels: config.backend.enabledModels)
            + Self.pendingSelectionLines(state: state, enabledModels: config.backend.enabledModels)
            + Self.placementLines(state: state, now: now) {
            print(line)
        }
        let readiness = Self.liveLoadReadiness(
            state: state, models: models, now: now,
            heartbeatIntervalSecs: config.coordinator.heartbeatIntervalSecs)
        if let usable = state.capacity?.loadUsableGb, !readiness.isEmpty {
            print("Live load memory: \(String(format: "%.1f", usable)) GB usable now (no eviction)")
        }
        for line in Self.notLoadedLines(
            advertised: state.advertisedModels,
            warmModels: state.warmModels,
            currentModel: state.currentModel,
            startupPreloadPendingModels: state.startupPreloadPendingModels,
            readiness: readiness,
            evictionAwareWeightGb: state.capacity?.freeForLoadGb,
            inferenceActive: state.inferenceActive || state.requestWorkPending == true
                || state.loadTransitionActive == true
                || state.capacity?.loadTransitionActive == true)
        {
            print(line)
        }
        for line in Self.recoveryLines(state: state, now: now) + Self.evictionExclusionLines(state: state) {
            print(line)
        }
        print("\(WarmModelsFormat.mostRecentlyUsedLabel): \(WarmModelsFormat.mostRecentlyUsedLine(currentModel: state.currentModel))")
        for line in Self.servedRequestLines(state: state, now: now) { print(line) }
        if let err = state.lastModelLoadError {
            print("Last model-load error: \(err.model): \(err.message)")
            print("  Recorded \(Self.compactDuration(now - err.at)) ago")
            if let notice = GLMWiredLimitAdvice.statusNotice(
                loadError: err, hardware: hardware, limits: .live()) {
                print("  → fix: \(notice)")
            }
        }

        // Which KV backend is this box actually serving on, and is MTP
        // producing drafts or merely enabled? Both read the same state file
        // as everything above, against the same `staleAfter` bar, so the block
        // carries its own age — see `KVBackendPosture` for why a bare value
        // would be worse than none.
        for line in KVBackendPosture.statusLines(
            state: state,
            now: now,
            heartbeatIntervalSecs: config.coordinator.heartbeatIntervalSecs)
        {
            print(line)
        }
    }

    /// Both bars come from `KVBackendPosture`, the same source the
    /// slot-posture block reads. `DaemonState.isStale` defaults to a flat
    /// 90 s while that block derives its bound from `heartbeat_interval_secs`,
    /// so at the default 5 s heartbeat — 90 s against 10 s — a 30-second-old
    /// snapshot printed "Daemon: running" immediately above "Slot posture:
    /// STALE": two verdicts on one file, fourteen lines apart, and nothing
    /// to say which to believe.
    ///
    /// THREE states, because one derived bar is still one bar too few.
    /// "The snapshot is suspect" and "the daemon is stuck" are different
    /// claims. `staleAfterSeconds` is four missed writes — 10 s at the
    /// default heartbeat — which transient load crosses on a perfectly
    /// healthy box, so it may only discount the live fields below it.
    /// Only `wedgedAfterSeconds`, eight missed writes floored at 90 s, is
    /// an accusation against the daemon, and it is the same bar `doctor`
    /// withholds its backend verdict at.
    ///
    /// `WatchdogProbe`, `WatchdogRecoveryService` and `DoctorRunner` still
    /// take the flat 90 s default; moving them is a behavior change to
    /// restart and health-gating logic and needs its own review.
    func daemonHealthLine(
        state: DaemonState,
        now: Double,
        heartbeatIntervalSecs: UInt64
    ) -> String {
        let age = state.ageSeconds(now: now)
        let ageText = "\(Int(age.rounded()))s"
        let wedgedAfter = KVBackendPosture.wedgedAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        if age > wedgedAfter {
            return "Daemon: running (pid \(state.pid)) but last update \(ageText) ago "
                + "(expected within \(Int(wedgedAfter))s) — possibly wedged"
        }

        let uptime = Self.compactDuration(state.uptimeSeconds(now: now))
        let staleAfter = KVBackendPosture.staleAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        guard age > staleAfter else {
            return "Daemon: running (pid \(state.pid), up \(uptime))"
        }
        let period = KVBackendPosture.refreshPeriodSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        return "Daemon: running (pid \(state.pid), up \(uptime)) but last update \(ageText) ago "
            + "(expected every ~\(Int(period))s) — snapshot stale, the fields below may be "
            + "out of date"
    }

    /// Separate models still queued for startup preload from those that will
    /// load on a request. The latter include idle-unloaded, skipped and failed
    /// preloads; `Last model-load error` below supplies a known failure cause.
    static func notLoadedLines(
        advertised: [String]?,
        warmModels: [String],
        currentModel: String?,
        startupPreloadPendingModels: [String]?,
        readiness: [String: ModelLoadReadiness] = [:],
        evictionAwareWeightGb: Double? = nil,
        inferenceActive: Bool = false
    ) -> [String] {
        guard let advertised else { return [] }
        var resident = Set(warmModels)
        if let currentModel, !currentModel.isEmpty { resident.insert(currentModel) }
        let notLoaded = advertised.filter { !resident.contains($0) }
        let pending = Set(startupPreloadPendingModels ?? [])
        let preloading = notLoaded.filter { pending.contains($0) }
        let temporarilyBusy = notLoaded.filter {
            inferenceActive && !pending.contains($0) && (readiness[$0]?.shortfallGb ?? 0) > 0
        }
        let blocked = notLoaded.filter {
            !inferenceActive && !pending.contains($0) && (readiness[$0]?.shortfallGb ?? 0) > 0
        }
        let onRequest = notLoaded.filter {
            !pending.contains($0) && !blocked.contains($0) && !temporarilyBusy.contains($0)
        }
        var lines: [String] = []
        if !preloading.isEmpty {
            lines.append("Startup preload pending: \(preloading.joined(separator: ", "))")
        }
        if !onRequest.isEmpty {
            lines.append("Not loaded (loads on request): \(onRequest.joined(separator: ", "))")
        }
        if !temporarilyBusy.isEmpty {
            lines.append("Load readiness temporarily busy: \(temporarilyBusy.joined(separator: ", ")) — a request, model load, or reload is active; recheck when idle.")
        }
        var coldLoadBlocked = false
        var coldShortfallGb = 0.0
        for model in blocked {
            guard let budget = readiness[model] else { continue }
            let mayEvict = evictionAwareWeightGb.map { $0 >= budget.estimatedMemoryGb }
            if mayEvict == false {
                coldLoadBlocked = true
                coldShortfallGb = max(coldShortfallGb, budget.estimatedMemoryGb - (evictionAwareWeightGb ?? 0))
            }
            let label = mayEvict == true ? "Preload skipped (no eviction)"
                : mayEvict == false ? "Cold load blocked (memory)" : "Preload blocked (memory)"
            lines.append(
                "\(label): \(model) — "
                + "\(String(format: "%.1f", budget.estimatedMemoryGb)) GB model + "
                + "\(String(format: "%.1f", budget.headroomGb)) GB serving reserve = "
                + "\(String(format: "%.1f", budget.requiredGb)) GB needed; "
                + "\(String(format: "%.1f", budget.usableGb)) GB usable now "
                + "(\(String(format: "%.1f", budget.shortfallGb)) GB short without eviction)."
                + (mayEvict == false
                    ? " Still \(String(format: "%.1f", budget.estimatedMemoryGb - (evictionAwareWeightGb ?? 0))) GB short after idle eviction."
                    : ""))
            if mayEvict == true {
                lines.append("  A request may load it after evicting idle slots; startup preload keeps them resident.")
            }
        }
        if coldLoadBlocked {
            lines.append("  Free at least \(String(format: "%.1f", coldShortfallGb)) GB with margin, confirm with `\(BuildEnvironment.current.cliName) doctor`, then retry the load.")
        }
        return lines
    }
}

/// Render every configured beta posture rather than only the force-enabled
/// subset. In particular, MTP automatic mode is model-aware and must not
/// disappear from `darkbloom status` or look like an explicit rollback.
func betaFeaturesStatus(_ config: ProviderConfig) -> String {
    guard !BetaFeatures.all.isEmpty else { return "none" }
    return BetaFeatures.all.map { feature in
        "\(feature.id)=\(feature.state(in: config).displayValue)"
    }.joined(separator: ", ")
}
