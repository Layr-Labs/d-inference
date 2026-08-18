import Foundation
import ProviderCoreFoundation

/// Live `ProviderRuntimeServicing`: reads the provider daemon's on-disk
/// truth (`daemon-state.json`, `local.json`, launchd install state) and
/// drives lifecycle actions through the `darkbloom` CLI subprocess.
///
/// Why files instead of IPC: the daemon already atomically rewrites
/// `daemon-state.json` every heartbeat-ish tick — the same file `darkbloom
/// status`/`doctor` render — so polling it gives the app the CLI's exact
/// trust picture with zero new daemon surface. Polling is cheap (a tiny JSON
/// read every couple of seconds) and publish-on-change keeps SwiftUI quiet.
///
/// Actions invoke the CLI rather than reimplementing launchd/driver policy:
/// `stop` is idempotent, `restart` reuses the installed model selection
/// non-interactively (starting when installed-but-stopped), and a first-ever
/// start falls back to `start --all` (all local models, no picker — plain
/// `start` prompts and would wedge on stdin).
actor DaemonRuntimeService: ProviderRuntimeServicing {
    /// How a lifecycle action's wait-for-state-convergence stays honest.
    enum ActionError: Error, Equatable, LocalizedError {
        /// The CLI succeeded but the daemon didn't enter the expected state
        /// within the settle window. The poll loop keeps tracking the real
        /// file, so the UI recovers as soon as the daemon lands.
        case settleTimedOut(ProviderAction)

        var errorDescription: String? {
            switch self {
            case .settleTimedOut(let action):
                "\(action.title) was sent, but the provider did not report its new state in time. Status will catch up automatically."
            }
        }
    }

    private let stateFileURL: URL
    private let cli: any ProviderCLIRunning
    private let pollInterval: Duration
    private let cliTimeout: Duration
    private let settleTimeout: Duration
    private let providerName: String
    private let localEndpointReader: @Sendable () -> LocalEndpointInfo?
    private let processAlive: @Sendable (Int32) -> Bool
    private let selectionInstalled: @Sendable () -> Bool

    /// Snapshot computed from disk synchronously at init — lets the
    /// `@MainActor` store boot with real state before any actor hop.
    nonisolated let initialSnapshot: ProviderSnapshot

    private var published: ProviderSnapshot
    private var continuations: [UUID: AsyncStream<ProviderSnapshot>.Continuation] = [:]
    private var pollTask: Task<Void, Never>?
    /// Suppresses the poll loop while a lifecycle action is in flight —
    /// otherwise a mid-`stop` tick would adopt the not-yet-stopped on-disk
    /// state and flicker `.stopping → .online → .paused` in one second.
    /// Action-driven reads (settle, error recovery) call `refreshFromDisk`
    /// directly and are unaffected.
    private var actionInFlight = false

    init(
        stateFileURL: URL = DaemonStateFile.path(),
        cli: any ProviderCLIRunning = ProcessProviderCLIRunner(),
        pollInterval: Duration = .seconds(2),
        cliTimeout: Duration = .seconds(120),
        settleTimeout: Duration = .seconds(30),
        providerName: String = ProcessInfo.processInfo.environment["DARKBLOOM_PROVIDER_NAME"] ?? "This Mac",
        localEndpointReader: @escaping @Sendable () -> LocalEndpointInfo? = LocalEndpointDiscovery.readInfo,
        processAlive: @escaping @Sendable (Int32) -> Bool = daemonProcessAlive,
        selectionInstalled: @escaping @Sendable () -> Bool = DarkbloomServiceLabels.providerLaunchAgentInstalled
    ) {
        self.stateFileURL = stateFileURL
        self.cli = cli
        self.pollInterval = pollInterval
        self.cliTimeout = cliTimeout
        self.settleTimeout = settleTimeout
        self.providerName = providerName
        self.localEndpointReader = localEndpointReader
        self.processAlive = processAlive
        self.selectionInstalled = selectionInstalled
        let initial = Self.mapFromDisk(
            stateFileURL: stateFileURL, providerName: providerName,
            localEndpointReader: localEndpointReader, processAlive: processAlive
        )
        published = initial
        initialSnapshot = initial
    }

    func currentSnapshot() async throws -> ProviderSnapshot {
        refreshFromDisk()
        return published
    }

    func updates() async -> AsyncStream<ProviderSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ProviderSnapshot.self)
        continuations[id] = continuation
        continuation.yield(published)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        startPollingIfNeeded()
        return stream
    }

    @discardableResult
    func perform(_ action: ProviderAction) async throws -> ProviderSnapshot {
        switch action {
        case .refresh, .runDiagnostics:
            refreshFromDisk()
            return published
        case .start:
            try await lifecycleStart()
            return published
        case .stop:
            try await lifecycleStop()
            return published
        case .restart:
            try await lifecycleRestart()
            return published
        }
    }

    // MARK: - Lifecycle actions

    private func lifecycleStart() async throws {
        guard published.runState == .paused else {
            throw ProviderRuntimeServiceError.actionUnavailable(.start, state: published.runState)
        }
        let arguments = selectionInstalled() ? ["restart"] : ["start", "--all"]
        actionInFlight = true
        defer { actionInFlight = false }
        publishTransition(.starting)
        do {
            _ = try await cli.run(arguments: arguments, timeout: cliTimeout)
        } catch {
            refreshFromDisk()
            throw normalize(error)
        }
        try await settle(until: { $0.runState != .paused }, action: .start)
    }

    private func lifecycleStop() async throws {
        switch published.runState {
        case .online, .serving, .attention, .stale:
            break
        default:
            throw ProviderRuntimeServiceError.actionUnavailable(.stop, state: published.runState)
        }
        actionInFlight = true
        defer { actionInFlight = false }
        publishTransition(.stopping)
        do {
            _ = try await cli.run(arguments: ["stop"], timeout: cliTimeout)
        } catch {
            refreshFromDisk()
            throw normalize(error)
        }
        try await settle(until: { $0.runState == .paused }, action: .stop)
    }

    private func lifecycleRestart() async throws {
        guard !published.runState.isTransitioning else {
            throw ProviderRuntimeServiceError.actionUnavailable(.restart, state: published.runState)
        }
        actionInFlight = true
        defer { actionInFlight = false }
        publishTransition(.restarting)
        do {
            _ = try await cli.run(arguments: ["restart"], timeout: cliTimeout)
        } catch {
            refreshFromDisk()
            throw normalize(error)
        }
        try await settle(until: { $0.runState != .paused }, action: .restart)
    }

    /// Poll the state file until the expectation holds or the settle window
    /// lapses. A timeout surfaces as an error (the store shows a retryable
    /// failure) while the background polling keeps adopting the real state.
    private func settle(
        until expectation: @Sendable (ProviderSnapshot) -> Bool,
        action: ProviderAction
    ) async throws {
        let deadline = ContinuousClock.now + settleTimeout
        while true {
            refreshFromDisk()
            if expectation(published) { return }
            if ContinuousClock.now >= deadline {
                throw ActionError.settleTimedOut(action)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.pollTick()
            }
        }
    }

    private func pollTick() {
        guard !actionInFlight else { return }
        refreshFromDisk()
    }

    /// Re-read the truth files; publish only on a content change so the UI
    /// isn't redrawing on a 2-second heartbeat of identical state.
    ///
    /// Note `sampledAt`: the mapping sets it to the source file's write time,
    /// so `uptime`/`freshness` derive from the source and Equatable-diffing
    /// doesn't publish on every tick. The 90 s stale cutover still publishes
    /// because the mapped `runState` flips.
    private func refreshFromDisk() {
        let mapped = Self.mapFromDisk(
            stateFileURL: stateFileURL, providerName: providerName,
            localEndpointReader: localEndpointReader, processAlive: processAlive
        )
        guard mapped != published else { return }
        published = mapped
        publish()
    }

    private func publishTransition(_ runState: ProviderRunState) {
        var transition = published
        transition.sampledAt = .now
        transition.runState = runState
        published = transition
        publish()
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(published)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func normalize(_ error: Error) -> Error {
        switch error {
        case let cliError as ProviderCLIError:
            ProviderRuntimeServiceError.unavailable(cliError.localizedDescription)
        case is CancellationError:
            error
        default:
            ProviderRuntimeServiceError.unavailable(error.localizedDescription)
        }
    }

    // MARK: - Mapping entry point

    static func mapFromDisk(
        stateFileURL: URL,
        providerName: String,
        localEndpointReader: @Sendable () -> LocalEndpointInfo?,
        processAlive: @Sendable (Int32) -> Bool
    ) -> ProviderSnapshot {
        let state = DaemonStateFile.read(from: stateFileURL)
        return DaemonSnapshotMapping.map(
            DaemonSnapshotMapping.Inputs(
                state: state,
                processIsAlive: state.map { processAlive($0.pid) } ?? false,
                localEndpoint: localEndpointReader(),
                providerName: providerName
            )
        )
    }
}
