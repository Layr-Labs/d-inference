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
    var removeError: Error?

    var fetchCount: Int { lock.withLock { fetchCountStorage } }
    var channels: [DownloadChannel] { lock.withLock { channelStorage } }
    var cancelledChannelIDs: Set<Int> { lock.withLock { cancelledChannelIDStorage } }
    var removedModelIDs: [String] { lock.withLock { removedModelIDStorage } }

    init(snapshot: Result<ModelLibrarySnapshot, Error>) {
        snapshotStorage = snapshot
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

    func downloadEvents(modelID: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
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
        local: [CLILocalModelEntry] = [],
        warmModelIDs: Set<String> = [],
        servingModelID: String? = nil,
        physicalMemoryGB: Int? = 32
    ) -> ModelLibrarySnapshot {
        ModelLibrarySnapshot(
            catalog: catalog,
            local: local,
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
        #expect(store.beginDownload(modelID: "anything") == .modelNotFound)

        // Recover: the same stub then serves a real catalog.
        let entry = catalogEntry(id: "mlx/Qwen-7B")!
        cli.setSnapshot(.success(makeSnapshot(catalog: [entry])))
        store.retryCatalog()
        #expect(await _eventually { store.catalogState == .available(lastUpdated: makeSnapshot().fetchedAt) })
        #expect(cli.fetchCount == 2)
    }

    @Test("download progress, verifying, and done events drive installation state")
    func downloadLifecycle() async throws {
        let qwen = catalogEntry(id: "mlx/Qwen-7B", sizeBytes: 4_000)!
        let cli = StubModelCatalogCLI(snapshot: .success(makeSnapshot(catalog: [qwen])))
        let store = ModelLibraryStore(live: cli)
        await store.start()

        #expect(store.beginDownload(modelID: "mlx/Qwen-7B") == .applied)
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

        #expect(store.beginDownload(modelID: "mlx/Qwen-7B") == .applied)
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

        #expect(store.beginDownload(modelID: "mlx/Qwen-7B") == .applied)
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
        #expect(store.resumeDownload(modelID: "mlx/Qwen-7B") == .applied)
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
