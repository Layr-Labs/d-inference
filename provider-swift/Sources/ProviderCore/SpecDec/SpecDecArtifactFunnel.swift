import Foundation

protocol SpecDecCatalogLooking: Sendable {
    func cachedModel(id: String) async -> CatalogModel?
    func model(id: String) async throws -> CatalogModel?
}

extension SpecDecCatalogLooking {
    func cachedModel(id: String) async -> CatalogModel? { nil }
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
    struct Request: Sendable {
        let modelId: String
        let modelType: String?
        let enabled: Bool
        let localPath: String?
        let allowDownload: Bool
        let environment: [String: String]
    }

    private let resolver: SpecDecResolver
    private let catalog: (any SpecDecCatalogLooking)?
    private struct Prefetch {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var prefetches: [String: Prefetch] = [:]
    private var prefetchFailures: [String: MTPFallbackReason] = [:]
    private let maximumPrefetches = 2
    private var isShutdown = false
    private var shutdownTasks: [Task<Void, Never>] = []

    init(resolver: SpecDecResolver, catalog: (any SpecDecCatalogLooking)?) {
        self.resolver = resolver
        self.catalog = catalog
    }

    /// Populate only the small catalog metadata cache before startup model
    /// loads. The deadline is intentionally short and fail-open; target loads
    /// never await catalog or artifact network I/O themselves.
    @discardableResult
    func prewarmCatalog(
        modelId: String,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await taskSleep(duration)
        }
    ) async -> Bool {
        guard !isShutdown, let catalog else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await catalog.model(id: modelId)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
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
        }
        guard let artifact = resolution.artifact else {
            return .init(
                artifact: nil,
                status: .disabled(resolution.reason ?? .publicationFailed, configured: true))
        }
        return .init(artifact: artifact, status: .candidate(artifact))
    }

    func shutdown() async {
        if isShutdown {
            for task in shutdownTasks { await task.value }
            return
        }
        // Terminal before the first suspension: reentrant prepare calls and
        // tasks returning from catalog lookup cannot enqueue successor work.
        isShutdown = true
        let tasks = prefetches.values.map(\.task)
        shutdownTasks = tasks
        prefetches.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        shutdownTasks.removeAll()
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
        let resolver = self.resolver
        let task = Task {
            let reason: MTPFallbackReason?
            do {
                guard let model = try await catalog.model(id: modelId) else {
                    self.finishPrefetch(
                        modelId: modelId, id: id, reason: .catalogModelMissing)
                    return
                }
                guard self.prefetchMayContinue(modelId: modelId, id: id) else {
                    return
                }
                let result = await resolver.prefetch(model: model)
                reason = result.artifact == nil ? result.reason : nil
            } catch {
                reason = .catalogUnavailable
            }
            self.finishPrefetch(modelId: modelId, id: id, reason: reason)
        }
        prefetches[modelId] = Prefetch(id: id, task: task)
    }

    private func scheduleArtifactPrefetch(modelId: String, model: CatalogModel) {
        guard !isShutdown,
            prefetches[modelId] == nil,
            prefetches.count < maximumPrefetches
        else {
            return
        }
        let id = UUID()
        let resolver = self.resolver
        let task = Task {
            let result = await resolver.prefetch(model: model)
            self.finishPrefetch(
                modelId: modelId,
                id: id,
                reason: result.artifact == nil ? result.reason : nil)
        }
        prefetches[modelId] = Prefetch(id: id, task: task)
    }

    private func prefetchMayContinue(modelId: String, id: UUID) -> Bool {
        !isShutdown && prefetches[modelId]?.id == id
    }

    private func finishPrefetch(
        modelId: String,
        id: UUID,
        reason: MTPFallbackReason?
    ) {
        guard prefetches[modelId]?.id == id else { return }
        prefetches.removeValue(forKey: modelId)
        if let reason {
            prefetchFailures[modelId] = reason
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
