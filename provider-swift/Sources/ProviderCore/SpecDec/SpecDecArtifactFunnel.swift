import Foundation

protocol SpecDecCatalogLooking: Sendable {
    func cachedModel(id: String) async -> CatalogModel?
    func model(id: String) async throws -> CatalogModel?
    /// Bypass the cache and refetch the catalog. Used when a CACHED entry is
    /// suspected stale (present, but without usable `spec_dec` metadata) so a
    /// coordinator that adds spec-dec to an existing model id can roll out
    /// without a provider restart. New builds get new ids and refresh through
    /// the ordinary `model(id:)` miss path.
    func freshModel(id: String) async throws -> CatalogModel?
}

extension SpecDecCatalogLooking {
    func cachedModel(id: String) async -> CatalogModel? { nil }
    func freshModel(id: String) async throws -> CatalogModel? {
        try await model(id: id)
    }
}

actor SpecDecCatalogLookup: SpecDecCatalogLooking {
    private let client: ModelCatalogClient
    private var cached: [String: CatalogModel]?

    init(coordinatorURL: String, urlSession: URLSession = .shared) {
        self.client = ModelCatalogClient(coordinatorURL: coordinatorURL, urlSession: urlSession)
    }

    func cachedModel(id: String) -> CatalogModel? {
        cached?[id]
    }

    func model(id: String) async throws -> CatalogModel? {
        if let model = cached?[id] { return model }
        // Refresh on a miss so a provider that stays up across a newly
        // published desired build can resolve that build's immutable pointer.
        return try await freshModel(id: id)
    }

    func freshModel(id: String) async throws -> CatalogModel? {
        let models = try await client.fetchCatalog()
        // ModelCatalogClient rejects oversized/unbounded responses before this
        // actor can retain them.
        let indexed = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cached = indexed
        return indexed[id]
    }
}

/// One target-independent artifact funnel shared by coordinator-serving and
/// standalone slots. It never loads model weights and never throws.
actor SpecDecArtifactFunnel {
    typealias ArtifactReadyHandler =
        @Sendable (String, SpecDecArtifact, UInt64) async -> Void

    struct Request: Sendable {
        let modelId: String
        let modelType: String?
        let enabled: Bool
        let localPath: String?
        let allowDownload: Bool
        let environment: [String: String]
    }

    let resolver: SpecDecResolver
    let catalog: (any SpecDecCatalogLooking)?
    private struct Prefetch {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }
    private var prefetches: [String: Prefetch] = [:]
    var prefetchFailures: [String: MTPFallbackReason] = [:]
    private let maximumPrefetches = 2
    var isShutdown = false
    private var shutdownTasks: [Task<Void, Never>] = []
    var loadPreparations: [UUID: Task<SpecDecPreparation, Never>] = [:]
    private var shutdownLoadPreparations:
        [Task<SpecDecPreparation, Never>] = []
    var artifactReadyHandler: ArtifactReadyHandler?
    struct Reevaluation {
        let id: UUID
        let task: Task<Void, Never>
    }
    var reevaluations: [String: Reevaluation] = [:]
    var reevaluationAttempts: [String: Int] = [:]
    var knownRequests: [String: Request] = [:]
    var catalogGenerations: [String: UInt64] = [:]
    var reevaluationDelays: [Duration] = [
        .seconds(30), .seconds(60), .seconds(120),
    ]
    var steadyRefreshInterval: Duration = .seconds(600)
    /// Cooldown for stale-entry catalog refreshes so a model that is
    /// permanently missing spec-dec metadata cannot make every load attempt
    /// refetch the catalog. Internal-settable for tests.
    var catalogRefreshCooldown: Duration = .seconds(600)
    private var catalogRefreshedAt: [String: ContinuousClock.Instant] = [:]

    init(resolver: SpecDecResolver, catalog: (any SpecDecCatalogLooking)?) {
        self.resolver = resolver
        self.catalog = catalog
    }

    func setArtifactReadyHandler(_ handler: ArtifactReadyHandler?) {
        artifactReadyHandler = handler
    }

    func beginCatalogGeneration(modelId: String) -> UInt64 {
        let next = (catalogGenerations[modelId] ?? 0) &+ 1
        catalogGenerations[modelId] = next
        return next
    }

    func isCurrentCatalogGeneration(modelId: String, generation: UInt64) -> Bool {
        catalogGenerations[modelId] == generation
    }

    func configureReevaluationForTesting(
        delays: [Duration],
        steadyInterval: Duration
    ) {
        reevaluationDelays = delays
        steadyRefreshInterval = steadyInterval
    }

    func prepare(_ request: Request) async -> SpecDecPreparation {
        guard !isShutdown else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogUnavailable, configured: request.enabled))
        }
        guard request.enabled else {
            return .init(artifact: nil, status: .disabled(.configDisabled, configured: false))
        }
        guard Self.killSwitchEnabled(environment: request.environment) else {
            return .init(artifact: nil, status: .disabled(.killSwitchDisabled, configured: true))
        }
        guard Self.isGemma4Target(modelType: request.modelType) else {
            return .init(artifact: nil, status: .disabled(.targetUnsupported, configured: true))
        }
        if request.allowDownload {
            knownRequests[request.modelId] = request
        }

        // An explicitly configured local artifact is authoritative. An invalid
        // local override falls back to target-only rather than silently fetching
        // and activating a different assistant from the catalog.
        if let rawPath = request.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        {
            guard let artifact = SpecDecStore.inspectLocalArtifact(path: rawPath) else {
                return .init(
                    artifact: nil,
                    status: .disabled(.localArtifactInvalid, configured: true))
            }
            return .init(artifact: artifact, status: .candidate(artifact))
        }

        guard let catalog else {
            return .init(
                artifact: nil,
                status: .disabled(.catalogDisabled, configured: true))
        }

        guard let model = await catalog.cachedModel(id: request.modelId) else {
            if request.allowDownload {
                schedulePrefetch(modelId: request.modelId, catalog: catalog)
            }
            return .init(
                artifact: nil,
                status: .disabled(
                    prefetchFailures[request.modelId] ?? .artifactNotCached,
                    configured: true))
        }
        // Loading paths only inspect verified local state. Any optional network
        // work is owned by this funnel so shutdown can cancel it promptly.
        let resolution = await resolver.resolve(model: model, allowDownload: false)
        if resolution.reason == .artifactNotCached, request.allowDownload {
            scheduleArtifactPrefetch(modelId: request.modelId, model: model)
        } else if let reason = resolution.reason,
            reason == .metadataMissing || reason == .metadataMalformed,
            request.allowDownload
        {
            // The cached catalog entry exists but carries no usable spec_dec.
            // The coordinator may have added it after this cache filled, so
            // refresh (cooldown-gated) instead of staying stuck until restart.
            scheduleCatalogRefresh(modelId: request.modelId, catalog: catalog)
        }
        guard let artifact = resolution.artifact else {
            return .init(
                artifact: nil,
                status: .disabled(resolution.reason ?? .publicationFailed, configured: true))
        }
        return .init(artifact: artifact, status: .candidate(artifact))
    }

    /// Number of in-flight prefetch/refresh tasks (test observability).
    var prefetchInFlightForTesting: Int { prefetches.count }

    func shutdown() async {
        if isShutdown {
            for task in shutdownTasks { await task.value }
            for task in shutdownLoadPreparations { _ = await task.value }
            return
        }
        // Terminal before the first suspension: reentrant prepare calls and
        // tasks returning from catalog lookup cannot enqueue successor work.
        isShutdown = true
        let tasks = prefetches.values.map(\.task)
        let refreshTasks = reevaluations.values.map(\.task)
        let preparations = Array(loadPreparations.values)
        shutdownTasks = tasks + refreshTasks
        shutdownLoadPreparations = preparations
        prefetches.removeAll()
        reevaluations.removeAll()
        loadPreparations.removeAll()
        knownRequests.removeAll()
        catalogGenerations.removeAll()
        for task in shutdownTasks { task.cancel() }
        for task in shutdownLoadPreparations { task.cancel() }
        for task in shutdownTasks { await task.value }
        for task in shutdownLoadPreparations { _ = await task.value }
        shutdownTasks.removeAll()
        shutdownLoadPreparations.removeAll()
    }

    private func schedulePrefetch(
        modelId: String,
        catalog: any SpecDecCatalogLooking
    ) {
        guard !isShutdown,
            prefetches[modelId] == nil,
            prefetches.count < maximumPrefetches
        else {
            return
        }
        let id = UUID()
        let generation = beginCatalogGeneration(modelId: modelId)
        let resolver = self.resolver
        let task = Task {
            let reason: MTPFallbackReason?
            do {
                guard let model = try await catalog.model(id: modelId) else {
                    await self.finishPrefetch(
                        modelId: modelId, id: id,
                        generation: generation,
                        resolution: .fallback(.catalogModelMissing))
                    return
                }
                guard self.prefetchMayContinue(modelId: modelId, id: id) else {
                    return
                }
                guard self.isCurrentCatalogGeneration(
                    modelId: modelId, generation: generation)
                else {
                    await self.finishPrefetch(
                        modelId: modelId, id: id, generation: generation,
                        resolution: .fallback(.catalogUnavailable))
                    return
                }
                let result = await resolver.prefetch(model: model)
                reason = result.artifact == nil ? result.reason : nil
                await self.finishPrefetch(
                    modelId: modelId, id: id, generation: generation,
                    resolution: result)
                return
            } catch {
                reason = .catalogUnavailable
            }
            await self.finishPrefetch(
                modelId: modelId, id: id,
                generation: generation,
                resolution: .fallback(reason ?? .catalogUnavailable))
        }
        prefetches[modelId] = Prefetch(
            id: id, generation: generation, task: task)
    }

    /// Refresh a suspected-stale cached catalog entry, then prefetch the
    /// artifact if the refreshed metadata now resolves. Reuses the prefetch
    /// ledger for dedupe/shutdown and is additionally cooldown-gated.
    private func scheduleCatalogRefresh(
        modelId: String,
        catalog: any SpecDecCatalogLooking
    ) {
        guard !isShutdown,
            prefetches[modelId] == nil,
            prefetches.count < maximumPrefetches
        else {
            return
        }
        let now = ContinuousClock.now
        if let last = catalogRefreshedAt[modelId], now - last < catalogRefreshCooldown {
            return
        }
        catalogRefreshedAt[modelId] = now
        let id = UUID()
        let generation = beginCatalogGeneration(modelId: modelId)
        let resolver = self.resolver
        let task = Task {
            let reason: MTPFallbackReason?
            do {
                guard let model = try await catalog.freshModel(id: modelId) else {
                    await self.finishPrefetch(
                        modelId: modelId, id: id,
                        generation: generation,
                        resolution: .fallback(.catalogModelMissing))
                    return
                }
                guard self.prefetchMayContinue(modelId: modelId, id: id) else {
                    return
                }
                guard self.isCurrentCatalogGeneration(
                    modelId: modelId, generation: generation)
                else {
                    await self.finishPrefetch(
                        modelId: modelId, id: id, generation: generation,
                        resolution: .fallback(.catalogUnavailable))
                    return
                }
                let result = await resolver.prefetch(model: model)
                reason = result.artifact == nil ? result.reason : nil
                await self.finishPrefetch(
                    modelId: modelId, id: id, generation: generation,
                    resolution: result)
                return
            } catch {
                reason = .catalogUnavailable
            }
            await self.finishPrefetch(
                modelId: modelId, id: id,
                generation: generation,
                resolution: .fallback(reason ?? .catalogUnavailable))
        }
        prefetches[modelId] = Prefetch(
            id: id, generation: generation, task: task)
    }

    private func scheduleArtifactPrefetch(modelId: String, model: CatalogModel) {
        guard !isShutdown,
            prefetches[modelId] == nil,
            prefetches.count < maximumPrefetches
        else {
            return
        }
        let id = UUID()
        let generation = beginCatalogGeneration(modelId: modelId)
        let resolver = self.resolver
        let task = Task {
            let result = await resolver.prefetch(model: model)
            await self.finishPrefetch(
                modelId: modelId,
                id: id,
                generation: generation,
                resolution: result)
        }
        prefetches[modelId] = Prefetch(
            id: id, generation: generation, task: task)
    }

    private func prefetchMayContinue(modelId: String, id: UUID) -> Bool {
        !isShutdown && prefetches[modelId]?.id == id
    }

    private func finishPrefetch(
        modelId: String,
        id: UUID,
        generation: UInt64,
        resolution: SpecDecResolution
    ) async {
        guard prefetches[modelId]?.id == id else { return }
        prefetches.removeValue(forKey: modelId)
        guard !isShutdown,
            isCurrentCatalogGeneration(
                modelId: modelId, generation: generation)
        else { return }
        if let artifact = resolution.artifact {
            prefetchFailures.removeValue(forKey: modelId)
            reevaluationAttempts.removeValue(forKey: modelId)
            await notifyReady(
                modelId: modelId,
                artifact: artifact,
                generation: generation)
            if let request = knownRequests[modelId] {
                scheduleSteadyRefresh(for: request)
            }
        } else if let reason = resolution.reason {
            prefetchFailures[modelId] = reason
            if let request = knownRequests[modelId] {
                scheduleReevaluation(for: request)
            }
        } else {
            prefetchFailures.removeValue(forKey: modelId)
        }
    }

    static func isGemma4Target(modelType: String?) -> Bool {
        EngineV2SupportedModels.isGemma4Target(modelType: modelType)
    }

    static func killSwitchEnabled(environment: [String: String]) -> Bool {
        guard let raw = environment["DARKBLOOM_CBV2_MTP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return true }
        return !["0", "false", "no", "off"].contains(raw)
    }
}
