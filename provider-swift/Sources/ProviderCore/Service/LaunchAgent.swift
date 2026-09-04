/// LaunchAgent -- launchd user agent management for the Darkbloom provider.
///
/// The provider runs only after the user explicitly starts it (`darkbloom start`
/// or the app's "Go Online"). It auto-starts at login (RunAtLoad) so a rebooted
/// box re-attests without a manual start; crash recovery is delegated to the
/// separate `WatchdogAgent`. `darkbloom stop` unloads it AND persistently
/// disables it (`launchctl disable`), so a reboot/re-login does not resurrect a
/// provider the user explicitly stopped; `start` re-enables it.

import Foundation

public enum LaunchAgent: Sendable {

    public static let label = "io.darkbloom.provider"
    private static let legacyLabels = ["dev.darkbloom.provider"]

    /// Canonical + legacy labels the provider may be registered under (the
    /// watchdog probes all of them).
    public static var supportedLabels: [String] { [label] + legacyLabels }

    // MARK: - Paths

    /// Path to the launchd plist: ~/Library/LaunchAgents/io.darkbloom.provider.plist
    public static func plistPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// Path to the provider log file: ~/.darkbloom/provider.log
    public static func logPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/provider.log")
    }

    // MARK: - Queries

    /// Whether the plist file exists on disk.
    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath().path)
    }

    /// Whether the launchd service is currently loaded (registered with launchd).
    public static func isLoaded() -> Bool {
        isLoaded(label: label)
    }

    /// Whether any supported launchd label is currently loaded. Prefer this for
    /// process-lifecycle decisions where legacy installations should still be
    /// treated as launchd-managed.
    public static func isAnySupportedLabelLoaded() -> Bool {
        if isLoaded() { return true }
        return legacyLabels.contains { isLoaded(label: $0) }
    }

    private static func isLoaded(label: String) -> Bool {
        let target = "gui/\(getuid())/\(label)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Install & Start

    /// Write the plist, load the service, and kickstart the process.
    ///
    /// If the service is already loaded it is unloaded first to pick up
    /// any plist changes. The plist is written with:
    ///   - KeepAlive = false (no auto-restart on crash; avoids racing the updater)
    ///   - RunAtLoad = true (auto-start when the GUI session loads, i.e. at login —
    ///     at boot on an auto-login box — so a rebooted provider re-attests via APNs
    ///     without a manual `darkbloom start`)
    ///   - ProcessType = Interactive (high priority for real-time inference)
    ///   - Nice = -5 (slight scheduling boost)
    ///
    /// - Parameters:
    ///   - coordinatorURL: WebSocket URL for the coordinator (ws:// or wss://).
    ///   - models: Model IDs to serve (passed as --model flags to `serve`).
    ///   - idleTimeout: Optional idle timeout in minutes (passed as --idle-timeout).
    /// Options for the unified local OpenAI endpoint (serve the public fleet AND
    /// a local endpoint off the same loaded models). `enabled == false` keeps the
    /// daemon coordinator-only.
    public struct LocalEndpointOptions: Sendable {
        public let enabled: Bool
        public let port: UInt16
        public let bind: String
        public let noAuth: Bool
        public init(enabled: Bool = false, port: UInt16 = 8000, bind: String = "127.0.0.1", noAuth: Bool = false) {
            self.enabled = enabled
            self.port = port
            self.bind = bind
            self.noAuth = noAuth
        }
    }

    ///   - progress: Receives one human-readable line when the start has to
    ///     wait for a running provider to drain (the CLI prints it).
    public static func installAndStart(
        coordinatorURL: String,
        models: [String] = [],
        idleTimeout: UInt64? = nil,
        configPath: URL? = nil,
        localEndpoint: LocalEndpointOptions = LocalEndpointOptions(),
        progress: (String) -> Void = { _ in }
    ) throws {
        // Determine the binary path (current executable)
        let binaryPath = currentExecutablePath()

        // If already loaded, unload first so we pick up plist changes — and
        // WAIT for the old instance to leave launchd's table. The daemon
        // traps SIGTERM and drains (refuse → drain → close, up to the
        // graceful drain bound), so after `bootout` returns the old process
        // is still alive: seconds for an idle daemon's teardown, up to
        // `ExitTimeOut` for a busy one. `launchctl print` keeps succeeding
        // for exactly that long (measured on a throwaway label), and a
        // bootstrap issued meanwhile fails with "5: Input/output error" —
        // the old job already booted out, the new one never loaded, the
        // provider offline. Canonical label first, then any legacy label.
        for serviceLabel in supportedLabels where isLoaded(label: serviceLabel) {
            try unloadService(label: serviceLabel)
            try waitForPreviousInstanceToExit(label: serviceLabel, progress: progress)
        }

        try writePlist(
            binaryPath: binaryPath,
            coordinatorURL: coordinatorURL,
            models: models,
            idleTimeout: idleTimeout,
            configPath: configPath,
            localEndpoint: localEndpoint
        )
        try loadService()
    }

    /// Bound on the wait for a booted-out instance to exit: launchd's own
    /// SIGKILL budget for the job (`ExitTimeOut`) plus a margin for the kill
    /// to land. Past it the old process is dead by construction.
    static let previousInstanceExitBound: Duration = .seconds(exitTimeOutSeconds + 5)

    /// Poll until `launchctl print` no longer finds the job — launchd
    /// removes it only once the process has exited — bounded by
    /// `previousInstanceExitBound`. Announces the wait through `progress`
    /// once it exceeds a second (a drain, not an idle teardown).
    static func waitForPreviousInstanceToExit(
        label serviceLabel: String,
        progress: (String) -> Void
    ) throws {
        let gone = ProcessExitWait.wait(
            bound: previousInstanceExitBound,
            onWaiting: { bound in
                progress(
                    "Waiting for the running provider to finish in-flight work before "
                        + "restarting (up to \(bound.components.seconds) s)...")
            },
            gone: { !isLoaded(label: serviceLabel) })
        guard gone else {
            throw LaunchAgentError.previousInstanceStillRunning(
                label: serviceLabel, waitedSeconds: Int(previousInstanceExitBound.components.seconds))
        }
    }

    // MARK: - Stop

    /// Stop the provider: unload the launchd agent AND persistently disable it.
    ///
    /// `bootout` alone only deregisters the job from the current login session.
    /// The plist stays in ~/Library/LaunchAgents (it holds the model selection
    /// for `restart`), and launchd re-bootstraps everything in that directory at
    /// the next login/reboot — so with RunAtLoad=true the provider would come
    /// back even though the user explicitly stopped it. `launchctl disable`
    /// writes a per-user override that survives reboots; `loadService()`
    /// re-enables on the next `start`/`restart`.
    ///
    /// If the service is not loaded, the unload is a no-op but the disable
    /// still applies (covers a stop issued after a crash or partial install).
    public static func stop() throws {
        if isLoaded() {
            try unloadService()
        }
        for legacyLabel in legacyLabels where isLoaded(label: legacyLabel) {
            try unloadService(label: legacyLabel)
        }
        // Disable every supported label: a not-yet-migrated legacy plist on
        // disk would otherwise RunAtLoad under its old label at next login.
        for serviceLabel in supportedLabels {
            let result = LaunchctlControl.setEnabled(false, label: serviceLabel)
            if !result.succeeded {
                throw LaunchAgentError.disableFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - Restart

    /// Restart the provider in place, preserving the current model selection.
    ///
    /// This re-runs the EXISTING launchd plist (same coordinator URL and
    /// `--model` flags) — it never rewrites the plist or shows the model
    /// picker. Behaviour by state:
    ///   - loaded:    `launchctl kickstart -k` kills the running instance and
    ///                immediately relaunches it from the plist's ProgramArguments.
    ///   - installed: (plist on disk but not loaded) bootstrap + kickstart.
    ///   - neither:   throws — there is nothing to restart.
    public static func restart() throws {
        // Canonical label first.
        if isLoaded() {
            try kickstartInPlace(label: label)
            return
        }
        // An upgraded machine may still be running under a legacy label; bounce
        // whichever is actually loaded. Mirrors `stop()`/`installAndStart()`,
        // which both iterate `legacyLabels`, so `restart` can preserve a running
        // provider that hasn't been migrated to the current label yet.
        for legacyLabel in legacyLabels where isLoaded(label: legacyLabel) {
            try kickstartInPlace(label: legacyLabel)
            return
        }
        if isInstalled() {
            // Plist exists but the service isn't loaded — load + kickstart it.
            try loadService()
            return
        }
        throw LaunchAgentError.notInstalled
    }

    /// Restart in place ONLY if currently loaded (`reloadIfMissing: false`), so
    /// the watchdog recovers a crashed (loaded-but-dead) provider but never
    /// revives one the user stopped (`bootout` unloads it). Returns false if not
    /// loaded under any supported label.
    @discardableResult
    public static func kickstartIfLoaded() throws -> Bool {
        if isLoaded() {
            try kickstartInPlace(label: label, reloadIfMissing: false)
            return true
        }
        for legacyLabel in legacyLabels where isLoaded(label: legacyLabel) {
            try kickstartInPlace(label: legacyLabel, reloadIfMissing: false)
            return true
        }
        return false
    }

    /// `launchctl kickstart -k` — kill + relaunch the loaded service in place.
    /// `reloadIfMissing`: `restart()` wants it (bring up an unloaded-but-installed
    /// job); the watchdog passes false so it never loads a job the user stopped.
    private static func kickstartInPlace(label serviceLabel: String, reloadIfMissing: Bool = true) throws {
        let target = "gui/\(getuid())/\(serviceLabel)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", target]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Error 3 = "could not find service": the service vanished between
            // the isLoaded() check and here.
            if stderr.contains("3:") || stderr.contains("could not find service") {
                // Fall back to a fresh load only when allowed; the watchdog opts
                // out so it can't resurrect an intentionally-stopped provider.
                if reloadIfMissing {
                    try loadService()
                }
                return
            }
            throw LaunchAgentError.kickstartFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Uninstall

    /// Completely remove the service: unload + delete plist.
    public static func uninstall() throws {
        try stop()
        let path = plistPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Private

    /// Env vars passed through from the installing shell into the launchd plist's
    /// `EnvironmentVariables`. Kept to a small allowlist so the daemon's
    /// environment stays predictable; only non-empty values are forwarded.
    /// `DARKBLOOM_CBV2_PAGED_KV`: same rationale for
    /// the paged KV backend's fleet kill switch (default-ON for GPT-OSS
    /// slots — see `EngineV2KVBackendPolicy`).
    /// `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS`: the tighten-only automatic
    /// rectangular cap override is the operator's lever to REDUCE speculative
    /// verification work short of disabling MTP entirely; it must survive
    /// install/restart like the kill switches.
    /// `DARKBLOOM_KV_BACKEND_GUARD`: the crash-loop guard's record-path
    /// override (`KVBackendGuardStore.pathEnvKey`). The guard has one writer
    /// (the launchd watchdog — same key in `WatchdogAgent.passthroughEnvKeys`)
    /// and several readers (the launchd daemon's engine factory, a
    /// shell-invoked `status`/`doctor --clear-backend-guard`); a shell-set
    /// override that did not reach the launchd jobs would split them across
    /// two files — the watchdog tripping one path while the daemon and the
    /// operator's clear verb read another.
    /// `DARKBLOOM_MLX_CACHE_LIMIT_GB` / `DARKBLOOM_MLX_MEMORY_RESERVE_GB`:
    /// the `MLXMemoryGuard` operator knobs (buffer-pool cap and whole-machine
    /// memory ceiling reserve). The daemon is where they matter — a shell
    /// export that did not reach launchd would silently no-op in the normal
    /// `darkbloom start` deployment, leaving the advertised recovery lever
    /// (e.g. raising the cache cap after the 8 GiB default) foreground-only.
    /// `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS`: the production cap defaults to
    /// one; exact `0` is the immediate rollback to unlimited interleave.
    /// `DARKBLOOM_PREFILL_DEADLINE_MODE`: the operator's `off` / `enforce`
    /// admission-mode control. Both must persist in the provider job because
    /// launchd restarts (including watchdog recovery) reuse this plist.
    /// `DARKBLOOM_CBV2_PREFILL_NARROWING`: the prompt-narrowing A/B control
    /// and incident escape (`0` restores the full-vocabulary prompt forward).
    static let prefillNarrowingEnvKey = "DARKBLOOM_CBV2_PREFILL_NARROWING"

    /// `DARKBLOOM_CBV2_MIXED_PREFILL_CAP`: the mixed-step prefill token quota
    /// (`SchedulerV2.mixedStepPrefillTokenCap`, read once at engine
    /// construction; default nil = off). Without passthrough the quota was
    /// unreachable in production — set in a shell, lost by the daemon.
    /// The remaining keys are engine reads of the same shape (parsed at
    /// engine/model construction, foreground-only without passthrough):
    /// `DARKBLOOM_CBV2_PREFILL_NARROWING` (`0` restores engine-sliced full
    /// prefill), `CBV2_STEP_PROFILE` (step profiler), `MLX_COMPILED_DECODE`
    /// (the documented Tahoe opt-out) and `MLX_QWEN_DIRECT_EXPERT_REDUCTION`.
    /// Defaults are unchanged: nothing here is set unless an operator does.
    /// `CBV2_STEP_PROFILE` is dumped on SIGUSR1 by `EngineStepProfileDump`.
    /// Persistence is from the INSTALLING shell: a key exported for a
    /// foreground run (`CBV2_STEP_PROFILE=1` for a step profile,
    /// `MLX_COMPILED_DECODE=0` for a Tahoe check) and still set when
    /// `darkbloom start` runs becomes the daemon's steady state until the
    /// plist is rewritten — `persistedInferenceEnvironment(from:)` reports
    /// exactly that set so both starts can say so.
    static let inferencePassthroughEnvKeys = [
        EngineV2Factory.maxPartialPrefillsKey,
        PrefillDeadlineMode.environmentKey,
        "DARKBLOOM_CBV2_MIXED_PREFILL_CAP",
        prefillNarrowingEnvKey,
        EngineStepProfileDump.environmentKey,
        "MLX_COMPILED_DECODE",
        "MLX_QWEN_DIRECT_EXPERT_REDUCTION",
    ]

    /// `DARKBLOOM_ACTIVATION_RESERVE_GB`: the documented (v0.8.0 notes),
    /// raise-only-against-the-floor activation reserve lever. Without
    /// passthrough the daemon silently kept the floor while `darkbloom
    /// doctor` (a shell process) computed model fit WITH the override — box
    /// and doctor disagreed. `DARKBLOOM_MEM_CAP_FRACTION` is deliberately
    /// NOT carried: undocumented, and any finite value > 0 is honored, so
    /// persisting it into the plist would bake a request-rejecting foot-gun
    /// into the daemon that today only affects foreground runs.
    static let passthroughEnvKeys = [
        "DARKBLOOM_PREFIX_CACHE",
        // The HuggingFace cache root (`ModelScanner.defaultCacheDirectory`):
        // forwarded so the daemon scans/downloads where the installing
        // shell's `darkbloom models download` / `huggingface-cli` put the
        // weights, instead of the CLI and its own daemon splitting across
        // two caches. Unset in the shell ⇒ not forwarded ⇒ legacy path.
        "HF_HUB_CACHE", "HF_HOME",
        "DARKBLOOM_MLX_RESOURCE_DEBUG", "DARKBLOOM_CBV2_PAGED_KV",
        "DARKBLOOM_CBV2_MTP", "DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS",
        "DARKBLOOM_KV_BACKEND_GUARD",
        "DARKBLOOM_MLX_CACHE_LIMIT_GB", "DARKBLOOM_MLX_MEMORY_RESERVE_GB",
        "DARKBLOOM_ACTIVATION_RESERVE_GB",
    ] + inferencePassthroughEnvKeys

    /// Build the daemon `EnvironmentVariables` map from a source environment,
    /// keeping only the allowlisted, non-empty keys. Pure (environment injected)
    /// so it is unit-testable without touching the real process environment.
    ///
    /// One value-conditional entry rides along: the operator drain
    /// refinement of the expert-slice route
    /// (`GemmaOptimizationEnvironment.daemonDrainPassthrough`). Serving
    /// defaults to `trust`; launchd does not inherit the installing shell, so
    /// without persisting exact `1` into the plist the background daemon
    /// would collapse a drain export back to `trust`. Config-backed `0` /
    /// `trust` remain excluded — `provider.toml` stays authoritative for
    /// whether the route runs, and `trust` is the default whenever it does.
    static func passthroughEnvironment(from environment: [String: String]) -> [String: String] {
        var out = GemmaOptimizationEnvironment.daemonDrainPassthrough(
            from: environment)
        for key in passthroughEnvKeys {
            if let value = environment[key], !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    /// The engine-read inference keys (`inferencePassthroughEnvKeys`) that
    /// `passthroughEnvironment(from:)` persists from `environment`, as
    /// `KEY=value` lines in allowlist order. Printed by `darkbloom start`
    /// (the moment of persistence) and in the daemon's startup banner (every
    /// launchd restart/recovery replays the plist), so a foreground-only
    /// export — the step profiler, the compiled-decode opt-out — that became
    /// the daemon's steady state is visible instead of silent.
    public static func persistedInferenceEnvironment(
        from environment: [String: String]
    ) -> [String] {
        inferencePassthroughEnvKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
    }

    private static func writePlist(
        binaryPath: String,
        coordinatorURL: String,
        models: [String],
        idleTimeout: UInt64?,
        configPath: URL?,
        localEndpoint: LocalEndpointOptions = LocalEndpointOptions()
    ) throws {
        let plist = plistPath()
        let parentDir = plist.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        let log = logPath().path

        let programArguments = serviceProgramArguments(
            binaryPath: binaryPath,
            coordinatorURL: coordinatorURL,
            models: models,
            idleTimeout: idleTimeout,
            configPath: configPath,
            localEndpoint: localEndpoint
        )

        let plistDict = makeServicePlist(
            label: label,
            programArguments: programArguments,
            logPath: log,
            environment: ProcessInfo.processInfo.environment
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        try data.write(to: plist, options: .atomic)
    }

    /// Build the child argv without touching launchd or the filesystem.
    /// A custom config is explicit so every relaunch reads the same TOML;
    /// the canonical default remains implicit and follows normal migration.
    static func serviceProgramArguments(
        binaryPath: String,
        coordinatorURL: String,
        models: [String],
        idleTimeout: UInt64?,
        configPath: URL?,
        localEndpoint: LocalEndpointOptions = LocalEndpointOptions()
    ) -> [String] {
        var arguments = [
            binaryPath,
            "start",
            "--foreground",
            "--coordinator-url",
            coordinatorURL,
        ]
        if let configPath {
            arguments.append(contentsOf: ["--config", configPath.standardizedFileURL.path])
        }
        for model in models {
            arguments.append(contentsOf: ["--model", model])
        }
        if let idleTimeout {
            arguments.append(contentsOf: ["--idle-timeout", "\(idleTimeout)"])
        }
        if localEndpoint.enabled {
            arguments.append("--local-endpoint")
            arguments.append(contentsOf: ["--port", "\(localEndpoint.port)"])
            arguments.append(contentsOf: ["--bind", localEndpoint.bind])
            if localEndpoint.noAuth {
                arguments.append("--no-auth")
            }
        }
        return arguments
    }

    /// Build the launchd plist dictionary for the provider service. Pure (no I/O)
    /// so the auto-start and environment-passthrough behavior is unit-testable.
    ///
    /// `RunAtLoad = true`: launchd starts the provider as soon as the GUI session
    /// loads the agent — i.e. at login, which on an auto-login box is at boot. This
    /// is what lets a rebooted/power-cycled provider come back and re-attest via
    /// APNs with no human running `darkbloom start`. (APNs registration needs the
    /// GUI/Aqua session, which a gui-domain LaunchAgent already runs in.)
    ///
    /// `KeepAlive = false` is deliberate: unconditional KeepAlive would have launchd
    /// relaunch the process the instant the graceful self-updater stops it to swap
    /// the binary, racing the stage-then-swap. Crash-recovery is instead owned by
    /// the separate `WatchdogAgent`, which waits out a grace period before
    /// relaunching (so it never races the updater) and honours `darkbloom stop`.
    /// Margin launchd's `ExitTimeOut` leaves PAST the graceful drain bound.
    /// On the stuck-request path the drain returns at the bound, then the
    /// stragglers are force-cancelled and their terminals get a flush
    /// window (`ProviderLoop.terminalFlushTimeout`, 2 s), then the goingAway
    /// frame is awaited (`CoordinatorClient.closeFrameFlushBound`, 500 ms),
    /// plus the 250 ms drain poll — so with a zero margin launchd's SIGKILL
    /// (measured at ExitTimeOut + 0.7 s) landed BEFORE the close frame in
    /// precisely the scenario the bound exists for. The rest is room for the
    /// post-close teardown. The same margin is what the daemon keeps below
    /// its job's EFFECTIVE ExitTimeOut when it clamps its drain
    /// (`ProviderLoop.shutdownDrainBound(forLaunchdExitTimeOut:)`).
    static let shutdownCloseMarginSeconds = 15

    /// launchd `ExitTimeOut` for the provider job: the graceful drain bound
    /// (`ProviderLoop.gracefulDrainTimeout`) plus the close margin, so a
    /// SIGTERM'd daemon gets its full drain AND its close frame out before
    /// SIGKILL. Written on `darkbloom start`; auto-updated installs are
    /// reconciled by `LaunchAgent+ExitTimeOut`.
    public static let exitTimeOutSeconds =
        Int(ProviderLoop.gracefulDrainTimeout.components.seconds) + shutdownCloseMarginSeconds

    static func makeServicePlist(
        label: String,
        programArguments: [String],
        logPath: String,
        environment: [String: String]
    ) -> [String: Any] {
        var plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "KeepAlive": false,
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Interactive",
            "Nice": -5,
            // launchd SIGTERMs the job on `bootout` (stop) and `kickstart -k`
            // (restart / watchdog recovery / auto-update relaunch) and SIGKILLs
            // it `ExitTimeOut` seconds later (default 20 s). The daemon traps
            // SIGTERM and drains in-flight requests for up to the graceful
            // drain bound before it closes the link and exits; the timeout
            // exceeds that bound by the close margin so launchd never cuts a
            // drain that is still inside it, nor the close frame after it.
            // Measured on macOS 26: `bootout` returns at once regardless,
            // `kickstart -k` blocks until the old process exits — so
            // `darkbloom restart` on a busy box waits for the drain.
            "ExitTimeOut": exitTimeOutSeconds,
        ]

        // launchd does NOT inherit the installing shell's environment, so any
        // opt-out the operator set (e.g. DARKBLOOM_PREFIX_CACHE=0 to disable the
        // on-by-default encrypted SSD KV cache) would be silently ignored by the
        // daemon. Persist the allowlisted passthrough vars into the plist so the
        // operator actually has a per-machine off switch.
        let environmentVariables = passthroughEnvironment(from: environment)
        if !environmentVariables.isEmpty {
            plistDict["EnvironmentVariables"] = environmentVariables
        }

        return plistDict
    }

    private static func loadService() throws {
        let path = plistPath()
        let domain = "gui/\(getuid())"

        // Clear any persistent disable left by `stop()` (launchctl disable
        // survives reboots). Without this, bootstrap fails and RunAtLoad stays
        // suppressed. Best-effort: if it fails while the service is actually
        // disabled, the bootstrap below surfaces the error.
        LaunchctlControl.setEnabled(true, label: label)

        // Bootstrap registers the service with launchd.
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", domain, path.path]

        let errPipe = Pipe()
        bootstrap.standardOutput = FileHandle.nullDevice
        bootstrap.standardError = errPipe

        try bootstrap.run()
        bootstrap.waitUntilExit()

        if bootstrap.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Error 37 = "already loaded" -- not a real failure.
            if !stderr.contains("37:") && !stderr.contains("already loaded") {
                throw LaunchAgentError.bootstrapFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // RunAtLoad=true already starts the service on bootstrap; this kickstart
        // is belt-and-suspenders (a no-op if it's already running). After a
        // successful bootstrap the service exists, so kickstart should return 0 —
        // surface a non-zero exit (or a spawn failure) rather than silently
        // reporting success when launchd never launched the process.
        let target = "gui/\(getuid())/\(label)"
        let kickstart = Process()
        kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kickstart.arguments = ["kickstart", target]
        let kickstartErr = Pipe()
        kickstart.standardOutput = FileHandle.nullDevice
        kickstart.standardError = kickstartErr

        do {
            try kickstart.run()
        } catch {
            throw LaunchAgentError.kickstartFailed("could not run launchctl kickstart: \(error.localizedDescription)")
        }
        kickstart.waitUntilExit()

        if kickstart.terminationStatus != 0 {
            let stderr = String(
                data: kickstartErr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw LaunchAgentError.kickstartFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func unloadService(label serviceLabel: String = LaunchAgent.label) throws {
        let target = "gui/\(getuid())/\(serviceLabel)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", target]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Error 3 = "could not find service" -- already unloaded, not an error.
            if !stderr.contains("3:") && !stderr.contains("could not find service") {
                throw LaunchAgentError.bootoutFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Resolve the current executable path. Falls back to ~/.darkbloom/bin/darkbloom.
    /// Shared with `WatchdogAgent` via `LaunchctlControl`.
    private static func currentExecutablePath() -> String {
        LaunchctlControl.currentExecutablePath()
    }

}

// MARK: - Errors

public enum LaunchAgentError: Error, CustomStringConvertible, Sendable {
    case bootstrapFailed(String)
    case bootoutFailed(String)
    case kickstartFailed(String)
    case disableFailed(String)
    case notInstalled
    /// The booted-out instance did not exit inside launchd's SIGKILL budget,
    /// so the new plist was not bootstrapped (it would have failed with EIO).
    case previousInstanceStillRunning(label: String, waitedSeconds: Int)

    public var description: String {
        switch self {
        case .previousInstanceStillRunning(let label, let waited):
            return "the running provider (\(label)) did not exit within \(waited)s; "
                + "check `darkbloom status`, then run `darkbloom stop` and retry"
        case .bootstrapFailed(let detail):
            return "launchctl bootstrap failed: \(detail)"
        case .bootoutFailed(let detail):
            return "launchctl bootout failed: \(detail)"
        case .kickstartFailed(let detail):
            return "launchctl kickstart failed: \(detail)"
        case .disableFailed(let detail):
            return "launchctl disable failed (the provider may auto-start again at next login): \(detail)"
        case .notInstalled:
            return "provider service is not installed; run `darkbloom start` first"
        }
    }
}
