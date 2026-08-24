import Foundation
import Observation
import ProviderCoreFoundation

@MainActor
@Observable
final class LocalAPIStore {
    private(set) var state: LocalAPIState
    private(set) var isAPIKeyRevealed = false
    private(set) var lastCopiedItem: LocalAPICopyItem?
    var selectedExample: LocalAPICodeExample = .curl

    /// Where this store's truth comes from. Fixture mode replays
    /// deterministic preview states; live mode reads the real discovery
    /// file and probes the real endpoint.
    private enum Source {
        case fixture
        case live(LiveSource)
    }

    private struct LiveSource {
        let discoveryReader: @Sendable () -> LocalEndpointInfo?
        let processIdentityReader: @Sendable (Int32) -> ProcessIdentity?
        let clientFactory: @Sendable (LocalEndpointInfo) -> LocalEndpointClient
    }

    private let source: Source
    private let pollInterval: Duration
    private let staleAfter: TimeInterval

    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored
    private var probeInFlight: Task<Void, Never>?
    @ObservationIgnored
    private var lastProbeAt: Date?

    private init(source: Source, initialState: LocalAPIState, pollInterval: Duration, staleAfter: TimeInterval) {
        self.source = source
        self.state = initialState
        self.pollInterval = pollInterval
        self.staleAfter = staleAfter
    }

    convenience init(fixture: LocalAPIFixture = .active) {
        self.init(
            source: .fixture,
            initialState: LocalAPIFixtures.make(fixture),
            pollInterval: .seconds(3),
            staleAfter: 15
        )
    }

    /// Live store: boots synchronously from `~/.darkbloom/local.json`
    /// (DaemonRuntimeService idiom — real state before any async hop), then
    /// re-reads discovery and probes the endpoint while monitoring.
    static func live(
        discoveryReader: @escaping @Sendable () -> LocalEndpointInfo? = LocalEndpointDiscovery.readInfo,
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? = ProcessIdentity.read,
        probeTimeout: TimeInterval = 2.5,
        pollInterval: Duration = .seconds(3),
        staleAfter: TimeInterval = 15,
        clientFactory: @escaping @Sendable (LocalEndpointInfo) -> LocalEndpointClient = { info in
            LocalEndpointClient(info: info, timeout: 2.5)
        }
    ) -> LocalAPIStore {
        let source = LiveSource(
            discoveryReader: discoveryReader,
            processIdentityReader: processIdentityReader,
            clientFactory: clientFactory
        )
        return LocalAPIStore(
            source: .live(source),
            initialState: bootstrapState(
                reader: discoveryReader,
                processIdentityReader: processIdentityReader
            ),
            pollInterval: pollInterval,
            staleAfter: staleAfter
        )
    }

    deinit {
        monitoringTask?.cancel()
        probeInFlight?.cancel()
    }

    var endpoint: LocalAPIEndpointSnapshot? {
        guard case .running(let endpoint) = state else { return nil }
        return endpoint
    }

    var isLive: Bool {
        if case .live = source { return true }
        return false
    }

    func setAPIKeyRevealed(_ revealed: Bool) {
        isAPIKeyRevealed = revealed && endpoint?.requiresAuthentication == true
    }

    func hideAPIKey() {
        isAPIKeyRevealed = false
    }

    func text(for item: LocalAPICopyItem) -> String? {
        switch item {
        case .command(let mode):
            return mode.startCommand
        case .baseURL, .apiKey, .code:
            break
        }

        guard let endpoint else { return nil }
        switch item {
        case .baseURL:
            return endpoint.baseURL.absoluteString
        case .apiKey:
            return endpoint.apiKey
        case .code(let example):
            return code(example, endpoint: endpoint)
        case .command:
            return nil
        }
    }

    func markCopied(_ item: LocalAPICopyItem) {
        lastCopiedItem = item
    }

    func clearCopyConfirmation() {
        lastCopiedItem = nil
    }

    // MARK: - Live mode: monitoring + probing

    /// Starts the live poll loop (no-op for fixture stores, so preview
    /// captures stay fully static). Called from the Local API view's task.
    func startMonitoring() {
        guard case .live = source, monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                await self.refreshNow()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        probeInFlight?.cancel()
        probeInFlight = nil
    }

    /// One refresh cycle: re-read the discovery record, adopt state changes,
    /// and probe the endpoint when the current picture warrants it
    /// (unprobed, unhealthy, missing catalog, or stale). `forceProbe` is for
    /// manual retries. Fixture stores do nothing — previews stay frozen.
    func refreshNow(forceProbe: Bool = false) async {
        guard case .live(let live) = source else { return }
        let info = live.discoveryReader()
        syncDiscovery(info: info, live: live)
        guard case .running(let endpoint) = state else { return }
        let catalogSettled: Bool = if case .available = endpoint.modelCatalog { true } else { false }
        let shouldProbe = forceProbe
            || endpoint.health != .reachable
            || !catalogSettled
            || lastProbeAt.map { Date().timeIntervalSince($0) >= staleAfter } ?? true
        if shouldProbe, let info {
            await probe(live: live, info: info)
        }
    }

    // MARK: Dual-mode retries (fixture stays deterministic)

    /// Deterministic UI-only recovery in fixture mode; in live mode it
    /// re-reads the discovery record and re-probes.
    func retryPreviewDiscovery() {
        switch source {
        case .fixture:
            guard case .unavailable = state else { return }
            state = LocalAPIFixtures.make(.active)
        case .live:
            Task { await refreshNow(forceProbe: true) }
        }
    }

    /// Deterministic UI-only catalog recovery in fixture mode; in live mode
    /// it performs a real `/models` request.
    func retryPreviewModelCatalog() {
        switch source {
        case .fixture:
            guard case .running(var endpoint) = state,
                  case .failed = endpoint.modelCatalog
            else { return }
            endpoint.modelCatalog = .available(LocalAPIFixtures.sampleModelIDs)
            state = .running(endpoint)
        case .live:
            Task { await refreshNow(forceProbe: true) }
        }
    }

    /// Deterministic UI-only health recovery in fixture mode; in live mode
    /// it performs a real HTTP probe before exposing credentials/examples.
    func retryPreviewHealth() {
        switch source {
        case .fixture:
            guard case .running(var endpoint) = state,
                  endpoint.health == .unreachable
            else {
                retryPreviewDiscovery()
                return
            }
            endpoint.health = .reachable
            state = .running(endpoint)
        case .live:
            guard case .running = state else {
                Task { await refreshNow(forceProbe: true) }
                return
            }
            if var endpoint = endpoint, endpoint.health != .reachable {
                endpoint.health = .checking
                state = .running(endpoint)
            }
            Task { await refreshNow(forceProbe: true) }
        }
    }

    // MARK: - Live internals

    private static func bootstrapState(
        reader: @Sendable () -> LocalEndpointInfo?,
        processIdentityReader: @Sendable (Int32) -> ProcessIdentity?
    ) -> LocalAPIState {
        guard let info = reader() else {
            return .stopped(message: "No live local discovery record was found.")
        }
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: processIdentityReader
        ) else {
            return .stopped(message: "The local discovery record does not belong to the running provider. Start the provider again.")
        }
        return .running(Self.snapshot(from: info, health: .checking, modelCatalog: .loading))
    }

    /// Maps the wire discovery record onto the UI snapshot. `mode` stays nil:
    /// `local.json` does not record how the server was started, and the
    /// presentation layer reports "Mode not reported" rather than guessing.
    private static func snapshot(
        from info: LocalEndpointInfo,
        health: LocalAPIHealth,
        modelCatalog: LocalAPIModelCatalog
    ) -> LocalAPIEndpointSnapshot {
        LocalAPIEndpointSnapshot(
            baseURL: URL(string: info.baseURL) ?? URL(string: "http://127.0.0.1:\(info.port)/v1")!,
            host: info.host,
            port: info.port,
            apiKey: info.apiKey.isEmpty ? nil : info.apiKey,
            pid: info.pid,
            version: info.version,
            updatedAt: ISO8601DateFormatter().date(from: info.updatedAt) ?? Date(timeIntervalSince1970: 0),
            mode: nil,
            health: health,
            modelCatalog: modelCatalog
        )
    }

    /// Adopt the current on-disk truth. Endpoint identity (pid, URL, key)
    /// changes reset probe state to checking/loading; otherwise probe results
    /// are preserved so healthy endpoints don't flicker on every poll.
    private func syncDiscovery(info: LocalEndpointInfo?, live: LiveSource) {
        guard let info,
              LocalEndpointRuntimeTruth.belongsToLiveProcess(
                  info,
                  readIdentity: live.processIdentityReader
              )
        else {
            if case .stopped = state { return }
            state = .stopped(
                message: info == nil
                    ? "No live local discovery record was found."
                    : "The local endpoint discovery is stale or belongs to a different process. Start the provider again."
            )
            return
        }

        let mapped = Self.snapshot(from: info, health: .checking, modelCatalog: .loading)
        switch state {
        case .running(let existing):
            let identityChanged = existing.pid != mapped.pid
                || existing.baseURL != mapped.baseURL
                || existing.apiKey != mapped.apiKey
            if identityChanged {
                state = .running(mapped)
            } else {
                var merged = mapped
                merged.health = existing.health
                merged.modelCatalog = existing.modelCatalog
                if merged != existing {
                    state = .running(merged)
                }
            }
        case .starting, .stopped, .unavailable:
            state = .running(mapped)
        }
    }

    /// Probes the endpoint with the small-timeout client. Probes are
    /// serialized (`probeInFlight`) so a slow endpoint can't stack probes,
    /// and results publish only on a content change.
    ///
    /// Result mapping: transport failure → unreachable + failed catalog;
    /// HTTP 404 → reachable but catalog unavailable (older servers without
    /// `/models`); success → reachable + the decoded model ids.
    private func probe(
        live: LiveSource,
        info: LocalEndpointInfo
    ) async {
        guard case .running = state else { return }
        guard probeInFlight == nil else { return }
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: live.processIdentityReader
        ) else {
            syncDiscovery(info: info, live: live)
            return
        }
        let task = Task {
            defer { probeInFlight = nil }
            lastProbeAt = .now
            let client = live.clientFactory(info)
            do {
                let modelIDs = try await client.listModels()
                adoptProbeResult(health: .reachable, modelCatalog: .available(modelIDs))
            } catch LocalEndpointError.httpError(let status, _) where status == 404 {
                adoptProbeResult(health: .reachable, modelCatalog: .failed)
            } catch {
                guard !Task.isCancelled else { return }
                adoptProbeResult(health: .unreachable, modelCatalog: .failed)
            }
        }
        probeInFlight = task
        await task.value
    }

    private func adoptProbeResult(health: LocalAPIHealth, modelCatalog: LocalAPIModelCatalog) {
        guard case .running(var endpoint) = state else { return }
        guard endpoint.health != health || endpoint.modelCatalog != modelCatalog else { return }
        endpoint.health = health
        endpoint.modelCatalog = modelCatalog
        state = .running(endpoint)
    }

    // MARK: - Code examples

    private func code(
        _ example: LocalAPICodeExample,
        endpoint: LocalAPIEndpointSnapshot
    ) -> String {
        let modelID = endpoint.availableModelIDs?.first ?? "<model-id>"
        switch example {
        case .curl:
            let authLine = endpoint.requiresAuthentication
                ? "  -H \"Authorization: Bearer $OPENAI_API_KEY\" \\\n"
                : ""
            return """
            curl \(endpoint.baseURL.absoluteString)/chat/completions \\
            \(authLine)  -H 'Content-Type: application/json' \\
              -d '{"model":"\(modelID)","messages":[{"role":"user","content":"Hello from this Mac"}]}'
            """

        case .python:
            let apiKey = endpoint.requiresAuthentication
                ? "os.environ[\"OPENAI_API_KEY\"]"
                : "\"not-needed\""
            return """
            import os
            from openai import OpenAI

            client = OpenAI(
                base_url="\(endpoint.baseURL.absoluteString)",
                api_key=\(apiKey),
            )

            response = client.chat.completions.create(
                model="\(modelID)",
                messages=[{"role": "user", "content": "Hello from this Mac"}],
            )
            print(response.choices[0].message.content)
            """
        }
    }
}
