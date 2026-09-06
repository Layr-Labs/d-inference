import Foundation
import Testing
@testable import DarkbloomApp

/// Scripted `ModelCatalogCLIRunning` for the live store. Snapshots are
/// replaceable (the on-disk world "changes" between refreshes), and every
/// `downloadEvents` call gets its own manually driven channel so the test
/// controls timing exactly — no sleeps, no real processes.
private final class StubModelCatalogCLI: ModelCatalogCLIRunning, @unchecked Sendable {
    struct DownloadChannel {
        let id: Int
        let modelID: String
        let continuation: AsyncThrowingStream<ModelDownloadStreamEvent, Error>.Continuation
    }

    private let lock = NSLock()
    private var snapshotStorage: Result<ModelLibrarySnapshot, Error>
    private var fetchCountStorage = 0
    private var channelStorage: [DownloadChannel] = []
    private var cancelledChannelIDStorage: Set<Int> = []
    private var removedModelIDStorage: [String] = []
    private var prepareCountStorage = 0
    private let preparationGate: StubPreparationGate?
    var removeError: Error?

    var fetchCount: Int { lock.withLock { fetchCountStorage } }
    var prepareCount: Int { lock.withLock { prepareCountStorage } }
    var channels: [DownloadChannel] { lock.withLock { channelStorage } }
    var cancelledChannelIDs: Set<Int> { lock.withLock { cancelledChannelIDStorage } }
    var removedModelIDs: [String] { lock.withLock { removedModelIDStorage } }

    init(
        snapshot: Result<ModelLibrarySnapshot, Error>,
        preparationGate: StubPreparationGate? = nil
    ) {
        snapshotStorage = snapshot
        self.preparationGate = preparationGate
    }

    func setSnapshot(_ result: Result<ModelLibrarySnapshot, Error>) {
        lock.withLock { snapshotStorage = result }
    }

    func fetchSnapshot() async throws -> ModelLibrarySnapshot {
        let result = lock.withLock {
            fetchCountStorage += 1
            return snapshotStorage
        }
        return try result.get()
    }

    func prepareDownload(modelID: String) async throws -> PreparedModelDownload {
        lock.withLock { prepareCountStorage += 1 }
        if let preparationGate {
            await preparationGate.wait()
        }
        try Task.checkCancellation()
        let snapshot = try lock.withLock { snapshotStorage }.get()
        let plan = try ValidatedModelDownloadStoragePlan.validate(
            snapshot.downloadPlans[modelID],
            modelID: modelID
        )
        return PreparedModelDownload(
            modelID: modelID,
            plan: plan,
            start: { [weak self] in
                self?.makeDownloadStream(modelID: modelID)
                    ?? AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
            },
            cancel: {}
        )
    }

    private func makeDownloadStream(
        modelID: String
    ) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        var continuation: AsyncThrowingStream<ModelDownloadStreamEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<ModelDownloadStreamEvent, Error> { c in
            continuation = c
        }
        let id = lock.withLock {
            let id = (channelStorage.last?.id ?? 0) + 1
            channelStorage.append(DownloadChannel(id: id, modelID: modelID, continuation: continuation))
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.noteCancelled(id)
        }
        return stream
    }

    func removeModel(modelID: String) async throws {
        let error = lock.withLock {
            removedModelIDStorage.append(modelID)
            return removeError
        }
        if let error { throw error }
    }

    private func noteCancelled(_ id: Int) {
        lock.withLock { cancelledChannelIDStorage.insert(id) }
    }

    func channel(id: Int) -> DownloadChannel? {
        lock.withLock { channelStorage.first { $0.id == id } }
    }
}

private actor StubPreparationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private func _eventually(
    iterations: Int = 200,
    condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@Suite("ModelLibraryStore live mode (stubbed CLI)")
@MainActor
struct ModelLibraryStoreLiveTests {

    // MARK: Fixtures

    private func makeSnapshot(
        catalog: [CLICatalogModel] = [],
        catalogError: ModelCatalogCLIError? = nil,
        local: [CLILocalModelEntry] = [],
        downloadPlans: [String: CLIModelDownloadStoragePlan] = [:],
        automaticallyPlanDownloads: Bool = true,
        warmModelIDs: Set<String> = [],
        servingModelID: String? = nil,
        physicalMemoryGB: Int? = 32,
        runtimeEligibility: [String: CLIModelRuntimeEligibility]? = nil
    ) -> ModelLibrarySnapshot {
        let plans: [String: CLIModelDownloadStoragePlan]
        if automaticallyPlanDownloads, downloadPlans.isEmpty {
            let reserve = Int64(2 * 1_073_741_824)
            plans = Dictionary(uniqueKeysWithValues: catalog.map { model in
                let remaining = max(0, model.totalSizeBytes ?? 0)
                let required = remaining + reserve
                return (model.id, CLIModelDownloadStoragePlan(
                    remainingBytes: remaining,
                    reserveBytes: reserve,
                    requiredAvailableBytes: required,
                    availableBytes: 1_000_000_000_000,
                    hasSufficientCapacity: true
                ))
            })
        } else {
            plans = downloadPlans
        }
        return ModelLibrarySnapshot(
            catalog: catalog,
            catalogError: catalogError,
            local: local,
            downloadPlans: plans,
            runtimeEligibility: runtimeEligibility ?? Dictionary(uniqueKeysWithValues: catalog.map {
                ($0.id, CLIModelRuntimeEligibility(status: .eligible, reason: "Fixture runtime is eligible."))
            }),
            warmModelIDs: warmModelIDs,
            servingModelID: servingModelID,
            physicalMemoryGB: physicalMemoryGB,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func catalogEntry(
        id: String,
        minRamGb: Int? = nil,
        capabilities: [String]? = ["text-generation"],
        sizeBytes: Int64 = 4_000_000_000
    ) -> CLICatalogModel? {
        let json = """
        {
          "id" : "\(id)",
          "s3_name" : "\(id.replacingOccurrences(of: "/", with: "__"))/v1",
          "display_name" : "\(id.split(separator: "/").last ?? "model")",
          "model_type" : "text",
          "size_gb" : 4.0,
          "description" : "A catalog model.",
          "min_ram_gb" : \(minRamGb.map(String.init) ?? "null"),
          "family" : "TestFamily",
          "quantization" : "4-bit",
          "max_context_length" : 32768,
          "capabilities" : \(capabilities.map { "[\($0.map { "\"\($0)\"" }.joined(separator: ","))]" } ?? "null"),
          "total_size_bytes" : \(sizeBytes)
        }
        """
        return try? JSONDecoder().decode(CLICatalogModel.self, from: Data(json.utf8))
    }

    private func localEntry(id: String, sizeBytes: UInt64 = 4_000_000_000) -> CLILocalModelEntry {
        let json = """
        {
          "id" : "\(id)",
          "model_type" : "text",
          "quantization" : "4-bit",
          "size_bytes" : \(sizeBytes),
          "estimated_memory_gb" : 4.4
        }
        """
        return try! JSONDecoder().decode(CLILocalModelEntry.self, from: Data(json.utf8))
    }

    // MARK: Snapshot → rows

    @Test("enough RAM cannot override a refused or unknown runtime verdict")
    func runtimeEligibilityBlocksRAMOverride() async throws {
        let model = try #require(catalogEntry(id: "org/runtime-gated", minRamGb: 16))
        let cases: [CLIModelRuntimeEligibility] = [
            .init(status: .ineligible, reason: "Requires hardware unavailable on this Mac."),
            .init(status: .unknown, reason: "Runtime detection was unavailable."),
        ]
        for verdict in cases {
            let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
                catalog: [model], physicalMemoryGB: 128,
                runtimeEligibility: [model.id: verdict])))
            let store = ModelLibraryStore(live: cli)
            await store.start()
            #expect(store.models.first?.fit.runtimeBlockReason == verdict.reason)
            #expect(store.models.first?.fit.canRunOnThisMac == false)
            #expect(await store.beginDownload(modelID: model.id, allowingIncompatibleModel: true)
                == .unavailable(verdict.reason))
            #expect(await store.resumeDownload(modelID: model.id) == .unavailable(verdict.reason))
            #expect(cli.prepareCount == 0)
            #expect(cli.channels.isEmpty)
        }
    }

    @Test("missing runtime verdicts never become confirmed RAM compatibility")
    func missingRuntimeVerdictIsUnknown() async throws {
        let model = try #require(catalogEntry(id: "org/model", minRamGb: 8))
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
            catalog: [model], runtimeEligibility: [:])))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        #expect(store.models.first?.fit == .runtimeUnknown(reason: CLIModelRuntimeEligibility.unreported.reason))
    }

    @Test("runtime eligibility is rechecked after a delayed download preflight")
    func changedRuntimeVerdictFencesDelayedStart() async throws {
        let model = try #require(catalogEntry(id: "org/delayed", minRamGb: 8))
        let gate = StubPreparationGate()
        let cli = StubModelCatalogCLI(
            snapshot: .success(makeSnapshot(catalog: [model])), preparationGate: gate)
        let store = ModelLibraryStore(live: cli)
        await store.start()
        let start = Task { await store.beginDownload(modelID: model.id) }
        #expect(await _eventually { cli.prepareCount == 1 })
        cli.setSnapshot(.success(makeSnapshot(catalog: [model], runtimeEligibility: [
            model.id: .init(status: .ineligible, reason: "Runtime became unavailable."),
        ])))
        await store.refresh()
        await gate.open()
        #expect(await start.value == .invalidState)
        #expect(cli.channels.isEmpty)
        #expect(store.models.first?.installation == .notInstalled)
    }

    @Test("live start builds rows from catalog + local list + daemon warmth")
    func startBuildsRows() async {
        let qwen = catalogEntry(id: "mlx/Qwen-7B", minRamGb: 16)!
        let big = catalogEntry(id: "mlx/Big-70B", minRamGb: 48)!
        let installedID = "mlx/Qwen-7B"
        let snapshot = makeSnapshot(
            catalog: [qwen, big],
            local: [localEntry(id: installedID), localEntry(id: "local/custom")],
            warmModelIDs: [installedID],
            servingModelID: installedID,
            physicalMemoryGB: 32
        )
        let store = ModelLibraryStore(live: StubModelCatalogCLI(snapshot: .success(snapshot)))

        #expect(store.isLive)
        #expect(store.catalogState == .loading)
        #expect(store.models.isEmpty)

        await store.start()

        guard case .available(let lastUpdated) = store.catalogState else {
            Issue.record("expected available catalog, got \(store.catalogState)")
            return
        }
        #expect(lastUpdated == snapshot.fetchedAt)

        #expect(store.models.count == 3)

        let warm = store.models.first { $0.id == installedID }
        #expect(warm?.isInstalled == true)
        #expect(warm?.runtime == .serving)
        #expect(warm?.fit == .fits)
        #expect(warm?.origin == .catalog)
        #expect(warm?.sizeBytes == 4_000_000_000)

        let tooBig = store.models.first { $0.id == "mlx/Big-70B" }
        #expect(tooBig?.isInstalled == false)
        #expect(tooBig?.fit == .tooLarge(requiredMemoryGB: 48, availableMemoryGB: 32))
        #expect(tooBig?.runtime == .cold)

        let localOnly = store.models.first { $0.id == "local/custom" }
        #expect(localOnly?.origin == .localOnly)
        #expect(localOnly?.isInstalled == true)
    }

    @Test("CLI failure in live mode flips the catalog offline and blocks downloads")
    func catalogFailureOffline() async {
        let cli = StubModelCatalogCLI(snapshot: .failure(
            ModelCatalogCLIError.exited(1, message: "could not fetch catalog: coordinator unreachable")))
        let store = ModelLibraryStore(live: cli)

        await store.start()

        guard case .offline(let message, let cached) = store.catalogState else {
            Issue.record("expected offline catalog, got \(store.catalogState)")
            return
        }
        #expect(message.contains("coordinator unreachable"))
        #expect(!cached)
        #expect(await store.beginDownload(modelID: "anything") == .modelNotFound)

        // Recover: the same stub then serves a real catalog.
        let entry = catalogEntry(id: "mlx/Qwen-7B")!
        cli.setSnapshot(.success(makeSnapshot(catalog: [entry])))
        store.retryCatalog()
        #expect(await _eventually { store.catalogState == .available(lastUpdated: makeSnapshot().fetchedAt) })
        #expect(cli.fetchCount == 2)
    }

    @Test("First offline refresh exposes installed models for local use without asserting eligibility")
    func offlineFirstRefreshKeepsLocalModels() async throws {
        let modelID = "local/custom"
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
            catalogError: .exited(7, message: "registry unavailable"),
            local: [localEntry(id: modelID)],
            warmModelIDs: [modelID]
        )))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        #expect(store.catalogState == .offline(message: "registry unavailable", showingCachedResults: false))
        let model = try #require(store.installedModels.first)
        #expect(model.id == modelID)
        #expect(model.origin == .localOnly)
        #expect(model.fit == .unknown)
        #expect(model.runtime == .warm)
        try LocalAPIStartPreflight.validateModel(modelID: modelID, models: store.models, modelsAreLive: store.isLive)
        #expect(await store.beginDownload(modelID: modelID) == .unavailable(
            "This model is not available in the current catalog."))
        #expect(cli.prepareCount == 0)
        #expect(cli.channels.isEmpty)
    }

    @Test("Offline refresh preserves cached eligibility while replacing installed and warm state")
    func offlineRefreshPreservesEligibilityAndRefreshesInventory() async throws {
        let eligible = try #require(catalogEntry(id: "catalog/eligible", minRamGb: 16))
        let refused = try #require(catalogEntry(id: "catalog/refused", minRamGb: 16))
        let downloadable = try #require(catalogEntry(id: "catalog/download", minRamGb: 16))
        let reason = "The installed runtime cannot load this model."
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
            catalog: [eligible, refused, downloadable],
            local: [localEntry(id: eligible.id), localEntry(id: "local/removed")],
            warmModelIDs: [eligible.id],
            runtimeEligibility: [
                eligible.id: .init(status: .eligible, reason: "Supported"),
                refused.id: .init(status: .ineligible, reason: reason),
                downloadable.id: .init(status: .eligible, reason: "Supported"),
            ]
        )))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        store.selectModel(id: eligible.id)

        cli.setSnapshot(.success(makeSnapshot(
            catalogError: .exited(7, message: "registry unavailable"),
            local: [localEntry(id: refused.id), localEntry(id: "local/new")]
        )))
        await store.refresh()

        #expect(store.catalogState == .offline(message: "registry unavailable", showingCachedResults: true))
        #expect(Set(store.installedModels.map(\.id)) == [refused.id, "local/new"])
        #expect(!store.models.contains { $0.id == "local/removed" })
        #expect(store.selectedModelID == eligible.id)
        #expect(store.selectedModel?.installation == .notInstalled)
        #expect(store.selectedModel?.runtime == .cold)
        #expect(store.selectedModel?.fit == .fits)
        let blocked = try #require(store.models.first { $0.id == refused.id })
        #expect(blocked.fit == .runtimeIneligible(reason: reason))
        #expect(blocked.origin == .catalog)
        #expect(throws: LocalAPIStartError.self) {
            try LocalAPIStartPreflight.validateModel(modelID: refused.id, models: store.models, modelsAreLive: true)
        }
        try LocalAPIStartPreflight.validateModel(modelID: "local/new", models: store.models, modelsAreLive: true)
        #expect(await store.beginDownload(modelID: downloadable.id) == .unavailable(
            "Reconnect to refresh the catalog before downloading."))
        #expect(cli.prepareCount == 0)
        #expect(cli.channels.isEmpty)

        // Recovery supplies the next authoritative CLI verdict.
        cli.setSnapshot(.success(makeSnapshot(
            catalog: [eligible, refused, downloadable], local: [localEntry(id: refused.id)]
        )))
        await store.refresh()
        #expect(store.catalogState == .available(lastUpdated: makeSnapshot().fetchedAt))
        #expect(store.installedModels.first?.fit == .fits)
    }

    @Test("A missing catalog verdict cannot clear a cached runtime refusal")
    func missingVerdictPreservesCachedRefusal() async throws {
        let entry = try #require(catalogEntry(id: "catalog/refused"))
        let refusal = CLIModelRuntimeEligibility(status: .ineligible, reason: "Unsupported runtime")
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
            catalog: [entry], local: [localEntry(id: entry.id)], runtimeEligibility: [entry.id: refusal]
        )))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        cli.setSnapshot(.success(makeSnapshot(
            catalog: [entry], local: [localEntry(id: entry.id)], runtimeEligibility: [:]
        )))
        await store.refresh()
        #expect(store.installedModels.first?.fit == .runtimeIneligible(reason: refusal.reason))
        cli.setSnapshot(.success(makeSnapshot(local: [localEntry(id: entry.id)])))
        await store.refresh()
        #expect(store.installedModels.first?.fit == .runtimeIneligible(reason: refusal.reason))
    }

    @Test("Offline refresh preserves paused progress and refuses resume before preflight")
    func offlineResumeDoesNotPrepareDownload() async throws {
        let entry = try #require(catalogEntry(id: "catalog/download", sizeBytes: 4_000))
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [entry])))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        #expect(await store.beginDownload(modelID: entry.id) == .applied)
        #expect(await _eventually { cli.channel(id: 1) != nil })
        let channel = try #require(cli.channel(id: 1))
        channel.continuation.yield(.progress(file: "weights", bytes: 1_000, total: 4_000))
        #expect(await _eventually { store.models.first?.installation.progress?.downloadedBytes == 1_000 })
        #expect(store.pauseDownload(modelID: entry.id) == .applied)
        let paused = store.models.first?.installation
        cli.setSnapshot(.success(makeSnapshot(catalogError: .exited(7, message: "registry unavailable"))))
        await store.refresh()

        #expect(store.models.first?.installation == paused)
        #expect(await store.resumeDownload(modelID: entry.id) == .unavailable(
            "Reconnect to refresh the catalog before downloading."))
        #expect(cli.prepareCount == 1)
        #expect(cli.channels.count == 1)
    }

    @Test("A cancelled refresh does not publish a returned offline snapshot")
    func cancelledRefreshDoesNotPublishOfflineInventory() async {
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(local: [localEntry(id: "local/original")])))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        cli.setSnapshot(.success(makeSnapshot(
            catalogError: .exited(7, message: "registry unavailable"), local: [localEntry(id: "local/new")]
        )))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh()
        }
        await task.value
        #expect(store.catalogState == .available(lastUpdated: makeSnapshot().fetchedAt))
        #expect(store.installedModels.map(\.id) == ["local/original"])
    }

    @Test("Returning after a cancelled first load can fetch the installed inventory")
    func cancelledInitialLoadCanRestart() async {
        let cli = StubModelCatalogCLI(snapshot: .failure(CancellationError()))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        #expect(store.catalogState != .loading)
        cli.setSnapshot(.success(makeSnapshot(local: [localEntry(id: "local/installed")])))
        await store.start()
        #expect(cli.fetchCount == 2)
        #expect(store.installedModels.map(\.id) == ["local/installed"])
        #expect(store.catalogState == .available(lastUpdated: makeSnapshot().fetchedAt))
    }

    @Test("insufficient download plan blocks the CLI before process creation")
    func insufficientStoragePlanBlocksDownload() async {
        let modelID = "mlx/Qwen-7B"
        let qwen = catalogEntry(id: modelID, sizeBytes: 4_000)!
        let reserve = Int64(2 * 1_073_741_824)
        let required = reserve + 4_000
        let plan = CLIModelDownloadStoragePlan(
            remainingBytes: 4_000,
            reserveBytes: reserve,
            requiredAvailableBytes: required,
            availableBytes: required - 1,
            hasSufficientCapacity: false
        )
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
            catalog: [qwen],
            downloadPlans: [modelID: plan]
        )))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        let result = await store.beginDownload(modelID: modelID)

        guard case .unavailable(let message) = result else {
            Issue.record("expected disk-space refusal, got \(result)")
            return
        }
        #expect(message.contains("Not enough disk space"))
        #expect(cli.channels.isEmpty)
        #expect(store.models.first?.installation == .notInstalled)
    }

    @Test("a stale sufficient screen plan cannot authorize a fresh insufficient preflight")
    func stalePlanCannotAuthorizeDownload() async {
        let modelID = "mlx/Qwen-7B"
        let qwen = catalogEntry(id: modelID, sizeBytes: 4_000)!
        let reserve = Int64(2 * 1_073_741_824)
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        let required = reserve + 4_000
        cli.setSnapshot(.success(makeSnapshot(
            catalog: [qwen],
            downloadPlans: [modelID: CLIModelDownloadStoragePlan(
                remainingBytes: 4_000,
                reserveBytes: reserve,
                requiredAvailableBytes: required,
                availableBytes: required - 1,
                hasSufficientCapacity: false
            )]
        )))

        guard case .unavailable(let message) =
            await store.beginDownload(modelID: modelID)
        else {
            Issue.record("expected the fresh plan to refuse the stale admission")
            return
        }
        #expect(message.contains("Not enough disk space"))
        #expect(cli.prepareCount == 1)
        #expect(cli.channels.isEmpty)
        #expect(store.models.first?.installation == .notInstalled)
    }

    @Test("missing, unknown, and inconsistent fresh plans fail closed")
    func invalidFreshPlansFailClosed() async {
        let modelID = "mlx/Qwen-7B"
        let qwen = catalogEntry(id: modelID, sizeBytes: 4_000)!
        let reserve = Int64(2 * 1_073_741_824)
        let required = reserve + 4_000
        let invalidPlans: [CLIModelDownloadStoragePlan?] = [
            nil,
            CLIModelDownloadStoragePlan(
                remainingBytes: 4_000,
                reserveBytes: reserve,
                requiredAvailableBytes: required,
                availableBytes: nil,
                hasSufficientCapacity: false
            ),
            CLIModelDownloadStoragePlan(
                remainingBytes: 4_000,
                reserveBytes: reserve - 1,
                requiredAvailableBytes: required - 1,
                availableBytes: required,
                hasSufficientCapacity: true
            ),
            CLIModelDownloadStoragePlan(
                remainingBytes: 4_000,
                reserveBytes: reserve,
                requiredAvailableBytes: required + 1,
                availableBytes: required + 1,
                hasSufficientCapacity: true
            ),
            CLIModelDownloadStoragePlan(
                remainingBytes: 4_000,
                reserveBytes: reserve,
                requiredAvailableBytes: required,
                availableBytes: required - 1,
                hasSufficientCapacity: true
            ),
            CLIModelDownloadStoragePlan(
                remainingBytes: Int64.max,
                reserveBytes: reserve,
                requiredAvailableBytes: Int64.max,
                availableBytes: Int64.max,
                hasSufficientCapacity: true
            ),
        ]

        for plan in invalidPlans {
            let plans = plan.map { [modelID: $0] } ?? [:]
            let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(
                catalog: [qwen],
                downloadPlans: plans,
                automaticallyPlanDownloads: false
            )))
            let store = ModelLibraryStore(live: cli)
            await store.start()

            guard case .unavailable =
                await store.beginDownload(modelID: modelID)
            else {
                Issue.record("expected invalid plan refusal: \(String(describing: plan))")
                continue
            }
            #expect(cli.channels.isEmpty)
            #expect(store.models.first?.installation == .notInstalled)
        }
    }

    @Test("paused resume admits at the exact remaining-byte plus reserve boundary")
    func resumedStoragePlanUsesRemainingBytes() async throws {
        let modelID = "mlx/Qwen-7B"
        let qwen = catalogEntry(id: modelID, sizeBytes: 10_000)!
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        #expect(await store.beginDownload(modelID: modelID) == .applied)
        #expect(await _eventually { cli.channel(id: 1) != nil })
        let first = try #require(cli.channel(id: 1))
        first.continuation.yield(.progress(file: "weights", bytes: 9_000, total: 10_000))
        #expect(await _eventually {
            store.models.first?.installation.progress?.downloadedBytes == 9_000
        })
        #expect(store.pauseDownload(modelID: modelID) == .applied)

        let reserve = Int64(2 * 1_073_741_824)
        let remaining = Int64(1_000)
        let required = reserve + remaining
        let plan = CLIModelDownloadStoragePlan(
            remainingBytes: remaining,
            reserveBytes: reserve,
            requiredAvailableBytes: required,
            availableBytes: required,
            hasSufficientCapacity: true
        )
        cli.setSnapshot(.success(makeSnapshot(
            catalog: [qwen],
            downloadPlans: [modelID: plan]
        )))

        #expect(await store.resumeDownload(modelID: modelID) == .applied)
        #expect(await _eventually { cli.channel(id: 2) != nil })
        #expect(cli.channel(id: 2)?.modelID == modelID)
    }

    @Test("paused and resumable-failed retries refuse before creating another stream")
    func resumeStatesRefuseInsufficientFreshPlan() async throws {
        for shouldFailStream in [false, true] {
            let modelID = "mlx/Qwen-7B-\(shouldFailStream)"
            let qwen = catalogEntry(id: modelID, sizeBytes: 10_000)!
            let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
            let store = ModelLibraryStore(live: cli)
            await store.start()
            #expect(await store.beginDownload(modelID: modelID) == .applied)
            #expect(await _eventually { cli.channel(id: 1) != nil })
            let first = try #require(cli.channel(id: 1))
            first.continuation.yield(
                .progress(file: "weights", bytes: 5_000, total: 10_000)
            )
            #expect(await _eventually {
                store.models.first?.installation.progress?.downloadedBytes == 5_000
            })

            if shouldFailStream {
                first.continuation.finish(
                    throwing: ModelCatalogCLIError.exited(
                        1,
                        message: "connection interrupted"
                    )
                )
                #expect(await _eventually {
                    if case .failed = store.models.first?.installation { return true }
                    return false
                })
            } else {
                #expect(store.pauseDownload(modelID: modelID) == .applied)
                #expect(await _eventually { cli.cancelledChannelIDs.contains(1) })
            }

            let reserve = Int64(2 * 1_073_741_824)
            let required = reserve + 5_000
            cli.setSnapshot(.success(makeSnapshot(
                catalog: [qwen],
                downloadPlans: [modelID: CLIModelDownloadStoragePlan(
                    remainingBytes: 5_000,
                    reserveBytes: reserve,
                    requiredAvailableBytes: required,
                    availableBytes: required - 1,
                    hasSufficientCapacity: false
                )]
            )))

            guard case .unavailable =
                await store.resumeDownload(modelID: modelID)
            else {
                Issue.record("expected resume refusal")
                continue
            }
            #expect(cli.channels.count == 1)
        }
    }

    @Test("cancelling a delayed preflight cannot create a late event stream")
    func cancelledDelayedStartNeverSpawns() async {
        let modelID = "mlx/Qwen-7B"
        let qwen = catalogEntry(id: modelID, sizeBytes: 4_000)!
        let gate = StubPreparationGate()
        let cli = StubModelCatalogCLI(
            snapshot: .success(makeSnapshot(catalog: [qwen])),
            preparationGate: gate
        )
        let store = ModelLibraryStore(live: cli)
        await store.start()

        let start = Task {
            await store.beginDownload(modelID: modelID)
        }
        #expect(await _eventually { cli.prepareCount == 1 })
        #expect(cli.channels.isEmpty)
        start.cancel()
        await gate.open()
        _ = await start.value
        await Task.yield()

        #expect(cli.channels.isEmpty)
        #expect(store.models.first?.installation == .notInstalled)
    }

    @Test("download progress, verifying, and done events drive installation state")
    func downloadLifecycle() async throws {
        let qwen = catalogEntry(id: "mlx/Qwen-7B", sizeBytes: 4_000)!
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        #expect(await store.beginDownload(modelID: "mlx/Qwen-7B") == .applied)
        // The pump task creates its stream asynchronously — wait for it.
        #expect(await _eventually { cli.channel(id: 1) != nil })
        let channel = try #require(cli.channel(id: 1))

        guard case .downloading(let initial) = store.models.first?.installation else {
            Issue.record("expected downloading")
            return
        }
        #expect(initial.downloadedBytes == 0)

        channel.continuation.yield(.progress(file: "model-00001-of-00002.safetensors", bytes: 1000, total: 3000))
        #expect(await _eventually {
            guard case .downloading(let p) = store.models.first?.installation else { return false }
            return p.downloadedBytes == 1000 && p.totalBytes == 4000
        })

        channel.continuation.yield(.progress(file: "model-00002-of-00002.safetensors", bytes: 500, total: 1000))
        #expect(await _eventually {
            guard case .downloading(let p) = store.models.first?.installation else { return false }
            return p.downloadedBytes == 1500
        })

        channel.continuation.yield(.verifying)
        #expect(await _eventually {
            guard case .verifying = store.models.first?.installation else { return false }
            return true
        })

        channel.continuation.yield(.done)
        #expect(await _eventually { store.models.first?.isInstalled == true })

        // The settle refresh publishes "now installed" disk truth.
        cli.setSnapshot(.success(makeSnapshot(catalog: [qwen], local: [localEntry(id: "mlx/Qwen-7B")])))
        channel.continuation.finish()
        #expect(await _eventually { cli.fetchCount >= 2 })
        #expect(store.models.first?.isInstalled == true)
    }

    @Test("a failure mid-download keeps staged bytes resumable")
    func downloadFailureResumable() async throws {
        let qwen = catalogEntry(id: "mlx/Qwen-7B", sizeBytes: 4_000)!
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        #expect(await store.beginDownload(modelID: "mlx/Qwen-7B") == .applied)
        #expect(await _eventually { cli.channel(id: 1) != nil })
        let channel = try #require(cli.channel(id: 1))

        channel.continuation.yield(.progress(file: "a.bin", bytes: 1500, total: 4000))
        #expect(await _eventually {
            store.models.first?.installation.progress?.downloadedBytes == 1500
        })

        channel.continuation.finish(throwing: ModelCatalogCLIError.exited(1, message: "download failed: connection lost"))
        #expect(await _eventually {
            guard case .failed = store.models.first?.installation else { return false }
            return true
        })

        guard case .failed(let failure) = store.models.first?.installation else {
            Issue.record("expected failed installation")
            return
        }
        #expect(failure.isResumable)
        #expect(failure.message.contains("connection lost"))
        #expect(failure.resumableProgress?.downloadedBytes == 1500)
    }

    @Test("pause terminates the child; resume relaunches the CLI with the staged credit")
    func pauseAndResume() async throws {
        let qwen = catalogEntry(id: "mlx/Qwen-7B", sizeBytes: 4_000)!
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        #expect(await store.beginDownload(modelID: "mlx/Qwen-7B") == .applied)
        #expect(await _eventually { cli.channel(id: 1) != nil })
        let first = try #require(cli.channel(id: 1))
        first.continuation.yield(.progress(file: "a.bin", bytes: 2000, total: 4000))
        #expect(await _eventually {
            store.models.first?.installation.progress?.downloadedBytes == 2000
        })

        #expect(store.pauseDownload(modelID: "mlx/Qwen-7B") == .applied)
        guard case .paused(let paused) = store.models.first?.installation else {
            Issue.record("expected paused")
            return
        }
        #expect(paused.downloadedBytes == 2000)

        // The first child was terminated.
        #expect(await _eventually { cli.cancelledChannelIDs.contains(1) })

        // Resume relaunches the CLI; the staged prefix returns as the first
        // progress, so the bar continues at 50% instead of restarting.
        #expect(await store.resumeDownload(modelID: "mlx/Qwen-7B") == .applied)
        #expect(await _eventually { cli.channel(id: 2) != nil })
        let second = try #require(cli.channel(id: 2))
        second.continuation.yield(.progress(file: "a.bin", bytes: 2500, total: 4000))
        #expect(await _eventually {
            guard case .downloading(let p) = store.models.first?.installation else { return false }
            return p.downloadedBytes == 2500 && p.resumedBytes == 2000 && p.isResumed
        })

        second.continuation.yield(.done)
        #expect(await _eventually { store.models.first?.isInstalled == true })
    }

    @Test("removeModel shells out and the row converges after refresh")
    func removeModelCLI() async {
        let localOnly = localEntry(id: "local/custom")
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(local: [localOnly])))
        let store = ModelLibraryStore(live: cli)
        await store.start()
        #expect(store.models.count == 1)

        // Arrange the post-removal world first: the refresh the removal
        // triggers must see a scan that no longer lists the model.
        cli.setSnapshot(.success(makeSnapshot()))

        #expect(store.removeModel(modelID: "local/custom") == .applied)
        #expect(await _eventually { cli.removedModelIDs == ["local/custom"] })
        #expect(await _eventually { cli.fetchCount >= 2 })
        #expect(await _eventually { store.models.isEmpty })
    }
}
