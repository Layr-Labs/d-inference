import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the provider as a background service.",
        discussion: """
        Scans local MLX models, lets you pick which to serve, then launches
        a launchd background service. Use --model to skip the interactive picker.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator WebSocket URL.")
    var coordinatorURL: String?

    @Option(help: "Model ID to serve (repeatable, skips interactive picker).")
    var model: [String] = []

    @Flag(help: "Serve all local models (skips interactive picker).")
    var all = false

    @Option(help: "Idle timeout in minutes before unloading the model.")
    var idleTimeout: UInt64?

    @Flag(inversion: .prefixedNo, help: .hidden)
    var foreground = false

    @Flag(help: "Run a local OpenAI-compatible HTTP server only; do not connect to the coordinator.")
    var local = false

    @Flag(help: "Serve a local OpenAI endpoint ALONGSIDE the coordinator (unified mode): same loaded models serve both the public fleet and local clients.")
    var localEndpoint = false

    @Option(help: "Local server port (used with --local / --local-endpoint).")
    var port: UInt16 = 8000

    @Option(help: "Bind address for --local / --local-endpoint (default 127.0.0.1; a tailnet IP exposes it to same-account devices, still API-key gated).")
    var bind: String = "127.0.0.1"

    @Flag(help: "Disable local API-key auth for --local / --local-endpoint (NOT recommended; trusted/airgapped use only).")
    var noAuth = false

    /// Public URL of the Darkbloom Terms of Service.
    static let termsURL = "https://darkbloom.dev/terms.html"

    /// Prints a one-line terms-of-service notice. Starting the provider is the
    /// act of acceptance — there is no separate yes/no prompt — so this is an
    /// informational notice, not a gate. Shown only for the user-facing
    /// invocation; the launchd-relaunched `--foreground` child skips it since
    /// the user already saw it when they ran `darkbloom start`.
    private func printTermsNotice() {
        print("By starting the provider, you agree to the Darkbloom Terms of Service:")
        print("  \(Start.termsURL)")
        print()
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        if !foreground {
            printTermsNotice()
        }

        // --local (coordinator-less) and --local-endpoint (alongside the
        // coordinator) are mutually exclusive serve modes; reject the ambiguous
        // combination rather than silently picking one.
        if local && localEndpoint {
            printError("--local and --local-endpoint are mutually exclusive: use --local for a coordinator-less local server, or --local-endpoint to serve a local endpoint alongside the coordinator.")
            throw ExitCode.failure
        }

        // GPU is required. Reject CPU fallback up-front so we never
        // come up reporting healthy and then silently churn at 0.5 tok/s.
        do {
            _ = try GPUEnforcement.requireMetal()
        } catch {
            printError("\(error)")
            throw ExitCode.failure
        }

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let effectiveCoordinator = coordinatorURL ?? snapshot.config.coordinator.url
        var effectiveConfig = snapshot.config
        if let idleTimeout {
            effectiveConfig.backend.idleTimeoutMins = idleTimeout
        }

        guard let hardware = snapshot.hardware else {
            printError("Cannot start: hardware detection failed (\(snapshot.hardwareError?.localizedDescription ?? "unknown"))")
            throw ExitCode.failure
        }

        if local {
            try await runLocalStandalone(
                snapshot: snapshot,
                config: effectiveConfig,
                hardware: hardware
            )
        } else if foreground {
            try await runForeground(
                snapshot: snapshot,
                hardware: hardware,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator
            )
        } else {
            try await launchDaemon(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator
            )
        }
    }

    // MARK: - Standalone (--local)

    private func runLocalStandalone(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        hardware: HardwareInfo
    ) async throws {
        let advertised = advertisedModels(
            from: snapshot.models,
            config: config,
            modelOverrides: model,
            includeDisabled: all
        )

        // Direct/local mode: mint (or reuse) a bearer token so the loopback
        // server isn't open to every local process / hostile webpage. --no-auth
        // opts out for trusted/airgapped use.
        let token: String?
        if noAuth {
            token = nil
        } else {
            token = try LocalEndpoint.loadOrCreateToken()
        }

        let baseURL = "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1"
        print("darkbloom \(ProviderCore.version) (local / direct mode)")
        print("Listening on \(bind):\(port)")
        print("Models: \(advertised.count)")
        for m in advertised {
            print("  \(m.id) (\(String(format: "%.1f", m.estimatedMemoryGb)) GB)")
        }
        print()
        print("OpenAI-compatible endpoint:")
        print("  base URL: \(baseURL)")
        if let token {
            print("  API key:  \(token)")
            print()
            print("  export OPENAI_BASE_URL=\(baseURL)")
            print("  export OPENAI_API_KEY=\(token)")
        } else {
            print("  API key:  (auth disabled — --no-auth)")
        }
        print()
        print("  Shareable any time with: darkbloom local")
        print()

        // Standalone mode still benefits from the PID lock + sleep prevention.
        try ProcessLifecycle.acquireSingleInstanceLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        let server = StandaloneServer(
            config: StandaloneServerConfig(
                port: port,
                host: bind,
                maxCachedModels: Int(clamping: config.backend.maxModelSlots),
                authToken: token
            ),
            models: advertised
        )
        try await server.start()

        // Wait until the server CONFIRMS it bound the port before advertising it.
        // start() launches Hummingbird in a child task and returns before the
        // bind completes; we must not write a discovery record pointing at a dead
        // (or, worse, a foreign) endpoint that `darkbloom local` / local-first
        // clients would then trust. waitUntilBound reads the actor's own bind
        // signal (Hummingbird onServerRunning), not an HTTP probe a process
        // already holding the port could answer.
        guard await server.waitUntilBound(timeoutSeconds: 5.0) else {
            await server.stop()
            printError("Local server failed to bind \(bind):\(port) within 5s — is the port already in use?")
            throw ExitCode.failure
        }

        // Publish discovery metadata so a same-machine client (and
        // `darkbloom local`) can find + authenticate to this server. Removed on
        // exit; the token file persists so the token survives restarts.
        let info = LocalEndpoint.Info(
            host: bind,
            port: port,
            apiKey: token ?? "",
            version: ProviderCore.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try? LocalEndpoint.writeInfo(info)
        defer { LocalEndpoint.removeInfo() }

        // Wait forever (until SIGINT). In standalone mode we don't have a
        // coordinator event stream to drive the loop, so we just block.
        let waitForever = AsyncStream<Never> { _ in }
        for await _ in waitForever {}
    }


    // MARK: - Foreground (invoked by launchd)

    private func runForeground(
        snapshot: RuntimeSnapshot,
        hardware: HardwareInfo,
        config: ProviderConfig,
        coordinatorURL: String
    ) async throws {
        let selectedModels: [ModelInfo]
        if !model.isEmpty {
            selectedModels = advertisedModels(from: snapshot.models, config: config, modelOverrides: model)
        } else if all {
            selectedModels = snapshot.models
        } else {
            selectedModels = advertisedModels(from: snapshot.models, config: config)
        }

        guard !selectedModels.isEmpty else {
            printError("No models selected.")
            throw ExitCode.failure
        }

        let (models, modelHashes, modelHashFingerprints) = attachWeightHashes(to: selectedModels)
        let runtimeHashes = (try? RuntimeHashReporter().report().coordinatorRuntimeHashes)
        let authToken = AuthTokenStore.load()

        if config.provider.autoUpdate {
            try await runStartupAutoUpdate(coordinatorURL: coordinatorURL)
        }

        // ----- Process-level lifecycle: PID lock + caffeinate. -----
        try ProcessLifecycle.acquireSingleInstanceLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        // Install panic hook BEFORE telemetry so a crash during telemetry
        // setup is itself captured.
        PanicHook.install()

        // Arm crash recovery for the running daemon however it was launched
        // (manual start, login, or auto-update relaunch). Idempotent (skip when
        // already loaded → no churn on restarts) + best-effort.
        if config.provider.autoRestart, !WatchdogAgent.isLoaded() {
            try? WatchdogAgent.installAndStart()
        }

        // ----- Telemetry: configure now so reconnect/inference/panic events flow. -----
        TelemetryClient.shared.configure(TelemetryClientConfig(
            coordinatorURL: coordinatorURL,
            source: .provider,
            authToken: authToken,
            version: ProviderCore.version,
            machineId: macHardwareSerialNumber() ?? ""
        ))

        TelemetryClient.shared.emit(
            kind: .log,
            severity: .info,
            message: "provider starting",
            fields: [
                "backend": .string("mlx-swift"),
                "models": .int(models.count),
            ]
        )

        let schedule: Schedule? = config.schedule.flatMap { Schedule.from(config: $0) }

        print("darkbloom \(ProviderCore.version)")
        print("Backend: mlx-swift")
        print("Config: \(describeConfigPath(snapshot))")
        print("Coordinator: \(coordinatorURL)")
        if let schedule {
            print("Schedule: \(schedule.describe())")
        } else {
            print("Schedule: always available")
        }
        print("Advertised models: \(models.count)")
        for m in models {
            print("  \(m.id) (\(String(format: "%.1f", m.estimatedMemoryGb)) GB)")
        }

        // Unified mode: build the local-endpoint config when --local-endpoint is
        // set. Reuses the same persistent bearer token + bind/port options as
        // --local; --no-auth opts out of the token (trusted/airgapped only).
        var localEndpointConfig: LocalInferenceHTTPConfig?
        if localEndpoint {
            // FAIL CLOSED: if auth is requested (no --no-auth) but the token
            // can't be created/read, abort rather than silently opening the
            // endpoint unauthenticated — otherwise an unwritable ~/.darkbloom
            // would expose it (especially under --bind 0.0.0.0). Mirrors --local.
            let token: String?
            if noAuth {
                token = nil
            } else {
                do {
                    token = try LocalEndpoint.loadOrCreateToken()
                } catch {
                    printError("Cannot start --local-endpoint: failed to create the local API token (\(error)). Fix ~/.darkbloom permissions, or pass --no-auth for a trusted/airgapped setup.")
                    throw ExitCode.failure
                }
            }
            localEndpointConfig = LocalInferenceHTTPConfig(host: bind, port: port, authToken: token)
            let shownURL = "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1"
            print("Local endpoint: \(shownURL)\(token != nil ? "  (API key from `darkbloom local`)" : "  (auth disabled)")")
        }

        let loopConfig = ProviderLoopConfig(
            coordinatorURL: coordinatorURL,
            hardware: hardware,
            models: models,
            config: config,
            authToken: authToken,
            runtimeHashes: runtimeHashes,
            modelHashes: modelHashes,
            modelHashFingerprints: modelHashFingerprints,
            localEndpoint: localEndpointConfig
        )

        do {
            if let schedule {
                try await runScheduled(loopConfig: loopConfig, schedule: schedule)
            } else {
                let loop = try ProviderLoop(config: loopConfig)
                try await loop.run()
            }
        } catch {
            TelemetryClient.shared.emit(
                kind: .log,
                severity: .error,
                message: "provider loop terminated: \(error.localizedDescription)"
            )
            throw error
        }

        await TelemetryClient.shared.shutdown()
    }

    private func runStartupAutoUpdate(coordinatorURL: String) async throws {
        if ProcessInfo.processInfo.environment["DARKBLOOM_NO_UPDATE_CHECK"] != nil {
            return
        }
        print("Checking for provider update...")
        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)
        switch await updater.update() {
        case .alreadyUpToDate:
            return
        case .updated(let from, let to):
            print("Updated provider: v\(from) -> v\(to). Restarting into new binary...")
            try ProcessLifecycle.execCurrentProcess()
        case .downloadFailed(let reason):
            printError("auto-update skipped: \(reason)")
        case .hashMismatch(let expected, let got):
            printError("auto-update skipped: bundle hash mismatch (expected \(expected), got \(got))")
        case .replaceFailed(let reason):
            printError("auto-update skipped: \(reason)")
        }
    }

    private enum ScheduledLoopResult {
        case loopEnded
        case windowClosed
    }

    private func runScheduled(
        loopConfig: ProviderLoopConfig,
        schedule: Schedule
    ) async throws {
        while !Task.isCancelled {
            if !schedule.isActiveNow() {
                let wait = schedule.durationUntilNextActive()
                print("Outside availability schedule; next window opens in \(formatDuration(wait)).")
                try await Task.sleep(nanoseconds: sleepNanoseconds(for: wait))
                continue
            }

            let activeFor = schedule.durationUntilInactive() ?? 3600
            print("Availability window active for \(formatDuration(activeFor)).")

            let loop = try ProviderLoop(config: loopConfig)
            try await withThrowingTaskGroup(of: ScheduledLoopResult.self) { group in
                group.addTask {
                    try await loop.run()
                    return .loopEnded
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: sleepNanoseconds(for: activeFor))
                    return .windowClosed
                }

                guard let result = try await group.next() else { return }
                group.cancelAll()

                switch result {
                case .loopEnded:
                    return
                case .windowClosed:
                    print("Availability window closed; disconnecting until the next scheduled window.")
                    return
                }
            }
        }
    }

    private func sleepNanoseconds(for interval: TimeInterval) -> UInt64 {
        let seconds = max(1.0, min(interval, Double(UInt64.max) / 1_000_000_000))
        return UInt64(seconds * 1_000_000_000)
    }

    // MARK: - Preflight Checks

    /// Runs critical doctor checks inline before the model picker so users
    /// don't discover problems *after* downloading GBs of weights.
    private func runPreflightChecks(snapshot: RuntimeSnapshot) throws {
        let sipEnabled = checkSIPEnabled()
        if !sipEnabled {
            printError("System Integrity Protection (SIP) is disabled.")
            printError("The coordinator will reject this provider. Re-enable SIP and restart.")
            throw ExitCode.failure
        }

        let debuggerAttached = checkDebuggerAttached()
        if debuggerAttached {
            printError("A debugger is attached. The coordinator will reject this provider.")
            throw ExitCode.failure
        }

        guard let hardware = snapshot.hardware else { return }
        if hardware.memoryGb < 8 {
            printError("This Mac has \(hardware.memoryGb) GB RAM. At least 8 GB is needed to serve any model.")
            throw ExitCode.failure
        }
    }

    /// Offers to link the machine to a Darkbloom account if not already logged
    /// in. Skipped in non-interactive (piped) contexts and when the user
    /// declines. This runs *before* the model picker so the auth token is
    /// available by the time the daemon starts.
    private func offerInlineLogin(coordinatorURL: String) async {
        // Already logged in — nothing to do.
        guard AuthTokenStore.load() == nil else { return }

        // Can't prompt if stdin isn't a terminal.
        guard isatty(STDIN_FILENO) != 0 else { return }

        print()
        print("  Your provider is not linked to an account.")
        print("  Link now to receive earnings for serving inference.")
        print()
        print("  Link account? [Y/n] ", terminator: "")
        fflush(stdout)

        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces) else { return }
        let declined = ["n", "no"].contains(answer.lowercased())
        if declined {
            print("  Skipped. You can link later with: darkbloom login")
            return
        }

        do {
            try await performDeviceCodeLogin(
                coordinatorURL: coordinatorURL,
                onDisplayCode: { userCode, verificationURI, expiresIn in
                    print()
                    print("  Open this URL in your browser:")
                    print()
                    print("    \(verificationURI)")
                    print()
                    print("  Then enter this code:")
                    print()
                    print("    \(userCode)")
                    print()
                    print("  Waiting for approval (expires in \(expiresIn / 60) minutes)...")
                },
                onPollTick: {
                    print(".", terminator: "")
                    fflush(stdout)
                }
            )
            print()
            print("  Account linked successfully!")
            print()
        } catch {
            print()
            print("  Could not link account: \(error)")
            print("  Continuing without account link. Run `darkbloom login` later.")
            print()
        }
    }

    // MARK: - Daemon (interactive picker → launchd)

    private mutating func launchDaemon(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        coordinatorURL: String
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
            localEndpoint: LaunchAgent.LocalEndpointOptions(
                enabled: localEndpoint, port: port, bind: bind, noAuth: noAuth
            )
        )

        // Arm the crash-recovery watchdog (relaunches ~5 min after a crash;
        // `stop` disarms, `auto_restart = false` opts out). Best-effort.
        let autoRestartOn = config.provider.autoRestart
        if autoRestartOn {
            do {
                try WatchdogAgent.installAndStart()
            } catch {
                printError("note: could not install crash-recovery watchdog: \(error)")
            }
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

    // MARK: - Interactive Catalog Picker

    /// Entry shown in the interactive TUI model picker.
    ///
    /// `downloaded` is computed from an UNFILTERED on-disk check (not the
    /// available-memory-filtered scan) so a fully-downloaded model that exceeds
    /// available RAM still reads "downloaded (won't fit)" rather than "not
    /// downloaded". `resumable` flags a build whose foreground download was
    /// interrupted (staging on disk) so the picker can show "resuming".
    struct PickerEntry: Equatable {
        let id: String
        let catalogModel: CatalogModel
        let displayName: String
        let sizeGb: Double
        let minRamGb: Int?
        let downloaded: Bool
        var resumable: Bool = false
    }

    struct PickerCatalogRow {
        let model: CatalogModel
        let displayName: String
    }

    /// Build picker entries from catalog rows and on-disk state. Pure (no IO) so
    /// the downloaded / won't-fit / resuming classification is unit-testable.
    ///
    /// - `downloadedIDs` MUST come from an UNFILTERED on-disk scan so a
    ///   present-but-too-big model still reads "downloaded".
    /// - `localMemoryByID` carries the on-disk estimated memory for sizing
    ///   downloaded rows (falls back to the catalog `size_gb` when absent).
    /// - `resumableIDs` are builds with interrupted-download staging on disk.
    /// - A not-yet-downloaded model whose declared `min_ram_gb` exceeds this box
    ///   is hidden; a downloaded one is always shown (with a won't-fit note in
    ///   the renderer).
    static func buildPickerEntries(
        rows: [PickerCatalogRow],
        downloadedIDs: Set<String>,
        localMemoryByID: [String: Double],
        resumableIDs: Set<String>,
        memoryGb: Double
    ) -> [PickerEntry] {
        var entries: [PickerEntry] = rows.compactMap { row in
            let model = row.model
            let isDownloaded = downloadedIDs.contains(model.id)
            if !isDownloaded, let minRam = model.minRamGb, Double(minRam) > memoryGb {
                return nil
            }
            let size = isDownloaded ? (localMemoryByID[model.id] ?? model.sizeGb) : model.sizeGb
            return PickerEntry(
                id: model.id,
                catalogModel: model,
                displayName: row.displayName,
                sizeGb: size,
                minRamGb: model.minRamGb,
                downloaded: isDownloaded,
                resumable: !isDownloaded && resumableIDs.contains(model.id)
            )
        }
        // Downloaded first, then larger first.
        entries.sort { a, b in
            if a.downloaded != b.downloaded { return a.downloaded }
            return a.sizeGb > b.sizeGb
        }
        return entries
    }

    /// Memory held back for the OS before the per-model serving budget. Shared by
    /// the interactive TUI picker and the non-TTY fallback so both agree on what
    /// "fits".
    static let pickerOSReserveGb = 4.0

    /// Whether a single model of `sizeGb` can be served on a box with `memoryGb`
    /// RAM. One model is warm at a time, so this is an individual-fit check with
    /// the OS reserve held back.
    static func modelFitsBudget(sizeGb: Double, memoryGb: Double) -> Bool {
        sizeGb <= memoryGb - pickerOSReserveGb
    }

    /// Outcome of resolving a non-TTY fallback-picker input line.
    enum FallbackSelection: Equatable {
        case cancelled
        case selected([String])
        case rejected(String)
    }

    /// Resolve a fallback-picker input ("all" or comma-separated 1-based indices)
    /// into model IDs, rejecting any pick that can't fit in RAM — the non-TTY
    /// equivalent of the TUI refusing to toggle a won't-fit row. Pure + testable.
    /// Without this guard a scripted/piped `darkbloom start` could select a model
    /// that is on disk but too large for this box and always OOMs on load.
    static func resolveFallbackSelection(
        input rawInput: String,
        entries: [PickerEntry],
        memoryGb: Double
    ) -> FallbackSelection {
        let input = rawInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return .cancelled }
        let budget = memoryGb - pickerOSReserveGb
        func fits(_ e: PickerEntry) -> Bool { modelFitsBudget(sizeGb: e.sizeGb, memoryGb: memoryGb) }

        if input.lowercased() == "all" {
            let fitting = entries.filter(fits)
            guard !fitting.isEmpty else {
                return .rejected(
                    "No model fits in \(Int(memoryGb)) GB RAM (need ≤ \(String(format: "%.1f", budget)) GB per model).")
            }
            return .selected(fitting.map(\.id))
        }

        var picked: [PickerEntry] = []
        for token in input.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard let n = Int(t) else {
                return .rejected("Invalid selection: '\(t)' is not a number.")
            }
            guard n >= 1, n <= entries.count else {
                return .rejected("Invalid selection: \(n) (must be 1-\(entries.count)).")
            }
            let entry = entries[n - 1]
            guard fits(entry) else {
                return .rejected(
                    "\(entry.displayName) (\(String(format: "%.1f", entry.sizeGb)) GB) needs more memory than this Mac has "
                        + "(\(Int(memoryGb)) GB RAM, ~\(String(format: "%.1f", budget)) GB usable). Choose a smaller model.")
            }
            picked.append(entry)
        }
        return .selected(picked.map(\.id))
    }

    private static let gemmaPublicID = "gemma-4-26b"
    private static let gemmaQATID = "gemma-4-26b-qat-4bit"
    private static let gemmaRollbackID = "gemma-4-26b-8bit"

    private func pickerCatalogRows(models: [CatalogModel], aliases: [CatalogAlias]) -> [PickerCatalogRow] {
        if aliases.isEmpty {
            let gemmaQATAvailable = models.contains { $0.id == Self.gemmaQATID }
            return models.compactMap { model in
                if shouldHideGemmaRolloutModel(model, qatAvailable: gemmaQATAvailable) || isHiddenPickerModel(model) {
                    return nil
                }
                return PickerCatalogRow(model: model, displayName: gemmaRolloutDisplayName(for: model) ?? model.displayName)
            }
        }

        var hiddenBuilds = Set<String>()
        var aliasDisplayByBuild: [String: String] = [:]
        for alias in aliases {
            hiddenBuilds.insert(alias.desiredBuild)
            if let previous = alias.previousBuild { hiddenBuilds.insert(previous) }
            for retired in alias.retiredBuilds ?? [] { hiddenBuilds.insert(retired) }

            let primary = alias.primaryBuild ?? alias.desiredBuild
            aliasDisplayByBuild[primary] = alias.displayName
        }

        return models.compactMap { model in
            if let displayName = aliasDisplayByBuild[model.id] {
                return PickerCatalogRow(model: model, displayName: displayName)
            }
            if hiddenBuilds.contains(model.id) || isHiddenPickerModel(model) {
                return nil
            }
            return PickerCatalogRow(model: model, displayName: model.displayName)
        }
    }

    private func isHiddenPickerModel(_ model: CatalogModel) -> Bool {
        if let metadata = model.metadata {
            if metadata["hidden_from_picker"] == .bool(true) { return true }
            if metadata["hide_standalone"] == .bool(true) { return true }
        }
        return model.displayName.localizedCaseInsensitiveContains("rollback")
    }

    private func gemmaRolloutDisplayName(for model: CatalogModel) -> String? {
        // Temporary Gemma 4 rollout shim. Remove after the coordinator alias
        // catalog contract is deployed and the picker consumes alias metadata.
        model.id == Self.gemmaQATID ? "Gemma 4 26B" : nil
    }

    private func shouldHideGemmaRolloutModel(_ model: CatalogModel, qatAvailable: Bool) -> Bool {
        guard qatAvailable else { return model.id == Self.gemmaRollbackID }
        return model.id == Self.gemmaPublicID || model.id == Self.gemmaRollbackID
    }

    /// Fetches the model catalog from the coordinator, shows an interactive
    /// terminal picker, downloads any missing models, and returns the
    /// selected model IDs.
    private func interactiveCatalogPicker(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        coordinatorURL: String
    ) async throws -> [String] {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)

        let catalogSnapshot: CatalogSnapshot
        do {
            catalogSnapshot = try await client.fetchCatalogSnapshot(typeFilter: "text", includeAliases: true)
        } catch {
            printError("Could not fetch model catalog from coordinator: \(error)")
            printError("hint: check your coordinator URL or use --model to specify models directly")
            throw ExitCode.failure
        }

        let catalog = pickerCatalogRows(models: catalogSnapshot.models, aliases: catalogSnapshot.aliases)

        guard !catalog.isEmpty else {
            printError("No models in the coordinator catalog.")
            throw ExitCode.failure
        }

        let memoryGb: Double = Double(snapshot.hardware?.memoryGb ?? 16)

        // "Downloaded" must be computed from an UNFILTERED on-disk scan: the
        // memory-filtered `snapshot.models` drops models too large for available
        // RAM, which would make a fully-downloaded-but-too-big model read "not
        // downloaded" forever on a marginal-RAM box. The filtered scan is only
        // used (via the renderer's budget check) to flag "won't fit".
        let allLocal = snapshot.hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
        let downloadedIDs = Set(allLocal.map(\.id))
        let localMemoryByID = Dictionary(allLocal.map { ($0.id, $0.estimatedMemoryGb) }, uniquingKeysWith: { first, _ in first })
        // Builds with an interrupted foreground download staged on disk: show
        // "resuming" so re-selecting finishes rather than restarts.
        let resumableIDs = Set(catalog.compactMap { row -> String? in
            guard !downloadedIDs.contains(row.model.id), let prefix = row.model.r2Prefix else { return nil }
            return ModelDownloader.hasResumableStaging(modelID: row.model.id, r2Prefix: prefix) ? row.model.id : nil
        })

        let entries = Start.buildPickerEntries(
            rows: catalog,
            downloadedIDs: downloadedIDs,
            localMemoryByID: localMemoryByID,
            resumableIDs: resumableIDs,
            memoryGb: memoryGb
        )

        guard !entries.isEmpty else {
            printError("No supported models fit in \(Int(memoryGb)) GB RAM.")
            throw ExitCode.failure
        }

        // Fall back to simple numbered picker if stdin is not a TTY.
        guard isatty(STDIN_FILENO) != 0 else {
            return try await fallbackPicker(entries: entries, memoryGb: memoryGb, client: client)
        }

        // Run the interactive TUI picker.
        let selectedIndices = try runModelPicker(entries: entries, memoryGb: memoryGb)

        guard !selectedIndices.isEmpty else {
            return []
        }

        // Download any selected models that aren't local yet.
        let missing = selectedIndices
            .map { entries[$0] }
            .filter { !$0.downloaded }

        if !missing.isEmpty {
            print()
            let downloader = ModelDownloader(catalogClient: client)
            for entry in missing {
                print("  Downloading \(entry.displayName) (\(String(format: "%.1f GB", entry.sizeGb)))...")
                do {
                    try await downloader.download(model: entry.catalogModel) { progress in
                        let pct: String
                        if let total = progress.bytesTotal, total > 0 {
                            pct = String(format: " %.0f%%", Double(progress.bytesDownloaded) / Double(total) * 100)
                        } else {
                            pct = ""
                        }
                        let mb = Double(progress.bytesDownloaded) / 1_048_576
                        print("    \(progress.file)  \(String(format: "%.1f MB", mb))\(pct)")
                    }
                    print("  \u{2713} Downloaded \(entry.displayName)")
                } catch {
                    printError("Failed to download \(entry.displayName): \(error)")
                    printError("hint: download manually with `darkbloom models download \(entry.id)`")
                    throw ExitCode.failure
                }
            }
            print()
        }

        return selectedIndices.map { entries[$0].id }
    }

    /// Simple numbered fallback picker for non-TTY environments.
    private func fallbackPicker(
        entries: [PickerEntry],
        memoryGb: Double,
        client: ModelCatalogClient
    ) async throws -> [String] {
        print()
        print("  Models (from coordinator catalog):")
        print()
        for (i, entry) in entries.enumerated() {
            let status: String
            if entry.downloaded {
                status = "downloaded"
            } else if entry.resumable {
                status = "resuming"
            } else {
                status = "not downloaded"
            }
            let sizeStr = String(format: "%.1f GB", entry.sizeGb)
            let ramStr = entry.minRamGb.map { " (>= \($0) GB RAM)" } ?? ""
            // Parity with the TUI: a downloaded-but-too-big model is shown but
            // flagged so a non-interactive caller knows it can't be served here.
            let fitStr = Start.modelFitsBudget(sizeGb: entry.sizeGb, memoryGb: memoryGb) ? "" : "  [won't fit]"
            print("    [\(i + 1)] \(entry.displayName)  \(sizeStr)\(ramStr)  [\(status)]\(fitStr)")
        }
        print()
        print("  Select models (comma-separated numbers, or 'all'): ", terminator: "")

        let selected: [PickerEntry]
        switch Start.resolveFallbackSelection(input: readLine() ?? "", entries: entries, memoryGb: memoryGb) {
        case .cancelled:
            return []
        case .rejected(let message):
            printError(message)
            printError("hint: pick a model that fits, or run on a Mac with more RAM")
            throw ExitCode.failure
        case .selected(let ids):
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            selected = ids.compactMap { byID[$0] }
        }

        let localIDs = Set(entries.filter(\.downloaded).map(\.id))
        let missing = selected.filter { !localIDs.contains($0.id) }
        if !missing.isEmpty {
            print()
            print("  Downloading \(missing.count) model(s)...")
            print()
            let downloader = ModelDownloader(catalogClient: client)
            for entry in missing {
                print("  Downloading \(entry.displayName) (\(String(format: "%.1f GB", entry.sizeGb)))...")
                do {
                    try await downloader.download(model: entry.catalogModel) { progress in
                        let mb = Double(progress.bytesDownloaded) / 1_048_576
                        print("    \(progress.file)  \(String(format: "%.1f MB", mb))")
                    }
                    print("  \(entry.displayName) downloaded.")
                } catch {
                    printError("Failed to download \(entry.displayName): \(error)")
                    printError("hint: download manually with `darkbloom models download \(entry.id)`")
                    throw ExitCode.failure
                }
            }
            print()
        }

        return selected.map(\.id)
    }

    // MARK: - TUI Model Picker

    /// Interactive multi-select model picker using raw terminal mode.
    /// Arrow keys navigate, Space toggles selection, Enter confirms, Esc/q cancels.
    /// Enforces memory budget and shows two sections: downloaded and available.
    private func runModelPicker(entries: [PickerEntry], memoryGb: Double) throws -> [Int] {
        let budget = memoryGb - Start.pickerOSReserveGb

        var cursorPos = 0
        var selected = [Bool](repeating: false, count: entries.count)

        let downloadedCount = entries.filter(\.downloaded).count
        let availableCount = entries.count - downloadedCount

        // Enable raw terminal mode.
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN = 1 byte minimum
        raw.c_cc.17 = 0  // VTIME = no timeout
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Ensure terminal is restored on any exit path.
        defer {
            // Show cursor, restore terminal.
            write(STDOUT_FILENO, "\u{1B}[?25h", 6)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldTermios)
        }

        // Hide cursor.
        write(STDOUT_FILENO, "\u{1B}[?25l", 6)

        var lastLineCount: Int = 0

        let ansiReset = "\u{1B}[0m"
        let ansiDim = "\u{1B}[2m"
        let ansiYellow = "\u{1B}[33m"

        func formattedGB(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        func canFitIndividually(_ entry: PickerEntry) -> Bool {
            Start.modelFitsBudget(sizeGb: entry.sizeGb, memoryGb: memoryGb)
        }

        // Pre-select the largest downloaded model that can fit on this machine.
        if let idx = entries.firstIndex(where: { $0.downloaded && canFitIndividually($0) }) {
            selected[idx] = true
        }

        /// Render the picker UI, returning the number of lines written.
        func render(pos: Int, sel: [Bool], prevLines: Int) -> Int {
            var output = ""

            // Move cursor up to overwrite previous render.
            if prevLines > 0 {
                output += "\u{1B}[\(prevLines)A"
            }
            // Carriage return + clear to end of screen.
            output += "\r\u{1B}[J"

            let used: Double = entries.enumerated()
                .filter { sel[$0.offset] }
                .map(\.element.sizeGb)
                .reduce(0, +)
            let count = sel.filter { $0 }.count
            let fitsSimultaneously = used <= budget

            var lines = 0

            output += "  Select models (RAM: \(Int(memoryGb)) GB)  \u{2191}\u{2193} navigate \u{00B7} Space toggle \u{00B7} Enter confirm\r\n"
            lines += 1

            if fitsSimultaneously {
                output += "  \(ansiDim)\(count) selected \u{00B7} \(formattedGB(used)) GB total \u{00B7} all models can be served simultaneously\(ansiReset)\r\n\r\n"
            } else {
                output += "  \(ansiDim)\(count) selected \u{00B7} \(formattedGB(used)) GB on disk \u{00B7} \(ansiReset)\(ansiYellow)one model active at a time (swap on demand)\(ansiReset)\r\n\r\n"
            }
            lines += 2

            var idx = 0

            // Section 1: Downloaded models.
            if downloadedCount > 0 {
                output += "  \u{1B}[1mReady to serve:\u{1B}[0m\r\n"
                lines += 1
                for entry in entries where entry.downloaded {
                    let arrow = idx == pos ? "\u{25B8}" : " "
                    let check = sel[idx] ? "\u{2713}" : " "
                    let highlight = idx == pos ? "\u{1B}[36m" : ""
                    let reset = highlight.isEmpty ? "" : "\u{1B}[0m"
                    // A downloaded model that exceeds this box's budget is shown
                    // (it IS on disk) but flagged "won't fit" — never hidden.
                    let warn = canFitIndividually(entry) ? "" : " \u{26A0} won't fit"
                    output += "    \(highlight)\(arrow) [\(check)] \(entry.displayName) (\(formattedGB(entry.sizeGb)) GB)\(warn)\(reset)\r\n"
                    lines += 1
                    idx += 1
                }
            }

            // Section 2: Not-downloaded models.
            if availableCount > 0 {
                if downloadedCount > 0 {
                    output += "\r\n"
                    lines += 1
                }
                output += "  \u{1B}[1mAvailable to download:\u{1B}[0m\r\n"
                lines += 1
                for entry in entries where !entry.downloaded {
                    let arrow = idx == pos ? "\u{25B8}" : " "
                    let check = sel[idx] ? "\u{2713}" : " "
                    let tooLargeForMachine = !canFitIndividually(entry)
                    let highlight: String
                    if idx == pos {
                        highlight = "\u{1B}[33m"
                    } else if tooLargeForMachine {
                        highlight = "\u{1B}[2;31m"
                    } else {
                        highlight = "\u{1B}[2m"
                    }
                    let note: String
                    if entry.resumable {
                        note = tooLargeForMachine ? " \u{21BB} resuming \u{00B7} \u{26A0} exceeds RAM" : " \u{21BB} resuming"
                    } else {
                        note = tooLargeForMachine ? " \u{26A0} exceeds RAM" : ""
                    }
                    output += "    \(highlight)\(arrow) [\(check)] \u{2193} \(entry.displayName) (\(formattedGB(entry.sizeGb)) GB)\(note)\u{1B}[0m\r\n"
                    lines += 1
                    idx += 1
                }
            }

            // Write the full frame in one syscall.
            output.withCString { ptr in
                _ = write(STDOUT_FILENO, ptr, strlen(ptr))
            }

            return lines
        }

        // Initial render.
        lastLineCount = render(pos: cursorPos, sel: selected, prevLines: 0)

        // Input loop.
        var buf = [UInt8](repeating: 0, count: 3)
        while true {
            let n = read(STDIN_FILENO, &buf, 3)
            guard n > 0 else { continue }

            if n == 1 {
                switch buf[0] {
                case 0x1B:
                    // Bare Escape — cancel.
                    print()
                    return []
                case 0x71: // 'q'
                    print()
                    return []
                case 0x20: // Space — toggle selection.
                    if selected[cursorPos] {
                        selected[cursorPos] = false
                    } else {
                        // Allow selection if the model individually fits in memory.
                        // Multiple models can be selected even if their total exceeds
                        // available RAM — only one will be warm (loaded) at a time;
                        // the coordinator manages model swaps on demand.
                        if canFitIndividually(entries[cursorPos]) {
                            selected[cursorPos] = true
                        }
                    }
                case 0x0A, 0x0D: // Enter — confirm.
                    if selected.contains(true) {
                        print()
                        return selected.enumerated()
                            .filter(\.element)
                            .map(\.offset)
                    }
                    // Don't allow confirm with nothing selected.
                default:
                    break
                }
            } else if n == 3, buf[0] == 0x1B, buf[1] == 0x5B {
                // Arrow key escape sequence: ESC [ A/B/C/D
                switch buf[2] {
                case 0x41: // Up
                    if cursorPos > 0 { cursorPos -= 1 }
                case 0x42: // Down
                    if cursorPos < entries.count - 1 { cursorPos += 1 }
                default:
                    break
                }
            }

            lastLineCount = render(pos: cursorPos, sel: selected, prevLines: lastLineCount)
        }
    }
}
